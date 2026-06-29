# Development Plan

## 0. Pace and Principles

- **No skipping phases**: Complete each phase, get it running, and have an acceptance signal before moving to the next.
- **Bottom layer first**: Within each phase, follow the order `schema → lib → adapter → orchestrator → bin → templates → integration tests`.
- **Verifiability is the admission ticket**: Any feature running inside a project must have a corresponding gate check first — "implement first, add tests later" is not allowed.
- **Driven by real tasks**: Each phase gets validated by running a concrete small project; no stacking features without real use.

## 1. Phase 1: Single Backend Closed Loop (Week 1)

**Goal**: Coordinator → enqueue → single worker (Claude) → validation gate → merge; full pipeline end-to-end. Human watches every step.

### 1.1 Deliverables (in dependency order)

| # | Module | Files | Definition of Done |
|----|--------|-------|-------------------|
| 1 | Data contracts | `schema/harness.sql`, `schema/json/*.json` | DDL can create database; JSON schema can be validated with jq |
| 2 | DB wrapper | `lib/db.sh` | `db_init / db_claim / db_transition / db_log_call` five functions + unit tests |
| 3 | File writes | `lib/atomic_write.sh` | `atomic_write_json` function; crash test passes |
| 4 | Logging | `lib/log.sh` | Call JSON written to `logs/raw/` |
| 5 | Claude adapter | `adapters/claude.sh` | Input prompt file → output unified structure `{ok, session_id, result, cost_usd, num_turns, error}` |
| 6 | Validation gate | `lib/gate.sh` | Five steps in sequence; any failure outputs `.gate-report.json` |
| 7 | Hooks (minimal security gate) | `hooks/pre_tool_use.sh`, `hooks/stop.sh` | Intercepts `push --force`, `rm -rf` outside worktree, stop without passing gate |
| 8 | Orchestrator | `orchestrator.sh` | Single worker serial loop: claim → worktree → adapter → gate → merge → reap |
| 9 | Coordinator arming | `coordinator/coordinator.md`, `coordinator/tools/harness-task` | System prompt with interrupt policy written; harness-task add/query functional |
| 10 | Entry points | `bin/harness-infi`, `bin/harness` | infi starts coordinator session; harness supports setup/doctor/init/status |
| 11 | Templates | `templates/AGENTS.md.tmpl`, `templates/settings.json.tmpl`, `templates/gitignore-fragment` | Rendered to project by `harness init` |

**Phase 1 deferred**: Codex / OpenCode adapter, cross-model review, parallel workers, dead worker detection, Notification routing, automated budget kill switch (manual calculation suffices).

### 1.2 Acceptance

- A real project (recommended: a small TypeScript or Python library with `make test`) runs 5 small tasks in sequence (e.g. "add unit tests for module X", "fix issue Y"), with **first-pass gate rate ≥ 60%**.
- `harness status` at any moment outputs the current queue and each task's state, consistent with the disk state.
- After manually `kill -9 orchestrator.sh` and restarting, a task in GATING can continue; a task in WORKING can be identified by dead worker detection (phase 2 takes over; manual restart suffices for phase 1).

## 2. Phase 2: Closed Loop and Crash Recovery (Week 2)

**Goal**: "Leave instructions before bed, review in the morning" is usable — the system can run unattended overnight, self-heal from crashes, and interrupt when needed.

### 2.1 Deliverables

| # | Module | Definition of Done |
|----|--------|-------------------|
| 1 | State machine transition history | `transitions` table writes + `harness status --history T-XXX` query |
| 2 | Error feedback | Gate failure → adapter `--resume` continuation, `.gate-report.json` injected as prompt; `retries++`, default cap of 3 |
| 3 | Dead worker detection | Refresh `sessions.last_seen` when ingesting status.json; scanner returns tasks to QUEUED after threshold exceeded (default 10 minutes); `redispatches++` capped at default 2 |
| 4 | Guidance escalation | Worker writes `guidance.json {blocking: true}` → orchestrator sets BLOCKED → escalated via notify |
| 5 | Notification routing | `lib/notify.sh` + `hooks/notification.sh` three event types: needs decision / pending acceptance / failure |
| 6 | Budget gate | `lib/budget.sh`: daily budget SQL accumulation; when exceeded, triggers kill switch + Notification |
| 7 | Backup | `harness backup` calls `sqlite3 .backup`, hooked at merge points |

