#!/usr/bin/env bash
# 校验门 — 读 AGENTS.md 的 gate 配置，按序执行
# 见 docs/interfaces.md §6, docs/data-schemas.md §3
#
# 用法：gate.sh <worktree_dir> [--skip-cross-review]
# 退出：0 全绿；非 0 至少一步失败
# 副作用：<worktree>/.gate-report.json
#
# gate 配置约定（写在 AGENTS.md 中由 ```gate ... ``` 包裹）：
#   gate:
#     build: "tsc --noEmit"        # 留空字符串则跳过
#     lint:  "npm run lint"
#     test:  "npm test"
#     diff_audit: ""               # MVP 留空
#     cross_review:
#       enabled: false             # MVP 关
#
# MVP 简化：用 grep + sed 抽取 key: value，不引 yq 依赖

set -uo pipefail

WORKTREE="${1:?worktree path required}"
SKIP_CROSS_REVIEW=0
[[ "${2:-}" == "--skip-cross-review" ]] && SKIP_CROSS_REVIEW=1

[[ ! -d "$WORKTREE" ]] && { echo "gate: worktree not found: $WORKTREE" >&2; exit 2; }
cd "$WORKTREE"

AGENTS_FILE=""
for cand in AGENTS.md ../AGENTS.md ../../AGENTS.md; do
  if [[ -f "$cand" ]]; then AGENTS_FILE=$(cd "$(dirname "$cand")" && pwd)/$(basename "$cand"); break; fi
done

_extract() {
  # _extract <key>  — 从 AGENTS.md gate 块中抽 value（最朴素 sed）
  [[ -z "$AGENTS_FILE" ]] && return 0
  awk -v key="$1" '
    /^```gate/{in_block=1; next}
    /^```/{in_block=0}
    in_block && $0 ~ ("^[[:space:]]*" key ":") {
      sub(/^[[:space:]]*[a-zA-Z_]+:[[:space:]]*/, "", $0)
      gsub(/^"|"$/, "", $0)
      print $0
      exit
    }
  ' "$AGENTS_FILE"
}

REPORT="$WORKTREE/.gate-report.json"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

declare -a STEPS_JSON=()
overall_ok=1
summary=""

_run_step() {
  # _run_step <name> <command>
  local name="$1" cmd="$2"
  local skipped=false ok=true output="" dur_ms=0
  if [[ -z "$cmd" ]]; then
    skipped=true
    STEPS_JSON+=("$(jq -nc --arg n "$name" '{name:$n, ok:true, duration_ms:0, skipped:true, output:""}')")
    return 0
  fi
  local start end
  start=$(python3 -c 'import time;print(int(time.time()*1000))')
  set +e
  output=$(bash -c "$cmd" 2>&1)
  rc=$?
  set -e
  end=$(python3 -c 'import time;print(int(time.time()*1000))')
  dur_ms=$((end - start))
  if [[ $rc -ne 0 ]]; then
    ok=false; overall_ok=0
    summary="${summary:+$summary; }$name failed (rc=$rc)"
  fi
  # 截断 output 至 2KB
  local trimmed; trimmed=$(printf '%s' "$output" | tail -c 2048)
  STEPS_JSON+=("$(jq -nc --arg n "$name" --argjson ok "$ok" --argjson d "$dur_ms" --arg o "$trimmed" \
    '{name:$n, ok:$ok, duration_ms:$d, skipped:false, output:$o}')")
}

BUILD_CMD=$(_extract build)
LINT_CMD=$(_extract lint)
TEST_CMD=$(_extract test)
DIFF_AUDIT_CMD=$(_extract diff_audit)
CROSS_REVIEW_ENABLED=$(_extract 'cross_review_enabled')   # 简化：扁平 key

_run_step "build"        "$BUILD_CMD"
_run_step "lint"         "$LINT_CMD"
_run_step "test"         "$TEST_CMD"
_run_step "diff_audit"   "$DIFF_AUDIT_CMD"

if [[ "$CROSS_REVIEW_ENABLED" == "true" && $SKIP_CROSS_REVIEW -eq 0 ]]; then
  # MVP 不实现真正的跨模型审查，记录 skipped 占位
  STEPS_JSON+=("$(jq -nc '{name:"cross_review", ok:true, duration_ms:0, skipped:true, output:"not implemented in MVP"}')")
else
  STEPS_JSON+=("$(jq -nc '{name:"cross_review", ok:true, duration_ms:0, skipped:true, output:""}')")
fi

ok_bool=true; [[ $overall_ok -eq 0 ]] && ok_bool=false
task_id="${HARNESS_TASK_ID:-unknown}"

steps_arr=$(printf '%s\n' "${STEPS_JSON[@]}" | jq -s .)
jq -n --arg ts "$TS" --arg tid "$task_id" --argjson ok "$ok_bool" \
      --arg summary "${summary:-all green}" --argjson steps "$steps_arr" \
  '{schema_version:1, task_id:$tid, ts:$ts, ok:$ok, steps:$steps, summary:$summary}' \
  > "$REPORT"

if [[ $overall_ok -eq 0 ]]; then exit 1; fi
exit 0
