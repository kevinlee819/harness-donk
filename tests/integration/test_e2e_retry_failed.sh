#!/usr/bin/env bash
# integration: gate 一直失败 → 回灌 → 重试耗尽 → FAILED
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"

register_cleanup_trap
TASK_CMD="$HARNESS_HOME/coordinator/tools/harness-task"

test_gate_failure_exhausts_retries() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"

  # gate test 设为永远失败
  set_gate_test_cmd "$proj" "false"

  "$TASK_CMD" add --id T-fail <<< "this gate will always fail" >/dev/null

  # max-retries=2 → 应共尝试 3 次（初始 + 2 重试）后 FAILED
  "$HARNESS_HOME/bin/harness" run-once --mock --max-retries 2 2>&1 | tail -25

  local row; row=$("$TASK_CMD" query --task T-fail)
  assert_contains "failed" "$row" "exhausted → failed"

  # retries 字段应到 2
  local retries; retries=$(sqlite3 "$proj/.harness/harness.db" "SELECT retries FROM tasks WHERE id='T-fail';")
  assert_eq "2" "$retries" "retries=2"

  # 不应合并：主分支不应包含失败任务的内容（HELLO.txt 不在主分支）
  set +e
  git -C "$proj" log --all --oneline | grep -q "harness: merge T-fail"
  local has_merge=$?
  set -e
  assert_neq 0 "$has_merge" "no merge commit for failed task"

  # transitions 应包含多次 gating↔working 回灌
  local hist; hist=$("$TASK_CMD" history T-fail)
  local n_regating; n_regating=$(echo "$hist" | grep -c regating || true)
  assert_eq "2" "$n_regating" "2 regate cycles"

  # 终态原因
  assert_contains "gate_failed_after_retries" "$hist"

  # 阶段二：FAILED 终态写了 task_failed 事件，含 gate 报告摘要
  local n_ev; n_ev=$(sqlite3 "$proj/.harness/harness.db" \
    "SELECT COUNT(*) FROM events WHERE task_id='T-fail' AND event_type='task_failed';")
  assert_eq "1" "$n_ev" "task_failed event emitted on FAILED"
  local payload; payload=$(sqlite3 "$proj/.harness/harness.db" \
    "SELECT payload FROM events WHERE task_id='T-fail' LIMIT 1;")
  assert_contains "gate_failed_after_retries" "$payload" "payload carries reason"
}

run_tests
