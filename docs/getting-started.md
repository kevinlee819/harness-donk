<p align="center">
  <img src="donk.png" alt="harness — a pixel-art donkey wearing a harness" width="140">
</p>

# 🫏 开始使用 harness

本指南面向第一次接触这类工具的人。读完应能：知道 harness 由谁组成、各角色之间怎么交互、自己怎么切入、装好工具、接管项目、派出第一个真任务。

如果你想了解**为什么这么设计**（哲学层面），看 [design.md](design.md)。

---

## 0. 30 秒的具体场景

假设你说：

> "在 `src/utils/` 加一个 `slugify(input: string)` 函数，把字符串转 URL slug，要单测覆盖空字符串/中文/连续空格三种情况。"

接下来发生的事，**你完全不用动手**：

1. harness 自动给这个任务建一个独立的 git 分支和工作目录（叫 worktree，你的主分支完全不受影响）。
2. 让 Claude（或 Codex，看你配的）在那个工作目录里读你的需求 → 写代码 → 写测试 → `git commit`。
3. 跑你预先配好的检查命令：`tsc` 通了吗？`pnpm lint` 通了吗？`pnpm test` 通了吗？再让另一个 LLM 读 diff 挑刺。
4. 全过 → 自动合并到主分支。
5. 哪步过不了 → 把报错塞回去让模型自己改，最多重试 3 次。
6. 实在过不了 → 系统通知"任务 X 失败，原因 Y"，你决定下一步。

整个过程你可以去喝咖啡。等通知响才回来。

适合：本地代码迭代、夜间无人值守跑测试驱动开发、跨模型互审。
不适合：跨机器分布式、多人协作的中央调度。

---

## 1. 这套系统由谁组成

harness 不是一个 AI，是**一个把多个 AI 串起来用、并加上确定性安全网的程序**。下面这些角色你心里有数，后面所有命令的含义都自动通了。

### 1.1 用户（你）

你只跟**一个对话面**说话——下面要介绍的"协调者"。永远不直接打开 Claude 或 Codex 的客户端来写代码。原则上你不需要知道下面的细节，但理解了交互会顺畅得多。

### 1.2 协调者（coordinator）

**它是什么**：一个交互式的 Claude Code 会话，启动时被注入了一份特殊的"上岗手册"（[coordinator/coordinator.md](../coordinator/coordinator.md)），让它表现得像一个**项目经理**而不是程序员。

**它做什么**：
- 接你的需求、跟你来回澄清直到你给出可验收的标准。
- 把大需求拆成小任务，写成规范（spec），塞进任务队列。
- 任务跑完/卡住/失败时找你汇报。

**它不做什么**：
- ❌ 不写代码（写代码归"执行 agent"）。
- ❌ 不自己 attach 别的 tmux 窗口去敲键盘驱动其他 AI。
- ❌ 不在主分支上动手。

如果协调者表现出想自己写代码——说明它走偏了，coordinator.md 里写明了"你不是 worker"。

### 1.3 编排器（orchestrator）

**它是什么**：一个 Python 程序，**完全没有 AI**。就是一个 dumb loop（笨笨的死循环）：每 5 秒检查一次任务队列。

**它做什么**：
- 从 SQLite 队列里取一个 `queued` 状态的任务。
- 用 git 命令建一个 worktree（独立分支 + 独立目录）给这个任务。
- 通过 adapter 调用真正写代码的 AI（见 §1.4）。
- 跑校验门（见 §1.6）。
- 过了就合并主分支，没过就让 AI 重写。

它的"智能"是 0。所有的判断都在协调者那边（要不要做这件事？做完了吗？）和校验门那边（机器可验证的、是否通过测试？）。这是 harness 最关键的设计：**聪明的部分（LLM）和确定性的部分（流程编排）完全分离**。

### 1.4 执行 agent / worker

**它是什么**：真正写代码的那个 AI。Claude 或 Codex 都行。

**怎么调用**：编排器以**子进程**方式启动它（命令行 `claude -p` 或 `codex exec`），把任务规范作为提示词喂进 stdin，等它写完，读它的输出。每次调用是一个独立的短命进程，**不是常驻服务**。

