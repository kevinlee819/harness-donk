#!/usr/bin/env bash
# Codex CLI adapter — codex exec --json 归一化
# 见 docs/interfaces.md §4, docs/adapter-contract.md, CLAUDE.md §4.6
#
# 入参（环境变量）— 与 claude.sh 对齐：
#   ADAPTER_TASK_FILE     必填，提示词文件
#   ADAPTER_WORKTREE      必填，工作目录
#   ADAPTER_SESSION_ID    可选；非空触发 resume —— UUID 形态直接传 codex exec resume <uuid>，
#                         否则降级 --last（按 cwd 取最近会话）。
#   ADAPTER_MAX_TURNS     默认 12（codex 无 turn cap，这里仅记录，靠 timeout 兜底）
#   ADAPTER_TIMEOUT       默认 900
#   ADAPTER_LOG_DIR       原始 JSONL 落盘
#   ADAPTER_TASK_ID / ADAPTER_WORKER_ID / ADAPTER_WORKER_DIR
#   ADAPTER_MODEL         传 codex -m
#   ADAPTER_SANDBOX       read-only / workspace-write / danger-full-access
#                         默认 workspace-write；review 模式调用方应传 read-only
#                         （此时自动 --ephemeral + 关 web_search + 应用 output-schema）
#   HARNESS_MOCK_ADAPTER  非空 → 走 mock 路径（不调真 codex）
#   HARNESS_ADAPTER_DRYRUN 非空 → 构造 args 后打印到 stdout（一行一个）+ exit 0，
#                         不实际调 codex。用于测试 flag 装配是否正确。
#
# 出参（stdout 单行 JSON）—— 与 claude.sh 同 schema：
#   {ok, session_id, result, cost_usd, num_turns, files_changed, duration_ms, error}
#
# 串行约束（CLAUDE.md §4.6）：同一 worktree 同时最多一个 codex 进程。
# 用 mkdir 原子互斥（macOS 无 flock）。

set -uo pipefail

ADAPTER_NAME="codex"

# capability bitmap（写法须形如 NAME=VALUE 一行，便于 grep；
# 调用方读 bitmap 决定可派任务类型）
ADAPTER_CAP_SESSION_RESUME=1                   # codex exec resume <uuid|--last>
ADAPTER_CAP_SESSION_ID_PROGRAMMATIC=1          # thread_id 从 thread.started 事件可取（codex 0.142+）
ADAPTER_CAP_TOOL_PERMISSION=1                  # --sandbox + --ask-for-approval
ADAPTER_CAP_COST_REPORT=1                      # USD 自算：token × schema/model-prices.json（详见 src/harness/usage.py）
ADAPTER_PARALLEL_PER_WORKTREE=0                # 必须串行（避开 git index 竞争）

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
  # base..HEAD（branch 视角全量改动）— worker 已 commit 后 `git diff HEAD` 会归零。
  local base
  for ref in main master; do
    if base=$(git merge-base HEAD "$ref" 2>/dev/null); then
      git diff --name-only "$base"..HEAD 2>/dev/null | wc -l | tr -d ' '
      return
    fi
  done
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
  # resume 时保留传入 sid（模拟 codex thread 持久化）；否则生成新 mock sid
  if [[ -n "$ADAPTER_SESSION_ID" ]]; then
    fake_sid="$ADAPTER_SESSION_ID"
  else
    fake_sid="codex-mock-$(date +%s)"
  fi

  # 测试钩子：与 claude.sh 对齐 — sleep N 秒后再写文件，给杀进程留窗口
  if [[ -n "${HARNESS_MOCK_SLEEP_S:-}" ]]; then
    sleep "$HARNESS_MOCK_SLEEP_S"
  fi

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

  # 常规 mock：在 worktree 写 CODEX.txt + commit。如需并行安全，
  # 设 HARNESS_MOCK_OUTPUT_FILE='CODEX-$ADAPTER_TASK_ID.txt' 隔离路径。
  output_file="${HARNESS_MOCK_OUTPUT_FILE:-CODEX.txt}"
  output_file=$(eval "printf '%s' \"$output_file\"")
  echo "codex-mock-adapter ran: $(echo "$prompt" | head -c 100)" > "$output_file"
  git add "$output_file" >/dev/null 2>&1 || true
  git -c user.email=mock@harness -c user.name=mock-codex \
      commit -m "mock-codex: ${ADAPTER_TASK_ID:-?}: $(echo "$prompt" | head -c 50)" >/dev/null 2>&1 || true
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

# 构造命令。源码学到的几条要点（codex-rs/exec/src/lib.rs 与 cli.rs）：
#   (1) `exec` 的子命令选项（特别是 `-C/--cd`）必须放在 `resume` 子命令**之前**，
#       否则 `codex exec resume` 报 unexpected argument。
#   (2) `codex exec` 在 headless 模式下默认 `approval_policy = AskForApproval::Never`
#       （lib.rs:426 注释 "Default to never ask for approvals in headless mode"），
#       所以无需也无法通过 exec 传 `-a/--ask-for-approval`（它是 TuiCli 的字段，
#       `inherit_exec_root_options` 不会传给 exec）。
#   (3) **绝不**用 `--dangerously-bypass-approvals-and-sandbox`：lib.rs:294 显示它会
#       强制 sandbox_mode = SandboxMode::DangerFullAccess，覆盖我们传的 `-s`。
#       此前版本两个 flag 同时传，实际跑的是 DangerFullAccess —— worktree 写区
#       限制被静默废掉，等于把 codex 完全放飞。这是真实安全 bug。
_args=(exec -C "$ADAPTER_WORKTREE" --json -s "$ADAPTER_SANDBOX"
       -o "$LAST_MSG" --skip-git-repo-check)
