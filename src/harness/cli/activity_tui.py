"""Scrollable history of the coordinator's activity log — `harness activity`.

Mirrors what the right-pane watch TUI's status bar shows, but full history
instead of just the most recent line. The status bar only tells you what
happened LAST; this command lets you see what happened OVER TIME.

Single zone (one full-height list pane) + a footer. Stdlib curses only.

Source: .harness/logs/coordinator-activity.log
Line format: `<YYYY-MM-DDTHH:MM:SSZ>  <text>`

Read-only. The coordinator writes via `harness-task log-action`.
"""

from __future__ import annotations

import curses
import datetime
import os
import re
import time
from pathlib import Path
from typing import Optional


def _project_dir() -> Path:
    p = os.environ.get("HARNESS_DB")
    if not p:
        return Path.cwd()
    return Path(p).parent.parent


def _activity_log_path(project: Path) -> Path:
    return project / ".harness" / "logs" / "coordinator-activity.log"


def _parse_iso(s: str) -> Optional[float]:
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        ).timestamp()
    except ValueError:
        return None


_TS_RE = re.compile(r"^(\S+)\s+(.*)$")


def _load_entries(path: Path) -> list[tuple[float, str]]:
    """Return [(epoch, text), ...] sorted newest-first. Missing file → []."""
    if not path.is_file():
        return []
    out: list[tuple[float, str]] = []
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.rstrip()
            if not line:
                continue
            m = _TS_RE.match(line)
            if not m:
                continue
            ts = _parse_iso(m.group(1))
            if ts is None:
                continue
            out.append((ts, m.group(2)))
    except OSError:
        return []
    out.sort(key=lambda r: r[0], reverse=True)
    return out


def _age_human(seconds: float) -> str:
    if seconds < 60:
        return f"{int(seconds)}s ago"
    if seconds < 3600:
        return f"{int(seconds / 60)}m ago"
    if seconds < 86400:
        return f"{int(seconds / 3600)}h ago"
    return f"{int(seconds / 86400)}d ago"


def _local_hhmm(epoch: float) -> str:
    return datetime.datetime.fromtimestamp(epoch).strftime("%H:%M")


def _addstr_clip(win, y: int, x: int, text: str, attr: int = 0) -> None:
    max_y, max_x = win.getmaxyx()
    if y < 0 or y >= max_y or x >= max_x:
        return
    text = text[: max(0, max_x - x - 1)]
    try:
        win.addstr(y, x, text, attr)
    except curses.error:
        pass


# Curses pair indices
PAIR_DIM = 1
PAIR_CYAN = 2
PAIR_YELLOW = 3
PAIR_RED = 4
PAIR_GREEN = 5


def init_colors() -> None:
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(PAIR_DIM,    8,                    -1)
    curses.init_pair(PAIR_CYAN,   curses.COLOR_CYAN,    -1)
    curses.init_pair(PAIR_YELLOW, curses.COLOR_YELLOW,  -1)
    curses.init_pair(PAIR_RED,    curses.COLOR_RED,     -1)
    curses.init_pair(PAIR_GREEN,  curses.COLOR_GREEN,   -1)


def _color_for_line(text: str) -> int:
    """Pick a color based on the prefix emoji in `text`."""
    # Coordinator prefix conventions (see coordinator.md §2.0):
    #   🤖 action  ·  📥 receipt  ·  💬 proactive  ·  ⚠ escalation  ·  🫏: reply
    if text.startswith("⚠"):
        return curses.color_pair(PAIR_RED) | curses.A_BOLD
    if text.startswith("🤖"):
        return curses.color_pair(PAIR_CYAN)
    if text.startswith("💬"):
        return curses.color_pair(PAIR_YELLOW)
    if text.startswith("📥"):
        return curses.color_pair(PAIR_DIM)
    return 0  # default (no color)


