# 模块接口

本文档形式化定义模块间的契约：脚本入参/出参、函数签名、文件触发关系。**改动这里的任何一处都必须同步上下游**。

数据 schema 的字段定义见 [data-schemas.md](data-schemas.md)，本文只描述「谁调谁、传什么、收什么」。

---

## 1. 用户入口（M1）

### 1.1 `harness-infi`

```
harness-infi [--no-attach] [--backend <name>] [--model <name>]
```

- 行为：在当前目录创建/复用一个 tmux 会话（名 `harness-<sha8(pwd)>`），含两个 window：
  - **window 0 `coordinator`**：交互式 `claude` 加载 `coordinator/coordinator.md` 为 system prompt，PATH 注入 `coordinator/tools/`（`harness-task` 可用）
  - **window 1 `orchestrator`**：长跑 `orchestrator.sh`（无 `--once`），每 5s 轮询 queue；任务来了立刻派
- 默认 attach 到 window 0；`Ctrl-B 0/1` 切窗，`Ctrl-B D` detach 后会话继续存活
- 选项：
  - `--no-attach`：仅创建会话（脚本/CI 用），结束后用 `tmux attach -t harness-<hash>` 进入
  - `--backend <name>`：orchestrator 用哪个写者 backend（默 `claude`，需 `adapters/${name}.sh` 存在）
  - `--model <name>`：透传给 adapter（如 `claude-sonnet-4-6`）
- 前置：当前目录必须是已 `harness init` 过的项目（`.harness/harness.db` 存在）；`tmux`、`claude` 在 PATH
- 失败：未初始化 → 提示 `harness init`；缺失 backend CLI / 未知 backend → 提示 `harness doctor` / 选项 typo
- 实现备注：两个 launcher 脚本写到 `.harness/.coordinator-launcher.sh` 和 `.harness/.orchestrator-launcher.sh`，避开 shell 引号灾难；tmux session 开了 `remain-on-exit on`，orchestrator daemon 挂掉后 pane 仍保留以便排障

### 1.2 `harness`

```
harness setup                            # 一次性环境：校验依赖、建 ~/.config/harness/
harness doctor                           # 各 backend echo 级自检（真调 claude + codex）
harness init [--backend claude|codex]    # 当前目录 bootstrap：建 .harness/、装模板、装 hooks
                                         # --backend 决定 AGENTS.md 默认 cross_review_reviewer
                                         # （writer-reviewer 自动反转：claude→codex / codex→claude）
harness status [--task <id>] [--history] # 任务列表 / 单任务详情 / 迁移史
harness events pending                   # 列出待处理事件（needs_decision / failed / completed / budget_exceeded）
harness events ack <eid>...              # 标记事件已交付（防止协调者重复报告）
harness attach [<worker_id>]             # attach 到 tmux（无参 = 协调者会话）
harness backup                           # sqlite3 .backup → .harness/backups/harness-<ts>.db
                                         # 含保留策略（默 7 天，HARNESS_BACKUP_RETAIN_DAYS 可调）
harness run-once [--mock] [--backend N] [--model M] [--max-retries N]
                                         # 跑一轮编排器（处理一个任务后退出，调试 / 验收用）
```

返回码：0 成功，1 用户错误（缺参等），2 系统错误（依赖缺失、数据库损坏）。

未实现：`stop` / `ls` —— 当前 MVP/iter 1-2 范围未需。

---

## 2. 协调者武装（M2）

### 2.1 `coordinator/tools/harness-task`

协调者可调脚本。**只对协调者暴露**，是协调者写入任务队列的唯一手段。

```
harness-task add [--id T-XXX] [--priority N] [--depends-on T-A,T-B] [--spec PATH]
                 # body 走 stdin → 写到 specs/<id>.md（除非 --spec 指向已存在文件）
harness-task query [--status queued|dispatched|working|gating|blocked|merged|failed]
                   [--task T-XXX] [--json]
harness-task history <task_id>          # 状态迁移历史
harness-task cancel  <task_id>          # 取消未完成任务（→ failed, reason=user_cancelled）
harness-task answer  <task_id> <text>   # 答复 BLOCKED 状态的任务（写 inbox/<id>.answer）
```

