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
- [x] `files_changed` 准确度：claude.sh / codex.sh 改用 `base..HEAD`（fallback main → master → diff HEAD）

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
- [x] `hooks/notification.sh` — 阶段二 iter 2 完成（needs_decision/task_failed/budget_exceeded 触发；macOS osascript + notify.log）
- [-] `hooks/stop.sh` — 决定**暂不实装**，理由见 [hooks/stop.md](hooks/stop.md)（gate.sh 已是完成度权威 + PreToolUse 已覆盖越界，stop 重复且更弱）

### 协调者会话
- [x] `bin/harness-infi` — tmux 新建/复用会话，启动 `claude` 加载 coordinator.md（用 launcher 脚本避开引号灾难）
- [x] `coordinator/coordinator.md` — system prompt：八原则、打扰策略、harness-task 用法、spec 模板、入队前必填检查
- [x] tmux 会话名规范：`harness-<sha8(pwd)>`
- [x] **harness-infi 双 window**（2026-06-25 #1）：window 0=coordinator + window 1=orchestrator daemon；`--no-attach` / `--backend` / `--model` 选项；remain-on-exit 防 pane 关闭丢错；4 infra test 覆盖
- [x] **协调者真启动端到端验证**（2026-06-25 #1）：claude --print + coordinator.md 真使用 `harness-task add`，写出完整模板 spec → orchestrator 派给 worker → gate 失败一次（我自己配置错） → worker 回灌自修 → merge。$0.36 / 4m15s。原则一「统一入口持有上下文」首次端到端验证

### 其他
- [x] `bin/harness setup` — 校验 sqlite3 ≥ 3.35 / jq / git / tmux / python；建 `~/.config/harness/{config,projects.list}`
- [x] `bin/harness init` 登记项目到 `~/.config/harness/projects.list`（幂等，design §10.3）— 为后续多项目全局预算聚合铺路
- [x] `bin/harness doctor` — 各 backend echo 自检（真调一次 claude）
- [x] `bin/harness attach` — 默认 attach 协调者会话；worker pane 阶段二
- [x] adapter 原始日志 envelope 加 task_id / worker_id / prompt_path（替代独立 lib/log.sh）
- [x] `lib/budget.sh`（手算版）— `budget_today` / `budget_check` 只读不杀；`budget_kill_switch` 阶段二
- [~] 阶段一验收：5 个真实小任务一次过门率 ≥ 60%
   - 已跑 4 个真 Claude 任务全部 MERGED：T-hello1（hello.txt）、T-greet（greeting.txt）、T-license（BLOCKED→answer→MIT）、T-retry（codex 写）、T-001（coord 派发）
   - 一次过门：T-hello1 ✓、T-greet ✓、T-license ✓（一次问题→一次答完通）、T-retry ✓（codex 写）、T-001 一次回灌（gate 配置我自己写错）
   - **样本基本够用了**，但都是设计过的任务；要严格验收需未事先调好的真实 5 个任务

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

### Iteration 2 收尾（2026-06-25 完成 #3：orphan reaper + BLOCKED 超时）
- [x] **孤儿任务回收**：单进程编排器下，loop 顶端 `transient 状态 + updated 老于阈值` 即崩溃残留（不用心跳）。
   - `_reap_orphans`：扫 dispatched/working/gating + updated > dead_worker_threshold_min 分钟（默 10）
   - `redispatches < MAX_REDISPATCHES`（默 2）→ 转 queued + redispatches++（下个 loop claim 会再跑）
   - 否则 → failed + task_failed 事件（payload 含 redispatches）
- [x] **BLOCKED 超时**：`_timeout_blocked` 扫 blocked + 最后 blocked transition > blocked_timeout_hours（默 72h）→ failed + task_failed 事件
- [x] 配置项：`blocked_timeout_hours` 加入 `~/.config/harness/config` setup 默认
- [x] db.py `query_orphans` / `query_blocked_overdue` / `inc_redispatches` + db_cli 子命令
- [x] 测试：17 文件 / 113+ cases 全绿（+4 e2e orphan/blocked-timeout / +5 unit db queries）

### Iteration 2 仍待
- [-] orchestrator 周期扫描 events 注入协调者会话 — 已用 pull-on-re-engagement 替代（coordinator.md §2.2）。push 路径（tmux send-keys / file watcher）原则上更弱（不可靠 / 状态外置），不做
- [x] `kill -9` 续跑回归测试（自动化版）— test_e2e_kill_recovery 2 case，真起 orchestrator + SIGKILL 进程树 + 重启 → orphan reap → re-run → merged。**过程中发现并修复两个真 bug**：(1) `updated < datetime('now', ?)` 字符串比较坑（ISO-8601 `T`/`Z` vs SQL `datetime('now')` 空格无 Z）→ 改 `strftime('%s', ...)`；(2) worker 退出后清 `in_flight`，下个 loop 顶端 reap 看到 `gating` 任务无主 → 误判孤儿 → 双派 → 改用 `pending_merge` 集合显式守住 worker 退出到 merge 完成之间的窗口
- [ ] 验收：8 任务 / 8 小时离场无人值守，≥ 5 MERGED（用户明示先收下）
- [ ] 验收：模拟 timeout → 自动重派一次 → 失败 → FAILED 上抛（orphan reaper 覆盖了状态机一半，差 timeout 触发路径；用户明示先收下）

