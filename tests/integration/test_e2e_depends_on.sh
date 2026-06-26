#!/usr/bin/env bash
# integration: --depends-on 全链路 — CLI → DB → orchestrator claim 顺序
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"

register_cleanup_trap
TASK_CMD="$HARNESS_HOME/coordinator/tools/harness-task"

test_child_waits_for_parent_then_runs() {
  local parent_dir; parent_dir=$(make_tmp_dir); track_cleanup "$parent_dir"
  local proj; proj=$(make_fixture_project "$parent_dir")
  cd "$proj"
  set_gate_test_cmd "$proj" "test -f HELLO.txt"

  # T-CHILD 优先级更高（数小先派），但依赖 T-PARENT；orchestrator 第一轮应先派 T-PARENT
  "$TASK_CMD" add --id T-PARENT --priority 100 <<< "make HELLO.txt" >/dev/null
  "$TASK_CMD" add --id T-CHILD  --priority 50 --depends-on T-PARENT <<< "make HELLO.txt again" >/dev/null

  # 第 1 轮：claim 应跳过 T-CHILD（被阻），派 T-PARENT
  "$HARNESS_HOME/bin/harness" run-once --mock 2>&1 | tail -5

  local p_row; p_row=$("$TASK_CMD" query --task T-PARENT)
  assert_contains "merged" "$p_row" "PARENT merged first"

  local c_row; c_row=$("$TASK_CMD" query --task T-CHILD)
  assert_contains "queued" "$c_row" "CHILD still queued (PARENT not yet merged at claim time)"

  # 第 2 轮：T-PARENT 已 merged，T-CHILD 可被 claim
  "$HARNESS_HOME/bin/harness" run-once --mock 2>&1 | tail -5

  c_row=$("$TASK_CMD" query --task T-CHILD)
  assert_contains "merged" "$c_row" "CHILD merged after PARENT done"
}

test_child_with_failed_parent_blocks_indefinitely() {
  local parent_dir; parent_dir=$(make_tmp_dir); track_cleanup "$parent_dir"
  local proj; proj=$(make_fixture_project "$parent_dir")
  cd "$proj"
  # T-FAILP 永远 gate 失败
  set_gate_test_cmd "$proj" "false"
  "$TASK_CMD" add --id T-FAILP <<< "x" >/dev/null
  "$TASK_CMD" add --id T-DEP --depends-on T-FAILP <<< "y" >/dev/null

  # 让 T-FAILP 跑到 failed（max-retries=0 一次就死）
  "$HARNESS_HOME/bin/harness" run-once --mock --max-retries 0 >/dev/null 2>&1

  local p_row; p_row=$("$TASK_CMD" query --task T-FAILP)
  assert_contains "failed" "$p_row"

  # T-DEP 应保持 queued（depends_on 检查只看 merged，failed 不解除阻塞）
  "$HARNESS_HOME/bin/harness" run-once --mock >/dev/null 2>&1
  local d_row; d_row=$("$TASK_CMD" query --task T-DEP)
  assert_contains "queued" "$d_row" "depends_on failed → child blocked indefinitely"
}

run_tests
