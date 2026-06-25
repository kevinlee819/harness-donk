#!/usr/bin/env bash
# unit: lib/notify.sh — 事件写库 + JSON 落盘
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"
source "$HARNESS_HOME/lib/python_env.sh"
register_cleanup_trap

# 每个测试自己调 _setup 拿到 $PROJ 与 $HARNESS_DB（不用命令替换，避免 subshell 丢 export）
_setup_proj() {
  PROJ=$(make_fixture_project)
  track_cleanup "$(dirname "$PROJ")"
  export HARNESS_DB="$PROJ/.harness/harness.db"
  source "$HARNESS_HOME/lib/notify.sh"
}

test_notify_task_completed_writes_event_and_file() {
  _setup_proj
  echo "spec body" | "$HARNESS_PYTHON" -m harness.cli.harness_task add --id T-ev1 >/dev/null
  local eid; eid=$(notify task_completed "T-ev1" '{"branch":"harness/T-ev1"}')
  assert_eq "1" "$eid" "first event id is 1"

  local pending; pending=$("$HARNESS_PYTHON" -m harness.cli.db_cli event-pending)
  assert_match "task_completed" "$pending"
  assert_match "T-ev1" "$pending"

  local n; n=$(ls "$PROJ/.harness/events/"*task_completed*T-ev1*.json 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "1" "$n" "exactly one event file"
}

test_notify_invalid_event_type_rejected() {
  _setup_proj
  local rc=0
  notify bogus_type "-" '{}' >/dev/null 2>&1 || rc=$?
  assert_neq "0" "$rc" "invalid event_type → non-zero"
}

test_notify_invalid_payload_rejected() {
  _setup_proj
  local rc=0
  notify needs_decision "-" 'not json{' >/dev/null 2>&1 || rc=$?
  assert_neq "0" "$rc" "non-JSON payload → non-zero"
}

test_notify_default_empty_payload() {
  _setup_proj
  local eid; eid=$(notify budget_exceeded "-")
  assert_eq "1" "$eid"
  local n; n=$(ls "$PROJ/.harness/events/"*budget_exceeded-none*.json 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "1" "$n" "tid='-' → filename uses 'none'"
}

test_event_ack_removes_from_pending() {
  _setup_proj
  echo "x" | "$HARNESS_PYTHON" -m harness.cli.harness_task add --id T-ack >/dev/null
  local eid; eid=$(notify task_completed "T-ack" '{}')
  "$HARNESS_PYTHON" -m harness.cli.db_cli event-ack "$eid"
  local n; n=$("$HARNESS_PYTHON" -m harness.cli.db_cli event-pending | wc -l | tr -d ' ')
  assert_eq "0" "$n" "after ack, no pending"
}

run_tests
