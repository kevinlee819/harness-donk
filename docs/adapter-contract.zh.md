# Adapter 合同：接入新 backend

本文档定义把一个新 CLI（或经兼容端点挂入的新模型）接入 harness 执行平面的合同。

**两条轴勿混淆**：

- **新模型**（DeepSeek、Kimi、Qwen 等）通常 ≠ 新 CLI。首选经 OpenAI/Anthropic 兼容端点挂入 OpenCode（provider 配置加 baseURL + key + 模型名），**harness 与 adapter 零改动**，spec 中以 `backend: opencode, model: <name>` 指定。
- **新 CLI**（独立工具，例如 Aider、Continue CLI、自研 agent runner）才需走本文档的 adapter 接入合同。

---

## 1. 硬门槛（三选三，缺一不接）

| 能力 | 验证方式 | 缺失时 |
|------|---------|--------|
| 1. 非交互模式 | 无 TTY 下 `cli <cmd> < prompt.txt > out` 能完成并退出 | **不接** |
| 2. 退出码语义 | 成功 0、失败非零 | **不接**（若输出可判但码乱可降级，需 PR review） |
| 3. 可解析输出 | `--json` 单对象 或 NDJSON 事件流 | **不接**（无结构化输出 = 没法机器读） |

---

## 2. 软门槛（缺失走能力位图降级）

| 能力 | 验证 | 降级 |
|------|------|------|
| 4. 会话续接 | `--resume <id>` / `--session <id>` / `--last`；ID 可程序化获取 | 仅派**单发**任务；BLOCKED 后重发完整上下文 |
| 5. 工具权限控制 | allowlist / 沙箱 / 审批模式 | 仅靠 worktree 隔离 + gate 兜底，**禁触敏感仓库** |
| 6. 成本数据 | 输出含 cost / token usage | `calls.cost_usd` 写 NULL，预算闸按调用次数估算 |

每个 backend 在 `adapters/<name>.sh` 顶部声明能力位图：

```bash
# capability bitmap
ADAPTER_CAP_SESSION_RESUME=1
ADAPTER_CAP_SESSION_ID_PROGRAMMATIC=1    # Claude / Codex 0.142+ / OpenCode: 1
ADAPTER_CAP_TOOL_PERMISSION=1
ADAPTER_CAP_COST_REPORT=1                # Codex: 0（只有 token usage 无 USD）
ADAPTER_PARALLEL_PER_WORKTREE=0          # Codex: 0（git index 竞争，必须串行）
```

编排器据此限制可派任务类型、决定是否加 flock。

---

## 3. Adapter 必须做的归一化

