# TODO

实时进度跟踪。Claude 会在工作过程中实时更新此文件，用户可监控。

约定：`[ ]` 未开始 / `[~]` 进行中 / `[x]` 完成 / `[!]` 阻塞 / `[-]` 暂缓

最后更新：见每节末尾的 timestamp。

---

## 📐 架构调整（2026-06-25）

**分层选型，不再单一语言**（见 CLAUDE.md §8.1）。已完成的重构：

- [x] `pyproject.toml` + `src/harness/` 包结构
- [x] `src/harness/db.py` — 替换原 `lib/db.sh`，真 sqlite3 参数化（杜绝 bash 拼 SQL）
- [x] `src/harness/cli/db_cli.py` — bash 调用桥（`harness-db <subcmd>`）
- [x] `src/harness/cli/harness_task.py` — 替换原 bash 版 harness-task
- [x] `coordinator/tools/harness-task` 改为薄 shim
- [x] `bin/harness` + `orchestrator.sh` 改为调 `python3 -m harness.cli.db_cli`
- [x] `tests/run.sh` 同时发现 .sh + .py
- [x] `tests/unit/test_db.py`（15 cases）替换 test_db.sh
- [x] `tests/unit/test_harness_task.py`（11 cases）替换 test_harness_task.sh
- [x] CLAUDE.md §8.1 加语言边界硬约束 + 迁移触发线
- [x] docs/module-architecture.md 同步

**新规则**：bash 管「拼命令调进程」，Python 管「碰 SQL / 状态机」，自然语言定义协调者。

### Python 环境管理改为 uv（2026-06-25）

- [x] `lib/python_env.sh` — 共享加载器：`HARNESS_PYTHON` 优先 `.venv/bin/python3`，回落系统 `python3`
- [x] 所有 bash 入口（bin/harness、orchestrator.sh、coordinator/tools/harness-task、tests/run.sh）source 之
- [x] `tests/unit/test_harness_task.py` 读 `HARNESS_PYTHON` 而非硬编码 `python3`
- [x] `.gitignore` 加 `.venv/`、`__pycache__/` 等
- [x] `uv sync` 生成 `.venv/` 与 `uv.lock`（uv.lock 进 git）
- [x] CLAUDE.md §8.3 改为 uv 工作流；目录树添 uv.lock / .venv/
- [x] 全套 70/70 测试在 .venv python 下通过

## ✅ MVP（最小可运行版本，已完成）

**status**: 2026-06-24 — mock 模式端到端跑通；真 Claude 调用路径已实现但未付费验证。
**2026-06-25 更新**：DB 层迁 Python 后 70/70 测试全绿，mock e2e 仍通过。

**目标**：手动 `harness-task add` 入队 → `orchestrator.sh --once` 执行 → 单 Claude worker 在 worktree 内改代码 → gate.sh 校验 → 编排器合并。无 hooks、无并行、无死 worker 检测、无协调者会话。

### 目录骨架
- [x] 创建 `schema/json/`、`lib/`、`adapters/`、`bin/`、`coordinator/tools/`、`templates/`、`hooks/`、`tests/{unit,integration,fixtures}/`

### 数据契约
- [x] `schema/harness.sql` — DDL + PRAGMA + user_version
- [-] `schema/json/status.schema.json` — worker status.json 校验（MVP 暂用 jq 简单校验，json schema 文件后置）
- [-] `schema/json/guidance.schema.json`（同上）
- [-] `schema/json/gate-report.schema.json`（同上）
- [-] `schema/json/call-result.schema.json`（同上）

### 核心 lib
- [x] `lib/atomic_write.sh` — `atomic_write_json` 函数
- [x] `lib/db.sh` — db_init / db_claim / db_transition / db_log_call / db_query_status 等（smoke 通过）
- [x] `lib/gate.sh` — 读 AGENTS.md gate 配置，按序执行，输出 `.gate-report.json`（正反 smoke 通过）

### Adapter
- [x] `adapters/claude.sh` — 调 `claude --print --output-format json --permission-mode bypassPermissions`，归一化输出
- [x] `--model` 透传（`ADAPTER_MODEL` / orchestrator `--model`）
- [x] hooks 环境：导出 `HARNESS_WORKTREE` 给 pre_tool_use 用
- [x] 原始日志 envelope 含 task_id / worker_id / prompt_path
- [x] mock 模式：`HARNESS_MOCK_ADAPTER=1` 走假后端（不烧 API）
- [ ] `files_changed` 准确度：当前 `git diff HEAD`，commit 后为 0；后置用 `base..HEAD` 改进

### Orchestrator
- [x] `orchestrator.sh --once` — 单次循环：claim → worktree → adapter → gate → merge
- [x] worktree 位于 `<project 同级>/.worktrees/<project>/<task_id>/`
- [x] 合并到主分支前必须 gate 全绿
- [x] 回灌：gate 失败拼报告续接，retries++，封顶 3

