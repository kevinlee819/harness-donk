"""Interactive curses TUI — `harness watch`.

Replaces the static `harness watch-panel` snapshot. Three zones:
  ① task list  (top ~60%)     — live, j/k nav, ▶ cursor
  ② detail     (middle ~35%)  — selected task's worker status + transitions
  ③ status bar (bottom 1 row) — last coordinator action + counters + cost

Refresh every 1s; input poll non-blocking. Reads only — actions (retry/cancel)
shell out to `harness-task` so the source of truth stays in the DB.

Stdlib-only (curses). No textual / rich.
"""

from __future__ import annotations

import curses
import datetime
import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Optional

from harness import db


# ── data loaders ──────────────────────────────────────────────────

def _project_dir() -> Path:
    p = os.environ.get("HARNESS_DB")
    if not p:
        return Path.cwd()
    return Path(p).parent.parent


def _read_status_json(project: Path, worker_id: str) -> dict:
    if not worker_id:
        return {}
    f = project / ".harness" / "workers" / worker_id / "status.json"
    if not f.is_file():
        return {}
    try:
        return json.loads(f.read_text())
    except (json.JSONDecodeError, OSError):
        return {}


def _read_worker_activity(project: Path, worker_id: str,
                          limit: int = 8) -> tuple[list[str], Optional[float]]:
    """Return (last N human-readable activity lines, file_mtime_epoch).

    Tries both known event files:
      - `.harness/workers/<wid>/codex.events.jsonl`  (adapters/codex.sh)
      - `.harness/workers/<wid>/claude.events.jsonl` (adapters/claude.sh stream mode)

    Whichever exists is parsed with the matching renderer. Returns ([], None)
    when neither file exists (no worker yet, brand-new task, dry-run tests).

    Defensive against partial writes (last line may be truncated): tolerated by
    json.loads + try/except per line.
    """
    if not worker_id:
        return [], None
    wdir = project / ".harness" / "workers" / worker_id
    candidates = [
        (wdir / "codex.events.jsonl",  _render_codex_event),
        (wdir / "claude.events.jsonl", _render_claude_event),
    ]
    for f, renderer in candidates:
        if not f.is_file():
            continue
        try:
            mtime = f.stat().st_mtime
            # Read at most the last ~32KB. Codex JSONL lines are ≤2KB each in
            # practice, so this gives us > 16 events of context.
            size = f.stat().st_size
            with open(f, "rb") as fh:
                fh.seek(max(0, size - 32_768))
                raw = fh.read().decode("utf-8", errors="replace")
        except OSError:
            continue
        # Discard the first (possibly partial) line if we did the tail seek
        lines = raw.splitlines()
        if size > 32_768 and lines:
            lines = lines[1:]
        out: list[str] = []
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            for rendered in renderer(ev):
                out.append(rendered)
        return out[-limit:], mtime
    return [], None


def _render_codex_event(ev: dict) -> list[str]:
    """Map a codex JSONL event to human-readable lines. Returns [] to skip.

    Event taxonomy (codex 0.142+):
      thread.started        — session bookkeeping; skipped (no signal for user)
      turn.started/completed — turn-level boundary
      item.started/completed — finer-grained items within a turn:
        item.type = agent_message      → user-visible model text
        item.type = reasoning          → model's hidden thinking
        item.type = exec_command_call  → shell command
        item.type = file_change_call   → write/edit a file
    Unknown event types are silently dropped.
    """
    t = ev.get("type", "")
    item = ev.get("item") or {}
    it = item.get("type", "")
    if t == "turn.started":
        return ["▸ turn started"]
    if t == "turn.completed":
        usage = ev.get("usage") or {}
        in_tok = usage.get("input_tokens", 0)
        out_tok = usage.get("output_tokens", 0)
        return [f"✓ turn done  ({in_tok} in, {out_tok} out tok)"]
    if t in ("item.started", "item.completed"):
        if it == "agent_message":
            txt = (item.get("text") or "").strip()
            return [f"💬 {txt[:80]}"] if txt else []
        if it == "reasoning":
            txt = (item.get("text") or "").strip()
            return [f"💭 {txt[:80]}"] if txt else []
        if it in ("exec_command_call", "shell_call", "command"):
            cmd = (item.get("command") or item.get("cmd")
                   or item.get("args") or "?")
            if isinstance(cmd, list):
                cmd = " ".join(str(x) for x in cmd)
            return [f"$ {str(cmd)[:80]}"]
        if it in ("file_change_call", "edit", "write"):
            path = item.get("path") or item.get("file") or "?"
            return [f"✏️  {path}"]
    return []


