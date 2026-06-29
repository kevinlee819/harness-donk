#!/usr/bin/env bash
# unit: hooks/notification.sh — 由 lib/notify.sh 触发的本地落 log
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"
source "$HARNESS_HOME/lib/python_env.sh"
register_cleanup_trap

_setup() {
  PROJ=$(make_fixture_project)
  track_cleanup "$(dirname "$PROJ")"
  export HARNESS_DB="$PROJ/.harness/harness.db"
}

# Direct call to harness.notify.notify — same path the orchestrator uses:
# writes event row, JSON file, and fires hooks/notification.sh in background.
notify() {
  local etype="$1" tid="$2" payload="${3:-}"
  [[ -z "$payload" ]] && payload='{}'
  "$HARNESS_PYTHON" -c '
import sys, json
from harness.notify import notify
tid = None if sys.argv[2] in ("-", "") else sys.argv[2]
print(notify(sys.argv[1], tid, json.loads(sys.argv[3])))
' "$etype" "$tid" "$payload"
}

# 等 notify 的后台 hook 完成（最多 2s）
_wait_log() {
  local log="$1" needle="$2"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [[ -f "$log" ]] && grep -q "$needle" "$log" && return 0
    sleep 0.2
  done
  return 1
}

test_hook_writes_local_notify_log_for_needs_decision() {
  _setup
  "$HARNESS_PYTHON" -m harness.cli.harness_task add --id T-nh1 <<< "x" >/dev/null
  notify needs_decision "T-nh1" '{"question":"A or B?"}' >/dev/null

  local log="$PROJ/.harness/logs/notify.log"
  _wait_log "$log" "needs_decision" || { echo "notify.log missing 'needs_decision'" >&2; cat "$log" 2>/dev/null >&2; return 1; }
  local content; content=$(cat "$log")
  assert_contains "needs_decision" "$content"
  assert_contains "A or B?" "$content"
  assert_contains "T-nh1" "$content"
}

test_hook_writes_for_task_completed() {
  _setup
  "$HARNESS_PYTHON" -m harness.cli.harness_task add --id T-nh2 <<< "x" >/dev/null
  notify task_completed "T-nh2" '{"branch":"harness/T-nh2"}' >/dev/null

  # task_completed 必须写 log + 弹桌面通知 —— 协调者会话不能自唤醒，
  # 桌面 toast 是把用户拉回对话的唯一信号（不再是「静默」事件）。
  local log="$PROJ/.harness/logs/notify.log"
  _wait_log "$log" "task_completed" || { cat "$log" 2>/dev/null >&2; return 1; }
  local content; content=$(cat "$log")
  assert_contains "T-nh2" "$content"
  assert_contains "harness/T-nh2" "$content"
}

test_hook_writes_for_task_failed() {
  _setup
  "$HARNESS_PYTHON" -m harness.cli.harness_task add --id T-nh3 <<< "x" >/dev/null
  notify task_failed "T-nh3" '{"reason":"gate_failed_after_retries"}' >/dev/null
  local log="$PROJ/.harness/logs/notify.log"
  _wait_log "$log" "task_failed" || { cat "$log" 2>/dev/null >&2; return 1; }
  local content; content=$(cat "$log")
  assert_contains "T-nh3" "$content"
  assert_contains "gate_failed_after_retries" "$content"
}

run_tests
