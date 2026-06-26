#!/usr/bin/env bash
# integration: kill -9 续跑回归 — 编排器跑到一半被 SIGKILL → 重启后 orphan reaper
# 接管 → 任务正确续跑到 MERGED。覆盖阶段二崩溃恢复路径的端到端真序列。
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"

register_cleanup_trap
TASK_CMD="$HARNESS_HOME/coordinator/tools/harness-task"

# 递归杀进程树（macOS / Linux 都可，不依赖 setsid）
_kill_tree() {
  local pid="$1"
  local kids
  kids=$(pgrep -P "$pid" 2>/dev/null || true)
  for k in $kids; do
    _kill_tree "$k"
  done
  kill -KILL "$pid" 2>/dev/null || true
}

# 轮询直到任务进入指定状态，或超时
_wait_status() {
  local db="$1" tid="$2" want="$3" timeout="${4:-50}"  # timeout in 100ms ticks
  local i
  for (( i=0; i<timeout; i++ )); do
    local s; s=$(sqlite3 "$db" "SELECT status FROM tasks WHERE id='$tid'")
    [[ "$s" == "$want" ]] && return 0
    sleep 0.1
  done
  return 1
}

test_kill_mid_task_recovers_via_orphan_reaper() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  set_gate_test_cmd "$proj" "test -f HELLO.txt"

  # 配置：dead_worker_threshold_min=0 让 reaper 立刻识别 transient 状态的任务
  export HARNESS_CONFIG_DIR="$proj/.harness/_conf"
  mkdir -p "$HARNESS_CONFIG_DIR"
  echo "dead_worker_threshold_min=0" > "$HARNESS_CONFIG_DIR/config"

  "$TASK_CMD" add --id T-kill <<< "create HELLO.txt" >/dev/null

  # 后台跑 orchestrator，mock adapter 睡 3s 给我们留杀窗口
  local db="$proj/.harness/harness.db"
  (
    cd "$proj"
    HARNESS_MOCK_SLEEP_S=3 HARNESS_CONFIG_DIR="$HARNESS_CONFIG_DIR" \
      "$HARNESS_HOME/orchestrator.sh" --mock --max-workers 1 >/dev/null 2>&1
  ) &
  local orch_pid=$!

  # 等 worker 进入 working（adapter 已被调，正在 sleep）
  _wait_status "$db" "T-kill" "working" 50 || {
    _kill_tree "$orch_pid"
    _assert_fail "task did not enter 'working' within 5s"
    return 1
  }

  # 抢杀进程树（含正在 sleep 的 adapter 子进程，避免它继续 commit 制造竞争）
  _kill_tree "$orch_pid"
  wait "$orch_pid" 2>/dev/null || true

  # 确认 kill 时机 — 任务仍在 transient 状态（不是 merged）
  local stat_after_kill; stat_after_kill=$(sqlite3 "$db" "SELECT status FROM tasks WHERE id='T-kill'")
  if [[ "$stat_after_kill" == "merged" ]]; then
    _assert_fail "task completed before kill (sleep window too short); test inconclusive"
    return 1
  fi
  case "$stat_after_kill" in
    working|dispatched|gating) ;;  # transient — 符合期望
    *) _assert_fail "expected transient state after kill, got: $stat_after_kill"; return 1 ;;
  esac

  # SQL `updated < datetime('now', '-0 minutes')` 是严格小于；同一秒的 updated
  # 与 now 比较为假，所以等任务 updated 至少老 1 秒再启动 reaper。
  sleep 1

  # 重启 orchestrator（--once 流：reap 一个孤儿 → 跑完一个任务 → 退出）
  HARNESS_CONFIG_DIR="$HARNESS_CONFIG_DIR" \
    "$HARNESS_HOME/bin/harness" run-once --mock 2>&1 | tail -10

  # 终态校验
  local row; row=$("$TASK_CMD" query --task T-kill)
  assert_contains "merged" "$row" "after restart → orphan reaped → re-run → merged"

  local reds; reds=$(sqlite3 "$db" "SELECT redispatches FROM tasks WHERE id='T-kill';")
  assert_eq "1" "$reds" "redispatches=1 (one reap)"

  local hist; hist=$("$TASK_CMD" history T-kill)
  assert_contains "orphan_redispatch" "$hist" "transition reason recorded"

  # task_completed 事件应有（最终 merge 触发）
  local n_done; n_done=$(sqlite3 "$db" \
    "SELECT COUNT(*) FROM events WHERE task_id='T-kill' AND event_type='task_completed';")
  assert_eq "1" "$n_done" "task_completed event emitted on final merge"
}

test_kill_with_max_redispatches_reached_goes_failed() {
  # 把任务的 redispatches 直接 fossilize 到上限 → 重启时 reaper 看到老 transient
  # 状态 + reds >= MAX → 直接 FAILED 而不是再 queued
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  export HARNESS_CONFIG_DIR="$proj/.harness/_conf"
  mkdir -p "$HARNESS_CONFIG_DIR"
  echo "dead_worker_threshold_min=0" > "$HARNESS_CONFIG_DIR/config"

  "$TASK_CMD" add --id T-deadkill <<< "x" >/dev/null
  # 模拟"上次崩溃留下"，且已重派到上限
  sqlite3 "$proj/.harness/harness.db" \
    "UPDATE tasks SET status='working', worker_id='w1', branch='harness/T-deadkill',
                      redispatches=2, updated='2020-01-01T00:00:00Z'
       WHERE id='T-deadkill';"

  HARNESS_CONFIG_DIR="$HARNESS_CONFIG_DIR" \
    "$HARNESS_HOME/bin/harness" run-once --mock 2>&1 | tail -5

  local row; row=$("$TASK_CMD" query --task T-deadkill)
  assert_contains "failed" "$row" "reds >= max → FAILED (not queued again)"

  local n_ev; n_ev=$(sqlite3 "$proj/.harness/harness.db" \
    "SELECT COUNT(*) FROM events WHERE task_id='T-deadkill' AND event_type='task_failed';")
  assert_eq "1" "$n_ev" "task_failed event emitted"
}

run_tests
