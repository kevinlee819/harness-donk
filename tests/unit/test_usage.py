"""harness.usage — token × price → USD."""

from __future__ import annotations

import io
import os
import sys
import unittest
from contextlib import redirect_stdout

from harness import usage


class UsageTests(unittest.TestCase):
    # --- Claude / Anthropic schema -----------------------------------------

    def test_claude_opus_basic(self) -> None:
        # 10000 input × 5e-6 + 2000 output × 2.5e-5 = 0.05 + 0.05 = 0.10
        got = usage.tokens_to_usd(
            "claude", "claude-opus-4-7",
            input_tokens=10000, output_tokens=2000,
        )
        self.assertAlmostEqual(got, 0.10, places=6)

    def test_claude_with_cache_buckets(self) -> None:
        # Anthropic: input/cache_read/cache_write are SEPARATE buckets.
        # 10000×5e-6 + 5000×5e-7 + 1000×6.25e-6 + 2000×2.5e-5
        # = 0.05 + 0.0025 + 0.00625 + 0.05 = 0.10875
        got = usage.tokens_to_usd(
            "claude", "claude-opus-4-7",
            input_tokens=10000, output_tokens=2000,
            cache_read_tokens=5000, cache_write_tokens=1000,
        )
        self.assertAlmostEqual(got, 0.10875, places=6)

    def test_claude_sonnet(self) -> None:
        # 1M input × 3e-6 = 3.00
        got = usage.tokens_to_usd(
            "claude", "claude-sonnet-4-6",
            input_tokens=1_000_000,
        )
        self.assertAlmostEqual(got, 3.0, places=6)

    def test_claude_haiku(self) -> None:
        got = usage.tokens_to_usd(
            "claude", "claude-haiku-4-5",
            input_tokens=1_000_000, output_tokens=100_000,
        )
        # 1e6 × 1e-6 + 1e5 × 5e-6 = 1.0 + 0.5 = 1.5
        self.assertAlmostEqual(got, 1.5, places=6)

    # --- Codex / OpenAI schema ---------------------------------------------

    def test_codex_gpt5(self) -> None:
        # adapter pre-subtracts cached from input (OpenAI convention).
        # non-cached: 50000×1.25e-6 + cached: 50000×1.25e-7 + output: 20000×1e-5
        # = 0.0625 + 0.00625 + 0.2 = 0.26875
        got = usage.tokens_to_usd(
            "codex", "gpt-5-codex",
            input_tokens=50000, cache_read_tokens=50000, output_tokens=20000,
        )
        self.assertAlmostEqual(got, 0.26875, places=6)

    def test_codex_gpt41(self) -> None:
        # 100000×2e-6 + 10000×8e-6 = 0.2 + 0.08 = 0.28
        got = usage.tokens_to_usd(
            "codex", "gpt-4.1",
            input_tokens=100000, output_tokens=10000,
        )
        self.assertAlmostEqual(got, 0.28, places=6)

    # --- Resolution / fallback ---------------------------------------------

    def test_family_fallback_claude_opus_unknown_version(self) -> None:
        # claude-opus-4-99 doesn't exist → falls back to claude-opus-4-7
        got = usage.tokens_to_usd(
            "claude", "claude-opus-4-99",
            input_tokens=10000,
        )
        self.assertAlmostEqual(got, 0.05, places=6)

    def test_family_fallback_codex_gpt5_variant(self) -> None:
        # gpt-5-something → falls back to gpt-5-codex
        got = usage.tokens_to_usd(
            "codex", "gpt-5-something",
            input_tokens=1000, output_tokens=100,
        )
        # 1000×1.25e-6 + 100×1e-5 = 0.00125 + 0.001 = 0.00225
        self.assertAlmostEqual(got, 0.00225, places=6)

    def test_unknown_model_returns_none(self) -> None:
        got = usage.tokens_to_usd(
            "codex", "completely-made-up-model-xyz",
            input_tokens=100,
        )
        self.assertIsNone(got)

    def test_unknown_backend_returns_none(self) -> None:
        got = usage.tokens_to_usd(
            "fake-backend", "claude-opus-4-7",
            input_tokens=100,
        )
        self.assertIsNone(got)

    def test_empty_model_returns_none(self) -> None:
        self.assertIsNone(usage.tokens_to_usd("claude", "", input_tokens=1))

    # --- Edge cases ---------------------------------------------------------

    def test_zero_tokens_yields_zero(self) -> None:
        got = usage.tokens_to_usd("claude", "claude-opus-4-7")
        self.assertEqual(got, 0.0)

    def test_opencode_routes_to_anthropic(self) -> None:
        # opencode delegates to Anthropic models per _BACKEND_PROVIDER map.
        got = usage.tokens_to_usd(
            "opencode", "claude-sonnet-4-6",
            input_tokens=1_000_000,
        )
        self.assertAlmostEqual(got, 3.0, places=6)

    # --- CLI -----------------------------------------------------------------

    def test_cli_known_model(self) -> None:
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = usage._main(
                ["usage", "claude", "claude-opus-4-7", "input=10000", "output=2000"]
            )
        self.assertEqual(rc, 0)
        self.assertAlmostEqual(float(buf.getvalue().strip()), 0.10, places=6)

    def test_cli_unknown_model_prints_null(self) -> None:
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = usage._main(
                ["usage", "codex", "made-up-xyz", "input=100"]
            )
        self.assertEqual(rc, 0)
        self.assertEqual(buf.getvalue().strip(), "null")

    def test_cli_missing_args_returns_2(self) -> None:
        # Avoid stderr noise but still verify exit code.
        rc = usage._main(["usage"])
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main()
