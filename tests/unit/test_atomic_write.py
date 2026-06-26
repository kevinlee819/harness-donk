"""harness.atomic_write — JSON / text atomic file write."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from harness.atomic_write import write_json, write_text


class AtomicWriteTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="harness_atomic_"))

    def tearDown(self) -> None:
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_writes_valid_json(self) -> None:
        p = self.tmp / "a.json"
        write_json(p, {"k": 1})
        self.assertEqual(json.loads(p.read_text())["k"], 1)

    def test_no_tmp_leftover_on_success(self) -> None:
        p = self.tmp / "c.json"
        write_json(p, {"x": 2})
        leftovers = list(self.tmp.glob("c.json.tmp.*"))
        self.assertEqual(leftovers, [])

    def test_overwrites_existing(self) -> None:
        p = self.tmp / "d.json"
        write_json(p, {"v": 1})
        write_json(p, {"v": 2})
        self.assertEqual(json.loads(p.read_text())["v"], 2)

    def test_creates_parent_dir(self) -> None:
        p = self.tmp / "nested" / "deep" / "e.json"
        write_json(p, {"ok": True})
        self.assertTrue(p.is_file())

    def test_write_text_no_json_check(self) -> None:
        p = self.tmp / "f.txt"
        write_text(p, "not json: {")
        self.assertEqual(p.read_text(), "not json: {")
