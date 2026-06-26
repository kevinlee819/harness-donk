#!/usr/bin/env bash
# manual smoke: adapters/codex.sh 真调 — 不进 CI
#
# 预期：~$0.05 / ~30s
# 需要：codex CLI + login + 网络
# 覆盖：initial 调用 + resume by UUID（验证 c47048b 修过的 bug 不复发）
#
# 用法：bash tests/manual/smoke_real_codex.sh

set -euo pipefail

HARNESS_HOME="${HARNESS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SMOKE_DIR=$(mktemp -d -t harness-codex-smoke.XXXXXX)
trap 'rm -rf "$SMOKE_DIR"' EXIT

mkdir -p "$SMOKE_DIR/wt"
cd "$SMOKE_DIR/wt"
git init -q
git config user.email t@t
git config user.name t
git config commit.gpgsign false
echo init > README.md
git add . && git commit -qm i

# ── initial 调用 ──
cat > "$SMOKE_DIR/p1.txt" <<'EOF'
请在仓库根创建文件 CX.txt，内容单行：codex smoke ok
EOF

echo "▶ initial call..."
R1=$(ADAPTER_TASK_FILE="$SMOKE_DIR/p1.txt" \
     ADAPTER_WORKTREE="$SMOKE_DIR/wt" \
     ADAPTER_TASK_ID=T-cxsmoke ADAPTER_WORKER_ID=w1 \
     ADAPTER_TIMEOUT=120 \
     bash "$HARNESS_HOME/adapters/codex.sh")
echo "$R1" | jq .
sid=$(echo "$R1" | jq -r '.session_id')
[[ "$sid" != "null" && -n "$sid" ]] || { echo "✗ no session_id returned" >&2; exit 1; }
[[ -f "$SMOKE_DIR/wt/CX.txt" ]] || { echo "✗ CX.txt not created" >&2; exit 1; }
echo "✓ initial: session_id=$sid  file created"

# ── resume by UUID ──
cat > "$SMOKE_DIR/p2.txt" <<'EOF'
我之前让你做了什么？(简短回答)
EOF

echo "▶ resume by UUID..."
R2=$(ADAPTER_TASK_FILE="$SMOKE_DIR/p2.txt" \
     ADAPTER_WORKTREE="$SMOKE_DIR/wt" \
     ADAPTER_TASK_ID=T-cxsmoke ADAPTER_WORKER_ID=w1 \
     ADAPTER_SESSION_ID="$sid" \
     ADAPTER_TIMEOUT=120 \
     bash "$HARNESS_HOME/adapters/codex.sh")
echo "$R2" | jq .
ok=$(echo "$R2" | jq -r '.ok')
sid2=$(echo "$R2" | jq -r '.session_id')
[[ "$ok" == "true" ]] || { echo "✗ resume returned ok=false" >&2; exit 1; }
[[ "$sid2" == "$sid" ]] || { echo "✗ session_id changed: $sid → $sid2" >&2; exit 1; }
echo "✓ resume: session_id preserved"

# 结果文本应提到 CX.txt（上下文连贯）
result=$(echo "$R2" | jq -r '.result')
if [[ "$result" != *"CX"* && "$result" != *"cx"* && "$result" != *"smoke"* ]]; then
  echo "⚠ result may have lost context: $result" >&2
fi

echo "✓ real codex smoke passed"
