# Module Architecture

## 1. Directory Structure (Final State)

```
~/tools/harness/                        # tool repository (this repo)
│
├── README.md                           # project entry point
├── CLAUDE.md                           # Claude development quick reference (includes language boundary hard constraints §8.1)
├── docs/                               # design and development documentation (this directory)
├── pyproject.toml                      # Python package definition (console scripts: harness-task / harness-db)
├── uv.lock                             # uv lock file (in git; use `uv sync` to rebuild .venv)
│
├── bin/                                # user/system executable entry points (exposed in PATH)
│   ├── harness-infi                    # start coordinator session (sole user entry point)
│   ├── harness                         # bash entry: init/status/run-once; DB operations via harness-db CLI
│   └── harness-watchdog                # periodic supervisor daemon (launched by harness-infi as tmux window 2)
│
├── orchestrator.sh                     # 7-line shim: exec python -m harness.cli.orchestrator_cli (kept for compatibility with bin/harness run-once / harness-infi entry)
│
├── src/harness/                        # Python layer (parts touching SQL / state machine / concurrency)
│   ├── __init__.py
│   ├── db.py                           # SQLite short-connection wrapper, true parameterization (BEGIN IMMEDIATE write transactions)
│   ├── orchestrator.py                 # phase 4 — parallel worker pool + serial merge consumer
│   ├── worker.py                       # WorkerThread: full single-task lifecycle (adapter → gate → retry → merge queue)
│   ├── merge.py                        # MergeRequest + drain_queue (main thread serial git merge)
│   ├── adapter.py                      # subprocess wrapper: calls adapters/<backend>.sh
│   ├── notify.py                       # events table + JSON files + hooks/notification.sh (ported from lib/notify.sh)
│   ├── watchdog.py                     # periodic supervisor — detects orchestrator-down / persistent stuck / unread events
│   ├── budget.py                       # budget gate (ported from lib/budget.sh)
│   ├── atomic_write.py                 # JSON / text atomic write (ported from lib/atomic_write.sh)
│   ├── config.py                       # reads ~/.config/harness/config
│   └── cli/
│       ├── harness_task.py             # coordinator tool implementation
│       ├── db_cli.py                   # bash bridge (harness-db <subcmd>)
│       ├── orchestrator_cli.py         # console script: harness-orchestrator
│       ├── watchdog.py                 # one watchdog tick (called by bin/harness-watchdog loop)
│       ├── watch_tui.py                # `harness watch` interactive curses TUI (read-only against DB)
│       ├── activity_tui.py             # `harness activity` — scrollable coordinator-activity.log viewer
│       └── statusline.py               # Claude Code statusLine renderer
│
├── coordinator/                        # coordinator arming package
│   ├── coordinator.md                  # coordinator system prompt / interrupt policy (natural language definition)
│   └── tools/
│       └── harness-task                # thin shim: exec python3 -m harness.cli.harness_task
│
├── adapters/                           # backend normalization layer (bash)
│   ├── claude.sh
│   └── codex.sh                        # opencode not yet done
│
├── lib/                                # remaining bash function library (gate still in bash; rest migrated to Python)
│   ├── gate.sh                         # validation gate multi-step execution (includes cross_review)
│   └── python_env.sh                   # bash → python bridge: sets $HARNESS_PYTHON + PYTHONPATH
│
├── hooks/                              # hook scripts installed to project .claude/settings.json
│   ├── pre_tool_use.sh                 # dangerous command interception (stderr + exit 2)
│   └── notification.sh                 # event desktop notification + notify.log
│
├── templates/                          # copied/rendered to project during harness init
│   ├── AGENTS.md.tmpl                  # includes gate block + cross_review_reviewer
│   ├── settings.json.tmpl              # .claude/settings.json hooks registration
│   └── gitignore-fragment
│
├── schema/                             # data contracts
│   ├── harness.sql                     # SQLite DDL (create tables + PRAGMA + version)
│   └── migrations/                     # incremental migration files V<N>__<desc>.sql
│       └── README.md
│
└── tests/
    ├── run.sh                          # test entry point, discovers .sh + .py
    ├── lib/{assert.sh, setup.sh}       # bash test helpers
    ├── unit/                           # all mocked, runs in CI
    │   ├── test_atomic_write.sh / test_gate.sh / test_hooks.sh
    │   ├── test_notify.sh / test_notification_hook.sh
    │   ├── test_budget.sh / test_backup.sh / test_events_cli.sh
    │   ├── test_claude_adapter.sh / test_codex_adapter.sh
    │   ├── test_gate_cross_review.sh
    │   ├── test_db.py                  # 30+ cases including migration drill
    │   └── test_harness_task.py
    ├── integration/                    # e2e mocked, runs in CI
    │   ├── test_e2e_success.sh / test_e2e_retry_failed.sh
    │   ├── test_e2e_blocked_resume.sh / test_e2e_orphan_reaper.sh
    │   ├── test_e2e_backend_switch.sh / test_e2e_depends_on.sh
    │   ├── test_init_idempotent.sh / test_harness_infi.sh
    └── manual/                         # real model calls, run manually, not in CI
        ├── README.md
        ├── smoke_real_claude.sh
        ├── smoke_real_codex.sh
        ├── smoke_real_cross_review.sh
        └── smoke_coordinator.sh
```

