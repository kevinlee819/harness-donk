"""harness.cli.statusline — Claude Code statusline renderer."""

from __future__ import annotations

import io
import json
import os
import shutil
import re
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from harness import db
from harness.cli import statusline


HARNESS_HOME = Path(os.environ["HARNESS_HOME"])
_ANSI = re.compile(r"\x1b\[[0-9;]*m")


def strip(s: str) -> str:
    return _ANSI.sub("", s)


class StatuslineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.proj = Path(tempfile.mkdtemp(prefix="harness_sl_"))
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
        os.environ.pop("HARNESS_PROJECT_DIR", None)

    def _render(self, blob: dict) -> str:
        # Force project resolution to this test's tmp dir.
        os.environ["HARNESS_PROJECT_DIR"] = str(self.proj)
        return statusline.render(blob)

    # ---- happy paths ------------------------------------------------------

    def test_renders_empty_db(self) -> None:
        out = strip(self._render({"model": {"display_name": "Opus 4.7"}}))
        self.assertIn("🫏", out)
        self.assertIn("W:0", out)
        self.assertIn("Q:0", out)
        self.assertIn("M:0", out)
        self.assertIn("Opus 4.7", out)

    def test_counts_tasks_by_status(self) -> None:
        db.add_task("T-1", priority=5, spec_path="/dev/null")
        db.transition("T-1", "working", "")
        db.add_task("T-2", priority=5, spec_path="/dev/null")  # stays queued
        db.add_task("T-3", priority=5, spec_path="/dev/null")
        db.transition("T-3", "blocked", "")

        out = strip(self._render({"model": {"display_name": "Opus 4.7"}}))
        self.assertIn("W:1", out)
        self.assertIn("Q:1", out)
        self.assertIn("B:1", out)

    def test_merged_today_counted(self) -> None:
        db.add_task("T-m", priority=5, spec_path="/dev/null")
        db.transition("T-m", "merged", "")
        out = strip(self._render({}))
        self.assertIn("M:1", out)

    def test_worker_pool_busy_count(self) -> None:
        for wid, state in [("w1", "working"), ("w2", "idle"), ("w3", "working")]:
            wd = self.proj / ".harness" / "workers" / wid
            wd.mkdir(parents=True)
            (wd / "status.json").write_text(json.dumps({"state": state}))
        out = strip(self._render({}))
        self.assertIn("w2/3", out)

    # ---- color thresholds -------------------------------------------------

    def test_blocked_count_red_when_nonzero(self) -> None:
        db.add_task("T-b", priority=5, spec_path="/dev/null")
        db.transition("T-b", "blocked", "")
        raw = self._render({})
        # B segment should carry red prefix when count > 0
        self.assertRegex(raw, r"\x1b\[31mB:1")

    # ---- robustness -------------------------------------------------------

    def test_no_harness_project_falls_back_to_model_only(self) -> None:
        # Point project resolution at a path with no .harness/
        os.environ["HARNESS_PROJECT_DIR"] = str(Path(tempfile.mkdtemp()))
        try:
            out = strip(statusline.render({"model": {"display_name": "Sonnet"}}))
            self.assertIn("🫏", out)
            self.assertIn("Sonnet", out)
            # Should NOT have task segments (no DB found)
            self.assertNotIn("W:", out)
        finally:
            shutil.rmtree(os.environ["HARNESS_PROJECT_DIR"], ignore_errors=True)

    def test_main_silent_on_malformed_stdin(self) -> None:
        # main() must never raise; emits at least a newline.
        with patch("sys.stdin", io.StringIO("not json at all")):
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = statusline.main()
            self.assertEqual(rc, 0)
            self.assertTrue(buf.getvalue().endswith("\n"))

    def test_model_date_suffix_stripped(self) -> None:
        out = strip(self._render({"model": {"id": "claude-opus-4-7-20260416"}}))
        self.assertIn("claude-opus-4-7", out)
        self.assertNotIn("20260416", out)

if __name__ == "__main__":
    unittest.main()
