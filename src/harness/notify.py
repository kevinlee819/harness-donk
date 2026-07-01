"""Event router — ports lib/notify.sh.

Three outputs:
  1. INSERT into events table (db.event_write)
  2. JSON file under <project>/.harness/events/<ts>-<event_type>-<task_id>.json
  3. fire-and-forget hooks/notification.sh
  4. tmux send-keys poke into coordinator pane (if idle) so it reacts without
     waiting for the user to type a message.

See docs/interfaces.md §8.1.
"""

from __future__ import annotations

import datetime
import hashlib
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Optional

from harness import db
from harness.atomic_write import write_json

ALLOWED = {"needs_decision", "task_completed", "task_failed", "task_blocked"}

# Debounce: don't inject more than once per N seconds across all threads.
_last_poke_time: float = 0.0
_POKE_DEBOUNCE_S: float = 15.0


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


def _session_name(proj_dir: Path) -> str:
    """Derive the harness-infi tmux session name for a project directory.

    Must match the formula in bin/harness-infi:
        hash=$(printf '%s' "$cwd" | shasum -a 256 | cut -c1-8)
        session="harness-$hash"
    """
    hash8 = hashlib.sha256(str(proj_dir).encode()).hexdigest()[:8]
    return f"harness-{hash8}"


POKE_SENTINEL = "🔔"
"""Single-emoji trigger we inject into the coordinator pane to wake Claude up
without polluting the chat history. Coordinator.md §2.3 treats this as
'process events, respond only if needed, never echo.' Kept short on purpose:
the user WILL see it once in their scrollback per fire — `[watchdog] auto-check`
was 21 chars per fire, which adds up fast on a busy day."""


def _poke_coordinator_if_idle(proj_dir: Path) -> None:
    """Inject the wake sentinel into the coordinator pane if it looks idle.

    'Idle' means Claude Code is showing an empty input prompt (user hasn't
    started typing and Claude isn't generating). This prevents garbling
    in-progress user input.

    Fire-and-forget: all errors are silently swallowed.
    """
    global _last_poke_time
    now = time.time()
    if now - _last_poke_time < _POKE_DEBOUNCE_S:
        return

    session = _session_name(proj_dir)
    # Pane addressing uses window INDEX (0), not name — the window used to be
    # called `coordinator` but is now `main`; index is rename-proof.
    pane = f"{session}:0.0"
    try:
        # Quick existence check
        r = subprocess.run(
            ["tmux", "has-session", "-t", session],
            capture_output=True, timeout=2,
        )
        if r.returncode != 0:
            return

        # Capture last line of coordinator pane to detect idle prompt
        r2 = subprocess.run(
            ["tmux", "capture-pane", "-t", pane, "-p"],
            capture_output=True, text=True, timeout=2,
        )
        if r2.returncode != 0:
            return
        lines = [l for l in r2.stdout.splitlines() if l.strip()]
        if not lines:
            return
        last = lines[-1]
        # Claude Code's input prompt is "> " with nothing after it when idle.
        # If user has typed something, last will be "> <their text>".
        if not re.match(r"^\s*>\s*$", last):
            return

        _last_poke_time = now
        subprocess.Popen(
            ["tmux", "send-keys", "-t", pane, POKE_SENTINEL, "Enter"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


def notify(event_type: str, task_id: Optional[str], payload: dict) -> int:
    """Emit an event. Returns the new event id.

    `task_id` of None or "-" means project-level event (e.g. task_blocked
    covering multiple downstream tasks).
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

    # Poke the coordinator pane so it processes this event without waiting
    # for the user to send a message first.
    try:
        _poke_coordinator_if_idle(_project_dir())
    except Exception:
        pass

    return eid
