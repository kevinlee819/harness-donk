<p align="center">
  <img src="docs/donk.png" alt="harness — a pixel-art donkey wearing a harness" width="160">
</p>

# harness-donk — 多 Agent 自驱动编码 Harness

> 🫏 像驯一头会写代码的驴 —— 你说要去哪，它驮着活儿去；过了门才算到，没过自己回头再来。

个人级、单机运行的编码自动化工具。`harness-infi` 启动一个"协调者" Claude Code 会话作为唯一对话面；后台 dumb-loop 编排器取任务、起 worktree、调真正干活的 agent（Claude / Codex），跑校验门，过了才合并主分支。失败自动回灌重跑，需要决策时主动找你。

> 命令依然叫 `harness` 和 `harness-infi`（短、好打、不破坏已初始化的项目）；"harness-donk" 是 GitHub / PyPI / brew tap 上的项目标识，与社区其他叫 "harness" 的项目区分。

```
你 ──对话──▶ 协调者（Claude Code, system prompt = coordinator.md）
                  │
                  ▼ harness-task add（写 .harness/harness.db）
              ┌────────────────┐
              │ orchestrator   │  ←─ 编排器并行 worker 池 + 串行合并
              │ (Python, 后台) │
              └────────────────┘
                  │ claim → worktree → adapter → gate → merge
                  ▼
              Claude / Codex 各自在独立 worktree 工作
```

## 快速开始

```bash
# 1. 装（一行；自动检系统依赖 / 自动装 uv / 自动设 PATH）
curl -LsSf https://raw.githubusercontent.com/USER/harness-donk/main/install.sh | bash

# 或：已 clone 的情况
git clone https://github.com/USER/harness-donk.git && cd harness-donk && ./install.sh

# 2. 自检 backend（真烧少量 API）
harness doctor

# 3. 接管项目
cd ~/code/my-project
harness init             # 生成 AGENTS.md（编辑顶部 gate 配置：test/lint/build 命令）
harness-infi             # 启动协调者，开始干活
```

> installer 默认装到 `$HOME/.harness/`，入口符号链接到 `$HOME/.local/bin/`。改路径用 `--prefix` / `--bindir`。
>
> **升级**：`harness upgrade`（`git pull --ff-only + uv sync`，有未提交改动会拒绝）
> **卸载**：`bash $HOME/.harness/install.sh --uninstall`

详细安装、配置、使用、排障 → **[docs/getting-started.md](docs/getting-started.md)**。

## 文档

| 文档 | 受众 | 何时看 |
|------|------|--------|
| **[getting-started.md](docs/getting-started.md)** | **首次使用者** | **从这里开始** |
| [design.md](docs/design.md) | 想了解为什么 | 设计哲学、八条原则、权衡 |
| [development-plan.md](docs/development-plan.md) | 开发者 | 按阶段干什么 |
| [module-architecture.md](docs/module-architecture.md) | 开发者 | 模块清单、目录、写者归属 |
| [interfaces.md](docs/interfaces.md) | 开发者 | 模块间契约 |
| [data-schemas.md](docs/data-schemas.md) | 开发者 / 接入方 | JSON / SQLite schema |
| [adapter-contract.md](docs/adapter-contract.md) | 接入新 backend | 能力位图、降级策略 |
| [CLAUDE.md](CLAUDE.md) | 在本仓库开发 | 速查 + 八条不可妥协原则 |

## 状态

- 阶段 1-4 已完成（MVP → 闭环与崩溃恢复 → 跨模型审查 → 并行 worker + Python 迁移）
- 26 测试文件 / 163+ cases / ~64s 全绿
- 真实使用前请按 [getting-started.md §11](docs/getting-started.md) 跑一遍"最低可用配置"自检

## License

[你想加哪个就加哪个]
