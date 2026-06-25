#!/usr/bin/env bash
# 断言库 — 纯 bash，零依赖（除 jq 用于 JSON 比较）
# 失败时打印上下文并 exit 1（在子进程中调用，runner 捕获返回码）

_assert_fail() {
  local msg="$1"
  echo "  ✗ ASSERT FAIL: $msg" >&2
  echo "    at: ${BASH_SOURCE[2]}:${BASH_LINENO[1]}" >&2
  exit 1
}

assert_eq() {
  # assert_eq <expected> <actual> [msg]
  local exp="$1" act="$2" msg="${3:-equality}"
  if [[ "$exp" != "$act" ]]; then
    _assert_fail "$msg: expected='$exp' actual='$act'"
  fi
}

assert_neq() {
  local a="$1" b="$2" msg="${3:-inequality}"
  if [[ "$a" == "$b" ]]; then
    _assert_fail "$msg: both='$a'"
  fi
}

assert_match() {
  # assert_match <regex> <actual> [msg]
  local pat="$1" act="$2" msg="${3:-regex match}"
  if [[ ! "$act" =~ $pat ]]; then
    _assert_fail "$msg: pattern='$pat' actual='$act'"
  fi
}

assert_not_match() {
  local pat="$1" act="$2" msg="${3:-regex no match}"
  if [[ "$act" =~ $pat ]]; then
    _assert_fail "$msg: pattern='$pat' actual='$act' (matched)"
  fi
}

assert_file_exists() {
  local path="$1" msg="${2:-file exists}"
  [[ -f "$path" ]] || _assert_fail "$msg: $path not found"
}

assert_file_absent() {
  local path="$1" msg="${2:-file absent}"
  [[ ! -e "$path" ]] || _assert_fail "$msg: $path exists"
}

assert_exit_code() {
  # assert_exit_code <expected> <actual> [msg]
  local exp="$1" act="$2" msg="${3:-exit code}"
  [[ "$exp" == "$act" ]] || _assert_fail "$msg: expected=$exp actual=$act"
}

assert_json_eq() {
  # assert_json_eq <expected_json_str> <actual_json_str> [msg]
  # 用 jq -S 标准化键序后字符串比较
  local exp act msg
  exp=$(printf '%s' "$1" | jq -S . 2>/dev/null) || _assert_fail "exp not JSON"
  act=$(printf '%s' "$2" | jq -S . 2>/dev/null) || _assert_fail "act not JSON: $2"
  msg="${3:-json equality}"
  assert_eq "$exp" "$act" "$msg"
}

assert_json_field() {
  # assert_json_field <json> <jq_path> <expected> [msg]
  local json="$1" path="$2" exp="$3"
  local msg="${4:-json field $path}"
  local act
  act=$(printf '%s' "$json" | jq -r "$path") || _assert_fail "jq failed on $path"
  assert_eq "$exp" "$act" "$msg"
}

assert_contains() {
  # assert_contains <substring> <haystack> [msg]
  local needle="$1" hay="$2" msg="${3:-contains substring}"
  if [[ "$hay" != *"$needle"* ]]; then
    _assert_fail "$msg: needle='$needle' missing from haystack"
  fi
}

# 运行所有定义为 test_* 的函数。每个用例独立子进程，互不污染。
# 用法：在测试脚本末尾调用 run_tests
run_tests() {
  local total=0 passed=0 failed=0 name rc
  local funcs=()
  while IFS= read -r line; do funcs+=("$line"); done < <(declare -F | awk '$3 ~ /^test_/ {print $3}')
  for name in "${funcs[@]+"${funcs[@]}"}"; do
    total=$((total+1))
    # subshell 隔离 + 失败不退出
    (set -euo pipefail; "$name") 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "  ✓ $name"
      passed=$((passed+1))
    else
      echo "  ✗ $name (rc=$rc)" >&2
      failed=$((failed+1))
    fi
  done
  echo "  ── $passed/$total passed, $failed failed"
  [[ $failed -eq 0 ]] || exit 1
}
