# 开发计划

## 0. 节奏与原则

- **不越级**：每阶段先做完、跑通、有验收信号再进下一阶段。
- **底层先行**：每阶段内部按 `schema → lib → adapter → orchestrator → bin → templates → 集成测试` 顺序。
- **可校验性是入门票**：任何在项目内运行的功能，必须先有对应的 gate 检查 — 不允许「先实现、后补测试」。
- **真实任务驱动**：每阶段都用一个具体小项目跑通验收，不堆功能不试用。

## 1. 阶段一：单 backend 闭环（第 1 周）

**目标**：协调者 → 入队 → 单 worker（Claude）→ 校验门 → 合并，全链路打通。手工盯每一步。

### 1.1 交付物（按依赖顺序）

| 序 | 模块 | 文件 | 交付定义 |
|----|------|------|---------|
| 1 | 数据契约 | `schema/harness.sql`, `schema/json/*.json` | DDL 可建库；JSON schema 可被 jq 校验 |
| 2 | DB 封装 | `lib/db.sh` | `db_init / db_claim / db_transition / db_log_call` 五个函数 + 单元测试 |
| 3 | 文件写入 | `lib/atomic_write.sh` | `atomic_write_json` 函数，崩溃测试通过 |
| 4 | 日志 | `lib/log.sh` | 调用 JSON 落盘 `logs/raw/` |
| 5 | Claude adapter | `adapters/claude.sh` | 输入提示词文件 → 输出统一结构 `{ok, session_id, result, cost_usd, num_turns, error}` |
| 6 | 校验门 | `lib/gate.sh` | 五步骤按序，任一失败输出 `.gate-report.json` |
| 7 | hooks（安全门最小集） | `hooks/pre_tool_use.sh`, `hooks/stop.sh` | 拦截 `push --force`、worktree 外 `rm -rf`、未过门 stop |
| 8 | 编排器 | `orchestrator.sh` | 单 worker 串行循环：claim → worktree → adapter → gate → merge → reap |
| 9 | 协调者武装 | `coordinator/coordinator.md`, `coordinator/tools/harness-task` | system prompt 写好打扰策略；harness-task add/query 可用 |
| 10 | 入口 | `bin/harness-infi`, `bin/harness` | infi 起协调者会话；harness 支持 setup/doctor/init/status |
| 11 | 模板 | `templates/AGENTS.md.tmpl`, `templates/settings.json.tmpl`, `templates/gitignore-fragment` | `harness init` 渲染到项目 |

**阶段一不做**：Codex / OpenCode adapter、跨模型审查、并行 worker、死 worker 检测、Notification 路由、预算闸自动 kill（手算即可）。

### 1.2 验收

- 真实项目（推荐：一个有 `make test` 的小型 TypeScript 或 Python 库）连续派 5 个小任务（如「为模块 X 添加单元测试」「修复 issue Y」），**一次过门率 ≥ 60%**。
- 任意时刻 `harness status` 输出当前队列与每个任务状态，与磁盘真相一致。
- 手动 `kill -9 orchestrator.sh` 后重启，正在 GATING 的任务可继续；正在 WORKING 的可被死 worker 检测识别（阶段二接管，阶段一手工重启即可）。

## 2. 阶段二：闭环与崩溃恢复（第 2 周）

**目标**：「睡前交代、早上验收」可用 — 系统能无人值守跑过夜，崩溃自愈，需要时打扰。

### 2.1 交付物

| 序 | 模块 | 交付定义 |
|----|------|---------|
| 1 | 状态机迁移历史 | `transitions` 表写入 + `harness status --history T-XXX` 查询 |
| 2 | 错误回灌 | gate 失败 → adapter `--resume` 续接，注入 `.gate-report.json` 为 prompt；`retries++`，封顶默认 3 |
| 3 | 死 worker 检测 | 摄取 status.json 时刷新 `sessions.last_seen`；超阈值（默认 10 分钟）扫描器退回 QUEUED；`redispatches++` 封顶默认 2 |
| 4 | guidance 升级 | worker 写 `guidance.json {blocking: true}` → 编排器置 BLOCKED → 经 notify 上抛 |
| 5 | 通知路由 | `lib/notify.sh` + `hooks/notification.sh` 三类事件路由：需决策 / 待验收 / 故障 |
| 6 | 预算闸 | `lib/budget.sh`：日预算 SQL 累加，超限触发 kill switch + Notification |
| 7 | 备份 | `harness backup` 调 `sqlite3 .backup`，挂在合并节点 |

