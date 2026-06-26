"""Event router — ports lib/notify.sh.

Three outputs:
  1. INSERT into events table (db.event_write)
  2. JSON file under <project>/.harness/events/<ts>-<event_type>-<task_id>.json
  3. fire-and-forget hooks/notification.sh

See docs/interfaces.md §8.1.
"""

from __future__ import annotations

import datetime
import os
import subprocess
from pathlib import Path
from typing import Optional

from harness import db
from harness.atomic_write import write_json

ALLOWED = {"needs_decision", "task_completed", "task_failed", "budget_exceeded"}


def _project_dir() -> Path:
    """Derive project dir from HARNESS_DB path: <proj>/.harness/harness.db."""
    p = os.environ.get("HARNESS_DB")
    if not p:
        raise RuntimeError("HARNESS_DB env not set")
    return Path(p).parent.parent


def _now_iso() -> str:
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def _now_compact() -> str:
    return datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")


def notify(event_type: str, task_id: Optional[str], payload: dict) -> int:
    """Emit an event. Returns the new event id.

    `task_id` of None or "-" means project-level event (e.g. budget_exceeded).
    """
    if event_type not in ALLOWED:
        raise ValueError(f"invalid event_type: {event_type}")

    tid = task_id if task_id and task_id != "-" else None
    eid = db.event_write(event_type, tid, payload)

    ev_dir = _project_dir() / ".harness" / "events"
    tid_seg = tid if tid else "none"
    fname = ev_dir / f"{_now_compact()}-{event_type}-{tid_seg}.json"
    write_json(
        fname,
        {
            "schema_version": 1,
            "id": eid,
            "ts": _now_iso(),
            "event_type": event_type,
            "task_id": tid,
            "payload": payload,
        },
    )

    nhook_env = os.environ.get("HARNESS_HOME")
    if nhook_env:
        nhook = Path(nhook_env) / "hooks" / "notification.sh"
        if nhook.is_file() and os.access(nhook, os.X_OK):
            subprocess.Popen(
                [str(nhook), event_type, tid or "-", str(fname)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )

    return eid
