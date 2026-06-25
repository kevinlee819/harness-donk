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
CROSS_REVIEW_REVIEWER=$(_extract 'cross_review_reviewer') # claude / codex

_run_step "build"        "$BUILD_CMD"
_run_step "lint"         "$LINT_CMD"
_run_step "test"         "$TEST_CMD"
_run_step "diff_audit"   "$DIFF_AUDIT_CMD"

# ── 第 5 步：跨模型审查 ─────────────────────────────────────
# 把 diff 喂给另一 backend，要 {approve:bool, issues:[str]} JSON。
# enabled=false 或 --skip-cross-review 时记 skipped。
_run_cross_review() {
  : "${HARNESS_HOME:?HARNESS_HOME required for cross_review}"
  local reviewer="${CROSS_REVIEW_REVIEWER:-codex}"
  local adapter="$HARNESS_HOME/adapters/${reviewer}.sh"
  if [[ ! -x "$adapter" && ! -f "$adapter" ]]; then
    STEPS_JSON+=("$(jq -nc --arg r "$reviewer" \
      '{name:"cross_review", ok:false, duration_ms:0, skipped:false,
        output:("reviewer adapter not found: " + $r)}')")
    overall_ok=0
    summary="${summary:+$summary; }cross_review reviewer missing"
    return 1
  fi

  # 取差集：base..HEAD（worktree 是从主分支拉出来的，base 就是 merge-base）
  local main_branch
  main_branch=$(git symbolic-ref --short refs/heads/main 2>/dev/null \
                || git -C "$WORKTREE" rev-parse --abbrev-ref @{upstream} 2>/dev/null \
                || echo "main")
  local base; base=$(git -C "$WORKTREE" merge-base HEAD "$main_branch" 2>/dev/null || git -C "$WORKTREE" rev-list --max-parents=0 HEAD | tail -1)
  local diff_text; diff_text=$(git -C "$WORKTREE" diff "$base..HEAD" 2>/dev/null)
  # 空 diff（什么都没改）就跳过
  if [[ -z "$diff_text" ]]; then
    STEPS_JSON+=("$(jq -nc '{name:"cross_review", ok:true, duration_ms:0, skipped:true, output:"empty diff"}')")
    return 0
  fi

  # 截断 diff 至 16KB，超过的后置由审查方提示
  local diff_trim; diff_trim=$(printf '%s' "$diff_text" | head -c 16384)
  local truncated=""
  [[ ${#diff_text} -gt 16384 ]] && truncated="（diff 已截断到前 16KB）"

  # 构造 review prompt（含 REVIEW DIFF 标记触发 mock）
  local prompt_file; prompt_file=$(mktemp -t crreview.XXXXXX)
  {
    echo "=== REVIEW DIFF ==="
    echo "你正在跨模型审查同行 agent 的 diff。$truncated"
    echo "仅以 JSON 回复，schema：{\"approve\": bool, \"issues\": [string]}"
    echo "approve=false 时 issues 必须非空，每条一句话说明问题。"
    echo "不要写其他文本、不要 markdown 代码块、不要前缀。"
    echo
    echo "=== diff ==="
    echo "$diff_trim"
  } > "$prompt_file"

  # 调审查 backend；review 模式用 read-only sandbox（codex）/ 默认（claude）
  # mock 模式（测试用）：父进程已 export 即继承；不在命令前缀做条件 env（bash 不支持）
  # 把 review 调用也落 raw log（worktree 合并后即丢；放到项目 .harness/logs/raw/）
  local log_dir=""
  if [[ -n "${HARNESS_TASK_ID:-}" ]] && [[ -n "${HARNESS_DB:-}" ]]; then
    log_dir=$(dirname "$HARNESS_DB")/logs/raw
    mkdir -p "$log_dir"
  fi
  local start; start=$(python3 -c 'import time;print(int(time.time()*1000))')
  local resp; set +e
  resp=$(ADAPTER_TASK_FILE="$prompt_file" ADAPTER_WORKTREE="$WORKTREE" \
         ADAPTER_SANDBOX="read-only" ADAPTER_MAX_TURNS=4 \
         ADAPTER_TASK_ID="${HARNESS_TASK_ID:-cross-review}-review" \
         ADAPTER_LOG_DIR="$log_dir" \
         bash "$adapter")
  local rc=$?
  set -e
  rm -f "$prompt_file"
  local end; end=$(python3 -c 'import time;print(int(time.time()*1000))')
  local dur=$((end - start))

  if [[ $rc -ne 0 ]] || [[ "$(printf '%s' "$resp" | jq -r '.ok')" != "true" ]]; then
    local err; err=$(printf '%s' "$resp" | jq -r '.error // "review adapter failed"')
    STEPS_JSON+=("$(jq -nc --arg n "cross_review" --argjson d "$dur" --arg o "$err" \
      '{name:$n, ok:false, duration_ms:$d, skipped:false, output:$o}')")
    overall_ok=0
    summary="${summary:+$summary; }cross_review adapter error"
    return 1
  fi

  local result_text; result_text=$(printf '%s' "$resp" | jq -r '.result')
  # 容忍 result 里有 markdown 代码块包裹：抓第一个 { 到最后一个 }
  local json_only; json_only=$(printf '%s' "$result_text" | python3 -c '
import json, re, sys
s = sys.stdin.read()
# strip ```json ... ``` 或 ``` ... ``` 包裹
m = re.search(r"\{.*\}", s, re.DOTALL)
print(m.group(0) if m else s.strip())
')
  local approve issues
  approve=$(printf '%s' "$json_only" | jq -r '.approve // false' 2>/dev/null)
  issues=$(printf '%s' "$json_only" | jq -c '.issues // []' 2>/dev/null)

  local ok=true; local out_summary="approved"
  if [[ "$approve" != "true" ]]; then
    ok=false; overall_ok=0
    local n_issues; n_issues=$(printf '%s' "$issues" | jq 'length' 2>/dev/null || echo 0)
    out_summary="rejected ($n_issues issues): $issues"
    summary="${summary:+$summary; }cross_review rejected"
  fi
  STEPS_JSON+=("$(jq -nc --arg n "cross_review" --argjson ok "$ok" \
    --argjson d "$dur" --arg o "$out_summary" \
    '{name:$n, ok:$ok, duration_ms:$d, skipped:false, output:$o}')")
}

if [[ "$CROSS_REVIEW_ENABLED" == "true" && $SKIP_CROSS_REVIEW -eq 0 ]]; then
  _run_cross_review
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
