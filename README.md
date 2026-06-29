<p align="center">
  <img src="docs/donk.png" alt="harness — a pixel-art donkey wearing a harness" width="160">
</p>

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
harness init             # generates AGENTS.md (edit the gate config at the top: test/lint/build commands)
harness-infi             # start the coordinator and get to work
```

> installer defaults to `$HOME/.harness/`; entry symlinks go to `$HOME/.local/bin/`. Override with `--prefix` / `--bindir`.
>
> **Upgrade**: `harness upgrade` (`git pull --ff-only + uv sync`; refuses if you have uncommitted changes)
> **Uninstall**: `bash $HOME/.harness/install.sh --uninstall`

Full install, configuration, usage, and troubleshooting → **[docs/getting-started.md](docs/getting-started.md)**.

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

## Language

English is the primary display language. Set `HARNESS_LANG=zh` to switch agent prompts and project templates to Chinese.

## License

MIT — see [LICENSE](LICENSE)
