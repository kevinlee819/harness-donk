#!/usr/bin/env bash
# Codex CLI adapter — codex exec --json 归一化
# 见 docs/interfaces.md §4, docs/adapter-contract.md, CLAUDE.md §4.6
#
# 入参（环境变量）— 与 claude.sh 对齐：
#   ADAPTER_TASK_FILE     必填，提示词文件
#   ADAPTER_WORKTREE      必填，工作目录
#   ADAPTER_SESSION_ID    无意义（codex 不暴露 session id）；非空触发 --last resume
#   ADAPTER_MAX_TURNS     默认 12（codex 自身没有 turn cap，这里仅记录）
#   ADAPTER_TIMEOUT       默认 900
#   ADAPTER_LOG_DIR       原始 JSONL 落盘
#   ADAPTER_TASK_ID / ADAPTER_WORKER_ID / ADAPTER_WORKER_DIR
#   ADAPTER_MODEL         传 codex -m
#   ADAPTER_SANDBOX       read-only / workspace-write / danger-full-access
#                         默认 workspace-write；review 模式调用方应传 read-only
#   HARNESS_MOCK_ADAPTER  非空 → mock
#
# 出参（stdout 单行 JSON）—— 与 claude.sh 同 schema：
#   {ok, session_id, result, cost_usd, num_turns, files_changed, duration_ms, error}
#
# 串行约束（CLAUDE.md §4.6）：同一 worktree 同时最多一个 codex 进程。
# 用 mkdir 原子互斥（macOS 无 flock）。

set -uo pipefail

ADAPTER_NAME="codex"

# capability bitmap
ADAPTER_CAP_SESSION_RESUME=1                   # 经 codex exec resume --last
ADAPTER_CAP_SESSION_ID_PROGRAMMATIC=0          # 不能拿到 session id
ADAPTER_CAP_TOOL_PERMISSION=1
ADAPTER_CAP_COST_REPORT=0                      # JSON 里只有 token 用量，没 USD
ADAPTER_PARALLEL_PER_WORKTREE=0                # 必须串行

: "${ADAPTER_TASK_FILE:?ADAPTER_TASK_FILE required}"
: "${ADAPTER_WORKTREE:?ADAPTER_WORKTREE required}"
ADAPTER_SESSION_ID="${ADAPTER_SESSION_ID:-}"
ADAPTER_MAX_TURNS="${ADAPTER_MAX_TURNS:-12}"
ADAPTER_TIMEOUT="${ADAPTER_TIMEOUT:-900}"
ADAPTER_LOG_DIR="${ADAPTER_LOG_DIR:-}"
ADAPTER_TASK_ID="${ADAPTER_TASK_ID:-}"
ADAPTER_WORKER_ID="${ADAPTER_WORKER_ID:-}"
ADAPTER_WORKER_DIR="${ADAPTER_WORKER_DIR:-}"
ADAPTER_MODEL="${ADAPTER_MODEL:-}"
ADAPTER_SANDBOX="${ADAPTER_SANDBOX:-workspace-write}"

[[ ! -f "$ADAPTER_TASK_FILE" ]] && { echo "task file not found: $ADAPTER_TASK_FILE" >&2; exit 1; }
[[ ! -d "$ADAPTER_WORKTREE" ]]  && { echo "worktree not found: $ADAPTER_WORKTREE" >&2; exit 1; }

cd "$ADAPTER_WORKTREE"
export HARNESS_WORKTREE="$ADAPTER_WORKTREE"
[[ -n "$ADAPTER_WORKER_DIR" ]] && export HARNESS_WORKER_DIR="$ADAPTER_WORKER_DIR"
[[ -n "$ADAPTER_TASK_ID" ]] && export HARNESS_TASK_ID="$ADAPTER_TASK_ID"

_count_files_changed() {
  git diff --name-only HEAD 2>/dev/null | wc -l | tr -d ' '
}

# ── 串行锁（mkdir-based）─────────────────────────────────────
LOCKDIR="$ADAPTER_WORKTREE/.codex.lock"
LOCK_TIMEOUT_S=120

