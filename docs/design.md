# Multi-Agent Self-Driving Coding Harness — Design Document



## 1. Background and Goals

This system is a personal workflow-level automated coding harness. It exposes a **single entry-point command** to the user, which starts a Claude Code session configured as a "coordinator" as the sole conversation interface; the coordinator dispatches coding tasks to multiple CLI execution agents (Codex, OpenCode, etc.) in the background, verifies their work through deterministic validation gates, and forms a self-driving loop capable of running unattended for long periods. The user only talks to the coordinator, which only interrupts the user when necessary.

Design goals in priority order:

1. **Single entry point, context ownership**: The user only faces one conversation interface; the context for sessions, tasks, costs, and artifacts is all held and managed by this system — not scattered across the engines being called.
2. **Self-driving**: Tasks enter from the queue and automatically flow through dispatch, execution, validation, and merge; failures are automatically fed back for retry; escalation to humans only when a real decision is needed.
3. **Interrupt-on-demand, always observable**: The coordinator is silent by default, only proactively reaching out when a decision is needed, acceptance is pending, or a failure occurs; when the user wants to know progress, task state and each agent's work is always queryable.
4. **Reliable**: Any process crashing at any moment — system state is not lost or corrupted; can resume from disk.
5. **Controllable**: Dangerous operations are intercepted deterministically (not via prompt constraints); changes can be reviewed before merging; costs have hard budget gates.
6. **Simple**: Implemented with bash + standard Unix tools (jq, sqlite3, tmux); no persistent services or specialized protocols; single-machine operation.

Non-goals: cross-machine distributed orchestration, peer agent networks (A2A), general multi-tenant platforms. Not built until requirements emerge.

## 2. Core Design Principles

**Principle 1: Single entry point holds context.** The user never directly uses the underlying engines (no bare `claude`). The entry command starts a coordinator session as the sole conversation interface; the ledger for sessions, costs, and artifacts is recorded by this system in the project's `.harness/`. Surrendering context ownership makes this system a name without substance — this is a non-negotiable dividing line.

**Principle 2: Intelligent judgment and deterministic execution are separated.** The coordinator (LLM) is only responsible for judgment and decisions: decomposing tasks, deciding what to dispatch to whom, interpreting results, deciding whether to escalate to humans. The actual process driving is handled by the deterministic dumb loop + adapter. The coordinator expresses intent through **script tools** we provide (which essentially writes tasks to the queue); it never uses send-keys to drive other agents itself.

**Principle 3: CLI is the protocol.** Calling any execution agent uses no specialized protocol — just Unix subprocesses: prompts go in via stdin/file, JSON comes out on stdout, exit codes indicate success/failure. A single call is "a task brief" not "a conversation round" — the agent runs autonomously through multiple think→tool→observe cycles internally until done or at the turn limit.

**Principle 4: Files, git, embedded SQLite are the medium.** Agents don't communicate via memory or network. State is layered by audience: **the interface for agents and humans is files** (spec, status, guidance, inbox); **the orchestrator's private transactional state is SQLite** (queue, state machine, transition history, session registry, cost ledger). Code artifacts are committed to git. State only lives on disk; crash recovery is natural.

**Principle 5: Processes are ephemeral, conversations are persistent.** Each interaction is an independent short-lived process call, sharing conversation history via session ID (`--resume`). Session resumption has a cap; when reached, a checkpoint is written to disk, a new session begins (fresh context, preventing long-session drift).

**Principle 6: Generator and judge are separated.** The agent writing code cannot declare itself done. Completion is determined by external judges: deterministic gates (tests/lint/type/build) as the first layer, cross-model adversarial review as the second layer. "Done" is a machine-verifiable standard.

**Principle 7: Deterministic constraints go in hooks, not prompts.** No force push, no touching sensitive directories, no stopping without passing the gate — hard constraints all use hooks to deterministically intercept at the tool execution checkpoint.

**Principle 8: Control plane and data plane are separated.** tmux only handles the control/observation plane (persistent sessions, always observable, survives disconnection); it never handles the data plane. Machine-readable data goes through structured interfaces (JSON + blackboard); never use capture-pane scraping to parse agents with structured output.

