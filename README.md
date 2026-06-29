<p align="center">
  <img src="docs/donk.png" alt="harness — a pixel-art donkey wearing a harness" width="160">
</p>

<p align="center">
  <a href="#en">English</a> · <a href="#zh">中文</a>
</p>

---

<a id="en"></a>

# harness-donk — Multi-Agent Self-Driving Coding Harness

> 🫏 Like taming a code-writing donkey — you say where to go, it carries the work there; it only counts as done when it passes the gate, otherwise it turns around and tries again.

A personal, single-machine coding automation tool. `harness-infi` starts a "coordinator" Claude Code session as your sole conversation interface; a background dumb-loop orchestrator picks up tasks, creates worktrees, calls the actual coding agents (Claude / Codex), runs the validation gate, and only merges on a clean pass. Failures are automatically fed back for a retry; when a decision is needed, it comes to you.

> The commands are still `harness` and `harness-infi` (short, easy to type, no breakage for already-initialized projects). "harness-donk" is the GitHub / PyPI / brew-tap identifier to distinguish it from other "harness" projects in the community.

```
You ──chat──▶ Coordinator (Claude Code, system prompt = coordinator.md)
                  │
                  ▼ harness-task add (writes .harness/harness.db)
              ┌────────────────┐
              │ orchestrator   │  ←─ parallel worker pool + serial merger
              │ (Python, bg)   │
              └────────────────┘
                  │ claim → worktree → adapter → gate → merge
                  ▼
              Claude / Codex each working in their own isolated worktree
```

## Quick Start

```bash
# 1. Install (one line; auto-checks system deps / installs uv / sets PATH)
curl -LsSf https://raw.githubusercontent.com/kevinlee819/harness-donk/main/install.sh | bash

# Or if you already cloned:
git clone https://github.com/kevinlee819/harness-donk.git && cd harness-donk && ./install.sh

# 2. Check backends (makes real API calls, costs a few cents)
harness doctor

# 3. Onboard a project
cd ~/code/my-project
harness init             # generates AGENTS.md (edit gate config at the top: test/lint/build commands)
harness-infi             # start the coordinator and get to work
```

> Installer defaults to `$HOME/.harness/`; entry symlinks go to `$HOME/.local/bin/`. Override with `--prefix` / `--bindir`.
>
> **Upgrade**: `harness upgrade` (`git pull --ff-only + uv sync`; refuses if you have uncommitted changes)
> **Uninstall**: `bash $HOME/.harness/install.sh --uninstall`

Full install, configuration, usage, and troubleshooting → **[docs/getting-started.md](docs/getting-started.md)**

## Docs

| Doc | Audience | When to read |
|-----|----------|--------------|
| **[getting-started.md](docs/getting-started.md)** | **First-time users** | **Start here** |
| [design.md](docs/design.md) | Want to understand why | Design philosophy, eight principles, trade-offs |
| [development-plan.md](docs/development-plan.md) | Developers | Phase-by-phase plan and acceptance criteria |
| [module-architecture.md](docs/module-architecture.md) | Developers | Module list, directory layout, writer ownership |
| [interfaces.md](docs/interfaces.md) | Developers | Inter-module contracts |
| [data-schemas.md](docs/data-schemas.md) | Developers / integrators | JSON / SQLite schemas |
| [adapter-contract.md](docs/adapter-contract.md) | Adding a new backend | Capability bitmap, degradation strategy |
| [CLAUDE.md](CLAUDE.md) | Developing in this repo | Quick reference + eight inviolable principles |

## Status

- Phases 1–4 complete (MVP → crash recovery → cross-model review → parallel workers + Python migration)
- 29 test files / 163+ cases / ~64s all green
- Before real use, run the "minimum viable config" checklist in [getting-started.md §13](docs/getting-started.md)

## License

MIT — see [LICENSE](LICENSE)

---

<a id="zh"></a>

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
curl -LsSf https://raw.githubusercontent.com/kevinlee819/harness-donk/main/install.sh | bash

# 或：已 clone 的情况
git clone https://github.com/kevinlee819/harness-donk.git && cd harness-donk && ./install.sh

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

详细安装、配置、使用、排障 → **[docs/getting-started.zh.md](docs/getting-started.zh.md)**

## 文档

| 文档 | 受众 | 何时看 |
|------|------|--------|
| **[getting-started.zh.md](docs/getting-started.zh.md)** | **首次使用者** | **从这里开始** |
| [design.zh.md](docs/design.zh.md) | 想了解为什么 | 设计哲学、八条原则、权衡 |
| [development-plan.zh.md](docs/development-plan.zh.md) | 开发者 | 按阶段干什么 |
| [module-architecture.zh.md](docs/module-architecture.zh.md) | 开发者 | 模块清单、目录、写者归属 |
| [interfaces.zh.md](docs/interfaces.zh.md) | 开发者 | 模块间契约 |
| [data-schemas.zh.md](docs/data-schemas.zh.md) | 开发者 / 接入方 | JSON / SQLite schema |
| [adapter-contract.zh.md](docs/adapter-contract.zh.md) | 接入新 backend | 能力位图、降级策略 |
| [CLAUDE.md](CLAUDE.md) | 在本仓库开发 | 速查 + 八条不可妥协原则 |

## 状态

- 阶段 1-4 已完成（MVP → 闭环与崩溃恢复 → 跨模型审查 → 并行 worker + Python 迁移）
- 29 测试文件 / 163+ cases / ~64s 全绿
- 真实使用前请按 [getting-started.zh.md §13](docs/getting-started.zh.md) 跑一遍"最低可用配置"自检

## License

MIT — 见 [LICENSE](LICENSE)
