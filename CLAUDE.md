# CLAUDE.md

本项目是「多 Agent 自驱动编码 Harness」的实现仓库。本文件是 Claude 在本仓库开发时的速查；完整文档在 [docs/](docs/)。

| 想了解 | 看 |
|--------|----|
| 设计哲学与权衡（**冲突时以此为准**） | [docs/design.md](docs/design.md) |
| 阶段任务、验收标准、依赖顺序 | [docs/development-plan.md](docs/development-plan.md) |
| 模块清单、目录结构、写者归属 | [docs/module-architecture.md](docs/module-architecture.md) |
| 模块间契约（脚本/函数/文件触发） | [docs/interfaces.md](docs/interfaces.md) |
| JSON 黑板 schema + SQLite DDL | [docs/data-schemas.md](docs/data-schemas.md) |
| 接入新 backend CLI | [docs/adapter-contract.md](docs/adapter-contract.md) |
| Git 提交规范（每次提交必读） | [docs/git-workflow.md](docs/git-workflow.md) |

## 1. 这是什么

一套个人级、单机运行的编码自动化 harness：

- **唯一入口**：`harness-infi` 启动一个被武装为「协调者」的 Claude Code 会话，作为用户的唯一对话面。
- **执行平面**：`orchestrator.sh`（dumb loop）取任务 → 建 worktree → 经 adapter 调用执行 agent（Claude / Codex / OpenCode）→ 跑校验门 → 合并或回灌。
- **黑板**：文件层是 agent/人界面（status.json / guidance.json / inbox），SQLite (`.harness/harness.db`) 是编排器的唯一真相。
- **目标**：单机、bash + sqlite + tmux 实现，崩溃可恢复，长时间无人值守。

## 2. 八条不可妥协原则（出现冲突时按此判优先级）

1. **统一入口持有上下文**：用户从不裸跑 `claude`；会话/成本/产物账本归 harness 所有。
2. **聪明判断 vs 确定执行分离**：协调者（LLM）只判断与决策；进程编排由 dumb loop + adapter 承担。
3. **CLI 即协议**：调用任何 agent 都是 Unix 子进程，stdin/file 进、JSON 出、退出码定成败。无专用协议。
4. **文件 + git + SQLite 即媒介**：agent 间不通过内存/网络通信；状态只活在磁盘。
5. **进程临时、对话持久**：每轮 CLI 调用是短命进程，对话靠 session_id `--resume` 续接；续接封顶。
6. **生成者与裁判分离**：写代码的 agent 不能自我宣告完成；完成由确定性校验门 + 跨模型审查判定。
7. **硬约束放 hooks，不放提示词**：禁 force push、禁改敏感目录等用 PreToolUse / Stop hook 拦截。
8. **控制面与数据面分离**：tmux 只做观测；机器读的数据走结构化 JSON + SQLite，绝不 capture-pane 刮屏。

## 3. 目录心智模型

**工具本体永远不复制进项目**（心智模型同 git）。

```
~/tools/harness/              # 工具本体（本仓库就是这里）
├── pyproject.toml            # Python 包定义（console scripts）
├── uv.lock                   # uv 锁文件（进 git）
├── .venv/                    # uv sync 生成（不进 git）
├── src/harness/              # Python 层
│   ├── db.py                 # SQLite 操作（真参数化）
│   └── cli/{harness_task,db_cli}.py
├── bin/{harness-infi,harness}
├── orchestrator.sh
├── coordinator/{tools/harness-task (shim), coordinator.md}
├── adapters/{claude.sh, codex.sh, opencode.sh}
├── lib/{atomic_write.sh, gate.sh}
├── hooks/pre_tool_use.sh
└── templates/{AGENTS.md.tmpl, settings.json.tmpl, gitignore-fragment}

~/.config/harness/{config, projects.list}   # 全局配置

<project>/.harness/           # 项目运行时状态（整体 gitignore）
├── harness.db                # 编排器独占写
├── workers/<id>/{status,guidance}.json   # worker 独占写
├── inbox/<id>.answer         # 人/协调者独占写
└── logs/raw/
```

