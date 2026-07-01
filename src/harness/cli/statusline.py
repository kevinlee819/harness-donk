"""Claude Code statusline renderer.

Wired into a project's .claude/settings.json as:
    "statusLine": { "command": "harness statusline", "refreshInterval": 5 }

Claude Code calls us every refresh interval, piping a JSON blob to stdin:
    {
      "session_id": "...",
      "cwd": "...",
      "model": {"id": "claude-opus-4-7", "display_name": "Opus 4.7"},
      ...
    }

We read it, augment with harness state from .harness/harness.db (task counts,
busy workers from workers/<id>/status.json), and emit one ANSI line to stdout.
Goes silent (empty line, exit 0) on any error so a broken statusline never
crashes the user's coordinator session.

Why a separate command (not just `harness status`):
  - `harness status` is human-typed, prints multi-line table
  - statusline is machine-piped, one line, called every 5s, must be fast +
    silent on failure
"""

from __future__ import annotations

import json
import os
import sys
from collections import Counter
from pathlib import Path
from typing import Optional


# ---- ANSI helpers ----------------------------------------------------------

R = "\033[0m"
DIM = "\033[2m"
BOLD = "\033[1m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
CYAN = "\033[36m"
GREY = "\033[90m"


# ---- Data gathering --------------------------------------------------------


def _read_stdin_json() -> dict:
    """Read Claude Code's status blob. Empty/invalid → empty dict (silent)."""
    if sys.stdin.isatty():
        return {}
    try:
        data = sys.stdin.read()
        if not data.strip():
            return {}
        return json.loads(data)
    except Exception:
        return {}


def _project_dir(cc_blob: dict) -> Optional[Path]:
    """Decide which project's .harness/ to read from.

    Priority: HARNESS_PROJECT_DIR env > Claude Code's cwd > $PWD.
    Returns None if no .harness/ found upward from that root.
    """
    candidates = [
        os.environ.get("HARNESS_PROJECT_DIR"),
        cc_blob.get("cwd"),
        os.environ.get("PWD"),
    ]
    for c in candidates:
        if not c:
            continue
        p = Path(c)
        for parent in [p, *p.parents]:
            if (parent / ".harness" / "harness.db").exists():
                return parent
    return None


def _count_busy_workers(project: Path) -> tuple[int, int]:
    """Return (busy, total_seen). Reads status.json files (single-writer)."""
    wdir = project / ".harness" / "workers"
    if not wdir.is_dir():
        return 0, 0
    busy = 0
    total = 0
    for sj in wdir.glob("*/status.json"):
        total += 1
        try:
            st = json.loads(sj.read_text(encoding="utf-8"))
            if st.get("state") == "working":
                busy += 1
        except Exception:
            continue
    return busy, total


def _task_counts(db_path: Path) -> Counter:
    """status → count, including a synthetic 'merged_today' bucket."""
    import sqlite3

    out: Counter = Counter()
    try:
        with sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2.0) as c:
            for status, n in c.execute(
                "SELECT status, COUNT(*) FROM tasks GROUP BY status"
            ):
                out[status] = n
            (merged_today,) = c.execute(
                "SELECT COUNT(*) FROM transitions "
                "WHERE to_state='merged' "
                "AND strftime('%s', ts) >= strftime('%s', 'now', 'start of day')"
            ).fetchone()
            out["_merged_today"] = merged_today
    except Exception:
        pass
    return out


def _short_model(cc_blob: dict) -> str:
    m = (cc_blob.get("model") or {}).get("display_name") or (
        cc_blob.get("model") or {}
    ).get("id") or ""
    # Strip date suffixes like -20260416; keep canonical short.
    m = m.split("-2026")[0].split("-2025")[0]
    return m


# ---- Render ----------------------------------------------------------------


def render(cc_blob: dict) -> str:
    """Compose the single statusline. Always returns a non-empty string."""
    parts: list[str] = ["\U0001facf"]  # donkey 🫏 (project logo)

    project = _project_dir(cc_blob)
    if project is None:
        # Not inside a harness-init'd project — render minimal info.
        m = _short_model(cc_blob)
        if m:
            parts.append(f"{DIM}{m}{R}")
        return " ".join(parts)

    db = project / ".harness" / "harness.db"
    counts = _task_counts(db)
    busy, total = _count_busy_workers(project)
    model = _short_model(cc_blob)

    # Task counts segment: W:n Q:n B:n F:n M:n (today)
    w = counts.get("working", 0)
    q = counts.get("queued", 0)
    b = counts.get("blocked", 0)
    f = counts.get("failed", 0)
    m_today = counts.get("_merged_today", 0)
    task_seg = (
        f"{CYAN}W:{w}{R} {GREY}Q:{q}{R} "
        f"{(RED if b else GREY)}B:{b}{R} "
        f"{(RED if f else GREY)}F:{f}{R} "
        f"{GREEN}M:{m_today}{R}"
    )
    parts.append(task_seg)

    # Worker pool segment (only if any worker dir seen).
    if total > 0:
        parts.append(f"{DIM}w{busy}/{total}{R}")

    # Model tag (smallest, last).
    if model:
        parts.append(f"{DIM}{model}{R}")

    return " · ".join([parts[0] + " " + parts[1]] + parts[2:]) if len(parts) > 1 else parts[0]


def main(argv: Optional[list[str]] = None) -> int:
    try:
        cc_blob = _read_stdin_json()
        line = render(cc_blob)
        # Single trailing newline; Claude Code splits on lines.
        sys.stdout.write(line + "\n")
        return 0
    except Exception:
        # Never crash — emit empty line so Claude Code statusline stays usable.
        sys.stdout.write("\n")
        return 0


if __name__ == "__main__":
    sys.exit(main())