**每次只在自己的 worktree 里活动**：你的主代码完全不受影响。worker 在它分到的 worktree 里看到的是你主分支的一份"独立副本"，它在那里改完、commit，然后退出。它**没有权限**直接 `git push` 主分支（hooks 会拦下）。

可以并行：默认 4 个 worker 同时跑，互不干扰。

### 1.5 Adapter（接头转换器）

**它是什么**：一层薄薄的 bash 脚本（[adapters/claude.sh](../adapters/claude.sh) / [adapters/codex.sh](../adapters/codex.sh)）。

**它做什么**：Claude 和 Codex 的命令行格式不同（参数名、JSON 输出格式都不一样），adapter 把不同 backend 翻译成同一种调用契约，让编排器代码不用关心每个 backend 的脾气。

**你日常不直接碰它**。但接入第三个 backend（比如 OpenCode、DeepSeek）时，就是写一个新 adapter（见 [adapter-contract.md](adapter-contract.md)）。

### 1.6 校验门（gate）

**它是什么**：[lib/gate.sh](../lib/gate.sh)，一个按你的配置依次跑命令的脚本。

**它做什么**：在合并主分支前，**强制**跑你配的检查：
1. 构建/类型检查（`tsc --noEmit` / `mypy` / `cargo check` 等）
2. Lint
3. 测试
4. diff 静态审计（worker 是否动了不该动的目录）
5. 跨模型审查（**让另一个 LLM 读 diff 挑刺**——claude 写就让 codex 审，反之亦然）

任何一步不过，gate 返回失败 → 编排器把报错信息塞回提示词，让 worker 重写。失败 3 次 → 任务标记 FAILED，通知你。

**这是 harness 的信任根**。配得严，自动化才有意义；配得松（gate 空着），整个系统就是个糊弄机。

### 1.7 角色关系图

```
                  ┌──────────────────┐
                  │     用户（你）    │
                  └────────┬─────────┘
                           │ 自然语言
                           ▼
                  ┌──────────────────┐
                  │     协调者        │  ← 一个 Claude Code 会话
                  │  （像项目经理）    │     加载 coordinator.md 当 system prompt
                  └────────┬─────────┘
                           │ harness-task add → SQLite 队列
                           ▼
                  ┌──────────────────┐
                  │     编排器        │  ← Python dumb loop，无 AI
                  │  (orchestrator)  │     每 5s 取任务、起 worktree、跑 gate
                  └────────┬─────────┘
                           │ 调用 adapter
                           ▼
              ┌──────────────────────────┐
              │   adapter (claude/codex) │  ← bash 翻译层
              └────────────┬─────────────┘
                           │ 子进程 claude -p / codex exec
                           ▼
              ┌──────────────────────────┐
              │  执行 agent / worker     │  ← Claude / Codex
              │  在独立 worktree 写代码   │     git commit 后退出
              └────────────┬─────────────┘
                           │ 完事退出
                           ▼
                  ┌──────────────────┐
                  │   gate.sh        │  ← 跑你配的命令
                  │  (build/lint/    │     全过才能合并
                  │   test/review)   │
                  └──────────────────┘
```

---

## 2. `harness` 与 `harness-infi` —— 两个命令的分工

仓库装好后你 PATH 里会有两个二进制：

| 命令 | 是什么 | 何时用 |
|------|--------|--------|
| **`harness-infi`** | 唯一入口 / 启动协调者会话 | **99% 的日常使用都是它** |
| `harness` | 一组管理与观测子命令 | 接管项目、查状态、自检、排障时用 |

类比：`harness-infi` 像启动一艘船的引擎；`harness` 是船上的小工具箱。

### `harness-infi` 做什么

跑 `harness-infi`（在已 `harness init` 过的项目目录里）：

