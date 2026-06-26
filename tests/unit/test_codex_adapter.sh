#!/usr/bin/env bash
# unit: adapters/codex.sh mock 路径 + 串行锁
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

test_mock_writes_codex_txt_and_returns_ok() {
  local wt; wt=$(_setup_worktree)
  local prompt="$wt/.prompt.txt"
  echo "make CODEX.txt" > "$prompt"
  local wd="$wt/.harness/workers/w1"; mkdir -p "$wd"
  local resp
  resp=$(HARNESS_MOCK_ADAPTER=1 \
    ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
    ADAPTER_WORKER_DIR="$wd" ADAPTER_TASK_ID=T-cx1 ADAPTER_WORKER_ID=w1 \
    bash "$HARNESS_HOME/adapters/codex.sh")
  assert_json_field "$resp" '.ok' 'true'
  assert_file_exists "$wt/CODEX.txt"
  # 应清掉锁
  assert_file_absent "$wt/.codex.lock"
}

test_mock_blocking_writes_guidance() {
  local wt; wt=$(_setup_worktree)
  local prompt="$wt/.prompt.txt"
  echo "x" > "$prompt"
  local wd="$wt/.harness/workers/w1"; mkdir -p "$wd"
  local resp
  resp=$(HARNESS_MOCK_ADAPTER=1 HARNESS_MOCK_BLOCK=1 HARNESS_MOCK_BLOCK_QUESTION="cx?" \
    ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
    ADAPTER_WORKER_DIR="$wd" ADAPTER_TASK_ID=T-cxb ADAPTER_WORKER_ID=w1 \
    bash "$HARNESS_HOME/adapters/codex.sh")
  assert_json_field "$resp" '.ok' 'true'
  assert_file_exists "$wd/guidance.json"
  local blk; blk=$(jq -r '.blocking' "$wd/guidance.json")
  assert_eq "true" "$blk"
}

test_mock_review_returns_json_result() {
  local wt; wt=$(_setup_worktree)
  local prompt="$wt/.prompt.txt"
  cat > "$prompt" <<EOF
=== REVIEW DIFF ===
some diff text here
EOF
  local resp
  resp=$(HARNESS_MOCK_ADAPTER=1 HARNESS_MOCK_REVIEW_RESULT='{"approve":false,"issues":["bad style"]}' \
    ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
    ADAPTER_TASK_ID=T-cxr ADAPTER_WORKER_ID=w1 \
    bash "$HARNESS_HOME/adapters/codex.sh")
  assert_json_field "$resp" '.ok' 'true'
  local result; result=$(printf '%s' "$resp" | jq -r '.result')
  local approve; approve=$(printf '%s' "$result" | jq -r '.approve')
  assert_eq "false" "$approve"
  local issue0; issue0=$(printf '%s' "$result" | jq -r '.issues[0]')
  assert_eq "bad style" "$issue0"
}

test_mock_review_default_approves() {
  local wt; wt=$(_setup_worktree)
  local prompt="$wt/.prompt.txt"
  echo "=== REVIEW DIFF ===" > "$prompt"
  local resp
  resp=$(HARNESS_MOCK_ADAPTER=1 \
    ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
    bash "$HARNESS_HOME/adapters/codex.sh")
  local approve; approve=$(printf '%s' "$resp" | jq -r '.result' | jq -r '.approve')
  assert_eq "true" "$approve" "default review approves"
}

test_resume_passes_uuid_to_codex_args() {
  # 验证 UUID 形态的 ADAPTER_SESSION_ID 触发 `exec ... resume <uuid>` 路径
  # 通过 mock：mock 不真调 codex，但我们可观察 mock 也会接收 ADAPTER_SESSION_ID
  # 此处实际 codex 调用太贵；改成只检查 capability bitmap + 输入校验路径
  local wt; wt=$(_setup_worktree)
  local prompt="$wt/.prompt.txt"; echo "x" > "$prompt"
  local resp
  resp=$(HARNESS_MOCK_ADAPTER=1 \
    ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
    ADAPTER_SESSION_ID="01934dac-0000-7000-8000-abc000000001" \
    ADAPTER_TASK_ID=T-resume ADAPTER_WORKER_ID=w1 \
    bash "$HARNESS_HOME/adapters/codex.sh")
  assert_json_field "$resp" '.ok' 'true'
  # mock 模式下 session_id 保持传入值
  local sid; sid=$(printf '%s' "$resp" | jq -r '.session_id')
  # mock 用 fake_sid="${ADAPTER_SESSION_ID:-...}"，所以应保留传入的 UUID
  assert_eq "01934dac-0000-7000-8000-abc000000001" "$sid" "resume preserves session_id"
}

test_missing_task_file_fails() {
  local wt; wt=$(_setup_worktree)
  set +e
  local out; out=$(HARNESS_MOCK_ADAPTER=1 \
    ADAPTER_TASK_FILE="$wt/nope.txt" ADAPTER_WORKTREE="$wt" \
    bash "$HARNESS_HOME/adapters/codex.sh" 2>&1)
  local rc=$?
  set -e
  assert_neq "0" "$rc"
  assert_contains "task file not found" "$out"
}

test_serial_lock_held_during_call_released_after() {
  # 单进程跑也能验证锁被正确释放
  local wt; wt=$(_setup_worktree)
  local prompt="$wt/.prompt.txt"; echo "x" > "$prompt"
  HARNESS_MOCK_ADAPTER=1 ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
    bash "$HARNESS_HOME/adapters/codex.sh" >/dev/null
  assert_file_absent "$wt/.codex.lock" "lock released after exit"
}