def run(stdscr) -> None:
    curses.curs_set(0)
    init_colors()
    stdscr.timeout(1000)  # 1s refresh tick

    project = _project_dir()
    log_path = _activity_log_path(project)

    sel_idx = 0
    scroll = 0
    entries: list[tuple[float, str]] = _load_entries(log_path)
    last_load = time.time()

    while True:
        now = time.time()
        # Refresh every 2s — activity log appends are rare; cheap re-read.
        if now - last_load > 2.0:
            entries = _load_entries(log_path)
            last_load = now
            sel_idx = max(0, min(sel_idx, len(entries) - 1)) if entries else 0

        H, W = stdscr.getmaxyx()
        stdscr.erase()

        if H < 6 or W < 50:
            _addstr_clip(stdscr, 0, 0, "terminal too small (need ≥50x6)",
                         curses.color_pair(PAIR_RED))
            stdscr.refresh()
            ch = stdscr.getch()
            if ch in (ord("q"), 27):
                return
            continue

        # ── header ─────────────────────────────────────
        title = f"  🫏 协调者活动日志  ·  {project.name}"
        _addstr_clip(stdscr, 0, 0, title, curses.A_BOLD)
        sub = f"({log_path})"
        _addstr_clip(stdscr, 0, W - len(sub) - 1, sub,
                     curses.color_pair(PAIR_DIM))

        # ── body: scrollable list ──────────────────────
        body_top = 2
        body_bot = H - 2  # leave 1 row hline + 1 row footer
        visible = body_bot - body_top
        if visible < 1:
            visible = 1

        if not entries:
            _addstr_clip(stdscr, body_top + 1, 4,
                         "(no activity yet — coordinator hasn't logged anything)",
                         curses.color_pair(PAIR_DIM))
        else:
            # Keep sel_idx in view
            if sel_idx < scroll:
                scroll = sel_idx
            elif sel_idx >= scroll + visible:
                scroll = sel_idx - visible + 1

            for i in range(visible):
                idx = i + scroll
                if idx >= len(entries):
                    break
                epoch, text = entries[idx]
                hhmm = _local_hhmm(epoch)
                age = _age_human(now - epoch)
                sel_mark = "▶" if idx == sel_idx else " "
                line = f" {sel_mark} {hhmm}  {text}"
                attr = _color_for_line(text)
                if idx == sel_idx:
                    attr |= curses.A_REVERSE
                _addstr_clip(stdscr, body_top + i, 0, line, attr)
                # Right-aligned age (dim) — overlays if line is long; that's OK
                age_x = max(0, W - len(age) - 2)
                if age_x > len(line) + 2:  # only if won't overlap
                    _addstr_clip(stdscr, body_top + i, age_x, age,
                                 curses.color_pair(PAIR_DIM))

        # ── footer ─────────────────────────────────────
        hline_y = H - 2
        line = "─" * (W - 1)
        try:
            stdscr.addstr(hline_y, 0, line, curses.color_pair(PAIR_DIM))
        except curses.error:
            pass

        if entries:
            oldest = _age_human(now - entries[-1][0])
            footer_left = (f"{len(entries)} entries  ·  newest "
                           f"{_age_human(now - entries[0][0])}  ·  oldest {oldest}")
        else:
            footer_left = "no entries"
        keys = "[j/k] nav  [g/G] top/bot  [r] refresh  [q] quit"
        _addstr_clip(stdscr, hline_y + 1, 0, footer_left,
                     curses.color_pair(PAIR_DIM))
        _addstr_clip(stdscr, hline_y + 1, max(0, W - len(keys) - 1), keys,
                     curses.color_pair(PAIR_DIM) | curses.A_DIM)

        stdscr.refresh()

        # ── input ──────────────────────────────────────
        try:
            ch = stdscr.getch()
        except KeyboardInterrupt:
            return
        if ch == -1:
            continue  # tick — refresh
        if ch in (ord("q"), 27):
            return
        if not entries:
            continue
        if ch in (ord("j"), curses.KEY_DOWN):
            sel_idx = min(sel_idx + 1, len(entries) - 1)
        elif ch in (ord("k"), curses.KEY_UP):
            sel_idx = max(0, sel_idx - 1)
        elif ch == curses.KEY_NPAGE:  # PgDn
            sel_idx = min(sel_idx + visible, len(entries) - 1)
        elif ch == curses.KEY_PPAGE:  # PgUp
            sel_idx = max(0, sel_idx - visible)
        elif ch == ord("g"):
            sel_idx = 0
        elif ch == ord("G"):
            sel_idx = len(entries) - 1
        elif ch == ord("r"):
            entries = _load_entries(log_path)
            last_load = time.time()
            sel_idx = 0


def main() -> int:
    project = _project_dir()
    db_path = project / ".harness" / "harness.db"
    if not db_path.is_file():
        print(f"harness not initialized in {project} — run 'harness init' first",
              flush=True)
        return 2
    os.environ.setdefault("HARNESS_DB", str(db_path))
    try:
        curses.wrapper(run)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
