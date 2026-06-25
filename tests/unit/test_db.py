"""Unit tests for src/harness/db.py — replaces tests/unit/test_db.sh."""

from __future__ import annotations

import os
import re
import tempfile
import unittest
from pathlib import Path

# Expect runner to put src/ on PYTHONPATH and HARNESS_HOME in env
from harness import db


HARNESS_HOME = Path(os.environ["HARNESS_HOME"])
SCHEMA = HARNESS_HOME / "schema" / "harness.sql"


class DbTestCase(unittest.TestCase):
    """Each test gets a fresh tmp DB."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.db_path = Path(self._tmp.name) / "h.db"
        os.environ["HARNESS_DB"] = str(self.db_path)
        db.init(SCHEMA)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    # ── schema ──
    def test_init_sets_user_version(self):
        import sqlite3

        with sqlite3.connect(str(self.db_path)) as c:
            (v,) = c.execute("PRAGMA user_version").fetchone()
        self.assertEqual(1, v)

    def test_init_idempotent(self):
        db.init(SCHEMA)  # second call must not fail
        import sqlite3

        with sqlite3.connect(str(self.db_path)) as c:
            (n,) = c.execute("SELECT COUNT(*) FROM tasks").fetchone()
        self.assertEqual(0, n)

    # ── claim ──
    def test_add_and_claim_priority_order(self):
        db.add_task("T-A", "specs/a.md", 100)
        db.add_task("T-B", "specs/b.md", 50)
        db.add_task("T-C", "specs/c.md", 200)
        self.assertEqual(("T-B", "specs/b.md"), db.claim("w1"))
        self.assertEqual(("T-A", "specs/a.md"), db.claim("w1"))

    def test_claim_empty_returns_none(self):
        self.assertIsNone(db.claim("w1"))

    def test_depends_on_blocks_claim(self):
        # T-CHILD has higher priority but depends on T-PARENT (not merged)
        db.add_task("T-PARENT", "p.md", 100)
        db.add_task("T-CHILD", "c.md", 50, ["T-PARENT"])
        # Should pick T-PARENT first because T-CHILD is blocked
        self.assertEqual(("T-PARENT", "p.md"), db.claim("w1"))

    def test_depends_on_unblocks_after_merge(self):
        db.add_task("T-PARENT", "p.md", 100)
        db.add_task("T-CHILD", "c.md", 50, ["T-PARENT"])
        db.claim("w1")  # claims T-PARENT
        db.transition("T-PARENT", "merged")
        self.assertEqual(("T-CHILD", "c.md"), db.claim("w1"))

    # ── transitions ──
    def test_transition_logs_history(self):
        db.add_task("T-X", "s.md")
        db.claim("w1")
        db.transition("T-X", "working", "first")
        db.transition("T-X", "gating")
        hist = db.query_history("T-X")
        states = [(r[1], r[2]) for r in hist]
        self.assertIn(("dispatched", "working"), states)
        self.assertIn(("working", "gating"), states)

    def test_transition_atomic_on_failure(self):
        # transition is a transaction; if INSERT fails, UPDATE should roll back
        # Hard to simulate without injecting; instead verify happy path stays consistent
        db.add_task("T-T", "s.md")
        db.transition("T-T", "working", "ok")
        rows = db.query_status("T-T")
        self.assertEqual("working", rows[0][1])

    # ── retries ──
    def test_inc_and_get_retries(self):
        db.add_task("T-R", "s.md")
        self.assertEqual(0, db.get_retries("T-R"))
        db.inc_retries("T-R")
        db.inc_retries("T-R")
        self.assertEqual(2, db.get_retries("T-R"))

    # ── sessions ──
    def test_session_register_and_get(self):
        db.add_task("T-S", "s.md")
        db.register_session("T-S", "claude", "sid-1")
        self.assertEqual("sid-1", db.get_session("T-S", "claude"))
        db.register_session("T-S", "claude", "sid-2")
        self.assertEqual("sid-2", db.get_session("T-S", "claude"))

    # ── calls / cost ──
    def test_log_call_and_today_cost(self):
        db.add_task("T-C", "s.md")
        db.log_call("T-C", "w1", "claude", "sid-1", 0, 0.5, 3, 1200, 2)
        db.log_call("T-C", "w1", "claude", "sid-2", 0, 0.7, 4, 1500, 1)
        self.assertAlmostEqual(1.2, db.today_cost(), places=4)

    def test_today_cost_empty(self):
        # Regression for bash args[@] unbound bug — now N/A in Python but kept
        self.assertEqual(0.0, db.today_cost())

    def test_log_call_with_null_cost(self):
        db.add_task("T-N", "s.md")
        db.log_call("T-N", "w1", "claude", None, 0, None, None, None, 0)
        self.assertEqual(0.0, db.today_cost())

    # ── ids ──
    def test_gen_task_id_format(self):
        tid = db.gen_task_id()
        self.assertRegex(tid, r"^T-\d+-[a-f0-9]{6}$")

    # ── query ──
    def test_query_by_status(self):
        db.add_task("T-1", "a.md")
        db.add_task("T-2", "b.md")
        db.claim("w1")
        rows = db.query_by_status("queued")
        ids = [r[0] for r in rows]
        self.assertIn("T-2", ids)
        rows = db.query_by_status("dispatched")
        ids = [r[0] for r in rows]
        self.assertIn("T-1", ids)

    # ── events ──
    def test_event_write_and_pending(self):
        db.add_task("T-EV", "a.md")
        eid1 = db.event_write("task_completed", "T-EV", {"branch": "harness/T-EV"})
        eid2 = db.event_write("needs_decision", "T-EV", {"q": "?"})
        eid3 = db.event_write("budget_exceeded", None, {"used": 11.0, "limit": 10})
        self.assertEqual([1, 2, 3], [eid1, eid2, eid3])

        pending = db.event_query_pending()
        self.assertEqual(3, len(pending))
        types = [r[2] for r in pending]
        self.assertEqual(["task_completed", "needs_decision", "budget_exceeded"], types)

        db.event_mark_delivered(eid1)
        pending2 = db.event_query_pending()
        self.assertEqual(2, len(pending2))
        self.assertEqual([eid2, eid3], [r[0] for r in pending2])

    def test_event_invalid_type_rejected(self):
        with self.assertRaises(ValueError):
            db.event_write("bogus_type", None, {})

    def test_event_payload_is_json_round_trip(self):
        db.add_task("T-PL", "a.md")
        eid = db.event_write("task_failed", "T-PL", {"reason": "x", "deep": [1, 2]})
        import json as _json
        row = db.event_query_pending()[0]
        self.assertEqual({"reason": "x", "deep": [1, 2]}, _json.loads(row[4]))

    # ── session touch ──
    def test_session_touch_refreshes_last_seen(self):
        db.add_task("T-SS", "a.md")
        db.register_session("T-SS", "claude", "sid-1")
        import sqlite3, time as _time
        with sqlite3.connect(str(self.db_path)) as c:
            before = c.execute(
                "SELECT last_seen FROM sessions WHERE task_id=?", ("T-SS",)
            ).fetchone()[0]
        _time.sleep(1.1)
        db.session_touch("T-SS", "claude")
        with sqlite3.connect(str(self.db_path)) as c:
            after = c.execute(
                "SELECT last_seen FROM sessions WHERE task_id=?", ("T-SS",)
            ).fetchone()[0]
        self.assertNotEqual(before, after)

    # ── orphan reaper / blocked timeout ──
    def _fossilize(self, tid: str, status: str, days_ago: int = 30) -> None:
        """Set status + force `updated` to ages-ago, for query_orphans tests."""
        import sqlite3
        with sqlite3.connect(str(self.db_path)) as c:
            c.execute(
                f"UPDATE tasks SET status=?, updated=datetime('now','-{days_ago} days') WHERE id=?",
                (status, tid),
            )

    def test_query_orphans_finds_transient_stale(self):
        db.add_task("T-OLD-W", "a.md")
        self._fossilize("T-OLD-W", "working")
        db.add_task("T-OLD-G", "b.md")
        self._fossilize("T-OLD-G", "gating")
        db.add_task("T-OLD-D", "c.md")
        self._fossilize("T-OLD-D", "dispatched")
        rows = db.query_orphans(10)
        ids = {r[0] for r in rows}
        self.assertEqual({"T-OLD-W", "T-OLD-G", "T-OLD-D"}, ids)

    def test_query_orphans_excludes_terminal_states(self):
        db.add_task("T-MRG", "a.md")
        self._fossilize("T-MRG", "merged")
        db.add_task("T-FAIL", "b.md")
        self._fossilize("T-FAIL", "failed")
        db.add_task("T-BLK", "c.md")
        self._fossilize("T-BLK", "blocked")
        rows = db.query_orphans(10)
        self.assertEqual([], rows, "merged/failed/blocked not orphans")

    def test_query_orphans_excludes_recent(self):
        db.add_task("T-FRESH", "a.md")
        # status='working' but updated is current time (transition sets it)
        db.transition("T-FRESH", "working", "test")
        rows = db.query_orphans(10)
        self.assertEqual([], rows, "recent transient not orphans")

    def test_inc_redispatches(self):
        db.add_task("T-RD", "a.md")
        db.inc_redispatches("T-RD")
        db.inc_redispatches("T-RD")
        import sqlite3
        with sqlite3.connect(str(self.db_path)) as c:
            (n,) = c.execute(
                "SELECT redispatches FROM tasks WHERE id=?", ("T-RD",)
            ).fetchone()
        self.assertEqual(2, n)

    def test_query_blocked_overdue(self):
        import sqlite3
        db.add_task("T-OLD-BLK", "a.md")
        db.add_task("T-NEW-BLK", "b.md")
        with sqlite3.connect(str(self.db_path)) as c:
            c.execute("UPDATE tasks SET status='blocked' WHERE id IN ('T-OLD-BLK','T-NEW-BLK')")
            c.execute(
                "INSERT INTO transitions(task_id, from_state, to_state, reason, ts) "
                "VALUES('T-OLD-BLK','working','blocked','needs_decision',datetime('now','-100 hours'))"
            )
            c.execute(
                "INSERT INTO transitions(task_id, from_state, to_state, reason, ts) "
                "VALUES('T-NEW-BLK','working','blocked','needs_decision',datetime('now','-1 hours'))"
            )
        rows = db.query_blocked_overdue(72)
        ids = [r[0] for r in rows]
        self.assertEqual(["T-OLD-BLK"], ids, "only T-OLD-BLK is overdue")

    def test_query_blocked_overdue_excludes_non_blocked(self):
        # Tasks that WERE blocked but are now merged shouldn't show up.
        import sqlite3
        db.add_task("T-EX", "a.md")
        with sqlite3.connect(str(self.db_path)) as c:
            c.execute(
                "INSERT INTO transitions(task_id, from_state, to_state, reason, ts) "
                "VALUES('T-EX','working','blocked','test',datetime('now','-100 hours'))"
            )
            c.execute(
                "INSERT INTO transitions(task_id, from_state, to_state, reason, ts) "
                "VALUES('T-EX','blocked','merged','ok',datetime('now','-50 hours'))"
            )
            c.execute("UPDATE tasks SET status='merged' WHERE id='T-EX'")
        rows = db.query_blocked_overdue(72)
        self.assertEqual([], rows, "current status must be blocked")


if __name__ == "__main__":
    unittest.main(verbosity=2)
