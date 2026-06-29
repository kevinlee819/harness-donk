<p align="center">
  <img src="donk.png" alt="harness — a pixel-art donkey wearing a harness" width="140">
</p>

# 🫏 Getting Started with harness

This guide is for first-time users. By the end you should know: who makes up harness, how the roles interact, how you fit in, how to install everything, how to onboard a project, and how to dispatch your first real task.

If you want to understand **why it's designed this way** (the philosophy), see [design.md](design.md).

---

## 0. A 30-Second Concrete Scenario

Suppose you say:

> "Add a `slugify(input: string)` function in `src/utils/` that converts a string to a URL slug, with unit tests covering three cases: empty string, CJK characters, and consecutive spaces."

What happens next — **you don't have to do anything**:

1. harness automatically creates an isolated git branch and working directory for the task (called a worktree — your main branch is completely unaffected).
2. It has Claude (or Codex, depending on your config) read your requirements → write code → write tests → `git commit` in that working directory.
3. It runs the check commands you configured in advance: did `tsc` pass? Did `pnpm lint` pass? Did `pnpm test` pass? Then it has a different LLM read the diff and find issues.
4. All pass → automatically merged to main branch.
5. Any step fails → the error is fed back and the model revises, up to 3 retries.
6. Still failing → system notification "task X failed, reason Y", you decide what to do next.

You can go get coffee during this whole process. Come back when the notification sounds.

Suitable for: local code iteration, overnight unattended test-driven development, cross-model review.
Not suitable for: cross-machine distributed setups, multi-person centralized scheduling.

---

## 1. Who Makes Up This System

harness is not an AI — it's **a program that chains multiple AIs together and adds a deterministic safety net**. Once you understand the roles below, the meaning of every command becomes clear.

### 1.1 You (The User)

You only talk to **one interface** — the "coordinator" introduced below. You never open Claude or Codex clients directly to write code. In principle you don't need to know the details below, but understanding them makes the interaction much smoother.

### 1.2 The Coordinator

**What it is**: An interactive Claude Code session, injected at startup with a special "job description" ([coordinator/coordinator.md](../coordinator/coordinator.md)) that makes it behave like a **project manager** rather than a programmer.

**What it does**:
- Takes your requirements, goes back and forth with you for clarification until you have verifiable acceptance criteria.
- Breaks large requirements into small tasks, writes specs, and adds them to the task queue.
- Reports back to you when tasks complete, get stuck, or fail.

