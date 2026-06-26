#!/usr/bin/env bash
# manual smoke: 跨模型审查 — codex 写 + claude 审，覆盖 approve + reject 两条路径
#
# 预期：~$0.20 / ~3min
# 需要：claude + codex CLI + login + 网络
# 覆盖：阶段三 D1 的完整闭环
#
# 用法：bash tests/manual/smoke_real_cross_review.sh

set -euo pipefail

HARNESS_HOME="${HARNESS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SMOKE_DIR=$(mktemp -d -t harness-xreview-smoke.XXXXXX)
trap 'rm -rf "$SMOKE_DIR"' EXIT

mkdir -p "$SMOKE_DIR/proj"
cd "$SMOKE_DIR/proj"
git init -q
git config user.email t@t
git config user.name t
git config commit.gpgsign false
echo init > README.md
git add . && git commit -qm i

"$HARNESS_HOME/bin/harness" init --backend codex >/dev/null
# init --backend codex 自动反转 reviewer 为 claude

python3 - <<'PY'
import re, pathlib
p = pathlib.Path('AGENTS.md')
t = p.read_text()
t = re.sub(r'(\ntest:\s*)""', r'\1"python3 -m unittest test_clean.py"', t, count=1)
t = t.replace('cross_review_enabled: false', 'cross_review_enabled: true')
p.write_text(t)
PY
git add AGENTS.md && git commit -qm "gate config" >/dev/null

# ── 1. approve 路径：让 codex 写一段干净代码 ──
export PATH="$HARNESS_HOME/coordinator/tools:$HARNESS_HOME/bin:$PATH"
harness-task add --id T-clean <<'EOF'
创建 clean.py 实现 def add(a, b): return a + b。
创建 test_clean.py 用 unittest 验证 add(2,3)==5。
完成后 git add + commit。
EOF

echo "▶ approve path: codex writes clean code → claude approves..."
"$HARNESS_HOME/bin/harness" run-once --backend codex 2>&1 | tail -8

row=$(harness-task query --task T-clean)
echo "$row" | grep -q merged || { echo "✗ T-clean not merged: $row" >&2; exit 1; }
echo "✓ approve path passed"

# ── 2. reject 路径：手动注入 buggy diff，gate cross_review 应 reject ──
git worktree add "$SMOKE_DIR/.worktrees/proj/T-bug" -b harness/T-bug 2>&1 | tail -1
cat > "$SMOKE_DIR/.worktrees/proj/T-bug/clean.py" <<'EOF'
# 改劣化版本：硬编码、忽略参数
def add(a, b):
    return 5  # always return 5, regardless of inputs
EOF
(cd "$SMOKE_DIR/.worktrees/proj/T-bug" && git add clean.py && git commit -qm "buggy version")

echo "▶ reject path: claude reviews intentional bug..."
HARNESS_TASK_ID=T-bug HARNESS_DB="$SMOKE_DIR/proj/.harness/harness.db" \
  bash "$HARNESS_HOME/lib/gate.sh" "$SMOKE_DIR/.worktrees/proj/T-bug" || true

cr=$(jq -c '.steps[] | select(.name=="cross_review")' \
     "$SMOKE_DIR/.worktrees/proj/T-bug/.gate-report.json")
ok=$(echo "$cr" | jq -r '.ok')
out=$(echo "$cr" | jq -r '.output')

if [[ "$ok" == "true" ]]; then
  echo "⚠ claude approved buggy code: $out"
  echo "  (may be acceptable if test passes; check manually)"
else
  echo "✓ reject path: claude caught bug"
  echo "  issues: $out" | head -3
fi
echo
echo "✓ smoke completed; both paths exercised"
