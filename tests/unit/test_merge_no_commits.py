"""harness.merge.do_merge — refuse ghost merges.

Regression test for the "T-003~T-006 marked merged with no code" bug. The
worker would post a MergeRequest after gate passed, but if the agent never
committed anything to its branch, `git merge --no-ff` returned 0 with no
merge commit, leaving the task in `merged` state with no actual changes
on main.

These tests use a real git repo (cheap) instead of mocking subprocess —
the bug was in how do_merge interpreted git's exit code, so mocking git
would defeat the point of the test.
"""

from __future__ import annotations

import os
import queue
import subprocess
import tempfile
import unittest
from pathlib import Path

from harness import db, merge as merge_mod
from harness.merge import MergeRequest

HARNESS_HOME = Path(os.environ["HARNESS_HOME"])
SCHEMA = HARNESS_HOME / "schema" / "harness.sql"


def _git(*args: str, cwd: Path) -> str:
    r = subprocess.run(
        ["git", "-C", str(cwd), *args],
        capture_output=True, text=True, check=True,
    )
    return r.stdout


class DoMergeNoCommitsTests(unittest.TestCase):
    """do_merge must refuse to merge a branch with zero commits ahead of main."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.proj = Path(self._tmp.name) / "proj"
        self.proj.mkdir()
        _git("init", "-q", "-b", "main", cwd=self.proj)
        _git("config", "user.email", "t@t", cwd=self.proj)
        _git("config", "user.name", "t", cwd=self.proj)
        _git("config", "commit.gpgsign", "false", cwd=self.proj)
        (self.proj / "README.md").write_text("seed\n")
        _git("add", ".", cwd=self.proj)
        _git("commit", "-q", "-m", "init", cwd=self.proj)

        # harness DB
        (self.proj / ".harness").mkdir()
        os.environ["HARNESS_DB"] = str(self.proj / ".harness" / "harness.db")
        db.init(SCHEMA)
        (self.proj / ".harness" / "workers" / "w1").mkdir(parents=True)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _make_empty_branch(self, branch: str) -> Path:
        """Create a branch + worktree that is identical to main (no new commits)."""
        worktree = Path(self._tmp.name) / "wt"
        _git("worktree", "add", "-B", branch, str(worktree), cwd=self.proj)
        return worktree

    def test_refuses_branch_with_no_commits(self) -> None:
        db.add_task("T-GHOST", "specs/g.md")
        db.transition("T-GHOST", "gating", "gate_pass")
        wt = self._make_empty_branch("harness/T-GHOST")
        req = MergeRequest(
            task_id="T-GHOST",
            worker_id="w1",
            branch="harness/T-GHOST",
            worktree=wt,
            session_id="sid-1",
        )
        ok = merge_mod.do_merge(req, self.proj, "claude", HARNESS_HOME)
        self.assertFalse(ok, "must return False on empty branch")

        # Task transitioned to failed/no_commits
        rows = db.query_status("T-GHOST")
        self.assertEqual("failed", rows[0][1])
        hist = db.query_history("T-GHOST")
        last = hist[-1]
        self.assertEqual(("gating", "failed", "no_commits"), (last[1], last[2], last[3]))

        # main HEAD is unchanged — no merge commit produced
        head = _git("rev-list", "--count", "main", cwd=self.proj).strip()
        self.assertEqual("1", head, "main should still be the seed commit only")

        # task_failed event was fired with no_commits reason
        events = db.event_query_pending()
        self.assertTrue(events, "expected a pending task_failed event")
        # find ours
        ours = [e for e in events if e[3] == "T-GHOST"]
        self.assertTrue(ours, "no event for T-GHOST")
        import json as _json
        payload = _json.loads(ours[-1][4])
        self.assertEqual("no_commits", payload["reason"])

        # Branch + worktree are preserved (don't destroy evidence)
        branches = _git("branch", "--list", "harness/T-GHOST", cwd=self.proj).strip()
        self.assertIn("harness/T-GHOST", branches)
        self.assertTrue(wt.exists(), "worktree kept for debugging")

    def test_merges_branch_with_real_commits(self) -> None:
        """Sanity: do_merge still works when there ARE commits to merge."""
        db.add_task("T-REAL", "specs/r.md")
        db.transition("T-REAL", "gating", "gate_pass")
        wt = self._make_empty_branch("harness/T-REAL")
        # add a real commit in the worktree
        (wt / "hello.txt").write_text("hi\n")
        _git("add", "hello.txt", cwd=wt)
        _git("-c", "commit.gpgsign=false", "commit", "-q", "-m", "real work", cwd=wt)

        req = MergeRequest(
            task_id="T-REAL",
            worker_id="w1",
            branch="harness/T-REAL",
            worktree=wt,
            session_id="sid-2",
        )
        ok = merge_mod.do_merge(req, self.proj, "claude", HARNESS_HOME)
        self.assertTrue(ok, "must succeed on a branch with commits")
        self.assertEqual("merged", db.query_status("T-REAL")[0][1])
        # main advanced (merge commit + the work commit)
        count = int(_git("rev-list", "--count", "main", cwd=self.proj).strip())
        self.assertGreaterEqual(count, 2)