**What it does NOT do**:
- Does not write code (writing code is the "execution agent"'s job).
- Does not attach to other tmux windows to drive other AIs by typing.
- Does not touch the main branch.

If the coordinator seems like it wants to write code itself — it has gone off-track. The coordinator.md explicitly states "you are not a worker."

### 1.3 The Orchestrator

**What it is**: A Python program with **no AI whatsoever**. Just a dumb loop: it checks the task queue every 5 seconds.

**What it does**:
- Picks a `queued` task from the SQLite queue.
- Uses git commands to create a worktree (isolated branch + isolated directory) for the task.
- Calls the actual code-writing AI through an adapter (see §1.4).
- Runs the validation gate (see §1.6).
- If passed, merges to main branch; if not, has the AI rewrite.

Its "intelligence" is 0. All judgment is on the coordinator side (should we do this? is it done?) and the gate side (machine-verifiable: did the tests pass?). This is harness's most critical design: **the intelligent part (LLM) and the deterministic part (process orchestration) are completely separate**.

### 1.4 Execution Agent / Worker

**What it is**: The AI that actually writes code. Claude or Codex both work.

**How it's called**: The orchestrator launches it as a **subprocess** (command line `claude -p` or `codex exec`), feeds the task spec as a prompt via stdin, waits for it to finish, and reads its output. Each call is an independent short-lived process — **not a persistent service**.

**Only active in its own worktree**: Your main code is completely unaffected. The worker sees an "independent copy" of your main branch in its assigned worktree, makes changes there, commits, and exits. It has **no permission** to directly `git push` to main (hooks will block it).

Can run in parallel: up to 4 workers run simultaneously by default, with no interference.

### 1.5 Adapter

**What it is**: A thin bash script ([adapters/claude.sh](../adapters/claude.sh) / [adapters/codex.sh](../adapters/codex.sh)).

**What it does**: Claude and Codex have different CLI formats (different argument names and JSON output formats). The adapter translates different backends into a unified calling contract, so the orchestrator code doesn't need to deal with each backend's quirks.

**You don't interact with it daily**. But when onboarding a third backend (like OpenCode or DeepSeek), you write a new adapter (see [adapter-contract.md](adapter-contract.md)).

### 1.6 The Gate

**What it is**: [lib/gate.sh](../lib/gate.sh), a script that runs commands sequentially according to your configuration.

**What it does**: Before merging to main, **forces** your configured checks to run:
1. Build/type checking (`tsc --noEmit` / `mypy` / `cargo check`, etc.)
2. Lint
3. Tests
4. Diff audit (did the worker touch directories it shouldn't have?)
5. Cross-model review (**have another LLM read the diff and find issues** — if claude wrote, codex reviews, and vice versa)

Any step fails → gate returns failure → the orchestrator feeds the error info back as a prompt and has the worker rewrite. Fails 3 times → task marked FAILED, you're notified.

**This is harness's root of trust**. Strict configuration makes automation meaningful; loose configuration (empty gate) means the whole system is a rubber stamp.

### 1.7 Role Diagram

```
                  ┌──────────────────┐
                  │      User        │
                  └────────┬─────────┘
                           │ natural language
                           ▼
                  ┌──────────────────┐
                  │   Coordinator    │  ← a Claude Code session
                  │ (like a PM)      │     loads coordinator.md as system prompt
                  └────────┬─────────┘
                           │ harness-task add → SQLite queue
                           ▼
                  ┌──────────────────┐
                  │  Orchestrator    │  ← Python dumb loop, no AI
                  │  (orchestrator)  │     every 5s: claim task, start worktree, run gate
                  └────────┬─────────┘
                           │ calls adapter
                           ▼
              ┌──────────────────────────┐
              │   adapter (claude/codex) │  ← bash translation layer
              └────────────┬─────────────┘
                           │ subprocess claude -p / codex exec
                           ▼
              ┌──────────────────────────┐
              │  Execution agent/worker  │  ← Claude / Codex
              │  writes code in          │     git commit then exit
              │  isolated worktree       │
              └────────────┬─────────────┘
                           │ done, exit
                           ▼
                  ┌──────────────────┐
                  │   gate.sh        │  ← runs your configured commands
                  │  (build/lint/    │     all must pass before merge
                  │   test/review)   │
                  └──────────────────┘
```

---

## 2. `harness` vs `harness-infi` — Two Commands, Two Roles

After installing the repo, you'll have two binaries in your PATH:

| Command | What it is | When to use |
|---------|-----------|-------------|
| **`harness-infi`** | Sole entry point / starts coordinator session | **99% of daily use** |
| `harness` | A set of management and observation subcommands | For onboarding projects, checking status, self-diagnosis, troubleshooting |

Analogy: `harness-infi` is like starting a ship's engine; `harness` is the toolbox on board.

### What `harness-infi` Does

Running `harness-infi` (in a project directory that has been `harness init`-ed):

1. Creates a tmux session named `harness-<project hash>` with three windows:
   - **window 0 — coordinator**: An interactive Claude Code session with coordinator.md loaded (the place where you chat).
   - **window 1 — orchestrator**: Background orchestrator daemon, polling the queue every 5 seconds, dispatching workers as tasks arrive.
   - **window 2 — watchdog**: Periodic supervisor; every 10 minutes it checks for problems the orchestrator can't notice itself (orchestrator process down, queued tasks stuck on a failed dependency, unread events piling up) and fires desktop notifications.
2. Attaches you to window 0.

After that, all your interaction is chatting with the coordinator in window 0. `Ctrl-B 1` / `Ctrl-B 2` to peek at the orchestrator / watchdog logs, `Ctrl-B 0` to come back, `Ctrl-B d` to detach (all three windows keep running in the background).

`-infi` is short for "infinite" — it starts a **long-running session** rather than a one-shot command.

### What `harness` Does

Each subcommand handles one thing, all **auxiliary**:

```bash
harness init [--backend codex]     # onboard current project (run once per new project)
harness setup                      # one-time environment check + create global config dir
harness doctor                     # check each backend CLI (burns a small amount of API)
harness status                     # view current status of all tasks
harness attach <wid>               # view a snapshot of what a worker is currently doing
harness events pending             # view pending notification events
harness backup                     # backup SQLite database
harness run-once [--mock]          # run one orchestrator cycle then exit (for manual debugging)
harness help                       # help
```

**Important: `harness` itself does not start the coordinator**. If you want to talk to the coordinator, use `harness-infi`.

---

## 3. Prerequisites

**Operating system**: macOS / Linux (not tested on Windows; WSL should work).

**Required commands** (`install.sh` will verify these, and report what to install if missing):

| Command | Minimum version | Purpose |
|---------|----------------|---------|
| `git` | any common version | worktree management, commits |
| `sqlite3` | **≥ 3.35** | task queue storage; requires `RETURNING` clause |
| `jq` | any | JSON processing |
| `tmux` | any | coordinator session hosting |
| `python3` | ≥ 3.9 | runs the `src/harness/` Python layer |

`uv` (Python environment manager) is **not on the required list** — the installer will detect it, and if missing, ask if you want it installed automatically using the official script (`curl -LsSf https://astral.sh/uv/install.sh | sh`).

**Optional**:

- `terminal-notifier` (macOS only) — makes notifications show the 🫏 donk logo instead of the default grey plug icon, and collapses consecutive notifications for the same task rather than stacking. Install: `brew install terminal-notifier`.

**At least one backend CLI** (pick one to start, more can be added later):

- Claude Code: installed and authenticated with `claude /login` (subscription or API key both work).
- Codex CLI: installed and authenticated with `codex login`.

> ⚠️ **Database must be on local filesystem** — do not put your project on an NFS / network share / sync client's remote mount. SQLite WAL mode is unreliable on network filesystems ([CLAUDE.md §4.3](../CLAUDE.md)).

---

## 4. Installation

Two options, pick one.

### 4.1 One-Line Script Install

```bash
curl -LsSf https://raw.githubusercontent.com/kevinlee819/harness-donk/main/install.sh | bash
```

Or with interactive confirmation (lets you review each step):

```bash
curl -LsSf https://raw.githubusercontent.com/kevinlee819/harness-donk/main/install.sh -o /tmp/install.sh
bash /tmp/install.sh
```

### 4.2 If You've Already Cloned

```bash
git clone https://github.com/kevinlee819/harness-donk.git
cd harness-donk
./install.sh
```

### 4.3 What the Installer Does

1. **Checks system dependencies**: `git` / `sqlite3 ≥ 3.35` / `jq` / `tmux` / `python3 ≥ 3.9` — any missing triggers an error telling you what to install.
2. **Checks for uv**: If missing, asks whether to install automatically using the official script.
3. **Locates source**: Local mode → uses your cloned directory; one-line install mode → automatically `git clone` to `$HOME/.harness/`.
4. **`uv sync`**: Installs Python dependencies to `.venv/` in the source directory.
5. **Entry point symlinks**: Symlinks `harness` and `harness-infi` to `$HOME/.local/bin/` (uv also installs there; if that directory is not in PATH, installer will ask whether to add it to your shell rc).
6. **`harness setup`**: Creates `~/.config/harness/` and writes default global config.

### 4.4 Installer Options

```bash
./install.sh --help              # see all options
./install.sh -y                  # skip all confirmations (common for CI / one-line installs)
./install.sh --prefix /opt/harness   # change source install directory (default $HOME/.harness)
./install.sh --bindir /usr/local/bin # change entry point symlink directory (default $HOME/.local/bin)
./install.sh --uninstall         # reverse: remove symlinks + shell rc lines + (optionally) source dir
```

### 4.5 Upgrading

```bash
harness upgrade
```

Equivalent to `bash $HOME/.harness/install.sh --upgrade`. Runs in sequence:

1. **Validates source state**: Uncommitted changes / local commits beyond upstream → refuses upgrade (prevents silently losing work).
2. **`git pull --ff-only`**: Accepts only fast-forward. Merge conflict probability = 0.
3. Prints all commit messages pulled (see at a glance what changed).
4. **`uv sync`**: Installs new dependencies, removes unneeded ones; Python env matches repo.
5. **Redo symlinks** (idempotent) + run `harness setup` once (also idempotent).

**Regarding running tasks**: The upgrade process does not touch `.harness/harness.db` or worker worktrees. Workers already running continue to completion using the old code; new tasks (first claim after upgrade) begin using new code. **To be safe, stop the `harness-infi` session before upgrading**:

```bash
tmux kill-session -t harness-<sha8>     # or :exit in the coordinator window
harness upgrade
harness-infi                            # restart
```

### 4.6 Uninstalling

```bash
bash $HOME/.harness/install.sh --uninstall
```

Asks at each step (without `--yes`, confirmation required for each):

1. Remove `$HOME/.local/bin/{harness,harness-infi}` symlinks.
2. Remove `# added by harness installer` marker lines from shell rc.
3. Ask whether to remove `$HOME/.harness/` source directory (includes `.venv/`).
4. Ask whether to remove `~/.config/harness/` (includes daily budget config and project registry).

**Not automatically removed**: `.harness/` and `AGENTS.md` in each project. These are project data — only you know whether to keep them. Manually `rm -rf <project>/.harness <project>/AGENTS.md` to fully clean up a project.

### 4.7 Directory Mental Model (Same as git)

- `$HOME/.harness/` is the tool itself, installed once, **never copied into any project**.
- Entry points `harness` / `harness-infi` live in `$HOME/.local/bin/` (uv also installs there; most modern systems already have this in PATH).
- Projects only contain declarative `AGENTS.md` / `.claude/settings.json` / `specs/` (in git) + runtime state `.harness/` (entirely gitignored).
- Upgrading harness = `harness upgrade`, and all onboarded projects immediately get the new version.

---

## 5. First-Time Configuration (Once Per Machine)

### 5.1 Environment Check

```bash
harness setup
```

Does two things:
1. Validates that sqlite3 / jq / git / tmux / python are installed and meet version requirements.
2. Creates `~/.config/harness/` and writes default configuration:

```ini
# ~/.config/harness/config
budget_daily_usd=10          # daily budget USD; new dispatches stop when exceeded
session_resume_cap=6         # same-session resume cap; opens new session at limit to prevent context drift
dead_worker_threshold_min=10 # transient state timeout treated as dead worker, automatically redispatched
blocked_timeout_hours=72     # BLOCKED task past this time → marked FAILED
```

These defaults are for personal happy-path use. Tune them after real long-running sessions.

### 5.2 Backend Self-Check

```bash
harness doctor
```

Makes one real echo call to each backend CLI found — **burns a small amount of real API money, within a few cents**. Only proceed once all backends show `✓ responded`. At least one ✓ is required to use harness.

---

## 6. Onboarding Your First Project

```bash
cd ~/code/my-project          # any directory — git init runs automatically if needed
harness init                  # default backend=claude, reviewer=codex
# or:
harness init --backend codex  # writer=codex automatically flips reviewer=claude
```

`init` runs an interactive wizard (skipped silently when there is no TTY):

- **Empty / brand-new project**: asks (1) what you want to build — saved to `specs/initial.md` — then (2) language/framework, which is used to auto-fill the gate commands.
- **Existing project with files**: detects project type (Python / Node / Go / Rust), proposes gate config, and asks "Does this look right? [Y/n]". Both paths let you override individual commands before anything is written.

What `init` sets up (runs once per new project):

1. Creates `.harness/` at the project root (containing queue, worker state, events, logs, etc.), added entirely to `.gitignore`.
2. Generates `AGENTS.md` at the project root with gate commands pre-filled from auto-detection, and the reviewer configured.
3. Symlinks `CLAUDE.md → AGENTS.md` (so Claude reads this too).
4. Installs security hooks into `.claude/settings.json`. If that file already exists, writes a `.harness-suggested` for you to merge manually.
5. Registers the project's absolute path in `~/.config/harness/projects.list` (idempotent).

### 6.1 Reviewing the Gate Configuration

`init` fills gate commands automatically during setup — review and adjust if needed. The YAML frontmatter at the top of `AGENTS.md` contains:

```yaml
---
gate:
  build: ""                       # build/type-check command
  lint: ""                        # static analysis command
  test: ""                        # test command
  diff_audit_paths_allowlist: []  # allowlist: worker may only touch files under these paths
  cross_review: true              # whether to run cross-model review
  cross_review_reviewer: codex    # reviewer backend (opposite of writer)
---
```

**The gate is harness's root of trust. The stricter these commands are, the more trustworthy the automation. Empty = no gate = the system is just letting workers declare themselves done, violating the design principles.**

What each field means:

| Field | Meaning | When to skip |
|-------|---------|-------------|
| `build` | Build or static type check. Any "code syntax/type/compile"-level check | Can be left empty if project has no build step, but **strongly recommended to have at least type checking** |
| `lint` | Style / static analysis | Can be left empty if project has no linter |
| `test` | **Required**. Automated test suite | Empty = no gate, strongly discouraged |
| `diff_audit_paths_allowlist` | List of path globs the worker is allowed to touch. Empty list = no restriction | Fill in when you want strict control over worker scope |
| `cross_review` | When true, runs cross-model review (has another LLM read the diff and find issues) | Set false to disable (saves money, but loses a layer of defense) |
| `cross_review_reviewer` | Reviewer backend: `claude` or `codex` | init automatically flips based on writer: claude writes → codex reviews |

### 6.2 Sample Gate Configuration for Different Languages

**Node / TypeScript**:
```yaml
gate:
  build: "tsc --noEmit"
  lint:  "pnpm lint"               # or npm run lint / eslint .
  test:  "pnpm test"
  cross_review: true
  cross_review_reviewer: codex
```

**Python**:
```yaml
gate:
  build: "mypy ."                  # or pyright
  lint:  "ruff check ."            # or flake8 / pylint
  test:  "pytest -q"
  cross_review: true
  cross_review_reviewer: codex
```

**Rust**:
```yaml
gate:
  build: "cargo check --all-targets"
  lint:  "cargo clippy -- -D warnings"
  test:  "cargo test"
  cross_review: true
  cross_review_reviewer: codex
```

**Go**:
```yaml
gate:
  build: "go vet ./..."
  lint:  "golangci-lint run"       # install separately; requires go ≥ 1.20
  test:  "go test ./..."
  cross_review: true
  cross_review_reviewer: codex
```

**bash / script repos** (like harness itself):
```yaml
gate:
  build: ""                        # no build
  lint:  "shellcheck $(find . -name '*.sh' -not -path './.venv/*')"
  test:  "bash tests/run.sh"
  cross_review: true
  cross_review_reviewer: codex
```

### 6.3 Manually Verify Gate Commands Pass on a Clean Branch

**The most important check — skip it and you'll keep hitting the same pitfalls**:

```bash
# at project root, make sure you're on a clean main branch
git status                       # should be clean

# run each gate command you configured
tsc --noEmit && pnpm lint && pnpm test      # use your actual commands

# all three must exit with code 0
echo "exit code: $?"             # should be 0
```

**Only when all gate commands exit 0 on a clean main branch** can harness use them as judges. If main branch itself fails lint/test, workers will fail even more after their changes, and the task will keep failing.

---

## 7. First Launch

```bash
harness-infi
```

What happens:
- tmux starts a session, cursor lands in window 0 (coordinator).
- window 0 is a Claude Code session with coordinator.md loaded as system prompt.
- window 1 is the background orchestrator daemon. `Ctrl-B 1` switches there to see it polling `queue empty`.
- window 2 is the watchdog daemon. `Ctrl-B 2` switches there to see its 10-minute tick output.

Try talking to the coordinator (in window 0):

```
You: Help me add a slugify function in src/utils/ that converts a string to a URL slug.
     Unit tests covering: empty string → ""; CJK → pinyin or dropped; consecutive spaces → single -.
```

It will ask you to confirm the spec, ask about concurrent dependencies, check your AGENTS.md gate config; once satisfied, it calls `harness-task add` to enqueue.

**After enqueueing you can**:
- Keep watching in tmux (`Ctrl-B 1` switches to window 1 to see orchestrator assign work to workers).
- Detach (`Ctrl-B d`) and do something else; everything continues running in the background.
- Wait for a notification (task complete / failed / needs decision).

`Ctrl-B 0` returns to coordinator; it will proactively report task status changes.

---

## 8. Daily Use: Three "Modes"

All three modes share the same coordinator session and the same `.harness/` ledger.

### 8.1 Conversation Mode (Exploration + Decomposition)

Usage: Just chat with the coordinator. "I want to do X, but I haven't thought through Y and Z" — the coordinator will ask until it can write down machine-verifiable acceptance criteria.

```
You: How should I implement login?
Coordinator: Let me ask a few questions to nail down the approach... (3-5 back-and-forth)
Coordinator: I'll break it into 3 tasks: T-jwt (middleware), T-login (endpoint), T-session (cookie/csrf).
             T-login depends on T-jwt. Should I enqueue?
You: Enqueue, T-jwt first.
```

### 8.2 Delegation Mode (Enqueue + Background Execution)

After the coordinator breaks things down, it calls `harness-task add`. You don't need to touch this command — but knowing it exists helps explain why the coordinator can't run code itself.

```bash
harness-task add [--id T-XXX] [--priority N] [--depends-on T-A,T-B]
                 [--spec specs/foo.md] [--backend codex]
                 # body via stdin, written to specs/<id>.md
```

After enqueueing you can close your laptop and go to dinner. The orchestrator polls in the background and runs at the right time.

### 8.3 Observation Mode (What's the Status)

Any time you ask "how's it going," the coordinator queries `harness status` and gives you a briefing. **You can also check yourself** (even outside the coordinator tmux):

```bash
# at project root
harness status                         # all tasks summary + pending events
harness status --task T-jwt            # single task details
harness status --task T-jwt --history  # includes state transition history

# live snapshot (workers are threads, not separate panes)
harness attach w1                      # see what w1 is currently doing
harness attach w1 --path               # print only the worktree path
cd $(harness attach w1 --path)         # go directly to the scene
git -C $(harness attach w1 --path) log --oneline   # see what the worker committed

# pending events (coordinator also actively pulls each round)
harness events pending
harness events ack <eid>...
```

### 8.4 Status Bar (Automatic, No Action Needed)

`harness init` writes a `statusLine` configuration to the project's `.claude/settings.json`, making the Claude Code coordinator session's **bottom status bar** refresh every 5 seconds:

```
🫏 W:2 Q:1 B:0 F:0 M:7 · $1.24/$10 · w2/4 · Opus 4.7
   │   │   │   │   │      │           │       │
   │   │   │   │   │      │           │       └─ current model
   │   │   │   │   │      │           └─ worker pool busy/total
   │   │   │   │   │      └─ today's cost / daily budget (>50% yellow, >90% red)
   │   │   │   │   └─ merged today
   │   │   │   └─ failed
   │   │   └─ blocked (red, alerts when present)
   │   └─ queued
   └─ working
```

Data source is `.harness/harness.db` (not Claude Code's own token statistics). So this status bar shows you **the task scheduling layer's state**, not the current conversation's token usage.

> Want to see Claude Code's native token / cache / weekly Sonnet/Opus breakdown? You can also install [ccstatusline](https://github.com/sirmalloc/ccstatusline), which is orthogonal to harness's status bar (but only one `statusLine.command` can be active at a time — choose one).

### 8.5 Transitions Between Modes

- Conversation → Delegation: The coordinator calls `harness-task add` directly; you don't need to re-enter the prompt.
- Delegation → Observation: You can check in anytime, or not at all and let it run to completion and notify you.
- Observation → Conversation: When a task is `FAILED`, the coordinator brings `.gate-report.json` and consults you on "redispatch / revise spec / abandon."

---

## 9. Command Quick Reference

### harness-infi (sole user entry point)

```bash
harness-infi                          # start coordinator + background orchestrator
harness-infi --backend codex          # use codex as main writer (reviewer auto-flips)
harness-infi --model claude-sonnet-4-6   # pass model through to adapter
harness-infi --no-attach              # create session without attaching (for scripts/CI)
```

### harness (management/observation)

```bash
harness init [--backend NAME]    # onboard current git repo
harness setup                    # environment check + create ~/.config/harness/
harness doctor                   # echo self-check for each backend (burns real API)
harness status [--task T-XXX [--history]]
harness events {pending|ack <eid>...}
harness attach                   # attach to coordinator tmux session
harness attach <wid> [--path]    # worker live snapshot (or just worktree path)
harness backup                   # sqlite3 .backup → .harness/backups/
harness run-once [--mock]        # run one orchestrator cycle then exit (for manual debugging)
harness statusline               # Claude Code status bar renderer (not called directly, see §8.4)
harness help
```

### Tools Used by the Coordinator

```bash
harness-task add [--id T-XXX] [--priority N] [--depends-on T-A,T-B]
                 [--spec specs/foo.md] [--backend codex]
harness-task query [--status QUEUED|WORKING|...|FAILED] [--task T-XXX] [--json]
harness-task history <task_id>
harness-task cancel  <task_id>
harness-task answer  <task_id> <text>   # reply to a BLOCKED task
```

---

## 10. Configuration File Hierarchy

### Global (One Per Machine)

`~/.config/harness/config`:

```ini
budget_daily_usd=10           # daily budget USD; accumulated excess stops new task dispatching
session_resume_cap=6          # same-session resume cap; forces new session at limit
dead_worker_threshold_min=10  # transient state + updated older than this → considered dead, redispatched
blocked_timeout_hours=72      # BLOCKED past this duration → FAILED + coordinator notified
```

`~/.config/harness/projects.list`: One project absolute path per line, auto-appended by `harness init` (idempotent). Used for future cross-project budget aggregation.

### Project-Level (One Per Project, in git)

`AGENTS.md` top frontmatter is gate config — this is your **primary tuning location** (see §6.1). Each task's spec can override project-level gate config using `reviewer:` / `cross_review:` frontmatter fields ([interfaces.md §5](interfaces.md)).

`.claude/settings.json` holds hooks (PreToolUse security gate + Notification routing). **Don't change it arbitrarily** — especially don't disable PreToolUse; that's harness's security baseline.

### Runtime (One Per Project, gitignored)

`.harness/`:

| Path | What it is | Who writes |
|------|-----------|-----------|
| `harness.db` | SQLite state store (queue / state machine / call ledger) | Orchestrator exclusive |
| `workers/<id>/status.json` | Worker's current state | That worker |
| `workers/<id>/guidance.json` | Written by worker when decision needed | That worker |
| `inbox/<id>.answer` | Your / coordinator's reply to a BLOCKED task | Human / coordinator |
| `events/*.json` | Pending events | Orchestrator |
| `logs/raw/*.json` | Raw JSON of each call (for debugging) | Adapter |
| `backups/` | Periodic database backups | `harness backup` |

---

## 11. Troubleshooting FAQ

### Q: `harness setup` reports sqlite3 < 3.35

The system's built-in sqlite3 may be too old. Install a newer one:
- macOS: `brew install sqlite` then put `/opt/homebrew/opt/sqlite/bin` before other PATH entries.
- Linux: Use your distro's sqlite3 ≥ 3.35 package; or build from source.

### Q: window 1 immediately shows `[exited]` after `harness-infi` starts

The orchestrator failed to start. `Ctrl-B 1` to switch there and see the error message (`remain-on-exit` option keeps the pane for debugging); the most common cause is the project hasn't been `harness init`-ed, or `.harness/harness.db` is corrupted.

If `harness backup` has been run, you can restore from `.harness/backups/`.

### Q: Task stuck at `dispatched` or `working` without progress

The worker may have crashed (process died but state wasn't rolled back). The orphan reaper scans by default every 10 minutes and automatically transitions back to `queued` for redispatch. Wait and check again.

To force immediate handling:
```bash
sqlite3 .harness/harness.db "UPDATE tasks SET updated='2020-01-01T00:00:00Z' WHERE id='T-XXX'"
```
The next reap cycle will pick it up (**only do this if you're certain the worker is truly dead**).

### Q: Gate keeps failing

```bash
cat .worktrees/<project>/<task_id>/.gate-report.json | jq .
```
Look for which step has `ok=false` and its `output`. Common causes:
- Gate command itself doesn't pass on a clean branch → fix AGENTS.md gate config (see §6.3).
- Flaky tests → fix the tests.
- Cross-model review rejection → look at the issues list in `output`.

### Q: Cross-model review always rejects

The reviewer defaults to the opposite of the writer (claude ↔ codex), which fits most cases. If a particular task's issues are actually inconsequential, you can disable it in the spec frontmatter:

```markdown
---
reviewer: codex
cross_review: false   # disable cross-review for this spec
---
```

Or change the reviewer:

```markdown
---
reviewer: claude     # force claude as judge, even if global config is codex
---
```

### Q: I want to see exactly what the coordinator said

`tmux attach -t harness-<sha8(pwd)>` to enter the session directly (`harness attach` also works); all conversation is in window 0's scroll history.

### Q: How do I stop things

- Single task: have the coordinator run `harness-task cancel <task_id>`.
- Entire session: `Ctrl-B d` just detaches (background orchestrator keeps running); to truly stop: `tmux kill-session -t harness-<sha8>`.
- Fully clean up a project: remove `.harness/` and `AGENTS.md` from the project root, delete that line from `~/.config/harness/projects.list`. Code stays intact; you can `harness init` again later.

### Q: Where do I see money spent

```bash
sqlite3 .harness/harness.db "SELECT date(ts), SUM(cost_usd) FROM calls GROUP BY date(ts) ORDER BY 1 DESC LIMIT 7"
```

Or run the daily budget check: `harness status` shows today's cumulative total at the top. Note that codex's `cost_usd` is currently NULL (the CLI doesn't expose a USD field, only token usage).

### Q: Notification icon is a grey plug, not a donkey

A known macOS `osascript` limitation (no app bundle). Install `terminal-notifier` to get the donk logo:
```bash
brew install terminal-notifier
```
No need to restart harness after installing; the next notification will automatically use it.

---

## 12. Next Steps

- Want to understand the architecture / why it's designed this way → [design.md](design.md)
- Want to onboard a new backend CLI (DeepSeek, OpenCode, etc.) → [adapter-contract.md](adapter-contract.md)
- Want to change JSON / SQL schema → [data-schemas.md](data-schemas.md)
- Want to develop in the repo → [CLAUDE.md](../CLAUDE.md) at the repo root + [development-plan.md](development-plan.md)

---

## 13. A "Minimum Viable Configuration" Checklist

Pre-launch self-check — for a project to truly "work with harness," all of the following should be satisfied:

- [ ] `harness setup` all ✓
- [ ] `harness doctor` at least one backend ✓
- [ ] Project root has `AGENTS.md`, gate block has `test` (at minimum) and `cross_review_reviewer` filled in
- [ ] Manually ran all gate commands (build/lint/test) on a clean main branch — all return 0
- [ ] `.claude/settings.json` has `pre_tool_use.sh` registered under PreToolUse
- [ ] After `harness-infi` starts, window 0 is the coordinator and window 1 is the orchestrator daemon polling (not `[exited]`)
- [ ] Have the coordinator dispatch a trivial task like "add hello.txt" — it runs to MERGED

Only when the last item is satisfied have you truly onboarded the project.