### 2.2 Acceptance

- Submit 8 tasks and leave for 8 hours; returning to ≥ 5 MERGED, ≤ 1 BLOCKED that has been answered after notification, ≤ 2 FAILED with clear reason reports.
- `kill -9` orchestrator + all worker processes; after restarting, all tasks continue from correct state with **no task stuck in a "half-completed intermediate state"** (DISPATCHED with no worker / GATING with no report).
- Simulate API failure causing one task to timeout → should automatically redispatch once → still fails → FAILED and escalated.

## 3. Phase 3: Cross-Model Review (Week 3)

**Goal**: Introduce Codex / OpenCode as **judges** (not parallel writers), improving merge quality through cross-model adversarial review.

### 3.1 Deliverables

| # | Module | Definition of Done |
|----|--------|-------------------|
| 1 | Codex adapter | `adapters/codex.sh`, respecting per-worktree serial constraints |
| 2 | OpenCode adapter | `adapters/opencode.sh` |
| 3 | Gate step 5: cross-model review | Feed `git diff` to another backend, output `{approve: bool, issues: []}` |
| 4 | Configuration toggle | `AGENTS.md` gate.cross_review.reviewer: `codex | opencode | none` |
| 5 | Adapter doctor enhancement | `harness doctor` echo self-check for each backend |

### 3.2 Acceptance

- Deliberately create 3 diffs with subtle bugs (e.g. out-of-bounds access, null pointer, wrong SQL escaping); **cross-model review detection rate ≥ 2/3**.
- All hard requirements in the adapter contract table (see `adapter-contract.md`) are satisfied.

## 4. Phase 4: Parallel Worktrees (Week 4+)

**Goal**: Multiple workers execute independent tasks in parallel; throughput improves.

### 4.1 Prerequisites

- Phase 2 crash recovery has been stable for at least two weeks.
- Task split quality validated by coordinator self-check: spec template adds a "dependency check" field; coordinator answers "does this task depend on the output of any task currently in the queue" before enqueueing.

### 4.2 Deliverables

- Orchestrator main loop goes concurrent: worker pool + serial claim (SQL `RETURNING` is atomic) + parallel dispatch.
- Merging remains **strictly serial** (orchestrator main thread exclusive).
- `harness attach <worker>` selects pane.
- Resource gates: max concurrent workers, per-task token / time hard limits.

### 4.3 Acceptance

- 8 independent tasks run in parallel; throughput ≥ 3x serial.
- No race in merge phase (two complete simultaneously → second waits).
- Any worker crash does not contaminate other workers' worktrees.

## 5. Not on the Roadmap (Explicitly Will Not Do)

- Cross-machine distributed.
- Peer agent networks (A2A).
- Web UI.
- Multi-tenancy.
- Replacing SQLite with an external database.

Not built until requirements emerge (design §1 non-goals).

## 6. Risks and Mitigations (Development Phase)

| Risk | Trigger | Mitigation |
|------|---------|-----------|
| Bash complexity explosion | State machine/adapter exceeds 500 lines | Evaluate migration to Python at end of phase 3 (keeping file protocol and schema unchanged, transparent to agents) |
| Codex session out of control | Per-worktree serialization still shows concurrency | Add flock inside adapter to force serialization |
| OpenCode sub-agent hang | serve mode | Use only `opencode run` CLI path |
| Long session drift | Resume exceeds 6 rounds | Checkpoint to disk + open new session (implement this cap in phase 1) |
| Schema change sync miss | Three ends inconsistent | Schema change PRs must simultaneously touch adapter / orchestrator / harness-task in all three places |