_acquire_lock() {
  local elapsed=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    if [[ $elapsed -ge $LOCK_TIMEOUT_S ]]; then
      echo "codex adapter: lock timeout after ${LOCK_TIMEOUT_S}s on $LOCKDIR" >&2
      return 2
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

_release_lock() { rmdir "$LOCKDIR" 2>/dev/null || true; }

trap _release_lock EXIT INT TERM

_log_raw() {
  local raw_lines="$1" final="$2"
  [[ -z "$ADAPTER_LOG_DIR" ]] && return 0
  mkdir -p "$ADAPTER_LOG_DIR"
  local ts_file; ts_file=$(date -u +%s)
  local tid="${ADAPTER_TASK_ID:-notask}"
  local fname="$ADAPTER_LOG_DIR/${ts_file}-${tid}-${ADAPTER_NAME}-$$.json"
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg backend "$ADAPTER_NAME" \
        --arg tid "$ADAPTER_TASK_ID" \
        --arg wid "$ADAPTER_WORKER_ID" \
        --arg prompt_path "$ADAPTER_TASK_FILE" \
        --argjson max_turns "$ADAPTER_MAX_TURNS" \
        --arg events "$raw_lines" \
        --argjson final "$final" \
    '{schema_version:1, ts:$ts, task_id:$tid, worker_id:$wid, backend:$backend,
      request:{prompt_path:$prompt_path, resume:('"$([[ -n "$ADAPTER_SESSION_ID" ]] && echo true || echo false)"'), max_turns:$max_turns},
      response:{events_jsonl:$events, final:$final}}' \
    > "$fname" 2>/dev/null || true
}

# ── Mock 模式 ─────────────────────────────────────────────
if [[ -n "${HARNESS_MOCK_ADAPTER:-}" ]]; then
  _acquire_lock || exit 2
  prompt=$(cat "$ADAPTER_TASK_FILE")
  fake_sid="codex-mock-$(date +%s)"

  # 复用 mock blocking 钩子，给 cross-model 风格的 mock 也留可观测面
  if [[ -n "${HARNESS_MOCK_BLOCK:-}" ]]; then
    : "${ADAPTER_WORKER_DIR:?ADAPTER_WORKER_DIR required for HARNESS_MOCK_BLOCK}"
    mkdir -p "$ADAPTER_WORKER_DIR"
    jq -n --arg tid "$ADAPTER_TASK_ID" \
          --arg q "${HARNESS_MOCK_BLOCK_QUESTION:-mock-codex question}" \
          --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{schema_version:1, blocking:true, task_id:$tid, question:$q, context:"mock", created:$now}' \
      > "$ADAPTER_WORKER_DIR/guidance.json.tmp" \
      && mv "$ADAPTER_WORKER_DIR/guidance.json.tmp" "$ADAPTER_WORKER_DIR/guidance.json"
    jq -nc --arg sid "$fake_sid" \
      '{ok:true, session_id:$sid, result:"mock blocked", cost_usd:null, num_turns:1, files_changed:0, error:null}'
    exit 0
  fi

  # review-style mock：若 prompt 包含 "REVIEW DIFF"，返回 {approve, issues} 风格 result
  if grep -q "REVIEW DIFF" "$ADAPTER_TASK_FILE" 2>/dev/null; then
    review_result="${HARNESS_MOCK_REVIEW_RESULT:-}"
    [[ -z "$review_result" ]] && review_result='{"approve":true,"issues":[]}'
    jq -nc --arg sid "$fake_sid" --arg r "$review_result" \
      '{ok:true, session_id:$sid, result:$r, cost_usd:null, num_turns:1, files_changed:0, error:null}'
    exit 0
  fi

  # 常规 mock：在 worktree 写 CODEX.txt + commit
  echo "codex-mock-adapter ran: $(echo "$prompt" | head -c 100)" > CODEX.txt
  git add CODEX.txt >/dev/null 2>&1 || true
  git -c user.email=mock@harness -c user.name=mock-codex \
      commit -m "mock-codex: $(echo "$prompt" | head -c 50)" >/dev/null 2>&1 || true
  changed=$(_count_files_changed)
  jq -nc --arg sid "$fake_sid" --argjson fc "${changed:-0}" \
    '{ok:true, session_id:$sid, result:"mock-codex done", cost_usd:null, num_turns:1, files_changed:$fc, error:null}'
  exit 0