def _render_claude_event(ev: dict) -> list[str]:
    """Map a claude-code stream-json event to human-readable lines.

    Event taxonomy (Claude Code v2 `--output-format stream-json --verbose`):
      type=system, subtype=init            session start — skipped
      type=rate_limit_event                skipped
      type=assistant, message.content=[…]  model output: iterate content array
        content[i].type=text                   → 💬 <text>
        content[i].type=tool_use, name=X       → prefix by tool:
                                                   Bash → $, Read → 📖,
                                                   Edit/Write → ✏️, others → 🔧
        content[i].type=thinking               → 💭 <text>  (extended thinking)
      type=user, message.content=[tool_result] echo — skipped
      type=result                          final summary — skipped (we already have
                                              turns/usage from the DB)
    """
    t = ev.get("type", "")
    if t == "assistant":
        msg = ev.get("message") or {}
        lines: list[str] = []
        for c in msg.get("content") or []:
            ct = c.get("type", "")
            if ct == "text":
                txt = (c.get("text") or "").strip()
                if txt:
                    lines.append(f"💬 {txt[:80]}")
            elif ct == "thinking":
                txt = (c.get("thinking") or c.get("text") or "").strip()
                if txt:
                    lines.append(f"💭 {txt[:80]}")
            elif ct == "tool_use":
                name = c.get("name") or "?"
                inp = c.get("input") or {}
                if name == "Bash":
                    cmd = str(inp.get("command", "?"))
                    lines.append(f"$ {cmd[:80]}")
                elif name in ("Edit", "Write", "NotebookEdit"):
                    path = inp.get("file_path") or inp.get("path") or "?"
                    lines.append(f"✏️  {path}")
                elif name == "Read":
                    path = inp.get("file_path") or inp.get("path") or "?"
                    lines.append(f"📖 {path}")
                elif name in ("Grep", "Glob"):
                    pat = inp.get("pattern") or inp.get("path") or "?"
                    lines.append(f"🔍 {name}: {str(pat)[:70]}")
                elif name == "TodoWrite":
                    lines.append("📝 TodoWrite")
                else:
                    lines.append(f"🔧 {name}")
        return lines
    return []


def _spec_title(project: Path, task_id: str) -> str:
    """First `# heading` from specs/<id>.md, skipping YAML frontmatter. Falls back to id."""
    spec = project / "specs" / f"{task_id}.md"
    if not spec.is_file():
        return task_id
    try:
        lines = spec.read_text().splitlines()
    except OSError:
        return task_id
    in_fm = False
    for i, line in enumerate(lines):
        s = line.strip()
        if i == 0 and s == "---":
            in_fm = True
            continue
        if in_fm and s == "---":
            in_fm = False
            continue
        if in_fm:
            continue
        if s.startswith("# "):
            return s[2:].strip()
    return task_id


def _parse_iso(s: str) -> Optional[float]:
    if not s:
        return None
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        ).timestamp()
    except ValueError:
        return None


def _last_coordinator_action(project: Path) -> Optional[tuple[str, float]]:
    """Most recent line of coordinator-activity.log → (text, age_seconds)."""
    f = project / ".harness" / "logs" / "coordinator-activity.log"
    if not f.is_file():
        return None
    try:
        # Read last 4KB to find the last line cheaply
        size = f.stat().st_size
        with open(f, "rb") as fh:
            fh.seek(max(0, size - 4096))
            tail = fh.read().decode("utf-8", errors="replace")
    except OSError:
        return None
    lines = [ln for ln in tail.splitlines() if ln.strip()]
    if not lines:
        return None
    last = lines[-1]
    # Format: "YYYY-MM-DDTHH:MM:SSZ  <text>"
    m = re.match(r"^(\S+)\s+(.*)$", last)
    if not m:
        return None
    ts = _parse_iso(m.group(1))
    if ts is None:
        return None
    return (m.group(2), max(0, time.time() - ts))


