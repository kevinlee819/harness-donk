#!/usr/bin/env bash
# integration: 完整成功路径 — 入队 → mock adapter → gate → merge
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"

register_cleanup_trap
TASK_CMD="$HARNESS_HOME/coordinator/tools/harness-task"

test_full_happy_path() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"

  # gate test 必须能过 — 用 mock adapter 会创建 HELLO.txt，所以 test 用 test -f HELLO.txt
  set_gate_test_cmd "$proj" "test -f HELLO.txt"

  # 入队
  local out; out=$("$TASK_CMD" add --id T-happy <<< "create HELLO.txt")
  assert_json_field "$out" '.ok' 'true'

  # 跑一轮 mock 模式
  "$HARNESS_HOME/bin/harness" run-once --mock 2>&1 | tail -20

  # 验证最终状态
  local row; row=$("$TASK_CMD" query --task T-happy)
  assert_contains "merged" "$row" "task ended in merged"

  # 主分支应有 merge 提交 + mock 提交
  local log; log=$(git -C "$proj" log --oneline)
  assert_contains "harness: merge T-happy" "$log"
  assert_contains "mock:" "$log"

  # HELLO.txt 应在主分支
  assert_file_exists "$proj/HELLO.txt"

  # transitions 完整
  local hist; hist=$("$TASK_CMD" history T-happy)
  assert_contains "merged" "$hist"

  # worktree 应被回收
  assert_file_absent "$parent/.worktrees/proj/T-happy" "worktree cleaned"

  # calls 表应有记录
  local n_calls; n_calls=$(sqlite3 "$proj/.harness/harness.db" "SELECT COUNT(*) FROM calls WHERE task_id='T-happy';")
  assert_neq "0" "$n_calls" "call recorded"

  # 阶段二：MERGED 终态写了 task_completed 事件
  local n_ev; n_ev=$(sqlite3 "$proj/.harness/harness.db" \
    "SELECT COUNT(*) FROM events WHERE task_id='T-happy' AND event_type='task_completed';")
  assert_eq "1" "$n_ev" "task_completed event emitted on MERGED"

  # events/ 目录也有 JSON
  local ev_files; ev_files=$(ls "$proj/.harness/events/"*task_completed*T-happy*.json 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "1" "$ev_files" "event JSON file written"

  # MERGED 自动备份
  local n_backup; n_backup=$(ls "$proj/.harness/backups/" 2>/dev/null | wc -l | tr -d ' ')
  assert_neq "0" "$n_backup" "auto-backup on merge"
}

test_status_history_flag_shows_transitions() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  set_gate_test_cmd "$proj" "test -f HELLO.txt"

  "$TASK_CMD" add --id T-hist <<< "create HELLO.txt" >/dev/null
  "$HARNESS_HOME/bin/harness" run-once --mock >/dev/null 2>&1

  local out; out=$("$HARNESS_HOME/bin/harness" status --task T-hist --history)
  assert_contains "first_dispatch" "$out"
  assert_contains "merged" "$out"
  assert_contains "ok" "$out"
}

run_tests
