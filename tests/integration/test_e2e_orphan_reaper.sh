#!/usr/bin/env bash
# integration: orphan reaper（崩溃残留任务回收）+ BLOCKED 超时
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"

register_cleanup_trap
TASK_CMD="$HARNESS_HOME/coordinator/tools/harness-task"

# 强制 updated 为远古时间（模拟「上次崩溃留下的任务」）
_fossilize_task() {
  # _fossilize_task <db> <task_id> <status>
  local db="$1" tid="$2" stat="$3"
  sqlite3 "$db" "UPDATE tasks SET status='$stat', worker_id='w1', branch='harness/$tid',
                  updated='2020-01-01T00:00:00Z' WHERE id='$tid';"
  sqlite3 "$db" "INSERT INTO transitions(task_id, from_state, to_state, reason, ts)
                  VALUES('$tid', 'queued', '$stat', 'test_setup', '2020-01-01T00:00:00Z');"
}

test_orphan_in_working_gets_redispatched() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  set_gate_test_cmd "$proj" "test -f HELLO.txt"

  "$TASK_CMD" add --id T-orph1 <<< "create HELLO.txt" >/dev/null
  _fossilize_task "$proj/.harness/harness.db" "T-orph1" "working"

  "$HARNESS_HOME/bin/harness" run-once --mock 2>&1 | tail -15

  # reap → queued → claim → run → merge
  local row; row=$("$TASK_CMD" query --task T-orph1)
  assert_contains "merged" "$row" "orphan reaped → re-runs → merged"

  local reds; reds=$(sqlite3 "$proj/.harness/harness.db" "SELECT redispatches FROM tasks WHERE id='T-orph1';")
  assert_eq "1" "$reds" "redispatches incremented"

  # transitions 应含 orphan_redispatch
  local hist; hist=$("$TASK_CMD" history T-orph1)
  assert_contains "orphan_redispatch" "$hist"
}

test_orphan_at_max_redispatches_goes_failed() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"

  "$TASK_CMD" add --id T-orph2 <<< "stale task" >/dev/null
  _fossilize_task "$proj/.harness/harness.db" "T-orph2" "working"
  sqlite3 "$proj/.harness/harness.db" "UPDATE tasks SET redispatches=2 WHERE id='T-orph2';"

  "$HARNESS_HOME/bin/harness" run-once --mock 2>&1 | tail -10

  local row; row=$("$TASK_CMD" query --task T-orph2)
  assert_contains "failed" "$row" "orphan at max redispatches → failed"

  local n_ev; n_ev=$(sqlite3 "$proj/.harness/harness.db" \
    "SELECT COUNT(*) FROM events WHERE task_id='T-orph2' AND event_type='task_failed';")
  assert_eq "1" "$n_ev" "task_failed event emitted"

  local payload; payload=$(sqlite3 "$proj/.harness/harness.db" \
    "SELECT payload FROM events WHERE task_id='T-orph2' LIMIT 1;")
  assert_contains "orphan_max_redispatches" "$payload"
}

test_blocked_overdue_times_out_to_failed() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  export HARNESS_CONFIG_DIR="$proj/.harness/_conf"
  mkdir -p "$HARNESS_CONFIG_DIR"
  # 超短超时方便测试：1 小时
  echo "blocked_timeout_hours=1" > "$HARNESS_CONFIG_DIR/config"

  "$TASK_CMD" add --id T-blkto <<< "x" >/dev/null
  # 直接置 blocked 状态 + 一条远古 blocked transition
  sqlite3 "$proj/.harness/harness.db" "UPDATE tasks SET status='blocked' WHERE id='T-blkto';
    INSERT INTO transitions(task_id, from_state, to_state, reason, ts)
    VALUES('T-blkto', 'working', 'blocked', 'needs_decision', '2020-01-01T00:00:00Z');"

  "$HARNESS_HOME/bin/harness" run-once --mock 2>&1 | tail -10

  local row; row=$("$TASK_CMD" query --task T-blkto)
  assert_contains "failed" "$row" "overdue blocked → failed"

  local hist; hist=$("$TASK_CMD" history T-blkto)
  assert_contains "blocked_timeout" "$hist"

  local n_ev; n_ev=$(sqlite3 "$proj/.harness/harness.db" \
    "SELECT COUNT(*) FROM events WHERE task_id='T-blkto' AND event_type='task_failed';")
  assert_eq "1" "$n_ev"

  unset HARNESS_CONFIG_DIR
}

test_recent_blocked_not_timed_out() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  export HARNESS_CONFIG_DIR="$proj/.harness/_conf"
  mkdir -p "$HARNESS_CONFIG_DIR"
  echo "blocked_timeout_hours=72" > "$HARNESS_CONFIG_DIR/config"

  "$TASK_CMD" add --id T-blkok <<< "x" >/dev/null
  # 刚刚 blocked，不应超时
  sqlite3 "$proj/.harness/harness.db" "UPDATE tasks SET status='blocked' WHERE id='T-blkok';
    INSERT INTO transitions(task_id, from_state, to_state, reason, ts)
    VALUES('T-blkok', 'working', 'blocked', 'needs_decision', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"

  "$HARNESS_HOME/bin/harness" run-once --mock 2>&1 | tail -5

  local row; row=$("$TASK_CMD" query --task T-blkok)
  assert_contains "blocked" "$row" "recent blocked stays blocked"

  unset HARNESS_CONFIG_DIR
}

run_tests
