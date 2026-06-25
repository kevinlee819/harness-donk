"""SQLite layer — replaces lib/db.sh.

Short connection / short transaction per call. WAL + busy_timeout for safe
concurrency. Real parameterized queries (no string assembly).

See docs/data-schemas.md §1 for schema definition, docs/interfaces.md §5.1
for function contracts.
"""

from __future__ import annotations

import contextlib
import datetime
import hashlib
import json
import os
import random
import sqlite3
import time
from pathlib import Path
from typing import Iterator, Optional

SCHEMA_VERSION = 1
"""harness.db schema version. Bump on incompatible changes; see CLAUDE.md §8."""


def _now() -> str:
    """UTC ISO-8601 timestamp, second precision (matches bash _now)."""
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def _db_path() -> Path:
    p = os.environ.get("HARNESS_DB")
    if not p:
        raise RuntimeError("HARNESS_DB env not set")
    return Path(p)


@contextlib.contextmanager
def _connect(db_path: Optional[Path] = None) -> Iterator[sqlite3.Connection]:
    """Short-lived connection. WAL + busy_timeout are persistent on the file."""
    p = db_path if db_path is not None else _db_path()
    conn = sqlite3.connect(str(p), timeout=5.0, isolation_level=None)
    # busy_timeout in milliseconds; safety net on top of the Python timeout
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA foreign_keys=ON")
    try:
        yield conn
    finally:
        conn.close()


def init(schema_sql_path: Path, db_path: Optional[Path] = None) -> None:
    """Run schema SQL (idempotent) and verify user_version."""
    p = db_path if db_path is not None else _db_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    sql = schema_sql_path.read_text()
    with _connect(p) as c:
        c.executescript(sql)
        v = c.execute("PRAGMA user_version").fetchone()[0]
        if v != SCHEMA_VERSION:
            raise RuntimeError(
                f"db_init: user_version={v}, expected {SCHEMA_VERSION}"
            )


def add_task(
    task_id: str,
    spec_path: str,
    priority: int = 100,
    depends_on: Optional[list[str]] = None,
) -> None:
    deps = json.dumps(depends_on) if depends_on else None
    now = _now()
    with _connect() as c:
        c.execute(
            "INSERT INTO tasks(id, spec_path, priority, depends_on, created, updated) "
            "VALUES(?, ?, ?, ?, ?, ?)",
            (task_id, spec_path, priority, deps, now, now),
        )


def claim(worker_id: str) -> Optional[tuple[str, str]]:
    """Atomically claim the highest-priority queued task whose deps are met.

    Returns (task_id, spec_path) or None if the queue is empty.
    """
    now = _now()
    with _connect() as c:
        row = c.execute(
            """
            UPDATE tasks
               SET status='dispatched', worker_id=?, updated=?
             WHERE id=(
               SELECT id FROM tasks t1
                WHERE t1.status='queued'
                  AND (t1.depends_on IS NULL OR t1.depends_on=''
                       OR NOT EXISTS (
                         SELECT 1 FROM json_each(t1.depends_on) je
                         JOIN tasks t2 ON t2.id = je.value
                          WHERE t2.status != 'merged'
                       ))
                ORDER BY t1.priority, t1.id LIMIT 1
             )
             RETURNING id, spec_path
            """,
            (worker_id, now),
        ).fetchone()
    return (row[0], row[1]) if row else None


def transition(task_id: str, to_state: str, reason: str = "") -> None:
    """Set tasks.status and append a transitions row in one short transaction."""
    now = _now()
    with _connect() as c:
        c.execute("BEGIN")
        try:
            from_state = c.execute(
                "SELECT status FROM tasks WHERE id=?", (task_id,)
            ).fetchone()
            from_state = from_state[0] if from_state else None
            c.execute(
                "UPDATE tasks SET status=?, updated=? WHERE id=?",
                (to_state, now, task_id),
            )
            c.execute(
                "INSERT INTO transitions(task_id, from_state, to_state, reason, ts) "
                "VALUES(?, ?, ?, ?, ?)",
                (task_id, from_state, to_state, reason or None, now),
            )
            c.execute("COMMIT")
        except Exception:
            c.execute("ROLLBACK")
            raise


def set_branch(task_id: str, branch: str) -> None:
    with _connect() as c:
        c.execute(
            "UPDATE tasks SET branch=?, updated=? WHERE id=?",
            (branch, _now(), task_id),
        )


def inc_retries(task_id: str) -> None:
    with _connect() as c:
        c.execute(
            "UPDATE tasks SET retries=retries+1, updated=? WHERE id=?",
            (_now(), task_id),
        )


def inc_redispatches(task_id: str) -> None:
    """Used by orphan reaper when a task is redispatched after orchestrator crash."""
    with _connect() as c:
        c.execute(
            "UPDATE tasks SET redispatches=redispatches+1, updated=? WHERE id=?",
            (_now(), task_id),
        )


def query_orphans(threshold_minutes: int) -> list[tuple]:
    """Tasks left in transient states with `updated` older than threshold.

    Single-process orchestrator: at loop top, no task of ours is mid-flight
    (run_task is synchronous). Anything still in dispatched/working/gating
    is from a previous crashed run → reap.

    Returns rows of (id, status, retries, redispatches, updated).
    """
    modifier = f"-{int(threshold_minutes)} minutes"
    with _connect() as c:
        rows = c.execute(
            """
            SELECT id, status, retries, redispatches, updated
            FROM tasks
            WHERE status IN ('dispatched','working','gating')
              AND updated < datetime('now', ?)
            ORDER BY priority, id
            """,
            (modifier,),
        ).fetchall()
    return rows


