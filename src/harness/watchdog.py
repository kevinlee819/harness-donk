"""Periodic supervisor — detects problems orchestrator can't notice itself.

Designed to be invoked by a small daemon loop (`bin/harness-watchdog`) every
~10 minutes. One `tick()` call is idempotent and stateless except for a small
JSON file at `.harness/.watchdog-state.json` that tracks "last-alerted-at"
per problem-key so we don't spam the user.

Three problem classes:
  1. orchestrator_down — there are non-terminal tasks but none has been
     updated in `STALE_MINUTES` minutes. The orchestrator main loop bumps
     `updated` on every transition, claim, and status write, so a long
     silence means the process died or hung. Re-alert every 30 min.
  2. persistent_stuck — queued tasks blocked by a failed dependency. The
     orchestrator's hot loop fires this once via `_stuck_notified` but the
     set is in-memory; if the user dismisses the notification, the watchdog
     re-surfaces it hourly so it isn't silently lost.
  3. events_pending — undelivered events older than `EVENTS_PENDING_MINUTES`
     in the events table. Means the coordinator hasn't been asked anything
     by the user since the events fired (pull-on-re-engagement model).
     Watchdog fires a soft desktop notification to nudge the user back.

All alerts are emitted via `notify()` → events table + JSON + desktop popup,
which is the same pipeline used by the worker / orchestrator. Coordinator
consumes via `harness events pending` (same code path).
"""

from __future__ import annotations

import datetime
import json
import logging
import os
import time
from pathlib import Path
from typing import Optional

from harness import db
from harness.atomic_write import write_json
from harness.notify import notify

log = logging.getLogger("harness.watchdog")

# ── thresholds ────────────────────────────────────────────
STALE_MINUTES = 15         # tasks not updated for this long → orchestrator likely dead
EVENTS_PENDING_MINUTES = 1   # undelivered event age before we nudge

# ── re-alert intervals (seconds) ──────────────────────────
RE_ALERT_ORCH_DOWN = 30 * 60       # 30 min
RE_ALERT_STUCK_TASK = 60 * 60       # 60 min
RE_ALERT_EVENTS_PENDING = 30 * 60   # 30 min


def _state_path(project_dir: Path) -> Path:
    return project_dir / ".harness" / ".watchdog-state.json"


def _load_state(project_dir: Path) -> dict:
    p = _state_path(project_dir)
    if not p.is_file():
        return {"version": 1, "alerts": {}}
    try:
        data = json.loads(p.read_text())
        if "alerts" not in data:
            data["alerts"] = {}
        return data
    except (json.JSONDecodeError, OSError):
        return {"version": 1, "alerts": {}}


def _save_state(project_dir: Path, state: dict) -> None:
    write_json(_state_path(project_dir), state)


def _iso_to_epoch(s: str) -> Optional[float]:
    """Parse 'YYYY-MM-DDTHH:MM:SSZ' → epoch. Returns None on failure."""
    if not s:
        return None
    try:
        # Python 3.11+ fromisoformat accepts 'Z'; older needs replace
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        ).timestamp()
    except ValueError:
        return None


def _should_alert(state: dict, key: str, interval_s: float, now: float) -> bool:
    last = state["alerts"].get(key)
    if last is None:
        return True
    try:
        return (now - float(last)) >= interval_s
    except (TypeError, ValueError):
        return True


def _mark_alert(state: dict, key: str, now: float) -> None:
    state["alerts"][key] = now


def tick(project_dir: Path) -> dict:
    """Run one watchdog cycle. Returns a summary dict for caller logging."""
    state = _load_state(project_dir)
    now = time.time()
    summary: dict = {
        "ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "orchestrator_down": False,
        "stuck_alerted": [],
        "events_alerted": False,
        "active_count": 0,
    }

    # ── 1. orchestrator_down ────────────────────────────
    fresh = db.query_active_freshness()
    if fresh is None:
        # No active tasks → orchestrator idle, not a problem
        state["alerts"].pop("orchestrator_down", None)
    else:
        active_count, max_updated = fresh
        summary["active_count"] = active_count
        last_epoch = _iso_to_epoch(max_updated)
        # If parse fails, treat as fresh (avoid false alarm)
        if last_epoch is not None and (now - last_epoch) >= STALE_MINUTES * 60:
            if _should_alert(state, "orchestrator_down", RE_ALERT_ORCH_DOWN, now):
                age_min = int((now - last_epoch) / 60)
                notify("task_failed", None, {
                    "reason": "orchestrator_down",
                    "active_tasks": active_count,
                    "last_update": max_updated,
                    "stale_minutes": age_min,
                    "message": (
                        f"{active_count} 个任务在运行态但 {age_min} 分钟无更新——"
                        "orchestrator 可能已停止。"
                    ),
                })
                _mark_alert(state, "orchestrator_down", now)
                summary["orchestrator_down"] = True
                log.warning("watchdog: orchestrator_down alert (active=%d age=%dm)",
                            active_count, age_min)
        else:
            # Recently updated → healthy, clear sticky flag if any
            state["alerts"].pop("orchestrator_down", None)

    # ── 2. persistent_stuck (failed-dep blocked queued tasks) ──
    try:
        stuck = db.query_stuck_queued()
    except Exception:
        log.exception("watchdog: query_stuck_queued failed")
        stuck = []
    for tid in stuck:
        key = f"stuck:{tid}"
        if _should_alert(state, key, RE_ALERT_STUCK_TASK, now):
            notify("task_failed", tid, {
                "reason": "persistent_stuck",
                "message": f"{tid} 持续被失败依赖卡住——需要决策（重试 / 改 spec / 放弃）",
            })
            _mark_alert(state, key, now)
            summary["stuck_alerted"].append(tid)
    # GC stale stuck entries (no longer stuck → drop)
    stuck_set = set(f"stuck:{t}" for t in stuck)
    for k in list(state["alerts"].keys()):
        if k.startswith("stuck:") and k not in stuck_set:
            del state["alerts"][k]

    # ── 3. events_pending (coordinator hasn't picked up) ──
    ev = db.query_oldest_pending_event()
    if ev is not None:
        count, oldest_ts = ev
        oldest_epoch = _iso_to_epoch(oldest_ts)
        if oldest_epoch is not None \
           and (now - oldest_epoch) >= EVENTS_PENDING_MINUTES * 60:
            if _should_alert(state, "events_pending",
                             RE_ALERT_EVENTS_PENDING, now):
                age_min = int((now - oldest_epoch) / 60)
                notify("task_failed", None, {
                    "reason": "events_pending_unread",
                    "count": count,
                    "oldest_age_minutes": age_min,
                    "message": (
                        f"{count} 个未消费事件（最老 {age_min} 分钟）——"
                        "回协调者窗口说一句话即可处理。"
                    ),
                })
                _mark_alert(state, "events_pending", now)
                summary["events_alerted"] = True
                log.info("watchdog: events_pending alert (count=%d age=%dm)",
                         count, age_min)
    else:
        state["alerts"].pop("events_pending", None)

    _save_state(project_dir, state)
    return summary


def _project_dir_from_env() -> Path:
    p = os.environ.get("HARNESS_DB")
    if not p:
        raise RuntimeError("HARNESS_DB env not set")
    # <proj>/.harness/harness.db → <proj>
    return Path(p).parent.parent
