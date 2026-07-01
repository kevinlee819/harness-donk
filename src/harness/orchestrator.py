"""Orchestrator main loop — parallel worker pool + serial merger.

Replaces orchestrator.sh. Threading model:
  - main thread: reap orphans → timeout blocked → scan resume → budget guard
    → claim free slots → drain merge queue → sleep
  - worker threads: drive one task end-to-end (adapter → gate → retry)
  - merge: strictly serial on main thread (consumes from queue)

See plan: /Users/kevinlee/.claude/plans/robust-bubbling-iverson.md
"""

from __future__ import annotations

import datetime
import json
import logging
import os
import queue
import signal
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from harness import db
from harness import merge as merge_mod
from harness.config import read_config
from harness.merge import MergeRequest
from harness.notify import notify
from harness.worker import WorkerJob, WorkerThread

log = logging.getLogger("harness.orchestrator")


@dataclass
class RuntimeConfig:
    project_dir: Path
    harness_home: Path
    backend: str
    model: str
    mock: bool
    once: bool
    max_retries: int
    max_workers: int


class Pool:
    """Worker slot bookkeeping. Slots are w1..wN; reused as threads finish.

    Tracks two distinct sets of "this orchestrator owns it" task IDs:
      - `_in_flight`: a WorkerThread is actively running the task
      - `_pending_merge`: worker finished + posted MergeRequest, but main
        thread hasn't merged yet. Without this, the reaper can see a task
        in 'gating' state with no live worker (worker exited after posting)
        and falsely reap it, causing double-dispatch.

    `protected_task_ids()` returns the union — what reap_orphans must exclude.
    """

    def __init__(self, size: int):
        self.size = size
        self._free: list[str] = [f"w{i+1}" for i in range(size)]
        self._busy: dict[str, WorkerThread] = {}
        self._in_flight: dict[str, str] = {}  # worker_id -> task_id
        self._pending_merge: set[str] = set()
        self._lock = threading.Lock()

    def free_slot(self) -> Optional[str]:
        with self._lock:
            return self._free.pop(0) if self._free else None

    def assign(self, worker_id: str, task_id: str, thread: WorkerThread) -> None:
        with self._lock:
            self._busy[worker_id] = thread
            self._in_flight[worker_id] = task_id

    def release(self, worker_id: str, task_id: str) -> None:
        with self._lock:
            self._busy.pop(worker_id, None)
            self._in_flight.pop(worker_id, None)
            if worker_id not in self._free:
                self._free.append(worker_id)
                self._free.sort()  # keep deterministic order

    def mark_pending_merge(self, task_id: str) -> None:
        with self._lock:
            self._pending_merge.add(task_id)

    def unmark_pending_merge(self, task_id: str) -> None:
        with self._lock:
            self._pending_merge.discard(task_id)

    def in_flight_task_ids(self) -> list[str]:
        with self._lock:
            return list(self._in_flight.values())

    def protected_task_ids(self) -> list[str]:
        """Union of in-flight + pending-merge — what reaper must exclude."""
        with self._lock:
            return list(set(self._in_flight.values()) | self._pending_merge)

    def busy_count(self) -> int:
        with self._lock:
            return len(self._busy)

    def has_work(self) -> bool:
        """True if any worker is running OR any merge is queued for main thread."""
        with self._lock:
            return bool(self._busy or self._pending_merge)

    def join_all(self, timeout: float = 60.0) -> None:
        with self._lock:
            threads = list(self._busy.values())
        for t in threads:
            t.join(timeout=timeout)


# ── globals (set by main) ────────────────────────────────
_shutdown = threading.Event()
_pool: Optional[Pool] = None
_merge_q: "queue.Queue[MergeRequest]" = queue.Queue()


def _handle_sigint(signum, frame) -> None:
    log.info("SIGINT received — stopping new claims, waiting for in-flight workers")
    _shutdown.set()


def _reap_orphans(cfg: RuntimeConfig) -> None:
    threshold = int(read_config("dead_worker_threshold_min", "5"))
    max_red = int(os.environ.get("HARNESS_MAX_REDISPATCHES", "2"))
    # Exclude both: actively-running workers' tasks AND tasks awaiting merge.
    # The second set matters because workers exit immediately after posting
    # a MergeRequest — without protected_task_ids, a tight reap loop sees the
    # task in 'gating' with no live worker and falsely reaps it.
    exclude = _pool.protected_task_ids() if _pool else []
    try:
        rows = db.query_orphans(threshold, exclude_ids=exclude)
    except Exception:
        log.exception("query_orphans failed")
        return
    for tid, status, retries, reds, updated in rows:
        if reds < max_red:
            log.info("orphan reap: %s (status=%s updated=%s reds=%d) → queued",
                     tid, status, updated, reds)
            db.inc_redispatches(tid)
            db.transition(tid, "queued", "orphan_redispatch")
        else:
            log.info("orphan reap: %s (status=%s reds=%d maxed) → failed",
                     tid, status, reds)
            db.transition(tid, "failed", "orphan_max_redispatches")
            notify("task_failed", tid,
                   {"reason": "orphan_max_redispatches", "redispatches": reds})


