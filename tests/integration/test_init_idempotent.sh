#!/usr/bin/env bash
# integration: harness init 幂等性 + 模板正确渲染
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"

register_cleanup_trap

test_init_creates_expected_files() {
  local d; d=$(make_tmp_dir); track_cleanup "$d"
  cd "$d"
  git init -q && git config user.email t@t && git config user.name t
  git config commit.gpgsign false
  echo "# proj" > README.md && git add . && git commit -q -m init

  "$HARNESS_HOME/bin/harness" init >/dev/null

  assert_file_exists "$d/AGENTS.md"
  assert_file_exists "$d/.harness/harness.db"
  [[ -L "$d/CLAUDE.md" ]] || _assert_fail "CLAUDE.md should be symlink"
  assert_contains ".harness/" "$(cat "$d/.gitignore")"

  # SQLite 版本对
  local v; v=$(sqlite3 "$d/.harness/harness.db" "PRAGMA user_version;")
  assert_eq "1" "$v"

  # 必备目录
  [[ -d "$d/.harness/workers" ]] || _assert_fail "workers/"
  [[ -d "$d/.harness/inbox" ]]   || _assert_fail "inbox/"
  [[ -d "$d/.harness/logs/raw" ]] || _assert_fail "logs/raw/"
  [[ -d "$d/specs" ]]            || _assert_fail "specs/"

  # 知识层文件（参照 project-harness 思想；worker 在 AGENTS.md 必读列表里读它们）
  assert_file_exists "$d/docs/decisions.md"
  assert_file_exists "$d/docs/error-journal.md"
  assert_contains "决策记录" "$(cat "$d/docs/decisions.md")"
  assert_contains "错误日志" "$(cat "$d/docs/error-journal.md")"
}

test_init_preserves_existing_knowledge_files() {
  # 用户在 docs/decisions.md 已经记了东西，重跑 init 不应覆盖
  local d; d=$(make_tmp_dir); track_cleanup "$d"
  cd "$d"
  git init -q && git config user.email t@t && git config user.name t
  git config commit.gpgsign false
  echo "# proj" > README.md && git add . && git commit -q -m init

  mkdir -p "$d/docs"
  echo "## 2025-01-01: 用户已经记的决策" > "$d/docs/decisions.md"
  echo "## 2025-01-01: 用户已经记的坑"   > "$d/docs/error-journal.md"

  "$HARNESS_HOME/bin/harness" init >/dev/null 2>&1

  # 内容应保留
  assert_contains "用户已经记的决策" "$(cat "$d/docs/decisions.md")"
  assert_contains "用户已经记的坑"   "$(cat "$d/docs/error-journal.md")"
}

test_init_idempotent_no_overwrite() {
  local d; d=$(make_tmp_dir); track_cleanup "$d"
  cd "$d"
  git init -q && git config user.email t@t && git config user.name t
  git config commit.gpgsign false
  echo "# proj" > README.md && git add . && git commit -q -m init

  "$HARNESS_HOME/bin/harness" init >/dev/null

  # 人工修改 AGENTS.md
  echo "MY CUSTOM CONTENT" >> "$d/AGENTS.md"
  local before; before=$(cat "$d/AGENTS.md")

  # 第二次 init 不应覆盖
  "$HARNESS_HOME/bin/harness" init >/dev/null 2>&1
  local after; after=$(cat "$d/AGENTS.md")
  assert_eq "$before" "$after" "AGENTS.md preserved"

  # gitignore 不应有重复条目
  local n_lines; n_lines=$(grep -c '^\.harness/' "$d/.gitignore")
  assert_eq "1" "$n_lines" "gitignore not duplicated"
}

test_init_installs_settings_json() {
  local d; d=$(make_tmp_dir); track_cleanup "$d"
  cd "$d"
  git init -q && git config user.email t@t && git config user.name t
  git config commit.gpgsign false
  echo "# proj" > README.md && git add . && git commit -q -m init
  "$HARNESS_HOME/bin/harness" init >/dev/null

  assert_file_exists "$d/.claude/settings.json"
  # 应是合法 JSON 且含 PreToolUse hook
  local hooks; hooks=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$d/.claude/settings.json")
  assert_contains "pre_tool_use.sh" "$hooks"
  # HARNESS_HOME 占位符应已替换为绝对路径
  assert_not_match '\{\{HARNESS_HOME\}\}' "$hooks" "placeholder substituted"
}

test_init_preserves_existing_settings() {
  local d; d=$(make_tmp_dir); track_cleanup "$d"
  cd "$d"
  git init -q && git config user.email t@t && git config user.name t
  git config commit.gpgsign false
  echo "# proj" > README.md && git add . && git commit -q -m init

  # 预置一个自定义 settings.json
  mkdir -p "$d/.claude"
  echo '{"user": "preexisting"}' > "$d/.claude/settings.json"

  "$HARNESS_HOME/bin/harness" init >/dev/null 2>&1

  local content; content=$(cat "$d/.claude/settings.json")
  assert_contains "preexisting" "$content" "existing settings.json kept intact"
  assert_file_exists "$d/.claude/settings.json.harness-suggested"
}

test_init_non_git_repo_fails() {
  local d; d=$(make_tmp_dir); track_cleanup "$d"
  cd "$d"
  set +e
  "$HARNESS_HOME/bin/harness" init 2>/dev/null
  local rc=$?
  set -e
  assert_neq 0 "$rc" "non-git should fail"
}

test_init_with_backend_codex_flips_reviewer() {
  local d; d=$(make_tmp_dir); track_cleanup "$d"
  mkdir -p "$d/proj"
  (
    cd "$d/proj"
    git init -q
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    echo init > r
    git add . && git commit -qm i
  )
  (cd "$d/proj" && "$HARNESS_HOME/bin/harness" init --backend codex >/dev/null 2>&1)
  local line; line=$(grep "^cross_review_reviewer:" "$d/proj/AGENTS.md")
  assert_contains "claude" "$line" "--backend codex → reviewer claude"
}

test_init_default_backend_keeps_codex_reviewer() {
  local d; d=$(make_tmp_dir); track_cleanup "$d"
  mkdir -p "$d/proj"
  (
    cd "$d/proj"
    git init -q
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    echo init > r
    git add . && git commit -qm i
  )
  (cd "$d/proj" && "$HARNESS_HOME/bin/harness" init >/dev/null 2>&1)
  local line; line=$(grep "^cross_review_reviewer:" "$d/proj/AGENTS.md")
  assert_contains "codex" "$line" "default (claude writer) → codex reviewer"
}

test_init_registers_project_in_global_projects_list() {
  local d; d=$(make_tmp_dir); track_cleanup "$d"
  local confd="$d/conf"
  export HARNESS_CONFIG_DIR="$confd"
  mkdir -p "$d/proj"
  (
    cd "$d/proj"
    git init -q
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    echo init > r
    git add . && git commit -qm i
  )

  (cd "$d/proj" && "$HARNESS_HOME/bin/harness" init >/dev/null 2>&1)

  local plist="$confd/projects.list"
  assert_file_exists "$plist" "projects.list created"
  local proj_real; proj_real=$(cd "$d/proj" && pwd)
  local n; n=$(grep -cxF "$proj_real" "$plist")
  assert_eq "1" "$n" "project registered exactly once"

  # 第二次 init（已 initialized）不应重复登记
  (cd "$d/proj" && "$HARNESS_HOME/bin/harness" init >/dev/null 2>&1)
  n=$(grep -cxF "$proj_real" "$plist")
  assert_eq "1" "$n" "second init does not duplicate"

  unset HARNESS_CONFIG_DIR
}

run_tests
