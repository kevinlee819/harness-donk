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

# ── workspace-write writable_roots（linked worktree git ops fix）─────
# Background: when a worker runs in a linked git worktree, `git commit` writes
# into the MAIN repo's .git/ tree (worktrees/<id>/index.lock, objects, refs, ...).
# That dir lives OUTSIDE the worktree, so default workspace-write blocks all
# commits — every worker produces zero commits → ghost merges. The adapter
# must add the main .git/ as an extra writable_root.

_setup_linked_worktree() {
  # main repo at $d/main with a linked worktree at $d/wt.
  local d; d=$(make_tmp_dir); track_cleanup "$d"
  local main="$d/main"
  mkdir -p "$main"
  (cd "$main" && git init -q -b main && \
    git config user.email t@t && git config user.name t && \
    git config commit.gpgsign false && \
    echo "seed" > README.md && git add . && git commit -qm i) >/dev/null
  (cd "$main" && git worktree add -b feature "$d/wt" >/dev/null 2>&1)
  echo "$d/wt"
}

test_workspace_write_adds_main_git_dir_to_writable_roots() {
  # Regression: codex sandbox=workspace-write blocked git commits in linked
  # worktrees because the main repo's .git/ was read-only. Fix adds it via
  # `-c sandbox_workspace_write.writable_roots=[...]`.
  local wt; wt=$(_setup_linked_worktree)
  local prompt="$wt/.prompt.txt"; echo "x" > "$prompt"
  local main_git; main_git=$(git -C "$wt" rev-parse --git-common-dir)
  main_git=$(cd "$wt" && cd "$main_git" && pwd)
  local out
  out=$(env HARNESS_ADAPTER_DRYRUN=1 ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
        HARNESS_HOME="$HARNESS_HOME" \
        bash "$HARNESS_HOME/adapters/codex.sh")
  assert_contains "sandbox_workspace_write.writable_roots" "$out" \
    "writable_roots flag added for linked worktree"
  assert_contains "$main_git" "$out" "main .git path included"
}

test_read_only_mode_omits_writable_roots() {
  # No writes allowed in read-only mode → writable_roots is meaningless and
  # shouldn't be emitted. (Review path also uses read-only.)
  local wt; wt=$(_setup_linked_worktree)
  local prompt="$wt/.prompt.txt"; echo "x" > "$prompt"
  local out
  out=$(env HARNESS_ADAPTER_DRYRUN=1 ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
        ADAPTER_SANDBOX=read-only HARNESS_HOME="$HARNESS_HOME" \
        bash "$HARNESS_HOME/adapters/codex.sh")
  if [[ "$out" == *"sandbox_workspace_write.writable_roots"* ]]; then
    _assert_fail "writable_roots should not be passed in read-only mode"
  fi
}