## 3. Dual-Plane Architecture

The system consists of two planes with distinct responsibilities, each with independent visibility policies.

```
┌──────────────────── Conversation Plane (user's main entry) ───────────────────────┐
│                                                                                    │
│  User ⇄ Coordinator session (Claude Code started by harness-infi, armed as coordinator) │
│        · holds all conversation and context with the user                          │
│        · silent by default; only proactively reaches out when decision/acceptance/failure needed │
│        · expresses intent through script tools (writes tasks to queue); doesn't drive agents directly │
│                                                                                    │
└──────────────────────────────┬───────────────────────────────────────────────────┘
                                │ script tools (harness-task add / query …)
                                ▼  writes to .harness/harness.db (task queue)
┌──────────────────── Execution Plane (background workshop) ────────────────────────┐
│                                                                                    │
│  orchestrator.sh (dumb loop, deterministic driver)                                │
│    claim task → create worktree → call execution agent via adapter → poll blackboard → gate → merge │
│                                                                                    │
│  Execution agents: Claude Code (primary) / Codex / OpenCode (parallel/backup/review) │
│    each in isolated tmux pane + isolated git worktree; hidden by default, always observable │
│                                                                                    │
└──────────────────────────────┬───────────────────────────────────────────────────┘
                                ▼
      shared base: AGENTS.md (contract) · .harness/harness.db (truth) · git (code handoff)
```

### 3.1 Conversation Plane

The user's sole conversation interface. `harness-infi` starts an interactive Claude Code session in a tmux session with coordinator configuration (dedicated system prompt / AGENTS.md / toolset). That session is the "main coordinating agent":

- Holds the full conversation context with the user; enjoys Claude Code's native interactive experience (we don't rebuild the TUI).
- Its tools are not for writing code, but for: decomposing tasks, calling script tools to enqueue, querying the blackboard for progress, interpreting validation reports, deciding when to escalate to humans.
- **Interrupt policy**: Silent by default. Only proactively speaks via Notification at three moments — ① decision needed from user (guidance); ② task complete pending acceptance; ③ failure it cannot resolve on its own.
- Because it's an interactive session (not a `claude -p` programmatic call), it runs against the user's **subscription quota**.

### 3.2 Execution Plane

The background workshop that the coordinator sees only the results of, hidden from the user by default.

- **orchestrator.sh**: A deterministic dumb loop — the real driver of task execution. Intelligence is not here; it's all in the coordinator's decisions and the gate's feedback loop.
- **Execution agents**: Claude Code as the primary; Codex / OpenCode for parallel runs, backup models, and cross-model review. Each execution agent works in an isolated worktree on an isolated branch, never touching the main branch; their processes are shown in tmux panes (for observation only, not for driving).
- Execution plane agent calls are programmatic (`claude -p` etc.), running against **programmatic quota** (API pricing).

The two planes' billing is naturally separated: high-frequency conversation runs on subscription; batch execution runs on programmatic quota — each independently controllable.

### 3.3 Scheduling: How the Coordinator Commands the Execution Plane (Option A)

The coordinator **does not directly drive** execution agents. It only expresses intent through script tools; actual process orchestration is done by the dumb loop:

1. Coordinator determines a task needs to be done → calls script tool `harness-task add <spec>` (essentially: INSERT a row into the `tasks` table of `.harness/harness.db`).
2. orchestrator.sh's loop runs independently, picks up the task → creates worktree → calls execution agent via adapter → runs gate → merges or feeds back.
3. Coordinator can call `harness-task query` at any time to read the blackboard for progress; task terminal states (complete/failed/blocked) return to the coordinator via Notification, which then decides whether and how to inform the user.

This way: **the intelligent part (coordinator) only judges; the deterministic part (dumb loop + adapter) executes** — responsibilities don't mix; and the execution plane can run independently of the conversation plane (coordinator session closes, background tasks keep running).

## 4. Communication Mechanism (Data Plane)

### 4.1 Calls and Sessions: Session Resume + JSON

The three backends have asymmetric session capabilities and must be normalized by the adapter; orchestration logic never touches native formats.

**Claude Code (adapter: claude.sh)**

