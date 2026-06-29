"""harness.i18n — locale catalog loader."""

from __future__ import annotations

import os
import unittest

from harness import i18n as _i18n_module
from harness.i18n import t


def _reset():
    _i18n_module._catalog = None
    _i18n_module._loaded_lang = None


class I18nTests(unittest.TestCase):
    def setUp(self) -> None:
        _reset()
        os.environ.pop("HARNESS_LANG", None)

    def tearDown(self) -> None:
        _reset()
        os.environ.pop("HARNESS_LANG", None)

    def test_default_lang_is_english(self) -> None:
        out = t("worker.resume_header")
        self.assertIn("User/Coordinator", out)
        self.assertNotIn("用户", out)

    def test_zh_locale_returns_chinese(self) -> None:
        os.environ["HARNESS_LANG"] = "zh"
        _reset()
        out = t("worker.resume_header")
        self.assertIn("用户", out)

    def test_format_kwargs_substituted(self) -> None:
        out = t("worker.gate_retry_prompt", steps="lint failed")
        self.assertIn("lint failed", out)

    def test_unknown_key_returns_key_itself(self) -> None:
        self.assertEqual(t("no.such.key"), "no.such.key")

    def test_missing_locale_falls_back_to_english(self) -> None:
        os.environ["HARNESS_LANG"] = "xx_NONEXISTENT"
        _reset()
        out = t("worker.initial_instructions")
        self.assertIn("git add", out)

    def test_all_worker_keys_present_in_en(self) -> None:
        keys = [
            "worker.gate_retry_prompt",
            "worker.initial_spec_header",
            "worker.initial_instructions",
            "worker.resume_header",
            "worker.resume_previous_question",
            "worker.resume_decision",
            "worker.resume_instructions",
        ]
        for k in keys:
            self.assertNotEqual(t(k), k, f"key {k!r} missing from en.json")

    def test_all_worker_keys_present_in_zh(self) -> None:
        os.environ["HARNESS_LANG"] = "zh"
        _reset()
        keys = [
            "worker.gate_retry_prompt",
            "worker.initial_spec_header",
            "worker.initial_instructions",
            "worker.resume_header",
            "worker.resume_previous_question",
            "worker.resume_decision",
            "worker.resume_instructions",
        ]
        for k in keys:
            self.assertNotEqual(t(k), k, f"key {k!r} missing from zh.json")


if __name__ == "__main__":
    unittest.main()
