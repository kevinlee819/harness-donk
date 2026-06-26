# harness-donk 文档索引

| 文档 | 受众 | 解决什么问题 |
|------|------|-------------|
| **[getting-started.md](getting-started.md)** | **首次使用者** | **装好、接管项目、派出第一个真任务；含命令速查 + 排障 FAQ** |
| [design.md](design.md) | 全员 | 设计哲学、原则、权衡 — **冲突时以此为准** |
| [development-plan.md](development-plan.md) | 开发者 | 按阶段干什么、每阶段验收什么、依赖顺序 |
| [module-architecture.md](module-architecture.md) | 开发者 | 模块清单、目录结构、写者归属、依赖图 |
| [interfaces.md](interfaces.md) | 开发者 | 模块间契约：脚本签名、函数接口、文件触发关系 |
| [data-schemas.md](data-schemas.md) | 开发者 / 接入方 | JSON 黑板 schema + SQLite DDL，形式化版 |
| [adapter-contract.md](adapter-contract.md) | 接入新 backend 的人 | 接入合同、能力位图、降级策略 |

**阅读顺序**：

- 第一次用：**getting-started.md**（其它都不用看）
- 新接手开发：design.md → development-plan.md → module-architecture.md → interfaces.md
- 接入新 CLI：adapter-contract.md → data-schemas.md
- 改 schema：data-schemas.md → 同步 adapter / 编排器 / 协调者三端
- 改原则：design.md（PR 必须 review）

仓库根的 [CLAUDE.md](../CLAUDE.md) 是 Claude 在本仓库开发时的速查，不替代以上文档。