```bash
RESP=$(timeout 900 claude -p "$(cat "$TASK_FILE")" --output-format json --max-turns 12)
SID=$(echo "$RESP" | jq -r '.session_id')
RESP=$(timeout 900 claude -p "$(cat "$FOLLOWUP")" --resume "$SID" --output-format json --max-turns 8)
```

session_id can be obtained programmatically and recorded; `--output-format json` captures `.result` (for humans) and `.session_id`/`.cost_usd`/`.num_turns` (for machines); custom session IDs must be valid UUIDs.

**Codex (adapter: codex.sh)**

```bash
codex exec "$(cat "$TASK_FILE")" --json
codex exec resume --last "$(cat "$FOLLOWUP")" --json
```

Hard constraint: Codex cannot obtain the current session ID programmatically — can only rely on `--last` filtered by working directory. Therefore: **at most one Codex session per worktree at a time, and Codex calls to that worktree must be serialized**. Its `--json` is an NDJSON event stream; the adapter aggregates it into a single result object; sessions are written as JSONL to `~/.codex/sessions/` for auditing.

**OpenCode (adapter: opencode.sh)**

```bash
opencode run "$(cat "$TASK_FILE")" --session "$SESSION_ID" --json
```

### 4.2 Blackboard: File Layer (agent/human interface) + SQLite Layer (orchestrator truth)

The file layer is the write interface for agent→orchestrator and human→orchestrator; the SQLite layer (`.harness/harness.db`) is the sole truth for orchestrator decisions. Workers atomically write their own `status.json`; the orchestrator **ingests** it into the database on each poll — files are the API, the database is the state; there is no double source of truth.

Two core schemas in the file layer:

**workers/<id>/status.json** (worker exclusive write)

```json
{
  "schema_version": 1, "worker_id": "w1", "backend": "claude",
  "session_id": "uuid-...", "status": "working", "task_id": "T-042",
  "branch": "harness/T-042", "progress": "JWT middleware done, writing tests",
  "turns": 42, "blockers": [], "updated": "2026-06-12T10:15:00Z"
}
```

**workers/<id>/guidance.json** (written when worker needs a decision — escalation trigger)

```json
{
  "schema_version": 1, "blocking": true,
  "question": "Use RS256 or HS256 for JWT signing?",
  "context": "RS256 is more secure but requires key management", "created": "2026-06-12T10:20:00Z"
}
```

Escalation path: orchestrator polls and sees `blocking: true` → writes pending decision event → escalated via Notification to coordinator → coordinator decides whether to ask the user per interrupt policy → user/coordinator's answer written to `inbox/<id>.answer` → orchestrator resumes original context with saved session_id via `--resume`. This is the complete implementation of "agent promptly asks main entry for decision on changes."

**SQLite layer schema draft** (`.harness/harness.db`):

```sql
CREATE TABLE tasks (
  id TEXT PRIMARY KEY, spec_path TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued',   -- queued/dispatched/working/gating/blocked/merged/failed
  worker_id TEXT, branch TEXT, priority INTEGER DEFAULT 100,
  retries INTEGER DEFAULT 0, redispatches INTEGER DEFAULT 0,
  created TEXT NOT NULL, updated TEXT NOT NULL
);
CREATE TABLE transitions (
  id INTEGER PRIMARY KEY, task_id TEXT NOT NULL,
  from_state TEXT, to_state TEXT NOT NULL, reason TEXT, ts TEXT NOT NULL
);
CREATE TABLE sessions (
  task_id TEXT NOT NULL, backend TEXT NOT NULL,
  session_id TEXT, resume_count INTEGER DEFAULT 0, last_seen TEXT
);
CREATE TABLE calls (
  id INTEGER PRIMARY KEY, ts TEXT, task_id TEXT, worker_id TEXT, backend TEXT,
  session_id TEXT, exit_code INTEGER, cost_usd REAL, num_turns INTEGER,
  duration_ms INTEGER, files_changed INTEGER
);
```

Atomic claim (claim a task and mark as dispatched, single statement, no race):

```bash
sqlite3 .harness/harness.db "UPDATE tasks
  SET status='dispatched', worker_id='$W', updated=datetime('now')
  WHERE id=(SELECT id FROM tasks WHERE status='queued' ORDER BY priority, id LIMIT 1)
  RETURNING id, spec_path;"
```

