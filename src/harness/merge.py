"""MergeRequest + serial merger.

Workers post on gate-pass; the orchestrator's main thread drains the queue
and runs git merge strictly serially (phase-four acceptance: no merge race).
"""

from __future__ import annotations

import datetime
import logging
import queue
import subprocess
from dataclasses import dataclass
from pathlib import Path

from harness import db
from harness.atomic_write import write_json
from harness.notify import notify

log = logging.getLogger("harness.merge")


def _now_iso() -> str:
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class MergeRequest:
    task_id: str
    worker_id: str
    branch: str
    worktree: Path
    session_id: str


def do_merge(req: MergeRequest, project_dir: Path, backend: str, harness_home: Path) -> bool:
    """Run git merge serially. Returns True on success."""
    db.transition(req.task_id, "gating", "merging")
    main_branch_proc = subprocess.run(
        ["git", "-C", str(project_dir), "symbolic-ref", "--short", "HEAD"],
        capture_output=True, text=True,
    )
    main_branch = main_branch_proc.stdout.strip() or "main"
    log.info("merging %s into %s", req.branch, main_branch)

    merge_proc = subprocess.run(
        ["git", "-C", str(project_dir), "merge", "--no-ff", req.branch,
         "-m", f"harness: merge {req.task_id}"],
        capture_output=True, text=True,
    )
    worker_status_path = project_dir / ".harness" / "workers" / req.worker_id / "status.json"

    if merge_proc.returncode == 0:
        log.info("merged %s", req.task_id)
        db.transition(req.task_id, "merged", "ok")
        write_json(worker_status_path, {
            "schema_version": 1,
            "worker_id": req.worker_id,
            "backend": backend,
            "session_id": req.session_id,
            "task_id": req.task_id,
            "status": "done",
            "branch": req.branch,
            "progress": "merged",
            "turns": 0,
            "files_changed": 0,
            "blockers": [],
            "updated": _now_iso(),
        })
        notify("task_completed", req.task_id, {"branch": req.branch})
        # Cleanup worktree + branch (best effort)
        subprocess.run(
            ["git", "-C", str(project_dir), "worktree", "remove", "--force", str(req.worktree)],
            capture_output=True, text=True,
        )
        subprocess.run(
            ["git", "-C", str(project_dir), "branch", "-D", req.branch],
            capture_output=True, text=True,
        )
        # Best-effort backup
        subprocess.run(
            [str(harness_home / "bin" / "harness"), "backup"],
            capture_output=True, text=True,
        )
        return True

    log.info("merge failed: %s", merge_proc.stderr.strip() or merge_proc.stdout.strip())
    # Abort the half-applied merge so the working tree is clean for the next attempt.
    # Without this, subsequent merges see "unmerged files" and cascade-fail.
    subprocess.run(
        ["git", "-C", str(project_dir), "merge", "--abort"],
        capture_output=True, text=True,
    )
    db.transition(req.task_id, "failed", "merge_conflict")
    notify("task_failed", req.task_id, {"reason": "merge_conflict"})
    return False


def drain_queue(
    q: "queue.Queue[MergeRequest]",
    project_dir: Path,
    backend: str,
    harness_home: Path,
    on_done=None,  # Optional[Callable[[str], None]] — called after each merge attempt
) -> int:
    """Pop and merge all queued requests serially. Returns count processed.

    `on_done(task_id)` fires whether merge succeeded or not — used by the
    orchestrator to remove the task from `pending_merge` so reap_orphans
    no longer needs to protect it.
    """
    n = 0
    while True:
        try:
            req = q.get_nowait()
        except queue.Empty:
            break
        try:
            do_merge(req, project_dir, backend, harness_home)
        except Exception:
            log.exception("merge crashed for %s", req.task_id)
        finally:
            if on_done is not None:
                try:
                    on_done(req.task_id)
                except Exception:
                    log.exception("on_done hook failed for %s", req.task_id)
        n += 1
    return n