def _timeout_blocked() -> None:
    hrs = int(read_config("blocked_timeout_hours", "72"))
    try:
        rows = db.query_blocked_overdue(hrs)
    except Exception:
        log.exception("query_blocked_overdue failed")
        return
    for tid, since in rows:
        log.info("BLOCKED timeout: %s (blocked since %s) → failed", tid, since)
        db.transition(tid, "failed", "blocked_timeout")
        notify("task_failed", tid,
               {"reason": "blocked_timeout", "blocked_since": since, "threshold_hours": hrs})


def _scan_resume_blocked(cfg: RuntimeConfig) -> int:
    """Find BLOCKED tasks with an inbox answer → spawn resume worker.

    Returns count spawned (so the main loop can track spawned_any for --once).
    """
    if _shutdown.is_set():
        return 0
    inbox = cfg.project_dir / ".harness" / "inbox"
    try:
        rows = db.query_by_status("blocked")
    except Exception:
        log.exception("query_by_status(blocked) failed")
        return 0
    n = 0
    for tid, status, wid, retries, prio, created in rows:
        ans = inbox / f"{tid}.answer"
        if not ans.is_file():
            continue
        slot = _pool.free_slot()
        if not slot:
            return n
        job = _make_job(cfg, slot, tid, spec_path="", kind="resume")
        _spawn(job)
        n += 1
    return n


def _make_job(cfg: RuntimeConfig, worker_id: str, task_id: str,
              spec_path: str, kind: str) -> WorkerJob:
    return WorkerJob(
        task_id=task_id,
        worker_id=worker_id,
        spec_path=spec_path,
        kind=kind,
        project_dir=cfg.project_dir,
        worktree_base=Path(os.path.dirname(cfg.project_dir)) / ".worktrees" / cfg.project_dir.name,
        log_dir=cfg.project_dir / ".harness" / "logs" / "raw",
        inbox_dir=cfg.project_dir / ".harness" / "inbox",
        inbox_processed=cfg.project_dir / ".harness" / "inbox" / "processed",
        harness_home=cfg.harness_home,
        backend=cfg.backend,
        model=cfg.model,
        mock=cfg.mock,
        max_retries=cfg.max_retries,
        merge_queue=_merge_q,
        mark_pending_merge=(_pool.mark_pending_merge if _pool else None),
    )


def _on_worker_exit(worker_id: str, task_id: str) -> None:
    assert _pool is not None
    _pool.release(worker_id, task_id)


def _spawn(job: WorkerJob) -> None:
    assert _pool is not None
    t = WorkerThread(job, on_exit=_on_worker_exit)
    _pool.assign(job.worker_id, job.task_id, t)
    t.start()


def _claim_into_pool(cfg: RuntimeConfig) -> int:
    """Claim as many tasks as there are free slots. Returns spawn count."""
    if _shutdown.is_set():
        return 0
    n = 0
    while True:
        slot = _pool.free_slot() if _pool else None
        if not slot:
            return n
        try:
            row = db.claim(slot)
        except Exception:
            log.exception("db.claim failed")
            _pool.release(slot, "")  # give slot back
            return n
        if row is None:
            # No task → return slot
            _pool.release(slot, "")
            return n
        task_id, spec_path = row
        job = _make_job(cfg, slot, task_id, spec_path, kind="initial")
        _spawn(job)
        n += 1
        if cfg.once:
            return n  # --once: at most one claim


def _ensure_dirs(cfg: RuntimeConfig) -> None:
    base = Path(os.path.dirname(cfg.project_dir)) / ".worktrees" / cfg.project_dir.name
    base.mkdir(parents=True, exist_ok=True)
    (cfg.project_dir / ".harness" / "logs" / "raw").mkdir(parents=True, exist_ok=True)
    (cfg.project_dir / ".harness" / "inbox").mkdir(parents=True, exist_ok=True)
    (cfg.project_dir / ".harness" / "inbox" / "processed").mkdir(parents=True, exist_ok=True)


