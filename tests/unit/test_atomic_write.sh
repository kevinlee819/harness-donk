#!/usr/bin/env bash
# unit: lib/atomic_write.sh
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"
source "$HARNESS_HOME/lib/atomic_write.sh"

register_cleanup_trap
TMP=$(make_tmp_dir); track_cleanup "$TMP"

test_writes_valid_json() {
  local path="$TMP/a.json"
  atomic_write_json "$path" '{"k":1}'
  assert_file_exists "$path"
  assert_json_field "$(cat "$path")" '.k' '1'
}

test_rejects_invalid_json() {
  local path="$TMP/b.json"
  set +e
  atomic_write_json "$path" '{not json' 2>/dev/null
  local rc=$?
  set -e
  assert_neq 0 "$rc" "invalid JSON should fail"
  assert_file_absent "$path" "no half file"
}

test_no_tmp_leftover_on_success() {
  local path="$TMP/c.json"
  atomic_write_json "$path" '{"x":2}'
  local tmps; tmps=$(find "$TMP" -name 'c.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
  assert_eq 0 "$tmps" "no leftover *.tmp"
}

test_overwrites_existing() {
  local path="$TMP/d.json"
  atomic_write_json "$path" '{"v":1}'
  atomic_write_json "$path" '{"v":2}'
  assert_json_field "$(cat "$path")" '.v' '2'
}

test_creates_parent_dir() {
  local path="$TMP/nested/deep/e.json"
  atomic_write_json "$path" '{"ok":true}'
  assert_file_exists "$path"
}

test_atomic_write_text_no_json_check() {
  local path="$TMP/f.txt"
  atomic_write_text "$path" "not json: {"
  assert_eq "not json: {" "$(cat "$path")"
}

run_tests
