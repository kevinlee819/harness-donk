# Adapter Contract: Onboarding a New Backend

This document defines the contract for connecting a new CLI (or a new model connected via a compatible endpoint) to the harness execution plane.

**Two axes — do not confuse them**:

- **New models** (DeepSeek, Kimi, Qwen, etc.) usually ≠ a new CLI. Preferred approach: connect to existing multi-provider CLIs via OpenAI/Anthropic compatible endpoints (OpenCode is preferred: add baseURL + key + model name to provider config). **harness and adapter need zero changes**; specify `backend: opencode, model: <name>` in the spec.
- **New CLI** (standalone tool, e.g. Aider, Continue CLI, custom agent runner) requires going through the adapter onboarding contract in this document.

---

## 1. Hard Requirements (All Three Required — Missing Any Means No Onboard)

| Capability | Verification | If Missing |
|-----------|-------------|-----------|
| 1. Non-interactive mode | Pipe call without TTY `cli <cmd> < prompt.txt > out` completes and exits | **Not onboarded** |
| 2. Exit code semantics | Success 0, failure non-zero | **Not onboarded** (if output can determine success/failure but code is inconsistent, can downgrade with PR review) |
| 3. Parseable output | `--json` single object or NDJSON event stream | **Not onboarded** (no structured output = not machine-readable) |

---

## 2. Soft Requirements (Missing → Capability Bitmap Downgrade)

| Capability | Verification | Downgrade |
|-----------|-------------|----------|
| 4. Session resumption | `--resume <id>` / `--session <id>` / `--last`; ID obtainable programmatically | Single-shot tasks only; resend full context after BLOCKED |
| 5. Tool permission control | allowlist / sandbox / approval mode | Rely only on worktree isolation + gate backstop; **no sensitive repos** |

Each backend declares its capability bitmap at the top of `adapters/<name>.sh`:

```bash
# capability bitmap
ADAPTER_CAP_SESSION_RESUME=1
ADAPTER_CAP_SESSION_ID_PROGRAMMATIC=1    # Claude / Codex 0.142+ / OpenCode: 1
ADAPTER_CAP_TOOL_PERMISSION=1
ADAPTER_PARALLEL_PER_WORKTREE=0          # Codex: 0 (git index race; must be serial)
```

The orchestrator uses this to restrict dispatchable task types and decide whether to add flock.

