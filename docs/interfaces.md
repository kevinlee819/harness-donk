# Module Interfaces

This document formally defines the contracts between modules: script inputs/outputs, function signatures, and file trigger relationships. **Any change here must be synchronized upstream and downstream**.

Field definitions for data schemas are in [data-schemas.md](data-schemas.md); this document only describes "who calls whom, what they pass, and what they receive."

---

## 1. User Entry (M1)

### 1.1 `harness-infi`

```
harness-infi [--no-attach] [--backend <name>] [--model <name>]
```

- Behavior: Creates or reuses a tmux session in the current directory (named `harness-<sha8(pwd)>`), with three windows:
  - **window 0 `coordinator`**: Interactive `claude` loading `coordinator/coordinator.md` as system prompt, with `coordinator/tools/` injected into PATH (`harness-task` available); bottom split-pane shows live status panel
  - **window 1 `orchestrator`**: Long-running `orchestrator.sh` (without `--once`), polling queue every 5s; dispatches immediately when tasks arrive
  - **window 2 `watchdog`**: Long-running `harness-watchdog`, ticks every 10 min (configurable via `HARNESS_WATCHDOG_INTERVAL`); see §8.2
- Attaches to window 0 by default; `Ctrl-B 0/1/2` to switch windows, `Ctrl-B D` to detach while session remains alive
- Options:
  - `--no-attach`: Only create the session (for scripts/CI); use `tmux attach -t harness-<hash>` afterward to enter
  - `--backend <name>`: Which writer backend the orchestrator uses (default `claude`; requires `adapters/${name}.sh` to exist)
  - `--model <name>`: Passed through to adapter (e.g. `claude-sonnet-4-6`)
- Prerequisites: Current directory must be a project that has been `harness init`-ed (`.harness/harness.db` exists); `tmux` and `claude` in PATH
- Failures: Not initialized → prompts `harness init`; missing backend CLI / unknown backend → prompts `harness doctor` / option typo
- Implementation note: Three launcher scripts written to `.harness/.coordinator-launcher.sh`, `.harness/.orchestrator-launcher.sh`, and `.harness/.watchdog-launcher.sh`, avoiding shell quoting nightmares; tmux session opened with `remain-on-exit on` so daemon panes remain after crash for debugging

### 1.2 `harness`

```
harness setup                            # one-time environment: validate deps, create ~/.config/harness/
harness doctor                           # echo-level self-check for each backend (real calls to claude + codex)
harness init [--backend claude|codex]    # bootstrap current directory: create .harness/, install templates, install hooks
                                         # --backend determines default cross_review_reviewer in AGENTS.md
                                         # (writer-reviewer auto-flip: claude→codex / codex→claude)
harness status [--task <id>] [--history] # task list / single task details / transition history
harness events pending                   # list pending events (needs_decision / failed / completed / budget_exceeded)
harness events ack <eid>...              # mark events as delivered (prevent coordinator from reporting duplicates)
harness orphans [minutes]                # list orphan tasks (working/dispatched/gating updated > N min ago, default 5)
harness watchdog-tick                    # run one watchdog cycle manually (see §8.2)
harness attach [<worker_id>]             # attach to tmux (no argument = coordinator session)
harness backup                           # sqlite3 .backup → .harness/backups/harness-<ts>.db
                                         # includes retention policy (default 7 days, HARNESS_BACKUP_RETAIN_DAYS adjustable)
harness run-once [--mock] [--backend N] [--model M] [--max-retries N]
                                         # run one orchestrator cycle (process one task then exit, for debugging/acceptance)
```

Return codes: 0 success, 1 user error (missing args etc.), 2 system error (missing dependency, database corruption).

Not implemented: `stop` / `ls` — not needed for current MVP/iter 1-2 scope.

---

## 2. Coordinator Arming (M2)

### 2.1 `coordinator/tools/harness-task`

Script callable by the coordinator. **Exposed only to the coordinator** — the sole means by which the coordinator writes to the task queue.

```
harness-task add [--id T-XXX] [--priority N] [--depends-on T-A,T-B] [--spec PATH]
                 # body via stdin → written to specs/<id>.md (unless --spec points to existing file)
harness-task query [--status queued|dispatched|working|gating|blocked|merged|failed]
                   [--task T-XXX] [--json]
harness-task history <task_id>          # state transition history
harness-task cancel  <task_id>          # cancel unfinished task (→ failed, reason=user_cancelled)
harness-task answer  <task_id> <text>   # reply to a BLOCKED task (writes inbox/<id>.answer)
```

