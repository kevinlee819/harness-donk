# 数据契约（schema）

形式化定义本系统所有持久化数据。三端（adapter / 编排器 / 协调者工具）必须同步实现；改动必须递增 `schema_version` 并同步全部代码。

当前版本：`schema_version = 1`。

---

## 1. SQLite：`<project>/.harness/harness.db`

### 1.1 启动 PRAGMA

```sql
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=ON;
PRAGMA user_version=1;          -- schema_version 等价
```

### 1.2 DDL

```sql
-- 任务主表
CREATE TABLE IF NOT EXISTS tasks (
  id            TEXT PRIMARY KEY,        -- T-XXXX，建议时间序+短哈希
  spec_path     TEXT NOT NULL,           -- 相对项目根：specs/T-0042.md
  status        TEXT NOT NULL DEFAULT 'queued'
                CHECK (status IN ('queued','dispatched','working',
                                  'gating','blocked','merged','failed')),
  worker_id     TEXT,                    -- w1 / w2 ...
  branch        TEXT,                    -- harness/T-0042
  priority      INTEGER DEFAULT 100,     -- 数越小越先派
  retries       INTEGER DEFAULT 0,       -- gate 失败回灌次数
  redispatches  INTEGER DEFAULT 0,       -- 死 worker 重派次数
  depends_on    TEXT,                    -- JSON array of task_id 或 NULL
  created       TEXT NOT NULL,           -- ISO-8601 UTC
  updated       TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tasks_status_priority ON tasks(status, priority, id);

-- 状态迁移历史（审计 + 崩溃续跑读回）
CREATE TABLE IF NOT EXISTS transitions (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id    TEXT NOT NULL REFERENCES tasks(id),
  from_state TEXT,
  to_state   TEXT NOT NULL,
  reason     TEXT,                       -- 'gate_failed' / 'worker_dead' / 'user_answered' ...
  ts         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_transitions_task ON transitions(task_id, ts);

-- 会话注册（session resume + 死 worker 检测）
CREATE TABLE IF NOT EXISTS sessions (
  task_id       TEXT NOT NULL REFERENCES tasks(id),
  backend       TEXT NOT NULL,            -- claude / codex / opencode
  session_id    TEXT,                     -- Codex 可能为 NULL（用 --last）
  resume_count  INTEGER DEFAULT 0,
  last_seen     TEXT,                     -- 摄取 status.json 时刷新
  PRIMARY KEY (task_id, backend)
);

-- 调用账（成本与可观测）
CREATE TABLE IF NOT EXISTS calls (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  ts            TEXT NOT NULL,
  task_id       TEXT NOT NULL REFERENCES tasks(id),
  worker_id     TEXT,
  backend       TEXT NOT NULL,
  session_id    TEXT,
  exit_code     INTEGER,
  cost_usd      REAL,                     -- 不可获取时 NULL
  num_turns     INTEGER,
  duration_ms   INTEGER,
  files_changed INTEGER
);
CREATE INDEX IF NOT EXISTS idx_calls_ts ON calls(ts);
CREATE INDEX IF NOT EXISTS idx_calls_task ON calls(task_id);

-- 待路由事件队列（编排器写、协调者注入器消费）
CREATE TABLE IF NOT EXISTS events (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  ts         TEXT NOT NULL,
  event_type TEXT NOT NULL                -- needs_decision/task_completed/task_failed/budget_exceeded
             CHECK (event_type IN ('needs_decision','task_completed',
                                   'task_failed','budget_exceeded')),
  task_id    TEXT REFERENCES tasks(id),
  payload    TEXT NOT NULL,               -- JSON
  delivered  INTEGER NOT NULL DEFAULT 0   -- 0/1
);
CREATE INDEX IF NOT EXISTS idx_events_pending ON events(delivered, ts);
```

### 1.3 关键查询

**原子 claim 队首任务**：

