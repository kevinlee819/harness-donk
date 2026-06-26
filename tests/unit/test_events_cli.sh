#!/usr/bin/env bash
# unit: harness events {pending,ack}
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"
source "$HARNESS_HOME/lib/python_env.sh"
register_cleanup_trap

_setup() {
  PROJ=$(make_fixture_project)
  track_cleanup "$(dirname "$PROJ")"
  cd "$PROJ"
  export HARNESS_DB="$PROJ/.harness/harness.db"
  source "$HARNESS_HOME/lib/notify.sh"
}

test_events_pending_shows_unacked() {
  _setup
  "$HARNESS_PYTHON" -m harness.cli.harness_task add --id T-EV1 <<< "x" >/dev/null
  notify task_completed "T-EV1" '{"branch":"harness/T-EV1"}' >/dev/null
  local out; out=$("$HARNESS_HOME/bin/harness" events pending)
  assert_contains "task_completed" "$out"
  assert_contains "T-EV1" "$out"
}

test_events_ack_marks_delivered() {
  _setup
  "$HARNESS_PYTHON" -m harness.cli.harness_task add --id T-EV2 <<< "x" >/dev/null
  local eid; eid=$(notify needs_decision "T-EV2" '{"question":"A or B?"}')
  "$HARNESS_HOME/bin/harness" events ack "$eid" >/dev/null

  local out; out=$("$HARNESS_HOME/bin/harness" events pending)
  # 表头一行总在；ack 后内容里不应再出现 T-EV2
  if [[ "$out" == *"T-EV2"* ]]; then
    _assert_fail "T-EV2 should be acked"
  fi
}

test_events_ack_multiple() {
  _setup
  "$HARNESS_PYTHON" -m harness.cli.harness_task add --id T-EV3 <<< "x" >/dev/null
  local e1; e1=$(notify task_completed "T-EV3" '{}')
  local e2; e2=$(notify task_failed "T-EV3" '{"reason":"test"}')

  local out; out=$("$HARNESS_HOME/bin/harness" events ack "$e1" "$e2")
  assert_contains "acked 2" "$out"

  local pending; pending=$("$HARNESS_HOME/bin/harness" events pending | grep -c "T-EV3" || true)
  assert_eq "0" "$pending" "both events acked"
}

test_events_unknown_subcommand() {
  _setup
  set +e
  local out; out=$("$HARNESS_HOME/bin/harness" events bogus 2>&1)
  local rc=$?
  set -e
  assert_neq "0" "$rc"
  assert_contains "usage" "$out"
}

run_tests