fi

# ── 真实调用 ─────────────────────────────────────────────
command -v codex >/dev/null 2>&1 || { echo "codex CLI not found" >&2; exit 1; }

_acquire_lock || exit 2

LAST_MSG=$(mktemp -t codex-last.XXXXXX)
EVENTS=$(mktemp -t codex-events.XXXXXX)
trap '_release_lock; rm -f "$LAST_MSG" "$EVENTS"' EXIT INT TERM

# 构造命令。Codex exec 默认在 -C 工作目录里跑。
# resume 时 --last 接最近的会话（按 cwd 索引）。
_args=(exec --json -C "$ADAPTER_WORKTREE" -s "$ADAPTER_SANDBOX"
       --dangerously-bypass-approvals-and-sandbox -o "$LAST_MSG"
       --skip-git-repo-check)
[[ -n "$ADAPTER_MODEL" ]] && _args+=(-m "$ADAPTER_MODEL")

# resume：把 exec 改成 exec resume --last
if [[ -n "$ADAPTER_SESSION_ID" ]]; then
  _args=(exec resume --last -C "$ADAPTER_WORKTREE" --json -s "$ADAPTER_SANDBOX"
         --dangerously-bypass-approvals-and-sandbox -o "$LAST_MSG"
         --skip-git-repo-check)
  [[ -n "$ADAPTER_MODEL" ]] && _args+=(-m "$ADAPTER_MODEL")
fi

start_ms=$(python3 -c 'import time;print(int(time.time()*1000))')

set +e
timeout "$ADAPTER_TIMEOUT" codex "${_args[@]}" < "$ADAPTER_TASK_FILE" > "$EVENTS" 2>"$ADAPTER_WORKTREE/.adapter.stderr"
EXIT=$?
set -e

end_ms=$(python3 -c 'import time;print(int(time.time()*1000))')
duration=$((end_ms - start_ms))

# 解析 JSONL：抓 turn.completed 数、最后 agent_message、thread_id
turns=$(grep -c '"type":"turn.completed"' "$EVENTS" 2>/dev/null || echo 0)
thread_id=$(jq -r 'select(.type=="thread.started") | .thread_id' "$EVENTS" 2>/dev/null | head -1)
[[ -z "$thread_id" || "$thread_id" == "null" ]] && thread_id=""

# 取最后一条 agent_message 文本
final_text=$(jq -r 'select(.type=="item.completed" and .item.type=="agent_message") | .item.text' \
             "$EVENTS" 2>/dev/null | tail -1)
# 兜底：用 -o 文件
if [[ -z "$final_text" && -f "$LAST_MSG" ]]; then
  final_text=$(cat "$LAST_MSG")
fi

# 落原始 JSONL（用换行符压一行 string 存）
raw_lines=$(jq -Rs . < "$EVENTS" 2>/dev/null || echo '""')
final_json=$(jq -nc --arg t "$final_text" --arg tid "$thread_id" --argjson turns "${turns:-0}" \
  '{result:$t, thread_id:$tid, num_turns:$turns}')
_log_raw "$raw_lines" "$final_json"

if [[ $EXIT -ne 0 ]]; then
  err_msg=$(tail -c 500 "$ADAPTER_WORKTREE/.adapter.stderr" 2>/dev/null | tr -d '\0')
  [[ -z "$err_msg" ]] && err_msg="codex exit_$EXIT"
  jq -nc --arg err "$err_msg" --arg sid "$thread_id" --argjson dur "$duration" \
    '{ok:false, session_id:(if $sid=="" then null else $sid end), result:"",
      cost_usd:null, num_turns:null, files_changed:0, duration_ms:$dur, error:$err}'
  exit 0
fi

changed=$(_count_files_changed)
jq -nc --arg sid "$thread_id" --arg r "$final_text" --argjson turns "${turns:-0}" \
       --argjson fc "${changed:-0}" --argjson dur "$duration" \
  '{ok:true, session_id:(if $sid=="" then null else $sid end), result:$r,
    cost_usd:null, num_turns:$turns, files_changed:$fc, duration_ms:$dur, error:null}'
