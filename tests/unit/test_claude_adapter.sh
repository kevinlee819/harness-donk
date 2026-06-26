#!/usr/bin/env bash
# unit: adapters/claude.sh mock 路径 + 错误归一化
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"

register_cleanup_trap

_setup_worktree() {
  local d; d=$(make_tmp_dir); track_cleanup "$d"
  mkdir -p "$d/wt"
  (cd "$d/wt" && git init -q && git config user.email t@t && git config user.name t && \
   git config commit.gpgsign false && echo "init" > README.md && git add . && git commit -qm i)
  echo "$d/wt"
}

test_mock_writes_hello_and_returns_ok() {
  local wt; wt=$(_setup_worktree)
  local prompt="$wt/.prompt.txt"
  echo "make HELLO.txt" > "$prompt"
  local resp
  resp=$(HARNESS_MOCK_ADAPTER=1 \
    ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
    ADAPTER_TASK_ID=T-cl1 ADAPTER_WORKER_ID=w1 \
    bash "$HARNESS_HOME/adapters/claude.sh")
  assert_json_field "$resp" '.ok' 'true'
  assert_file_exists "$wt/HELLO.txt"
  # session_id 应是 mock 默认值
  local sid; sid=$(printf '%s' "$resp" | jq -r '.session_id')
  assert_match "00000000-0000-0000-0000-000000000001" "$sid"
}

test_mock_blocking_writes_guidance() {
  local wt; wt=$(_setup_worktree)
  local prompt="$wt/.prompt.txt"
  echo "x" > "$prompt"
  local wd="$wt/.harness/workers/w1"; mkdir -p "$wd"
  local resp
  resp=$(HARNESS_MOCK_ADAPTER=1 HARNESS_MOCK_BLOCK=1 HARNESS_MOCK_BLOCK_QUESTION="A or B?" \
    ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
    ADAPTER_WORKER_DIR="$wd" ADAPTER_TASK_ID=T-clb ADAPTER_WORKER_ID=w1 \
    bash "$HARNESS_HOME/adapters/claude.sh")
  assert_json_field "$resp" '.ok' 'true'
  assert_file_exists "$wd/guidance.json"
  assert_eq "true" "$(jq -r '.blocking' "$wd/guidance.json")"
  assert_eq "A or B?" "$(jq -r '.question' "$wd/guidance.json")"
}

test_mock_review_returns_default_approve() {
  local wt; wt=$(_setup_worktree)
  local prompt="$wt/.prompt.txt"
  echo "=== REVIEW DIFF ===" > "$prompt"
  local resp
  resp=$(HARNESS_MOCK_ADAPTER=1 \
    ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
    bash "$HARNESS_HOME/adapters/claude.sh")
  local approve; approve=$(printf '%s' "$resp" | jq -r '.result' | jq -r '.approve')
  assert_eq "true" "$approve"
}

test_mock_review_returns_custom_reject() {
  local wt; wt=$(_setup_worktree)
  local prompt="$wt/.prompt.txt"
  echo "=== REVIEW DIFF ===" > "$prompt"
  local resp
  resp=$(HARNESS_MOCK_ADAPTER=1 HARNESS_MOCK_REVIEW_RESULT='{"approve":false,"issues":["xyz"]}' \
    ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
    bash "$HARNESS_HOME/adapters/claude.sh")
  local r; r=$(printf '%s' "$resp" | jq -r '.result')
  assert_eq "false" "$(printf '%s' "$r" | jq -r '.approve')"
  assert_eq "xyz" "$(printf '%s' "$r" | jq -r '.issues[0]')"
}

test_missing_task_file_fails() {
  local wt; wt=$(_setup_worktree)
  set +e
  local out; out=$(HARNESS_MOCK_ADAPTER=1 \
    ADAPTER_TASK_FILE="$wt/no-such-prompt.txt" ADAPTER_WORKTREE="$wt" \
    bash "$HARNESS_HOME/adapters/claude.sh" 2>&1)
  local rc=$?
  set -e
  assert_neq "0" "$rc"
  assert_contains "task file not found" "$out"
}

test_missing_worktree_fails() {
  local prompt; prompt=$(mktemp); echo x > "$prompt"
  set +e
  local out; out=$(HARNESS_MOCK_ADAPTER=1 \
    ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="/no/such/dir" \
    bash "$HARNESS_HOME/adapters/claude.sh" 2>&1)
  local rc=$?
  set -e
  assert_neq "0" "$rc"
  assert_contains "worktree not found" "$out"
  rm -f "$prompt"
}

run_tests
