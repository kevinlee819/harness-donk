#!/usr/bin/env bash
# 原子写 JSON：先写 *.tmp 再 rename，崩溃也不会留半截文件。
# 用法：source lib/atomic_write.sh; atomic_write_json <path> <json_string>

atomic_write_json() {
  local path="$1"
  local content="$2"
  local dir tmp

  [[ -z "$path" ]] && { echo "atomic_write_json: empty path" >&2; return 2; }

  dir=$(dirname "$path")
  mkdir -p "$dir"
  tmp="$path.tmp.$$"

  # 校验 JSON 合法性后再写盘，防写出破损文件
  if ! printf '%s' "$content" | jq -e . >/dev/null 2>&1; then
    echo "atomic_write_json: invalid JSON for $path" >&2
    return 1
  fi

  printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path"
}

atomic_write_text() {
  local path="$1"
  local content="$2"
  local dir tmp

  [[ -z "$path" ]] && { echo "atomic_write_text: empty path" >&2; return 2; }

  dir=$(dirname "$path")
  mkdir -p "$dir"
  tmp="$path.tmp.$$"
  printf '%s' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path"
}
