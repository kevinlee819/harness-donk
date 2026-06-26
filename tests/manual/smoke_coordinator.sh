#!/usr/bin/env bash
# manual smoke: 协调者 system prompt 真用 harness-task 工具
#
# 预期：~$0.10 / ~25s
# 需要：claude CLI + login + 网络
# 覆盖：harness-infi 路径的核心（不真启 tmux，用 claude --print 单轮模拟）
#
# 用法：bash tests/manual/smoke_coordinator.sh

set -euo pipefail

HARNESS_HOME="${HARNESS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SMOKE_DIR=$(mktemp -d -t harness-coord-smoke.XXXXXX)
trap 'rm -rf "$SMOKE_DIR"' EXIT

mkdir -p "$SMOKE_DIR/proj"
cd "$SMOKE_DIR/proj"
git init -q
git config user.email t@t
git config user.name t
git config commit.gpgsign false
echo init > README.md
git add . && git commit -qm i
"$HARNESS_HOME/bin/harness" init >/dev/null

export HARNESS_HOME
export HARNESS_DB="$SMOKE_DIR/proj/.harness/harness.db"
export PATH="$HARNESS_HOME/coordinator/tools:$HARNESS_HOME/bin:$PATH"

echo "▶ sending vague request to coordinator..."
RESP=$(claude --print \
  --append-system-prompt "$(cat $HARNESS_HOME/coordinator/coordinator.md)" \
  --permission-mode bypassPermissions \
  --model "${HARNESS_SMOKE_MODEL:-claude-sonnet-4-6}" \
  --output-format json <<'EOF'
请把这个需求加到队列：往 README.md 末尾追加一行 "coordinator smoke"。
文件范围限 README.md。验收命令：grep -q 'coordinator smoke' README.md。
EOF
)

result=$(echo "$RESP" | jq -r '.result')
cost=$(echo "$RESP" | jq -r '.total_cost_usd')
turns=$(echo "$RESP" | jq -r '.num_turns')

echo "$RESP" | jq '{result,total_cost_usd,num_turns}'
echo
echo "result text: $result"

# 验证任务真被入队
n=$(harness-task query | wc -l | tr -d ' ')
[[ "$n" -gt 0 ]] || { echo "✗ no task queued" >&2; exit 1; }

# 验证 specs/ 有文件
spec_files=$(ls specs/*.md 2>/dev/null | wc -l | tr -d ' ')
[[ "$spec_files" -gt 0 ]] || { echo "✗ no spec file written" >&2; exit 1; }

# 验证 spec 含必填字段（文件范围 + 验收）
first_spec=$(ls specs/*.md | head -1)
grep -q "文件范围" "$first_spec" || { echo "✗ spec missing 文件范围" >&2; exit 1; }
grep -q "验收" "$first_spec" || { echo "✗ spec missing 验收清单" >&2; exit 1; }

echo "✓ coordinator smoke passed"
echo "  cost=\$$cost  turns=$turns"
echo "  queued: $n task(s), spec: $first_spec"