adapter 是一段 bash 脚本，**唯一入口** `adapters/<name>.sh`，**接口**见 [interfaces.md §4](interfaces.md#4-后端适配器m4--adapter-合同)。这里聚焦实现侧要求。

### 3.1 输入约束

- 提示词只从文件读：`cat "$ADAPTER_TASK_FILE"`。
- **禁止**把提示词内容内联进命令行（含引号/`$`/反引号/换行会爆）。
- 续接：`ADAPTER_SESSION_ID` 非空 → 加 `--resume "$SID"`（或 backend 等价）；为空 → 首发。
- 双重上限：外层 `timeout "$ADAPTER_TIMEOUT"` 包住整个 CLI 调用，CLI 内层用 `--max-turns "$ADAPTER_MAX_TURNS"`（或等价）。

### 3.2 输出归一化

无论 backend 原生输出格式如何，adapter 必须 stdout 输出**单行 JSON**：

```json
{
  "ok": true|false,
  "session_id": "string|null",
  "result": "string (自然语言摘要，仅给人/排障)",
  "cost_usd": 0.0,
  "num_turns": 0,
  "files_changed": 0,
  "error": null|"string"
}
```

- `ok=false` 时 `error` 必填，简述失败原因（如 "rate_limited" / "context_window_exceeded" / "tool_denied"）。
- `cost_usd` / `num_turns` 若 backend 不报，填 `null`。
- `files_changed` 由 adapter 在工作目录跑 `git diff --name-only HEAD | wc -l` 得到（adapter 兜底而非依赖 backend）。

### 3.3 副作用

| 必做 | 说明 |
|------|------|
| 原始输出落盘 | `<project>/.harness/logs/raw/<ts>-<task_id>-<backend>-<seq>.json` 含 envelope（见 [data-schemas.md §5](data-schemas.md#5-调用日志logsraw)）|
| 错误优先检 | 解析输出后**先检 `.is_error` / `.error` 再用 `.result`** — 失败往往仍是合法 JSON |
| stderr 不污染 stdout | 调试信息全走 stderr；stdout 必须**只有那一行 JSON** |
| flock（如需） | `ADAPTER_PARALLEL_PER_WORKTREE=0` 的 backend 在 `$ADAPTER_WORKTREE/.adapter.lock` 上 flock，串行化同 worktree 调用 |

---

## 4. 接入流程（典型 4 小时）

### 4.1 编写 `adapters/<name>.sh` 骨架

```bash
#!/usr/bin/env bash
set -euo pipefail

ADAPTER_CAP_SESSION_RESUME=1
ADAPTER_CAP_SESSION_ID_PROGRAMMATIC=1
ADAPTER_CAP_TOOL_PERMISSION=1
ADAPTER_CAP_COST_REPORT=1
ADAPTER_PARALLEL_PER_WORKTREE=1

: "${ADAPTER_TASK_FILE:?}"
: "${ADAPTER_WORKTREE:?}"
ADAPTER_SESSION_ID="${ADAPTER_SESSION_ID:-}"
ADAPTER_MAX_TURNS="${ADAPTER_MAX_TURNS:-12}"
ADAPTER_TIMEOUT="${ADAPTER_TIMEOUT:-900}"

cd "$ADAPTER_WORKTREE"

# flock 若需要
[[ "$ADAPTER_PARALLEL_PER_WORKTREE" == "0" ]] && exec 9>.adapter.lock && flock 9

# 调 backend
if [[ -n "$ADAPTER_SESSION_ID" ]]; then
  RESP=$(timeout "$ADAPTER_TIMEOUT" \
    your_cli --resume "$ADAPTER_SESSION_ID" --max-turns "$ADAPTER_MAX_TURNS" \
             --json < "$ADAPTER_TASK_FILE" 2>"$ADAPTER_WORKTREE/.adapter.stderr")
else
  RESP=$(timeout "$ADAPTER_TIMEOUT" \
    your_cli --max-turns "$ADAPTER_MAX_TURNS" --json < "$ADAPTER_TASK_FILE" \
             2>"$ADAPTER_WORKTREE/.adapter.stderr")
fi
EXIT=$?

# 落盘原始
TS=$(date -u +%Y%m%dT%H%M%SZ)
LOG_DIR="$(git rev-parse --show-toplevel)/../.harness/logs/raw"  # 据实际路径修正
mkdir -p "$LOG_DIR"
jq -n --arg ts "$TS" --argjson resp "$RESP" \
  '{schema_version:1, ts:$ts, backend:"<name>", response:$resp}' \
  > "$LOG_DIR/$TS-<...>.json"

# 错误优先
IS_ERR=$(echo "$RESP" | jq -r '.is_error // false')
if [[ "$IS_ERR" == "true" || $EXIT -ne 0 ]]; then
  echo "$RESP" | jq -c '{ok:false, session_id:.session_id, result:"", \
    cost_usd:null, num_turns:null, files_changed:0, error:(.error // "exit_'"$EXIT"'")}'
  exit 0
fi

FILES_CHANGED=$(git diff --name-only HEAD 2>/dev/null | wc -l | tr -d ' ')

echo "$RESP" | jq -c --argjson fc "$FILES_CHANGED" \
  '{ok:true, session_id:.session_id, result:.result, \
    cost_usd:.cost_usd, num_turns:.num_turns, files_changed:$fc, error:null}'
```

### 4.2 自检 — `harness doctor` 增加该 backend

```bash
# tests/integration/adapter_<name>_doctor.sh
echo "say hello in 5 words" > /tmp/p.txt
ADAPTER_TASK_FILE=/tmp/p.txt ADAPTER_WORKTREE=/tmp ADAPTER_TIMEOUT=60 \
  bash adapters/<name>.sh | jq -e '.ok == true and (.result | length > 0)'
```

### 4.3 跨模型审查冒烟（如能力允许）

```bash
# 故意 buggy diff
git diff HEAD > /tmp/diff.patch
echo "Review this diff. Output JSON {approve: bool, issues: [...]}." | \
  cat - /tmp/diff.patch > /tmp/p.txt
ADAPTER_TASK_FILE=/tmp/p.txt ADAPTER_WORKTREE=/tmp/wt bash adapters/<name>.sh \
  | jq -r .result | jq -e '.approve | type == "boolean"'
```

通过即可作为 reviewer 候选写入 `AGENTS.md` 的 `gate.cross_review.reviewer`。

---

## 5. 数据边界

接入第三方/境外模型必须评估：

- 默认**仅用于开源与数据分级允许的项目**。
- `<project>/AGENTS.md` 必须显式列出允许的 backend/model 白名单；gate 的 `diff_audit` 步骤强制检查任务 spec 的 `backend` 字段在白名单内。
- 含 PII / 内部秘密的仓库：白名单仅留本地或同信任域 backend。

---

## 6. 已接入参考

| Backend | adapter | 能力位图特点 | 已知坑 |
|---------|---------|------------|--------|
| Claude Code | `claude.sh` | 全 ✓ | UUID 必须合法格式；review 模式（ADAPTER_SANDBOX=read-only）用 `--tools "Read,Grep,Glob" --no-session-persistence --json-schema <schema>`；写模式必须 `--permission-mode bypassPermissions`（非交互会卡权限弹窗） |
| Codex | `codex.sh` | `COST_REPORT=0`, `PARALLEL_PER_WORKTREE=0` | mkdir lock + thread_id 从 thread.started 事件取（0.142+）；NDJSON 需聚合；`-C` 必须先于 `resume` 子命令；`-a` 不能传给 exec（headless 默认 Never）；**绝不**用 `--dangerously-bypass-approvals-and-sandbox`（会强制 DangerFullAccess 覆盖 `-s`） |
| OpenCode | `opencode.sh` | 全 ✓ | 用 `opencode run` CLI 路径；**避开** serve 模式（子 agent 挂死历史问题） |

新接入完成后，在本表追加一行并提交 PR。