- Input: command-line arguments + stdin (`add`'s spec body can come via stdin).
- Output: one-line JSON on stdout `{ok: bool, task_id: "T-XXX", error?: "..."}`.
- Implementation: thin shim calling `python -m harness.cli.harness_task`; **never let the coordinator directly construct SQL** (CLAUDE.md §8.1 language boundaries).

### 2.2 `coordinator/coordinator.md`

- Not a script — it's a system prompt.
- Must contain: the eight principles §2, interrupt policy (silent by default + three trigger types), `harness-task` usage, spec template format, pre-enqueue required checklist (must have acceptance commands, must declare file scope).

---

## 3. Execution Orchestrator (M3)

### 3.1 `orchestrator.sh` Main Loop

```bash
orchestrator.sh [--project <path>] [--once] [--mock] [--max-retries N] \
                [--model NAME] [--backend NAME] [--max-workers N]
```

- Real implementation: `src/harness/orchestrator.py`; `orchestrator.sh` is a 7-line shim.
- `--once`: Claim one task, run to terminal state (merged/blocked/failed) + drain merge queue, then exit.
- `--max-workers N`: Worker pool size (default 4, env `HARNESS_MAX_WORKERS` also works). `--once` implicitly sets pool=1.
- Default daemon mode, started in background by `harness-infi`, infinite loop polling every 5s when idle.
- **Concurrency model**: One `threading.Thread` per worker; main thread exclusively runs git merge (strictly serial). Workers hand off successful tasks to the main thread via `queue.Queue` for merging; failures/blocks are handled by each worker via transition + notify.

**Loop pseudocode**:

```
loop:
  budget_check || { kill_switch; sleep 30; continue }
  task = db_claim()              # atomically claim head of queued
  if !task: sleep 5; continue
  worktree = worktree_create(task)
  status = adapter_call(task, worktree)   # see §4
  ingest(workers/<id>/status.json)
  if guidance_blocking(): db_transition(task, BLOCKED); notify; continue
  while status == working: poll
  if !status.done: redispatch_or_fail(task); continue
  gate_result = gate.sh(worktree)
  if !gate_result.ok:
    if task.retries < MAX_RETRIES:
      task.retries++
      adapter_resume(task, gate_result.report_path)
      continue
    else:
      db_transition(task, FAILED); notify; continue
  merge_serial(worktree, task.branch)
  worktree_remove(worktree)
  db_transition(task, MERGED); notify
```

### 3.2 Dead Worker Scanner (M3 subprocess)

Runs every 60s:

```sql
SELECT task_id, worker_id FROM tasks
JOIN sessions USING(task_id)
WHERE status='working' AND last_seen < datetime('now', '-10 minutes');
```

On match: `db_transition(task, QUEUED, reason='worker_dead')`, `redispatches++`, capped at 2 before FAILED.

---

## 4. Backend Adapters (M4) — Adapter Contract

All adapters expose the same function `adapter_call`:

```bash
# Input: environment variables
ADAPTER_TASK_FILE=/path/to/prompt.txt       # required; prompt file path
ADAPTER_WORKTREE=/path/to/worktree          # required; working directory
ADAPTER_SESSION_ID=                         # optional; if present, resume session
ADAPTER_MAX_TURNS=12                        # inner turn limit
ADAPTER_TIMEOUT=900                         # outer wall clock, seconds
ADAPTER_BACKEND_MODEL=                      # optional; specify model

# Call
bash adapters/claude.sh

# Output: single-line JSON on stdout
{
  "ok": true,
  "session_id": "uuid-...",
  "result": "natural language summary",     # for humans/debugging only; must not be used for control decisions
  "cost_usd": 0.42,
  "num_turns": 7,
  "files_changed": 5,
  "error": null                              # filled with error brief when ok=false
}

# Output: stderr
raw backend output / debug info

# Exit codes
0  normal completion (ok may be true/false; JSON.error distinguishes business failure vs system failure)
non-0  adapter itself failed (parse error, CLI not found)
```

**Adapters must**:

1. Prompts go via stdin / file; never inline into command line.
2. After parsing backend output, **check errors before using results** (`.is_error` / `.error`).
3. Write raw call JSON to disk at `<project>/.harness/logs/raw/<ts>-<task_id>.json`.
4. `--output-format json` / `--json` must be passed; NDJSON (Codex) is aggregated internally by the adapter.
5. Resumption: when `ADAPTER_SESSION_ID` is non-empty, call with `--resume` / `--last`; otherwise first call.
6. Codex special constraint: if a Codex process already exists for the same worktree, wait (flock).

For onboarding new backends, see [adapter-contract.md](adapter-contract.md).

---

## 5. SQLite Wrapper (M5)

### 5.1 `src/harness/db.py` Public Functions (Python)

bash entry points call via `harness-db <subcommand>` console script (see `src/harness/cli/db_cli.py`). Python callers use `from harness import db` directly.

```python
db.init(schema_sql_path)                        # run schema/harness.sql + incremental migrations, idempotent
db.claim(worker_id)                             # atomic UPDATE...RETURNING → (task_id, spec_path) or None
db.transition(task_id, to_state, reason="")    # write tasks.status + transitions (BEGIN IMMEDIATE)
db.log_call(task_id, worker_id, backend, sid, exit_code, cost, turns, duration_ms, files_changed)
db.register_session(task_id, backend, session_id)
db.session_touch(task_id, backend)              # refresh last_seen=now
db.query_orphans(threshold_min, exclude_ids=[]) # list tasks stuck in transient states from crashes
db.today_cost()                                 # today's cumulative USD (float)
db.query_status(task_id=None)                   # task list
db.event_write / event_query_pending / event_mark_delivered
```

**Implementation requirements**:

- One short connection per call (`with _connect() as c:`); no long connections.
- Must use `PRAGMA busy_timeout=5000` and `journal_mode=WAL` (set once at database creation).
- Validate SQLite ≥ 3.35 at startup (`RETURNING` dependency).
- Multi-write transactions use `BEGIN IMMEDIATE` (so busy_timeout kicks in under write lock contention).
- Compare timestamps with `strftime('%s', ...)`; don't use string `<` (ISO-8601's `T`/`Z` doesn't match SQL `datetime('now')` format).

### 5.2 File Layer (M6)

Written by worker processes, ingested by orchestrator:

| File | Writer | Orchestrator action triggered |
|------|--------|------------------------------|
| `workers/<id>/status.json` | worker | Each ingest refreshes `sessions.last_seen`; if `status==done` triggers WORKING→GATING |
| `workers/<id>/guidance.json` | worker | `blocking==true` triggers WORKING→BLOCKED + notify |
| `inbox/<id>.answer` | human/coordinator | Triggers BLOCKED→WORKING, answer injected into next prompt |

File writing (`src/harness/atomic_write.py`):

```python
write_json(path, obj)                       # tmp + rename
write_text(path, content)                   # tmp + rename
```

---

## 6. Validation Gate (M7)

### 6.1 `lib/gate.sh`

```bash
gate.sh <worktree_dir> [--skip-cross-review]

# Exit codes
0  all green
non-0  at least one step failed

# Side effects
<worktree_dir>/.gate-report.json   # structured report
```

`.gate-report.json` schema see [data-schemas.md](data-schemas.md#gate-report).

### 6.2 Step Callbacks (commands declared in project AGENTS.md)

```yaml
gate:
  build: tsc --noEmit          # skip by setting to empty string
  lint: eslint .
  test: npm test
  diff_audit: harness diff-audit <spec>  # provided by orchestrator
  cross_review:
    enabled: true
    reviewer: codex             # codex / opencode / none
```

Undeclared steps are skipped and marked `skipped` in the report.

---

## 7. Security Hooks (M8)

Deployed to project `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/tools/harness/hooks/pre_tool_use.sh"}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "~/tools/harness/hooks/stop.sh"}]}
    ],
    "Notification": [
      {"hooks": [{"type": "command", "command": "~/tools/harness/hooks/notification.sh"}]}
    ]
  }
}
```

### 7.1 `hooks/pre_tool_use.sh` Contract

- stdin: Claude Code hook standard input JSON (containing `tool_input.command` etc.).
- Behavior: match dangerous pattern → write reason to stderr → `exit 2`.
- **Prohibited**: writing to stdout (model doesn't receive it), HTTP calls (network jitter bypasses security gate).
- Initial interception set: see design §7.5.

### 7.2 `hooks/stop.sh` Contract

- Input: Claude Code Stop hook stdin.
- Behavior: calls `gate.sh --quick` (build + lint only, not full test suite); any failure → write incomplete items to stderr → `exit 2` or output `{"decision":"block","reason":"..."}`.
- Purpose: prevents workers from exiting before completion — "intra-task self-driving" is built in this way.

### 7.3 `hooks/notification.sh` Contract

- Input: `hooks/notification.sh <event_type> <task_id> <event_json_path>` (called fire-and-forget by `harness.notify.notify`).
- Behavior: macOS desktop notification (osascript) + writes to `.harness/logs/notify.log`.

---

## 8. Notification Routing (M9)

### 8.1 `src/harness/notify.py`

```python
from harness.notify import notify
notify(event_type: str, task_id: Optional[str], payload: dict) -> int
# event_type: needs_decision | task_completed | task_failed | budget_exceeded
```

- Writes to `events` table + `.harness/events/<ts>-<event_type>-<task_id>.json`.
- Fire-and-forget calls `hooks/notification.sh` (desktop notification + notify.log).
- Coordinator consumes via `harness events pending` / `events ack` (pull-on-re-engagement, see coordinator.md §2.2).

### 8.2 Periodic Supervisor (M15) — `src/harness/watchdog.py` + `bin/harness-watchdog`

```bash
harness-watchdog [project_dir]   # daemon loop; project_dir defaults to $PWD
harness watchdog-tick            # run one cycle manually (debugging / verification)
```

- Configuration: `HARNESS_WATCHDOG_INTERVAL` (seconds, default 600 = 10 min).
- Launched by `harness-infi` as tmux window 2 — dies with the session.
- Each tick detects three problem classes; emits `task_failed` events with the
  reasons below. Dedup state lives at `.harness/.watchdog-state.json` so each
  problem doesn't fire on every tick.

| `payload.reason`         | When                                              | Re-alert interval | Coordinator handler (see coordinator.md §2.1) |
|--------------------------|---------------------------------------------------|------------------:|-----------------------------------------------|
| `orchestrator_down`      | Non-terminal tasks exist, none `updated` ≥ 15 min |          30 min   | Tell user to check window 1 / restart `harness-infi` |
| `persistent_stuck`       | Queued task blocked by failed dependency          |          60 min   | Check history; retry or escalate              |
| `events_pending_unread`  | Undelivered event in DB ≥ 10 min                  |          30 min   | Run full `harness events pending` consume loop |

- Tick output: one-line JSON on stdout (`{"ok": true, "ts": "...", ...}`); structured logs on stderr (also appended to `.harness/logs/watchdog.log`).
- A tick that crashes exits 0 — the daemon must not abort. Errors logged.

---

## 9. Cost Gate (M10)

### 9.1 `src/harness/budget.py`

```python
from harness.budget import under_limit, today_cost, daily_limit
under_limit() -> bool           # True = can still dispatch
today_cost() -> float           # today's cumulative USD
daily_limit() -> float          # read from ~/.config/harness/config, default 10
```

- Daily budget read from `~/.config/harness/config`; when exceeded, `notify budget_exceeded`.
- Does not kill running workers (prevents lost work); only stops `db_claim` for new tasks.

---

## 10. Project Initialization (M11)

### 10.1 `bin/harness init` Steps

In order:

1. Validate current directory is a git repo and has no `.harness/` (prevent overwrite).
2. Render `templates/AGENTS.md.tmpl` → `<project>/AGENTS.md` (project name, gate command placeholders).
3. `ln -s AGENTS.md CLAUDE.md`.
4. Merge `templates/settings.json.tmpl` into `<project>/.claude/settings.json` (if exists, prompt for manual merge).
5. Append `templates/gitignore-fragment` to `.gitignore`.
6. `mkdir -p .harness/{workers,inbox,events,logs/raw} specs`.
7. `db_init .harness/harness.db`.
8. Append project path to `~/.config/harness/projects.list`.

Idempotent: running again → only repairs missing items; does not overwrite manually edited AGENTS.md / settings.json.

---

## 11. Cross-Module Trigger Diagram

```
human/coordinator                  worker                       orchestrator
    │                                 │                            │
    │ harness-task add                │                            │
    └─────────────────────────────────┼────tasks INSERT───────────▶│
                                      │                            │ db_claim
                                      │   adapter_call ◀───────────│
                                      │ ─ status.json ────ingest──▶│
                                      │ ─ guidance.json ──notify──▶│──▶ events/
    │◀─────────── notify ──────────── events/ ──────────────────── │
    │ answer                                                       │
    └────── inbox/<id>.answer ──────resume────────────────────────▶│
                                      │ ─ commit ─────────────────▶│ gate.sh
                                      │                            │ merge (serial)
                                      │ ◀──── notify task_completed│
```
