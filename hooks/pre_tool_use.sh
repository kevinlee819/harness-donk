#!/usr/bin/env bash
# PreToolUse hook — 确定性拦截危险操作
# 见 docs/interfaces.md §7.1, CLAUDE.md §4.7
#
# 输入：stdin = Claude Code hook JSON
#   {tool_name, tool_input: {command|file_path|...}, ...}
#
# 行为：命中危险模式 → stderr 写原因 → exit 2
#       放行：exit 0（静默）
#
# 禁令：
#   - 写 stdout（模型收不到反馈，必须 stderr）
#   - HTTP hook（非 2xx 即旁路，网络抖动旁路安全门）
#
# 期望环境变量（由 settings.json 透传或调用方设置）：
#   HARNESS_WORKTREE   — 当前 worker 工作目录绝对路径（可选；缺失则降级到通用规则）
#
# 本脚本零依赖 harness lib（部署到外部项目时项目内无 lib）。
# 仅依赖 jq。

set -uo pipefail

_block() {
  # _block <reason>
  printf 'BLOCKED by harness pre_tool_use hook: %s\n' "$1" >&2
  exit 2
}

# 读 stdin JSON
INPUT=$(cat)
if ! printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
  # 输入不是合法 JSON — 放行（不该拦截非预期输入，否则 hook 自身就成故障点）
  exit 0
fi

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')

WORKTREE="${HARNESS_WORKTREE:-}"

# ─────── 规则 1：禁止 git push --force / -f ───────
if [[ "$TOOL" == "Bash" ]]; then
  # 命中 git push 且带 --force / -f / --force-with-lease 等
  if [[ "$CMD" =~ git[[:space:]]+push.*(--force|--force-with-lease|[[:space:]]-f([[:space:]]|$)) ]]; then
    _block "git push --force is forbidden"
  fi
fi

# ─────── 规则 2：禁止 worktree 外的 rm -rf（粗暴 catch-all） ───────
if [[ "$TOOL" == "Bash" ]]; then
  # 匹配 rm -rf / rm -fr / rm -r -f 等组合
  if [[ "$CMD" =~ rm[[:space:]]+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r) ]] || \
     [[ "$CMD" =~ rm[[:space:]]+-r[[:space:]]+-f ]] || \
     [[ "$CMD" =~ rm[[:space:]]+-f[[:space:]]+-r ]]; then
    # 提取 rm 后第一个非选项路径，做位置判定
    # 简化：只要命令里出现 rm -rf / -fr，未指定 worktree 或目标在 worktree 外即拦截
    if [[ -z "$WORKTREE" ]]; then
      _block "rm -rf without worktree context (HARNESS_WORKTREE unset) — blocked for safety"
    fi
    # 提取目标路径（最朴素：rm -rf 之后第一个 token，不含 -）
    target=$(printf '%s' "$CMD" | sed -E 's|.*rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)+([^[:space:];|&]+).*|\2|')
    if [[ -n "$target" && "$target" != "$CMD" ]]; then
      # 解析为绝对路径再判定
      abs=""
      case "$target" in
        /*) abs="$target" ;;
        *)  abs="$(pwd)/$target" ;;
      esac
      # 不在 worktree 内则拦截
      case "$abs" in
        "$WORKTREE"|"$WORKTREE"/*) : ;;
        *) _block "rm -rf target outside worktree: $target" ;;
      esac
    fi
  fi
fi

# ─────── 规则 3：禁止写 harness.db / harness.db-wal / harness.db-shm ───────
# Edit/Write/MultiEdit 检 file_path；Bash 检命令字符串
if [[ "$TOOL" =~ ^(Edit|Write|MultiEdit|NotebookEdit)$ ]]; then
  if [[ "$FILE_PATH" =~ /\.harness/harness\.db(-wal|-shm)?$ ]]; then
    _block "writing to .harness/harness.db is forbidden (orchestrator-only)"
  fi
fi
if [[ "$TOOL" == "Bash" ]]; then
  # 命令中出现重定向到 harness.db 或 sqlite3 .../harness.db "INSERT|UPDATE|DELETE|DROP|CREATE..."
  if [[ "$CMD" =~ \>[[:space:]]*[^[:space:]]*\.harness/harness\.db ]]; then
    _block "redirecting to .harness/harness.db is forbidden"
  fi
  if [[ "$CMD" =~ sqlite3[[:space:]].*\.harness/harness\.db.*(INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|REPLACE) ]]; then
    _block "agents must not write harness.db via SQL — write JSON files instead"
  fi
fi

# ─────── 规则 4：禁触含 prod / secret 的路径 ───────
_check_sensitive_path() {
  local p="$1"
  if [[ "$p" =~ (^|/)(prod|secrets?|\.env(\..*)?|credentials?)(/|$|\.) ]]; then
    _block "sensitive path: $p"
  fi
}

if [[ "$TOOL" =~ ^(Edit|Write|MultiEdit|Read|NotebookEdit)$ ]]; then
  [[ -n "$FILE_PATH" ]] && _check_sensitive_path "$FILE_PATH"
fi
if [[ "$TOOL" == "Bash" ]]; then
  # 提取命令中疑似路径 token，逐个检
  for tok in $CMD; do
    case "$tok" in
      */prod/*|*/prod|prod/*|*/secret*|secret*|*/credentials*|credentials*|*.env|*.env.*)
        _check_sensitive_path "$tok" ;;
    esac
  done
fi

# ─────── 规则 5：禁止对主分支的 git merge / git push ───────
if [[ "$TOOL" == "Bash" ]]; then
  # git merge — 任何在 worker 上下文的 merge 都禁（合并是编排器专属）
  if [[ "$CMD" =~ git[[:space:]]+(.*[[:space:]])?merge([[:space:]]|$) ]]; then
    _block "git merge is orchestrator-only; worker must not merge"
  fi
  if [[ "$CMD" =~ git[[:space:]]+(.*[[:space:]])?push([[:space:]]|$) ]]; then
    _block "git push is forbidden in worker context"
  fi
fi

# 放行
exit 0