# ── flag 装配（HARNESS_ADAPTER_DRYRUN 路径）──────────────────
# 不调真 codex，只检查 _args 装配是否符合 codex-rs 源码约束 + 安全策略

_dryrun_args() {
  # _dryrun_args [KEY=VAL ...] — extra env applied to the adapter call.
  # 必须 `env` 引导：bash 内联 KEY=VAL 只在命令首位生效，跟在 "$@" 后会被当成命令名。
  local wt; wt=$(_setup_worktree)
  local prompt="$wt/.prompt.txt"; echo "x" > "$prompt"
  env HARNESS_ADAPTER_DRYRUN=1 ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
      HARNESS_HOME="$HARNESS_HOME" "$@" \
      bash "$HARNESS_HOME/adapters/codex.sh"
}

test_default_args_use_workspace_write_no_yolo() {
  # 关键安全检查：必须用 -s workspace-write，绝不能传 --dangerously-bypass...
  # （codex-rs/exec/src/lib.rs:294 显示 bypass 会强制 DangerFullAccess，覆盖 -s）
  local out; out=$(_dryrun_args)
  assert_contains "workspace-write" "$out" "-s workspace-write present"
  if [[ "$out" == *"--dangerously-bypass-approvals-and-sandbox"* ]]; then
    _assert_fail "--dangerously-bypass-approvals-and-sandbox snuck back in (forces DangerFullAccess)"
  fi
}

test_default_args_omit_ask_for_approval() {
  # codex exec headless 默认 approval_policy=Never；-a 不是 exec 选项，
  # 也不通过 inherit_exec_root_options 传递。我们不应传。
  local out; out=$(_dryrun_args)
  if [[ "$out" == *"--ask-for-approval"* ]]; then
    _assert_fail "--ask-for-approval should not be passed (default is Never, flag is no-op for exec)"
  fi
}

test_default_args_use_json_and_skip_git_check() {
  local out; out=$(_dryrun_args)
  assert_contains "--json" "$out"
  assert_contains "--skip-git-repo-check" "$out"
  assert_contains "-o" "$out" "-o LAST_MSG fallback"
}

test_review_mode_adds_ephemeral_and_output_schema() {
  local out; out=$(_dryrun_args ADAPTER_SANDBOX=read-only)
  assert_contains "read-only" "$out" "-s read-only"
  assert_contains "--ephemeral" "$out" "review session not persisted"
  assert_contains "--output-schema" "$out" "structured output enforced"
  assert_contains "review-response.schema.json" "$out" "schema path present"
}

test_review_mode_disables_web_search() {
  local out; out=$(_dryrun_args ADAPTER_SANDBOX=read-only)
  assert_contains 'web_search="disabled"' "$out" "web search off for review"
}

test_write_mode_does_not_force_ephemeral() {
  # 写任务需要 session 持久化以便 resume — 默认不应 --ephemeral
  local out; out=$(_dryrun_args)
  if [[ "$out" == *"--ephemeral"* ]]; then
    _assert_fail "write mode should persist session, but --ephemeral was passed"
  fi
}

test_resume_by_uuid_uses_resume_subcommand() {
  local out; out=$(_dryrun_args ADAPTER_SESSION_ID="01934dac-0000-7000-8000-abc000000002")
  assert_contains "resume" "$out"
  assert_contains "01934dac-0000-7000-8000-abc000000002" "$out"
  # -C 必须先于 resume 子命令（clap 限制 codex-rs/exec/src/cli.rs）
  local cd_line; cd_line=$(printf '%s\n' "$out" | grep -n '^-C$' | head -1 | cut -d: -f1)
  local resume_line; resume_line=$(printf '%s\n' "$out" | grep -n '^resume$' | head -1 | cut -d: -f1)
  [[ -n "$cd_line" && -n "$resume_line" && "$cd_line" -lt "$resume_line" ]] \
    || _assert_fail "-C must precede 'resume' subcommand (clap requirement)"
}

test_resume_non_uuid_falls_back_to_last() {
  local out; out=$(_dryrun_args ADAPTER_SESSION_ID="not-a-uuid")
  assert_contains "resume" "$out"
  assert_contains -- "--last" "$out" "non-UUID sid → --last fallback"
}

test_capability_bitmap_session_id_programmatic_is_one() {
  # codex 0.142+ 暴露 thread_id via thread.started 事件，bitmap 应同步
  local src; src=$(cat "$HARNESS_HOME/adapters/codex.sh")
  assert_contains "ADAPTER_CAP_SESSION_ID_PROGRAMMATIC=1" "$src"
}

test_review_schema_file_is_valid_json() {
  local schema="$HARNESS_HOME/schema/json/review-response.schema.json"
  assert_file_exists "$schema"
  jq -e . "$schema" >/dev/null 2>&1 || _assert_fail "schema is not valid JSON"
  # 应声明 approve + issues
  local req; req=$(jq -r '.required | join(",")' "$schema")
  assert_contains "approve" "$req"
  assert_contains "issues" "$req"
  # additionalProperties: false 让 strict 校验拒绝意外字段
  local addl; addl=$(jq -r '.additionalProperties' "$schema")
  assert_eq "false" "$addl"
}

run_tests