def query_blocked_overdue(threshold_hours: int) -> list[tuple]:
    """Tasks BLOCKED for longer than threshold_hours.

    Returns rows of (id, last_blocked_ts).
    """
    modifier = f"-{int(threshold_hours)} hours"
    with _connect() as c:
        rows = c.execute(
            """
            SELECT t.id, MAX(tr.ts) AS blocked_since
            FROM tasks t
            JOIN transitions tr ON tr.task_id = t.id
            WHERE t.status = 'blocked'
              AND tr.to_state = 'blocked'
            GROUP BY t.id
            HAVING blocked_since < datetime('now', ?)
            ORDER BY blocked_since
            """,
            (modifier,),
        ).fetchall()
    return rows


def get_retries(task_id: str) -> int:
    with _connect() as c:
        row = c.execute(
            "SELECT retries FROM tasks WHERE id=?", (task_id,)
        ).fetchone()
    return int(row[0]) if row else 0


def register_session(task_id: str, backend: str, session_id: str) -> None:
    """Upsert session: on conflict bump resume_count and refresh last_seen."""
    with _connect() as c:
        c.execute(
            """
            INSERT INTO sessions(task_id, backend, session_id, last_seen)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(task_id, backend) DO UPDATE SET
              session_id   = excluded.session_id,
              resume_count = resume_count + 1,
              last_seen    = excluded.last_seen
            """,
            (task_id, backend, session_id, _now()),
        )


def get_session(task_id: str, backend: str) -> Optional[str]:
    with _connect() as c:
        row = c.execute(
            "SELECT session_id FROM sessions WHERE task_id=? AND backend=?",
            (task_id, backend),
        ).fetchone()
    return row[0] if row else None


def log_call(
    task_id: str,
    worker_id: str,
    backend: str,
    session_id: Optional[str],
    exit_code: int,
    cost_usd: Optional[float],
    num_turns: Optional[int],
    duration_ms: Optional[int],
    files_changed: int,
) -> None:
    with _connect() as c:
        c.execute(
            "INSERT INTO calls(ts, task_id, worker_id, backend, session_id, "
            "exit_code, cost_usd, num_turns, duration_ms, files_changed) "
            "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                _now(),
                task_id,
                worker_id,
                backend,
                session_id,
                exit_code,
                cost_usd,
                num_turns,
                duration_ms,
                files_changed,
            ),
        )


def today_cost() -> float:
    with _connect() as c:
        row = c.execute(
            "SELECT COALESCE(SUM(cost_usd), 0) FROM calls "
            "WHERE ts >= datetime('now', 'start of day')"
        ).fetchone()
    return float(row[0])


def query_status(task_id: Optional[str] = None) -> list[tuple]:
    """Return rows (id, status, worker_id, branch, retries, redispatches, priority, created)."""
    with _connect() as c:
        if task_id:
            rows = c.execute(
                "SELECT id, status, COALESCE(worker_id,''), COALESCE(branch,''), "
                "retries, redispatches, priority, created "
                "FROM tasks WHERE id=?",
                (task_id,),
            ).fetchall()
        else:
            rows = c.execute(
                "SELECT id, status, COALESCE(worker_id,''), COALESCE(branch,''), "
                "retries, redispatches, priority, created "
                "FROM tasks ORDER BY priority, id"
            ).fetchall()
    return rows


def query_by_status(status: str) -> list[tuple]:
    """Return rows of (id, status, worker_id, retries, priority, created)."""
    with _connect() as c:
        rows = c.execute(
            "SELECT id, status, COALESCE(worker_id,''), retries, priority, created "
            "FROM tasks WHERE status=? ORDER BY priority, id",
            (status,),
        ).fetchall()
    return rows


def query_history(task_id: str) -> list[tuple]:
    """Return (ts, from_state, to_state, reason) ordered by id."""
    with _connect() as c:
        rows = c.execute(
            "SELECT ts, COALESCE(from_state,''), to_state, COALESCE(reason,'') "
            "FROM transitions WHERE task_id=? ORDER BY id",
            (task_id,),
        ).fetchall()
    return rows


def event_write(
    event_type: str,
    task_id: Optional[str],
    payload: dict,
) -> int:
    """Append a row to events. Returns the new event id.

    event_type ∈ {needs_decision, task_completed, task_failed, budget_exceeded}.
    """
    allowed = {"needs_decision", "task_completed", "task_failed", "budget_exceeded"}
    if event_type not in allowed:
        raise ValueError(f"event_type {event_type!r} not in {allowed}")
    with _connect() as c:
        cur = c.execute(
            "INSERT INTO events(ts, event_type, task_id, payload, delivered) "
            "VALUES(?, ?, ?, ?, 0)",
            (_now(), event_type, task_id, json.dumps(payload)),
        )
        return int(cur.lastrowid)


def event_query_pending() -> list[tuple]:
    """Return (id, ts, event_type, task_id, payload) for undelivered events."""
    with _connect() as c:
        rows = c.execute(
            "SELECT id, ts, event_type, COALESCE(task_id,''), payload "
            "FROM events WHERE delivered=0 ORDER BY id"
        ).fetchall()
    return rows


def event_mark_delivered(event_id: int) -> None:
    with _connect() as c:
        c.execute("UPDATE events SET delivered=1 WHERE id=?", (event_id,))


def session_touch(task_id: str, backend: str) -> None:
    """Refresh sessions.last_seen — used by status.json ingestion / heartbeat."""
    with _connect() as c:
        c.execute(
            "UPDATE sessions SET last_seen=? WHERE task_id=? AND backend=?",
            (_now(), task_id, backend),
        )


def gen_task_id() -> str:
    """T-<unix_ts>-<6 hex>."""
    ts = int(time.time())
    seed = f"{ts}{random.randint(0, 1_000_000)}"
    h = hashlib.sha1(seed.encode()).hexdigest()[:6]
    return f"T-{ts}-{h}"