1. 在 tmux 里建一个名叫 `harness-<项目 hash>` 的会话，有两个窗口：
   - **window 0 — coordinator**：一个交互式 Claude Code 会话，加载好 coordinator.md（你跟它对话的地方）。
   - **window 1 — orchestrator**：后台编排器 daemon，每 5 秒轮询队列、调度 worker。
2. 把你 attach 到 window 0。

之后你的全部交互就是跟 window 0 的协调者对话。`Ctrl-B 1` 看后台编排器在干嘛、`Ctrl-B 0` 回来、`Ctrl-B d` detach（两个窗口都继续在后台跑）。

`-infi` 是 "infinite" 的缩写——它启动一个**长跑会话**而非一次性命令。

### `harness` 做什么

每个子命令各管一件事，都是**辅助性**的：

```bash
harness init [--backend codex]     # 接管当前项目（每个新项目跑一次，且仅一次）
harness setup                      # 一次性环境自检 + 建全局配置目录
harness doctor                     # 检查各 backend CLI 能不能用（会真烧少量 API）
harness status                     # 看所有任务的当前状态
harness attach <wid>               # 看某个 worker 当前在干嘛的快照
harness events pending             # 看待处理的通知事件
harness backup                     # 备份 SQLite 数据库
harness run-once [--mock]          # 跑一轮编排器后退出（手动调试用）
harness help                       # 帮助
```

**重要：`harness` 本身不启动协调者**。如果你想跟协调者对话，要 `harness-infi`。

---

## 3. 先决条件

**操作系统**：macOS / Linux（暂未在 Windows 测过；WSL 应该能跑）。

**必装命令**（`install.sh` 会校验，缺则报错告诉你装哪个）：

| 命令 | 最低版本 | 作用 |
|------|---------|------|
| `git` | 任意常见版本 | worktree 管理、commit |
| `sqlite3` | **≥ 3.35** | 任务队列存储；需要 `RETURNING` 子句 |
| `jq` | 任意 | JSON 处理 |
| `tmux` | 任意 | 协调者会话承载 |
| `python3` | ≥ 3.9 | 跑 `src/harness/` Python 层 |

`uv`（Python 环境管理）**不在必装清单里** —— installer 会检测，若缺会问你要不要自动用官方脚本装上（`curl -LsSf https://astral.sh/uv/install.sh | sh`）。

**可选**：

- `terminal-notifier`（macOS only）—— 让通知中心显示 🫏 donk logo 而不是默认的灰色插头图标，并把同一任务的连续通知合并而非堆积。装：`brew install terminal-notifier`。

**至少一个 backend CLI**（任选其一上手，后续可加）：

- Claude Code：装好并 `claude /login` 完成认证（订阅 / API key 都行）。
- Codex CLI：装好并 `codex login` 完成认证。

> ⚠️ **数据库必须在本地文件系统** —— 不要把项目放在 NFS / 网络盘 / 同步盘的远程挂载上。SQLite WAL 模式在网络文件系统上不可靠（[CLAUDE.md §4.3](../CLAUDE.md)）。

---

## 4. 安装

两种方式，二选一。

### 4.1 脚本一键安装

```bash
curl -LsSf https://raw.githubusercontent.com/kevinlee819/harness-donk/main/install.sh | bash
```

或带交互（让你过目每一步确认）：

```bash
curl -LsSf https://raw.githubusercontent.com/kevinlee819/harness-donk/main/install.sh -o /tmp/install.sh
bash /tmp/install.sh
```

### 4.2 已 clone 的情况

```bash
git clone https://github.com/kevinlee819/harness-donk.git
cd harness-donk
./install.sh
```

### 4.3 installer 做了什么

1. **检查系统依赖**：`git` / `sqlite3 ≥ 3.35` / `jq` / `tmux` / `python3 ≥ 3.9` 缺一就报错告诉你装哪个。
2. **检查 uv**：缺则问要不要用官方脚本自动装。
3. **定位源码**：本地模式 → 用你 clone 的目录；一行装模式 → 自动 `git clone` 到 `$HOME/.harness/`。
4. **`uv sync`**：在源码目录里装 Python 依赖到 `.venv/`。
5. **入口符号链接**：把 `harness` 和 `harness-infi` 软链到 `$HOME/.local/bin/`（uv 自己也装在这；如果该目录不在 PATH，installer 会问要不要写进 shell rc）。
6. **`harness setup`**：建 `~/.config/harness/` 写默认全局配置。