**写者唯一原则**：任何文件有且只有一个写者；`harness.db` 编排器独占写，并发交给 SQLite WAL。

## 4. 实现红线

写代码前必须知道、违反会被打回的硬约束：

### 4.1 进程与会话
- 每次执行 agent 调用 **必须双重上限**：外层 `timeout`（默认 900s）+ 内层 `--max-turns`（默认 12）。
- session 续接封顶（默认 6 轮），到顶 checkpoint 落盘、开新会话。
- 退出码 0 **不等于** 任务完成。真相 = 黑板 + git diff + 校验门，绝不是 CLI 返回值。

### 4.2 通信契约
- 每个 backend 一个 adapter，归一化为 `{ok, session_id, result, cost_usd, num_turns, error}`。编排逻辑不接触原生格式。
- **绝不解析自然语言输出 (`.result`) 做控制决策**；控制信号一律来自 agent 写的结构化黑板文件。
- 失败调用通常仍是合法 JSON（`.is_error`/`.error`），先检错再用结果。
- 提示词一律 stdin / 文件传入，**禁止内联拼进命令行**（引号/`$`/反引号/换行会爆）。

### 4.3 SQLite
- `PRAGMA journal_mode=WAL` + `PRAGMA busy_timeout=5000`。
- 必须本地文件系统，**严禁 NFS/网络盘**（WAL 共享内存机制在网络盘上不可靠）。
- 短连接短事务，每次 `sqlite3 db "..."`；禁止长事务。
- 依赖 `RETURNING`（SQLite ≥ 3.35），启动校验版本。
- **agent 不直接拼 SQL 写库**（LLM 转义/注入故障面高）；agent 只写 JSON，编排器摄取；协调者经参数化脚本读写。

### 4.4 文件层并发
- 所有 JSON 原子写：先 `*.tmp` 再 `mv`，禁原地写。
- 每个 schema 带 `schema_version`（当前 1）+ `updated` 时间戳。
- schema 不向后兼容的变更必须递增版本号并在 adapter / 编排器 / 协调者工具三端同步。

### 4.5 隔离与合并
- 一任务 = 一 worktree = 一分支；worker 对主仓库主分支只读。
- worktree 放在项目**外部兄弟目录** `<project 同级>/.worktrees/<project>/<task_id>/`，不嵌主工作区。
- 合并是编排器**专属、串行**职责，仅在校验门全绿后；worker 禁止 merge/push 主分支。

### 4.6 Codex 特别约束（与 0.142.2 实测）
- Codex **可以**程序化获取 session ID：`codex exec --json` 输出 `thread.started.thread_id` UUID；session 文件落在 `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`。
- resume 优先用 UUID：`codex exec ... resume <uuid>`；UUID 不存在时降级 `--last`（cwd 过滤）。**别只用 `--last`**——cwd 过滤可能匹错相邻 session。
- **clap 解析关键**：`exec` 的全局选项（`-C/--cd`、`-m/--model`）必须在 `resume` 子命令**之前**；其余如 `--json`、`-s`、`-o`、`--ephemeral` 在 `exec resume` 上也支持，前后均可。
- **每个 worktree 同时最多一个 Codex 会话，且对该 worktree 的 Codex 调用必须串行**：codex 进程对 git index、文件系统的并发写有竞争风险；锁是防御性的，不靠 codex 自己解决。
- 无 USD 成本字段：`turn.completed.usage` 只给 token 计数（input/cached_input/output/reasoning_output）；capability bitmap COST_REPORT=0。
- 跨模型审查时建议加 `--ephemeral`（review 不需要持久化）+ 可选 `-c web_search="disabled"`（review 只看 diff，不应联网）。

