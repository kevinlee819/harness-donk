#!/usr/bin/env bash
# lib/budget.sh — 预算闸（只读版，阶段一）
#
# 阶段一只实现 budget_today / budget_check（只读不杀）。
# 阶段二补 budget_kill_switch（停止派发 + Notification 上抛）。
#
# 见 docs/interfaces.md §9.1。
#
# 调用方式：source 之，再用函数。需要 $HARNESS_PYTHON 在环境中（由 lib/python_env.sh 提供）。

# 从全局配置读 budget_daily_usd（默认 10）
_budget_daily_limit() {
  local conf="${HARNESS_CONFIG_DIR:-$HOME/.config/harness}/config"
  local v
  if [[ -f "$conf" ]]; then
    v=$(awk -F= '/^budget_daily_usd[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$conf")
  fi
  echo "${v:-10}"
}

# stdout: 今日累计成本（USD，浮点）
budget_today() {
  : "${HARNESS_PYTHON:?lib/python_env.sh must be sourced first}"
  "$HARNESS_PYTHON" -m harness.cli.db_cli today-cost
}

# 退出码：0 未超 / 1 超限。不杀进程，仅信号。
budget_check() {
  local used limit
  used=$(budget_today)
  limit=$(_budget_daily_limit)
  # 用 python 比浮点（bash 不支持浮点）
  "$HARNESS_PYTHON" -c "import sys; sys.exit(0 if float('$used') < float('$limit') else 1)"
}

# 阶段一占位：阶段二补真 kill switch。
budget_kill_switch() {
  echo "budget_kill_switch: not implemented (stage 2)" >&2
  return 0
}