### 4.3 Hooks: Event and Enforcement Layer

Configured in project `.claude/settings.json`:

1. **PreToolUse = deterministic security gate**. Matcher `Bash`, checks `tool_input.command`, exits 2 to block on dangerous pattern match. Block reasons must be written to stderr (writing stdout means the model never receives the feedback).
2. **Stop hook** (completion enforcement): **Not currently implemented**. The original design intent was to use Stop to enforce completion when a worker exits (blocking exit if not all-green, forcing continuation), but after implementation it was found redundant with existing mechanisms: gate.sh is the authority on completion + error feedback on failure + retries have a cap; PreToolUse already covers out-of-bounds writes. The Stop hook context is weaker than gate, and forcing no-exit blows through token budgets. See [hooks/stop.md](../hooks/stop.md). Reassess when phase 4 parallel workers show real pathological cases.
3. **Notification = signal wire**. Events routed to coordinator / notification channels, eliminating empty-cycle polling.

Prohibition: hard policies must not use HTTP hooks (non-2xx is a non-blocking error, network jitter bypasses the security gate); always use command hooks.

## 5. Task State Machine

The lifecycle of each task is managed by the following state machine; current state and full transition history are persisted in `.harness/harness.db` (`tasks` and `transitions` tables); each transition is committed to the database first in a single transaction before action (if crashed, resume from database):

```
 QUEUED ──dispatch──▶ DISPATCHED ──▶ WORKING ──▶ GATING ──all green──▶ MERGED (terminal)
                                      │  ▲          │
                  guidance blocked    │  │          │ failed: error fed back, retries+1
                                      ▼  │          ▼
                                   BLOCKED ◀──    WORKING (retry with errors)
                              (awaiting human reply)
                                                    │ timeout / retries exhausted / redispatches exhausted
                                                    ▼
                                                 FAILED (terminal, notify coordinator)
```

Transition rules:

- QUEUED→DISPATCHED: Orchestrator atomically claims the head task, `git worktree add`, initiates first call via adapter and registers session_id.
- WORKING→GATING: Worker's status.json reports `done`, or process exits normally with commits in the worktree.
- GATING→WORKING (feedback): Any gate fails. Orchestrator concatenates failure output (test errors, lint, review comments) as follow-up prompt, resumes with `--resume`; `retries += 1`, capped (default 3).
- WORKING→BLOCKED: Polls and finds `guidance.json { blocking: true }`. BLOCKED→WORKING: Answer file appears in inbox, resumes with that session.
- Any state→FAILED: Wall clock timeout killed and redispatches exhausted, or retries cap exhausted. FAILED must be escalated to coordinator via Notification.
- **Dead worker detection** (not shown in diagram but must be implemented): Refreshes `sessions.last_seen` when ingesting status.json; a single SQL query identifies tasks with exceeded threshold (default 10 minutes) still `working`; declares worker dead; returns to QUEUED for redispatch (preferring the session_id saved in `sessions` table for resume, otherwise new session + continuing from existing commits on its branch). Redispatch count separately capped (default 2, `tasks.redispatches`).
- MERGED: Orchestrator (and only orchestrator) serially executes the merge, removes worktree with `git worktree remove` after merge, escalates "pending acceptance" via Notification.

## 6. Deployment Model and Directory Layout: Strict Tool/Project Separation

The mental model is **git**: the program is globally installed once; each project only holds its own state directory (`.harness/`, analogous to `.git/`). **harness code is never copied into any project**; the project repository only contains declarative content — AGENTS.md, specs/, hooks config (in git), plus runtime state `.harness/` (entirely gitignored). Upgrading harness = `git pull` in the tool directory; all projects immediately benefit.

File ownership follows the single-writer principle: **any file has exactly one writer**; `harness.db` is exclusively written by the orchestrator; concurrency is guaranteed by SQLite transactions (WAL).

