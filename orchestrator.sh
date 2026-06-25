#!/usr/bin/env bash
# 执行平面 dumb loop — 阶段二 iteration 2：含 BLOCKED 流 + 预算闸
# 见 docs/interfaces.md §3
#
# bash 只管"调命令"；DB 操作走 python -m harness.cli.db_cli。
# 语言边界见 CLAUDE.md §8。
#
# 用法：
#   orchestrator.sh --once [--project <path>] [--mock]

set -uo pipefail

HARNESS_HOME="${HARNESS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export HARNESS_HOME
source "$HARNESS_HOME/lib/python_env.sh"
source "$HARNESS_HOME/lib/atomic_write.sh"
source "$HARNESS_HOME/lib/notify.sh"
source "$HARNESS_HOME/lib/budget.sh"

_db() { "$HARNESS_PYTHON" -m harness.cli.db_cli "$@"; }

PROJECT_DIR="$(pwd)"
ONCE=0
MOCK=0
MAX_RETRIES=3
MAX_REDISPATCHES="${HARNESS_MAX_REDISPATCHES:-2}"
MODEL="${HARNESS_MODEL:-}"
BACKEND="${HARNESS_BACKEND:-claude}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) ONCE=1; shift ;;
    --project) PROJECT_DIR="$2"; shift 2 ;;
    --mock) MOCK=1; shift ;;
    --max-retries) MAX_RETRIES="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --backend) BACKEND="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

ADAPTER_SH="$HARNESS_HOME/adapters/${BACKEND}.sh"
[[ ! -f "$ADAPTER_SH" ]] && { echo "unknown backend: $BACKEND (no $ADAPTER_SH)" >&2; exit 1; }

cd "$PROJECT_DIR"
PROJECT_DIR=$(pwd)
PROJECT_NAME=$(basename "$PROJECT_DIR")

export HARNESS_DB="$PROJECT_DIR/.harness/harness.db"
[[ ! -f "$HARNESS_DB" ]] && { echo "harness not initialized in $PROJECT_DIR — run 'harness init'" >&2; exit 2; }

WORKTREE_BASE="$(dirname "$PROJECT_DIR")/.worktrees/$PROJECT_NAME"
LOG_DIR="$PROJECT_DIR/.harness/logs/raw"
INBOX_DIR="$PROJECT_DIR/.harness/inbox"
INBOX_PROCESSED="$INBOX_DIR/processed"
mkdir -p "$WORKTREE_BASE" "$LOG_DIR" "$INBOX_DIR" "$INBOX_PROCESSED"

