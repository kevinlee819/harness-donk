#!/usr/bin/env bash
# 测试 fixture 工具 — 创建临时项目、清理

# 期望 HARNESS_HOME 已由 runner 导出

make_tmp_dir() {
  # 返回一个新的临时目录路径（test 结束时由 trap 清理）
  local base="${TMPDIR:-/tmp}/harness-test-$$.$RANDOM"
  mkdir -p "$base"
  echo "$base"
}

make_fixture_project() {
  # make_fixture_project [parent_dir]
  # 创建一个初始化好的 git 项目并 harness init，返回项目绝对路径
  local parent="${1:-$(make_tmp_dir)}"
  local proj="$parent/proj"
  mkdir -p "$proj"
  (
    cd "$proj"
    git init -q
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    echo "# fixture" > README.md
    git add . && git commit -q -m init
  )
  (cd "$proj" && "$HARNESS_HOME/bin/harness" init >/dev/null)
  echo "$proj"
}

set_gate_test_cmd() {
  # set_gate_test_cmd <project_dir> <cmd>
  # 修改 AGENTS.md 的 gate.test 命令并 commit（必须 commit 才能被 worktree 看到）
  local proj="$1" cmd="$2"
  local agents="$proj/AGENTS.md"
  python3 - <<PY
import re, pathlib
p = pathlib.Path("$agents")
text = p.read_text()
text = re.sub(r'(\ntest:\s*)"[^"]*"', r'\1"$cmd"', text, count=1)
p.write_text(text)
PY
  (cd "$proj" && git add AGENTS.md && git commit -q -m "set gate test")
}

# 自动清理：trap 在测试脚本顶部调用 register_cleanup_trap
_CLEANUP_DIRS=()

register_cleanup_trap() {
  trap '_test_cleanup' EXIT
}

track_cleanup() {
  _CLEANUP_DIRS+=("$1")
}

_test_cleanup() {
  local d
  for d in "${_CLEANUP_DIRS[@]+"${_CLEANUP_DIRS[@]}"}"; do
    [[ -d "$d" ]] && rm -rf "$d"
  done
}
