# tests/manual/

**手动执行的烟测** — 真调 Claude / Codex / 其他 backend，会烧 API。

**绝不** 进 `tests/run.sh` 默认发现路径——CI 跑这些会破产、且不稳定（依赖外部服务 / 网络 / API key）。

## 何时跑

- 修过 adapter 后（claude.sh / codex.sh）—— `--print` / `exec --json` 输出 schema 可能因 CLI 升级飘走
- 阶段验收时（阶段一过门率 / 阶段三 subtle bug 识别率 / 阶段二 8 小时离场）
- 升级 backend CLI（claude code / codex-cli）后做回归

## 怎么跑

每个脚本自包含、自清理。直接执行：

```bash
bash tests/manual/smoke_real_claude.sh
bash tests/manual/smoke_real_codex.sh
bash tests/manual/smoke_real_cross_review.sh
```

需要 `claude` / `codex` 在 PATH、已登录、网络可用。每个脚本头部注明预期成本与时长。

## 文件清单（含估算成本）

| 脚本 | 用途 | 预期 |
|------|------|------|
| `smoke_real_claude.sh` | claude.sh adapter 真调 echo 自检 + 简单写文件任务 | $0.01 / ~15s |
| `smoke_real_codex.sh` | codex.sh adapter 真调 echo 自检 + initial + resume by UUID | $0.05 / ~30s |
| `smoke_real_cross_review.sh` | 完整跨模型审查闭环（claude 写 + codex 审 + reject 路径） | $0.20 / ~3min |
| `smoke_coordinator.sh` | 协调者 system prompt + harness-task 工具真使用 | $0.10 / ~25s |

## 不在这里

- 长跑 / 离场验收（阶段二 8 小时无人值守、阶段三 3/3 subtle bug 识别）—— 这些是 `acceptance/` 目录的事，需协调人值守，不属于「冒烟」。
- mock 测试 —— 进 `tests/{unit,integration}/`，由 `tests/run.sh` 自动跑。
