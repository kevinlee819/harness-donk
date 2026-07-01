#!/usr/bin/env bash
# Claude Code adapter — 归一化 claude -p 调用
# 见 docs/interfaces.md §4, docs/adapter-contract.md, tmp/claude-doc.md
#
# 入参（环境变量）：
#   ADAPTER_TASK_FILE     必填，提示词文件
#   ADAPTER_WORKTREE      必填，工作目录
#   ADAPTER_SESSION_ID    可选 UUID，非空则 --resume
#   ADAPTER_MAX_TURNS     默认 20
#   ADAPTER_TIMEOUT       默认 900 秒
#   ADAPTER_LOG_DIR       原始输出落盘目录（可选）
#   ADAPTER_MODEL         传 claude --model
#   ADAPTER_SANDBOX       与 codex 对齐的语义信号：
#                           read-only → review 模式：白名单 Read/Grep/Glob、
#                                       --json-schema 强制结构化输出、
#                                       --no-session-persistence 不落盘、
#                                       --max-turns 4 收紧
#                           其它/未设 → 写模式：bypassPermissions（hooks 兜底）
#   HARNESS_MOCK_ADAPTER  非空 → 走 mock 路径（不调真 CLI）
#   HARNESS_ADAPTER_DRYRUN 非空 → 构造 args 后打印到 stdout（一行一个）+ exit 0，
#                         不实际调 claude。用于测试 flag 装配是否正确。
#
# 出参（stdout 单行 JSON）—— 与 codex.sh 同 schema：
#   {ok, session_id, result, num_turns, files_changed, error}

set -euo pipefail

ADAPTER_NAME="claude"

# capability bitmap
ADAPTER_CAP_SESSION_RESUME=1
ADAPTER_CAP_SESSION_ID_PROGRAMMATIC=1
ADAPTER_CAP_TOOL_PERMISSION=1
ADAPTER_PARALLEL_PER_WORKTREE=1

: "${ADAPTER_TASK_FILE:?ADAPTER_TASK_FILE required}"
: "${ADAPTER_WORKTREE:?ADAPTER_WORKTREE required}"
ADAPTER_SESSION_ID="${ADAPTER_SESSION_ID:-}"
ADAPTER_MAX_TURNS="${ADAPTER_MAX_TURNS:-20}"
ADAPTER_TIMEOUT="${ADAPTER_TIMEOUT:-900}"
ADAPTER_LOG_DIR="${ADAPTER_LOG_DIR:-}"
ADAPTER_TASK_ID="${ADAPTER_TASK_ID:-}"
ADAPTER_WORKER_ID="${ADAPTER_WORKER_ID:-}"
ADAPTER_WORKER_DIR="${ADAPTER_WORKER_DIR:-}"
ADAPTER_MODEL="${ADAPTER_MODEL:-}"
ADAPTER_SANDBOX="${ADAPTER_SANDBOX:-}"

[[ ! -f "$ADAPTER_TASK_FILE" ]] && { echo "task file not found: $ADAPTER_TASK_FILE" >&2; exit 1; }
[[ ! -d "$ADAPTER_WORKTREE" ]]  && { echo "worktree not found: $ADAPTER_WORKTREE" >&2; exit 1; }

cd "$ADAPTER_WORKTREE"

# 让 hooks 读到当前 worker 的 worktree 边界（影响 rm -rf 规则等）
export HARNESS_WORKTREE="$ADAPTER_WORKTREE"
# 让 worker 知道自己 worker 目录的绝对路径（用于写 guidance.json / status.json）
[[ -n "$ADAPTER_WORKER_DIR" ]] && export HARNESS_WORKER_DIR="$ADAPTER_WORKER_DIR"
[[ -n "$ADAPTER_TASK_ID" ]] && export HARNESS_TASK_ID="$ADAPTER_TASK_ID"

_count_files_changed() {
  # 数本 worker 分支自 main 分叉以来动过的文件。worker 在 worktree 内会 git commit，
  # 所以 `git diff HEAD` 在 commit 后归零；这里改取 base..HEAD（branch 视角全量改动）。
  local base
  for ref in main master; do
    if base=$(git merge-base HEAD "$ref" 2>/dev/null); then
      git diff --name-only "$base"..HEAD 2>/dev/null | wc -l | tr -d ' '
      return
    fi
  done
  git diff --name-only HEAD 2>/dev/null | wc -l | tr -d ' '
}