```
~/tools/harness/                  # ① Tool itself (install once, bin/ in PATH, never copy)
├── bin/
│   ├── harness-infi              #    Entry command: starts Claude Code session with coordinator config
│   └── harness                   #    Management/observation command (status / attach / events / backup …)
├── orchestrator.sh               #    Execution plane entry (7-line shim, exec to Python body)
├── coordinator/                  #    Coordinator arming: system prompt + script tools
│   ├── tools/harness-task        #      Coordinator callable: add / query / answer / cancel / history
│   └── coordinator.md            #      Coordinator role and interrupt policy prompt
├── adapters/                     #    claude.sh / codex.sh (opencode not yet done)
├── src/harness/                  #    Python layer: parts touching SQL / state machine / concurrency
│   ├── db.py                     #      SQLite short-connection + true parameterization
│   ├── orchestrator.py + worker.py + merge.py   # parallel worker pool + serial merge
│   ├── adapter.py notify.py budget.py config.py atomic_write.py
│   └── cli/{harness_task,db_cli,orchestrator_cli}.py   # console scripts
├── lib/                          #    Remaining bash: gate.sh + python_env.sh
└── templates/                    #    AGENTS.md template, settings.json template, gitignore fragment

~/.config/harness/                # ② Global config (one per machine)
├── config                        #    Global daily budget, notification channel credentials
└── projects.list                 #    Registered project registry (global budget aggregation, harness ls)

<project>/                        # ③ Any onboarded project (clean: only its own code)
├── src/  tests/  Makefile        #    Project's own code
├── AGENTS.md                     #    Shared contract for all agents (in git)
├── CLAUDE.md → AGENTS.md         #    Symlink (in git)
├── .claude/settings.json         #    Hooks (in git, team-shared security gate)
├── specs/<task_id>.md            #    Task specs (in git: what AI did is project history)
└── .harness/                     #    Runtime state (entirely gitignored, disappears if project deleted)
    ├── harness.db                #    This project's queue/state machine/transition history/sessions/cost ledger
    ├── workers/<id>/{status,guidance}.json   # worker exclusive write
    ├── inbox/<id>.answer         #    Human/coordinator exclusive write
    └── logs/raw/                 #    Raw call JSON archive

<project sibling>/.worktrees/<project>/<task_id>/   # ④ worktrees in sibling directory outside project
                                  #    Avoids embedding in main workspace polluting git status
```

Global budget gate is implemented by `bin/harness` aggregating each project's `calls` table per `projects.list`; API console spend limit as final backstop.

## 7. Engineering Constraints (Implementation Must Follow)

### 7.1 Process and Session Boundaries

- Every execution agent call must have dual limits: outer `timeout` (wall clock, default 900s) + inner `--max-turns` (default 12). No exceptions.
- Session resumption cap: when the same session has been resumed N times (default 6) or is approaching the context window, force a checkpoint (write progress to blackboard, commit code), start a new session resuming from disk.
- Every call is by default treated as "possibly failed": may be killed by timeout, OOM, or crash mid-way. Exit code 0 ≠ task complete. **Truth = blackboard + git diff + gate; never the CLI return value.**
- Resume token costs increase 30–50% per round; independent tasks should prefer single calls over resumption.

### 7.2 Communication Contract

- One adapter per backend; normalizes `json` / `stream-json` / Codex NDJSON into the unified internal structure `{ok, session_id, result, cost_usd, num_turns, error}`; orchestration logic never touches native formats.
- Check error fields before using results: failed calls are often still valid JSON (`.is_error` / `.error`).
- **Never parse model natural language output (`.result`) for control decisions**; machine-readable control signals always come from structured blackboard files written by instructed agents.
- Prompts always go via stdin or file; never inline text containing quotes/`$`/backticks/newlines into the command line.

### 7.3 State Layer Concurrency Safety

File layer (worker/human writes):

- Atomic write: all JSON written to `*.tmp` then renamed with `mv`; no in-place writes.
- Single writer (see §6); all schemas carry `schema_version` validated on read, and `updated` timestamp for stale detection.

SQLite layer (orchestrator exclusive write):

