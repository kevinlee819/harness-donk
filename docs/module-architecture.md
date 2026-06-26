# 模块架构

## 1. 目录结构（最终态）

```
~/tools/harness/                        # 工具本体仓库（即本仓库）
│
├── README.md                           # 项目入口
├── CLAUDE.md                           # Claude 开发速查（含语言边界硬约束 §8.1）
├── docs/                               # 设计与开发文档（本目录）
├── pyproject.toml                      # Python 包定义（console scripts: harness-task / harness-db）
├── uv.lock                             # uv 锁文件（进 git；用 `uv sync` 重建 .venv）
│
├── bin/                                # 用户/系统可执行入口（PATH 暴露）
│   ├── harness-infi                    # 启动协调者会话（用户唯一入口）
│   └── harness                         # bash 入口：init/status/run-once；DB 操作经 harness-db CLI
│
├── orchestrator.sh                     # 执行平面 dumb loop（bash；DB 操作经 harness-db CLI）
│
├── src/harness/                        # Python 层（碰 SQL / 状态机的部分）
│   ├── __init__.py
│   ├── db.py                           # SQLite 短连接封装、真参数化（替换原 lib/db.sh）
│   └── cli/
│       ├── harness_task.py             # 协调者工具实现
│       └── db_cli.py                   # bash 调用桥（harness-db <subcmd>）
│
├── coordinator/                        # 协调者武装包
│   ├── coordinator.md                  # 协调者 system prompt / 打扰策略（自然语言定义）
│   └── tools/
│       └── harness-task                # 薄 shim：exec python3 -m harness.cli.harness_task
│
├── adapters/                           # backend 归一化层（bash）
│   ├── claude.sh
│   └── codex.sh                        # opencode 暂未做
│
├── lib/                                # 可复用 bash 函数库（被 source）
│   ├── atomic_write.sh                 # 原子写 JSON
│   ├── gate.sh                         # 校验门多步骤执行（含 cross_review）
│   ├── notify.sh                       # events 表 + JSON 文件 + 通知 hook 三路出口
│   ├── budget.sh                       # 预算闸（手算只读）
│   └── python_env.sh                   # bash → python 桥：设 $HARNESS_PYTHON + PYTHONPATH
│
├── hooks/                              # 安装到项目 .claude/settings.json 的钩子脚本
│   ├── pre_tool_use.sh                 # 危险命令拦截（stderr + exit 2）
│   └── notification.sh                 # 事件桌面通知 + notify.log
│
├── templates/                          # harness init 时拷贝/渲染到项目
│   ├── AGENTS.md.tmpl                  # 含 gate 块 + cross_review_reviewer
│   ├── settings.json.tmpl              # .claude/settings.json hooks 注册
│   └── gitignore-fragment
│
├── schema/                             # 数据契约
│   ├── harness.sql                     # SQLite DDL（建表 + PRAGMA + 版本）
│   └── migrations/                     # 增量迁移文件 V<N>__<desc>.sql
│       └── README.md
│
└── tests/
    ├── run.sh                          # 测试入口，发现 .sh + .py
    ├── lib/{assert.sh, setup.sh}       # bash 测试辅助
    ├── unit/                           # 全部 mock，CI 跑
    │   ├── test_atomic_write.sh / test_gate.sh / test_hooks.sh
    │   ├── test_notify.sh / test_notification_hook.sh
    │   ├── test_budget.sh / test_backup.sh / test_events_cli.sh
    │   ├── test_claude_adapter.sh / test_codex_adapter.sh
    │   ├── test_gate_cross_review.sh
    │   ├── test_db.py                  # 30+ cases 含 migration drill
    │   └── test_harness_task.py
    ├── integration/                    # e2e mock，CI 跑
    │   ├── test_e2e_success.sh / test_e2e_retry_failed.sh
    │   ├── test_e2e_blocked_resume.sh / test_e2e_orphan_reaper.sh
    │   ├── test_e2e_backend_switch.sh / test_e2e_depends_on.sh
    │   ├── test_init_idempotent.sh / test_harness_infi.sh
    └── manual/                         # 真模型调用，手动跑，不进 CI
        ├── README.md
        ├── smoke_real_claude.sh
        ├── smoke_real_codex.sh
        ├── smoke_real_cross_review.sh
        └── smoke_coordinator.sh
```

**语言边界**：调子进程/拼命令的薄层用 bash；碰 SQL/状态机/JSON-schema 的用 Python（`src/harness/`）。详见 [CLAUDE.md §8.1](../CLAUDE.md)。

**显式不在仓库**：实现期的 worktree、`.harness/`、`~/.config/harness/` — 它们是运行时产物或全局配置。

## 2. 模块清单与职责