### 2.2 验收

- 提交 8 个任务后离场 8 小时，回来 ≥ 5 个 MERGED、≤ 1 个 BLOCKED 经询问已答复、≤ 2 个 FAILED 报告原因清晰。
- `kill -9` orchestrator + 全部 worker 进程，重启后所有任务从正确状态继续，**无任何任务停留在「半截中间态」**（DISPATCHED 但无 worker / GATING 但无报告）。
- 模拟 API 故障让一个任务 timeout → 应自动重派一次 → 仍失败 → FAILED 并上抛。

## 3. 阶段三：跨模型审查（第 3 周）

**目标**：引入 Codex / OpenCode 作为**裁判**（不做并行编写），借跨模型对抗提升合并质量。

### 3.1 交付物

| 序 | 模块 | 交付定义 |
|----|------|---------|
| 1 | Codex adapter | `adapters/codex.sh`，遵守 per-worktree 串行约束 |
| 2 | OpenCode adapter | `adapters/opencode.sh` |
| 3 | gate 第 5 步：跨模型审查 | 把 `git diff` 喂给另一 backend，输出 `{approve: bool, issues: []}` |
| 4 | 配置开关 | `AGENTS.md` 中 `gate.cross_review.reviewer: codex | opencode | none` |
| 5 | adapter doctor 增强 | `harness doctor` 对每个 backend 做 echo 自检 |

### 3.2 验收

- 故意制造 3 个有 subtle bug 的 diff（如越界访问、空指针、错误的 SQL 转义），**跨模型审查识别率 ≥ 2/3**。
- adapter 合同表（见 `adapter-contract.md`）所有硬门槛全部满足。

## 4. 阶段四：并行 worktree（第 4 周起）

**目标**：多 worker 并行执行无依赖任务，吞吐量上去。

### 4.1 前置条件

- 阶段二崩溃恢复已经稳定跑过至少两周。
- 任务拆分质量经协调者自检：spec 模板增加「依赖检查」字段，协调者入队前回答「本任务是否依赖当前队列中任何任务的产物」。

### 4.2 交付物

- 编排器主循环改并发：worker 池 + claim 串行（SQL `RETURNING` 即原子）+ 调度并行。
- 合并仍**严格串行**（编排器主线程独占）。
- `harness attach <worker>` 选择 pane。
- 资源闸：max concurrent workers、单任务 token / 时间硬上限。

### 4.3 验收

- 8 个独立任务并行跑，吞吐量 ≥ 串行的 3 倍。
- 合并阶段无 race（同时两个完成 → 第二个等待）。
- 任意 worker 崩溃不污染其他 worker 的 worktree。

## 5. 不在路线图（明确不做）

- 跨机器分布式。
- 对等 agent 网络（A2A）。
- Web UI。
- 多租户。
- 替换 SQLite 为外部数据库。

需求出现前不做（设计 §1 非目标）。

## 6. 风险与缓解（开发期）

| 风险 | 触发条件 | 缓解 |
|------|---------|------|
| bash 复杂度爆炸 | 状态机/adapter 超 500 行 | 阶段三末评估迁 Python（保持文件协议与 schema 不变，对 agent 透明）|
| Codex session 不可控 | per-worktree 仍出现并发 | adapter 内加 flock 强制串行 |
| OpenCode 子 agent 挂死 | serve 模式 | 只用 `opencode run` CLI 路径 |
| 长 session 走形 | resume 超 6 轮 | checkpoint 落盘 + 开新会话（阶段一即实现该上限） |
| schema 改动遗漏同步 | 三端不一致 | schema 改 PR 必须同时 touch adapter / 编排器 / harness-task 三处 |
