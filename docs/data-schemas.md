# Data Contracts (Schema)

Formally defines all persisted data in this system. All three ends (adapter / orchestrator / coordinator tools) must implement in sync; changes must increment `schema_version` and synchronize all code.

Current version: `schema_version = 1`.

---

## 1. SQLite: `<project>/.harness/harness.db`

### 1.1 Startup PRAGMAs

```sql
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=ON;
PRAGMA user_version=1;          -- schema_version equivalent
```

### 1.2 DDL

```sql
-- main tasks table
CREATE TABLE IF NOT EXISTS tasks (
  id            TEXT PRIMARY KEY,        -- T-XXXX, recommended: time-ordered + short hash
  spec_path     TEXT NOT NULL,           -- relative to project root: specs/T-0042.md
  status        TEXT NOT NULL DEFAULT 'queued'
                CHECK (status IN ('queued','dispatched','working',
                                  'gating','blocked','merged','failed')),
  worker_id     TEXT,                    -- w1 / w2 ...
  branch        TEXT,                    -- harness/T-0042
  priority      INTEGER DEFAULT 100,     -- lower number = dispatched first
  retries       INTEGER DEFAULT 0,       -- gate failure feedback retry count
  redispatches  INTEGER DEFAULT 0,       -- dead worker redispatch count
  depends_on    TEXT,                    -- JSON array of task_id or NULL
  created       TEXT NOT NULL,           -- ISO-8601 UTC
  updated       TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tasks_status_priority ON tasks(status, priority, id);

-- state transition history (audit + crash recovery read-back)
CREATE TABLE IF NOT EXISTS transitions (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id    TEXT NOT NULL REFERENCES tasks(id),
  from_state TEXT,
  to_state   TEXT NOT NULL,
  reason     TEXT,                       -- 'gate_failed' / 'worker_dead' / 'user_answered' ...
  ts         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_transitions_task ON transitions(task_id, ts);

-- session registry (session resume + dead worker detection)
CREATE TABLE IF NOT EXISTS sessions (
  task_id       TEXT NOT NULL REFERENCES tasks(id),
  backend       TEXT NOT NULL,            -- claude / codex / opencode
  session_id    TEXT,                     -- Codex may be NULL (uses --last)
  resume_count  INTEGER DEFAULT 0,
  last_seen     TEXT,                     -- refreshed when status.json is ingested
  PRIMARY KEY (task_id, backend)
);

-- call ledger (cost and observability)
CREATE TABLE IF NOT EXISTS calls (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  ts            TEXT NOT NULL,
  task_id       TEXT NOT NULL REFERENCES tasks(id),
  worker_id     TEXT,
  backend       TEXT NOT NULL,
  session_id    TEXT,
  exit_code     INTEGER,
  cost_usd      REAL,                     -- NULL when not obtainable
  num_turns     INTEGER,
  duration_ms   INTEGER,
  files_changed INTEGER
);
CREATE INDEX IF NOT EXISTS idx_calls_ts ON calls(ts);
CREATE INDEX IF NOT EXISTS idx_calls_task ON calls(task_id);

-- pending event routing queue (orchestrator writes, coordinator injector consumes)
CREATE TABLE IF NOT EXISTS events (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  ts         TEXT NOT NULL,
  event_type TEXT NOT NULL                -- needs_decision/task_completed/task_failed/budget_exceeded
             CHECK (event_type IN ('needs_decision','task_completed',
                                   'task_failed','budget_exceeded')),
  task_id    TEXT REFERENCES tasks(id),
  payload    TEXT NOT NULL,               -- JSON
  delivered  INTEGER NOT NULL DEFAULT 0   -- 0/1
);
CREATE INDEX IF NOT EXISTS idx_events_pending ON events(delivered, ts);
```

### 1.3 Key Queries

**Atomic claim of head task**:

```sql
UPDATE tasks
SET status='dispatched', worker_id=:worker, updated=datetime('now')
WHERE id=(
  SELECT id FROM tasks
  WHERE status='queued'
    AND (depends_on IS NULL OR NOT EXISTS (
          SELECT 1 FROM json_each(depends_on) je
          JOIN tasks t2 ON t2.id = je.value
          WHERE t2.status != 'merged'
    ))
  ORDER BY priority, id
  LIMIT 1
)
RETURNING id, spec_path;
```

**Dead worker scan**:

```sql
SELECT t.id, t.worker_id
FROM tasks t
JOIN sessions s ON s.task_id = t.id
WHERE t.status='working'
  AND s.last_seen < datetime('now', '-' || :threshold || ' minutes');
```

**Today's cost**:

```sql
SELECT COALESCE(SUM(cost_usd), 0) FROM calls
WHERE ts >= datetime('now', 'start of day');
```

---

## 2. JSON Blackboard: Worker Writes

### 2.1 `<project>/.harness/workers/<worker_id>/status.json`

