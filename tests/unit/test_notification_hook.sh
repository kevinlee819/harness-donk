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
  source "$HARNESS_HOME/lib/notify.sh"
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

test_hook_skipped_for_task_completed() {
  _setup
  "$HARNESS_PYTHON" -m harness.cli.harness_task add --id T-nh2 <<< "x" >/dev/null
  notify task_completed "T-nh2" '{"branch":"harness/T-nh2"}' >/dev/null

  # task_completed 是「静默」事件，不写 notify.log
  sleep 0.5
  local log="$PROJ/.harness/logs/notify.log"
  if [[ -f "$log" ]]; then
    if grep -q "task_completed" "$log" 2>/dev/null; then
      echo "task_completed unexpectedly logged" >&2
      return 1
    fi
  fi
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