### 4.7 Hooks
- 硬策略只用 command hook，**不用 HTTP hook**（非 2xx 算非阻塞错误，网络抖动即旁路安全门）。
- 拦截输出走 **stderr** + `exit 2`；写 stdout 模型收不到反馈。
- PreToolUse 初始拦截清单：`push --force`、worktree 外的 `rm -rf`、写非本 worker 目录的 `.harness/`、读写含 `prod`/`secret` 的路径、对主分支的 `git merge`/`git push`。

### 4.8 成本
- 每次调用 `INSERT` 一行 `calls` 表；原始 JSON 另存 `logs/raw/` 排障。
- 预算闸即 SQL 累加；超限即 kill switch 停止派发并 Notification 上抛协调者。

## 5. 任务状态机

```
QUEUED → DISPATCHED → WORKING → GATING → MERGED（终态）
                         │         │
                guidance │         │ 未过门 → 回灌 → WORKING（带报错重跑）
                         ▼         │
                      BLOCKED      │ timeout / 重试耗尽 → FAILED（终态）
                  （待人工答复）
```

每次状态迁移：**单事务先落库 (`tasks` + `transitions`) 再行动**。崩溃后从库读回即可续跑。

死 worker 检测：摄取 status.json 时刷新 `sessions.last_seen`；超阈值（默认 10 分钟）仍 `working` 的判死，退回 QUEUED 重派；重派次数独立封顶（默认 2）。

## 6. 校验门 `lib/gate.sh`

按序执行，任一失败返回非零并输出结构化 `.gate-report.json`：

1. 构建 / 类型检查（`tsc --noEmit` / `mypy` / `cargo check`）
2. Lint（项目既有 linter，零新增告警）
3. 测试（全量或受影响子集）
4. diff 静态审计（越界 / 触碰禁区）
5. 跨模型审查（可配置；Claude 写 → Codex 审，反之亦然；输出 `{approve, issues}`）

## 7. 渐进落地（按阶段交付，不要越级）

1. **阶段一**：`harness-infi` + `harness-task` 脚本 + orchestrator（单 Claude backend + 单 worker）+ gate.sh + hooks 安全门。
2. **阶段二**：状态机、错误回灌、重试/重派上限、死 worker 检测、Notification 打扰策略。
3. **阶段三**：引入 Codex/OpenCode 作跨模型审查（先做裁判，不做并行编写）。
4. **阶段四**：多 worker 并行 worktree。

## 8. 开发风格约定

### 8.1 语言边界（硬约束，违反会被打回）

分层选型，**不是单一语言**。每一层用契合该层默认倾向的语言：

| 层 | 语言 | 理由 |
|----|------|------|
| 调子进程 / 拼命令 / 读 JSON 输出 | **bash** | shell 主场；状态自然外置到文件 |
| SQL / JSON-schema 校验 / 状态机迁移 / DB 事务 | **Python**（`src/harness/`，标准库） | 真参数化 SQL、异常机制、可单测 |
| 协调者本身（system prompt + 行为约束） | **自然语言 + 工具契约** | 不是「实现」出来的，是「配」出来的 |

**具体归属**：

- `orchestrator.sh`（shim）、`adapters/*.sh`、`lib/gate.sh`、`hooks/*.sh`、`bin/harness` → bash
- `src/harness/{db,orchestrator,worker,merge,adapter,notify,budget,config,atomic_write}.py` + `cli/{harness_task,db_cli,orchestrator_cli}.py` → Python
- `coordinator/coordinator.md`、`templates/AGENTS.md.tmpl` → Markdown / 提示词
- `coordinator/tools/harness-task` 是薄 shim，`exec python3 -m harness.cli.harness_task`

**绝不**：

- ❌ 在 bash 里拼 SQL（转义/注入对 LLM 是高发故障面；用 Python 真参数化）
- ❌ 在 Python 里维护长生命周期对象（违反原则四「状态只活在磁盘」；每次 CLI 调用都是新进程）
- ❌ 用 jq 嵌套深度操作复杂 JSON schema（→ Python json + dataclass）

### 8.2 迁移触发线

一旦满足任一条件，把 `orchestrator.sh` 整体迁 Python：

