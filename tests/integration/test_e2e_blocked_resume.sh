#!/usr/bin/env bash
# integration: worker 写 blocking guidance → BLOCKED + needs_decision → 答复 → resume → MERGED
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"

register_cleanup_trap
TASK_CMD="$HARNESS_HOME/coordinator/tools/harness-task"

test_blocked_then_resumed_to_merged() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"

  # gate: HELLO.txt 必须存在（mock 在 resume 那轮会创建）
  set_gate_test_cmd "$proj" "test -f HELLO.txt"

  "$TASK_CMD" add --id T-blk <<< "create HELLO.txt with deliberation" >/dev/null

  # 第一次跑：mock 走 BLOCK 路径写 guidance.json，不创建 HELLO.txt
  HARNESS_MOCK_BLOCK=1 HARNESS_MOCK_BLOCK_QUESTION="A or B?" \
    "$HARNESS_HOME/bin/harness" run-once --mock 2>&1 | tail -20

  # 任务应处于 BLOCKED
  local row; row=$("$TASK_CMD" query --task T-blk)
  assert_contains "blocked" "$row" "first run → blocked"

  # needs_decision 事件应已记录
  local n_ev; n_ev=$(sqlite3 "$proj/.harness/harness.db" \
    "SELECT COUNT(*) FROM events WHERE task_id='T-blk' AND event_type='needs_decision';")
  assert_eq "1" "$n_ev" "needs_decision event emitted"

  # guidance.json 应在 worker 目录
  assert_file_exists "$proj/.harness/workers/w1/guidance.json" "guidance written"

  # 通过 harness-task answer 写 inbox
  "$TASK_CMD" answer T-blk "do A and finish" >/dev/null
  assert_file_exists "$proj/.harness/inbox/T-blk.answer" "inbox answer written"

  # 第二次跑：不带 BLOCK 标志 → 正常 mock 行为，scanner 应捡 answer 走 resume
  "$HARNESS_HOME/bin/harness" run-once --mock 2>&1 | tail -20

  # 任务应到 MERGED
  row=$("$TASK_CMD" query --task T-blk)
  assert_contains "merged" "$row" "after resume → merged"

  # guidance.json 应被清掉（避免下轮再触发 BLOCKED）
  assert_file_absent "$proj/.harness/workers/w1/guidance.json" "guidance cleared on resume"

  # inbox 应归档
  assert_file_absent "$proj/.harness/inbox/T-blk.answer" "inbox consumed"
  local n_processed; n_processed=$(ls "$proj/.harness/inbox/processed/" 2>/dev/null | wc -l | tr -d ' ')
  assert_neq "0" "$n_processed" "answer moved to processed/"

  # transitions 链路：working → blocked → working(answered) → gating → merged
  local hist; hist=$("$TASK_CMD" history T-blk)
  assert_contains "blocked" "$hist"
  assert_contains "needs_decision" "$hist"
  assert_contains "answered" "$hist"
  assert_contains "merged" "$hist"

  # HELLO.txt 应在主分支
  assert_file_exists "$proj/HELLO.txt"

  # 两类终态事件都应有
  local n_done; n_done=$(sqlite3 "$proj/.harness/harness.db" \
    "SELECT COUNT(*) FROM events WHERE task_id='T-blk' AND event_type='task_completed';")
  assert_eq "1" "$n_done" "task_completed emitted on final merge"
}

test_blocked_without_answer_stays_blocked() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"

  set_gate_test_cmd "$proj" "test -f HELLO.txt"
  "$TASK_CMD" add --id T-blk2 <<< "create HELLO.txt" >/dev/null

  HARNESS_MOCK_BLOCK=1 "$HARNESS_HOME/bin/harness" run-once --mock >/dev/null 2>&1

  local row; row=$("$TASK_CMD" query --task T-blk2)
  assert_contains "blocked" "$row" "first run → blocked"

  # 再跑一次，无 answer：scanner 应跳过该任务，队列空 → 立即退出
  "$HARNESS_HOME/bin/harness" run-once --mock >/dev/null 2>&1

  row=$("$TASK_CMD" query --task T-blk2)
  assert_contains "blocked" "$row" "no answer → still blocked"
}

run_tests
