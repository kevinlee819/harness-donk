"""Token → USD normalization.

Why this exists
---------------
adapter 拿到的 token 使用量字段在不同 backend 之间形状各异：

- Claude CLI 输出（API key 模式）已有 `total_cost_usd`，Anthropic 后端算的，权威；
  订阅 / OAuth max 模式下该字段缺失或 0 —— 那才需要本模块兜底。
- Codex CLI **从不**输出 USD，只给 `turn.completed.usage = {input_tokens,
  cached_input_tokens, output_tokens, reasoning_output_tokens}`，要靠本表算。

价目表来源：litellm/model_prices_and_context_window.json 的子集，挑 harness
adapter 实际能调到的模型，存在 schema/model-prices.json。

未知模型走 family fallback（opus/sonnet/haiku / gpt-5/gpt-4 / o1），fallback
都不中再返回 None —— 让调用方自己决定是 NULL 还是报错。
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Optional


_PRICES: Optional[dict] = None


def _harness_home() -> Path:
    env = os.environ.get("HARNESS_HOME")
    if env:
        return Path(env)
    # Module is at <home>/src/harness/usage.py
    return Path(__file__).resolve().parent.parent.parent


def _load() -> dict:
    global _PRICES
    if _PRICES is None:
        path = _harness_home() / "schema" / "model-prices.json"
        with open(path, encoding="utf-8") as f:
            _PRICES = json.load(f)
    return _PRICES


def _resolve_model(provider_table: dict, model: str) -> Optional[dict]:
    if model in provider_table and not model.startswith("_"):
        return provider_table[model]
    fallback = provider_table.get("_family_fallback") or {}
    for family_key, target in fallback.items():
        if family_key in model:
            return provider_table.get(target)
    return None


# Map harness backend → provider key in prices table.
_BACKEND_PROVIDER = {
    "claude": "anthropic",
    "codex": "openai",
    "opencode": "anthropic",  # opencode delegates to Anthropic models
}


def price_for(backend: str, model: str) -> Optional[dict]:
    """Return {input, output, cache_read, cache_write?} or None if unknown."""
    if not model:
        return None
    prov = _BACKEND_PROVIDER.get(backend)
    if not prov:
        return None
    table = _load().get(prov, {})
    return _resolve_model(table, model)


def tokens_to_usd(
    backend: str,
    model: str,
    *,
    input_tokens: int = 0,
    output_tokens: int = 0,
    cache_read_tokens: int = 0,
    cache_write_tokens: int = 0,
) -> Optional[float]:
    """Multiply token counts by per-token prices. Returns None if model unknown.

    Note: Anthropic's `input_tokens` field already excludes cache_read tokens
    (they are reported separately as cache_read_input_tokens). Codex's
    `input_tokens` likewise excludes `cached_input_tokens`. So callers should
    pass them as separate buckets — we do NOT subtract cache hits from input.
    """
    p = price_for(backend, model)
    if p is None:
        return None

    cost = 0.0
    cost += input_tokens * p.get("input", 0.0)
    cost += output_tokens * p.get("output", 0.0)
    cost += cache_read_tokens * p.get("cache_read", 0.0)
    cost += cache_write_tokens * p.get("cache_write", 0.0)
    return round(cost, 6)


def _parse_kv(args: list[str]) -> dict[str, int]:
    out: dict[str, int] = {}
    for a in args:
        if "=" not in a:
            continue
        k, v = a.split("=", 1)
        try:
            out[k.strip()] = int(v.strip())
        except ValueError:
            continue
    return out


def _main(argv: list[str]) -> int:
    """CLI entry: usage <backend> <model> input=N output=M [cache_read=K] [cache_write=W]

    Prints USD as a plain float, or 'null' if model unknown.
    Exit code 0 either way (callers decide how to handle null).
    """
    if len(argv) < 3:
        print(
            "usage: python -m harness.usage <backend> <model> "
            "input=N output=M [cache_read=K] [cache_write=W]",
            file=__import__("sys").stderr,
        )
        return 2

    backend, model = argv[1], argv[2]
    kv = _parse_kv(argv[3:])

    usd = tokens_to_usd(
        backend,
        model,
        input_tokens=kv.get("input", 0),
        output_tokens=kv.get("output", 0),
        cache_read_tokens=kv.get("cache_read", 0),
        cache_write_tokens=kv.get("cache_write", 0),
    )
    if usd is None:
        print("null")
    else:
        print(f"{usd:.6f}")
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(_main(sys.argv))
