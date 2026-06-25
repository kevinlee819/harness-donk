#!/usr/bin/env bash
# 执行平面 dumb loop — MVP 单 worker、串行、--once 单跑一轮
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

_db() { "$HARNESS_PYTHON" -m harness.cli.db_cli "$@"; }

PROJECT_DIR="$(pwd)"
ONCE=0
MOCK=0
MAX_RETRIES=3
MODEL="${HARNESS_MODEL:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) ONCE=1; shift ;;
    --project) PROJECT_DIR="$2"; shift 2 ;;
    --mock) MOCK=1; shift ;;
    --max-retries) MAX_RETRIES="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

cd "$PROJECT_DIR"
PROJECT_DIR=$(pwd)
PROJECT_NAME=$(basename "$PROJECT_DIR")

export HARNESS_DB="$PROJECT_DIR/.harness/harness.db"
[[ ! -f "$HARNESS_DB" ]] && { echo "harness not initialized in $PROJECT_DIR — run 'harness init'" >&2; exit 2; }

WORKTREE_BASE="$(dirname "$PROJECT_DIR")/.worktrees/$PROJECT_NAME"
LOG_DIR="$PROJECT_DIR/.harness/logs/raw"
mkdir -p "$WORKTREE_BASE" "$LOG_DIR"

_log() { printf '[orchestrator %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

_write_status() {
  # _write_status <worker_id> <task_id> <status> <branch> <progress> <session_id>
  local wid="$1" tid="$2" stat="$3" branch="$4" progress="$5" sid="$6"
  local path="$PROJECT_DIR/.harness/workers/$wid/status.json"
  local json
  json=$(jq -nc --arg wid "$wid" --arg tid "$tid" --arg s "$stat" --arg b "$branch" \
                --arg p "$progress" --arg sid "$sid" \
                --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version:1, worker_id:$wid, backend:"claude", session_id:$sid, task_id:$tid,
      status:$s, branch:$b, progress:$p, turns:0, files_changed:0, blockers:[], updated:$now}')
  atomic_write_json "$path" "$json"
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

  local retries=0 sid=""
  while :; do
    _log "call claude adapter (retry $retries)"
    local resp
    if [[ $MOCK -eq 1 ]]; then
      resp=$(HARNESS_MOCK_ADAPTER=1 \
        ADAPTER_TASK_FILE="$prompt_file" ADAPTER_WORKTREE="$worktree" \
        ADAPTER_SESSION_ID="$sid" ADAPTER_LOG_DIR="$LOG_DIR" \
        ADAPTER_TASK_ID="$task_id" ADAPTER_WORKER_ID="$worker_id" \
        bash "$HARNESS_HOME/adapters/claude.sh") || resp='{"ok":false,"error":"adapter_failed"}'
    else
      resp=$(ADAPTER_TASK_FILE="$prompt_file" ADAPTER_WORKTREE="$worktree" \
        ADAPTER_SESSION_ID="$sid" ADAPTER_LOG_DIR="$LOG_DIR" \
        ADAPTER_TASK_ID="$task_id" ADAPTER_WORKER_ID="$worker_id" \
        ADAPTER_MODEL="$MODEL" \
        bash "$HARNESS_HOME/adapters/claude.sh") || resp='{"ok":false,"error":"adapter_failed"}'
    fi

    local ok new_sid cost turns dur fc err
    ok=$(printf '%s' "$resp" | jq -r '.ok')
    new_sid=$(printf '%s' "$resp" | jq -r '.session_id // empty')
    cost=$(printf '%s' "$resp" | jq -r '.cost_usd // "null"')
    turns=$(printf '%s' "$resp" | jq -r '.num_turns // "null"')
    dur=$(printf '%s' "$resp" | jq -r '.duration_ms // 0')
    fc=$(printf '%s' "$resp" | jq -r '.files_changed // 0')
    err=$(printf '%s' "$resp" | jq -r '.error // ""')

    [[ -n "$new_sid" ]] && { sid="$new_sid"; _db register-session "$task_id" claude "$sid"; }
    _db log-call "$task_id" "$worker_id" claude "${sid:-}" \
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
    # 合并节点自动备份（轻量、间隔自然）
    "$HARNESS_HOME/bin/harness" backup >/dev/null 2>&1 || true
  else
    _log "merge failed"
    _db transition "$task_id" failed "merge_conflict"
    notify task_failed "$task_id" "$(jq -nc '{reason:"merge_conflict"}')" >/dev/null
    return 1
  fi
}

# main
while :; do
  row=$(_db claim w1)
  if [[ -z "$row" ]]; then
    _log "queue empty"
    [[ $ONCE -eq 1 ]] && exit 0
    sleep 5; continue
  fi
  task_id="${row%%|*}"
  spec_path="${row#*|}"
  run_task "$task_id" "$spec_path" || _log "task $task_id failed"
  [[ $ONCE -eq 1 ]] && exit 0
done