- 输入：命令行参数 + stdin（`add` 的 spec body 可走 stdin）。
- 输出：stdout 一行 JSON `{ok: bool, task_id: "T-XXX", error?: "..."}`。
- 实现：薄 shim 调 `python -m harness.cli.harness_task`，**绝不让协调者直接拼 SQL**（CLAUDE.md §8.1 语言边界）。

### 2.2 `coordinator/coordinator.md`

- 不是脚本，是 system prompt。
- 必含：八原则 §2、打扰策略（默认沉默 + 三类触发）、`harness-task` 用法、spec 模板格式、入队前必填检查项（是否有验收命令、是否声明文件范围）。

---

## 3. 执行编排器（M3）

### 3.1 `orchestrator.sh` 主循环

```bash
orchestrator.sh [--project <path>] [--once] [--mock] [--max-retries N] \
                [--model NAME] [--backend NAME] [--max-workers N]
```

- 实质实现：`src/harness/orchestrator.py`；`orchestrator.sh` 是 7 行 shim。
- `--once`：claim 一个任务，跑到终态（merged/blocked/failed）+ 排干合并队列后退出。
- `--max-workers N`：worker 池大小（默 4，env `HARNESS_MAX_WORKERS` 也可设）。`--once` 隐式 pool=1。
- 默认 daemon 模式，由 `harness-infi` 启动时后台拉起，无限循环每空闲 5s 轮询。
- **并发模型**：每个 worker 一个 `threading.Thread`，主线程独占跑 git merge（严格串行）。worker 通过 `queue.Queue` 把成功的任务交给主线程合并；失败/blocked 由 worker 自己 transition + notify。

**循环伪代码**：

```
loop:
  budget_check || { kill_switch; sleep 30; continue }
  task = db_claim()              # 原子取 queued 队首
  if !task: sleep 5; continue
  worktree = worktree_create(task)
  status = adapter_call(task, worktree)   # 见 §4
  ingest(workers/<id>/status.json)
  if guidance_blocking(): db_transition(task, BLOCKED); notify; continue
  while status == working: poll
  if !status.done: redispatch_or_fail(task); continue
  gate_result = gate.sh(worktree)
  if !gate_result.ok:
    if task.retries < MAX_RETRIES:
      task.retries++
      adapter_resume(task, gate_result.report_path)
      continue
    else:
      db_transition(task, FAILED); notify; continue
  merge_serial(worktree, task.branch)
  worktree_remove(worktree)
  db_transition(task, MERGED); notify
```

### 3.2 死 worker 扫描器（M3 子进程）

每 60s 跑一次：

```sql
SELECT task_id, worker_id FROM tasks
JOIN sessions USING(task_id)
WHERE status='working' AND last_seen < datetime('now', '-10 minutes');
```

命中：`db_transition(task, QUEUED, reason='worker_dead')`，`redispatches++`，封顶 2 次后 FAILED。

---

## 4. 后端适配器（M4）— **adapter 合同**

所有 adapter 暴露同一函数 `adapter_call`：

```bash
# 入参：环境变量
ADAPTER_TASK_FILE=/path/to/prompt.txt       # 必填，提示词文件路径
ADAPTER_WORKTREE=/path/to/worktree          # 必填，工作目录
ADAPTER_SESSION_ID=                         # 可选，存在则续接
ADAPTER_MAX_TURNS=12                        # 内层上限
ADAPTER_TIMEOUT=900                         # 外层墙钟，秒
ADAPTER_BACKEND_MODEL=                      # 可选，指定模型

# 调用
bash adapters/claude.sh

# 出参：stdout 单行 JSON
{
  "ok": true,
  "session_id": "uuid-...",
  "result": "natural language summary",     # 仅供人/排障，禁止做控制决策
  "cost_usd": 0.42,
  "num_turns": 7,
  "files_changed": 5,
  "error": null                              # ok=false 时填错误简述
}

# 出参：stderr
原始 backend 输出 / 调试信息

# 退出码
0  正常完成（ok 可能 true/false，由 JSON.error 区分业务失败 vs 系统失败）
非0 adapter 自身故障（解析失败、CLI 不存在）
```

