#!/usr/bin/env bash
# harness-donk installer — 同时支持两种调用方式：
#
#   本地（已 clone）：
#     git clone https://github.com/USER/harness-donk.git
#     cd harness-donk && ./install.sh
#
#   一行装（curl|bash，仓库公开后）：
#     curl -LsSf https://raw.githubusercontent.com/USER/harness-donk/main/install.sh | bash
#
# 默认行为（无参数）：
#   1. 检测系统依赖（git/sqlite≥3.35/jq/tmux/python3）→ 缺则报错退出
#   2. 检测 uv → 缺则用官方脚本安装（curl https://astral.sh/uv/install.sh | sh）
#   3. 源码：若脚本在 git clone 里 → 用所在目录；否则 git clone 到 $HARNESS_HOME
#   4. uv sync 装 Python 依赖
#   5. 入口符号链接到 ~/.local/bin/{harness,harness-infi}
#   6. 把 ~/.local/bin 加进 shell rc（若未在 PATH 上）
#   7. 跑 harness setup 写默认全局配置
#   8. 打印下一步
#
# 选项：
#   --prefix DIR    源码安装目录（默 $HOME/.harness）
#   --bindir DIR    入口符号链接目录（默 $HOME/.local/bin）
#   --yes / -y      跳过所有交互确认
#   --upgrade       已装的源码 git pull --ff-only + uv sync + 幂等重做符号链接
#   --uninstall     反向操作：删符号链接 + shell rc 行 + （可选）源码目录
#   --help / -h     本帮助

set -euo pipefail

# ── 默认值（可被命令行/env 覆盖）──────────────────────────
HARNESS_REPO_URL="${HARNESS_REPO_URL:-https://github.com/USER/harness-donk.git}"
HARNESS_HOME="${HARNESS_HOME:-$HOME/.harness}"
HARNESS_BINDIR="${HARNESS_BINDIR:-$HOME/.local/bin}"
YES=0
MODE="install"

# ── ANSI 色 ────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
  C_BLUE=$'\033[34m';  C_DIM=$'\033[2m';     C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''; C_DIM=''; C_BOLD=''; C_RST=''
fi

ok()    { printf "%s ✓%s %s\n"  "$C_GREEN"  "$C_RST" "$*"; }
warn()  { printf "%s ⚠%s %s\n"  "$C_YELLOW" "$C_RST" "$*"; }
fail()  { printf "%s ✗%s %s\n"  "$C_RED"    "$C_RST" "$*" >&2; }
info()  { printf "%s•%s %s\n"   "$C_BLUE"   "$C_RST" "$*"; }
step()  { printf "\n%s==%s %s%s%s\n" "$C_BOLD" "$C_RST" "$C_BOLD" "$*" "$C_RST"; }

confirm() {
  local prompt="$1"
  if [[ $YES -eq 1 ]]; then return 0; fi
  printf "%s? %s%s [y/N] " "$C_YELLOW" "$prompt" "$C_RST"
  local ans; read -r ans
  [[ "$ans" =~ ^[yY] ]]
}

# ── 参数 ───────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)    HARNESS_HOME="$2"; shift 2 ;;
    --bindir)    HARNESS_BINDIR="$2"; shift 2 ;;
    -y|--yes)    YES=1; shift ;;
    --upgrade)   MODE="upgrade"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    -h|--help)
      sed -n '2,27p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) fail "unknown argument: $1"; exit 1 ;;
  esac
done

# ── 系统依赖检查 ─────────────────────────────────────────
_check_dep() {
  local name="$1" cmd="$2" min_major="${3:-}" min_minor="${4:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "$name 未安装（命令 $cmd 不存在）"
    return 1
  fi
  if [[ -n "$min_major" ]]; then
    local ver major minor
    case "$cmd" in
      sqlite3) ver=$("$cmd" --version 2>/dev/null | awk '{print $1}') ;;
      *)       ver=$("$cmd" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1) ;;
    esac
    major=${ver%%.*}; minor=${ver#*.}; minor=${minor%%.*}
    if (( major < min_major || ( major == min_major && minor < min_minor ) )); then
      fail "${name} 版本过低（${ver} < ${min_major}.${min_minor}）"
      return 1
    fi
    ok "$name $ver"
  else
    ok "$name 已安装"
  fi
}

