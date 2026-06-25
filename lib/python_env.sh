#!/usr/bin/env bash
# Shared Python env loader — source by every bash entry that invokes Python.
#
# 决策（见 CLAUDE.md §8.3）：
#   - 优先使用 .venv/bin/python3（uv sync 后存在）
#   - 否则回落系统 python3
#   - PYTHONPATH 总是包含 src/，以便未 uv sync 也能跑（开发期友好）
#
# 已 source 过的进程不再重复设置。

if [[ -z "${HARNESS_PYTHON:-}" ]]; then
  : "${HARNESS_HOME:?HARNESS_HOME must be set before sourcing python_env.sh}"
  if [[ -x "$HARNESS_HOME/.venv/bin/python3" ]]; then
    HARNESS_PYTHON="$HARNESS_HOME/.venv/bin/python3"
  else
    HARNESS_PYTHON=python3
  fi
  export HARNESS_PYTHON
fi

if [[ "${PYTHONPATH:-}" != *"$HARNESS_HOME/src"* ]]; then
  export PYTHONPATH="$HARNESS_HOME/src${PYTHONPATH:+:$PYTHONPATH}"
fi
