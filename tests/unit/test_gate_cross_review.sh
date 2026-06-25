#!/usr/bin/env bash
# unit: lib/gate.sh 第 5 步 cross_review — 把 diff 喂 reviewer 拿 {approve, issues}
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"

register_cleanup_trap

_make_review_worktree() {
  # 建一个 git worktree 含一些 diff 让 cross_review 有内容审
  local d; d=$(make_tmp_dir); track_cleanup "$d"
  mkdir -p "$d/proj"
  (
    cd "$d/proj"
    git init -q
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    git config init.defaultBranch main
    echo "init" > README.md
    git add . && git commit -qm init
    git checkout -q -b harness/T-cr 2>/dev/null
    echo "// new code" > foo.txt
    git add foo.txt
    git commit -qm "add foo.txt"
  )
  echo "$d/proj"
}

_write_agents() {
  local dir="$1" reviewer="$2" enabled="$3"
  cat > "$dir/AGENTS.md" <<EOF
# test

\`\`\`gate
build: ""
lint: ""
test: ""
diff_audit: ""
cross_review_enabled: $enabled
cross_review_reviewer: $reviewer
\`\`\`
EOF
}

test_disabled_records_skipped() {
  local wt; wt=$(_make_review_worktree)
  _write_agents "$wt" "codex" "false"
  HARNESS_TASK_ID=T-cr1 bash "$HARNESS_HOME/lib/gate.sh" "$wt"
  assert_exit_code 0 "$?"
  local cr; cr=$(jq -c '.steps[] | select(.name=="cross_review")' "$wt/.gate-report.json")
  assert_eq "true" "$(printf '%s' "$cr" | jq -r '.skipped')" "disabled → skipped"
}

test_enabled_approve_passes_gate() {
  local wt; wt=$(_make_review_worktree)
  _write_agents "$wt" "codex" "true"
  export HARNESS_MOCK_ADAPTER=1
  HARNESS_TASK_ID=T-cr2 bash "$HARNESS_HOME/lib/gate.sh" "$wt"
  local rc=$?
  unset HARNESS_MOCK_ADAPTER
  assert_exit_code 0 "$rc" "default approve → green"
  local cr; cr=$(jq -c '.steps[] | select(.name=="cross_review")' "$wt/.gate-report.json")
  assert_eq "true" "$(printf '%s' "$cr" | jq -r '.ok')"
  assert_eq "false" "$(printf '%s' "$cr" | jq -r '.skipped')"
  assert_contains "approved" "$(printf '%s' "$cr" | jq -r '.output')"
}

test_enabled_reject_fails_gate() {
  local wt; wt=$(_make_review_worktree)
  _write_agents "$wt" "codex" "true"
  export HARNESS_MOCK_ADAPTER=1
  export HARNESS_MOCK_REVIEW_RESULT='{"approve":false,"issues":["unsafe SQL concat","missing test"]}'
  set +e
  HARNESS_TASK_ID=T-cr3 bash "$HARNESS_HOME/lib/gate.sh" "$wt"
  local rc=$?
  set -e
  unset HARNESS_MOCK_ADAPTER HARNESS_MOCK_REVIEW_RESULT
  assert_exit_code 1 "$rc" "review reject → gate fails"
  local cr; cr=$(jq -c '.steps[] | select(.name=="cross_review")' "$wt/.gate-report.json")
  assert_eq "false" "$(printf '%s' "$cr" | jq -r '.ok')"
  local out; out=$(printf '%s' "$cr" | jq -r '.output')
  assert_contains "rejected" "$out"
  assert_contains "unsafe SQL concat" "$out"
}

test_enabled_with_claude_reviewer_works() {
  local wt; wt=$(_make_review_worktree)
  _write_agents "$wt" "claude" "true"
  export HARNESS_MOCK_ADAPTER=1
  HARNESS_TASK_ID=T-cr4 bash "$HARNESS_HOME/lib/gate.sh" "$wt"
  local rc=$?
  unset HARNESS_MOCK_ADAPTER
  assert_exit_code 0 "$rc" "claude reviewer also approves"
}

test_missing_reviewer_adapter_fails() {
  local wt; wt=$(_make_review_worktree)
  _write_agents "$wt" "bogus_backend" "true"
  set +e
  HARNESS_TASK_ID=T-cr5 bash "$HARNESS_HOME/lib/gate.sh" "$wt"
  local rc=$?
  set -e
  assert_exit_code 1 "$rc"
  local out; out=$(jq -r '.steps[] | select(.name=="cross_review") | .output' "$wt/.gate-report.json")
  assert_contains "reviewer adapter not found" "$out"
}

test_empty_diff_skipped() {
  local d; d=$(make_tmp_dir); track_cleanup "$d"
  mkdir -p "$d/proj"
  (
    cd "$d/proj"
    git init -q
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    echo init > README.md
    git add . && git commit -qm init
  )
  _write_agents "$d/proj" "codex" "true"
  export HARNESS_MOCK_ADAPTER=1
  HARNESS_TASK_ID=T-cr6 bash "$HARNESS_HOME/lib/gate.sh" "$d/proj"
  local rc=$?
  unset HARNESS_MOCK_ADAPTER
  assert_exit_code 0 "$rc"
  local out; out=$(jq -r '.steps[] | select(.name=="cross_review") | .output' "$d/proj/.gate-report.json")
  assert_contains "empty diff" "$out"
}

run_tests