[[ -n "$ADAPTER_MODEL" ]] && _args+=(-m "$ADAPTER_MODEL")

# Review 模式（read-only + 非 resume）：
#   --ephemeral              不持久化 session（review 不需要后续 resume）
#   --output-schema <file>   翻译到 Responses API 的 `text.format=json_schema,strict=true`
#                            （codex-api/src/common.rs:313-330）—— 模型**强制**只能输
#                            出符合 schema 的纯 JSON，无法回 markdown / 解释段。比让
#                            model 自由发挥再用正则抠 `{...}` 可靠一个量级。
#   -c web_search="disabled" review 只看 diff 不联网 —— 防注入 + 省钱
if [[ "$ADAPTER_SANDBOX" == "read-only" && -z "$ADAPTER_SESSION_ID" ]]; then
  _args+=(--ephemeral)
  _review_schema="${HARNESS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/schema/json/review-response.schema.json"
  [[ -f "$_review_schema" ]] && _args+=(--output-schema "$_review_schema")
  _args+=(-c 'web_search="disabled"')
fi

if [[ -n "$ADAPTER_SESSION_ID" ]]; then
  # resume：若 SESSION_ID 是 UUID 就直接传，否则用 --last 取本目录最近一次
  _args+=(resume)
  if [[ "$ADAPTER_SESSION_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    _args+=("$ADAPTER_SESSION_ID")
  else
    _args+=(--last)
  fi
fi

# Dry-run：打印构造好的 args 后 exit 0，不实际调 codex。用于测试 flag 装配。
if [[ -n "${HARNESS_ADAPTER_DRYRUN:-}" ]]; then
  printf '%s\n' "${_args[@]}"
  exit 0
fi

start_ms=$(python3 -c 'import time;print(int(time.time()*1000))')

# Fixture 注入：测试可传 HARNESS_CODEX_EVENTS_FIXTURE=<jsonl 文件> 跳过真 codex 调用，
# 直接用该文件作为 events 源。仅用于测试解析 + 价目折算管线。
if [[ -n "${HARNESS_CODEX_EVENTS_FIXTURE:-}" && -f "$HARNESS_CODEX_EVENTS_FIXTURE" ]]; then
  cp "$HARNESS_CODEX_EVENTS_FIXTURE" "$EVENTS"
  EXIT=0
else
  set +e
  timeout "$ADAPTER_TIMEOUT" codex "${_args[@]}" < "$ADAPTER_TASK_FILE" > "$EVENTS" 2>"$ADAPTER_WORKTREE/.adapter.stderr"
  EXIT=$?
  set -e
fi

end_ms=$(python3 -c 'import time;print(int(time.time()*1000))')
duration=$((end_ms - start_ms))

# 解析 JSONL：抓 turn.completed 数、最后 agent_message、thread_id
turns=$(grep -c '"type":"turn.completed"' "$EVENTS" 2>/dev/null || true)
[[ -z "$turns" ]] && turns=0
thread_id=$(jq -r 'select(.type=="thread.started") | .thread_id' "$EVENTS" 2>/dev/null | head -1)
[[ -z "$thread_id" || "$thread_id" == "null" ]] && thread_id=""

# Token usage：汇总所有 turn.completed.usage（codex JSONL 每轮一条）。
# 字段（codex 0.142+ / OpenAI Responses 风格）：
#   input_tokens (含 cached_input_tokens), cached_input_tokens,
#   output_tokens (含 reasoning_output_tokens), reasoning_output_tokens
# OpenAI 约定：cached 是 input 的子集 —— 计算时要先减去。
read_in=$(jq -s '[.[] | select(.type=="turn.completed") | .usage.input_tokens // 0] | add // 0' "$EVENTS" 2>/dev/null || echo 0)
read_cached=$(jq -s '[.[] | select(.type=="turn.completed") | .usage.cached_input_tokens // 0] | add // 0' "$EVENTS" 2>/dev/null || echo 0)
read_out=$(jq -s '[.[] | select(.type=="turn.completed") | .usage.output_tokens // 0] | add // 0' "$EVENTS" 2>/dev/null || echo 0)
non_cached_in=$((read_in - read_cached))
[[ $non_cached_in -lt 0 ]] && non_cached_in=0

# 调 harness.usage 折算 USD。模型未知或 token 全 0 时输出 'null' —— 保留 null 别填假数。
cost_usd_str="null"
if [[ -n "$ADAPTER_MODEL" && $((non_cached_in + read_cached + read_out)) -gt 0 ]]; then
  _ph="$HARNESS_HOME/lib/python_env.sh"
  if [[ -f "$_ph" ]]; then
    # shellcheck source=/dev/null
    source "$_ph"
    cost_usd_str=$("$HARNESS_PYTHON" -m harness.usage codex "$ADAPTER_MODEL" \
      "input=$non_cached_in" "output=$read_out" "cache_read=$read_cached" 2>/dev/null || echo null)
  fi
fi

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
       --argjson cost "${cost_usd_str:-null}" \
  '{ok:true, session_id:(if $sid=="" then null else $sid end), result:$r,
    cost_usd:$cost, num_turns:$turns, files_changed:$fc, duration_ms:$dur, error:null}'