- Create database with `PRAGMA journal_mode=WAL;`, each connection uses `PRAGMA busy_timeout=5000;` — reads don't block writes; occasional concurrent access automatically retried.
- Database file must be on local filesystem; **strictly prohibited on NFS/network mounts** (WAL shared memory mechanism is unreliable on network filesystems).
- One `sqlite3 db "..."` short-connection short-transaction per operation; no long transactions.
- Depends on `RETURNING` (SQLite ≥ 3.35); validate version at startup.
- Backup: `sqlite3 .harness/harness.db ".backup ..."`, run periodically at merge checkpoints.
- Agents must not directly write SQL to the database (escaping/injection is a high-frequency failure mode for LLMs); agents only write JSON files, ingested by the orchestrator. Coordinator reads/writes via `harness-task` script (parameterized); never touches SQL directly.

### 7.4 Isolation and Merging

- One task, one worktree, one branch; source repo and main branch are read-only to workers. Worktrees are in the sibling directory outside the project.
- Merging is the orchestrator's exclusive responsibility and strictly serial; only executed after the gate is all-green; workers are prohibited from merging / pushing to main.
- Worktrees are removed with `git worktree remove` when done; reaper periodically cleans up orphan worktrees.
- Parallel tasks must have no dependencies (task B does not import artifacts not yet created by task A); split quality is checked by the coordinator/human before enqueueing.

### 7.5 Hooks Enforcement Layer

- PreToolUse security gate initial interception list: `push --force`, `rm -rf` outside worktree, writing to `.harness/` directories other than the worker's own, reading/writing paths containing `prod`/`secret`, `git merge`/`git push` to main.
- Interception output to stderr + exit 2; a common error is writing to stdout causing the model to not receive feedback.
- Stop hook currently not implemented (completion handled by gate.sh + error feedback; see §4.3 and hooks/stop.md).
- Hard policies use only command hooks, not HTTP hooks.

### 7.6 Cost and Observability

- Each call INSERTs one row into the `calls` table; raw JSON archived to `logs/raw/` for debugging.
- Budget gate is SQL: `SELECT COALESCE(SUM(cost_usd),0) FROM calls WHERE ts >= date('now');` compared to daily budget; when exceeded, kill switch stops dispatching and notifies coordinator.
- Conversation plane runs on subscription; execution plane runs on programmatic quota (billed separately per API rate card as of 2026-06-15); configure a separate API key for the execution plane, enable prompt caching to amortize system prompts/file context sent repeatedly.

### 7.7 Security Baseline

- Production credentials physically isolated from harness runtime environment; environment variables accessible to agents are whitelisted.
- Main branch protection enforced by server-side rules, not relying on local hooks; the final gate before merging to main is always deterministic CI.
- Third-party skills/plugins treated like unfamiliar npm packages; audit source code before running.
- Automated loops produce large diffs; traditional line-by-line review becomes ineffective; backstop with engineering mechanisms: pre-commit, property tests, automated pipelines.

## 8. Validation Gate (gate.sh) Specification

Executed in sequence; any failure returns non-zero and outputs a structured failure report (for feedback):

1. **Build/type check** (if applicable): `tsc --noEmit` / `mypy` / `cargo check`.
2. **Lint**: project's existing linter, zero tolerance for new warnings.
3. **Tests**: full suite or affected subset; TDD-style tasks require spec to list tests that must pass upfront.
4. **Diff audit**: whether changes exceed the file scope declared in spec, whether forbidden paths were touched.
5. **Cross-model review** (configurable toggle): feeds `git diff` to another backend (Claude writes → Codex reviews, and vice versa); review agent outputs structured verdict `{approve: bool, issues: []}`; if not approved, issues become feedback material.

All gate output is written to `.gate-report.json` at the task's worktree root, as feedback prompt and human spot-check material.

## 9. Phased Rollout

- **Phase 1 (week 1) · Entry + single agent + gate**: Implement `harness-infi` (starts Claude Code with coordinator config) and `harness-task` script tool; orchestrator supports single backend (Claude), single worker; write AGENTS.md, gate.sh, hooks security gate. Coordinator can enqueue clearly-defined tasks from conversation; dumb loop executes and passes gate; human watches every run, refining spec writing. Acceptance: 5 consecutive real small tasks with first-pass gate rate ≥ 60%.
- **Phase 2 (week 2) · Closed loop and crash recovery**: Complete state machine, error feedback, retry/redispatch caps, dead worker detection, Notification interrupt policy. Begin "leave instructions before bed, review in the morning." Acceptance: after `kill -9` orchestrator, restart can correctly resume (SQLite transactions guarantee no half-completed intermediate states).
- **Phase 3 (week 3) · Cross-model review**: Introduce Codex/OpenCode as judges (review first, not parallel writing — higher value, lower risk).
- **Phase 4 · Parallel worktrees**: Multiple workers running in parallel; prerequisite is validated task split quality. Gradually reduce human intervention points.

