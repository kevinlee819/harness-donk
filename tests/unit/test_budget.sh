#!/usr/bin/env bash
# unit: lib/budget.sh + orchestrator _budget_guard 路径
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"
source "$HARNESS_HOME/lib/python_env.sh"
register_cleanup_trap

_setup() {
  PROJ=$(make_fixture_project)
  track_cleanup "$(dirname "$PROJ")"
  export HARNESS_DB="$PROJ/.harness/harness.db"
  # 隔离全局 config — 不污染用户的 ~/.config/harness
  export HARNESS_CONFIG_DIR="$PROJ/.harness/_conf"
  mkdir -p "$HARNESS_CONFIG_DIR"
  source "$HARNESS_HOME/lib/budget.sh"
}

test_budget_today_zero_when_no_calls() {
  _setup
  local today; today=$(budget_today)
  # 浮点 0 表达可能是 0 / 0.0
  assert_match "^0(\.0+)?$" "$today"
}

test_budget_check_under_limit() {
  _setup
  echo "budget_daily_usd=100" > "$HARNESS_CONFIG_DIR/config"
  local rc=0; budget_check || rc=$?
  assert_eq "0" "$rc" "no calls + limit=100 → under"
}

test_budget_check_over_limit() {
  _setup
  # 写一条假调用，cost=5
  "$HARNESS_PYTHON" -m harness.cli.harness_task add --id T-bdg <<< "spec" >/dev/null
  "$HARNESS_PYTHON" -m harness.cli.db_cli log-call T-bdg w1 claude "" 0 5.0 1 1000 1
  echo "budget_daily_usd=1" > "$HARNESS_CONFIG_DIR/config"
  local rc=0; budget_check || rc=$?
  assert_eq "1" "$rc" "cost=5 vs limit=1 → over"
}

test_budget_guard_emits_event_when_over() {
  _setup
  cd "$PROJ"
  "$HARNESS_PYTHON" -m harness.cli.harness_task add --id T-bdg2 <<< "spec" >/dev/null
  "$HARNESS_PYTHON" -m harness.cli.db_cli log-call T-bdg2 w1 claude "" 0 12.0 1 1000 1
  echo "budget_daily_usd=10" > "$HARNESS_CONFIG_DIR/config"

  # 直接跑 orchestrator --once：超限 → notify budget_exceeded → 退出
  "$HARNESS_HOME/bin/harness" run-once --mock 2>&1 | tail -5

  local n; n=$(sqlite3 "$HARNESS_DB" \
    "SELECT COUNT(*) FROM events WHERE event_type='budget_exceeded';")
  assert_eq "1" "$n" "budget_exceeded emitted on overrun"

  # marker 文件应建
  local today; today=$(date -u +%Y-%m-%d)
  assert_file_exists "$PROJ/.harness/.budget-exceeded-$today" "marker created"

  # 第二次跑不应重复 notify（按天去重）
  "$HARNESS_HOME/bin/harness" run-once --mock >/dev/null 2>&1
  n=$(sqlite3 "$HARNESS_DB" \
    "SELECT COUNT(*) FROM events WHERE event_type='budget_exceeded';")
  assert_eq "1" "$n" "dedup: still 1 event"
}

run_tests
