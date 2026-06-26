#!/usr/bin/env bash
# unit: harness attach <worker_id> — 现场快照（worker 是 Python 线程，非 tmux pane）
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"
register_cleanup_trap

HARNESS_BIN="$HARNESS_HOME/bin/harness"

_seed_worker_status() {
  # _seed_worker_status <proj> <wid> <task_id> <status> [progress]
  local proj="$1" wid="$2" tid="$3" status="$4" progress="${5:-running}"
  local dir="$proj/.harness/workers/$wid"
  mkdir -p "$dir"
  cat > "$dir/status.json" <<EOF
{"schema_version":1,"worker_id":"$wid","backend":"claude",
 "session_id":"sid-fake-1","task_id":"$tid","status":"$status",
 "branch":"harness/$tid","progress":"$progress","turns":0,
 "files_changed":0,"blockers":[],"updated":"2026-06-26T00:00:00Z"}
EOF
}

test_attach_unknown_worker_fails() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"

  set +e
  local out; out=$("$HARNESS_BIN" attach w99 2>&1)
  local rc=$?
  set -e
  assert_neq "0" "$rc" "exit non-zero for unknown worker"
  assert_contains "no such worker" "$out"
}

test_attach_worker_prints_snapshot() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  _seed_worker_status "$proj" w1 T-snap working "in gate"

  local out; out=$("$HARNESS_BIN" attach w1)
  assert_contains "Worker   : w1"        "$out"
  assert_contains "Task     : T-snap"    "$out"
  assert_contains "Status   : working"   "$out"
  assert_contains "Branch   : harness/T-snap" "$out"
  assert_contains "Progress : in gate"   "$out"
}

test_attach_with_guidance_shows_question() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  _seed_worker_status "$proj" w2 T-blk working "awaiting answer"
  cat > "$proj/.harness/workers/w2/guidance.json" <<'EOF'
{"schema_version":1,"blocking":true,"task_id":"T-blk",
 "question":"A or B?","context":"need a decision","created":"2026-06-26T00:00:00Z"}
EOF

  local out; out=$("$HARNESS_BIN" attach w2)
  assert_contains "Guidance (blocking)" "$out"
  assert_contains "A or B?"             "$out"
  assert_contains "need a decision"     "$out"
}

test_attach_path_only_prints_worktree() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  proj=$(pwd)  # 规范化路径以匹配 harness 内部 $(pwd)（fixture 可能含 //）
  _seed_worker_status "$proj" w3 T-path merged "merged"
  local wt; wt="$(dirname "$proj")/.worktrees/$(basename "$proj")/T-path"
  mkdir -p "$wt"

  local out; out=$("$HARNESS_BIN" attach w3 --path)
  assert_eq "$wt" "$out" "prints worktree path only"
}

test_attach_path_missing_worktree_exits_nonzero() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  _seed_worker_status "$proj" w4 T-gone merged "merged"
  # do NOT create worktree

  set +e
  local out; out=$("$HARNESS_BIN" attach w4 --path 2>&1)
  local rc=$?
  set -e
  assert_neq "0" "$rc" "--path on missing worktree exits non-zero"
  assert_contains "worktree gone" "$out"
}

run_tests
