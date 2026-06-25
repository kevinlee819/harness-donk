#!/usr/bin/env bash
# lib/notify.sh — 通知路由
# 见 docs/interfaces.md §8.1
#
# 阶段二实现：双写
#   1. events 表插一行（编排器/协调者扫描用）
#   2. .harness/events/<ts>-<event_type>-<task_id>.json 落盘（人 / 旁路工具可见）
#
# 阶段三再做：实际向协调者会话 inject（tmux send-keys 或 claude --resume）。
# 阶段一原则：通知是事件，不是动作。这里只记账，决策留给协调者。
#
# 调用：
#   notify <event_type> <task_id_or_-> <payload_json>
#
# event_type ∈ {needs_decision, task_completed, task_failed, budget_exceeded}
#
# 依赖：$HARNESS_PYTHON（lib/python_env.sh）、jq、$HARNESS_DB

notify() {
  : "${HARNESS_PYTHON:?lib/python_env.sh must be sourced first}"
  : "${HARNESS_DB:?HARNESS_DB must be set}"
  local etype="$1" tid="$2"
  local payload="${3:-}"
  [[ -z "$payload" ]] && payload='{}'

  case "$etype" in
    needs_decision|task_completed|task_failed|budget_exceeded) ;;
    *) echo "notify: invalid event_type: $etype" >&2; return 2 ;;
  esac

  # 校验 payload 是合法 JSON
  if ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
    echo "notify: payload not valid JSON: $payload" >&2
    return 2
  fi

  # 写 events 表，拿到 event_id
  local eid
  if [[ "$tid" == "-" || -z "$tid" ]]; then
    eid=$(printf '%s' "$payload" | "$HARNESS_PYTHON" -m harness.cli.db_cli event-write "$etype")
  else
    eid=$(printf '%s' "$payload" | "$HARNESS_PYTHON" -m harness.cli.db_cli event-write "$etype" --task "$tid")
  fi || { echo "notify: db event-write failed" >&2; return 1; }

  # 落盘 JSON（旁路可见）
  local project_dir
  project_dir=$(dirname "$(dirname "$HARNESS_DB")")
  local ev_dir="$project_dir/.harness/events"
  mkdir -p "$ev_dir"
  local ts_file; ts_file=$(date -u +%Y%m%dT%H%M%SZ)
  local tid_seg="${tid}"
  [[ -z "$tid_seg" || "$tid_seg" == "-" ]] && tid_seg="none"
  local fname="$ev_dir/${ts_file}-${etype}-${tid_seg}.json"

  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg etype "$etype" \
        --arg tid "$tid" \
        --argjson eid "$eid" \
        --argjson payload "$payload" \
    '{schema_version:1, id:$eid, ts:$ts, event_type:$etype,
      task_id:(if $tid=="-" or $tid=="" then null else $tid end),
      payload:$payload}' > "$fname.tmp" && mv "$fname.tmp" "$fname"

  echo "$eid"
}
