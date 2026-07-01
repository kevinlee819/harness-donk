-- V3: remove cost tracking entirely
--
-- Rationale: cost only reliably came from Claude in API-key mode. OAuth
-- subscriptions, custom-provider codex, and codex without --model all
-- either paid a flat fee or misbilled against wrong prices. Showing a
-- half-truth ("today $0.00 / $10.00" when 12 codex tasks ran) misled
-- more than it helped. Kill the whole surface: DB column, budget guard,
-- price table, budget_exceeded event.
--
-- This migration:
--   1. Drops `cost_usd` from `calls` (SQLite: recreate table).
--   2. Rewrites the `events.event_type` CHECK to drop 'budget_exceeded'.
--      Any existing 'budget_exceeded' rows are preserved but no new ones
--      can be inserted — the notify module also drops it from ALLOWED.

-- ── calls: drop cost_usd column ──────────────────────────────
ALTER TABLE calls RENAME TO _calls_old_v2;

CREATE TABLE calls (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  ts            TEXT NOT NULL,
  task_id       TEXT NOT NULL REFERENCES tasks(id),
  worker_id     TEXT,
  backend       TEXT NOT NULL,
  session_id    TEXT,
  exit_code     INTEGER,
  num_turns     INTEGER,
  duration_ms   INTEGER,
  files_changed INTEGER
);

INSERT INTO calls (id, ts, task_id, worker_id, backend, session_id,
                   exit_code, num_turns, duration_ms, files_changed)
SELECT id, ts, task_id, worker_id, backend, session_id,
       exit_code, num_turns, duration_ms, files_changed
  FROM _calls_old_v2;

DROP TABLE _calls_old_v2;

CREATE INDEX IF NOT EXISTS idx_calls_ts ON calls(ts);
CREATE INDEX IF NOT EXISTS idx_calls_task ON calls(task_id);

-- ── events: drop 'budget_exceeded' from CHECK ────────────────
ALTER TABLE events RENAME TO _events_old_v2;

CREATE TABLE events (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  ts         TEXT NOT NULL,
  event_type TEXT NOT NULL
             CHECK (event_type IN ('needs_decision','task_completed',
                                   'task_failed','task_blocked')),
  task_id    TEXT REFERENCES tasks(id),
  payload    TEXT NOT NULL,
  delivered  INTEGER NOT NULL DEFAULT 0
);

-- Preserve every historical event *except* budget_exceeded rows, which
-- the new CHECK would reject. If any exist, drop them (they refer to a
-- feature that no longer exists).
INSERT INTO events (id, ts, event_type, task_id, payload, delivered)
SELECT id, ts, event_type, task_id, payload, delivered
  FROM _events_old_v2
 WHERE event_type != 'budget_exceeded';

DROP TABLE _events_old_v2;

CREATE INDEX IF NOT EXISTS idx_events_pending ON events(delivered, ts);