### 4.4 installer 选项

```bash
./install.sh --help              # 看所有选项
./install.sh -y                  # 跳过所有确认（CI / 一行装常用）
./install.sh --prefix /opt/harness   # 改源码安装目录（默 $HOME/.harness）
./install.sh --bindir /usr/local/bin # 改入口符号链接目录（默 $HOME/.local/bin）
./install.sh --uninstall         # 反向操作：删符号链接 + shell rc 行 +（可选）源码目录
```

### 4.5 升级

```bash
harness upgrade
```

等价于 `bash $HOME/.harness/install.sh --upgrade`。会按序：

1. **校验源码状态**：有未提交改动 / 本地多于 upstream → 拒绝升级（防止静默丢工作）。
2. **`git pull --ff-only`**：只接受 fast-forward。合并冲突的可能性 = 0。
3. 打印这次拉到的所有 commit 信息（一眼看到改了啥）。
4. **`uv sync`**：装新依赖、清不需要的；Python 环境跟仓库一致。
5. **重做符号链接**（幂等）+ 跑一次 `harness setup`（也是幂等的）。

**关于正在跑的任务**：升级过程不会动 `.harness/harness.db` 或 worker 的 worktree。已在跑的 worker 继续用旧代码完成本轮；新任务（升级后第一次 claim）开始使用新代码。**保险起见，升级前先停掉 `harness-infi` 会话**：

```bash
tmux kill-session -t harness-<sha8>     # 或在协调者 window 里 :exit
harness upgrade
harness-infi                            # 重启
```

### 4.6 卸载

```bash
bash $HOME/.harness/install.sh --uninstall
```

会按序询问（不带 `--yes` 时每步都确认）：

1. 删 `$HOME/.local/bin/{harness,harness-infi}` 符号链接。
2. 删 shell rc 里 `# added by harness installer` 标记行。
3. 询问是否删 `$HOME/.harness/` 源码目录（含 `.venv/`）。
4. 询问是否删 `~/.config/harness/`（含日预算配置、项目登记表）。

**不会自动删的**：每个项目里的 `.harness/` 和 `AGENTS.md`。这些是项目数据，要不要保留只有你知道。手动 `rm -rf <project>/.harness <project>/AGENTS.md` 来彻底清理某个项目。

### 4.7 目录心智模型（同 git）

- `$HOME/.harness/` 是工具本体，装一份，**永远不复制进任何项目**。
- 入口 `harness` / `harness-infi` 在 `$HOME/.local/bin/`（uv 也装在这；大多数现代系统已经在 PATH 上）。
- 项目里只出现声明式的 `AGENTS.md` / `.claude/settings.json` / `specs/`（进 git）+ 运行时状态 `.harness/`（整体 gitignore）。
- 升级 harness = `harness upgrade`，所有接管的项目即刻享受新版本。

---

## 5. 第一次配置（每台机一次）

### 5.1 环境自检

```bash
harness setup
```

会做两件事：
1. 校验 sqlite3 / jq / git / tmux / python 都装了且版本够。
2. 创建 `~/.config/harness/` 并写默认配置：

```ini
# ~/.config/harness/config
budget_daily_usd=10          # 日预算 USD，超限停止新派
session_resume_cap=6         # 同一对话续接上限；到顶开新会话防上下文走形
dead_worker_threshold_min=10 # transient 状态超时即判死 worker，自动重派
blocked_timeout_hours=72     # BLOCKED 任务卡过此时间 → 标 FAILED
```

默认值是个人级 happy path 用的。等真长跑后再校。

### 5.2 backend 自检

```bash
harness doctor
```

会对每个找到的 backend CLI 做一次真 echo 调用——**会真烧 API 钱，几分钱以内**。看到所有 backend 都 `✓ responded` 才能继续。至少一个 ✓ 就能用。

