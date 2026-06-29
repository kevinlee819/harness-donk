# Git Workflow

Git usage conventions for this repository. **Applies to this tool repository itself (`~/tools/harness/`), not to user projects managed by harness**.

> Historical note: The project initially wasn't managed by git (an oversight); the first formal commit was made during backfill on 2026-06-25. All subsequent development strictly follows this workflow.

## 1. When to Commit

**Commit after each logical unit is complete** — don't batch them up. Criteria:

- A feature from requirement to passing tests — one unit
- A refactor (e.g. "migrate db.sh to db.py") — one unit
- A document (e.g. "write coordinator.md") — one unit
- "Got halfway through, leaving it for tomorrow" — NOT a unit; either finish it or stash it
- "Fixed 10 typos + added a feature" — TWO units; split them

Rule of thumb: a typical session should have 2–5 commits. One giant commit per session is an anti-pattern.

**Absolute hard rules**:

1. **No commits when tests are red** (unless explicitly marked WIP on a local branch)
2. **No committing secrets / .env / API keys** (already covered by gitignore, but eyeball `git add` each time)
3. **No committing `.venv/` / `__pycache__/` / backup files** (already covered by gitignore)

## 2. Commit Message Format

```
<type>: <summary under 50 chars>

<blank line>

<body: why this change was made, what was done, external impact>

<blank line (optional)>

<trailer: test results / breaking change notes / Co-Authored-By>
```

### 2.1 Type Vocabulary

| type | Purpose | Example |
|------|---------|---------|
| `feat` | new feature | `feat: add lib/notify.sh + events table writes` |
| `fix` | bug fix | `fix: bash ${3:-{}} parsing inflates payload with extra }` |
| `refactor` | rewrite without changing external behavior | `refactor: replace lib/db.sh with src/harness/db.py` |
| `test` | add/change tests | `test: cover event_write JSON round-trip` |
| `docs` | documentation | `docs: write coordinator.md system prompt` |
| `chore` | tooling / config / dependencies | `chore: add uv.lock, switch to .venv-managed python` |
| `revert` | revert a previous commit | `revert: revert "feat: add foo"` |

**Prohibited**: `update`, `misc`, `stuff`, `WIP` (except on local branches). Every commit should describe in one sentence what was done.

### 2.2 Summary Line (First Line)

- Under 50 characters (including type)
- Imperative mood, lowercase start (`add` not `Adds` / `Added`)
- No trailing period
- Be specific: `feat: add harness backup` is better than `feat: add backup feature`

### 2.3 Body

The body explains **why**, not **what** — the `git show` diff already shows what.

Template:

```
<problem / motivation>.
<approach taken / key decisions>.
<external impact: API changes / config changes / test count added>.
```

Example:

```
fix: adapter blocked by claude default permission mode in --print

Real Claude smoke test (T-hello1) hit error_max_turns after 12 turns
of Write/Bash denials. permission_denials in raw log show every file
write rejected. Default permission mode in --print is not configured
to auto-accept edits, and there's no interactive prompt to grant.

Add --permission-mode bypassPermissions to adapter args. Safe because:
worker runs in isolated worktree + pre_tool_use hook is the real
safety floor (CLAUDE.md §4.7 — hard constraints live in hooks).

Also export HARNESS_WORKTREE so hook rule 2 (rm -rf outside worktree)
can resolve the boundary.

Verified: T-hello1 now completes in 3 turns / 12.5s / $0.006.
70/70 mock tests still green.
```

### 2.4 Trailer Signature

Every Claude-authored commit ends with:

```
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

> Already part of Claude Code's default commit behavior; leave a blank line before it at the end of the body.

## 3. What Not to Commit

- `.venv/`, `__pycache__/`, `*.pyc`, `.pytest_cache/` (already gitignored)
- `.harness/`, `.worktrees/`, runtime artifacts (in user projects; the tool repo doesn't usually have these)
- Backups `.bak`, `*.orig`, editor temp files `.swp`, `*~`
- Any file containing API keys / tokens / private keys
- Large binaries (>5MB per file needs review)

**Counterintuitive exception**: `uv.lock` MUST be in git (CLAUDE.md §8.3). This is correct despite feeling backwards — lock files are meant to lock.

## 4. Branching Strategy

**Current (solo MVP phase)**:

- Commit directly to `main`; no feature branches
- For experiments requiring multiple commits, use `git stash` or a temporary `wip/<topic>` branch; merge back to `main` when done

**Future (after collaboration or going public)**:

- `main` only accepts PRs
- Feature branch naming: `feat/<topic>` / `fix/<topic>`
- At least self-review the diff before merging

## 5. Relationship with Projects Managed by harness

**Be alert**: This repo (`~/tools/harness/`) and user projects managed by harness are both git repositories — **never confuse them**:

| Repository | Main branch | Where workers write |
|-----------|------------|-------------------|
| This tool repo | `main` (Claude commits directly) | N/A |
| Managed user project | project's own main branch | worker's worktree → orchestrator merge |

**Prohibitions**:

- Code changes to the tool itself **must never** go through the worker → orchestrator path. Claude is just a regular developer in this repo; commits directly with `git commit`.
- Code changes inside a user project **must never** have the coordinator directly `git commit` to main. That is the worker + orchestrator's responsibility.

## 6. Prohibited Dangerous Operations

Without explicit user authorization, never:

- `git push --force` / `--force-with-lease` (hooks already block this in user projects; this repo relies on discipline)
- `git reset --hard` to a commit older than the current HEAD
- `git commit --amend` on already-pushed commits
- `git rebase -i` to modify history
- `git clean -fd` without reading `git status` first
- `--no-verify` to skip pre-commit hooks
- Delete a branch without checking `git log <branch>`

When any of the above is needed, **stop and ask the user first**.

## 7. Pre-Commit Self-Check

Answer four questions before every `git add`:

1. **Tests pass?** `bash tests/run.sh` all green.
2. **Diff is clean?** `git diff --staged` readable at a glance, no unrelated changes.
3. **TODO.md updated?** Completed items checked off; otherwise you'll redo them next time.
4. **Does the commit message explain "why"?** If not, rewrite the message.

## 8. Pushing

**No remote pushes during MVP phase.** The repo lives locally at `~/tools/harness/.git/`.

Remote push arrangements to be decided separately in the future (GitHub / GitLab / private). Until then `git push` is unavailable — and unnecessary.

## 9. Tool Repo `.gitignore`

Current coverage ([/.gitignore](../.gitignore)):

```
.venv/
__pycache__/
*.pyc
*.pyo
.pytest_cache/
.ruff_cache/
.mypy_cache/
*.egg-info/
build/
dist/
```

Update in sync when new dependencies are added.

---

**Bottom line**: Version control is not post-hoc housekeeping — it's part of development. Every commit is a reversible, explainable checkpoint.
