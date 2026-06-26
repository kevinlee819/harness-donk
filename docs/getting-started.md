# 开始使用 harness

本指南面向第一次使用 harness 的人。读完应能：装好工具、接管一个项目、用协调者派出第一个真任务、看懂日常的对话/委派/观测三档怎么用。

如果你想了解**为什么这么设计**而非**怎么用**，看 [design.md](design.md)。

---

## 1. 这是什么（30 秒）

一套**单机、个人级**的编码自动化系统。你的唯一对话面是一个被武装成"协调者"的 Claude Code 会话；它把你说的需求拆成任务，丢进队列。后台一个 dumb-loop 编排器取任务、起 worktree、调真正干活的 agent（Claude / Codex），跑校验门，过了才合并主分支。失败自动回灌重跑，需要决策时主动找你。

**核心承诺**：
- 你**永远不裸跑 `claude`** —— 上下文归 harness 所有，崩溃可恢复。
- worker 干完不算完 —— 必须过校验门（测试 + lint + 类型 + 跨模型审查）才合并。
- 危险操作（push 主分支、改 secret 路径等）由 hooks 在工具关口拦截，**不是**靠提示词约束。

适合：本地代码迭代、夜间无人值守跑测试驱动开发、跨模型互审。
不适合：跨机器分布式、多人协作的中央调度。

---

## 2. 先决条件

**操作系统**：macOS / Linux（暂未在 Windows 测过；WSL 应该能跑）。

**必装命令**（`harness setup` 会校验）：

