#!/usr/bin/env bash
# 测试总入口
# 用法：tests/run.sh [--filter <pattern>] [--unit-only|--integration-only] [--verbose]
#
# 发现 tests/{unit,integration}/test_*.sh，每个文件独立子进程跑。
# 任一失败则 exit 1，stdout 汇总。

set -uo pipefail

HARNESS_HOME="${HARNESS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export HARNESS_HOME
export TEST_LIB="$HARNESS_HOME/tests/lib"
source "$HARNESS_HOME/lib/python_env.sh"

FILTER=""
UNIT=1
INTEGRATION=1
VERBOSE=0
PER_TEST_TIMEOUT=120

while [[ $# -gt 0 ]]; do
  case "$1" in
    --filter) FILTER="$2"; shift 2 ;;
    --unit-only) INTEGRATION=0; shift ;;
    --integration-only) UNIT=0; shift ;;
    --verbose|-v) VERBOSE=1; shift ;;
    --timeout) PER_TEST_TIMEOUT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

collect() {
  local dir="$1"
  [[ ! -d "$dir" ]] && return 0
  find "$dir" \( -name 'test_*.sh' -o -name 'test_*.py' \) -type f | sort
}

files=()
if [[ $UNIT -eq 1 ]]; then
  while IFS= read -r line; do files+=("$line"); done < <(collect "$HARNESS_HOME/tests/unit")
fi
if [[ $INTEGRATION -eq 1 ]]; then
  while IFS= read -r line; do files+=("$line"); done < <(collect "$HARNESS_HOME/tests/integration")
fi

if [[ -n "$FILTER" ]]; then
  filtered=()
  for f in "${files[@]+"${files[@]}"}"; do
    [[ "$f" == *"$FILTER"* ]] && filtered+=("$f")
  done
  files=("${filtered[@]+"${filtered[@]}"}")
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "no tests found"
  exit 0
fi

total_files=${#files[@]}
ok_files=0
fail_files=0
fail_names=()

_runner_for() {
  case "$1" in
    *.sh) echo bash ;;
    *.py)
      # 取相对 tests/ 的模块路径，避免 python3 直接跑文件时无包上下文
      # 用 unittest 发现：python3 -m unittest tests.unit.test_xxx
      echo "python3 -m unittest -v"
      ;;
  esac
}

start_ts=$(date +%s)
for f in "${files[@]}"; do
  rel="${f#$HARNESS_HOME/}"
  echo "▶ $rel"
  if [[ "$f" == *.py ]]; then
    # 将 tests/unit/test_db.py → tests.unit.test_db
    mod="${rel%.py}"
    mod="${mod//\//.}"
    cmd=("$HARNESS_PYTHON" -m unittest "$mod")
  else
    cmd=(bash "$f")
  fi
  if [[ $VERBOSE -eq 1 ]]; then
    (cd "$HARNESS_HOME" && timeout "$PER_TEST_TIMEOUT" "${cmd[@]}")
  else
    out=$(cd "$HARNESS_HOME" && timeout "$PER_TEST_TIMEOUT" "${cmd[@]}" 2>&1)
  fi
  rc=$?
  if [[ $rc -eq 0 ]]; then
    ok_files=$((ok_files+1))
    if [[ $VERBOSE -eq 0 ]]; then
      # bash 测试有 ✓ / ──；python unittest 输出 "Ran N tests" / "OK"
      printf '%s\n' "$out" | grep -E '^(  ✓|  ──|Ran [0-9]+ tests|OK$)' || true
    fi
  else
    fail_files=$((fail_files+1))
    fail_names+=("$rel")
    if [[ $VERBOSE -eq 0 ]]; then
      printf '%s\n' "$out"
    fi
    echo "  → FAILED (rc=$rc)" >&2
  fi
done
end_ts=$(date +%s)
dur=$((end_ts - start_ts))

echo
echo "════════════════════════════════════════════════════════"
echo "Files: $ok_files/$total_files passed, $fail_files failed   (${dur}s)"
if [[ $fail_files -gt 0 ]]; then
  echo "Failed:"
  printf '  - %s\n' "${fail_names[@]}"
  exit 1
fi
echo "ALL GREEN ✓"