**adapter 必须**：

1. 提示词走 stdin / 文件，禁止内联拼命令行。
2. 解析 backend 输出后**先检错再用结果**（`.is_error` / `.error`）。
3. 原始调用 JSON 落盘 `<project>/.harness/logs/raw/<ts>-<task_id>.json`。
4. `--output-format json` / `--json` 必须传；NDJSON（Codex）由 adapter 内部聚合。
5. 续接：`ADAPTER_SESSION_ID` 非空时调 `--resume` / `--last`；否则首发。
6. Codex 特别约束：检测同 worktree 已有 Codex 进程则等待（flock）。

接入新 backend 见 [adapter-contract.md](adapter-contract.md)。

---

## 5. SQLite 封装（M5）

### 5.1 `lib/db.sh` 公共函数

```bash
db_init <db_path>                           # 执行 schema/harness.sql，幂等

db_claim                                    # stdout: T-XXX,<spec_path>;空表则空
                                            # 原子 UPDATE...RETURNING

db_transition <task_id> <to_state> [reason] # 写 tasks.status + transitions

db_log_call <task_id> <worker_id> <backend> <session_id> <exit_code> \
            <cost_usd> <num_turns> <duration_ms> <files_changed>

db_register_session <task_id> <backend> <session_id>

db_refresh_session <task_id>                # 更新 last_seen=now

db_scan_dead_workers <threshold_minutes>    # stdout: task_id 列表

db_today_cost                               # stdout: float

db_query_status [--task <id>] [--state <s>] # JSON 输出
```

**实现要求**：

- 每个函数一次短连接：`sqlite3 "$DB_PATH" "..."`，不长连。
- 必须 `PRAGMA busy_timeout=5000` 与 `journal_mode=WAL`（建库时一次性设）。
- 启动校验 `sqlite3 --version` ≥ 3.35（`RETURNING` 依赖）。
- 输入参数全部用 sqlite3 `--bail` + bind 形式或 jq 严格转义，**禁止字符串拼 SQL**。

### 5.2 文件层（M6）

由 worker 进程写、编排器摄取：

| 文件 | 写者 | 触发编排器动作 |
|------|------|---------------|
| `workers/<id>/status.json` | worker | 每次摄取后写 `sessions.last_seen`；若 `status==done` 触发 WORKING→GATING |
| `workers/<id>/guidance.json` | worker | `blocking==true` 触发 WORKING→BLOCKED + notify |
| `inbox/<id>.answer` | 人/协调者 | 触发 BLOCKED→WORKING，answer 注入下一轮 prompt |

文件写入函数：

```bash
atomic_write_json <path> <json_string>      # tmp + rename
schema_check <path> <expected_version>      # 失败则拒读
```

---

## 6. 校验门（M7）

### 6.1 `lib/gate.sh`

```bash
gate.sh <worktree_dir> [--skip-cross-review]

# 退出码
0  全绿
非0 至少一步失败

# 副作用
<worktree_dir>/.gate-report.json   # 结构化报告
```