**Language boundaries**: thin layers calling subprocesses/constructing commands use bash; parts touching SQL/state machine/JSON-schema use Python (`src/harness/`). See [CLAUDE.md §8.1](../CLAUDE.md).

**Explicitly not in repo**: worktrees, `.harness/`, `~/.config/harness/` during runtime — these are runtime artifacts or global configuration.

## 2. Module List and Responsibilities

| # | Module | Path | Single Responsibility | Writer |
|---|--------|------|----------------------|--------|
| M1 | User entry | `bin/harness-infi`, `bin/harness` | Start coordinator session; management / observation commands | — |
| M2 | Coordinator arming | `coordinator/` | Coordinator prompt + coordinator-callable scripts | LLM (reads) |
| M3 | Execution orchestrator | `src/harness/orchestrator.py` + `worker.py` + `merge.py` (shim: `orchestrator.sh`) | Parallel worker pool + serial merge: claim → worktree → adapter → gate → merge queue → main thread merge | Orchestrator process |
| M4 | Backend adapters | `adapters/*.sh` | Normalize backend CLI calls into unified return structure | Adapter process |
| M5 | SQLite storage | `src/harness/db.py` + `src/harness/cli/db_cli.py` + `schema/harness.sql` | Queue / state machine / sessions / call ledger (Python, true parameterization, `BEGIN IMMEDIATE`) | Orchestrator exclusive |
| M6 | File blackboard | `src/harness/atomic_write.py` + `schema/json/` | Worker and human → orchestrator write interface | See §4 |
| M7 | Validation gate | `lib/gate.sh` | Multi-step checks → `.gate-report.json` | Gate process |
| M8 | Security hooks | `hooks/` | Registered in project `.claude/settings.json`; deterministic interception | Hook process |
| M9 | Notification routing | `src/harness/notify.py` + `hooks/notification.sh` | events table + JSON files + desktop notification (pull-on-re-engagement, see coordinator.md §2.2) | Notify process |
| M10 | Cost gate | `src/harness/budget.py` + orchestrator `_budget_guard` | Accumulation + over-limit kill switch + budget_exceeded event | Orchestrator call |
| M11 | Project initialization | `bin/harness init` + `templates/` | Bootstrap new project; `--backend` flips default reviewer | Initialization script |
| M12 | Call logging | adapter internal `_log_raw` | Call JSON written to `logs/raw/` (including envelope) | Adapter process |
| M13 | Orphan recovery | orchestrator `_reap_orphans` + `_timeout_blocked` | Single-process crash residue self-healing + BLOCKED timeout recovery | Orchestrator call |
| M14 | Backup | `bin/harness backup` + automatic merge hook | sqlite3 `.backup` + retention policy (default 7 days) | bin/harness |
| M15 | Periodic supervisor | `src/harness/watchdog.py` + `bin/harness-watchdog` | 10-min poll detecting problems orchestrator can't notice (orchestrator-down) + re-notify on persistent stuck / unread events; deduped via `.harness/.watchdog-state.json` | Watchdog process |