```sql
UPDATE tasks
SET status='dispatched', worker_id=:worker, updated=datetime('now')
WHERE id=(
  SELECT id FROM tasks
  WHERE status='queued'
    AND (depends_on IS NULL OR NOT EXISTS (
          SELECT 1 FROM json_each(depends_on) je
          JOIN tasks t2 ON t2.id = je.value
          WHERE t2.status != 'merged'
    ))
  ORDER BY priority, id
  LIMIT 1
)
RETURNING id, spec_path;
```

**死 worker 扫描**：

```sql
SELECT t.id, t.worker_id
FROM tasks t
JOIN sessions s ON s.task_id = t.id
WHERE t.status='working'
  AND s.last_seen < datetime('now', '-' || :threshold || ' minutes');
```

**今日成本**：

```sql
SELECT COALESCE(SUM(cost_usd), 0) FROM calls
WHERE ts >= datetime('now', 'start of day');
```

---

## 2. JSON 黑板：worker 写入

### 2.1 `<project>/.harness/workers/<worker_id>/status.json`

```json
{
  "schema_version": 1,
  "worker_id": "w1",
  "backend": "claude",
  "session_id": "01J9F8...-uuid",
  "task_id": "T-0042",
  "status": "working",
  "branch": "harness/T-0042",
  "progress": "JWT 中间件已完成，正在写测试",
  "turns": 42,
  "files_changed": 3,
  "blockers": [],
  "updated": "2026-06-12T10:15:00Z"
}
```

| 字段 | 类型 | 必填 | 取值 |
|------|------|------|------|
| `schema_version` | int | ✓ | 1 |
| `worker_id` | string | ✓ | `w1`/`w2`... |
| `backend` | string | ✓ | `claude`/`codex`/`opencode` |
| `session_id` | string | ✓ | UUID；Codex 可填 `__last__` 占位 |
| `task_id` | string | ✓ | `T-XXXX` |
| `status` | enum | ✓ | `starting`/`working`/`done`/`error` |
| `branch` | string | ✓ | 该 worker 所在分支 |
| `progress` | string | ✓ | 给人看的一句话进度，不做控制决策 |
| `turns` | int | ✓ | 当前会话累计轮次 |
| `files_changed` | int | ✓ | 当前 worktree 累计改动文件数 |
| `blockers` | array | ✓ | 软阻塞清单（不触发 BLOCKED） |
| `updated` | ISO-8601 UTC | ✓ | 每次写更新 |

**编排器如何读**：

- `status` 为 `done` → 触发 WORKING→GATING。
- `status` 为 `error` → 触发回灌或 FAILED（按 retries）。
- 每次摄取都刷新 `sessions.last_seen`。

### 2.2 `<project>/.harness/workers/<worker_id>/guidance.json`

worker 需人工/协调者决策时写。**存在即视为阻塞**。

```json
{
  "schema_version": 1,
  "blocking": true,
  "task_id": "T-0042",
  "question": "JWT 签名用 RS256 还是 HS256?",
  "context": "RS256 更安全但需密钥管理；当前项目无 KMS。",
  "options": ["RS256", "HS256"],
  "created": "2026-06-12T10:20:00Z"
}
```

| 字段 | 类型 | 必填 | 备注 |
|------|------|------|------|
| `blocking` | bool | ✓ | 仅 `true` 触发 BLOCKED；预留 `false` 作软提醒 |
| `task_id` | string | ✓ | 关联任务 |
| `question` | string | ✓ | 自然语言问题 |
| `context` | string |   | 决策背景 |
| `options` | array<string> |   | 可选答案；非空时协调者优先在此中选 |
| `created` | ISO-8601 UTC | ✓ |   |

**编排器动作**：`blocking==true` → `db_transition(task, BLOCKED)` → `notify needs_decision` → 等待 `inbox/<id>.answer` 出现。

### 2.3 `<project>/.harness/inbox/<task_id>.answer`

