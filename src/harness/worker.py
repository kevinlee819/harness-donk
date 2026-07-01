"""WorkerThread — runs one task end-to-end (adapter → gate → retry loop).

Posts a MergeRequest on success; transitions the task to FAILED/BLOCKED in DB
otherwise. The thread is single-task — one job per run.
"""

from __future__ import annotations

import datetime
import json
import logging
import queue
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from harness import db
from harness.adapter import call as adapter_call
from harness.atomic_write import write_json
from harness.i18n import t
from harness.merge import MergeRequest
from harness.notify import notify

log = logging.getLogger("harness.worker")


def _now_iso() -> str:
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class WorkerJob:
    task_id: str
    worker_id: str
    spec_path: str  # relative to project_dir
    kind: str  # "initial" or "resume"
    project_dir: Path
    worktree_base: Path
    log_dir: Path
    inbox_dir: Path
    inbox_processed: Path
    harness_home: Path
    backend: str
    model: str
    mock: bool
    max_retries: int
    merge_queue: "queue.Queue[MergeRequest]"
    # Called before posting MergeRequest — tells the orchestrator to keep this
    # task in the reap exclusion set even after the worker thread exits.
    mark_pending_merge: object = None  # Callable[[str], None] or None


class WorkerThread(threading.Thread):
    def __init__(self, job: WorkerJob, on_exit=None):
        super().__init__(name=f"worker-{job.worker_id}-{job.task_id}", daemon=False)
        self.job = job
        self._on_exit = on_exit

    # ── public ─────────────────────────────────────────
    def run(self) -> None:
        j = self.job
        try:
            if j.kind == "initial":
                self._run_initial()
            elif j.kind == "resume":
                self._run_resume()
            else:
                raise ValueError(f"unknown job kind: {j.kind}")
        except Exception as e:
            log.exception("[%s/%s] worker crashed: %s", j.worker_id, j.task_id, e)
            try:
                db.transition(j.task_id, "failed", f"worker_exception:{e}")
                notify("task_failed", j.task_id, {"reason": "worker_exception", "error": str(e)})
            except Exception:
                pass
        finally:
            if self._on_exit:
                try:
                    self._on_exit(j.worker_id, j.task_id)
                except Exception:
                    log.exception("on_exit hook failed")

    # ── internal ───────────────────────────────────────
    def _worker_dir(self) -> Path:
        return self.job.project_dir / ".harness" / "workers" / self.job.worker_id

    def _write_status(
        self,
        status: str,
        branch: str,
        progress: str,
        sid: str,
        task_id: Optional[str] = None,
    ) -> None:
        j = self.job
        tid = task_id or j.task_id
        path = self._worker_dir() / "status.json"
        write_json(
            path,
            {
                "schema_version": 1,
                "worker_id": j.worker_id,
                "backend": j.backend,
                "session_id": sid,
                "task_id": tid,
                "status": status,
                "branch": branch,
                "progress": progress,
                "turns": 0,
                "files_changed": 0,
                "blockers": [],
                "updated": _now_iso(),
            },
        )

    def _check_blocking(self) -> bool:
        g = self._worker_dir() / "guidance.json"
        if not g.is_file():
            return False
        try:
            data = json.loads(g.read_text())
        except (json.JSONDecodeError, OSError):
            return False
        return bool(data.get("blocking"))

    def _handle_blocked(self, sid: str, branch: str) -> None:
        j = self.job
        g = self._worker_dir() / "guidance.json"
        question, context = "", ""
        if g.is_file():
            try:
                gd = json.loads(g.read_text())
                question = gd.get("question") or ""
                context = gd.get("context") or ""
            except (json.JSONDecodeError, OSError):
                pass
        db.transition(j.task_id, "blocked", "needs_decision")
        self._write_status("working", branch, "awaiting answer", sid)
        notify(
            "needs_decision",
            j.task_id,
            {"question": question, "context": context, "worker_id": j.worker_id},
        )
        log.info("[%s] task %s BLOCKED — awaiting inbox/%s.answer",
                 j.worker_id, j.task_id, j.task_id)

    def _drive(self, branch: str, worktree: Path, prompt_file: Path, sid: str) -> int:
        """Adapter → blocking? → gate → retry loop. Returns 0/1/2 = merged/failed/blocked.

        On gate-pass we post to merge_queue and return 0 — main thread does the
        actual git merge serially.
        """
        j = self.job
        retries = db.get_retries(j.task_id)
        # design §7.1: cap resumes per session to prevent context drift on long tasks
        from harness.config import read_config
        resume_cap = int(read_config("session_resume_cap", "6"))

        while True:
            # Session cap: if we've resumed too many times, drop the session and
            # let adapter start fresh. Code progress is already on disk via the
            # worker's git commits, so 'checkpoint' is implicit.
            if sid:
                rc = db.get_resume_count(j.task_id, j.backend)
                if rc >= resume_cap:
                    log.info("[%s] session resume cap reached (rc=%d ≥ %d) — "
                             "dropping session, next call starts fresh",
                             j.worker_id, rc, resume_cap)
                    db.reset_session(j.task_id, j.backend)
                    sid = ""

            log.info("[%s] call %s adapter (task=%s retries=%d)",
                     j.worker_id, j.backend, j.task_id, retries)
            resp = adapter_call(
                backend=j.backend,
                task_file=prompt_file,
                worktree=worktree,
                log_dir=j.log_dir,
                task_id=j.task_id,
                worker_id=j.worker_id,
                worker_dir=self._worker_dir(),
                session_id=sid,
                model=j.model,
                mock=j.mock,
                harness_home=j.harness_home,
            )

            ok = bool(resp.get("ok"))
            new_sid = resp.get("session_id") or ""
            turns = resp.get("num_turns")
            dur = resp.get("duration_ms") or 0
            fc = resp.get("files_changed") or 0
            err = resp.get("error") or ""

            if new_sid:
                sid = new_sid
                db.register_session(j.task_id, j.backend, sid)

            db.log_call(
                j.task_id, j.worker_id, j.backend, sid or None,
                0 if ok else 1, turns, dur, fc,
            )

            if not ok:
                log.info("[%s] adapter error: %s", j.worker_id, err)
                if retries >= j.max_retries:
                    db.transition(j.task_id, "failed", f"adapter_error:{err}")
                    self._write_status("error", branch, err, sid)
                    notify("task_failed", j.task_id,
                           {"reason": "adapter_error", "error": err})
                    return 1
                retries += 1
                db.inc_retries(j.task_id)
                continue

            if self._check_blocking():
                self._handle_blocked(sid, branch)
                return 2

            db.transition(j.task_id, "gating", "")
            self._write_status("working", branch, "gate running", sid)
            gate_rc = self._run_gate(worktree)
            if gate_rc == 0:
                log.info("[%s] gate passed", j.worker_id)
                # Mark pending-merge BEFORE posting; ensures reap exclusion is
                # in place by the time main thread next runs reap_orphans.
                if j.mark_pending_merge is not None:
                    j.mark_pending_merge(j.task_id)
                j.merge_queue.put(MergeRequest(
                    task_id=j.task_id,
                    worker_id=j.worker_id,
                    branch=branch,
                    worktree=worktree,
                    session_id=sid,
                ))
                return 0

            log.info("[%s] gate failed (retry %d)", j.worker_id, retries)
            if retries >= j.max_retries:
                db.transition(j.task_id, "failed", "gate_failed_after_retries")
                self._write_status("error", branch, "gate_failed", sid)
                summary = self._gate_summary(worktree)
                notify("task_failed", j.task_id,
                       {"reason": "gate_failed_after_retries", "gate": summary})
                return 1
            retries += 1
            db.inc_retries(j.task_id)
            self._write_retry_prompt(prompt_file, worktree)
            db.transition(j.task_id, "working", "regating")

    def _run_gate(self, worktree: Path) -> int:
        j = self.job
        env = {**__import__("os").environ, "HARNESS_TASK_ID": j.task_id}
        proc = subprocess.run(
            ["bash", str(j.harness_home / "lib" / "gate.sh"), str(worktree)],
            env=env,
        )
        return proc.returncode

    def _gate_summary(self, worktree: Path) -> dict:
        report = worktree / ".gate-report.json"
        if not report.is_file():
            return {}
        try:
            data = json.loads(report.read_text())
        except (json.JSONDecodeError, OSError):
            return {}
        steps = []
        for s in data.get("steps", []):
            steps.append({
                "name": s.get("name"),
                "ok": s.get("ok"),
                "output": str(s.get("output", ""))[:200],
            })
        return {"steps": steps}

    def _write_retry_prompt(self, prompt_file: Path, worktree: Path) -> None:
        report = worktree / ".gate-report.json"
        failed_steps = ""
        if report.is_file():
            try:
                data = json.loads(report.read_text())
                lines = []
                for s in data.get("steps", []):
                    if not s.get("ok"):
                        lines.append(f"[{s.get('name')}] {s.get('output', '')}")
                failed_steps = "\n".join(lines)
            except (json.JSONDecodeError, OSError):
                pass
        prompt_file.write_text(t("worker.gate_retry_prompt", steps=failed_steps))

    # ── job entry points ───────────────────────────────
    def _run_initial(self) -> None:
        import shutil
        j = self.job
        worktree = j.worktree_base / j.task_id
        branch = f"harness/{j.task_id}"

        log.info("[%s] claim %s (%s)", j.worker_id, j.task_id, j.spec_path)

        if worktree.exists():
            # Stale worktree from a previous failed/conflict attempt.
            # Reusing old commits causes repeated merge conflicts — remove and
            # recreate so the retry starts from a clean main-branch snapshot.
            log.info("[%s] removing stale worktree for clean retry: %s", j.worker_id, worktree)
            subprocess.run(
                ["git", "-C", str(j.project_dir), "worktree", "remove", "--force", str(worktree)],
                capture_output=True, text=True,
            )
            if worktree.exists():  # worktree remove failed (e.g. open handles)
                shutil.rmtree(str(worktree), ignore_errors=True)
            # Delete the branch so -B re-creates it fresh from HEAD
            subprocess.run(
                ["git", "-C", str(j.project_dir), "branch", "-D", branch],
                capture_output=True, text=True,
            )

        # Prune stale .git/worktrees/ registrations left by shutil.rmtree fallback
        # or previous forced removals; otherwise 'worktree add' reports "already
        # registered" even when the directory no longer exists.
        subprocess.run(
            ["git", "-C", str(j.project_dir), "worktree", "prune"],
            capture_output=True, text=True,
        )

        r = subprocess.run(
            ["git", "-C", str(j.project_dir), "worktree", "add", "-B", branch, str(worktree)],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            log.error("[%s] git worktree add failed: %s", j.worker_id, r.stderr)
            db.transition(j.task_id, "failed", "worktree_add_failed")
            return

        # Belt-and-suspenders cleanup (Bug 7): even though we just created the
        # worktree fresh from main HEAD, hammer it clean so any conceivable
        # leftover from a prior remove-failure can't poison the retry. Cheap.
        subprocess.run(
            ["git", "-C", str(worktree), "reset", "--hard", "HEAD"],
            capture_output=True, text=True,
        )
        subprocess.run(
            ["git", "-C", str(worktree), "clean", "-fdx"],
            capture_output=True, text=True,
        )

        db.set_branch(j.task_id, branch)
        db.transition(j.task_id, "working", "first_dispatch")
        self._write_status("working", branch, "starting", "")

        spec_full = j.project_dir / j.spec_path
        if not spec_full.is_file():
            log.error("[%s] spec not found: %s", j.worker_id, spec_full)
            db.transition(j.task_id, "failed", "spec_not_found")
            return

        prompt_file = worktree / ".harness-prompt.txt"
        prompt_file.write_text(
            t("worker.initial_spec_header") + "\n"
            + spec_full.read_text() + "\n\n"
            + t("worker.initial_instructions")
        )

        self._drive(branch, worktree, prompt_file, "")

    def _run_resume(self) -> None:
        j = self.job
        answer_file = j.inbox_dir / f"{j.task_id}.answer"
        if not answer_file.is_file():
            return

        row = db.query_status(j.task_id)
        if not row:
            log.info("resume: no such task %s", j.task_id)
            return
        tid, status, wid, branch, retries, reds, prio, created = row[0]
        if status != "blocked":
            log.info("resume: %s not blocked (status=%s)", j.task_id, status)
            return

        worktree = j.worktree_base / j.task_id
        if not worktree.is_dir():
            log.info("resume: worktree gone for %s", j.task_id)
            db.transition(j.task_id, "failed", "worktree_lost")
            return

        sid = db.get_session(j.task_id, j.backend) or ""

        try:
            data = json.loads(answer_file.read_text())
            answer = data.get("answer") or ""
        except (json.JSONDecodeError, OSError):
            answer = answer_file.read_text()
        if not answer:
            log.info("resume: empty answer for %s", j.task_id)
            return

        guidance = self._worker_dir() / "guidance.json"
        question = ""
        if guidance.is_file():
            try:
                question = json.loads(guidance.read_text()).get("question") or ""
            except (json.JSONDecodeError, OSError):
                pass

        prompt_file = worktree / ".harness-prompt.txt"
        parts = [t("worker.resume_header")]
        if question:
            parts.append(t("worker.resume_previous_question", question=question))
        parts.append(t("worker.resume_decision", answer=answer))
        parts.append("")
        parts.append(t("worker.resume_instructions"))
        prompt_file.write_text("\n".join(parts) + "\n")

        if guidance.is_file():
            guidance.unlink()
        stamp = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
        answer_file.rename(j.inbox_processed / f"{j.task_id}.answer.{stamp}")

        db.transition(j.task_id, "working", "answered")
        self._write_status("working", branch, "resumed", sid)
        log.info("[%s] resume %s with answer", j.worker_id, j.task_id)
        self._drive(branch, worktree, prompt_file, sid)