def _age_human(seconds: float) -> str:
    if seconds < 60:
        return f"{int(seconds)}s"
    if seconds < 3600:
        return f"{int(seconds / 60)}m"
    if seconds < 86400:
        return f"{int(seconds / 3600)}h"
    return f"{int(seconds / 86400)}d"


# ── rendering ─────────────────────────────────────────────────────

STATE_GLYPH = {
    "working":    ("⚙", "CYAN"),
    "gating":     ("🔍", "YELLOW"),
    "queued":     ("○", "GREY"),
    "dispatched": ("▶", "YELLOW"),
    "blocked":    ("⏸", "MAGENTA"),
    "merged":     ("✓", "GREEN"),
    "failed":     ("✗", "RED"),
}

# Curses color-pair indices we register in init_colors()
PAIRS = {
    "CYAN": 1, "YELLOW": 2, "GREY": 3,
    "MAGENTA": 4, "GREEN": 5, "RED": 6,
    "DIM": 7, "BOLD_GREEN": 8, "BOLD_RED": 9, "REVERSED": 10,
}


def init_colors() -> None:
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(PAIRS["CYAN"],       curses.COLOR_CYAN,    -1)
    curses.init_pair(PAIRS["YELLOW"],     curses.COLOR_YELLOW,  -1)
    curses.init_pair(PAIRS["GREY"],       8,                    -1)  # bright black
    curses.init_pair(PAIRS["MAGENTA"],    curses.COLOR_MAGENTA, -1)
    curses.init_pair(PAIRS["GREEN"],      curses.COLOR_GREEN,   -1)
    curses.init_pair(PAIRS["RED"],        curses.COLOR_RED,     -1)
    curses.init_pair(PAIRS["DIM"],        8,                    -1)
    curses.init_pair(PAIRS["BOLD_GREEN"], curses.COLOR_GREEN,   -1)
    curses.init_pair(PAIRS["BOLD_RED"],   curses.COLOR_RED,     -1)
    curses.init_pair(PAIRS["REVERSED"],   -1,                   -1)


def _addstr_clip(win, y: int, x: int, text: str, attr: int = 0) -> None:
    """Safe addstr that clips to window width and ignores curses overflow."""
    max_y, max_x = win.getmaxyx()
    if y < 0 or y >= max_y or x >= max_x:
        return
    text = text[: max(0, max_x - x - 1)]
    try:
        win.addstr(y, x, text, attr)
    except curses.error:
        pass


def _hline(win, y: int, label: str = "") -> None:
    max_y, max_x = win.getmaxyx()
    if y < 0 or y >= max_y:
        return
    line = "─" * (max_x - 1)
    if label:
        # "─ label ─────────"
        prefix = f"─ {label} "
        line = prefix + "─" * max(0, max_x - 1 - len(prefix))
    try:
        win.addstr(y, 0, line[: max_x - 1], curses.color_pair(PAIRS["DIM"]))
    except curses.error:
        pass


# ── main loop ─────────────────────────────────────────────────────

