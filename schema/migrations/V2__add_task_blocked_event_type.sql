-- V2: add 'task_blocked' to events.event_type CHECK constraint
--
-- task_blocked decouples "queued task blocked by a failed dep" from
-- task_failed. The coordinator runs different protocols for the two
-- (task_blocked → restart-the-chain; task_failed → diagnose-and-recover),
-- and overloading task_failed forced the coordinator to inspect payload
-- reason fields to disambiguate (Bug 6).
--
-- SQLite can't ALTER a CHECK constraint in place; we recreate the table.
-- Migration is idempotent against re-run because we drop _events_old_v1
-- at the end.

ALTER TABLE events RENAME TO _events_old_v1;

CREATE TABLE events (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  ts         TEXT NOT NULL,
  event_type TEXT NOT NULL
             CHECK (event_type IN ('needs_decision','task_completed',
                                   'task_failed','task_blocked','budget_exceeded')),
  task_id    TEXT REFERENCES tasks(id),
  payload    TEXT NOT NULL,
  delivered  INTEGER NOT NULL DEFAULT 0
);

INSERT INTO events (id, ts, event_type, task_id, payload, delivered)
SELECT id, ts, event_type, task_id, payload, delivered FROM _events_old_v1;

DROP TABLE _events_old_v1;

CREATE INDEX IF NOT EXISTS idx_events_pending ON events(delivered, ts);
