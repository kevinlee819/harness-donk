#!/usr/bin/env bash
# 系统通知 hook — 阶段二
# 由 lib/notify.sh 在写完事件 JSON 后 fire-and-forget 调用。
#
# 入参:
#   $1 = event_type (needs_decision / task_completed / task_failed / budget_exceeded)
#   $2 = task_id 或 "-"
#   $3 = 事件 JSON 文件绝对路径
#
# 行为：
#   只对人需要主动决策/关注的事件弹通知（needs_decision / task_failed /
#   budget_exceeded）。task_completed 通常静默——协调者下次查询时知道即可。
#
# 平台：
#   - macOS: osascript display notification
#   - 其他: 写一条 log 到 .harness/logs/notify.log
#
# 用户可改写本文件接入自家 webhook / 飞书 / Slack / 桌面通知。

set -uo pipefail

etype="${1:-}"
tid="${2:--}"
path="${3:-}"

[[ -z "$etype" ]] && exit 0

case "$etype" in
  needs_decision|task_failed|budget_exceeded) ;;
  *) exit 0 ;;
esac

title="harness: $etype"
body="task=$tid"
if [[ -f "$path" ]]; then
  case "$etype" in
    needs_decision)
      body=$(jq -r '"[" + (.task_id // "?") + "] " + (.payload.question // "需要决策")' "$path" 2>/dev/null || echo "$body") ;;
    task_failed)
      body=$(jq -r '"[" + (.task_id // "?") + "] " + (.payload.reason // "failed")' "$path" 2>/dev/null || echo "$body") ;;
    budget_exceeded)
      body=$(jq -r '"today $" + (.payload.cost_usd|tostring) + " > limit $" + (.payload.limit_usd|tostring)' "$path" 2>/dev/null || echo "$body") ;;
  esac
fi

# macOS 桌面通知
if [[ "$(uname)" == "Darwin" ]] && command -v osascript >/dev/null 2>&1; then
  # 转义 osascript 字符串里的引号
  esc_body=${body//\"/\\\"}
  esc_title=${title//\"/\\\"}
  osascript -e "display notification \"$esc_body\" with title \"$esc_title\"" >/dev/null 2>&1 || true
fi

# 永远写一条本地 log（便于无桌面环境也能追溯）
if [[ -n "${HARNESS_DB:-}" ]]; then
  proj_dir=$(dirname "$(dirname "$HARNESS_DB")")
  log_dir="$proj_dir/.harness/logs"
  mkdir -p "$log_dir"
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$etype" "$body" >> "$log_dir/notify.log"
fi

exit 0
