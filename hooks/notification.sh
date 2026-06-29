#!/usr/bin/env bash
# 系统通知 hook — 阶段二
# 由 notify.py 在写完事件 JSON 后 fire-and-forget 调用（detached）。
#
# 入参:
#   $1 = event_type (needs_decision / task_completed / task_failed / budget_exceeded)
#   $2 = task_id 或 "-"
#   $3 = 事件 JSON 文件绝对路径
#
# needs_decision 特殊处理：
#   弹 osascript 交互对话框，用户在通知框中直接选项或输入答案。
#   答案写入 <project>/.harness/inbox/<task_id>.answer，触发协调者继续。
#
# 其他事件：
#   terminal-notifier（若已装）或 osascript display notification 普通弹窗。
#
# 平台：macOS 优先；其他系统只写 notify.log。
# 装 terminal-notifier：brew install terminal-notifier

set -uo pipefail

etype="${1:-}"
tid="${2:--}"
path="${3:-}"

[[ -z "$etype" ]] && exit 0

case "$etype" in
  needs_decision|task_failed|budget_exceeded) ;;
  *) exit 0 ;;
esac

# ── 从 HARNESS_DB 推出项目路径 ────────────────────────────────
proj_dir=""
inbox_dir=""
log_dir=""
if [[ -n "${HARNESS_DB:-}" ]]; then
  proj_dir=$(dirname "$(dirname "$HARNESS_DB")")
  inbox_dir="$proj_dir/.harness/inbox"
  log_dir="$proj_dir/.harness/logs"
fi

# ── 解析事件 JSON ────────────────────────────────────────────
title="harness"
body="task=$tid"
question=""
opts_json="[]"
if [[ -f "$path" ]]; then
  case "$etype" in
    needs_decision)
      question=$(jq -r '.payload.question // "需要决策"' "$path" 2>/dev/null || echo "")
      opts_json=$(jq -c '.payload.options // []'        "$path" 2>/dev/null || echo "[]")
      body="[$tid] ${question:-需要决策}"
      title="harness: 需要您的决策"
      ;;
    task_failed)
      body=$(jq -r '"[" + (.task_id // "?") + "] " + (.payload.reason // "failed")' "$path" 2>/dev/null || echo "$body")
      title="harness: 任务失败"
      ;;
    budget_exceeded)
      body=$(jq -r '"今日 $" + (.payload.cost_usd|tostring) + " > 上限 $" + (.payload.limit_usd|tostring)' "$path" 2>/dev/null || echo "$body")
      title="harness: 预算超限"
      ;;
  esac
fi

# 先写一条本地 log——needs_decision 的 osascript 对话框会阻塞到用户作答，
# 而 notify.log 应在事件触发时就立刻可见（测试与排障都依赖它）
if [[ -n "$log_dir" ]]; then
  mkdir -p "$log_dir"
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$etype" "$body" >> "$log_dir/notify.log"
fi

# ── macOS 桌面通知 ───────────────────────────────────────────
if [[ "$(uname)" == "Darwin" ]]; then
  donk_icon="${HARNESS_HOME:-}/docs/donk.png"

  if [[ "$etype" == "needs_decision" ]] \
     && command -v osascript >/dev/null 2>&1 \
     && [[ -n "$inbox_dir" && "$tid" != "-" ]]; then
    # needs_decision → 交互式对话框，用户直接在弹框中作答
    # Python 负责字符串转义和生成 AppleScript；答案写入 inbox/<tid>.answer
    mkdir -p "$inbox_dir"
    _scpt=$(mktemp /tmp/harness_nd.XXXXXX.scpt)

    python3 - "$question" "$opts_json" "$inbox_dir" "$tid" "$_scpt" << 'PYEOF'
import sys, json, os

q, opts_json_str, inbox, tid, outfile = sys.argv[1:]
try:
    opts = json.loads(opts_json_str) if opts_json_str and opts_json_str != '[]' else []
except Exception:
    opts = []

def esc(s: str) -> str:
    """Escape a Python string for use inside an AppleScript double-quoted string."""
    return s.replace('\\', '\\\\').replace('"', '\\"')

answer_path = os.path.join(inbox, f"{tid}.answer")
q_esc = esc(q or "需要决策")
path_esc = esc(answer_path)

lines = []
if 2 <= len(opts) <= 3:
    # 多选：每个选项一个按钮（最多 3 个）
    btns = ', '.join(f'"{esc(str(o))}"' for o in opts[:3])
    lines += [
        'try',
        f'  set theBtn to button returned of (display dialog "{q_esc}" ¬',
        f'    buttons {{{btns}}} default button 1 ¬',
        f'    with title "harness: 需要决策")',
        f'  set f to open for access POSIX file "{path_esc}" with write permission',
        '  write theBtn to f',
        '  close access f',
        'end try',
    ]
elif len(opts) == 1:
    # 单项确认
    btn1 = esc(str(opts[0]))
    lines += [
        'try',
        f'  set theBtn to button returned of (display dialog "{q_esc}" ¬',
        f'    buttons {{"取消", "{btn1}"}} default button "{btn1}" ¬',
        f'    with title "harness: 需要决策")',
        f'  if theBtn is not "取消" then',
        f'    set f to open for access POSIX file "{path_esc}" with write permission',
        '    write theBtn to f',
        '    close access f',
        '  end if',
        'end try',
    ]
else:
    # 自由文本输入
    lines += [
        'try',
        f'  set dlg to display dialog "{q_esc}" ¬',
        '    default answer "" ¬',
        '    buttons {"取消", "发送"} default button "发送" ¬',
        '    with title "harness: 需要决策"',
        '  if button returned of dlg is "发送" then',
        '    set ans to text returned of dlg',
        f'    set f to open for access POSIX file "{path_esc}" with write permission',
        '    write ans to f',
        '    close access f',
        '  end if',
        'end try',
    ]

with open(outfile, 'w') as fp:
    fp.write('\n'.join(lines) + '\n')
PYEOF

    # 对话框阻塞直到用户作答；notification.sh 本身已是 detached 进程，不影响编排器
    osascript "$_scpt" 2>/dev/null || true
    rm -f "$_scpt"

  else
    # task_failed / budget_exceeded → 普通桌面通知（无需用户操作）
    if command -v terminal-notifier >/dev/null 2>&1; then
      _tn_args=(-title "$title" -message "$body" -group "harness-$tid")
      [[ -f "$donk_icon" ]] && _tn_args+=(-appIcon "$donk_icon")
      terminal-notifier "${_tn_args[@]}" >/dev/null 2>&1 || true
    elif command -v osascript >/dev/null 2>&1; then
      esc_body=${body//\"/\\\"}
      esc_title=${title//\"/\\\"}
      osascript -e "display notification \"$esc_body\" with title \"$esc_title\"" >/dev/null 2>&1 || true
    fi
  fi
fi

exit 0