**Cost tracking removed** (2026-07-01). Adapters no longer emit a `cost_usd` field
and there is no budget gate. Providers' own consoles (Anthropic / OpenAI) are
authoritative — see [getting-started.md §11](getting-started.md#q-where-do-i-see-money-spent).

---

## 3. Normalization the Adapter Must Do

An adapter is a bash script; **sole entry point** `adapters/<name>.sh`; **interface** see [interfaces.md §4](interfaces.md#4-backend-adapters-m4--adapter-contract). This section focuses on implementation-side requirements.

### 3.1 Input Constraints

- Prompts are read from file only: `cat "$ADAPTER_TASK_FILE"`.
- **Prohibited**: inlining prompt content into the command line (quotes/`$`/backticks/newlines will break it).
- Resumption: `ADAPTER_SESSION_ID` non-empty → add `--resume "$SID"` (or backend equivalent); empty → first call.
- Dual limits: outer `timeout "$ADAPTER_TIMEOUT"` wrapping the entire CLI call; CLI inner `--max-turns "$ADAPTER_MAX_TURNS"` (or equivalent).

### 3.2 Output Normalization

Regardless of the backend's native output format, the adapter must output **single-line JSON** on stdout:

```json
{
  "ok": true|false,
  "session_id": "string|null",
  "result": "string (natural language summary, for humans/debugging only)",
  "num_turns": 0,
  "files_changed": 0,
  "error": null|"string"
}
```

- When `ok=false`, `error` must be filled with a brief failure description (e.g. "rate_limited" / "context_window_exceeded" / "tool_denied").
- `num_turns` can be `null` if the backend doesn't report it.
- `files_changed` is obtained by the adapter running `git diff --name-only HEAD | wc -l` in the working directory (adapter provides this fallback, not relying on the backend).

### 3.3 Side Effects

| Required | Notes |
|---------|-------|
| Write raw output to disk | `<project>/.harness/logs/raw/<ts>-<task_id>-<backend>-<seq>.json` with envelope (see [data-schemas.md §5](data-schemas.md#5-call-logs-logsraw)) |
| Error-first parsing | After parsing output, **check `.is_error` / `.error` before using `.result`** — failures are often still valid JSON |
| Stderr doesn't pollute stdout | Debug info all goes to stderr; stdout must have **only that one line of JSON** |
| flock (if needed) | Backends with `ADAPTER_PARALLEL_PER_WORKTREE=0` use flock on `$ADAPTER_WORKTREE/.adapter.lock` to serialize same-worktree calls |

---

## 4. Onboarding Process (Typical 4 Hours)

### 4.1 Write `adapters/<name>.sh` Skeleton

```bash
#!/usr/bin/env bash
set -euo pipefail

ADAPTER_CAP_SESSION_RESUME=1
ADAPTER_CAP_SESSION_ID_PROGRAMMATIC=1
ADAPTER_CAP_TOOL_PERMISSION=1
ADAPTER_PARALLEL_PER_WORKTREE=1

: "${ADAPTER_TASK_FILE:?}"
: "${ADAPTER_WORKTREE:?}"
ADAPTER_SESSION_ID="${ADAPTER_SESSION_ID:-}"
ADAPTER_MAX_TURNS="${ADAPTER_MAX_TURNS:-12}"
ADAPTER_TIMEOUT="${ADAPTER_TIMEOUT:-900}"

cd "$ADAPTER_WORKTREE"

# flock if needed
[[ "$ADAPTER_PARALLEL_PER_WORKTREE" == "0" ]] && exec 9>.adapter.lock && flock 9

# call backend
if [[ -n "$ADAPTER_SESSION_ID" ]]; then
  RESP=$(timeout "$ADAPTER_TIMEOUT" \
    your_cli --resume "$ADAPTER_SESSION_ID" --max-turns "$ADAPTER_MAX_TURNS" \
             --json < "$ADAPTER_TASK_FILE" 2>"$ADAPTER_WORKTREE/.adapter.stderr")
else
  RESP=$(timeout "$ADAPTER_TIMEOUT" \
    your_cli --max-turns "$ADAPTER_MAX_TURNS" --json < "$ADAPTER_TASK_FILE" \
             2>"$ADAPTER_WORKTREE/.adapter.stderr")
fi
EXIT=$?

# write raw output to disk
TS=$(date -u +%Y%m%dT%H%M%SZ)
LOG_DIR="$(git rev-parse --show-toplevel)/../.harness/logs/raw"  # adjust to actual path
mkdir -p "$LOG_DIR"
jq -n --arg ts "$TS" --argjson resp "$RESP" \
  '{schema_version:1, ts:$ts, backend:"<name>", response:$resp}' \
  > "$LOG_DIR/$TS-<...>.json"

# error-first
IS_ERR=$(echo "$RESP" | jq -r '.is_error // false')
if [[ "$IS_ERR" == "true" || $EXIT -ne 0 ]]; then
  echo "$RESP" | jq -c '{ok:false, session_id:.session_id, result:"", \
    num_turns:null, files_changed:0, error:(.error // "exit_'"$EXIT"'")}'
  exit 0
fi

FILES_CHANGED=$(git diff --name-only HEAD 2>/dev/null | wc -l | tr -d ' ')

echo "$RESP" | jq -c --argjson fc "$FILES_CHANGED" \
  '{ok:true, session_id:.session_id, result:.result, \
    num_turns:.num_turns, files_changed:$fc, error:null}'
```

### 4.2 Self-Check — Add This Backend to `harness doctor`

```bash
# tests/integration/adapter_<name>_doctor.sh
echo "say hello in 5 words" > /tmp/p.txt
ADAPTER_TASK_FILE=/tmp/p.txt ADAPTER_WORKTREE=/tmp ADAPTER_TIMEOUT=60 \
  bash adapters/<name>.sh | jq -e '.ok == true and (.result | length > 0)'
```

### 4.3 Cross-Model Review Smoke Test (If Capability Allows)

```bash
# intentionally buggy diff
git diff HEAD > /tmp/diff.patch
echo "Review this diff. Output JSON {approve: bool, issues: [...]}." | \
  cat - /tmp/diff.patch > /tmp/p.txt
ADAPTER_TASK_FILE=/tmp/p.txt ADAPTER_WORKTREE=/tmp/wt bash adapters/<name>.sh \
  | jq -r .result | jq -e '.approve | type == "boolean"'
```

If this passes, the backend can be listed as a reviewer candidate in `AGENTS.md`'s `gate.cross_review.reviewer`.

---

## 5. Data Boundaries

When onboarding third-party / offshore models, evaluate:

- By default, **only use with open-source and data-classification-permitted projects**.
- `<project>/AGENTS.md` must explicitly list the allowed backend/model whitelist; the gate's `diff_audit` step enforces that the task spec's `backend` field is in the whitelist.
- Repos containing PII / internal secrets: whitelist only local or same-trust-domain backends.

---

## 6. Already-Onboarded Reference

| Backend | Adapter | Capability Bitmap Highlights | Known Issues |
|---------|---------|----------------------------|-------------|
| Claude Code | `claude.sh` | All ✓ | UUID must be valid format; review mode (ADAPTER_SANDBOX=read-only) uses `--tools "Read,Grep,Glob" --no-session-persistence --json-schema <schema>`; write mode requires `--permission-mode bypassPermissions` (non-interactive will hang on permission prompts) |
| Codex | `codex.sh` | `COST_REPORT=0`, `PARALLEL_PER_WORKTREE=0` | mkdir lock + thread_id obtained from thread.started event (0.142+); NDJSON needs aggregation; `-C` must come before `resume` subcommand; `-a` cannot be passed to exec (headless defaults to Never); **never** use `--dangerously-bypass-approvals-and-sandbox` (forces DangerFullAccess, overrides `-s`) |
| OpenCode | `opencode.sh` | All ✓ | Use `opencode run` CLI path; **avoid** serve mode (historical sub-agent hang issue) |

After completing a new onboarding, add a row to this table and submit a PR.