_install_uv() {
  warn "uv 未安装"
  if confirm "运行官方安装脚本 'curl -LsSf https://astral.sh/uv/install.sh | sh'"; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # uv 默认装到 ~/.local/bin；本 shell 看不到新 PATH，临时补一下
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v uv >/dev/null 2>&1; then
      fail "uv 装完但仍找不到。确认 ~/.local/bin 在 PATH 上"
      exit 1
    fi
    ok "uv $(uv --version 2>&1 | head -1)"
  else
    fail "uv 是 harness 的硬依赖。请手动装：curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
  fi
}

# ── shell rc 检测与 PATH 注入 ───────────────────────────
_detect_shell_rc() {
  # 返回当前用户主 shell 的 rc 文件路径
  local shell_name; shell_name=$(basename "${SHELL:-bash}")
  case "$shell_name" in
    bash) echo "$HOME/.bashrc"   ;;
    zsh)  echo "$HOME/.zshrc"    ;;
    fish) echo "$HOME/.config/fish/config.fish" ;;
    *)    echo "$HOME/.profile"  ;;
  esac
}

_ensure_path() {
  # _ensure_path <dir>  -- 若不在 PATH 中，写一行到对应 rc
  local dir="$1"
  case ":$PATH:" in
    *":$dir:"*) ok "$dir 已在 PATH 上"; return 0 ;;
  esac
  local rc; rc=$(_detect_shell_rc)
  local marker="# added by harness installer"
  if [[ -f "$rc" ]] && grep -qF "$marker" "$rc"; then
    ok "$rc 已有 harness PATH 行"
    return 0
  fi
  if confirm "把 'export PATH=\"$dir:\$PATH\"' 加到 $rc"; then
    mkdir -p "$(dirname "$rc")"
    case "$(basename "$rc")" in
      config.fish)
        printf '\n%s\nfish_add_path -p %s\n' "$marker" "$dir" >> "$rc"
        ;;
      *)
        printf '\n%s\nexport PATH="%s:$PATH"\n' "$marker" "$dir" >> "$rc"
        ;;
    esac
    ok "已写 $rc — 重启 shell 或 source 它后生效"
  else
    warn "跳过 PATH 注入；记得手动把 $dir 加进 PATH，否则 harness/harness-infi 找不到"
  fi
}

# ── 入口符号链接（幂等，install 与 upgrade 共用）───────────
_link_entries() {
  local src="$1" bindir="$2"
  mkdir -p "$bindir"
  for entry in harness harness-infi; do
    local target="$src/bin/$entry"
    local link="$bindir/$entry"
    if [[ ! -f "$target" ]]; then
      fail "$target 不存在 — 源码不完整"
      exit 1
    fi
    if [[ -L "$link" || -e "$link" ]]; then
      if [[ "$(readlink "$link" 2>/dev/null)" == "$target" ]]; then
        ok "${link} → ${target}（已是正确链接）"
        continue
      fi
      if confirm "$link 已存在，覆盖"; then
        rm -f "$link"
      else
        warn "跳过 $link"; continue
      fi
    fi
    ln -s "$target" "$link"
    ok "$link → $target"
  done
}

# ── 源码就位 ────────────────────────────────────────────
_resolve_source() {
  # 如果脚本被 source 自一个有 bin/harness-infi 的目录 → 那就是源码树
  # 否则 git clone 到 $HARNESS_HOME
  local script_path="${BASH_SOURCE[0]:-}"
  if [[ -n "$script_path" && -f "$script_path" ]]; then
    local script_dir; script_dir=$(cd "$(dirname "$script_path")" && pwd)
    if [[ -f "$script_dir/bin/harness-infi" && -f "$script_dir/pyproject.toml" ]]; then
      echo "$script_dir"
      return 0
    fi
  fi
  # curl|bash 模式 — clone
  if [[ -d "$HARNESS_HOME/.git" ]]; then
    info "$HARNESS_HOME 已是 git 仓库，跳过 clone（用 'cd $HARNESS_HOME && git pull' 升级）"
  else
    if [[ -e "$HARNESS_HOME" ]]; then
      fail "$HARNESS_HOME 已存在但不是 git 仓库。删除或换 --prefix"
      exit 1
    fi
    info "克隆 $HARNESS_REPO_URL → $HARNESS_HOME"
    git clone "$HARNESS_REPO_URL" "$HARNESS_HOME"
  fi
  echo "$HARNESS_HOME"
}