---

## 6. 接管你的第一个项目

```bash
cd ~/code/my-project          # 必须是已 git init 的目录
harness init                  # 默认 backend=claude，reviewer=codex
# 或：
harness init --backend codex  # writer=codex 时自动反转 reviewer=claude
```

`init` 干了什么（这一步只对每个新项目执行一次）：

1. 在项目根建 `.harness/`（含队列、worker 状态、事件、日志等），整体加进 `.gitignore`。
2. 生成项目根 `AGENTS.md`（**你接下来要编辑这个文件**），并设好 reviewer。
3. 软链 `CLAUDE.md → AGENTS.md`（让 Claude 也读这份）。
4. 把安全 hooks 装到 `.claude/settings.json`。如果项目已有这个文件，会写一份 `.harness-suggested` 让你手动合并。
5. 把项目绝对路径登记到 `~/.config/harness/projects.list`（幂等）。

### 6.1 配置校验门（gate）—— 你必须做这一步

`init` 生成的 `AGENTS.md` 顶部有一段 YAML frontmatter：

```yaml
---
gate:
  build: ""                       # 构建/类型检查命令
  lint: ""                        # 静态检查命令
  test: ""                        # 测试命令
  diff_audit_paths_allowlist: []  # 白名单：worker 只能改这些路径下的文件
  cross_review: true              # 是否跑跨模型审查
  cross_review_reviewer: codex    # 审查者 backend（写者反面）
---
```

**校验门是 harness 的信任根。这些命令配得越严，自动化越值得信任。空着 = 没门 = 系统等于让 worker 自己宣告完成，违背设计原则。**

每个字段的含义：

| 字段 | 含义 | 何时跳过 |
|------|------|----------|
| `build` | 构建或静态类型检查。任何"代码语法/类型/编译"层面的检查 | 项目没构建步骤可以留空，但**强烈建议至少有类型检查** |
| `lint` | 风格 / 静态分析 | 项目没 linter 可以留空 |
| `test` | **必填**。自动化测试套件 | 留空 = 没门，强烈反对 |
| `diff_audit_paths_allowlist` | 允许 worker 触碰的路径 glob 列表。空列表 = 不限制 | 想严格控制 worker scope 时填 |
| `cross_review` | true 时跑跨模型审查（让另一个 LLM 读 diff 挑刺） | false 关掉（省钱，但失去一道防线） |
| `cross_review_reviewer` | 审查者 backend：`claude` 或 `codex` | init 自动按写者反转：claude 写 → codex 审 |

### 6.2 不同语言的起步配置样例

**Node / TypeScript**：
```yaml
gate:
  build: "tsc --noEmit"
  lint:  "pnpm lint"               # 或 npm run lint / eslint .
  test:  "pnpm test"
  cross_review: true
  cross_review_reviewer: codex
```

**Python**：
```yaml
gate:
  build: "mypy ."                  # 或 pyright
  lint:  "ruff check ."            # 或 flake8 / pylint
  test:  "pytest -q"
  cross_review: true
  cross_review_reviewer: codex
```

**Rust**：
```yaml
gate:
  build: "cargo check --all-targets"
  lint:  "cargo clippy -- -D warnings"
  test:  "cargo test"
  cross_review: true
  cross_review_reviewer: codex
```

**Go**：
```yaml
gate:
  build: "go vet ./..."
  lint:  "golangci-lint run"       # 装一下；要求 go ≥ 1.20
  test:  "go test ./..."
  cross_review: true
  cross_review_reviewer: codex
```

**bash / 脚本仓库**（比如 harness 自己）：
```yaml
gate:
  build: ""                        # 没构建
  lint:  "shellcheck $(find . -name '*.sh' -not -path './.venv/*')"
  test:  "bash tests/run.sh"
  cross_review: true
  cross_review_reviewer: codex
```

### 6.3 手动验证 gate 命令在干净分支能跑通

**最重要的检查，跳过了后面会反复掉坑**：