人或协调者写。**单行 JSON 或纯文本**：

```json
{
  "schema_version": 1,
  "task_id": "T-0042",
  "answer": "用 RS256，密钥放 .env.local，新增到 .gitignore",
  "decided_by": "user",
  "ts": "2026-06-12T10:25:00Z"
}
```

| 字段 | 类型 | 必填 | 备注 |
|------|------|------|------|
| `answer` | string | ✓ | 注入下一轮 prompt 的正文 |
| `decided_by` | enum | ✓ | `user` / `coordinator` |

**编排器动作**：摄取后删除 `guidance.json`，调 `adapter_call --resume`，将 answer 拼入 prompt：「上一次提问：<question>，决策：<answer>」。

---

## 3. 校验门报告

### 3.1 `<worktree>/.gate-report.json`

```json
{
  "schema_version": 1,
  "task_id": "T-0042",
  "ts": "2026-06-12T10:30:00Z",
  "ok": false,
  "steps": [
    {"name": "build",        "ok": true,  "duration_ms": 1200, "skipped": false, "output": ""},
    {"name": "lint",         "ok": true,  "duration_ms": 800,  "skipped": false, "output": ""},
    {"name": "test",         "ok": false, "duration_ms": 4500, "skipped": false,
     "output": "FAIL tests/auth.test.ts\n  expected 200, got 401"},
    {"name": "diff_audit",   "ok": true,  "duration_ms": 50,   "skipped": false, "output": ""},
    {"name": "cross_review", "ok": false, "duration_ms": 12000, "skipped": false,
     "output": "{\"approve\":false,\"issues\":[\"JWT 密钥硬编码\"]}"}
  ],
  "summary": "test failed + cross_review rejected"
}
```

| 字段 | 类型 | 备注 |
|------|------|------|
| `ok` | bool | 所有非 skipped 步骤 ok 才为 true |
| `steps[].name` | enum | `build`/`lint`/`test`/`diff_audit`/`cross_review` |
| `steps[].output` | string | 失败时关键摘要（不超 2KB）；全文落 `logs/raw/` |

**回灌用**：编排器读取所有 `ok==false` 步骤的 `output`，拼成 prompt：

```
上一次提交未通过校验门，需修复后重新提交：

[test] FAIL tests/auth.test.ts
  expected 200, got 401

[cross_review] 审查不通过：
  - JWT 密钥硬编码

请只修复上述问题，不要扩大改动范围。
```

---

## 4. 任务规格（spec）

### 4.1 `<project>/specs/<task_id>.md`

YAML frontmatter + Markdown body：

```markdown
---
schema_version: 1
task_id: T-0042
title: 为 /auth 端点添加 JWT 校验
backend: claude              # 可选；默认 orchestrator --backend 或 HARNESS_BACKEND（claude）
model: opus-4-7              # 可选；透传给 adapter
reviewer: codex              # 可选；覆盖 AGENTS.md 的 cross_review_reviewer
cross_review: true           # 可选 true/false；覆盖 AGENTS.md 的 cross_review_enabled
priority: 50
depends_on: []
file_scope:                  # 必填；diff_audit 据此判越界
  - src/middleware/**
  - tests/auth.test.ts
forbidden_paths:             # 可选；本任务的额外禁区（叠加全局 hooks）
  - src/billing/**
acceptance:                  # 必填；机器可校验
  - cmd: npm test -- tests/auth.test.ts
    expect_exit: 0
  - cmd: npm run lint
    expect_exit: 0
max_turns: 12
max_retries: 3
---

## 背景
...

## 期望行为
...

## 验收清单（人读版，与 acceptance 等价）
- [ ] /auth/login 返回 200 + Set-Cookie
- [ ] 无 token 访问受保护端点返回 401
```

**协调者入队前检查**：

- `file_scope` 非空。
- `acceptance` 至少 1 条且全部带 `cmd`。
- `depends_on` 中所有 task_id 均存在。
- spec body 中所有 `[ ]` 验收项都有对应 `acceptance` 命令覆盖。