_log_raw() {
  local resp="$1"
  [[ -z "$ADAPTER_LOG_DIR" ]] && return 0
  mkdir -p "$ADAPTER_LOG_DIR"
  local ts_file; ts_file=$(date -u +%s)
  local tid="${ADAPTER_TASK_ID:-notask}"
  local fname="$ADAPTER_LOG_DIR/${ts_file}-${tid}-${ADAPTER_NAME}-$$.json"
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg backend "$ADAPTER_NAME" \
        --arg sid "$ADAPTER_SESSION_ID" \
        --arg tid "$ADAPTER_TASK_ID" \
        --arg wid "$ADAPTER_WORKER_ID" \
        --arg prompt_path "$ADAPTER_TASK_FILE" \
        --argjson max_turns "$ADAPTER_MAX_TURNS" \
        --argjson resp "$resp" \
    '{schema_version:1, ts:$ts, task_id:$tid, worker_id:$wid, backend:$backend,
      request:{prompt_path:$prompt_path, session_id:(if $sid=="" then null else $sid end), max_turns:$max_turns},
      response:$resp}' \
    > "$fname" 2>/dev/null || true
}

# Mock mode：不调真 CLI，只 touch 一个文件后返回成功
if [[ -n "${HARNESS_MOCK_ADAPTER:-}" ]]; then
  prompt=$(cat "$ADAPTER_TASK_FILE")
  fake_sid="${ADAPTER_SESSION_ID:-00000000-0000-0000-0000-000000000001}"

  # 测试钩子：HARNESS_MOCK_SLEEP_S=N 让 mock 在写文件前 sleep N 秒，
  # 给上层（如 kill -9 续跑测试）留出杀进程的窗口期。
  if [[ -n "${HARNESS_MOCK_SLEEP_S:-}" ]]; then
    sleep "$HARNESS_MOCK_SLEEP_S"
  fi

  # 测试钩子：HARNESS_MOCK_BLOCK=1 让 mock 写一份 blocking guidance.json，
  # 模拟 worker 需人工决策。要求 ADAPTER_WORKER_DIR 已传入。
  if [[ -n "${HARNESS_MOCK_BLOCK:-}" ]]; then
    : "${ADAPTER_WORKER_DIR:?ADAPTER_WORKER_DIR required for HARNESS_MOCK_BLOCK}"
    mkdir -p "$ADAPTER_WORKER_DIR"
    jq -n --arg tid "$ADAPTER_TASK_ID" \
          --arg q "${HARNESS_MOCK_BLOCK_QUESTION:-mock question: A or B?}" \
          --arg ctx "${HARNESS_MOCK_BLOCK_CONTEXT:-mock-block test context}" \
          --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{schema_version:1, blocking:true, task_id:$tid, question:$q, context:$ctx, created:$now}' \
      > "$ADAPTER_WORKER_DIR/guidance.json.tmp" \
      && mv "$ADAPTER_WORKER_DIR/guidance.json.tmp" "$ADAPTER_WORKER_DIR/guidance.json"
    jq -nc --arg sid "$fake_sid" \
      '{ok:true, session_id:$sid, result:"mock blocked", num_turns:1, files_changed:0, error:null}'
    exit 0
  fi

  # review-style mock：prompt 含 "REVIEW DIFF" → 返回 {approve, issues} JSON 作 result
  if grep -q "REVIEW DIFF" "$ADAPTER_TASK_FILE" 2>/dev/null; then
    review_result="${HARNESS_MOCK_REVIEW_RESULT:-}"
    [[ -z "$review_result" ]] && review_result='{"approve":true,"issues":[]}'
    jq -nc --arg sid "$fake_sid" --arg r "$review_result" \
      '{ok:true, session_id:$sid, result:$r, num_turns:1, files_changed:0, error:null}'
    exit 0
  fi

  # 常规 mock 行为：写一个 HELLO.txt（兼容单任务测试）。如需并行安全，
  # 设 HARNESS_MOCK_OUTPUT_FILE='HELLO-$ADAPTER_TASK_ID.txt' 让每个任务写到独立路径。
  output_file="${HARNESS_MOCK_OUTPUT_FILE:-HELLO.txt}"
  # 允许模板包含 $ADAPTER_TASK_ID 等 — 用 envsubst 风格的 eval（输入受控）
  output_file=$(eval "printf '%s' \"$output_file\"")
  echo "mock-adapter ran: $(echo "$prompt" | head -c 100)" > "$output_file"
  git add "$output_file" >/dev/null 2>&1 || true
  git -c user.email=mock@harness -c user.name=mock commit -m "mock: $(echo "$prompt" | head -c 50)" >/dev/null 2>&1 || true
  changed=$(_count_files_changed)
  jq -nc --arg sid "$fake_sid" --argjson fc "${changed:-0}" \
    '{ok:true, session_id:$sid, result:"mock done", num_turns:1, files_changed:$fc, error:null}'
  exit 0
fi

# 真实调用
# Dry-run 时跳过 CLI 存在性检查（测试可在无 claude 环境下跑）
[[ -z "${HARNESS_ADAPTER_DRYRUN:-}" ]] && {
  command -v claude >/dev/null 2>&1 || { echo "claude CLI not found" >&2; exit 1; }
}