| # | 模块 | 路径 | 单一职责 | 写者 |
|---|------|------|---------|------|
| M1 | 用户入口 | `bin/harness-infi`, `bin/harness` | 启动协调者会话；管理 / 观测命令 | — |
| M2 | 协调者武装 | `coordinator/` | 协调者 prompt + 协调者可调脚本 | LLM（读） |
| M3 | 执行编排器 | `orchestrator.sh` | dumb loop：claim 任务 → worktree → adapter → 门 → 合并 | 编排器进程 |
| M4 | 后端适配器 | `adapters/*.sh` | 归一化 backend CLI 调用为统一返回结构 | adapter 进程 |
| M5 | SQLite 存储 | `src/harness/db.py` + `src/harness/cli/db_cli.py` + `schema/harness.sql` | 队列 / 状态机 / 会话 / 调用账（Python，真参数化） | 编排器独占 |
| M6 | 文件黑板 | `lib/atomic_write.sh` + `schema/json/` | worker 与人 → 编排器的写入界面 | 见 §4 |
| M7 | 校验门 | `lib/gate.sh` | 多步骤检查 → `.gate-report.json` | gate 进程 |
| M8 | 安全 hooks | `hooks/` | 项目 `.claude/settings.json` 注册，确定性拦截 | hook 进程 |
| M9 | 通知路由 | `lib/notify.sh` + `hooks/notification.sh` | events 表 + JSON 文件 + 桌面通知（pull-on-re-engagement，见 coordinator.md §2.2） | notify 进程 |
| M10 | 成本闸 | `lib/budget.sh` + orchestrator `_budget_guard` | 累计 + 超限 kill switch + budget_exceeded 事件 | 编排器调用 |
| M11 | 项目初始化 | `bin/harness init` + `templates/` | bootstrap 新项目；`--backend` 反转默认 reviewer | 初始化脚本 |
| M12 | 调用日志 | adapter 内 `_log_raw` | 调用 JSON 落 `logs/raw/`（含 envelope）| adapter 进程 |
| M13 | 孤儿回收 | orchestrator `_reap_orphans` + `_timeout_blocked` | 单进程下崩溃残留任务自愈 + BLOCKED 超时回收 | 编排器调用 |
| M14 | 备份 | `bin/harness backup` + 合并节点自动钩 | sqlite3 `.backup` + 保留策略（默 7 天） | bin/harness |

## 3. 依赖关系图（自下而上）

```
                    ┌──────────────────────────────────┐
                    │  M1 入口 (harness-infi, harness) │
                    └──────────────┬───────────────────┘
                                   │
                  ┌────────────────┼────────────────┐
                  ▼                ▼                ▼
       ┌──────────────────┐  ┌──────────┐   ┌─────────────┐
       │ M2 协调者武装      │  │ M11 init │   │ M3 编排器   │
       │ (harness-task)   │  │          │   │ orchestrator│
       └────────┬─────────┘  └────┬─────┘   └──────┬──────┘
                │                 │                 │
                ▼                 ▼                 ▼
        ┌──────────────────────────────────────────────┐
        │  M5 db.sh  │ M6 atomic_write │ M9 notify    │
        │  M7 gate   │ M10 budget      │ M12 log      │
        └────────┬───────────────────────────┬─────────┘
                 │                           │
                 ▼                           ▼
        ┌──────────────┐            ┌──────────────────┐
        │ schema/*.sql │            │ M4 adapters/*    │
        │ schema/json/ │            │ (claude/codex/   │
        └──────────────┘            │  opencode)       │
                                    └────────┬─────────┘
                                             │
                                             ▼
                                    ┌──────────────────┐
                                    │ backend CLI 进程 │
                                    └──────────────────┘

  M8 hooks 独立部署到项目 .claude/settings.json，被 backend CLI 触发，
  通过 stderr/exit code 与调用方通信，不在调用链内。
```

**规则**：

- 上层只调下层，不反向。
- `lib/` 之间相互独立，不互调（除非显式声明）。例外：`budget.sh` 与 `notify.sh` 都需调 `db.sh`。
- `adapters/` 不依赖 `lib/db.sh`、`lib/notify.sh` — 它们是纯函数式包装，输入提示词、输出统一结构。
- `hooks/` 是部署到外部项目的脚本，**禁止依赖 harness 仓库的 lib**（项目里没有），所有需要的工具函数 inline。

## 4. 写者归属（单写者原则）

| 文件/资源 | 唯一写者 | 读者 |
|-----------|---------|------|
| `<project>/.harness/harness.db` | 编排器（M3）、协调者经 `harness-task`（M2）| 所有需要状态的进程 |
| `<project>/.harness/workers/<id>/status.json` | 该 worker（adapter 内的 backend 进程）| 编排器 |
| `<project>/.harness/workers/<id>/guidance.json` | 该 worker | 编排器、协调者 |
| `<project>/.harness/inbox/<id>.answer` | 人 / 协调者 | 编排器（摄取后注入下一轮 prompt）|
| `<project>/.harness/logs/raw/*.json` | M12 log | 排障人员 |
| `<worktree>/.gate-report.json` | M7 gate | 编排器（回灌）、人 |
| `<project>/AGENTS.md` | 人 | 所有 agent |
| `<project>/specs/<task_id>.md` | 人 / 协调者 | worker |

并发安全：JSON 原子写（`*.tmp` → `mv`），SQLite WAL + busy_timeout=5000。

## 5. 计费平面分离

| 平面 | 进程 | 计费 | API key |
|------|------|------|---------|
| 对话（协调者） | `harness-infi` 启动的交互式 `claude` | 订阅额度 | 个人订阅 |
| 执行（worker） | `adapters/` 内的 `claude -p` / `codex exec` / `opencode run` | 程序化（API） | 独立 API key，启用 prompt caching |

入口与配置分离强制此边界，开发期不要混用 key。