```json
{
  "schema_version": 1,
  "worker_id": "w1",
  "backend": "claude",
  "session_id": "01J9F8...-uuid",
  "task_id": "T-0042",
  "status": "working",
  "branch": "harness/T-0042",
  "progress": "JWT middleware done, writing tests",
  "turns": 42,
  "files_changed": 3,
  "blockers": [],
  "updated": "2026-06-12T10:15:00Z"
}
```

| Field | Type | Required | Values |
|-------|------|----------|--------|
| `schema_version` | int | ✓ | 1 |
| `worker_id` | string | ✓ | `w1`/`w2`... |
| `backend` | string | ✓ | `claude`/`codex`/`opencode` |
| `session_id` | string | ✓ | UUID; Codex may use `__last__` as placeholder |
| `task_id` | string | ✓ | `T-XXXX` |
| `status` | enum | ✓ | `starting`/`working`/`done`/`error` |
| `branch` | string | ✓ | the branch this worker is on |
| `progress` | string | ✓ | one-line human-readable progress; not used for control decisions |
| `turns` | int | ✓ | cumulative turns in current session |
| `files_changed` | int | ✓ | cumulative files changed in current worktree |
| `blockers` | array | ✓ | soft blocker list (does not trigger BLOCKED) |
| `updated` | ISO-8601 UTC | ✓ | updated on every write |

**How the orchestrator reads this**:

- `status` is `done` → triggers WORKING→GATING.
- `status` is `error` → triggers feedback or FAILED (based on retries).
- Every ingest refreshes `sessions.last_seen`.

### 2.2 `<project>/.harness/workers/<worker_id>/guidance.json`

Written by the worker when it needs a human/coordinator decision. **Presence is treated as blocking**.

```json
{
  "schema_version": 1,
  "blocking": true,
  "task_id": "T-0042",
  "question": "Use RS256 or HS256 for JWT signing?",
  "context": "RS256 is more secure but requires key management; current project has no KMS.",
  "options": ["RS256", "HS256"],
  "created": "2026-06-12T10:20:00Z"
}
```

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `blocking` | bool | ✓ | Only `true` triggers BLOCKED; `false` reserved for soft reminders |
| `task_id` | string | ✓ | associated task |
| `question` | string | ✓ | natural language question |
| `context` | string |   | decision background |
| `options` | array<string> |   | possible answers; when non-empty, coordinator prefers to choose from these |
| `created` | ISO-8601 UTC | ✓ |   |

**Orchestrator action**: `blocking==true` → `db_transition(task, BLOCKED)` → `notify needs_decision` → wait for `inbox/<id>.answer` to appear.

### 2.3 `<project>/.harness/inbox/<task_id>.answer`

Written by human or coordinator. **Single-line JSON or plain text**:

```json
{
  "schema_version": 1,
  "task_id": "T-0042",
  "answer": "Use RS256, key stored in .env.local, added to .gitignore",
  "decided_by": "user",
  "ts": "2026-06-12T10:25:00Z"
}
```

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `answer` | string | ✓ | body injected into the next prompt |
| `decided_by` | enum | ✓ | `user` / `coordinator` |

**Orchestrator action**: After ingesting, delete `guidance.json`, call `adapter_call --resume`, prepend answer to prompt: "Previous question: <question>, decision: <answer>".

---

## 3. Validation Gate Report

### 3.1 `<worktree>/.gate-report.json`

```json
{
  "schema_version": 1,
  "task_id": "T-0042",
  "ts": "2026-06-12T10:30:00Z",
  "ok": false,
  "steps": [
    {"name": "build",        "ok": true,  "duration_ms": 1200, "skipped": false, "output": ""},
    {"name": "lint",         "ok": true,  "duration_ms": 800,  "skipped": false, "output": ""},
    {"name": "test",         "ok": false, "duration_ms": 4500, "skipped": false,
     "output": "FAIL tests/auth.test.ts\n  expected 200, got 401"},
    {"name": "diff_audit",   "ok": true,  "duration_ms": 50,   "skipped": false, "output": ""},
    {"name": "cross_review", "ok": false, "duration_ms": 12000, "skipped": false,
     "output": "{\"approve\":false,\"issues\":[\"JWT key hardcoded\"]}"}
  ],
  "summary": "test failed + cross_review rejected"
}
```

| Field | Type | Notes |
|-------|------|-------|
| `ok` | bool | true only when all non-skipped steps are ok |
| `steps[].name` | enum | `build`/`lint`/`test`/`diff_audit`/`cross_review` |
| `steps[].output` | string | key summary on failure (no more than 2KB); full output in `logs/raw/` |

**For feedback**: Orchestrator reads all `ok==false` steps' `output` and constructs prompt:

```
The last submission did not pass the validation gate; please fix the following and resubmit:

[test] FAIL tests/auth.test.ts
  expected 200, got 401

[cross_review] Review rejected:
  - JWT key hardcoded

Please fix only the issues above; do not expand the scope of changes.
```

---

## 4. Task Spec

### 4.1 `<project>/specs/<task_id>.md`

YAML frontmatter + Markdown body:

