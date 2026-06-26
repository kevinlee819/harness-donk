"""harness.notify — events table + JSON file + hooks/notification.sh."""

from __future__ import annotations

import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

from harness import db
from harness.notify import notify


HARNESS_HOME = Path(os.environ["HARNESS_HOME"])


class NotifyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.proj = Path(tempfile.mkdtemp(prefix="harness_notify_"))
        (self.proj / ".harness").mkdir()
        os.environ["HARNESS_DB"] = str(self.proj / ".harness" / "harness.db")
        db.init(HARNESS_HOME / "schema" / "harness.sql")
        # add a task so we can reference its id
        db.add_task("T-ev1", "specs/T-ev1.md")

    def tearDown(self) -> None:
        shutil.rmtree(self.proj, ignore_errors=True)
        os.environ.pop("HARNESS_DB", None)

    def test_task_completed_writes_event_and_file(self) -> None:
        eid = notify("task_completed", "T-ev1", {"branch": "harness/T-ev1"})
        self.assertEqual(eid, 1)
        pending = db.event_query_pending()
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0][2], "task_completed")
        files = list((self.proj / ".harness" / "events").glob("*task_completed*T-ev1*.json"))
        self.assertEqual(len(files), 1)
        data = json.loads(files[0].read_text())
        self.assertEqual(data["task_id"], "T-ev1")
        self.assertEqual(data["payload"]["branch"], "harness/T-ev1")

    def test_invalid_event_type_rejected(self) -> None:
        with self.assertRaises(ValueError):
            notify("bogus_type", "-", {})

    def test_dash_task_id_writes_none_filename(self) -> None:
        notify("budget_exceeded", "-", {"cost_usd": 1, "limit_usd": 0.5, "date": "2026-06-26"})
        files = list((self.proj / ".harness" / "events").glob("*budget_exceeded-none*.json"))
        self.assertEqual(len(files), 1)

    def test_event_ack_removes_from_pending(self) -> None:
        eid = notify("task_completed", "T-ev1", {})
        db.event_mark_delivered(eid)
        self.assertEqual(db.event_query_pending(), [])
