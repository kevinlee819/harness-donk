"""Budget gate — ports lib/budget.sh.

Read-only kill switch: query today's accumulated cost against config limit.
The actual stop-dispatch + notify logic lives in orchestrator (where project
context is available).
"""

from __future__ import annotations

from harness import db
from harness.config import read_config

DEFAULT_DAILY_USD = 10.0


def daily_limit() -> float:
    v = read_config("budget_daily_usd", str(DEFAULT_DAILY_USD))
    try:
        return float(v)
    except ValueError:
        return DEFAULT_DAILY_USD


def today_cost() -> float:
    return db.today_cost()


def under_limit() -> bool:
    return today_cost() < daily_limit()
