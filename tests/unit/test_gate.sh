#!/usr/bin/env bash
# unit: lib/gate.sh
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"

register_cleanup_trap

_make_worktree_with_agents() {
  # _make_worktree_with_agents <test_name> <gate_block>
  local name="$1" block="$2"
  local d; d=$(make_tmp_dir); track_cleanup "$d"
  mkdir -p "$d/proj"
  cat > "$d/proj/AGENTS.md" <<EOF
# fake project

\`\`\`gate
$block
\`\`\`
EOF
  echo "$d/proj"
}

test_all_skipped_when_commands_empty() {
  local wt; wt=$(_make_worktree_with_agents skipall '
build: ""
lint: ""
test: ""
diff_audit: ""
')
  HARNESS_TASK_ID=T-skip bash "$HARNESS_HOME/lib/gate.sh" "$wt"
  local rc=$?
  assert_exit_code 0 "$rc" "all skipped → green"
  assert_file_exists "$wt/.gate-report.json"
  local ok; ok=$(jq -r '.ok' "$wt/.gate-report.json")
  assert_eq "true" "$ok"
  # 全部 skipped=true
  local n_skipped; n_skipped=$(jq '[.steps[] | select(.skipped==true)] | length' "$wt/.gate-report.json")
  assert_eq "5" "$n_skipped" "build/lint/test/diff_audit/cross_review all skipped"
}

test_pass_when_commands_succeed() {
  local wt; wt=$(_make_worktree_with_agents pass '
build: ""
lint: "echo lint-ok"
test: "echo test-ok"
diff_audit: ""
')
  HARNESS_TASK_ID=T-pass bash "$HARNESS_HOME/lib/gate.sh" "$wt"
  assert_exit_code 0 "$?"
  local ok; ok=$(jq -r '.ok' "$wt/.gate-report.json")
  assert_eq "true" "$ok"
}

test_fail_when_test_fails() {
  local wt; wt=$(_make_worktree_with_agents failtest '
build: ""
lint: ""
test: "false"
diff_audit: ""
')
  set +e
  HARNESS_TASK_ID=T-failt bash "$HARNESS_HOME/lib/gate.sh" "$wt"
  local rc=$?
  set -e
  assert_exit_code 1 "$rc" "test=false → nonzero"
  local ok; ok=$(jq -r '.ok' "$wt/.gate-report.json")
  assert_eq "false" "$ok"
  local summary; summary=$(jq -r '.summary' "$wt/.gate-report.json")
  assert_contains "test failed" "$summary"
}

test_captures_failing_output() {
  local wt; wt=$(_make_worktree_with_agents capture '
build: ""
lint: ""
test: "echo specific-error-marker >&2; exit 1"
diff_audit: ""
')
  set +e
  HARNESS_TASK_ID=T-cap bash "$HARNESS_HOME/lib/gate.sh" "$wt" 2>/dev/null
  set -e
  local out; out=$(jq -r '.steps[] | select(.name=="test") | .output' "$wt/.gate-report.json")
  assert_contains "specific-error-marker" "$out" "stderr captured"
}

test_report_schema_version() {
  local wt; wt=$(_make_worktree_with_agents schema '
build: ""
lint: ""
test: ""
diff_audit: ""
')
  HARNESS_TASK_ID=T-sv bash "$HARNESS_HOME/lib/gate.sh" "$wt"
  local sv; sv=$(jq -r '.schema_version' "$wt/.gate-report.json")
  assert_eq "1" "$sv"
}

test_no_agents_md_treats_all_as_skipped() {
  local d; d=$(make_tmp_dir); track_cleanup "$d"
  mkdir -p "$d/proj"
  HARNESS_TASK_ID=T-nomd bash "$HARNESS_HOME/lib/gate.sh" "$d/proj"
  assert_exit_code 0 "$?"
  local ok; ok=$(jq -r '.ok' "$d/proj/.gate-report.json")
  assert_eq "true" "$ok"
}

run_tests