# Write mode uses stream-json so the watch TUI can tail progress in real time;
# review mode stays on plain --output-format json (one-shot, no need to stream).
# Stream mode requires --verbose per Claude CLI's own error message.
if [[ "$ADAPTER_SANDBOX" == "read-only" && -z "$ADAPTER_SESSION_ID" ]]; then
  # Review 模式（read-only + 非 resume）：白名单只读工具 + 强制 JSON schema +
  # 不持久化 session。见 tmp/claude-doc.md §"CLI flags".
  _args=(--print --output-format json --max-turns "$ADAPTER_MAX_TURNS")
  _review_schema="${HARNESS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/schema/json/review-response.schema.json"
  _args+=(--tools "Read,Grep,Glob" --no-session-persistence)
  [[ -f "$_review_schema" ]] && _args+=(--json-schema "$(cat "$_review_schema")")
  _STREAM_MODE=0
else
  # 写模式：hooks 兜底（PreToolUse 安全门），bypassPermissions 让非交互调用
  # 不被工具权限弹窗卡住（CLAUDE.md §4.7 "硬约束放 hooks 不放提示词"）
  _args=(--print --output-format stream-json --verbose
         --max-turns "$ADAPTER_MAX_TURNS" --permission-mode bypassPermissions)
  _STREAM_MODE=1
fi

[[ -n "$ADAPTER_SESSION_ID" ]] && _args+=(--resume "$ADAPTER_SESSION_ID")
[[ -n "$ADAPTER_MODEL" ]]      && _args+=(--model "$ADAPTER_MODEL")

# Dry-run：打印构造好的 args 后 exit 0，不实际调 claude。用于测试 flag 装配。
if [[ -n "${HARNESS_ADAPTER_DRYRUN:-}" ]]; then
  printf '%s\n' "${_args[@]}"
  exit 0
fi

start_ms=$(python3 -c 'import time;print(int(time.time()*1000))')

# In stream mode we redirect stdout to the worker's events file so the watch
# TUI can tail it live; then extract the terminal `type=result` event as our
# canonical response for the rest of the parsing logic (unchanged).
# Non-stream (review) mode captures stdout into RESP directly, as before.
set +e
if [[ "${_STREAM_MODE:-0}" == "1" && -n "$ADAPTER_WORKER_DIR" ]]; then
  mkdir -p "$ADAPTER_WORKER_DIR"
  _events_file="$ADAPTER_WORKER_DIR/claude.events.jsonl"
  : > "$_events_file"   # truncate stale data from a prior attempt
  timeout "$ADAPTER_TIMEOUT" claude "${_args[@]}" < "$ADAPTER_TASK_FILE" \
    > "$_events_file" 2>"$ADAPTER_WORKTREE/.adapter.stderr"
  EXIT=$?
  # The `result` event carries session_id / result / num_turns / usage; that's
  # what the parser below expects as a single JSON object.
  RESP=$(jq -c 'select(.type == "result")' "$_events_file" 2>/dev/null | tail -1)
else
  RESP=$(timeout "$ADAPTER_TIMEOUT" claude "${_args[@]}" < "$ADAPTER_TASK_FILE" 2>"$ADAPTER_WORKTREE/.adapter.stderr")
  EXIT=$?
fi
set -e

end_ms=$(python3 -c 'import time;print(int(time.time()*1000))')
duration=$((end_ms - start_ms))

# 即使失败也写日志
if ! printf '%s' "$RESP" | jq -e . >/dev/null 2>&1; then
  # 非合法 JSON — 包一层
  RESP=$(jq -nc --arg raw "$RESP" --arg err "non_json_or_empty" '{is_error:true, error:$err, raw:$raw}')
fi
_log_raw "$RESP"

IS_ERR=$(printf '%s' "$RESP" | jq -r '.is_error // false' 2>/dev/null || echo true)
if [[ "$IS_ERR" == "true" || $EXIT -ne 0 ]]; then
  err=$(printf '%s' "$RESP" | jq -r '.error // .raw // "exit_'"$EXIT"'"' | head -c 500)
  sid=$(printf '%s' "$RESP" | jq -r '.session_id // ""')
  jq -nc --arg sid "$sid" --arg err "$err" \
    '{ok:false, session_id:(if $sid=="" then null else $sid end), result:"", num_turns:null, files_changed:0, error:$err}'
  exit 0
fi

sid=$(printf '%s' "$RESP" | jq -r '.session_id // ""')
result=$(printf '%s' "$RESP" | jq -r '.result // ""')
turns=$(printf '%s' "$RESP" | jq -r '.num_turns // null')

changed=$(_count_files_changed)

jq -nc --arg sid "$sid" --arg result "$result" \
       --argjson turns "${turns:-null}" --argjson fc "${changed:-0}" \
       --argjson dur "$duration" \
  '{ok:true, session_id:$sid, result:$result, num_turns:$turns, files_changed:$fc, duration_ms:$dur, error:null}'
