"""harness.budget — daily limit / today cost / under_limit."""

from __future__ import annotations

import os
import shutil
import tempfile
import unittest
from pathlib import Path

from harness import db
from harness.budget import daily_limit, today_cost, under_limit


HARNESS_HOME = Path(os.environ["HARNESS_HOME"])


class BudgetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.proj = Path(tempfile.mkdtemp(prefix="harness_budget_"))
        (self.proj / ".harness").mkdir()
        os.environ["HARNESS_DB"] = str(self.proj / ".harness" / "harness.db")
        self.conf_dir = self.proj / ".harness" / "_conf"
        self.conf_dir.mkdir()
        os.environ["HARNESS_CONFIG_DIR"] = str(self.conf_dir)
        db.init(HARNESS_HOME / "schema" / "harness.sql")

    def tearDown(self) -> None:
        shutil.rmtree(self.proj, ignore_errors=True)
        os.environ.pop("HARNESS_DB", None)
        os.environ.pop("HARNESS_CONFIG_DIR", None)

    def _write_conf(self, limit: float) -> None:
        (self.conf_dir / "config").write_text(f"budget_daily_usd = {limit}\n")

    def test_today_zero_when_no_calls(self) -> None:
        self.assertEqual(today_cost(), 0.0)

    def test_under_limit_when_zero_cost(self) -> None:
        self._write_conf(100)
        self.assertTrue(under_limit())

    def test_over_limit_when_cost_exceeds(self) -> None:
        db.add_task("T-b1", "specs/T-b1.md")
        db.log_call("T-b1", "w1", "claude", None, 0, 5.0, 1, 1000, 1)
        self._write_conf(1)
        self.assertFalse(under_limit())

    def test_default_limit_when_no_config(self) -> None:
        # no config file → default 10
        self.assertEqual(daily_limit(), 10.0)
