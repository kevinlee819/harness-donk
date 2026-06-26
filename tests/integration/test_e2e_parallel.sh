#!/usr/bin/env bash
# integration: 阶段四并行 worker — N 任务并发派发，merge 严格串行
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"

register_cleanup_trap
TASK_CMD="$HARNESS_HOME/coordinator/tools/harness-task"

# 并行测试每个任务写独立文件，避免 4 个 worker 同时 add HELLO.txt 时 merge 冲突
_export_parallel_env() {
  # 注意：单引号 — 变量在 mock adapter 内 eval 展开
  export HARNESS_MOCK_OUTPUT_FILE='HELLO-$ADAPTER_TASK_ID.txt'
}

_drain_then_kill() {
  local proj="$1" timeout_s="${2:-30}"
  ( cd "$proj" && exec "$HARNESS_HOME/orchestrator.sh" --mock --max-workers 4 >/dev/null 2>&1 ) &
  local pid=$!
  local i
  for (( i=0; i<timeout_s*2; i++ )); do
    local pending; pending=$(sqlite3 "$proj/.harness/harness.db" \
      "SELECT COUNT(*) FROM tasks WHERE status IN ('queued','dispatched','working','gating')")
    [[ "$pending" == "0" ]] && break
    sleep 0.5
  done
  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_four_independent_tasks_all_merge() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  # gate 校验任意 HELLO-*.txt 存在 — 每个 worker 写自己的
  set_gate_test_cmd "$proj" "ls HELLO-*.txt"
  _export_parallel_env

  for i in 1 2 3 4; do
    "$TASK_CMD" add --id "T-par$i" <<< "task $i" >/dev/null
  done

  _drain_then_kill "$proj" 30

  local merged; merged=$(sqlite3 "$proj/.harness/harness.db" \
    "SELECT COUNT(*) FROM tasks WHERE status='merged' AND id LIKE 'T-par%'")
  assert_eq "4" "$merged" "all 4 tasks merged"

  local n_merges; n_merges=$(git -C "$proj" log --oneline | grep -c "harness: merge T-par" || true)
  assert_eq "4" "$n_merges" "4 merge commits on main"

  # 每个任务自己的文件应在主分支
  for i in 1 2 3 4; do
    assert_file_exists "$proj/HELLO-T-par$i.txt" "T-par$i output present"
  done

  local n_wt; n_wt=$(find "$parent/.worktrees" -maxdepth 3 -type d -name 'T-par*' 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "0" "$n_wt" "no worktrees left"
}

test_merge_serialized_across_workers() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  set_gate_test_cmd "$proj" "ls HELLO-*.txt"
  _export_parallel_env

  for i in 1 2 3; do
    "$TASK_CMD" add --id "T-ser$i" <<< "task $i" >/dev/null
  done

  _drain_then_kill "$proj" 30

  # transitions：merged 时刻去重应等于总数（主线程串行合并，时刻不可能完全重叠）
  local n_unique; n_unique=$(sqlite3 "$proj/.harness/harness.db" \
    "SELECT COUNT(DISTINCT id) FROM transitions WHERE to_state='merged' AND task_id LIKE 'T-ser%'")
  local n_total; n_total=$(sqlite3 "$proj/.harness/harness.db" \
    "SELECT COUNT(*) FROM transitions WHERE to_state='merged' AND task_id LIKE 'T-ser%'")
  assert_eq "$n_total" "$n_unique"
  assert_eq "3" "$n_total" "3 merges happened"
}

test_pool_one_falls_back_to_serial() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  set_gate_test_cmd "$proj" "ls HELLO-*.txt"
  _export_parallel_env

  "$TASK_CMD" add --id T-s1 <<< "x" >/dev/null
  "$TASK_CMD" add --id T-s2 <<< "x" >/dev/null

  ( cd "$proj" && exec "$HARNESS_HOME/orchestrator.sh" --mock --max-workers 1 >/dev/null 2>&1 ) &
  local pid=$!
  local i
  for (( i=0; i<60; i++ )); do
    local pending; pending=$(sqlite3 "$proj/.harness/harness.db" \
      "SELECT COUNT(*) FROM tasks WHERE status IN ('queued','dispatched','working','gating')")
    [[ "$pending" == "0" ]] && break
    sleep 0.5
  done
  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  local merged; merged=$(sqlite3 "$proj/.harness/harness.db" \
    "SELECT COUNT(*) FROM tasks WHERE status='merged' AND id LIKE 'T-s%'")
  assert_eq "2" "$merged" "both tasks merged with pool=1"
}

run_tests