### CLI
- [x] `bin/harness init` — bootstrap 当前项目（建 .harness/、装模板、init db）
- [x] `bin/harness status` — 列出任务与状态
- [x] `bin/harness run-once` — 包装 `orchestrator.sh --once`
- [x] `coordinator/tools/harness-task add` — 入队
- [x] `coordinator/tools/harness-task query` — 查询
- [x] `coordinator/tools/harness-task history/cancel/answer` — 附赠

### 模板
- [x] `templates/AGENTS.md.tmpl` — 含 gate 命令占位
- [x] `templates/gitignore-fragment`

### 验收
- [x] 在 fixture 项目中 `harness init` + `harness-task add` + `harness run-once` 全链路跑通（mock 模式）— ✅ T-demo1 merged
- [x] 失败回灌路径验证（mock 模式 + gate 强制失败）— ✅ T-fail2 retries 耗尽后 FAILED
- [x] **真 Claude 端到端**（2026-06-25）：「为 fixture 项目添加 hello.txt」 → ✅ T-hello1 MERGED；3 turns / 12.5s / $0.006 真正成本（含调试 retries 共 $0.26）。修复：adapter 需 `--permission-mode bypassPermissions`（worker 在 worktree + hooks 保护下，安全）+ 透传 `HARNESS_WORKTREE` 给 hooks。

---

## 🟡 阶段一补全（MVP 之后，仍属阶段一）

来自 [docs/development-plan.md §1](docs/development-plan.md)，MVP 砍掉但阶段一必须有的：

### Hooks 安全门
- [x] `hooks/pre_tool_use.sh` — 5 条规则全部实现（push --force、rm -rf 越界、harness.db 写入、prod/secret 路径、git merge/push 拦截）
- [x] `templates/settings.json.tmpl` — 注册 hooks 到 `.claude/settings.json`，含占位符
- [x] `bin/harness init` 集成 settings.json 安装（保护已有 settings.json，写 .harness-suggested 副本）
- [x] hooks 单元测试：25 cases，每条规则正反两路
- [x] `harness init` 集成测试：installs_settings_json / preserves_existing_settings
- [ ] `hooks/stop.sh` — 完成度强制（阶段二，需 task state 关联）
- [ ] `hooks/notification.sh` — 阶段二，需 notify 管道

### 协调者会话
- [x] `bin/harness-infi` — tmux 新建/复用会话，启动 `claude` 加载 coordinator.md（用 launcher 脚本避开引号灾难）
- [x] `coordinator/coordinator.md` — system prompt：八原则、打扰策略、harness-task 用法、spec 模板、入队前必填检查
- [x] tmux 会话名规范：`harness-<sha8(pwd)>`

### 其他
- [x] `bin/harness setup` — 校验 sqlite3 ≥ 3.35 / jq / git / tmux / python；建 `~/.config/harness/{config,projects.list}`
- [x] `bin/harness doctor` — 各 backend echo 自检（真调一次 claude）
- [x] `bin/harness attach` — 默认 attach 协调者会话；worker pane 阶段二
- [x] adapter 原始日志 envelope 加 task_id / worker_id / prompt_path（替代独立 lib/log.sh）
- [x] `lib/budget.sh`（手算版）— `budget_today` / `budget_check` 只读不杀；`budget_kill_switch` 阶段二
- [ ] 阶段一验收：5 个真实小任务一次过门率 ≥ 60%

---

## 🟡 阶段二：闭环与崩溃恢复

来自 [docs/development-plan.md §2](docs/development-plan.md)：

### Iteration 1（2026-06-25 完成）
- [x] `transitions` 表写入贯通（db.py transition 单事务先写表再迁状态）
- [x] `harness status --task T-XXX [--history]` 输出迁移史 + 待决策事件计数
- [x] 错误回灌：gate 失败 → 注入 `.gate-report.json` → `retries++`，封顶 3（MVP 已实现）
- [x] `lib/notify.sh` — 三类事件写 events 表 + `.harness/events/*.json` 落盘
- [x] orchestrator 在 MERGED / FAILED (adapter_error/gate_failed/merge_conflict) 终态自动 notify
- [x] `harness backup` + 合并节点自动备份到 `.harness/backups/harness-<ts>.db`
- [x] db.py `event_write` / `event_query_pending` / `event_mark_delivered` / `session_touch`
- [x] 测试：80+ cases 全绿（+4 db events / +5 notify / +1 history flag / +1 events 集成）

