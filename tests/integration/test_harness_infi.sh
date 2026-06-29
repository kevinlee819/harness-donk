#!/usr/bin/env bash
# integration: bin/harness-infi — 验证 tmux 多窗口 + orchestrator daemon 拉起
# 不发提示词给 claude，仅 spawn 进程；不烧 API
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"

register_cleanup_trap

_kill_session() {
  tmux kill-session -t "$1" 2>/dev/null || true
}

test_creates_session_with_two_windows() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  proj=$(pwd)  # 规范化，与 harness-infi 的 $(pwd) 对齐（fixture 路径可能含 //）

  local hash; hash=$(printf '%s' "$proj" | shasum -a 256 | cut -c1-8)
  local sess="harness-$hash"
  _kill_session "$sess"

  "$HARNESS_HOME/bin/harness-infi" --no-attach 2>&1 | tail -3

  # tmux has-session 在不存在时 rc=1，set -e 会爆；用 if 包
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    _kill_session "$sess"
    _assert_fail "tmux session not created"
  fi

  # 应有两个 window：coordinator + orchestrator
  local windows; windows=$(tmux list-windows -t "$sess" -F '#{window_index}:#{window_name}' 2>&1)
  assert_contains "coordinator" "$windows"
  assert_contains "orchestrator" "$windows"

  # orchestrator window 应有 orchestrator 进程（pane_pid 是 bash launcher，
  # 用 pgrep -P 找子进程的命令行）。注意阶段四后 orchestrator.sh 是 shim — exec 到
  # python -m harness.cli.orchestrator_cli，所以也接受 python 模块名。
  # 多窗口并发 spawn 时 launcher 的 exec 可能晚到——轮询而不是固定 sleep。
  local pane_pid; pane_pid=$(tmux list-panes -t "$sess:1" -F '#{pane_pid}' 2>/dev/null | head -1)
  local found=0
  _matches_orch() { [[ "$1" == *orchestrator.sh* || "$1" == *orchestrator_cli* ]]; }
  if [[ -n "$pane_pid" ]]; then
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      local cmd; cmd=$(ps -p "$pane_pid" -o args= 2>/dev/null || true)
      _matches_orch "$cmd" && { found=1; break; }
      local children; children=$(pgrep -P "$pane_pid" 2>/dev/null || true)
      for cpid in $children; do
        local c; c=$(ps -p "$cpid" -o args= 2>/dev/null || true)
        _matches_orch "$c" && { found=1; break 2; }
      done
      sleep 0.5
    done
  fi

  _kill_session "$sess"
  assert_eq "1" "$found" "orchestrator running in window 1"
}

test_idempotent_session_reuse() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  proj=$(pwd)  # 规范化，与 harness-infi 的 $(pwd) 对齐（fixture 路径可能含 //）

  local hash; hash=$(printf '%s' "$proj" | shasum -a 256 | cut -c1-8)
  local sess="harness-$hash"
  _kill_session "$sess"

  "$HARNESS_HOME/bin/harness-infi" --no-attach >/dev/null

  local out; out=$("$HARNESS_HOME/bin/harness-infi" --no-attach 2>&1)
  _kill_session "$sess"
  assert_contains "already exists" "$out"
}

test_unknown_backend_fails_before_session() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  local hash; hash=$(printf '%s' "$proj" | shasum -a 256 | cut -c1-8)
  _kill_session "harness-$hash"

  set +e
  "$HARNESS_HOME/bin/harness-infi" --no-attach --backend nosuch >/dev/null 2>&1
  local rc=$?
  set -e
  assert_neq "0" "$rc" "unknown backend → fast fail"

  if tmux has-session -t "harness-$hash" 2>/dev/null; then
    _kill_session "harness-$hash"
    _assert_fail "session unexpectedly created after backend check"
  fi
}

test_fails_if_not_initialized() {
  local d; d=$(make_tmp_dir); track_cleanup "$d"
  mkdir -p "$d/empty"
  cd "$d/empty"
  set +e
  local out; out=$("$HARNESS_HOME/bin/harness-infi" --no-attach 2>&1)
  local rc=$?
  set -e
  assert_neq "0" "$rc" "uninitialized → fail"
  assert_contains "not a harness project" "$out"
}

run_tests
