"""harness.merge.drain_queue — pops MergeRequests serially from a Queue.

We don't exercise real git here (that's covered by integration tests). Instead
we verify the queue draining contract: requests come off in FIFO order and
exceptions in one merge don't poison subsequent ones.
"""

from __future__ import annotations

import queue
import unittest
from pathlib import Path
from unittest import mock

from harness import merge as merge_mod
from harness.merge import MergeRequest, drain_queue


class DrainQueueTests(unittest.TestCase):
    def _req(self, tid: str) -> MergeRequest:
        return MergeRequest(
            task_id=tid,
            worker_id="w1",
            branch=f"harness/{tid}",
            worktree=Path(f"/tmp/wt-{tid}"),
            session_id="sid-1",
        )

    def test_drain_processes_in_fifo_order(self) -> None:
        q: "queue.Queue[MergeRequest]" = queue.Queue()
        q.put(self._req("T-1"))
        q.put(self._req("T-2"))
        q.put(self._req("T-3"))

        order = []
        def fake_merge(req, pd, be, hh):
            order.append(req.task_id)
            return True

        with mock.patch.object(merge_mod, "do_merge", side_effect=fake_merge):
            n = drain_queue(q, Path("/tmp/proj"), "claude", Path("/tmp/home"))

        self.assertEqual(n, 3)
        self.assertEqual(order, ["T-1", "T-2", "T-3"])

    def test_drain_continues_when_one_merge_crashes(self) -> None:
        q: "queue.Queue[MergeRequest]" = queue.Queue()
        q.put(self._req("T-good1"))
        q.put(self._req("T-crash"))
        q.put(self._req("T-good2"))

        attempted = []
        def fake_merge(req, pd, be, hh):
            attempted.append(req.task_id)
            if req.task_id == "T-crash":
                raise RuntimeError("merge boom")
            return True

        with mock.patch.object(merge_mod, "do_merge", side_effect=fake_merge):
            n = drain_queue(q, Path("/tmp/proj"), "claude", Path("/tmp/home"))

        self.assertEqual(n, 3)
        self.assertEqual(attempted, ["T-good1", "T-crash", "T-good2"])

    def test_drain_empty_queue_is_noop(self) -> None:
        q: "queue.Queue[MergeRequest]" = queue.Queue()
        n = drain_queue(q, Path("/tmp/proj"), "claude", Path("/tmp/home"))
        self.assertEqual(n, 0)