# ── 安装主流程 ──────────────────────────────────────────
do_install() {
  step "1/6  检查系统依赖"
  local rc=0
  _check_dep git     git        || rc=1
  _check_dep sqlite3 sqlite3 3 35 || rc=1
  _check_dep jq      jq          || rc=1
  _check_dep tmux    tmux        || rc=1
  _check_dep python3 python3 3 9 || rc=1
  if [[ $rc -ne 0 ]]; then
    fail "请先用包管理器装齐缺失的依赖（macOS: brew；Linux: apt/dnf/pacman）"
    exit 1
  fi

  step "2/6  检查 uv（Python 环境管理）"
  if command -v uv >/dev/null 2>&1; then
    ok "uv $(uv --version 2>&1 | head -1)"
  else
    _install_uv
  fi

  step "3/6  定位源码"
  local src; src=$(_resolve_source)
  ok "源码：$src"
  export HARNESS_HOME="$src"

  step "4/6  uv sync（装 Python 依赖到 $src/.venv）"
  ( cd "$src" && uv sync )
  ok "Python 环境就绪"

  step "5/6  入口符号链接到 $HARNESS_BINDIR"
  _link_entries "$src" "$HARNESS_BINDIR"
  _ensure_path "$HARNESS_BINDIR"

  step "6/6  写全局默认配置（harness setup）"
  # 此时 harness 应已可调（同一 shell 内 PATH 可能还没生效，绝对路径调）
  "$src/bin/harness" setup || warn "harness setup 报错；可单独再跑一次"

  cat <<EOF

${C_GREEN}${C_BOLD}🫏 harness-donk 安装完成${C_RST}

源码：       $src
入口：       $HARNESS_BINDIR/{harness,harness-infi}
全局配置：    ${HARNESS_CONFIG_DIR:-$HOME/.config/harness}

${C_BOLD}下一步${C_RST}
  1. 重启 shell 或 source 你的 rc（让 PATH 生效）
  2. ${C_BLUE}harness doctor${C_RST}              # 真烧少量 API 自检各 backend
  3. 在某个 git 项目里：
       ${C_BLUE}cd ~/your-project${C_RST}
       ${C_BLUE}harness init${C_RST}              # 接管这个项目（生成 AGENTS.md / hooks）
       编辑 AGENTS.md 顶部的 gate 配置（test/lint/build 命令）
       ${C_BLUE}harness-infi${C_RST}              # 启动协调者 + 编排器
  4. 详细使用：${C_DIM}docs/getting-started.md${C_RST}

升级：       cd $src && git pull && uv sync
卸载：       $HARNESS_BINDIR/harness 在 PATH 上时：${C_BLUE}bash $src/install.sh --uninstall${C_RST}
EOF
}

# ── 升级主流程 ──────────────────────────────────────────
# 设计：尽量幂等、保守。git pull --ff-only 拒绝有本地未提交改动或分支偏离的
# 情况，避免静默丢工作。dep 检查 + 符号链接复用 install 同一套函数。
_resolve_existing_source() {
  # 与 _resolve_source 不同：升级时必须找到已存在的源码，绝不 clone。
  # 优先级：1) 脚本所在目录（如果是 git 仓库）2) $HARNESS_HOME
  local script_path="${BASH_SOURCE[0]:-}"
  if [[ -n "$script_path" && -f "$script_path" ]]; then
    local script_dir; script_dir=$(cd "$(dirname "$script_path")" && pwd)
    if [[ -d "$script_dir/.git" && -f "$script_dir/bin/harness-infi" ]]; then
      echo "$script_dir"; return 0
    fi
  fi
  if [[ -d "$HARNESS_HOME/.git" && -f "$HARNESS_HOME/bin/harness-infi" ]]; then
    echo "$HARNESS_HOME"; return 0
  fi
  fail "找不到 harness-donk 源码（既不在脚本旁也不在 $HARNESS_HOME）"
  fail "如果你装到了别的位置，传 --prefix DIR"
  exit 1
}

