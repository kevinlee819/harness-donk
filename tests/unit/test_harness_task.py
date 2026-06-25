"""Unit tests for harness-task CLI — replaces tests/unit/test_harness_task.sh."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


HARNESS_HOME = Path(os.environ["HARNESS_HOME"])
SRC = HARNESS_HOME / "src"


_PYTHON = os.environ.get("HARNESS_PYTHON") or "python3"


def _run(args: list[str], cwd: Path, stdin: str = "") -> subprocess.CompletedProcess:
    """Invoke harness-task via `$HARNESS_PYTHON -m harness.cli.harness_task`."""
    env = os.environ.copy()
    env["PYTHONPATH"] = str(SRC)
    env.pop("HARNESS_DB", None)  # let CLI resolve from cwd
    return subprocess.run(
        [_PYTHON, "-m", "harness.cli.harness_task", *args],
        cwd=cwd,
        env=env,
        input=stdin,
        text=True,
        capture_output=True,
    )


class HarnessTaskTestCase(unittest.TestCase):

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.proj = Path(self._tmp.name) / "proj"
        self.proj.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=self.proj, check=True)
        subprocess.run(["git", "config", "user.email", "t@t"], cwd=self.proj, check=True)
        subprocess.run(["git", "config", "user.name", "t"], cwd=self.proj, check=True)
        subprocess.run(["git", "config", "commit.gpgsign", "false"], cwd=self.proj, check=True)
        (self.proj / "README.md").write_text("# proj")
        subprocess.run(["git", "add", "."], cwd=self.proj, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=self.proj, check=True)
        # harness init (bash, will call db_cli underneath later — for now sources db.sh path is gone,
        # so we just create the .harness dir + initialize via Python directly)
        env = os.environ.copy()
        env["HARNESS_HOME"] = str(HARNESS_HOME)
        subprocess.run(
            [str(HARNESS_HOME / "bin" / "harness"), "init"],
            cwd=self.proj,
            env=env,
            check=True,
            capture_output=True,
        )

    def tearDown(self) -> None:
        self._tmp.cleanup()

    # ── add ──
    def test_add_from_stdin_creates_spec(self):
        r = _run(["add", "--id", "T-stdin"], cwd=self.proj, stdin="task body here")
        self.assertEqual(0, r.returncode, msg=r.stderr)
        out = json.loads(r.stdout)
        self.assertTrue(out["ok"])
        self.assertEqual("T-stdin", out["task_id"])
        spec = self.proj / "specs" / "T-stdin.md"
        self.assertTrue(spec.exists())
        self.assertIn("task body here", spec.read_text())

    def test_add_with_existing_spec(self):
        (self.proj / "specs").mkdir(exist_ok=True)
        (self.proj / "specs" / "T-ext.md").write_text("preexisting")
        r = _run(["add", "--id", "T-ext", "--spec", "specs/T-ext.md"], cwd=self.proj)
        self.assertEqual(0, r.returncode, msg=r.stderr)
        self.assertTrue(json.loads(r.stdout)["ok"])

    def test_add_missing_spec_path_fails(self):
        r = _run(
            ["add", "--id", "T-miss", "--spec", "specs/nonexistent.md"], cwd=self.proj
        )
        self.assertNotEqual(0, r.returncode)

    def test_add_without_id_generates_one(self):
        r = _run(["add"], cwd=self.proj, stdin="auto id")
        self.assertEqual(0, r.returncode, msg=r.stderr)
        tid = json.loads(r.stdout)["task_id"]
        self.assertRegex(tid, r"^T-\d+-[a-f0-9]{6}$")

    def test_add_with_depends_on(self):
        _run(["add", "--id", "T-parent"], cwd=self.proj, stdin="parent")
        r = _run(
            ["add", "--id", "T-child", "--depends-on", "T-parent"],
            cwd=self.proj,
            stdin="child",
        )
        self.assertEqual(0, r.returncode, msg=r.stderr)
        self.assertTrue(json.loads(r.stdout)["ok"])

    # ── query ──
    def test_query_by_status(self):
        _run(["add", "--id", "T-q1"], cwd=self.proj, stdin="a")
        _run(["add", "--id", "T-q2"], cwd=self.proj, stdin="b")
        r = _run(["query", "--status", "queued"], cwd=self.proj)
        self.assertEqual(0, r.returncode)
        self.assertIn("T-q1", r.stdout)
        self.assertIn("T-q2", r.stdout)

    def test_query_by_task_id(self):
        _run(["add", "--id", "T-only"], cwd=self.proj, stdin="x")
        r = _run(["query", "--task", "T-only"], cwd=self.proj)
        self.assertIn("T-only", r.stdout)
        self.assertIn("queued", r.stdout)

    # ── cancel ──
    def test_cancel_marks_failed(self):
        _run(["add", "--id", "T-can"], cwd=self.proj, stdin="x")
        _run(["cancel", "T-can"], cwd=self.proj)
        r = _run(["query", "--task", "T-can"], cwd=self.proj)
        self.assertIn("failed", r.stdout)

    # ── answer ──
    def test_answer_writes_inbox(self):
        r = _run(["answer", "T-q", "use option A"], cwd=self.proj)
        self.assertEqual(0, r.returncode, msg=r.stderr)
        inbox = self.proj / ".harness" / "inbox" / "T-q.answer"
        self.assertTrue(inbox.exists())
        payload = json.loads(inbox.read_text())
        self.assertEqual("use option A", payload["answer"])
        self.assertEqual("coordinator", payload["decided_by"])

    # ── history ──
    def test_history_subcommand(self):
        _run(["add", "--id", "T-h"], cwd=self.proj, stdin="x")
        _run(["cancel", "T-h"], cwd=self.proj)
        r = _run(["history", "T-h"], cwd=self.proj)
        self.assertIn("failed", r.stdout)
        self.assertIn("user_cancelled", r.stdout)

    # ── uninitialized ──
    def test_uninitialized_fails(self):
        d = tempfile.mkdtemp()
        try:
            r = _run(["query"], cwd=Path(d))
            self.assertNotEqual(0, r.returncode)
        finally:
            shutil.rmtree(d)


if __name__ == "__main__":
    unittest.main(verbosity=2)
