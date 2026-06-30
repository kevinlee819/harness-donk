"""Periodic supervisor — detects problems orchestrator can't notice itself.

Designed to be invoked by a small daemon loop (`bin/harness-watchdog`) every
~10 minutes. One `tick()` call is idempotent and stateless except for a small
JSON file at `.harness/.watchdog-state.json` that tracks "last-alerted-at"
per problem-key so we don't spam the user.

Two problem classes:
  1. orchestrator_down — there are non-terminal tasks but the orchestrator's
     heartbeat file (.harness/.orchestrator-heartbeat) is stale or missing.
     The main loop touches it each tick; long silence = process gone.
     Re-alert every 30 min.
  2. events_pending — undelivered events older than `EVENTS_PENDING_MINUTES`
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
EVENTS_ACK_GRACE_S = 30      # quiet window after last ack before re-alerting (Bug 11)

# ── re-alert intervals (seconds) ──────────────────────────
RE_ALERT_ORCH_DOWN = 30 * 60       # 30 min
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
        "events_alerted": False,
        "active_count": 0,
    }

    # ── 1. orchestrator_down (heartbeat-based, Bug 9) ────
    # Old design read max(tasks.updated) but that's static when all live tasks are
    # queued waiting on a dependency — so a healthy orchestrator looked dead.
    # New: orchestrator main loop writes .harness/.orchestrator-heartbeat each tick;
    # if the file is stale (or missing while tasks exist), the process is really gone.
    heartbeat_file = project_dir / ".harness" / ".orchestrator-heartbeat"
    fresh = db.query_active_freshness()
    if fresh is None:
        # No active tasks → idle is fine; nothing to supervise.
        state["alerts"].pop("orchestrator_down", None)
    else:
        active_count, _ = fresh
        summary["active_count"] = active_count
        hb_epoch: Optional[float] = None
        if heartbeat_file.is_file():
            try:
                hb_epoch = float(heartbeat_file.read_text().strip())
            except (ValueError, OSError):
                hb_epoch = None
        # Stale = heartbeat older than threshold OR file missing entirely
        stale = (hb_epoch is None) or ((now - hb_epoch) >= STALE_MINUTES * 60)
        if stale:
            if _should_alert(state, "orchestrator_down", RE_ALERT_ORCH_DOWN, now):
                if hb_epoch is None:
                    age_desc = "no heartbeat file"
                    age_min = -1
                else:
                    age_min = int((now - hb_epoch) / 60)
                    age_desc = f"{age_min} 分钟无心跳"
                notify("task_failed", None, {
                    "reason": "orchestrator_down",
                    "active_tasks": active_count,
                    "heartbeat_age_minutes": age_min,
                    "message": (
                        f"{active_count} 个任务在运行态但 orchestrator {age_desc}——"
                        "进程可能已停止。"
                    ),
                })
                _mark_alert(state, "orchestrator_down", now)
                summary["orchestrator_down"] = True
                log.warning("watchdog: orchestrator_down alert (active=%d %s)",
                            active_count, age_desc)
        else:
            # Heartbeat fresh → orchestrator alive, clear sticky flag if any
            state["alerts"].pop("orchestrator_down", None)

    # ── 2. Garbage-collect legacy stuck:<tid> alert keys (Bug 10) ──
    # Previously watchdog re-fired `persistent_stuck` hourly for every queued
    # task with a failed dep, duplicating the orchestrator's downstream_blocked
    # event and generating one alert per blocked child. The orchestrator's
    # once-per-set in-memory dedup is sufficient; the watchdog no longer fires.
    for k in list(state["alerts"].keys()):
        if k.startswith("stuck:"):
            del state["alerts"][k]

    # ── 3. events_pending (coordinator hasn't picked up) ──
    ev = db.query_oldest_pending_event()
    if ev is not None:
        count, oldest_ts = ev
        oldest_epoch = _iso_to_epoch(oldest_ts)
        # Bug 11: respect an ack-grace window. If the coordinator just acked
        # something, give it EVENTS_ACK_GRACE_S to process any follow-up
        # events before we re-fire — otherwise new events arriving seconds
        # after an ack get misread as "ignored".
        ack_sentinel = project_dir / ".harness" / ".last-event-ack"
        last_ack_epoch: Optional[float] = None
        if ack_sentinel.is_file():
            try:
                last_ack_epoch = float(ack_sentinel.read_text().strip())
            except (ValueError, OSError):
                last_ack_epoch = None
        in_ack_grace = (last_ack_epoch is not None
                        and (now - last_ack_epoch) < EVENTS_ACK_GRACE_S)
        if oldest_epoch is not None \
           and (now - oldest_epoch) >= EVENTS_PENDING_MINUTES * 60 \
           and not in_ack_grace:
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