- 行数超过约 **500 行**
- 阶段四要求并行 worker 池（bash 子进程池管理不可靠）
- 错误处理逻辑出现嵌套层级 ≥ 3

迁移后**文件协议与 `harness.db` schema 不变**，对协调者和执行 agent 完全透明（它们只认 CLI 契约和文件契约）。

### 8.3 其他约定

- **时间戳**：一律 UTC ISO-8601。
- **JSON**：UTF-8 无 BOM。
- **schema_version**：当前 1。
- **Python 依赖**：仅标准库（`sqlite3` / `json` / `argparse` / `pathlib`）。引入第三方包须 PR review。
- **环境管理**：**用 `uv` 管理 Python 环境**。一次性设置：`cd $HARNESS_HOME && uv sync`。这会创建 `.venv/` 并装 console scripts（`harness-task` / `harness-db`）。`uv.lock` 进 git，`.venv/` 进 gitignore。
- **bash → python 桥**：所有 bash 入口 source `lib/python_env.sh`，得到 `$HARNESS_PYTHON`（优先 `.venv/bin/python3`，回落系统 `python3`）+ `PYTHONPATH=src/`。
  - **绝不**在 bash 里写死 `python3 -m harness.cli.xxx`；一律 `"$HARNESS_PYTHON" -m harness.cli.xxx`。
  - 未 `uv sync` 也能跑（用系统 python3 + PYTHONPATH），但建议先 sync 拿到锁版本的解释器。
- **adapter 接入新 CLI**：必须验证非交互模式、退出码语义、可解析输出（硬门槛）；会话续接 / 工具权限 / 成本数据缺失时按能力位图限制可派任务类型。

## 9. 工作方式（避免常见 LLM 编码失误）

写代码前的姿态比单次输出更重要。下面四条与本仓库"聪明判断 vs 确定执行分离"的精神一致，**冲突时不可绕过**。

### 9.1 先想清楚再写

- 显式声明假设；不确定就**问**，不要默默挑一个。
- 多种合理解读并存时，把选项摆出来让用户拍板。
- 看到更简单的做法就提出来；该 push back 时 push back。
- 不清楚就停下来，指出哪里困惑——不要边猜边写。

### 9.2 最小实现

- 不写未要求的功能、抽象、配置项、不可能场景的错误处理。
- 单次使用的代码不抽象；三处相似的代码好过过早抽象。
- 200 行能压成 50 行就重写。
- 自问："senior 看会不会觉得过度设计？" 是 → 简化。

### 9.3 外科手术式改动

- 只改必须改的；不顺手"改进"相邻代码、注释、格式。
- 不重构未坏的东西；风格随既有风格走，即便你不同意。
- 看到无关死代码——**指出**，不要删（除非被要求）。
- 自己改动产生的孤儿（未用的 import / 变量 / 函数）要清；既有死代码别动。
- 标尺：每行变更都能直接追溯到用户的请求。

### 9.4 目标驱动

把任务翻译成可验证目标，再开干：

- "加校验" → "为非法输入写测试，再让它通过"
- "修 bug" → "写复现测试，再让它通过"
- "重构 X" → "改前改后测试都过"

多步任务先列简短计划（步骤 + 每步的验证方式）。强成功标准让你能自循环；弱标准（"能跑就行"）会让你反复回头问。

## 10. 常见反模式（不要做）

- ❌ 用 `tmux capture-pane` 解析 agent 输出做控制决策。
- ❌ 让协调者直接 `send-keys` 驱动执行 agent。
- ❌ 让 agent 直接写 `harness.db`。
- ❌ 用提示词约束硬安全策略（必须用 hooks）。
- ❌ 把 harness 代码复制进项目仓库。
- ❌ 在 worktree 外或主分支上让 worker 改文件。
- ❌ 把 `.harness/harness.db` 放 NFS / 网络盘。
- ❌ 用 CLI 退出码当任务成功判据。
- ❌ 把含特殊字符的提示词内联拼进命令行。
- ❌ HTTP hook 做硬策略拦截。