```bash
# 在项目根，确保你在干净的主分支
git status                       # 应该是 clean

# 把你配的所有 gate 命令依次跑一遍
tsc --noEmit && pnpm lint && pnpm test      # 用你实际填的命令

# 三个全部退出码 0 才算通
echo "exit code: $?"             # 应该是 0
```

**只有干净主分支上 gate 命令全过 0**，harness 才能用它们当裁判。如果主分支自己都过不了 lint/test，那 worker 改完更过不了，会一直 FAILED。

---

## 7. 第一次起飞

```bash
harness-infi
```

会发生什么：
- tmux 起一个会话，光标停在 window 0（coordinator）。
- window 0 是一个 Claude Code 会话，已经加载 coordinator.md 当 system prompt。
- window 1 是后台 orchestrator daemon。`Ctrl-B 1` 切过去能看到它在 `queue empty` 轮询。

跟协调者说话试试（在 window 0）：

```
你：帮我在 src/utils/ 加一个 slugify 函数，输入字符串输出 URL slug。
   要单测覆盖：空字符串 → ""；中文 → 拼音或丢掉；连续空格 → 单个 -。
```

它会问你确认 spec、问要不要并发依赖、检查你的 AGENTS.md gate 配置；满意之后调 `harness-task add` 入队。

**入队后你可以**：
- 在 tmux 里继续看着（`Ctrl-B 1` 切到 window 1 看 orchestrator 把活分给 worker）。
- detach（`Ctrl-B d`）去干别的，所有东西继续在后台跑。
- 等通知响（任务完成 / 失败 / 需决策）。

`Ctrl-B 0` 回到协调者；它会主动报告任务状态变化。

---

## 8. 日常使用：三种"档位"

三档共享同一个协调者会话和同一份 `.harness/` 账本。

### 8.1 对话档（探索 + 拆解）

用法：直接和协调者聊。"我想做 X，但 Y 和 Z 我没想清楚"——协调者会问到能写下机器可校验的验收清单为止。

```
你：登录功能怎么搞？
协调者：先问几个问题确定方案……（来回 3-5 轮）
协调者：那我把它拆成 3 个任务：T-jwt（中间件）、T-login（接口）、T-session（cookie/csrf）。
        T-login 依赖 T-jwt。要我入队吗？
你：入队，T-jwt 先跑。
```

### 8.2 委派档（入队 + 后台跑）

协调者拆好后调 `harness-task add`。你不用碰这个命令——但知道它存在有助于理解为什么协调者不能自己跑代码。

```bash
harness-task add [--id T-XXX] [--priority N] [--depends-on T-A,T-B]
                 [--spec specs/foo.md] [--backend codex]
                 # body 走 stdin，写到 specs/<id>.md
```

入队后你可以关电脑去吃饭。orchestrator 在后台轮询，到点就跑。

### 8.3 观测档（什么情况）

任何时候你问"做得怎么样了"，协调者会查 `harness status` 给你简报。**也可以你自己看**（不在协调者 tmux 里也行）：

```bash
# 在项目根
harness status                         # 全部任务摘要 + 待处理事件
harness status --task T-jwt            # 单任务详情
harness status --task T-jwt --history  # 含状态迁移史

# 现场快照（worker 是线程，不是独立 pane）
harness attach w1                      # 看 w1 当前在干什么
harness attach w1 --path               # 只打印 worktree 路径
cd $(harness attach w1 --path)         # 直接进现场
git -C $(harness attach w1 --path) log --oneline   # 看 worker 提交了啥

# 待处理事件（协调者也会每轮主动 pull）
harness events pending
harness events ack <eid>...
```

### 8.4 三档之间的衔接

- 对话 → 委派：协调者直接调 `harness-task add`，不用你重打提示词。
- 委派 → 观测：你随时可问，也可彻底不问让它自己跑完通知你。
- 观测 → 对话：发现任务 `FAILED`，协调者带着 `.gate-report.json` 找你商量"重派 / 改 spec / 放弃"。

---

## 9. 命令速查表

### harness-infi（用户唯一入口）

