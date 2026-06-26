#!/usr/bin/env bash
# orchestrator.sh — thin shim, defers to Python implementation.
#
# 阶段四：orchestrator.sh 的实质实现已迁到 src/harness/orchestrator.py（CLAUDE.md §8.2）。
# 本文件保留是因为 bin/harness run-once 和 bin/harness-infi 仍 spawn orchestrator.sh；
# CLI 契约（--once --project --mock --max-retries --model --backend --max-workers）不变。

set -uo pipefail

HARNESS_HOME="${HARNESS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export HARNESS_HOME
source "$HARNESS_HOME/lib/python_env.sh"

exec "$HARNESS_PYTHON" -m harness.cli.orchestrator_cli "$@"
