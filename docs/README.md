# harness-donk Documentation Index

| Doc | Audience | What it solves |
|-----|----------|----------------|
| **[getting-started.md](getting-started.md)** | **First-time users** | **Install, onboard a project, dispatch your first real task; command cheatsheet + troubleshooting FAQ** |
| [design.md](design.md) | Everyone | Design philosophy, principles, trade-offs — **authoritative when there's a conflict** |
| [development-plan.md](development-plan.md) | Developers | What to build per phase, acceptance criteria, dependency order |
| [module-architecture.md](module-architecture.md) | Developers | Module list, directory layout, writer ownership, dependency graph |
| [interfaces.md](interfaces.md) | Developers | Inter-module contracts: script signatures, function interfaces, file-trigger relationships |
| [data-schemas.md](data-schemas.md) | Developers / integrators | JSON blackboard schemas + SQLite DDL, the formal version |
| [adapter-contract.md](adapter-contract.md) | Adding a new backend | Integration contract, capability bitmap, degradation strategy |

**Reading order**:

- First-time user: **getting-started.md** (nothing else needed)
- New developer onboarding: design.md → development-plan.md → module-architecture.md → interfaces.md
- Adding a new CLI backend: adapter-contract.md → data-schemas.md
- Changing schemas: data-schemas.md → sync adapter / orchestrator / coordinator on all three sides
- Changing principles: design.md (PR requires review)

Chinese versions of all docs are available as `*.zh.md` in this directory.

The repo root [CLAUDE.md](../CLAUDE.md) is a quick reference for Claude when developing in this repo; it does not replace the docs above.