---

## 🟡 阶段三：跨模型审查

来自 [docs/development-plan.md §3](docs/development-plan.md)：

### 第一批（2026-06-25 完成）
- [x] `adapters/codex.sh` — `codex exec --json` 归一化；mkdir 原子互斥串行（macOS 无 flock）
   - 输出 schema 与 claude.sh 对齐；session_id = `.thread_id`（codex 0.142 可拿 UUID，CLAUDE.md §4.6 已更新）
   - 真实 cost 数据缺失（capability bitmap COST_REPORT=0）
   - mock 含 REVIEW DIFF / blocking 两种模式
   - **审完官方文档后修了 resume 路径 bug**（`exec resume` 之前必须放 `-C`，否则 clap fail）+ UUID-优先 resume + `--ephemeral` for review
- [x] gate 第 5 步 cross_review — 真调 reviewer adapter；解析 `{approve, issues}`；reject 即 fail gate
   - 取 base..HEAD diff，截断到 16KB
   - 容忍 result 含 markdown 代码块包裹（Python regex 抽 `{...}`）
   - 空 diff / 缺 reviewer adapter 均有终态
- [x] AGENTS.md.tmpl 加 `cross_review_reviewer` 配置 + 「写者不审，审者不写」建议
- [x] claude.sh / codex.sh mock 都识别 REVIEW DIFF 提示返回 JSON result
- [x] `harness doctor` 加 codex 真 echo 自检（不再仅检查 PATH 存在）
- [x] 测试：15 files / 103+ cases 全绿（+5 codex adapter / +6 gate cross_review）

### D1：真环境跨模型冒烟（2026-06-25 完成）
- [x] 加 orchestrator `--backend` flag + `HARNESS_BACKEND` env；替换硬编码 claude（含 status.json / register-session / log-call / get-session）
- [x] 集成测试：T-bsw（codex backend → CODEX.txt + calls.backend=codex）、T-defcl（默认 claude）、unknown backend fast fail
- [x] codex 写 + claude 审完整闭环：T-retry（retry.py + test_retry.py）
   - codex sonnet-?? 约 105s 完成 写 18+40 行；gate 测试 + cross_review 全绿；merge OK
   - claude 沉默 approve 因 codex 写得干净（实测无 subtle bug）
- [x] **关键验证**：手动注入 sleep-before-first-attempt bug → claude 24s reject 输出 3 条精准 issue：
   - "每次循环开头都 sleep，导致首次尝试前也会 sleep(delay)..." 命中注入的 bug
   - "sleep 次数从最多 max_attempts-1 改为 max_attempts，行为不一致"
   - "docstring 退化降低契约清晰度"
   - **原则六生成者-裁判分离首次真实落地**
- [x] 修观测缺口：gate cross_review 调用现也落 `.harness/logs/raw/`（worktree 回收前抢救出来）

### 阶段三剩余
- [-] `adapters/opencode.sh` — `opencode run` 路径（opencode 暂未安装，等用户需要再做）
- [-] 跨模型审查 calls 记账（2026-06-25 用户决定先不管：codex `cost_usd=null` 本身已是观测黑洞，没好办法解决）
- [x] reviewer 选择从「单 backend」升级到 spec 级别 — spec frontmatter `reviewer:` 字段覆盖 AGENTS.md 全局；`cross_review:` 也可 spec 级开/关；test_gate_cross_review 加 2 cases
- [ ] 验收：3 个 subtle bug diff 识别率 ≥ 2/3（当前 1/1 命中 — sleep-before-first-attempt 的 retry bug 被精准抓出）
- [ ] 验收：adapter 合同所有硬门槛满足（capability bitmap、串行锁竞争、超时）

---

## 🟢 阶段四：并行 worktree（核心已完成）

来自 [docs/development-plan.md §4](docs/development-plan.md)：

- [x] 编排器主循环改并发 — worker 池 + claim 串行（SQL `RETURNING`）+ 调度并行
  - `orchestrator.sh` 414 行 bash → `src/harness/{orchestrator,worker,merge,adapter,notify,budget,config,atomic_write}.py`（CLAUDE.md §8.2 触发线）
  - 新建 `Pool` 类：`w1..wN` 池化复用，busy 集合 + 互斥锁
  - `WorkerThread` 单任务全周期，posts MergeRequest 到 Queue 退出
