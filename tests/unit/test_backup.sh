#!/usr/bin/env bash
# unit: bin/harness backup — 在线备份 + 保留策略
set -uo pipefail
source "$TEST_LIB/assert.sh"
source "$TEST_LIB/setup.sh"

register_cleanup_trap

_setup() {
  PROJ=$(make_fixture_project)
  track_cleanup "$(dirname "$PROJ")"
}

test_backup_creates_db_file() {
  _setup
  cd "$PROJ"
  local out; out=$("$HARNESS_HOME/bin/harness" backup)
  assert_file_exists "$out" "backup file written"
  # 应是合法 sqlite db
  sqlite3 "$out" "SELECT 1" >/dev/null
  assert_eq "0" "$?" "backup file is valid sqlite"
}

test_backup_retention_deletes_old_files() {
  _setup
  cd "$PROJ"
  local bdir="$PROJ/.harness/backups"
  mkdir -p "$bdir"
  # 造 3 个老文件（mtime 10 天前）
  touch -t "$(date -u -v-10d +%Y%m%d0000 2>/dev/null || date -d '10 days ago' +%Y%m%d0000)" \
    "$bdir/harness-old1.db" "$bdir/harness-old2.db" "$bdir/harness-old3.db"
  # 再造一个最新的（current）
  touch "$bdir/harness-recent.db"

  HARNESS_BACKUP_RETAIN_DAYS=7 "$HARNESS_HOME/bin/harness" backup >/dev/null

  # 3 个 10 天前的应被清掉
  assert_file_absent "$bdir/harness-old1.db" "old1 deleted"
  assert_file_absent "$bdir/harness-old2.db" "old2 deleted"
  assert_file_absent "$bdir/harness-old3.db" "old3 deleted"
  # recent 应在；新备份也在（目录至少 2 个 .db 文件：recent + 新建的）
  assert_file_exists "$bdir/harness-recent.db" "recent kept"
  local total; total=$(ls "$bdir"/harness-*.db 2>/dev/null | wc -l | tr -d ' ')
  # 期望 = recent + 新建 = 2（3 个 old 已删）
  assert_eq "2" "$total" "only recent + new remain"
}

test_backup_retention_keeps_recent_files() {
  _setup
  cd "$PROJ"
  local bdir="$PROJ/.harness/backups"
  mkdir -p "$bdir"
  # 3 天前 — 不应被 7 天默认保留删
  touch -t "$(date -u -v-3d +%Y%m%d0000 2>/dev/null || date -d '3 days ago' +%Y%m%d0000)" \
    "$bdir/harness-3days.db"

  "$HARNESS_HOME/bin/harness" backup >/dev/null

  assert_file_exists "$bdir/harness-3days.db" "3-day-old kept (< 7d)"
}

run_tests
