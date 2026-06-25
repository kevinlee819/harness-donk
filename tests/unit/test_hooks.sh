#!/usr/bin/env bash
# unit: hooks/pre_tool_use.sh — 每条规则一例命中 + 一例放行
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"

register_cleanup_trap
HOOK="$HARNESS_HOME/hooks/pre_tool_use.sh"

# _run_hook <tool> <field> <value> [--worktree DIR]
# 构造 hook 输入 JSON 并喂给 hook；返回 stderr，退出码留在 $rc
_run_hook() {
  local tool="$1" field="$2" value="$3"
  shift 3
  local worktree=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --worktree) worktree="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  local input
  input=$(jq -nc --arg t "$tool" --arg f "$field" --arg v "$value" \
    '{tool_name:$t, tool_input:({} | .[$f] = $v)}')
  set +e
  HOOK_STDERR=$(HARNESS_WORKTREE="$worktree" printf '%s' "$input" | env HARNESS_WORKTREE="$worktree" bash "$HOOK" 2>&1 >/dev/null)
  rc=$?
  set -e
}

# ─── 规则 1：git push --force ───
test_blocks_git_push_force() {
  _run_hook Bash command "git push --force origin main"
  assert_exit_code 2 "$rc"
  assert_contains "force" "$HOOK_STDERR"
}

test_blocks_git_push_dash_f() {
  _run_hook Bash command "git push -f origin main"
  assert_exit_code 2 "$rc"
}

test_blocks_git_push_force_with_lease() {
  _run_hook Bash command "git push --force-with-lease"
  assert_exit_code 2 "$rc"
}

test_allows_normal_git_push_is_still_blocked_by_rule5() {
  # 规则 5 会拦截任何 git push（worker 不许 push）
  _run_hook Bash command "git push origin feature"
  assert_exit_code 2 "$rc"
  assert_contains "push" "$HOOK_STDERR"
}

# ─── 规则 2：rm -rf 越界 ───
test_blocks_rm_rf_without_worktree() {
  _run_hook Bash command "rm -rf /tmp/something"
  assert_exit_code 2 "$rc"
  assert_contains "worktree" "$HOOK_STDERR"
}

test_blocks_rm_rf_outside_worktree() {
  _run_hook Bash command "rm -rf /etc/passwd" --worktree /tmp/wt
  assert_exit_code 2 "$rc"
  assert_contains "outside worktree" "$HOOK_STDERR"
}

test_allows_rm_rf_inside_worktree() {
  _run_hook Bash command "rm -rf /tmp/wt/build" --worktree /tmp/wt
  assert_exit_code 0 "$rc"
}

# ─── 规则 3：写 harness.db ───
test_blocks_write_to_harness_db_via_edit() {
  _run_hook Write file_path "/some/project/.harness/harness.db"
  assert_exit_code 2 "$rc"
  assert_contains "harness.db" "$HOOK_STDERR"
}

test_blocks_redirect_to_harness_db() {
  _run_hook Bash command "echo bad > /some/.harness/harness.db"
  assert_exit_code 2 "$rc"
}

test_blocks_sql_insert_to_harness_db() {
  _run_hook Bash command "sqlite3 .harness/harness.db 'INSERT INTO tasks VALUES (1)'"
  assert_exit_code 2 "$rc"
}

test_allows_read_harness_db() {
  # Read 工具不在写入规则范围内
  _run_hook Read file_path "/some/.harness/harness.db"
  assert_exit_code 0 "$rc"
}

test_allows_write_to_worker_status() {
  _run_hook Write file_path "/some/.harness/workers/w1/status.json"
  assert_exit_code 0 "$rc"
}

# ─── 规则 4：sensitive 路径 ───
test_blocks_write_to_dotenv() {
  _run_hook Write file_path "/proj/.env"
  assert_exit_code 2 "$rc"
}

test_blocks_write_to_prod_path() {
  _run_hook Write file_path "/proj/prod/config.yaml"
  assert_exit_code 2 "$rc"
}

test_blocks_secrets_dir() {
  _run_hook Edit file_path "/proj/secrets/db.json"
  assert_exit_code 2 "$rc"
}

test_blocks_credentials_path() {
  _run_hook Read file_path "/proj/credentials.json"
  assert_exit_code 2 "$rc"
}

test_blocks_bash_cat_secret() {
  _run_hook Bash command "cat secrets/db.json"
  assert_exit_code 2 "$rc"
}

test_allows_normal_file_write() {
  _run_hook Write file_path "/proj/src/main.ts"
  assert_exit_code 0 "$rc"
}

# ─── 规则 5：禁止 git merge ───
test_blocks_git_merge() {
  _run_hook Bash command "git merge feature-branch"
  assert_exit_code 2 "$rc"
  assert_contains "merge" "$HOOK_STDERR"
}

test_blocks_git_merge_with_args() {
  _run_hook Bash command "git -C /some/path merge --no-ff feature"
  assert_exit_code 2 "$rc"
}

# ─── 输入鲁棒性 ───
test_non_json_input_allows() {
  # 非合法 JSON 输入应放行（hook 自身不该成故障点）
  set +e
  echo "not json at all" | bash "$HOOK"
  rc=$?
  set -e
  assert_exit_code 0 "$rc"
}

test_empty_tool_input_allows() {
  _run_hook Bash command ""
  assert_exit_code 0 "$rc"
}

# ─── 与正常工具的协同：常规 Bash 命令通过 ───
test_allows_ls() {
  _run_hook Bash command "ls -la"
  assert_exit_code 0 "$rc"
}

test_allows_git_status() {
  _run_hook Bash command "git status"
  assert_exit_code 0 "$rc"
}

test_allows_git_commit() {
  _run_hook Bash command "git commit -m message"
  assert_exit_code 0 "$rc"
}

run_tests
