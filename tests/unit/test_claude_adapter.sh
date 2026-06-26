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

# ── flag 装配（HARNESS_ADAPTER_DRYRUN 路径，参照 codex_adapter 风格）──────────

_dryrun_args() {
  # _dryrun_args [KEY=VAL ...] — 额外 env 传给 adapter
  local wt; wt=$(_setup_worktree)
  local prompt="$wt/.prompt.txt"; echo "x" > "$prompt"
  env HARNESS_ADAPTER_DRYRUN=1 ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
      HARNESS_HOME="$HARNESS_HOME" "$@" \
      bash "$HARNESS_HOME/adapters/claude.sh"
}

test_default_args_use_bypass_permissions() {
  local out; out=$(_dryrun_args)
  assert_contains "bypassPermissions" "$out" "non-review uses bypassPermissions"
  assert_contains "--print" "$out"
  assert_contains "--output-format" "$out"
}

test_default_args_use_max_turns() {
  local out; out=$(_dryrun_args ADAPTER_MAX_TURNS=8)
  assert_contains "--max-turns" "$out"
  assert_contains "8" "$out"
}

test_default_args_do_not_use_review_flags() {
  local out; out=$(_dryrun_args)
  for forbidden in "--json-schema" "--no-session-persistence" "--tools"; do
    if [[ "$out" == *"$forbidden"* ]]; then
      _assert_fail "write mode should not use $forbidden"
    fi
  done
}

test_review_mode_uses_json_schema() {
  local out; out=$(_dryrun_args ADAPTER_SANDBOX=read-only)
  assert_contains "--json-schema" "$out" "structured output enforced"
  # schema 内容应被嵌入（看到 approve / issues 字段名）
  assert_contains "approve" "$out"
  assert_contains "issues" "$out"
}

test_review_mode_no_session_persistence() {
  local out; out=$(_dryrun_args ADAPTER_SANDBOX=read-only)
  assert_contains "--no-session-persistence" "$out" "review not saved to disk"
}

test_review_mode_restricts_tools_to_readonly() {
  local out; out=$(_dryrun_args ADAPTER_SANDBOX=read-only)
  assert_contains "--tools" "$out"
  assert_contains "Read,Grep,Glob" "$out" "tool whitelist for review"
}

test_review_mode_omits_bypass_permissions() {
  # 只读工具不会触发权限弹窗，不应也不需要 bypassPermissions
  local out; out=$(_dryrun_args ADAPTER_SANDBOX=read-only)
  if [[ "$out" == *"bypassPermissions"* ]]; then
    _assert_fail "review mode should not need bypassPermissions"
  fi
}

test_resume_path_uses_resume_flag() {
  local out; out=$(_dryrun_args ADAPTER_SESSION_ID="01234567-89ab-cdef-0123-456789abcdef")
  assert_contains "--resume" "$out"
  assert_contains "01234567-89ab-cdef-0123-456789abcdef" "$out"
}

test_resume_with_readonly_falls_back_to_write_mode() {
  # ADAPTER_SESSION_ID 非空时 review 硬化关闭（resume 路径继续走原会话；
  # gate.sh 也不会传 sid 给 reviewer，但作防御）
  local out; out=$(_dryrun_args ADAPTER_SANDBOX=read-only \
                                 ADAPTER_SESSION_ID="01234567-89ab-cdef-0123-456789abcdef")
  # 不应有 --json-schema（review-only flag）
  if [[ "$out" == *"--json-schema"* ]]; then
    _assert_fail "resume should disable review-mode flags"
  fi
  assert_contains "--resume" "$out"
}

test_model_override_propagates() {
  local out; out=$(_dryrun_args ADAPTER_MODEL=claude-sonnet-4-6)
  assert_contains "--model" "$out"
  assert_contains "claude-sonnet-4-6" "$out"
}

run_tests
