#!/usr/bin/env bash
# integration: --backend 切换 — orchestrator 调对应 adapter，DB 用对应 backend 名字
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"

register_cleanup_trap
TASK_CMD="$HARNESS_HOME/coordinator/tools/harness-task"

test_backend_codex_routes_to_codex_adapter() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  # mock codex 写 CODEX.txt（claude mock 写 HELLO.txt）— 用文件存在性区分
  set_gate_test_cmd "$proj" "test -f CODEX.txt"
  "$TASK_CMD" add --id T-bsw <<< "make CODEX.txt" >/dev/null

  "$HARNESS_HOME/bin/harness" run-once --mock --backend codex 2>&1 | tail -10

  local row; row=$("$TASK_CMD" query --task T-bsw)
  assert_contains "merged" "$row" "codex-backed task → merged"
  assert_file_exists "$proj/CODEX.txt"

  # calls 表应记 backend=codex
  local n_codex; n_codex=$(sqlite3 "$proj/.harness/harness.db" \
    "SELECT COUNT(*) FROM calls WHERE task_id='T-bsw' AND backend='codex';")
  assert_neq "0" "$n_codex" "call recorded with backend=codex"
}

test_backend_default_still_claude() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  set_gate_test_cmd "$proj" "test -f HELLO.txt"
  "$TASK_CMD" add --id T-defcl <<< "make HELLO.txt" >/dev/null

  "$HARNESS_HOME/bin/harness" run-once --mock 2>&1 | tail -5

  local row; row=$("$TASK_CMD" query --task T-defcl)
  assert_contains "merged" "$row"
  local n_claude; n_claude=$(sqlite3 "$proj/.harness/harness.db" \
    "SELECT COUNT(*) FROM calls WHERE task_id='T-defcl' AND backend='claude';")
  assert_neq "0" "$n_claude" "default backend=claude"
}

test_unknown_backend_fails_fast() {
  local parent; parent=$(make_tmp_dir); track_cleanup "$parent"
  local proj; proj=$(make_fixture_project "$parent")
  cd "$proj"
  set +e
  "$HARNESS_HOME/bin/harness" run-once --mock --backend bogus >/dev/null 2>&1
  local rc=$?
  set -e
  assert_neq 0 "$rc" "unknown backend → non-zero exit"
}

run_tests