_log() { printf '[orchestrator %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

_write_status() {
  # _write_status <worker_id> <task_id> <status> <branch> <progress> <session_id>
  local wid="$1" tid="$2" stat="$3" branch="$4" progress="$5" sid="$6"
  local path="$PROJECT_DIR/.harness/workers/$wid/status.json"
  local json
  json=$(jq -nc --arg wid "$wid" --arg tid "$tid" --arg s "$stat" --arg b "$branch" \
                --arg p "$progress" --arg sid "$sid" \
                --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg backend "$BACKEND" \
    '{schema_version:1, worker_id:$wid, backend:$backend, session_id:$sid, task_id:$tid,
      status:$s, branch:$b, progress:$p, turns:0, files_changed:0, blockers:[], updated:$now}')
  atomic_write_json "$path" "$json"
}

_worker_dir() {
  # echo absolute path of worker dir for a given worker_id
  echo "$PROJECT_DIR/.harness/workers/$1"
}

_check_blocking() {
  # _check_blocking <worker_id>  → 0 if guidance.json exists with blocking=true
  local g; g="$(_worker_dir "$1")/guidance.json"
  [[ ! -f "$g" ]] && return 1
  local blk; blk=$(jq -r '.blocking // false' "$g" 2>/dev/null)
  [[ "$blk" == "true" ]]
}

_handle_blocked() {
  # _handle_blocked <task_id> <worker_id> <session_id> <branch>
  local tid="$1" wid="$2" sid="$3" branch="$4"
  local g; g="$(_worker_dir "$wid")/guidance.json"
  local question="" context=""
  if [[ -f "$g" ]]; then
    question=$(jq -r '.question // ""' "$g")
    context=$(jq -r '.context // ""' "$g")
  fi
  _db transition "$tid" blocked "needs_decision"
  _write_status "$wid" "$tid" working "$branch" "awaiting answer" "$sid"
  notify needs_decision "$tid" \
    "$(jq -nc --arg q "$question" --arg c "$context" --arg w "$wid" \
       '{question:$q, context:$c, worker_id:$w}')" >/dev/null
  _log "task $tid BLOCKED — awaiting inbox/$tid.answer"
}

# _drive_task: 跑「adapter → (guidance? blocked) → gate → retry/merge」循环。
# 调用前需保证 worktree 已存在、status.json 已写、tasks.status='working'。
#
# 入参：task_id worker_id branch worktree prompt_file [initial_sid]
# 返回：0=merged  1=failed  2=blocked
_drive_task() {
  local task_id="$1" worker_id="$2" branch="$3" worktree="$4" prompt_file="$5"
  local sid="${6:-}"
  local retries; retries=$(_db get-retries "$task_id")

  while :; do
    _log "call $BACKEND adapter (task=$task_id retries=$retries)"
    local resp
    local worker_dir; worker_dir=$(_worker_dir "$worker_id")
    if [[ $MOCK -eq 1 ]]; then
      resp=$(HARNESS_MOCK_ADAPTER=1 \
        ADAPTER_TASK_FILE="$prompt_file" ADAPTER_WORKTREE="$worktree" \
        ADAPTER_SESSION_ID="$sid" ADAPTER_LOG_DIR="$LOG_DIR" \
        ADAPTER_TASK_ID="$task_id" ADAPTER_WORKER_ID="$worker_id" \
        ADAPTER_WORKER_DIR="$worker_dir" \
        bash "$ADAPTER_SH") || resp='{"ok":false,"error":"adapter_failed"}'
    else
      resp=$(ADAPTER_TASK_FILE="$prompt_file" ADAPTER_WORKTREE="$worktree" \
        ADAPTER_SESSION_ID="$sid" ADAPTER_LOG_DIR="$LOG_DIR" \
        ADAPTER_TASK_ID="$task_id" ADAPTER_WORKER_ID="$worker_id" \
        ADAPTER_WORKER_DIR="$worker_dir" \
        ADAPTER_MODEL="$MODEL" \
        bash "$ADAPTER_SH") || resp='{"ok":false,"error":"adapter_failed"}'
    fi

    local ok new_sid cost turns dur fc err
    ok=$(printf '%s' "$resp" | jq -r '.ok')
    new_sid=$(printf '%s' "$resp" | jq -r '.session_id // empty')
    cost=$(printf '%s' "$resp" | jq -r '.cost_usd // "null"')
    turns=$(printf '%s' "$resp" | jq -r '.num_turns // "null"')
    dur=$(printf '%s' "$resp" | jq -r '.duration_ms // 0')
    fc=$(printf '%s' "$resp" | jq -r '.files_changed // 0')
    err=$(printf '%s' "$resp" | jq -r '.error // ""')

    [[ -n "$new_sid" ]] && { sid="$new_sid"; _db register-session "$task_id" "$BACKEND" "$sid"; }
    _db log-call "$task_id" "$worker_id" "$BACKEND" "${sid:-}" \
      "$([[ $ok == true ]] && echo 0 || echo 1)" \
      "$cost" "$turns" "$dur" "$fc"

    if [[ "$ok" != "true" ]]; then
      _log "adapter returned error: $err"
      if [[ $retries -ge $MAX_RETRIES ]]; then
        _db transition "$task_id" failed "adapter_error:${err}"
        _write_status "$worker_id" "$task_id" error "$branch" "$err" "$sid"
        notify task_failed "$task_id" "$(jq -nc --arg r "adapter_error" --arg e "$err" '{reason:$r, error:$e}')" >/dev/null
        return 1
      fi
      retries=$((retries+1)); _db inc-retries "$task_id"
      continue
    fi

    # 阶段二：adapter 调用成功后，先看 worker 是否写了 blocking guidance
    if _check_blocking "$worker_id"; then
      _handle_blocked "$task_id" "$worker_id" "$sid" "$branch"
      return 2
    fi

    _db transition "$task_id" gating ""
    _write_status "$worker_id" "$task_id" working "$branch" "gate running" "$sid"
    HARNESS_TASK_ID="$task_id" bash "$HARNESS_HOME/lib/gate.sh" "$worktree"
    local gate_rc=$?
    if [[ $gate_rc -eq 0 ]]; then
      _log "gate passed"
      break
    fi

    _log "gate failed (retry $retries)"
    if [[ $retries -ge $MAX_RETRIES ]]; then
      _db transition "$task_id" failed "gate_failed_after_retries"
      _write_status "$worker_id" "$task_id" error "$branch" "gate_failed" "$sid"
      local report_summary
      report_summary=$(jq -c '{steps:[.steps[]|{name,ok,output:(.output|tostring|.[0:200])}]}' \
                       "$worktree/.gate-report.json" 2>/dev/null || echo '{}')
      notify task_failed "$task_id" "$(jq -nc --arg r "gate_failed_after_retries" --argjson g "$report_summary" '{reason:$r, gate:$g}')" >/dev/null
      return 1
    fi
    retries=$((retries+1)); _db inc-retries "$task_id"

    local report_path="$worktree/.gate-report.json"
    local failed_steps
    failed_steps=$(jq -r '.steps[] | select(.ok==false) | "[" + .name + "] " + .output' "$report_path" 2>/dev/null)
    {
      echo "上一次提交未通过校验门，需修复后重新提交："
      echo
      echo "$failed_steps"
      echo
      echo "请只修复上述问题，不要扩大改动范围。完成后再次 git add & git commit。"
    } > "$prompt_file"
    _db transition "$task_id" working "regating"
  done

  # 合并阶段
  _db transition "$task_id" gating "merging"
  local main_branch
  main_branch=$(git -C "$PROJECT_DIR" symbolic-ref --short HEAD)
  _log "merging $branch into $main_branch"
  if git -C "$PROJECT_DIR" merge --no-ff "$branch" -m "harness: merge $task_id" 2>&1 | sed 's/^/  merge: /' >&2; then
    _log "merged $task_id"
    _db transition "$task_id" merged "ok"
    _write_status "$worker_id" "$task_id" done "$branch" "merged" "$sid"
    notify task_completed "$task_id" "$(jq -nc --arg b "$branch" '{branch:$b}')" >/dev/null
    git -C "$PROJECT_DIR" worktree remove --force "$worktree" >/dev/null 2>&1 || true
    git -C "$PROJECT_DIR" branch -D "$branch" >/dev/null 2>&1 || true
    "$HARNESS_HOME/bin/harness" backup >/dev/null 2>&1 || true
    return 0
  else
    _log "merge failed"
    _db transition "$task_id" failed "merge_conflict"
    notify task_failed "$task_id" "$(jq -nc '{reason:"merge_conflict"}')" >/dev/null
    return 1
  fi
}

run_task() {
  local task_id="$1" spec_path="$2"
  local worker_id="w1"
  local branch="harness/$task_id"
  local worktree="$WORKTREE_BASE/$task_id"

  _log "claim $task_id ($spec_path)"

  if [[ -d "$worktree" ]]; then
    _log "worktree exists, reusing: $worktree"
  else
    git -C "$PROJECT_DIR" worktree add -b "$branch" "$worktree" 2>&1 | sed 's/^/  git: /' >&2 \
      || { _log "git worktree add failed"; _db transition "$task_id" failed "worktree_add_failed"; return 1; }
  fi
  _db set-branch "$task_id" "$branch"
  _db transition "$task_id" working "first_dispatch"
  _write_status "$worker_id" "$task_id" working "$branch" "starting" ""

  local spec_full="$PROJECT_DIR/$spec_path"
  if [[ ! -f "$spec_full" ]]; then
    _log "spec not found: $spec_full"
    _db transition "$task_id" failed "spec_not_found"
    return 1
  fi
  local prompt_file="$worktree/.harness-prompt.txt"
  {
    echo "=== TASK SPEC ==="
    cat "$spec_full"
    echo
    echo "=== INSTRUCTIONS ==="
    echo "请基于上述 spec 在当前目录完成任务。完成后必须 git add & git commit。"
    echo "禁止 push、merge 主分支，禁止离开本工作目录。"
  } > "$prompt_file"

  _drive_task "$task_id" "$worker_id" "$branch" "$worktree" "$prompt_file" ""
}

resume_blocked_task() {
  # 从 BLOCKED 恢复：读 inbox/<tid>.answer，拼 resume prompt，调 _drive_task
  local task_id="$1"
  local answer_file="$INBOX_DIR/${task_id}.answer"
  [[ ! -f "$answer_file" ]] && return 0

  local row; row=$(_db query-status "$task_id")
  [[ -z "$row" ]] && { _log "resume: no such task $task_id"; return 1; }
  local id stat wid branch retries reds prio created
  IFS=$'\t' read -r id stat wid branch retries reds prio created <<<"$row"
  [[ "$stat" != "blocked" ]] && { _log "resume: $task_id not blocked (status=$stat)"; return 1; }

  local worktree="$WORKTREE_BASE/$task_id"
  [[ ! -d "$worktree" ]] && { _log "resume: worktree gone for $task_id"; _db transition "$task_id" failed "worktree_lost"; return 1; }

  local sid; sid=$(_db get-session "$task_id" "$BACKEND")

  # 解析 answer：JSON 优先取 .answer，否则当纯文本
  local answer
  if jq -e . "$answer_file" >/dev/null 2>&1; then
    answer=$(jq -r '.answer // ""' "$answer_file")
  else
    answer=$(cat "$answer_file")
  fi
  [[ -z "$answer" ]] && { _log "resume: empty answer for $task_id"; return 1; }

  # 拿原问题作上下文
  local guidance; guidance="$(_worker_dir "$wid")/guidance.json"
  local question=""
  [[ -f "$guidance" ]] && question=$(jq -r '.question // ""' "$guidance")

  local prompt_file="$worktree/.harness-prompt.txt"
  {
    echo "=== RESUME — 用户/协调者已答复 ==="
    [[ -n "$question" ]] && echo "上一次提问：$question"
    echo "决策：$answer"
    echo
    echo "请基于此决策继续完成任务。完成后必须 git add & git commit。"
    echo "禁止 push、merge 主分支，禁止离开本工作目录。"
  } > "$prompt_file"

  # 清掉 guidance.json 防止下一轮再次触发 BLOCKED；归档 answer
  [[ -f "$guidance" ]] && rm -f "$guidance"
  mv "$answer_file" "$INBOX_PROCESSED/${task_id}.answer.$(date -u +%Y%m%dT%H%M%SZ)"

  _db transition "$task_id" working "answered"
  _write_status "$wid" "$task_id" working "$branch" "resumed" "$sid"
  _log "resume $task_id with answer"
  _drive_task "$task_id" "$wid" "$branch" "$worktree" "$prompt_file" "$sid"
}

_scan_resume_blocked() {
  # 扫所有 BLOCKED 任务，找有 answer 的，逐个恢复
  local rows; rows=$(_db query-by-status blocked 2>/dev/null)
  [[ -z "$rows" ]] && return 0
  local tid stat wid retries prio created
  while IFS=$'\t' read -r tid stat wid retries prio created; do
    [[ -z "$tid" ]] && continue
    [[ -f "$INBOX_DIR/${tid}.answer" ]] || continue
    resume_blocked_task "$tid" || _log "resume $tid failed"
  done <<< "$rows"
}

# ── 全局配置读取（小工具，不引依赖）─────────────────
_conf_value() {
  # _conf_value <key> <default>
  local key="$1" def="$2"
  local conf="${HARNESS_CONFIG_DIR:-$HOME/.config/harness}/config"
  local v=""
  if [[ -f "$conf" ]]; then
    v=$(awk -F= -v k="$key" '$0 ~ "^"k"[[:space:]]*=" {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$conf")
  fi
  echo "${v:-$def}"
}

_reap_orphans() {
  # 扫描 transient 状态的孤儿任务（dispatched/working/gating + updated 过老）
  # 单进程编排器在 loop 顶端时，本进程不可能有 in-flight 任务 → 全是上次崩溃留下的。
  # 重派封顶 redispatches=$MAX_REDISPATCHES，超过则 FAILED。
  local thresh; thresh=$(_conf_value dead_worker_threshold_min 10)
  local rows; rows=$(_db query-orphans "$thresh" 2>/dev/null)
  [[ -z "$rows" ]] && return 0
  local tid status retries reds updated
  while IFS=$'\t' read -r tid status retries reds updated; do
    [[ -z "$tid" ]] && continue
    if (( reds < MAX_REDISPATCHES )); then
      _log "orphan reap: $tid (status=$status updated=$updated reds=$reds) → queued"
      _db inc-redispatches "$tid"
      _db transition "$tid" queued "orphan_redispatch"
    else
      _log "orphan reap: $tid (status=$status reds=$reds maxed) → failed"
      _db transition "$tid" failed "orphan_max_redispatches"
      notify task_failed "$tid" \
        "$(jq -nc --arg r "orphan_max_redispatches" --argjson rd "$reds" \
           '{reason:$r, redispatches:$rd}')" >/dev/null
    fi
  done <<< "$rows"
}

_timeout_blocked() {
  # BLOCKED 任务卡过阈值（默认 72h）→ FAILED + task_failed 事件
  local hrs; hrs=$(_conf_value blocked_timeout_hours 72)
  local rows; rows=$(_db query-blocked-overdue "$hrs" 2>/dev/null)
  [[ -z "$rows" ]] && return 0
  local tid since
  while IFS=$'\t' read -r tid since; do
    [[ -z "$tid" ]] && continue
    _log "BLOCKED timeout: $tid (blocked since $since) → failed"
    _db transition "$tid" failed "blocked_timeout"
    notify task_failed "$tid" \
      "$(jq -nc --arg r "blocked_timeout" --arg s "$since" --arg h "$hrs" \
         '{reason:$r, blocked_since:$s, threshold_hours:($h|tonumber)}')" >/dev/null
  done <<< "$rows"
}

_budget_guard() {
  # 返回 0：可派；1：超限（已 notify）。
  if budget_check; then return 0; fi
  local today; today=$(date -u +%Y-%m-%d)
  local marker="$PROJECT_DIR/.harness/.budget-exceeded-${today}"
  if [[ ! -f "$marker" ]]; then
    local cost; cost=$(budget_today)
    local limit; limit=$(_budget_daily_limit)
    notify budget_exceeded "-" \
      "$(jq -nc --arg c "$cost" --arg l "$limit" --arg d "$today" \
         '{cost_usd:($c|tonumber), limit_usd:($l|tonumber), date:$d}')" >/dev/null
    touch "$marker"
    _log "budget exceeded: \$$cost > \$$limit (kill switch engaged)"
  fi
  return 1
}

# main loop
while :; do
  # 顶部清理顺序：先回收孤儿，再 BLOCKED 超时，再 resume 答复，最后预算 + claim
  _reap_orphans
  _timeout_blocked
  _scan_resume_blocked

  # 预算闸：超限就停止新派发
  if _budget_guard; then
    row=$(_db claim w1)
  else
    row=""
  fi

  if [[ -z "$row" ]]; then
    _log "queue empty (or budget locked)"
    [[ $ONCE -eq 1 ]] && exit 0
    sleep 5; continue
  fi
  task_id="${row%%|*}"
  spec_path="${row#*|}"
  run_task "$task_id" "$spec_path" || _log "task $task_id ended non-merged"
  [[ $ONCE -eq 1 ]] && exit 0
done