| 命令 | 最低版本 | 作用 |
|------|---------|------|
| `git` | 任意常见版本 | worktree 管理、commit |
| `sqlite3` | **≥ 3.35** | 需要 `RETURNING` 子句 |
| `jq` | 任意 | JSON 处理 |
| `tmux` | 任意 | 协调者会话承载 |
| `python3` | ≥ 3.9 | 跑 src/harness/ Python 层 |
| `uv` | 任意新版 | Python 环境管理（[安装](https://github.com/astral-sh/uv)） |

**至少一个 backend CLI**（任选其一上手，后续可加）：

- Claude Code: 装好并 `claude /login` 完成认证
- Codex CLI: 装好并 `codex login` 完成认证

> ⚠️ **数据库必须在本地文件系统** —— 不要把项目放在 NFS / 网络盘 / 同步盘的远程挂载上。SQLite WAL 模式在网络文件系统上不可靠（[CLAUDE.md §4.3](../CLAUDE.md)）。

---

## 3. 安装

```bash
# 1. 克隆到工具目录（不要放进任何项目目录！）
git clone <repo-url> ~/tools/harness
cd ~/tools/harness

# 2. 同步 Python 环境（建 .venv/、装 console scripts）
uv sync

# 3. 把 bin/ 加入 PATH
echo 'export PATH="$HOME/tools/harness/bin:$PATH"' >> ~/.zshrc   # 或 .bashrc
exec $SHELL                                                       # 重启 shell

# 4. 验证
which harness         # → $HOME/tools/harness/bin/harness
which harness-infi    # → $HOME/tools/harness/bin/harness-infi
```

**目录心智模型**（同 git）：
- `~/tools/harness/` 是工具本体，安装一份，**永远不复制进任何项目**。
- 项目里只出现声明式的 `AGENTS.md` / `.claude/settings.json` / `specs/`（进 git）+ 运行时状态 `.harness/`（整体 gitignore）。
- 升级 harness = 在工具目录 `git pull`，所有接管的项目即刻生效。

---

## 4. 第一次配置

### 4.1 环境自检

```bash
harness setup
```

这会：
1. 校验 sqlite3 / jq / git / tmux / python 都装了且版本够。
2. 创建 `~/.config/harness/` 并写默认配置：

```ini
# ~/.config/harness/config
budget_daily_usd=10          # 日预算，超限停止新派
session_resume_cap=6         # 同 session resume 上限，到顶开新会话
dead_worker_threshold_min=10 # 超时未刷新即判死 worker 重派
blocked_timeout_hours=72     # BLOCKED 任务卡过此时间 → FAILED
```

3. 创建 `~/.config/harness/projects.list`（项目登记表）。

> 默认值是个人级 happy path 用的。等真长跑后再校（参见 [TODO.md](../TODO.md) 决策待办）。

### 4.2 backend 自检

```bash
harness doctor
```

这会对每个找到的 backend CLI 做一次真 echo 调用（**会烧少量 API 钱**，几分钱以内）。看到所有 backend 都 `✓ responded` 才能继续。

如果某个 backend 没装或没登录，doctor 会标 `✗` 并打印第一行错信息。**至少一个 ✓ 就能用**。

---

## 5. 接管你的第一个项目

```bash
cd ~/code/my-project          # 必须是已 git init 的目录
harness init                  # 默认 backend=claude，reviewer=codex
# 或：
harness init --backend codex  # writer=codex 时自动反转 reviewer=claude
```

`init` 做了什么：

1. 在项目根建 `.harness/`（含 `harness.db` / `workers/` / `inbox/` / `events/` / `logs/raw/`），整体加进 `.gitignore`。
2. 渲染 `templates/AGENTS.md.tmpl` → 项目根 `AGENTS.md`，并设好 `cross_review_reviewer`。
3. 软链 `CLAUDE.md → AGENTS.md`（claude 和我们都读这份）。
4. 把 hooks 安装到 `.claude/settings.json`（PreToolUse 安全门 + Notification 路由）。**如果项目已有 `.claude/settings.json`，会写一份 `.harness-suggested` 供你手动合并**。
5. 把项目绝对路径登记到 `~/.config/harness/projects.list`（幂等）。

### 5.1 填 gate 命令

`init` 生成的 `AGENTS.md` 顶部有一段 `gate` 块，**默认是空的**：

```yaml
gate:
  build: ""
  lint: ""
  test: ""
  cross_review: true
  cross_review_reviewer: codex   # 自动按 --backend 反转
```

**校验门是 harness 的核心信任根。空的 gate 等于没门。**

至少填一个 `test` 命令，越严越好。例子（按你项目实际填）：

```yaml
gate:
  build: "tsc --noEmit"
  lint:  "pnpm lint"
  test:  "pnpm test"
  cross_review: true
  cross_review_reviewer: codex
```

填好之后**手动跑一次确认能通**：

```bash
cd .   # 在项目根
tsc --noEmit && pnpm lint && pnpm test
```

只有这些命令在干净的工作区都返回 0，harness 才能用它们当裁判。

### 5.2 第一次运行

打开协调者：

```bash
harness-infi
```

这会在当前目录起一个 tmux 会话：
- **window 0 — `coordinator`**: 交互式 claude，已注入 coordinator.md 作 system prompt。
- **window 1 — `orchestrator`**: 后台 dumb loop，每 5s 轮询队列。

你的光标默认在 window 0。`Ctrl-B 1` 看后台、`Ctrl-B 0` 回来。`Ctrl-B d` detach（会话和 orchestrator 都继续在后台跑）。

跟协调者说话试试：

> "帮我在 src/utils/ 加一个简单的 slugify 函数，要带单测。"

协调者会问你确认 spec、然后调 `harness-task add` 入队 → orchestrator 接手 → worker 在 worktree 里写代码 → gate 验 → 合并主分支 → notification 通知协调者 → 协调者来找你验收。

整个流程**默认沉默**，只在三类时刻找你：
- **需决策**：worker 写了 `guidance.json {blocking:true}`
- **待验收**：任务 `MERGED`
- **故障**：任务 `FAILED`

---

## 6. 日常使用：三种"档位"

三档共享同一个协调者会话和同一份 `.harness/` 账本。

### 6.1 对话档（探索 + 拆解）

用法：直接和协调者聊。"我想做 X，但 Y 和 Z 我没想清楚"——协调者会问到能写下机器可校验的验收清单为止。

例子：

```
你：登录功能怎么搞？
协调者：先问几个问题确定方案……（来回 3-5 轮）
协调者：那我把它拆成 3 个任务：T-jwt（中间件）、T-login（接口）、T-session（cookie/csrf）。
        T-login 依赖 T-jwt。要我入队吗？
你：入队，T-jwt 先跑。
```

### 6.2 委派档（入队 + 后台跑）

协调者拆好后调 `harness-task add`。你不用碰这个命令——但知道它存在有助于理解为什么协调者不能自己跑代码。

```
harness-task add [--id T-XXX] [--priority N] [--depends-on T-A,T-B]
                 [--spec specs/foo.md] [--backend codex]
                 # body 走 stdin，写到 specs/<id>.md
```

入队后你可以关电脑去吃饭。orchestrator 在后台轮询，到点就跑。

### 6.3 观测档（什么情况）

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

### 6.4 三档之间的衔接

- 对话 → 委派：协调者直接调 `harness-task add`，不用你重打提示词。
- 委派 → 观测：你随时可问，也可彻底不问让它自己跑完通知你。
- 观测 → 对话：发现任务 `FAILED`，协调者带着 `.gate-report.json` 找你商量"重派 / 改 spec / 放弃"。

---

## 7. 命令速查表

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

### 协调者用的工具（你不直接调，但知道存在）

```bash
harness-task add [--id T-XXX] [--priority N] [--depends-on T-A,T-B]
                 [--spec specs/foo.md] [--backend codex]
harness-task query [--status QUEUED|WORKING|...|FAILED] [--task T-XXX] [--json]
harness-task history <task_id>
harness-task cancel  <task_id>
harness-task answer  <task_id> <text>   # 答复 BLOCKED 任务
```

---

## 8. 配置文件

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

`AGENTS.md` 顶部 frontmatter 是 gate 配置——这是你**主要要调的地方**。每次任务的 spec 可在 frontmatter 用 `reviewer:` / `cross_review:` 字段覆盖项目级 gate 配置（[interfaces.md §5](interfaces.md)）。

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

## 9. 排障 FAQ

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
- gate 命令本身在干净分支上就跑不通 → 改 AGENTS.md 的 gate 配置。
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

---

## 10. 下一步

- 想了解架构 / 为什么这么设计 → [design.md](design.md)
- 想接入新 backend CLI → [adapter-contract.md](adapter-contract.md)
- 想改 JSON / SQL schema → [data-schemas.md](data-schemas.md)
- 想在仓库里开发 → 仓库根 [CLAUDE.md](../CLAUDE.md) + [development-plan.md](development-plan.md)

---

## 11. 一份"最低可用配置"清单

发布前自我体检——一个项目要算"真的能用 harness"，下面这些应该都满足：

- [ ] `harness setup` 全 ✓
- [ ] `harness doctor` 至少一个 backend ✓
- [ ] 项目根有 `AGENTS.md`，gate 块的 `test`（至少）和 `cross_review_reviewer` 都填了
- [ ] 在干净的主分支上手动跑过 gate 全部命令（build/lint/test），都返回 0
- [ ] `.claude/settings.json` 里 PreToolUse 注册了 `pre_tool_use.sh`
- [ ] `harness-infi` 启动后 window 0 是协调者，window 1 是 orchestrator daemon 在轮询（不是 `[exited]`）
- [ ] 让协调者派一个"加 hello.txt"级别的 trivial 任务，能跑到 MERGED

最后一条满足，你才真正接管了这个项目。