- [x] 合并严格串行（编排器主线程独占 drain Queue）
- [x] 资源闸：`HARNESS_MAX_WORKERS` env / `--max-workers` 默认 4；外层 `timeout` + 内层 `--max-turns` 双重上限沿用阶段一
- [x] 修复并发产生的 race：`BEGIN IMMEDIATE` 让 busy_timeout 真正起作用；merge 失败必 `git merge --abort` 防止下次 merge 被脏树污染
- [x] 验收：4 独立任务并行→全 merged + 合并时序无重叠（test_e2e_parallel 3 case 全绿）
- [x] 验收：worker 崩溃路径在 thread try/except 内 → task transition FAILED + notify，不污染池内其他 worker
- [x] `harness attach <worker_id>` 现场快照（worker 是 Python 线程，非 tmux pane；输出 status.json + worktree + guidance + 最近 adapter call；`--path` 仅打印 worktree 供 cd）+ 5 case 单测
- [x] 任务拆分依赖检查 — coordinator.md §5.1 加入 depends_on 自检流程（活跃任务清单 → 读写交集判断 → 显式 --depends-on）
- [ ] 验收：8 独立任务并行吞吐 ≥ 串行 3 倍（用户先收下不验收）

---

## 🔵 持续事项（横切）

### 测试设施
- [x] `tests/run.sh` — 测试发现（.sh + .py） + 子进程隔离 + 汇总报告
- [x] `tests/lib/assert.sh` — eq/neq/match/file/json/exit_code 等断言
- [x] `tests/lib/setup.sh` — make_fixture_project / set_gate_test_cmd / 自动清理
- [x] **当前规模：26 文件 / 153+ cases / ~55s 全绿**（+ session_resume_cap + projects.list 登记）
   - unit (.sh)：attach 5 / gate 6 / hooks 25 / notification_hook 3 / backup 3 / claude_adapter 6 / codex_adapter 7 / gate_cross_review 8 / events_cli 4
   - unit (.py)：atomic_write 5 / budget_python 4 / notify_python 4 / orchestrator_pool 5 / merge_serial 3 / db (含 events / orphan / blocked-overdue / migration drill / resume cap) 32 / harness_task 11
   - integration (.sh)：e2e_success 2 / e2e_retry_failed 1 / e2e_blocked_resume 2 / e2e_backend_switch 3 / e2e_orphan_reaper 4 / e2e_depends_on 2 / e2e_parallel 3 / e2e_kill_recovery 2 / init_idempotent 8 / harness_infi 4
- [x] orchestrator 孤儿任务回收 + BLOCKED 超时（阶段二 #3）
- [x] adapter 单测：claude.sh 错误路径 + mock 全分支（6 case）；codex.sh resume by UUID mock 验证（7 case）
- [x] **tests/manual/** 目录建立 — 真模型 smoke（claude / codex / cross_review / coordinator 4 个脚本 + README）；不进 run.sh
- [x] schema_version 升级框架 + 演练（runner code + 4 drill cases + docs/data-schemas.md §7 重写）
- [x] **kill -9 续跑回归测试**：tests/integration/test_e2e_kill_recovery.sh — 真起 orchestrator → 进程树 SIGKILL → 重启 reap → 续跑 merged（2 case 全绿）

### 其他
- [ ] schema_version 升级流程演练一次（人造改一个字段，三端同步）
- [ ] 文档同步：每个阶段完成后回灌 docs/ 中过时的部分

---

## 📌 决策待办（需要用户确认的设计点）

- [x] **notify 通道**（已定）：macOS 桌面通知 + `.harness/logs/notify.log` 永远落盘 + `events` 表 + JSON 文件四路并行。tmux 内消息不可靠暂未做
- [-] **预算默认值**：`budget_daily_usd=10 USD` 用户默认收下；长跑后再校
- [-] **死 worker 阈值**：`dead_worker_threshold_min=10` 用户默认收下；codex 单 turn 1-2 分钟，10min 安全
- [-] **BLOCKED 超时**：`blocked_timeout_hours=72` 用户默认收下；个人用足够
- [x] **session_resume_cap**：实装强制 — worker._drive 在 adapter 调用前查 `resume_count >= cap` 则 reset_session + sid="" 强制开新会话（design §7.1）。代码 commit 已在每轮做了，checkpoint 部分天然满足。db 加 `get_resume_count` / `reset_session` + 4 单测
- [x] **reviewer 默认值**：`harness init --backend <writer>` 自动反转 reviewer（claude↔codex），生成者-裁判分离原则保持默认设置即满足
- [ ] **跨模型审查 cost 记账**：codex `cost_usd=null` + gate.sh 不写 calls 表，跨模型工作流的成本完全不可见。token-based 估算还是单独 reviews 表？（用户说先不管）

---

_本文档由 Claude 在开发过程中实时维护。每完成一项立即更新状态。_