### Iteration 2（2026-06-25 大部完成）
- [x] guidance 升级：worker 写 `guidance.json {blocking:true}` → BLOCKED → `needs_decision` 事件
- [x] inbox 答复：`<task_id>.answer` 出现 → BLOCKED → WORKING + adapter `--resume`（保留 session_id；归档 answer 到 inbox/processed/）
- [x] `lib/budget.sh` kill switch — 超限停止派发 + `budget_exceeded` 事件（实现在 orchestrator `_budget_guard`，按天去重 marker）
- [x] `hooks/notification.sh` — 待决策/失败/超限事件触发；macOS osascript 桌面通知 + 永远落 `.harness/logs/notify.log`
- [x] `harness backup` 保留策略（默认 7 天，可 `HARNESS_BACKUP_RETAIN_DAYS` 覆盖）
- [x] orchestrator 主循环顶部：先 `_scan_resume_blocked`，再预算闸，再 claim
- [x] mock adapter 加 `HARNESS_MOCK_BLOCK=1` 钩子用于测试 BLOCKED 流
- [x] 测试：92+ cases / 13 files 全绿 (+2 e2e blocked-resume / +4 budget / +3 backup / +3 notification hook)

### Iteration 2（仍待）
- [ ] 死 worker 检测：扫描器 + `sessions.last_seen` 超阈值 + `redispatches++` 封顶 2（需要 worker 心跳机制；现在 adapter 是单 shot 调用，没自然心跳点）
- [ ] orchestrator 周期扫描 events 注入协调者会话（待协调者会话有可注入接口；tmux send-keys 不可靠，stage 3 再做）
- [ ] 验收：8 任务 / 8 小时离场无人值守，≥ 5 MERGED
- [ ] 验收：`kill -9` orchestrator + workers 后重启续跑，无半截中间态
- [ ] 验收：模拟 timeout → 自动重派一次 → 失败 → FAILED 上抛

---

## 🟡 阶段三：跨模型审查

来自 [docs/development-plan.md §3](docs/development-plan.md)：

- [ ] `adapters/codex.sh` — 含 per-worktree flock 串行约束
- [ ] `adapters/opencode.sh` — 走 `opencode run` 路径
- [ ] gate 第 5 步 cross_review — diff 喂另一 backend 输出 `{approve, issues}`
- [ ] AGENTS.md `gate.cross_review.reviewer` 配置开关
- [ ] `harness doctor` 增强（每个 backend echo 测试）
- [ ] 验收：3 个 subtle bug diff 识别率 ≥ 2/3
- [ ] 验收：adapter 合同所有硬门槛满足

---

## 🟡 阶段四：并行 worktree

来自 [docs/development-plan.md §4](docs/development-plan.md)：

- [ ] 编排器主循环改并发 — worker 池 + claim 串行 + 调度并行
- [ ] 合并仍严格串行（编排器主线程独占）
- [ ] `harness attach <worker>` 选择 pane
- [ ] 资源闸：max_concurrent_workers / 单任务 token / 时间硬上限
- [ ] 任务拆分依赖检查（spec 模板增 `depends_on` 字段，协调者入队前自检）
- [ ] 验收：8 独立任务并行吞吐 ≥ 串行 3 倍
- [ ] 验收：合并阶段无 race
- [ ] 验收：worker 崩溃不污染其他 worktree

---

## 🔵 持续事项（横切）

### 测试设施
- [x] `tests/run.sh` — 测试发现 + 子进程隔离 + 汇总报告
- [x] `tests/lib/assert.sh` — eq/neq/match/file/json/exit_code 等断言
- [x] `tests/lib/setup.sh` — make_fixture_project / set_gate_test_cmd / 自动清理
- [x] `tests/unit/test_atomic_write.sh` — 6 cases
- [x] `tests/unit/test_db.sh` — 11 cases（含 args[@] 回归 + 依赖检查）
- [x] `tests/unit/test_gate.sh` — 6 cases
- [x] `tests/unit/test_harness_task.sh` — 10 cases
- [x] `tests/integration/test_e2e_success.sh` — 完整成功路径
- [x] `tests/integration/test_e2e_retry_failed.sh` — 回灌耗尽 FAILED
- [x] `tests/integration/test_init_idempotent.sh` — init 幂等 + 非 git 失败
- [x] **总计 38 cases，~7s 跑完，全绿**
- [ ] adapter 单测（claude.sh mock + 错误路径）
- [ ] orchestrator 死 worker 检测路径（阶段二后）
- [ ] 真 Claude 集成（手工，单独 `tests/manual/` 目录，不进 run.sh 默认）

### 其他
- [ ] schema_version 升级流程演练一次（人造改一个字段，三端同步）
- [ ] 文档同步：每个阶段完成后回灌 docs/ 中过时的部分

---

## 📌 决策待办（需要用户确认的设计点）

- [ ] **notify 通道**：阶段二实现时选 tmux 内消息 / 桌面通知 / webhook 中的哪条？
- [ ] **预算默认值**：`~/.config/harness/config` 中 `budget_daily_usd` 默认 10 USD 是否合适？
- [ ] **死 worker 阈值**：10 分钟是否过长/过短？根据真实任务耗时调整
- [ ] **session_resume_cap**：默认 6 轮，需在真实任务跑后校准

---

_本文档由 Claude 在开发过程中实时维护。每完成一项立即更新状态。_
