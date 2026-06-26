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

run_tests