`.gate-report.json` schema 见 [data-schemas.md](data-schemas.md#gate-report)。

### 6.2 步骤回调（项目 AGENTS.md 中声明命令）

```yaml
gate:
  build: tsc --noEmit          # 跳过则填空字符串
  lint: eslint .
  test: npm test
  diff_audit: harness diff-audit <spec>  # 编排器提供
  cross_review:
    enabled: true
    reviewer: codex             # codex / opencode / none
```

未声明的步骤跳过并在 report 中标记 `skipped`。

---

## 7. 安全 Hooks（M8）

部署到项目 `.claude/settings.json`：

```json
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/tools/harness/hooks/pre_tool_use.sh"}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "~/tools/harness/hooks/stop.sh"}]}
    ],
    "Notification": [
      {"hooks": [{"type": "command", "command": "~/tools/harness/hooks/notification.sh"}]}
    ]
  }
}
```

### 7.1 `hooks/pre_tool_use.sh` 契约

- stdin: Claude Code hook 标准输入 JSON（含 `tool_input.command` 等）。
- 行为：匹配危险模式 → stderr 写原因 → `exit 2`。
- **禁止**：写 stdout（模型收不到）、HTTP 调用（网络抖动旁路安全门）。
- 初始拦截集见设计 §7.5。

### 7.2 `hooks/stop.sh` 契约

- 输入：Claude Code Stop hook stdin。
- 行为：调 `gate.sh --quick`（仅 build + lint，不跑全量 test）；任一失败 → stderr 写未完成项 → `exit 2` 或输出 `{"decision":"block","reason":"..."}`。
- 用途：防止 worker 在未完成时退出 — 「任务内自驱动」由此内建。

### 7.3 `hooks/notification.sh` 契约

- 输入：`hooks/notification.sh <event_type> <task_id> <event_json_path>`（由 `harness.notify.notify` fire-and-forget 调用）。
- 行为：macOS 桌面通知（osascript） + 写 `.harness/logs/notify.log`。

---

## 8. 通知路由（M9）

### 8.1 `src/harness/notify.py`

```python
from harness.notify import notify
notify(event_type: str, task_id: Optional[str], payload: dict) -> int
# event_type: needs_decision | task_completed | task_failed | budget_exceeded
```

- 写入 `events` 表 + `.harness/events/<ts>-<event_type>-<task_id>.json`。
- fire-and-forget 调 `hooks/notification.sh`（桌面通知 + notify.log）。
- 协调者经 `harness events pending` / `events ack` 消费（pull-on-re-engagement，见 coordinator.md §2.2）。

---

## 9. 成本闸（M10）

### 9.1 `src/harness/budget.py`

```python
from harness.budget import under_limit, today_cost, daily_limit
under_limit() -> bool           # True = 仍可派
today_cost() -> float           # 今日累计 USD
daily_limit() -> float          # 从 ~/.config/harness/config 读，默 10
```

- 日预算从 `~/.config/harness/config` 读取，超限 `notify budget_exceeded`。
- 不杀已运行 worker（防止丢工作）；只停 `db_claim` 新任务。

---

## 10. 项目初始化（M11）

### 10.1 `bin/harness init` 步骤

按序：

1. 校验当前目录是 git repo 且无 `.harness/`（防覆盖）。
2. 渲染 `templates/AGENTS.md.tmpl` → `<project>/AGENTS.md`（项目名、gate 命令占位）。
3. `ln -s AGENTS.md CLAUDE.md`。
4. 合并 `templates/settings.json.tmpl` 到 `<project>/.claude/settings.json`（已存在则提示手动 merge）。
5. 追加 `templates/gitignore-fragment` 到 `.gitignore`。
6. `mkdir -p .harness/{workers,inbox,events,logs/raw} specs`。
7. `db_init .harness/harness.db`。
8. 追加项目路径到 `~/.config/harness/projects.list`。

幂等：再次运行 → 仅修复缺失项，不覆盖人工修改的 AGENTS.md / settings.json。

---

## 11. 跨模块触发关系图

```
人/协调者                           worker                       编排器
    │                                 │                            │
    │ harness-task add                │                            │
    └─────────────────────────────────┼────tasks INSERT───────────▶│
                                      │                            │ db_claim
                                      │   adapter_call ◀───────────│
                                      │ ─ status.json ────ingest──▶│
                                      │ ─ guidance.json ──notify──▶│──▶ events/
    │◀─────────── notify ──────────── events/ ──────────────────── │
    │ answer                                                       │
    └────── inbox/<id>.answer ──────resume────────────────────────▶│
                                      │ ─ commit ─────────────────▶│ gate.sh
                                      │                            │ merge (serial)
                                      │ ◀──── notify task_completed│
```