def run(stdscr) -> None:
    curses.curs_set(0)
    init_colors()
    stdscr.nodelay(False)
    stdscr.timeout(1000)  # 1s implicit refresh tick via getch timeout

    project = _project_dir()

    sel_idx = 0
    pinned_task: Optional[str] = None
    last_action_text = ""
    last_action_age = -1.0
    flash_msg = ""           # short status flash (e.g. "retried T-001")
    flash_until = 0.0
    cached_tasks: list[tuple] = []
    cached_at = 0.0

    def refresh_data():
        nonlocal cached_tasks, cached_at
        nonlocal last_action_text, last_action_age
        try:
            cached_tasks = db.query_status()
        except Exception:
            cached_tasks = []
        act = _last_coordinator_action(project)
        if act:
            last_action_text, last_action_age = act
        else:
            last_action_text, last_action_age = "", -1.0
        cached_at = time.time()

    refresh_data()

    while True:
        # ── refresh data every 1s ────────────────────────────
        if time.time() - cached_at >= 1.0:
            refresh_data()

        # Clamp selection to current task count
        if cached_tasks:
            sel_idx = max(0, min(sel_idx, len(cached_tasks) - 1))
        else:
            sel_idx = 0

        # ── layout: task list (top) + detail (middle) + status bar (bottom) ──
        stdscr.erase()
        H, W = stdscr.getmaxyx()
        if H < 8 or W < 60:
            _addstr_clip(stdscr, 0, 0, "terminal too small (need ≥60x8)",
                         curses.color_pair(PAIRS["RED"]))
            stdscr.refresh()
            ch = stdscr.getch()
            if ch in (ord("q"), 27):
                return
            continue

        # Header row: project name
        header = f"  🫏  {project.name}"
        _addstr_clip(stdscr, 0, 0, header, curses.A_BOLD)

        # ── zone ② tasks ──────────────────────────────────
        list_top = 2
        # Reserve space: 2 rows for header (incl divider) + N rows for detail + 1 status
        detail_h = max(8, H // 3)
        status_y = H - 2
        list_bottom = H - detail_h - 2

        _hline(stdscr, 1, f"TASKS ({len(cached_tasks)})")

        if not cached_tasks:
            _addstr_clip(stdscr, list_top + 1, 4,
                         "no tasks yet — talk to 🫏 协调者 to create one",
                         curses.color_pair(PAIRS["DIM"]))
        else:
            visible = list_bottom - list_top
            # Scroll to keep sel_idx in view
            scroll = 0
            if sel_idx >= visible:
                scroll = sel_idx - visible + 1
            for i in range(visible):
                idx = i + scroll
                if idx >= len(cached_tasks):
                    break
                row = cached_tasks[idx]
                tid, status, wid, branch, retries, _reds, _prio, _created = row
                glyph, color = STATE_GLYPH.get(status, ("?", "GREY"))
                title = _spec_title(project, tid)
                # Build the line
                sel_mark = "▶" if idx == sel_idx else " "
                pin_mark = "📌" if pinned_task == tid else "  "
                retry_tag = f" ↻{retries}" if retries else ""
                wid_short = (wid or "--")[:4]
                # Compact format: ▶ ●  T-001  w1  working    Title here
                line = (f" {sel_mark} {glyph}  {tid:<14} {wid_short:<4} "
                        f"{status:<10} {pin_mark}{title}{retry_tag}")
                attr = curses.color_pair(PAIRS[color])
                if idx == sel_idx:
                    attr |= curses.A_BOLD | curses.A_REVERSE
                _addstr_clip(stdscr, list_top + i, 0, line, attr)

        # ── zone ③ detail ──────────────────────────────────
        _hline(stdscr, list_bottom, "DETAIL")
        detail_y = list_bottom + 1

        # Decide which task to detail: pinned > selected
        focus_tid = pinned_task
        if focus_tid is None and cached_tasks:
            focus_tid = cached_tasks[sel_idx][0]
        if focus_tid:
            _render_detail(stdscr, detail_y, status_y - 1, focus_tid, project,
                           cached_tasks)
        else:
            _addstr_clip(stdscr, detail_y, 2, "(no task selected)",
                         curses.color_pair(PAIRS["DIM"]))

        # ── status bar (2 rows: keys hint divider + main) ────
        _hline(stdscr, status_y, "j/k nav · Enter pin · r retry · c cancel · ? help · q quit")
        counts = _count_states(cached_tasks)
        cnt_str = (f"●{counts.get('working', 0)} "
                   f"○{counts.get('queued', 0)} "
                   f"✓{counts.get('merged', 0)} "
                   f"✗{counts.get('failed', 0)}")
        if time.time() < flash_until and flash_msg:
            left = flash_msg
            left_attr = curses.color_pair(PAIRS["BOLD_GREEN"]) | curses.A_BOLD
        elif last_action_text and last_action_age >= 0:
            left = f"🤖 {last_action_text}  ·  {_age_human(last_action_age)} ago"
            left_attr = curses.color_pair(PAIRS["DIM"])
        else:
            left = "🤖 (no coordinator activity yet)"
            left_attr = curses.color_pair(PAIRS["DIM"])
        right = cnt_str
        # Reserve room for `right` on the far right; truncate `left` so it
        # can't overlap. Give `left` whatever is left, minus a 2-col gutter.
        left_room = max(10, W - len(right) - 3)
        left_trunc = left[:left_room]
        _addstr_clip(stdscr, status_y + 1, 0, left_trunc, left_attr)
        right_x = max(0, W - len(right) - 1)
        _addstr_clip(stdscr, status_y + 1, right_x, right,
                     curses.color_pair(PAIRS["DIM"]))

        stdscr.refresh()

        # ── input ──────────────────────────────────────────
        try:
            ch = stdscr.getch()
        except KeyboardInterrupt:
            return
        if ch == -1:
            continue  # tick — refresh loop
        if ch in (ord("q"), 27):
            return
        if ch in (ord("j"), curses.KEY_DOWN):
            sel_idx = min(sel_idx + 1, max(0, len(cached_tasks) - 1))
        elif ch in (ord("k"), curses.KEY_UP):
            sel_idx = max(0, sel_idx - 1)
        elif ch in (ord("g"),):
            sel_idx = 0
        elif ch in (ord("G"),):
            sel_idx = max(0, len(cached_tasks) - 1)
        elif ch in (curses.KEY_ENTER, 10, 13, ord(" ")):
            if cached_tasks:
                tid = cached_tasks[sel_idx][0]
                pinned_task = None if pinned_task == tid else tid
        elif ch == ord("r"):
            if cached_tasks:
                tid = cached_tasks[sel_idx][0]
                ok, msg = _invoke_action(project, ["retry", tid])
                flash_msg = (f"retried {tid}" if ok
                             else f"retry failed: {msg[:40]}")
                flash_until = time.time() + 3.0
                refresh_data()
        elif ch == ord("R"):  # capital R = forced retry
            if cached_tasks:
                tid = cached_tasks[sel_idx][0]
                ok, msg = _invoke_action(project, ["retry", "--force", tid])
                flash_msg = (f"force-retried {tid}" if ok
                             else f"force-retry failed: {msg[:40]}")
                flash_until = time.time() + 3.0
                refresh_data()
        elif ch == ord("c"):
            if cached_tasks:
                tid = cached_tasks[sel_idx][0]
                ok, msg = _invoke_action(project, ["cancel", tid])
                flash_msg = (f"cancelled {tid}" if ok
                             else f"cancel failed: {msg[:40]}")
                flash_until = time.time() + 3.0
                refresh_data()
        elif ch == ord("?"):
            _show_help(stdscr)


def _count_states(tasks: list[tuple]) -> dict:
    out: dict = {}
    for row in tasks:
        st = row[1]
        out[st] = out.get(st, 0) + 1
    return out


def _render_detail(stdscr, y0: int, y_max: int, tid: str, project: Path,
                   tasks: list[tuple]) -> None:
    """Render the detail block for `tid` starting at y0 (inclusive) bounded by y_max."""
    # Find the task row
    row = next((r for r in tasks if r[0] == tid), None)
    if row is None:
        _addstr_clip(stdscr, y0, 2, f"{tid}: not found",
                     curses.color_pair(PAIRS["RED"]))
        return
    _tid, status, wid, branch, retries, redispatches, _prio, _created = row
    glyph, color = STATE_GLYPH.get(status, ("?", "GREY"))
    title = _spec_title(project, tid)

    # Line 1: header
    _addstr_clip(stdscr, y0, 2, f"{glyph}  {tid}  [{status}]",
                 curses.color_pair(PAIRS[color]) | curses.A_BOLD)
    meta = (f"worker {wid or '--'}  ·  branch {branch or '--'}  ·  "
            f"retries {retries}  ·  redispatches {redispatches}")
    _addstr_clip(stdscr, y0 + 1, 2, meta, curses.color_pair(PAIRS["DIM"]))
    _addstr_clip(stdscr, y0 + 2, 2, title,
                 curses.color_pair(PAIRS["DIM"]) | curses.A_DIM)

    # Line 4: live status.json (turns/files/progress/updated)
    status_json = _read_status_json(project, wid)
    if status_json:
        upd_age = ""
        upd_iso = status_json.get("updated", "")
        upd_ts = _parse_iso(upd_iso) if upd_iso else None
        if upd_ts:
            upd_age = _age_human(max(0, time.time() - upd_ts)) + " ago"
        turns = status_json.get("turns", 0)
        fc = status_json.get("files_changed", 0)
        progress = status_json.get("progress", "")
        live = (f"📊 turns {turns}  ·  files {fc}  ·  {progress}"
                f"{('  ·  ' + upd_age) if upd_age else ''}")
        _addstr_clip(stdscr, y0 + 4, 2, live,
                     curses.color_pair(PAIRS["CYAN"]))

    # Layout below: live activity (variable, up to ~6 rows) + transitions (last 2)
    cur_y = y0 + 6
    activity_lines, act_mtime = _read_worker_activity(project, wid, limit=8)
    if activity_lines:
        age_str = ""
        if act_mtime is not None:
            age_str = "  ·  " + _age_human(max(0, time.time() - act_mtime)) + " ago"
        backend_label = (status_json.get("backend") if status_json else None) or "worker"
        header = f"Live activity ({backend_label}){age_str}"
        _addstr_clip(stdscr, cur_y, 2, header,
                     curses.color_pair(PAIRS["DIM"]))
        cur_y += 1
        for line in activity_lines:
            if cur_y >= y_max:
                break
            # Mute color so the user's eye lands on the latest line (last drawn)
            attr = curses.color_pair(PAIRS["DIM"])
            if line.startswith("✓"):
                attr = curses.color_pair(PAIRS["GREEN"])
            elif line.startswith("$") or line.startswith("✏"):
                attr = curses.color_pair(PAIRS["CYAN"])
            elif line.startswith("⚠"):
                attr = curses.color_pair(PAIRS["RED"])
            _addstr_clip(stdscr, cur_y, 2, "  " + line, attr)
            cur_y += 1
        cur_y += 1  # gap before transitions

    # Transitions — keep only the last 2 since activity above gives more signal
    try:
        hist = db.query_history(tid)
    except Exception:
        hist = []
    if hist and cur_y < y_max - 1:
        _addstr_clip(stdscr, cur_y, 2, "Transitions (most recent first):",
                     curses.color_pair(PAIRS["DIM"]))
        cur_y += 1
        for ts, from_s, to_s, reason in reversed(hist[-2:]):
            if cur_y >= y_max:
                break
            t = ts.split("T")[-1].rstrip("Z") if "T" in ts else ts
            line = f"  {t}  {from_s or '·':<10} → {to_s:<10}  {reason or ''}"
            _addstr_clip(stdscr, cur_y, 2, line,
                         curses.color_pair(PAIRS["DIM"]))
            cur_y += 1


def _invoke_action(project: Path, args: list[str]) -> tuple[bool, str]:
    """Run `harness-task <args>` in project dir; return (ok, message)."""
    env = os.environ.copy()
    env["HARNESS_DB"] = str(project / ".harness" / "harness.db")
    try:
        proc = subprocess.run(
            ["harness-task", *args],
            cwd=str(project), env=env,
            capture_output=True, text=True, timeout=10,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        return (False, str(e))
    out = proc.stdout.strip() or proc.stderr.strip()
    if not out:
        return (proc.returncode == 0, f"exit_{proc.returncode}")
    try:
        data = json.loads(out.splitlines()[-1])
        if data.get("ok"):
            return (True, "")
        return (False, data.get("message") or data.get("error") or "unknown")
    except json.JSONDecodeError:
        return (proc.returncode == 0, out[:80])


def _show_help(stdscr) -> None:
    """Modal-ish help overlay: clear, print, wait for any key."""
    H, W = stdscr.getmaxyx()
    stdscr.erase()
    lines = [
        "  harness watch — keys",
        "",
        "    j / ↓        next task",
        "    k / ↑        prev task",
        "    g / G        first / last",
        "    Enter / Space  pin (📌) selected task in detail pane",
        "    r            retry selected task   (failed/merged only)",
        "    R            force-retry           (for orphaned working/blocked)",
        "    c            cancel selected task",
        "    ?            this help",
        "    q / Esc      quit",
        "",
        "  Status bar reads coordinator-activity.log — only actions the",
        "  coordinator has logged via `harness-task log-action` show up.",
        "",
        "  (press any key to return)",
    ]
    for i, ln in enumerate(lines):
        _addstr_clip(stdscr, i + 1, 0, ln)
    stdscr.refresh()
    stdscr.nodelay(False)
    stdscr.timeout(-1)
    stdscr.getch()
    stdscr.timeout(1000)


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