```bash
harness-infi                          # 启动协调者 + 后台 orchestrator
harness-infi --backend codex          # 用 codex 当主力 writer（reviewer 自动反转）
harness-infi --model claude-sonnet-4-6   # 透传 model 给 adapter
harness-infi --no-attach              # 创建会话但不 attach（脚本/CI 用）
```

### harness（管理/观测）

```bash
harness init [--backend NAME]    # 在当前 git repo 接管
harness setup                    # 环境自检 + 建 ~/.config/harness/
harness doctor                   # 对各 backend echo 自检（真烧 API）
harness status [--task T-XXX [--history]]
harness events {pending|ack <eid>...}
harness attach                   # attach 到协调者 tmux 会话
harness attach <wid> [--path]    # worker 现场快照（或仅 worktree 路径）
harness backup                   # sqlite3 .backup → .harness/backups/
harness run-once [--mock]        # 跑一轮编排器后退出（手动调试用）
harness help
```

### 协调者用的工具

```bash
harness-task add [--id T-XXX] [--priority N] [--depends-on T-A,T-B]
                 [--spec specs/foo.md] [--backend codex]
harness-task query [--status QUEUED|WORKING|...|FAILED] [--task T-XXX] [--json]
harness-task history <task_id>
harness-task cancel  <task_id>
harness-task answer  <task_id> <text>   # 答复 BLOCKED 任务
```

---

## 10. 配置文件分层

### 全局（每台机一份）

`~/.config/harness/config`：

```ini
budget_daily_usd=10           # 日预算 USD；累计超即停派新任务
session_resume_cap=6          # 同会话 resume 上限；到顶强制开新 session
dead_worker_threshold_min=10  # transient 状态 + updated 老于此值 → 判死重派
blocked_timeout_hours=72      # BLOCKED 卡过此时长 → FAILED + 通知协调者
```

`~/.config/harness/projects.list`：每行一个项目绝对路径，`harness init` 自动追加（幂等）。未来跨项目预算聚合用。

### 项目级（每个项目一份，进 git）

`AGENTS.md` 顶部 frontmatter 是 gate 配置——这是你**主要要调的地方**（见 §6.1）。每次任务的 spec 可在 frontmatter 用 `reviewer:` / `cross_review:` 字段覆盖项目级 gate 配置（[interfaces.md §5](interfaces.md)）。

`.claude/settings.json` 装 hooks（PreToolUse 安全门 + Notification 路由），**不要随便改**——尤其不要禁掉 PreToolUse，那是 harness 的安全底线。

### 运行时（每个项目一份，gitignore）

`.harness/`：

| 路径 | 是什么 | 谁写 |
|------|--------|------|
| `harness.db` | SQLite 状态库（队列 / 状态机 / 调用账） | 编排器独占 |
| `workers/<id>/status.json` | worker 当前状态 | 该 worker |
| `workers/<id>/guidance.json` | worker 需决策时写 | 该 worker |
| `inbox/<id>.answer` | 你 / 协调者给 BLOCKED 任务的答复 | 人 / 协调者 |
| `events/*.json` | 待处理事件 | 编排器 |
| `logs/raw/*.json` | 每次调用的原始 JSON（排障用） | adapter |
| `backups/` | 数据库定期备份 | `harness backup` |

---

## 11. 排障 FAQ

### Q: `harness setup` 报 sqlite3 < 3.35

系统自带的 sqlite3 可能太老。装新的：
- macOS: `brew install sqlite` 然后把 `/opt/homebrew/opt/sqlite/bin` 放到 PATH 前面。
- Linux: 用你发行版的 sqlite3 ≥ 3.35 包；或从源码装。

### Q: `harness-infi` 起来后 window 1 立刻就 `[exited]`

orchestrator 启动失败。`Ctrl-B 1` 切过去看错信息（`remain-on-exit` 选项让 pane 保留以便排障）；最常见的是项目没 `harness init` 过，或者 `.harness/harness.db` 损坏。

`harness backup` 跑过的话可以从 `.harness/backups/` 恢复。