## 10. Usage Manual

### 10.1 User Entry Point and Three Interaction Modes

The user entry point is fixed as **`harness-infi`** (run in the project directory): it starts Claude Code in a tmux session with coordinator configuration; all your interaction is with this coordinator. The three "modes" are not three entry points, but three ways of using the same coordinator session:

- **Conversation mode**: You and the coordinator discuss back and forth (exploring approaches, decomposing requirements, clarifying acceptance criteria). This is where "fuzzy" becomes "clear."
- **Delegation mode**: After discussion, you have the coordinator dispatch the tasks ("queue these three things, run overnight"). Coordinator calls `harness-task` to enqueue; the execution plane takes over. This is where "clear" becomes "code."
- **Observation/acceptance mode**: You ask the coordinator "how's it going," it queries the blackboard and reports; tasks complete and it proactively finds you for acceptance.

Key: all three modes share the same coordinator context and the same `.harness/` ledger; transitions are seamless — plans discussed in conversation mode can directly transition to delegation mode for enqueueing, with session and decisions continuous (this is exactly what v0.2 "bare claude mode A" couldn't do, the core fix in v0.3). **You never bare-run `claude`; that bypasses the coordinator and loses context ownership.**

### 10.2 Observability (Execution Plane Hidden by Default, Always Queryable)

The full process of the coordinator and execution agents is not shown to you by default. When you need to know, two granularities:

- **Snapshot** (usually sufficient): `harness status` queries `.harness/harness.db`, giving each task's status, each agent's current progress, and today's spending on one screen. Structured truth; no screen-reading required.
- **Live view**:
  - `harness attach` (no argument): enter the coordinator tmux session (window 0 started by harness-infi).
  - `harness attach <worker_id>` (e.g. `w1`, `w2`): **worker live snapshot** — after phase 4, workers are Python threads inside the orchestrator process, no longer independent tmux panes; this command outputs that worker's current status.json, worktree path, any blocking guidance if present, and a summary of the most recent adapter call.
  - `harness attach <worker_id> --path`: prints only the worktree path, useful for `cd "$(harness attach w1 --path)"` to enter the live scene.

### 10.3 One-Time Environment Setup (Per Machine)

Install and authenticate each backend CLI (claude / codex / opencode; OpenCode configured with third-party providers as needed); clone the harness tool to `~/tools/harness/`, add `bin/` to PATH (**never copy into any project**); `harness setup` validates dependencies (sqlite3 ≥ 3.35, jq, git, tmux) and creates `~/.config/harness/`; `harness doctor` does an echo-level self-check for each backend to confirm the full adapter chain works.

### 10.4 New Project Initialization (Bootstrap, With Human Supervision)

An empty repo has no tests and lint; the gate has nothing to check; **a project must first achieve "verifiability" before entering the automated loop** (the usage-side corollary of Principle 6). Process:

1. `cd <project> && harness init`: generates AGENTS.md template (with acceptance commands), symlinks CLAUDE.md, installs hooks, creates `.harness/` (initializes this project's harness.db) and `specs/`, appends gitignore entries, registers in `projects.list`.
2. `harness-infi` starts coordinator; in conversation mode, have it scaffold: project skeleton, test framework, linter, `make test`/`make lint` etc. as gate standard commands; human completes AGENTS.md in person.
3. After `lib/gate.sh` passes (at least one smoke test all green), the project may enter delegation mode automated loop.

### 10.5 A Typical Day

`cd <project> && harness-infi` starts coordinator → in conversation mode, lay out the day's tasks → coordinator decomposes and confirms acceptance criteria, then enqueues (delegation mode) → you go do other things; coordinator only finds you for decision/acceptance/failure → when a decision request arrives, reply directly in the conversation, coordinator passes it to the execution plane to resume → when a task completes, it finds you for acceptance; you run `harness status` for a snapshot and spot-check diff and `.gate-report.json`. Daily quality leverage is in spec verifiability, not orchestration parameters.

### 10.6 Adding New Models and CLIs (Two Axes, Don't Confuse)

**New models (DeepSeek, Kimi, etc.) ≠ new CLI.** Such models primarily connect to existing multi-provider CLIs via OpenAI/Anthropic-compatible endpoints (preferred: OpenCode with provider config adding baseURL + key + model name); **harness and adapter need zero changes**; specify `backend: opencode, model: <name>` in the task spec. Data boundaries must be evaluated: third-party/offshore models are by default only used for open-source and data-classification-permitted repos; the allowed backend/model whitelist is written in each project's AGENTS.md and enforced by gate.

**New CLI (standalone tool) goes through the adapter onboarding contract** — verify each item:

| # | Capability | Verification | Degradation if missing |
|---|-----------|-------------|----------------------|
| 1 | Non-interactive mode (hard requirement) | Pipe call without TTY completes and exits | No degradation — not onboarded |
| 2 | Exit code semantics (hard requirement) | Success 0 / failure non-zero | Determine success/failure from output; use with caution |
| 3 | Parseable output (hard requirement) | `--json` single object or NDJSON | Regex extraction, marked low-confidence; dispatch low-risk tasks only |
| 4 | Session resumption | `--resume/--session/--last`; ID obtainable programmatically | Single-shot tasks only; full context resent after BLOCKED |
| 5 | Tool permission control | allowlist/sandbox/approval mode | Rely only on worktree isolation + gate backstop; **no sensitive repos** |
| 6 | Cost data | Output contains cost/usage | `calls.cost_usd` written as NULL; budget gate estimates by call count |

Contract essence: adapter must normalize to `{ok, session_id, result, cost_usd, num_turns, error}`; missing fields declared in backend capability bitmap; orchestrator restricts dispatchable task types accordingly. Note: this contract is for **execution plane** backends; the conversation plane coordinator engine is currently fixed as Claude Code (can also be replaced with any engine with good interactive session capabilities, but requires separate adaptation, not covered by this table).

## 11. Known Risks and Trade-off Notes

- **Coordinator engine binding**: The conversation plane currently selects Claude Code as the coordinator engine (for its interactive experience and autonomous coding capabilities); replacing the coordinator engine costs more than replacing an execution backend — this is an architecture-level decision.
- **Coordinator reliability**: The coordinator is an LLM; its "judgment" may be wrong (dispatching wrong tasks, misjudging completion). Mitigation: the real go/no-go is always gated by deterministic gates; the coordinator has no authority to bypass gate and merge; coordinator enqueue actions are constrained by spec templates and AGENTS whitelist.
- Codex session ID not obtainable programmatically → forces per-worktree serialization, sacrificing some parallelism for determinism; can be resolved upstream if `--session-id` is added.
- OpenCode server mode has a known issue with sub-agent hangs → use the `opencode run` CLI path to avoid it; if switching to serve/SDK, verify the fix first.
- Session resume is context reconstruction, not memory snapshot; long-session recovery has latency and drift risk → resumption cap + checkpoint to disk as mitigation; cannot be omitted.
- Full-bash complexity ceiling: when state machine and adapter exceed ~500 lines, consider migrating orchestrator body to Python (keeping file protocol and harness.db schema unchanged, transparent to agents; Python standard library includes sqlite3; migration cost is low).
- SQLite sacrifices direct state readability (can't `cat`) → `harness status` output of current queue/task/cost snapshot compensates; raw call JSON archived to `logs/raw/`.
- Single-machine limitation: tmux and file/SQLite blackboard don't span machines; introducing multi-machine requires object storage blackboard or task distribution service, an architecture upgrade; explicitly not done currently.

## 12. Appendix: Fields and Conventions

Status / guidance / calls schemas see §4.2; all timestamps are UTC ISO-8601; JSON files are UTF-8 without BOM; `schema_version` is currently 1; non-backward-compatible changes must increment the version and synchronize across all three ends: adapter / orchestrator / coordinator tools.
