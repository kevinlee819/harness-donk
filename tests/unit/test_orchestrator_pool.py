"""harness.orchestrator.Pool — worker slot bookkeeping."""

from __future__ import annotations

import unittest

from harness.orchestrator import Pool


class _StubThread:
    """Minimal stand-in for WorkerThread (Pool only needs .start/.join existence
    indirectly; for slot tests we never call those methods)."""


class PoolTests(unittest.TestCase):
    def test_initial_free_slots_named_w1_to_wN(self) -> None:
        p = Pool(3)
        slots = [p.free_slot() for _ in range(3)]
        self.assertEqual(slots, ["w1", "w2", "w3"])
        self.assertIsNone(p.free_slot())

    def test_release_returns_slot_to_pool(self) -> None:
        p = Pool(2)
        s1 = p.free_slot()
        s2 = p.free_slot()
        p.assign(s1, "T-1", _StubThread())  # type: ignore[arg-type]
        p.release(s1, "T-1")
        # released slot reappears
        self.assertEqual(p.free_slot(), s1)
        # s2 still busy from caller's perspective (not assigned/released)
        # but we just popped it earlier; pool tracks only assignments

    def test_busy_count_tracks_assignments(self) -> None:
        p = Pool(3)
        a = p.free_slot()
        b = p.free_slot()
        p.assign(a, "T-a", _StubThread())  # type: ignore[arg-type]
        p.assign(b, "T-b", _StubThread())  # type: ignore[arg-type]
        self.assertEqual(p.busy_count(), 2)
        p.release(a, "T-a")
        self.assertEqual(p.busy_count(), 1)

    def test_in_flight_task_ids(self) -> None:
        p = Pool(3)
        a = p.free_slot()
        b = p.free_slot()
        p.assign(a, "T-a", _StubThread())  # type: ignore[arg-type]
        p.assign(b, "T-b", _StubThread())  # type: ignore[arg-type]
        self.assertEqual(set(p.in_flight_task_ids()), {"T-a", "T-b"})
        p.release(b, "T-b")
        self.assertEqual(p.in_flight_task_ids(), ["T-a"])

    def test_no_double_free_on_release(self) -> None:
        p = Pool(2)
        a = p.free_slot()
        p.assign(a, "T-a", _StubThread())  # type: ignore[arg-type]
        p.release(a, "T-a")
        p.release(a, "T-a")  # second release should be a no-op on _free
        b = p.free_slot()
        c = p.free_slot()
        # only two unique slots
        self.assertEqual({a, b, c} - {None}, {"w1", "w2"})