### Q: 任务卡在 `dispatched` 或 `working` 不动

worker 可能崩了（进程死了但状态没回卷）。orphan reaper 默认 10 分钟会扫一次，自动转回 `queued` 重派。等等再看。

想立刻强行处理：
```bash
sqlite3 .harness/harness.db "UPDATE tasks SET updated='2020-01-01T00:00:00Z' WHERE id='T-XXX'"
```
下一轮 reap 就会接手（**只在你确定 worker 真死了才这么干**）。

### Q: gate 一直过不去

```bash
cat .worktrees/<project>/<task_id>/.gate-report.json | jq .
```
看哪一步 `ok=false` 以及它的 `output`。常见原因：
- gate 命令本身在干净分支上就跑不通 → 改 AGENTS.md 的 gate 配置（参见 §6.3）。
- 测试不稳定 → 修测试。
- 跨模型审查 reject → 看 `output` 里的 issues 列表。

### Q: 跨模型审查总是 reject

reviewer 默认是 writer 的反面（claude ↔ codex），适合大多数情况。如果某个任务的 issue 实际无伤大雅，可在 spec frontmatter 关掉：

```markdown
---
reviewer: codex
cross_review: false   # 单 spec 关掉跨审
---
```

或者改 reviewer：

```markdown
---
reviewer: claude     # 强制 claude 当裁判，即使全局是 codex
---
```

### Q: 我想看协调者到底说了啥

`tmux attach -t harness-<sha8(pwd)>` 直接进会话（`harness attach` 也行），所有对话都在 window 0 的滚动历史里。

### Q: 怎么停

- 单个任务：让协调者 `harness-task cancel <task_id>`。
- 整个会话：`Ctrl-B d` 只 detach（后台 orchestrator 继续跑）；要真停：`tmux kill-session -t harness-<sha8>`。
- 完全卸载某个项目：删项目根的 `.harness/` 和 `AGENTS.md`，从 `~/.config/harness/projects.list` 删那一行。代码留着，可重新 `harness init` 一次。

### Q: 钱在哪里看

```bash
sqlite3 .harness/harness.db "SELECT date(ts), SUM(cost_usd) FROM calls GROUP BY date(ts) ORDER BY 1 DESC LIMIT 7"
```

或者跑日预算检查：`harness status` 顶部会显示今日累计。注意 codex 的 `cost_usd` 当前是 NULL（CLI 没暴露 USD 字段，只有 token usage）。

### Q: 通知图标是个灰色插头不是驴

macOS `osascript` 的已知限制（没 app bundle）。装 `terminal-notifier` 就会变成 donk logo：
```bash
brew install terminal-notifier
```
装完不用重启 harness，下次通知自动用上。

---

## 12. 下一步

- 想了解架构 / 为什么这么设计 → [design.md](design.md)
- 想接入新 backend CLI（DeepSeek、OpenCode 等）→ [adapter-contract.md](adapter-contract.md)
- 想改 JSON / SQL schema → [data-schemas.md](data-schemas.md)
- 想在仓库里开发 → 仓库根 [CLAUDE.md](../CLAUDE.md) + [development-plan.md](development-plan.md)

---

## 13. 一份"最低可用配置"清单

发布前自我体检——一个项目要算"真的能用 harness"，下面这些应该都满足：

- [ ] `harness setup` 全 ✓
- [ ] `harness doctor` 至少一个 backend ✓
- [ ] 项目根有 `AGENTS.md`，gate 块的 `test`（至少）和 `cross_review_reviewer` 都填了
- [ ] 在干净的主分支上手动跑过 gate 全部命令（build/lint/test），都返回 0
- [ ] `.claude/settings.json` 里 PreToolUse 注册了 `pre_tool_use.sh`
- [ ] `harness-infi` 启动后 window 0 是协调者，window 1 是 orchestrator daemon 在轮询（不是 `[exited]`）
- [ ] 让协调者派一个"加 hello.txt"级别的 trivial 任务，能跑到 MERGED

最后一条满足，你才真正接管了这个项目。
