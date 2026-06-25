-- harness SQLite schema
-- schema_version (PRAGMA user_version): 1
-- 见 docs/data-schemas.md §1

PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=ON;
PRAGMA user_version=1;

CREATE TABLE IF NOT EXISTS tasks (
  id            TEXT PRIMARY KEY,
  spec_path     TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'queued'
                CHECK (status IN ('queued','dispatched','working',
                                  'gating','blocked','merged','failed')),
  worker_id     TEXT,
  branch        TEXT,
  priority      INTEGER DEFAULT 100,
  retries       INTEGER DEFAULT 0,
  redispatches  INTEGER DEFAULT 0,
  depends_on    TEXT,
  created       TEXT NOT NULL,
  updated       TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tasks_status_priority ON tasks(status, priority, id);

CREATE TABLE IF NOT EXISTS transitions (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id    TEXT NOT NULL REFERENCES tasks(id),
  from_state TEXT,
  to_state   TEXT NOT NULL,
  reason     TEXT,
  ts         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_transitions_task ON transitions(task_id, ts);

CREATE TABLE IF NOT EXISTS sessions (
  task_id       TEXT NOT NULL REFERENCES tasks(id),
  backend       TEXT NOT NULL,
  session_id    TEXT,
  resume_count  INTEGER DEFAULT 0,
  last_seen     TEXT,
  PRIMARY KEY (task_id, backend)
);

CREATE TABLE IF NOT EXISTS calls (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  ts            TEXT NOT NULL,
  task_id       TEXT NOT NULL REFERENCES tasks(id),
  worker_id     TEXT,
  backend       TEXT NOT NULL,
  session_id    TEXT,
  exit_code     INTEGER,
  cost_usd      REAL,
  num_turns     INTEGER,
  duration_ms   INTEGER,
  files_changed INTEGER
);
CREATE INDEX IF NOT EXISTS idx_calls_ts ON calls(ts);
CREATE INDEX IF NOT EXISTS idx_calls_task ON calls(task_id);

CREATE TABLE IF NOT EXISTS events (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  ts         TEXT NOT NULL,
  event_type TEXT NOT NULL
             CHECK (event_type IN ('needs_decision','task_completed',
                                   'task_failed','budget_exceeded')),
  task_id    TEXT REFERENCES tasks(id),
  payload    TEXT NOT NULL,
  delivered  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_events_pending ON events(delivered, ts);
