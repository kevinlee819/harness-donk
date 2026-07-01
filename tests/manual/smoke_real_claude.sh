#!/usr/bin/env bash
# manual smoke: adapters/claude.sh 真调 — 不进 CI
#
# 预期：~$0.01 / ~15s
# 需要：claude CLI + login + 网络
#
# 用法：bash tests/manual/smoke_real_claude.sh

set -euo pipefail

HARNESS_HOME="${HARNESS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SMOKE_DIR=$(mktemp -d -t harness-claude-smoke.XXXXXX)
trap 'rm -rf "$SMOKE_DIR"' EXIT

mkdir -p "$SMOKE_DIR/wt"
cd "$SMOKE_DIR/wt"
git init -q
git config user.email t@t
git config user.name t
git config commit.gpgsign false
echo "init" > README.md
git add . && git commit -qm i

cat > "$SMOKE_DIR/prompt.txt" <<'EOF'
请在仓库根创建文件 SMOKE.txt，内容单行：claude smoke ok
完成后 git add + commit。
EOF

echo "▶ calling claude.sh (real) — should write SMOKE.txt and return JSON..."
RESP=$(ADAPTER_TASK_FILE="$SMOKE_DIR/prompt.txt" \
       ADAPTER_WORKTREE="$SMOKE_DIR/wt" \
       ADAPTER_TASK_ID=T-smoke ADAPTER_WORKER_ID=w1 \
       ADAPTER_MODEL="${HARNESS_SMOKE_MODEL:-claude-sonnet-4-6}" \
       ADAPTER_TIMEOUT=120 \
       bash "$HARNESS_HOME/adapters/claude.sh")

echo "$RESP" | jq .

ok=$(echo "$RESP" | jq -r '.ok')
turns=$(echo "$RESP" | jq -r '.num_turns')
duration=$(echo "$RESP" | jq -r '.duration_ms')

if [[ "$ok" != "true" ]]; then
  echo "✗ adapter returned ok=false" >&2
  exit 1
fi

if [[ ! -f "$SMOKE_DIR/wt/SMOKE.txt" ]]; then
  echo "✗ SMOKE.txt not created" >&2
  exit 1
fi

content=$(cat "$SMOKE_DIR/wt/SMOKE.txt")
if [[ "$content" != *"claude smoke ok"* ]]; then
  echo "✗ SMOKE.txt content unexpected: $content" >&2
  exit 1
fi

echo "✓ real claude smoke passed"
echo "  turns=$turns  duration=${duration}ms"