```markdown
---
schema_version: 1
task_id: T-0042
title: Add JWT validation to /auth endpoint
backend: claude              # optional; defaults to orchestrator --backend or HARNESS_BACKEND (claude)
model: opus-4-7              # optional; passed through to adapter
reviewer: codex              # optional; overrides AGENTS.md cross_review_reviewer
cross_review: true           # optional true/false; overrides AGENTS.md cross_review_enabled
priority: 50
depends_on: []
file_scope:                  # required; diff_audit uses this to detect out-of-scope changes
  - src/middleware/**
  - tests/auth.test.ts
forbidden_paths:             # optional; extra forbidden paths for this task (stacked on global hooks)
  - src/billing/**
acceptance:                  # required; machine-verifiable
  - cmd: npm test -- tests/auth.test.ts
    expect_exit: 0
  - cmd: npm run lint
    expect_exit: 0
max_turns: 12
max_retries: 3
---

## Background
...

## Expected Behavior
...

## Acceptance Checklist (human-readable, equivalent to acceptance above)
- [ ] /auth/login returns 200 + Set-Cookie
- [ ] Accessing a protected endpoint without token returns 401
```

**Pre-enqueue checks by coordinator**:

- `file_scope` is non-empty.
- `acceptance` has at least 1 item and all have `cmd`.
- All task_ids in `depends_on` exist.
- All `[ ]` acceptance items in spec body have corresponding `acceptance` command coverage.

---

## 5. Call Logs: `logs/raw/`

Filename: `<unix_ts>-<task_id>-<backend>-<seq>.json`

Contents: raw backend output received by adapter (Claude JSON / Codex NDJSON aggregated / OpenCode JSON), plus envelope:

```json
{
  "schema_version": 1,
  "ts": "2026-06-12T10:15:00Z",
  "task_id": "T-0042",
  "worker_id": "w1",
  "backend": "claude",
  "request": {
    "prompt_path": ".harness/prompts/T-0042-1.txt",
    "session_id": null,
    "max_turns": 12
  },
  "response": { ... raw backend output ... }
}
```

For debugging only; not stored in database; cleaned up by `harness gc` after 30 days.

---

## 6. Global Config: `~/.config/harness/config`

INI / simplified key-value:

```ini
budget_daily_usd = 10.00
notify_channel   = tmux      # tmux / desktop / webhook
session_resume_cap = 6
dead_worker_minutes = 10
max_concurrent_workers = 1    # fixed at 1 before phase 4
```

`~/.config/harness/projects.list`: one project absolute path per line.

---

## 7. Schema Upgrade Process

### 7.1 File Layout

```
schema/
├── harness.sql                            # base schema: run this for fresh installs
└── migrations/
    ├── README.md                          # this process quick reference
    └── V<N>__<short_description>.sql      # incremental migrations; N = target user_version
```

### 7.2 Adding a New Column / Table (Example: adding tags column to tasks)

1. **Sync base schema**: Add `tags TEXT,` field to the `CREATE TABLE tasks` statement in `schema/harness.sql`. `CREATE TABLE IF NOT EXISTS` is a no-op for existing tables; this change only affects **fresh installs**.
2. **Write migration file**: `schema/migrations/V2__add_tasks_tags_column.sql`:
   ```sql
   ALTER TABLE tasks ADD COLUMN tags TEXT;
   ```
   Do not write `PRAGMA user_version=2` in migration files — the migration runner sets this automatically.
3. **Update SCHEMA_VERSION**: `SCHEMA_VERSION = 2` at the top of `src/harness/db.py`.
4. **Sync base SQL header PRAGMA**: In `schema/harness.sql`, change `PRAGMA user_version=1` to `=2`.
5. **Sync three-end code changes** (anything touching the new field): `db.py`, `db_cli.py`, adapter log format, `coordinator-tool` usage.
6. **Local self-test**: Take an old `.harness/harness.db` (user_version=1) and run `harness init` or restart orchestrator once — `init()` should automatically run the V2 migration.
7. **Commit**: base SQL + V2 file + SCHEMA_VERSION change in the same commit.

### 7.3 Never Delete Old Columns

- Allows rollback compatibility (if the new version has issues, `git revert` lets old code read the old DB).
- Historical backups (`.harness/backups/harness-*.db`) remain readable.
- If deletion is truly needed, wait until data is migrated + one stable major version passes, then do a separate deprecation.

### 7.4 Runner Behavior (`db._apply_migrations`)

- Scans `schema/migrations/V*.sql` in ascending N order.
- Only executes for `current_user_version < N <= SCHEMA_VERSION` range.
- After applying each file → immediately writes `PRAGMA user_version=N`; next startup picks up from there.
- Fresh install: `base SQL` directly sets user_version to current SCHEMA_VERSION → runner sees current==target, no-op.
- Failure: raises original sqlite3 exception, does not silently swallow — upstream `init()` reports error to caller.

Test coverage: `tests/unit/test_db.py::test_apply_migrations_*` (4 cases), including missing directory, already-applied skip, and beyond-target-version ignore.