do_upgrade() {
  step "升级 harness-donk"

  info "1/5  定位源码"
  local src; src=$(_resolve_existing_source)
  ok "源码：$src"

  info "2/5  git fetch + 检查本地状态"
  ( cd "$src" && git fetch --quiet ) || { fail "git fetch 失败"; exit 1; }
  # 本地未提交改动 → 拒绝（防止 git pull 出冲突静默丢工作）
  if ! ( cd "$src" && git diff --quiet HEAD ); then
    fail "$src 有未提交改动，先 commit/stash 或 reset 再升级"
    ( cd "$src" && git status --short | sed 's/^/    /' >&2 )
    exit 1
  fi
  local local_head remote_head
  local_head=$( cd "$src" && git rev-parse HEAD )
  remote_head=$( cd "$src" && git rev-parse '@{u}' 2>/dev/null ) || {
    fail "$src 当前分支没有 upstream，无法升级"
    exit 1
  }
  if [[ "$local_head" == "$remote_head" ]]; then
    ok "已是最新（${local_head:0:8}）"
    info "如果只想强制重做 symlink + uv sync，继续走完后续步骤"
  else
    local n_ahead; n_ahead=$( cd "$src" && git rev-list --count "$remote_head".."$local_head" )
    if [[ "$n_ahead" -gt 0 ]]; then
      fail "$src 比 upstream 多 $n_ahead 个本地 commit；先 push 或 reset 再升级"
      exit 1
    fi
    local n_behind; n_behind=$( cd "$src" && git rev-list --count "$local_head".."$remote_head" )
    info "落后 upstream $n_behind 个 commit，将 fast-forward"
  fi

  info "3/5  git pull --ff-only"
  ( cd "$src" && git pull --ff-only ) || { fail "git pull 失败"; exit 1; }
  local new_head; new_head=$( cd "$src" && git rev-parse HEAD )
  if [[ "$new_head" != "$local_head" ]]; then
    ok "升级到 ${new_head:0:8}（含变更如下）"
    ( cd "$src" && git log --oneline "$local_head".."$new_head" | sed 's/^/    /' )
  fi

  info "4/5  uv sync（同步 Python 依赖）"
  ( cd "$src" && uv sync ) || { fail "uv sync 失败"; exit 1; }
  ok "Python 环境已同步"

  info "5/5  幂等重做入口符号链接 + harness setup"
  _link_entries "$src" "$HARNESS_BINDIR"
  "$src/bin/harness" setup >/dev/null 2>&1 || warn "harness setup 有 warning，可单独再跑"
  ok "升级完成"

  if [[ "$new_head" == "$local_head" ]]; then
    info "提示：本次只刷新了 symlink + .venv，源码没变。"
  fi
}

# ── 卸载主流程 ──────────────────────────────────────────
do_uninstall() {
  step "卸载 harness"

  info "1) 删入口符号链接"
  for entry in harness harness-infi; do
    local link="$HARNESS_BINDIR/$entry"
    if [[ -L "$link" ]]; then
      rm -f "$link" && ok "删 $link"
    else
      info "$link 不存在或不是符号链接，跳过"
    fi
  done

  info "2) 清理 shell rc 中的 PATH 行"
  local rc; rc=$(_detect_shell_rc)
  local marker="# added by harness installer"
  if [[ -f "$rc" ]] && grep -qF "$marker" "$rc"; then
    if confirm "从 $rc 删 harness PATH 行"; then
      # 删 marker 那行 + 紧跟的一行（PATH export）
      local tmp; tmp=$(mktemp)
      awk -v m="$marker" '
        $0 == m { skip = 2; next }
        skip > 0 { skip--; next }
        { print }
      ' "$rc" > "$tmp" && mv "$tmp" "$rc"
      ok "$rc 已清理"
    fi
  else
    info "$rc 没有 harness PATH 行，跳过"
  fi

  info "3) 源码目录"
  if [[ -d "$HARNESS_HOME" ]]; then
    if confirm "${C_RED}删除${C_RST} ${HARNESS_HOME}（含 .venv，源码若有改动会丢）"; then
      rm -rf "$HARNESS_HOME"
      ok "已删 $HARNESS_HOME"
    else
      info "保留 $HARNESS_HOME"
    fi
  fi

  info "4) 全局配置 ~/.config/harness/"
  local conf="${HARNESS_CONFIG_DIR:-$HOME/.config/harness}"
  if [[ -d "$conf" ]]; then
    if confirm "${C_RED}删除${C_RST} ${conf}（含日预算、项目登记表）"; then
      rm -rf "$conf"
      ok "已删 $conf"
    else
      info "保留 $conf"
    fi
  fi

  warn "项目里的 .harness/ 和 AGENTS.md 不会自动删 — 每个项目自己手动清理"
  ok "卸载完成"
}

# ── 入口分发 ─────────────────────────────────────────────
case "$MODE" in
  install)   do_install ;;
  upgrade)   do_upgrade ;;
  uninstall) do_uninstall ;;
esac