def run(cfg: RuntimeConfig) -> int:
    global _pool
    _pool = Pool(cfg.max_workers)
    signal.signal(signal.SIGINT, _handle_sigint)
    signal.signal(signal.SIGTERM, _handle_sigint)

    # Persist downstream-blocked dedup across orchestrator restarts (Bug 12).
    # Previously the set was in-memory only, so each restart re-fired
    # downstream_blocked for every still-blocked task — generating 3+ alerts
    # per task per hour when the orchestrator was being bounced. We persist
    # the set of (blocked_id, root_failed_id) pairs we've notified about;
    # only when a NEW root failure emerges for a blocked task do we re-alert.
    stuck_state_path = cfg.project_dir / ".harness" / ".stuck-notified.json"
    _stuck_notified_pairs: set[tuple[str, str]] = set()
    if stuck_state_path.is_file():
        try:
            data = json.loads(stuck_state_path.read_text())
            _stuck_notified_pairs = {(b, r) for b, r in data.get("pairs", [])}
        except (json.JSONDecodeError, OSError):
            pass

    adapter_sh = cfg.harness_home / "adapters" / f"{cfg.backend}.sh"
    if not adapter_sh.is_file():
        print(f"unknown backend: {cfg.backend} (no {adapter_sh})", file=sys.stderr)
        return 1

    os.chdir(cfg.project_dir)
    db_path = cfg.project_dir / ".harness" / "harness.db"
    if not db_path.is_file():
        print(f"harness not initialized in {cfg.project_dir} — run 'harness init'",
              file=sys.stderr)
        return 2
    os.environ["HARNESS_DB"] = str(db_path)
    _ensure_dirs(cfg)

    spawned_any = False
    heartbeat_path = cfg.project_dir / ".harness" / ".orchestrator-heartbeat"

    def _beat() -> None:
        # Truthful liveness signal for watchdog. Replaces the old "max(tasks.updated)"
        # heuristic, which false-alarmed when all tasks were queued-waiting-on-deps
        # (Bug 9). Plain epoch-seconds; one writer, last-writer-wins is fine.
        try:
            heartbeat_path.write_text(str(int(time.time())))
        except OSError:
            log.exception("heartbeat write failed")

    while True:
        _beat()
        if _shutdown.is_set() and _pool.busy_count() == 0:
            return 0

        if not _shutdown.is_set():
            _reap_orphans(cfg)
            _timeout_blocked()
            resumed = _scan_resume_blocked(cfg)
            spawned_any = spawned_any or resumed > 0
            claimed = _claim_into_pool(cfg)
            spawned_any = spawned_any or claimed > 0

        # Drain merges serially (main thread). The on_done callback clears
        # the pending_merge bookkeeping so reap_orphans no longer protects.
        merge_mod.drain_queue(
            _merge_q, cfg.project_dir, cfg.backend, cfg.harness_home,
            on_done=_pool.unmark_pending_merge,
        )

        if cfg.once:
            # In --once: wait for the one spawned worker to finish + merge, then exit.
            # If queue was empty and we spawned nothing, exit immediately.
            if not spawned_any:
                log.info("queue empty (or budget locked)")
                return 0
            if not _pool.has_work():
                # workers all done AND no merge still pending; drain residual + exit
                merge_mod.drain_queue(
                    _merge_q, cfg.project_dir, cfg.backend, cfg.harness_home,
                    on_done=_pool.unmark_pending_merge,
                )
                return 0

        if _shutdown.is_set():
            # Drain remaining merges as workers finish
            time.sleep(0.2)
            continue

        if not _pool.has_work():
            log.info("queue empty (or budget locked)")
            # Detect queued tasks permanently blocked by a failed dependency.
            # Dedup at the (blocked, failed_root) pair level so that orchestrator
            # restarts and root-task retry-fail flaps don't cause repeat alerts
            # for the same blocking relationship (Bug 12).
            try:
                pairs = db.query_stuck_queued_pairs()
                new_pairs = [p for p in pairs if p not in _stuck_notified_pairs]
                if new_pairs:
                    _stuck_notified_pairs.update(new_pairs)
                    try:
                        stuck_state_path.write_text(
                            json.dumps({"pairs": sorted(_stuck_notified_pairs)})
                        )
                    except OSError:
                        log.exception("stuck-state write failed")
                    blocked_ids = sorted({b for b, _ in new_pairs})
                    log.warning(
                        "STUCK: %d new blocked-by-failed-dep edge(s): %s — "
                        "retry the failed root or update spec",
                        len(new_pairs), new_pairs,
                    )
                    notify("task_blocked", blocked_ids[0], {
                        "reason": "downstream_blocked",
                        "blocked_tasks": blocked_ids,
                        "edges": [{"blocked": b, "failed_root": r}
                                  for b, r in new_pairs],
                    })
            except Exception:
                log.exception("stuck-check failed")
            time.sleep(5)
        else:
            time.sleep(0.5)


def main(argv: Optional[list[str]] = None) -> int:
    import argparse
    p = argparse.ArgumentParser(prog="harness-orchestrator")
    p.add_argument("--once", action="store_true")
    p.add_argument("--project", default=os.getcwd())
    p.add_argument("--mock", action="store_true")
    p.add_argument("--max-retries", type=int, default=3)
    p.add_argument("--model", default=os.environ.get("HARNESS_MODEL", ""))
    p.add_argument("--backend", default=os.environ.get("HARNESS_BACKEND", "claude"))
    p.add_argument("--max-workers", type=int,
                   default=int(os.environ.get("HARNESS_MAX_WORKERS", "4")))
    args = p.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="[orchestrator %(asctime)s] %(message)s",
        datefmt="%H:%M:%S",
        stream=sys.stderr,
    )

    cfg = RuntimeConfig(
        project_dir=Path(args.project).resolve(),
        harness_home=Path(os.environ.get("HARNESS_HOME",
                                          str(Path(__file__).resolve().parents[2]))),
        backend=args.backend,
        model=args.model,
        mock=args.mock,
        once=args.once,
        max_retries=args.max_retries,
        max_workers=1 if args.once else max(1, args.max_workers),
    )
    return run(cfg)


if __name__ == "__main__":
    sys.exit(main())