test_non_worktree_repo_omits_writable_roots() {
  # When the worktree IS the main repo (no linked worktree), .git is already
  # inside cwd — workspace-write covers it natively. Don't add it redundantly.
  local wt; wt=$(_setup_worktree)  # uses git init in $wt — .git is at $wt/.git
  local prompt="$wt/.prompt.txt"; echo "x" > "$prompt"
  local out
  out=$(env HARNESS_ADAPTER_DRYRUN=1 ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
        HARNESS_HOME="$HARNESS_HOME" \
        bash "$HARNESS_HOME/adapters/codex.sh")
  if [[ "$out" == *"sandbox_workspace_write.writable_roots"* ]]; then
    _assert_fail "writable_roots should NOT be added when .git is already inside cwd"
  fi
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

# ── 成本折算（HARNESS_CODEX_EVENTS_FIXTURE 路径）────────────
# 不调真 codex，注入伪造 JSONL，验证 turn.completed.usage 被正确汇总并喂给
# harness.usage 折算成 USD。这是 Codex 成本盲区的关键回归测试。

_make_events_fixture() {
  # 生成一份 JSONL fixture 到 $1。包含 thread.started + 两个 turn.completed
  # （token 各种字段都带）+ 一条 agent_message。
  cat > "$1" <<'EOF'
{"type":"thread.started","thread_id":"00000000-0000-4000-8000-000000000000"}
{"type":"turn.completed","usage":{"input_tokens":30000,"cached_input_tokens":10000,"output_tokens":5000,"reasoning_output_tokens":1000}}
{"type":"turn.completed","usage":{"input_tokens":20000,"cached_input_tokens":5000,"output_tokens":3000,"reasoning_output_tokens":500}}
{"type":"item.completed","item":{"type":"agent_message","text":"done"}}
EOF
}

test_cost_usd_computed_from_turn_completed_usage() {
  local wt; wt=$(_setup_worktree)
  local prompt="$wt/.prompt.txt"; echo "x" > "$prompt"
  local wd="$wt/.harness/workers/w1"; mkdir -p "$wd"
  local fx="$wt/.fixture.jsonl"
  _make_events_fixture "$fx"

  local resp
  resp=$(HARNESS_CODEX_EVENTS_FIXTURE="$fx" \
    ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
    ADAPTER_WORKER_DIR="$wd" ADAPTER_TASK_ID=T-cost1 ADAPTER_WORKER_ID=w1 \
    ADAPTER_MODEL=gpt-5-codex \
    bash "$HARNESS_HOME/adapters/codex.sh")

  assert_json_field "$resp" '.ok' 'true'
  # turn 数 = 2
  assert_json_field "$resp" '.num_turns' '2'
  # 期望成本：
  #   合计 input=50000, cached=15000, output=8000
  #   non-cached = 50000-15000 = 35000
  #   35000×1.25e-6 + 15000×1.25e-7 + 8000×1e-5
  #   = 0.04375 + 0.001875 + 0.08 = 0.125625
  local cost; cost=$(printf '%s' "$resp" | jq -r '.cost_usd')
  if [[ "$cost" == "null" ]]; then
    _assert_fail "cost_usd should not be null when model+tokens present (got: $resp)"
  fi
  # 浮点比较：用 awk 算差值绝对值 < 1e-5
  awk -v c="$cost" -v e="0.125625" 'BEGIN{ d=c-e; if(d<0) d=-d; exit (d<1e-5)?0:1 }' \
    || _assert_fail "cost_usd=$cost expected ~0.125625"
}

test_cost_usd_null_when_model_not_set() {
  # 没传 ADAPTER_MODEL，无法查价目表 → cost_usd 保持 null（绝不填假数）
  local wt; wt=$(_setup_worktree)
  local prompt="$wt/.prompt.txt"; echo "x" > "$prompt"
  local wd="$wt/.harness/workers/w1"; mkdir -p "$wd"
  local fx="$wt/.fixture.jsonl"
  _make_events_fixture "$fx"

  local resp
  resp=$(HARNESS_CODEX_EVENTS_FIXTURE="$fx" \
    ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
    ADAPTER_WORKER_DIR="$wd" ADAPTER_TASK_ID=T-cost2 ADAPTER_WORKER_ID=w1 \
    bash "$HARNESS_HOME/adapters/codex.sh")
  assert_json_field "$resp" '.cost_usd' 'null'
}

test_cost_usd_null_when_model_unknown() {
  local wt; wt=$(_setup_worktree)
  local prompt="$wt/.prompt.txt"; echo "x" > "$prompt"
  local wd="$wt/.harness/workers/w1"; mkdir -p "$wd"
  local fx="$wt/.fixture.jsonl"
  _make_events_fixture "$fx"

  local resp
  resp=$(HARNESS_CODEX_EVENTS_FIXTURE="$fx" \
    ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
    ADAPTER_WORKER_DIR="$wd" ADAPTER_TASK_ID=T-cost3 ADAPTER_WORKER_ID=w1 \
    ADAPTER_MODEL="totally-made-up-model-zzz" \
    bash "$HARNESS_HOME/adapters/codex.sh")
  assert_json_field "$resp" '.cost_usd' 'null'
}

test_cost_usd_zero_when_no_usage_events() {
  # 只有 thread.started + agent_message，没 turn.completed → 总 token = 0
  # adapter 应直接保持 null（短路：sum=0 不调 usage.py）
  local wt; wt=$(_setup_worktree)
  local prompt="$wt/.prompt.txt"; echo "x" > "$prompt"
  local wd="$wt/.harness/workers/w1"; mkdir -p "$wd"
  local fx="$wt/.fixture.jsonl"
  cat > "$fx" <<'EOF'
{"type":"thread.started","thread_id":"00000000-0000-4000-8000-000000000000"}
{"type":"item.completed","item":{"type":"agent_message","text":"empty"}}
EOF

  local resp
  resp=$(HARNESS_CODEX_EVENTS_FIXTURE="$fx" \
    ADAPTER_TASK_FILE="$prompt" ADAPTER_WORKTREE="$wt" \
    ADAPTER_WORKER_DIR="$wd" ADAPTER_TASK_ID=T-cost4 ADAPTER_WORKER_ID=w1 \
    ADAPTER_MODEL=gpt-5-codex \
    bash "$HARNESS_HOME/adapters/codex.sh")
  assert_json_field "$resp" '.cost_usd' 'null'
}

test_capability_bitmap_cost_report_is_one() {
  # 我们现在能自算 USD（token×price），bitmap 同步
  local src; src=$(cat "$HARNESS_HOME/adapters/codex.sh")
  assert_contains "ADAPTER_CAP_COST_REPORT=1" "$src"
}

run_tests