---

## 5. 调用日志：`logs/raw/`

文件名：`<unix_ts>-<task_id>-<backend>-<seq>.json`

内容：adapter 收到的原始 backend 输出（Claude JSON / Codex NDJSON 聚合后 / OpenCode JSON），加上 envelope：

```json
{
  "schema_version": 1,
  "ts": "2026-06-12T10:15:00Z",
  "task_id": "T-0042",
  "worker_id": "w1",
  "backend": "claude",
  "request": {
    "prompt_path": ".harness/prompts/T-0042-1.txt",
    "session_id": null,
    "max_turns": 12
  },
  "response": { ... 原始 backend 输出 ... }
}
```

排障专用，不进库；保留 30 天后由 `harness gc` 清理。

---

## 6. 全局配置：`~/.config/harness/config`

INI / 简化 KV：

```ini
budget_daily_usd = 10.00
notify_channel   = tmux      # tmux / desktop / webhook
session_resume_cap = 6
dead_worker_minutes = 10
max_concurrent_workers = 1    # 阶段四前固定 1
```

`~/.config/harness/projects.list`：每行一个项目绝对路径。

---

## 7. schema 升级流程

### 7.1 文件布局

```
schema/
├── harness.sql                            # base schema：全新安装跑这个
└── migrations/
    ├── README.md                          # 本流程速查
    └── V<N>__<short_description>.sql      # 增量迁移；N = 目标 user_version
```

### 7.2 加新列 / 新表的流程（举例：给 tasks 加 tags 列）

1. **base schema 同步**：在 `schema/harness.sql` 的 `CREATE TABLE tasks` 里加 `tags TEXT,` 字段。`CREATE TABLE IF NOT EXISTS` 对已存在的表是 no-op；这一改只影响**全新安装**。
2. **写迁移文件**：`schema/migrations/V2__add_tasks_tags_column.sql`：
   ```sql
   ALTER TABLE tasks ADD COLUMN tags TEXT;
   ```
   不要在迁移文件里写 `PRAGMA user_version=2`——迁移 runner 会自动设置。
3. **改 SCHEMA_VERSION**：`src/harness/db.py` 顶端 `SCHEMA_VERSION = 2`。
4. **同步 base SQL 顶端 PRAGMA**：`schema/harness.sql` 把 `PRAGMA user_version=1` 改为 `=2`。
5. **三端代码同步改**（碰新字段的）：`db.py`、`db_cli.py`、`adapter` 落日志格式、`coordinator-tool` 用法。
6. **本机自测**：把旧 `.harness/harness.db`（user_version=1）跑一次 `harness init` 或重启 orchestrator——`init()` 应自动跑 V2 迁移。
7. **commit**：base SQL + V2 文件 + SCHEMA_VERSION 改动同一个 commit。

### 7.3 不删旧字段

- 兼容回退（如果新版有问题，可以 `git revert` 让旧代码读老 DB）。
- 历史 backup（`.harness/backups/harness-*.db`）仍可读。
- 真要删，等数据迁完 + 跨越一个稳定大版本之后单独做 deprecation。

### 7.4 runner 行为（`db._apply_migrations`）

- 扫 `schema/migrations/V*.sql`，按 N 升序。
- 仅对 `current_user_version < N <= SCHEMA_VERSION` 范围执行。
- 每应用一份 → `PRAGMA user_version=N` 立即落，下次启动接着续。
- 全新安装：`base SQL` 直接把 user_version 设到当前 SCHEMA_VERSION → runner 看 current==target，no-op。
- 失败：抛出原 sqlite3 异常，不偷偷吞——上游 `init()` 会向 caller 报错。

测试覆盖：`tests/unit/test_db.py::test_apply_migrations_*`（4 case），含目录缺失、已应用跳过、超目标版本忽略。