## 3. Dependency Graph (Bottom-Up)

```
                    ┌──────────────────────────────────┐
                    │  M1 Entry (harness-infi, harness) │
                    └──────────────┬───────────────────┘
                                   │
                  ┌────────────────┼────────────────┐
                  ▼                ▼                ▼
       ┌──────────────────┐  ┌──────────┐   ┌─────────────┐
       │ M2 Coordinator   │  │ M11 init │   │ M3 Orch-    │
       │ (harness-task)   │  │          │   │ estrator    │
       └────────┬─────────┘  └────┬─────┘   └──────┬──────┘
                │                 │                 │
                ▼                 ▼                 ▼
        ┌──────────────────────────────────────────────┐
        │  M5 db.sh  │ M6 atomic_write │ M9 notify    │
        │  M7 gate   │ M10 budget      │ M12 log      │
        └────────┬───────────────────────────┬─────────┘
                 │                           │
                 ▼                           ▼
        ┌──────────────┐            ┌──────────────────┐
        │ schema/*.sql │            │ M4 adapters/*    │
        │ schema/json/ │            │ (claude/codex/   │
        └──────────────┘            │  opencode)       │
                                    └────────┬─────────┘
                                             │
                                             ▼
                                    ┌──────────────────┐
                                    │ backend CLI proc │
                                    └──────────────────┘

  M8 hooks deployed independently to project .claude/settings.json, triggered by backend CLI,
  communicates with caller via stderr/exit code; not in the call chain.
```

**Rules**:

- Upper layers only call lower layers, never the reverse.
- `lib/` modules are independent of each other; no cross-calls (unless explicitly declared). Exception: `budget.sh` and `notify.sh` both need to call `db.sh`.
- `adapters/` don't depend on db / notify — they are purely functional wrappers: input prompts, output unified structure.
- `hooks/` are scripts deployed to external projects; **must not depend on harness repo's `lib`** (not available in the project); all needed utilities are inlined.

## 4. Writer Ownership (Single-Writer Principle)

| File/Resource | Sole Writer | Readers |
|--------------|------------|---------|
| `<project>/.harness/harness.db` | Orchestrator (M3), coordinator via `harness-task` (M2) | All processes needing state |
| `<project>/.harness/workers/<id>/status.json` | That worker (backend process inside adapter) | Orchestrator |
| `<project>/.harness/workers/<id>/guidance.json` | That worker | Orchestrator, coordinator |
| `<project>/.harness/inbox/<id>.answer` | Human / coordinator | Orchestrator (ingested and injected into next prompt) |
| `<project>/.harness/logs/raw/*.json` | M12 log | Debugging personnel |
| `<worktree>/.gate-report.json` | M7 gate | Orchestrator (for feedback), humans |
| `<project>/AGENTS.md` | Human | All agents |
| `<project>/specs/<task_id>.md` | Human / coordinator | Worker |

Concurrency safety: JSON atomic write (`*.tmp` → `mv`), SQLite WAL + busy_timeout=5000.

## 5. Billing Plane Separation

| Plane | Process | Billing | API key |
|-------|---------|---------|---------|
| Conversation (coordinator) | Interactive `claude` started by `harness-infi` | Subscription quota | Personal subscription |
| Execution (worker) | `claude -p` / `codex exec` / `opencode run` inside `adapters/` | Programmatic (API) | Separate API key, prompt caching enabled |

Entry point and configuration separation enforces this boundary; do not mix keys during development.
