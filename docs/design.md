# 多 Agent 自驱动编码 Harness 设计文档



## 1. 背景与目标

本系统是一套个人工作流级别的自动化编码 harness。它对用户只暴露**一个入口命令**,该命令启动一个被武装为"协调者"的 Claude Code 会话作为唯一对话面;协调者在后台把编码任务分发给多个 CLI 执行 agent(Codex、OpenCode 等),通过确定性校验门验证其工作,形成可长时间无人值守运行的自驱动闭环。用户只与协调者对话,协调者只在必要时打扰用户。

设计目标按优先级:

1. **单一入口、上下文归我所有**:用户只面对一个对话面;会话、任务、成本、产物的上下文全部由本系统持有和管理,而非散落在被调用的引擎里。
2. **自驱动**:任务从队列进入,经派发、执行、校验、合并自动流转;失败自动回灌重试;只在真正需要决策时升级到人。
3. **按需打扰、随时可观测**:协调者默认沉默,只在需要决策、验收、故障时主动找用户;用户想了解进展时,任务状态与每个 agent 的工作随时可查。
4. **可靠**:任何进程在任何时刻崩溃,系统状态不丢、不脏,可从磁盘恢复续跑。
5. **可控**:危险操作被确定性拦截(非靠提示词约束);变更合并前可审查;成本有硬性预算闸。
6. **简单**:bash + 标准 Unix 工具(jq、sqlite3、tmux)实现,无需常驻服务或专用协议;单机运行。

非目标:跨机器分布式编排、对等 agent 网络(A2A)、通用多租户平台。需求出现前不做。

## 2. 核心设计原则

**原则一:统一入口持有上下文。** 用户永远不直接使用底层引擎(不裸跑 `claude`)。入口命令启动一个协调者会话作为唯一对话面;session、成本、产物的账本由本系统记录在项目的 `.harness/` 中。放弃上下文所有权,本系统即名存实亡——这是不可妥协的分界线。

**原则二:聪明的判断与确定的执行分离。** 协调者(LLM)只负责判断与决策:拆解任务、决定派什么给谁、判读结果、决定是否升级到人。真正的进程驱动由确定性的 dumb loop + adapter 承担。协调者通过我们提供的**脚本工具**下达指令(本质是写任务进队列),绝不自己用 send-keys 去驱动别的 agent。

**原则三:CLI 即协议。** 调用任何执行 agent 都不使用专用协议,就是 Unix 子进程:提示词从 stdin/文件进,JSON 从 stdout 出,退出码表示成败。一次调用是"一份任务简报"而非"一轮对话"——agent 在调用内部自主运行多轮 think→工具→观察直到完成或达上限。

**原则四:文件、git、嵌入式 SQLite 即媒介。** Agent 间不靠内存或网络通信。状态按受众分层:**面向 agent 与人的交互界面是文件**(spec、status、guidance、inbox);**编排器私有的事务性状态是 SQLite**(队列、状态机、迁移史、会话注册、成本账)。代码成果以 git commit 落盘。状态只活在磁盘,崩溃恢复天然成立。

**原则五:进程临时、对话持久。** 每轮交互是独立短命进程调用,通过 session ID(`--resume`)共享对话历史。会话续接有上限,达上限后 checkpoint 落盘、开新会话(新鲜上下文,防长会话走形)。

**原则六:生成者与裁判分离。** 写代码的 agent 不能自我宣告完成。完成与否由外部裁判判定:确定性门(测试/lint/类型/构建)为第一层,跨模型对抗审查为第二层。"完成"是机器可校验的标准。

**原则七:确定性约束放 hooks,不放提示词。** 禁 force push、禁改敏感目录、未过门不许停——硬约束全部用 hooks 在工具执行关口确定性拦截。

**原则八:控制面与数据面分离。** tmux 只承担控制/观测面(持久会话、随时观察、断连存活),绝不承担数据面。机器读取的数据走结构化接口(JSON + 黑板),绝不用 capture-pane 刮屏解析有结构化输出的 agent。

## 3. 双平面架构

系统由两个职责分明的平面构成,各有独立的可见性策略。

```
┌────────────────────── 对话平面(用户主入口)───────────────────────┐
│                                                                    │
│  用户 ⇄ 协调者会话(harness-infi 启动的 Claude Code,武装为 coordinator) │
│        · 持有与用户的对话与上下文                                   │
│        · 默认沉默,仅在 需决策/待验收/故障 时主动打扰用户           │
│        · 通过脚本工具下达指令(写任务进队列),不自己驱动执行 agent │
│                                                                    │
└──────────────────────────────┬───────────────────────────────────┘
                                │ 脚本工具(harness-task add / query …)
                                ▼  写入 .harness/harness.db(任务队列)
┌────────────────────── 执行平面(后台车间)─────────────────────────┐
│                                                                    │
│  orchestrator.sh(dumb loop,确定性驱动)                           │
│    取任务→建 worktree→经 adapter 调执行 agent→轮询黑板→校验门→合并  │
│                                                                    │
│  执行 agent:Claude Code(主力)/ Codex / OpenCode(并行·备用·审查) │
│    各自在独立 tmux pane + 独立 git worktree;默认隐藏,随时可观测   │
│                                                                    │
└──────────────────────────────┬───────────────────────────────────┘
                                ▼
      共享底座:AGENTS.md(规约)· .harness/harness.db(真相)· git(代码交接)
```

### 3.1 对话平面

用户的唯一对话面。`harness-infi` 在一个 tmux 会话里,以协调者配置(专属 system prompt / AGENTS.md / 工具集)启动一个交互式 Claude Code 会话。该会话即"主协调 agent":

- 持有与用户的全部对话上下文;享受 Claude Code 原生交互体验(我们不重做 TUI)。
- 它的工具不是写代码,而是:拆任务、调用脚本工具入队、查询黑板看进展、判读校验报告、决定何时升级到人。
- **打扰策略**:默认沉默。仅在三类时刻经 Notification 主动开口——① 需要用户决策(guidance);② 任务完成待验收;③ 出现它无法自行解决的故障。
- 因为是交互式会话(非 `claude -p` 程序化调用),走用户**订阅额度**。

### 3.2 执行平面

协调者看不见过程、只看结果的后台车间,对用户默认隐藏。

- **orchestrator.sh**:确定性 dumb loop,是任务的真正执行驱动者。智能不在它身上,全在协调者的决策与校验门的反馈回路里。
- **执行 agent**:Claude Code 主力,Codex / OpenCode 用于并行、备用模型、跨模型审查。每个执行 agent 在独立 worktree 的独立分支工作,永不接触主分支;其进程展示在 tmux pane 中(仅供观测,非驱动)。
- 执行平面的 agent 调用是程序化的(`claude -p` 等),走**程序化额度**(API 计价)。

两平面的计费天然分离:高频对话走订阅、批量执行走程序化额度,分别可控。

### 3.3 调度机制:协调者如何指挥执行平面(方案 a)

协调者**不直接驱动**执行 agent。它只通过脚本工具表达意图,真正的进程编排由 dumb loop 完成:

1. 协调者判断需要做某任务 → 调脚本工具 `harness-task add <spec>`(本质:向 `.harness/harness.db` 的 tasks 表 INSERT 一行)。
2. orchestrator.sh 的循环独立运行,取到该任务 → 建 worktree → 经 adapter 调执行 agent → 跑校验门 → 合并或回灌。
3. 协调者随时调 `harness-task query` 读黑板了解进展;任务终态(完成/失败/阻塞)经 Notification 回到协调者,由它决定是否、如何告知用户。

如此:**聪明的部分(协调者)只做判断,确定的部分(dumb loop + adapter)做执行**,职责不混;且执行平面可独立于对话平面运行(协调者会话关掉,后台任务照跑)。

## 4. 通信机制(数据面)

### 4.1 调用与会话:session resume + JSON

三个后端会话能力不对称,必须经 adapter 归一化,编排逻辑不接触原生格式。

**Claude Code(adapter: claude.sh)**

```bash
RESP=$(timeout 900 claude -p "$(cat "$TASK_FILE")" --output-format json --max-turns 12)
SID=$(echo "$RESP" | jq -r '.session_id')
RESP=$(timeout 900 claude -p "$(cat "$FOLLOWUP")" --resume "$SID" --output-format json --max-turns 8)
```

session_id 可程序化获取并记账;`--output-format json` 取 `.result`(给人)与 `.session_id`/`.cost_usd`/`.num_turns`(给机器);自定义 session ID 须为合法 UUID。

**Codex(adapter: codex.sh)**

```bash
codex exec "$(cat "$TASK_FILE")" --json
codex exec resume --last "$(cat "$FOLLOWUP")" --json
```

硬约束:Codex 无法程序化获取当前 session ID,只能依赖按工作目录划分的 `--last`。故规定:**每个 worktree 同时最多一个 Codex 会话,且对该 worktree 的 Codex 调用必须串行**。其 `--json` 为 NDJSON 事件流,adapter 聚合为单结果对象;会话以 JSONL 落盘 `~/.codex/sessions/`,可作审计。

**OpenCode(adapter: opencode.sh)**

```bash
opencode run "$(cat "$TASK_FILE")" --session "$SESSION_ID" --json
```

### 4.2 黑板:文件层(agent/人界面)+ SQLite 层(编排器真相)

文件层是 agent→编排器、人→编排器的写入界面;SQLite 层(`.harness/harness.db`)是编排器决策的唯一真相。worker 原子写自己的 `status.json`,编排器轮询时**摄取**进库——文件是 API,数据库是状态,不构成双真相。

文件层两个核心 schema:

**workers/<id>/status.json**(worker 独占写)

```json
{
  "schema_version": 1, "worker_id": "w1", "backend": "claude",
  "session_id": "uuid-...", "status": "working", "task_id": "T-042",
  "branch": "harness/T-042", "progress": "JWT 中间件已完成,正在写测试",
  "turns": 42, "blockers": [], "updated": "2026-06-12T10:15:00Z"
}
```

**workers/<id>/guidance.json**(worker 需决策时写,升级触发器)

```json
{
  "schema_version": 1, "blocking": true,
  "question": "JWT 签名用 RS256 还是 HS256?",
  "context": "RS256 更安全但需密钥管理", "created": "2026-06-12T10:20:00Z"
}
```

升级路径:编排器轮询到 `blocking: true` → 写入待决策事件 → 经 Notification 上抛给协调者 → 协调者按打扰策略决定是否问用户 → 用户/协调者的答复写入 `inbox/<id>.answer` → 编排器用保留的 session_id `--resume` 续接原上下文。这就是"agent 及时提示主入口确认变更"的完整实现。

**SQLite 层 schema 草案**(`.harness/harness.db`):

```sql
CREATE TABLE tasks (
  id TEXT PRIMARY KEY, spec_path TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued',   -- queued/dispatched/working/gating/blocked/merged/failed
  worker_id TEXT, branch TEXT, priority INTEGER DEFAULT 100,
  retries INTEGER DEFAULT 0, redispatches INTEGER DEFAULT 0,
  created TEXT NOT NULL, updated TEXT NOT NULL
);
CREATE TABLE transitions (
  id INTEGER PRIMARY KEY, task_id TEXT NOT NULL,
  from_state TEXT, to_state TEXT NOT NULL, reason TEXT, ts TEXT NOT NULL
);
CREATE TABLE sessions (
  task_id TEXT NOT NULL, backend TEXT NOT NULL,
  session_id TEXT, resume_count INTEGER DEFAULT 0, last_seen TEXT
);
CREATE TABLE calls (
  id INTEGER PRIMARY KEY, ts TEXT, task_id TEXT, worker_id TEXT, backend TEXT,
  session_id TEXT, exit_code INTEGER, cost_usd REAL, num_turns INTEGER,
  duration_ms INTEGER, files_changed INTEGER
);
```

原子 claim(取任务并标记派发,一条语句无竞态):

```bash
sqlite3 .harness/harness.db "UPDATE tasks
  SET status='dispatched', worker_id='$W', updated=datetime('now')
  WHERE id=(SELECT id FROM tasks WHERE status='queued' ORDER BY priority, id LIMIT 1)
  RETURNING id, spec_path;"
```

### 4.3 hooks:事件与强制层

配置于项目 `.claude/settings.json`:

1. **PreToolUse = 确定性安全门**。matcher `Bash`,检查 `tool_input.command`,命中危险模式 exit 2 拦截。拦截原因必须写 stderr(写 stdout 模型收不到反馈)。
2. **Stop = 完成度强制**。校验清单未全绿即 exit 2 / `decision:"block"`,迫使 agent 继续——任务内自驱动由此内建。
3. **Notification = 信号线**。事件路由到协调者 / 通知渠道,免去空转轮询。

禁令:硬策略不得用 HTTP hook(非 2xx 为非阻塞错误,网络抖动即旁路安全门),一律用 command hook。

## 5. 任务状态机

每个任务的生命周期由如下状态机管理,当前状态与全部迁移历史持久化于 `.harness/harness.db`(`tasks` 与 `transitions` 表),每次迁移以单事务先落库再行动(崩溃后从库读回继续):

```
 QUEUED ──派发──▶ DISPATCHED ──▶ WORKING ──▶ GATING ──全绿──▶ MERGED(终态)
                                  │  ▲          │
                  guidance 阻塞    │  │          │ 未过:错误回灌,重试+1
                                  ▼  │          ▼
                               BLOCKED ◀──    WORKING(带报错重跑)
                              (待人工答复)
                                                │ timeout / 重试耗尽 / 重派耗尽
                                                ▼
                                             FAILED(终态,通知协调者)
```

迁移规则:

- QUEUED→DISPATCHED:编排器原子 claim 队首任务,`git worktree add`,经 adapter 发起首轮调用并登记 session_id。
- WORKING→GATING:worker 的 status.json 报告 `done`,或其进程正常退出且工作区有 commit。
- GATING→WORKING(回灌):任一门未过。编排器把失败输出(测试报错、lint、审查意见)拼为后续提示,`--resume` 续接重跑;`retries += 1`,有上限(默认 3)。
- WORKING→BLOCKED:轮询到 `guidance.json { blocking: true }`。BLOCKED→WORKING:inbox 出现答案文件,resume 续接。
- 任意态→FAILED:墙钟 timeout 被杀且重派耗尽,或重试上限耗尽。FAILED 必经 Notification 上抛协调者。
- **死 worker 检测**(图中未画但必须实现):摄取 status.json 时刷新 `sessions.last_seen`;一条 SQL 筛出超阈值(默认 10 分钟)仍 `working` 的任务,判定 worker 已死;退回 QUEUED 重派(优先用 `sessions` 表保留的 session_id 续接,否则新会话 + 从其分支已有 commit 接续)。重派次数独立封顶(默认 2,`tasks.redispatches`)。
- MERGED:编排器(且只有编排器)串行执行合并,合并后 `git worktree remove` 回收,经 Notification 上抛"待验收"。

## 6. 部署模型与目录布局:工具与项目严格分离

心智模型是 **git**:程序全局安装一份,每个项目只持有自己的状态目录(`.harness/`,类比 `.git/`)。**harness 的代码永远不被复制进任何项目**;项目仓库里只出现声明式内容——AGENTS.md、specs/、hooks 配置(进 git),以及运行时状态 `.harness/`(整体 gitignore)。升级 harness = 在工具目录 git pull,所有项目即刻生效。

文件所有权遵循单写者原则:**任何文件有且只有一个写者**;`harness.db` 为编排器独占写,并发由 SQLite 事务(WAL)保证。

```
~/tools/harness/                  # ① 工具本体(装一次,bin/ 进 PATH,永不复制)
├── bin/
│   ├── harness-infi              #    入口命令:以协调者配置启动 Claude Code 会话
│   └── harness                   #    管理/观测命令(status / attach / stop …)
├── orchestrator.sh               #    执行平面 dumb loop
├── coordinator/                  #    协调者武装:system prompt、AGENTS 片段、脚本工具
│   ├── tools/harness-task        #      协调者可调:add / query(读写 harness.db)
│   └── coordinator.md            #      协调者角色与打扰策略提示
├── adapters/                     #    claude.sh / codex.sh / opencode.sh
├── lib/                          #    atomic_write.sh / gate.sh / budget.sh
└── templates/                    #    AGENTS.md 模板、hooks 模板、gitignore 片段

~/.config/harness/                # ② 全局配置(每台机器一份)
├── config                        #    全局日预算、通知渠道凭据
└── projects.list                 #    已接管项目注册表(全局预算聚合、harness ls)

<project>/                        # ③ 任一被接管的项目(纯净:只有自己的代码)
├── src/  tests/  Makefile        #    项目自身代码
├── AGENTS.md                     #    全 agent 共享规约(进 git)
├── CLAUDE.md → AGENTS.md         #    软链(进 git)
├── .claude/settings.json         #    hooks(进 git,团队共享安全门)
├── specs/<task_id>.md            #    任务规格(进 git:AI 做过什么即项目历史)
└── .harness/                     #    运行时状态(整体 gitignore,删项目即随之消失)
    ├── harness.db                #    本项目队列/状态机/迁移史/会话/成本账
    ├── workers/<id>/{status,guidance}.json   # worker 独占写
    ├── inbox/<id>.answer         #    人/协调者独占写
    └── logs/raw/                 #    原始调用 JSON 留档

<project 同级>/.worktrees/<project>/<task_id>/   # ④ worktree 置于项目外兄弟目录
                                  #    避免嵌入主工作区搅浑 git status
```

全局预算闸由 `bin/harness` 按 `projects.list` 聚合各项目 `calls` 表实现;API 控制台 spend limit 作最后兜底。

## 7. 工程约束(实现必须遵守)

### 7.1 进程与会话边界

- 每次执行 agent 调用必须双重上限:外层 `timeout`(墙钟,默认 900s)+ 内层 `--max-turns`(默认 12)。无例外。
- 会话续接封顶:同一 session 续接达 N 轮(默认 6)或接近上下文窗口,强制 checkpoint(进度写黑板、代码 commit),开新会话从磁盘接续。
- 每次调用默认视为"可能失败":可能被 timeout 杀、OOM、半途崩。退出码 0 ≠ 任务完成。**真相 = 黑板 + git diff + 校验门,永远不是 CLI 返回值。**
- 续接 token 成本随轮数增加 30–50%,独立任务优先单次调用而非续接。

### 7.2 通信契约

- 每个后端一个 adapter,把 `json` / `stream-json` / Codex NDJSON 归一化为统一内部结构 `{ok, session_id, result, cost_usd, num_turns, error}`;编排逻辑不接触原生格式。
- 先检错误字段再用结果:失败调用往往仍是合法 JSON(`.is_error` / `.error`)。
- **绝不解析模型自然语言输出(`.result`)做控制决策**;机器读的控制信号一律来自指示 agent 写的黑板结构化文件。
- 提示词一律走 stdin 或文件,禁止把含引号/`$`/反引号/换行的文本内联拼进命令行。

### 7.3 状态层并发安全

文件层(worker/人写入):

- 原子写:所有 JSON 写 `*.tmp` 后 `mv` 替换,禁止原地写。
- 单写者(见第 6 节);所有 schema 带 `schema_version` 读时校验,带 `updated` 时间戳供 stale 检测。

SQLite 层(编排器独占写):

- 建库 `PRAGMA journal_mode=WAL;`,每次连接 `PRAGMA busy_timeout=5000;`——读不阻塞写,偶发并发自动重试。
- 数据库文件必须在本地文件系统,**严禁 NFS/网络盘**(WAL 共享内存机制在网络文件系统上不可靠)。
- 每操作一次 `sqlite3 db "..."` 短连接短事务;禁止长事务。
- 依赖 `RETURNING`(SQLite ≥ 3.35),启动时校验版本。
- 备份:`sqlite3 .harness/harness.db ".backup ..."`,随合并节点定期执行。
- 禁止 agent 直接拼 SQL 写库(转义/注入对 LLM 是高发故障面);agent 只写 JSON 文件,由编排器摄取。协调者经 `harness-task` 脚本(参数化)读写,不直接碰 SQL。

### 7.4 隔离与合并

- 一任务一 worktree 一分支;源仓库与主分支对 worker 只读。worktree 置于项目外兄弟目录。
- 合并是编排器专属职责且严格串行,仅在校验门全绿后执行;worker 禁止 merge / push 主分支。
- worktree 用毕即 `git worktree remove`;reaper 定期清理孤儿 worktree。
- 并行任务拆分须无依赖(任务 B 不 import 任务 A 尚未创建的产物),拆分质量由协调者/人在入队前把关。

### 7.5 hooks 强制层

- PreToolUse 安全门拦截清单(初始):`push --force`、`rm -rf` 于 worktree 外、写 `.harness/` 中非本 worker 目录、读写含 `prod`/`secret` 路径、`git merge`/`git push` 主分支。
- 拦截输出 stderr + exit 2;常见错误是写 stdout 导致模型收不到反馈。
- Stop hook 检查任务清单与门状态,未完成即 block。
- 硬策略只用 command hook,不用 HTTP hook。

### 7.6 成本与可观测

- 每次调用 INSERT 一行 `calls` 表;原始 JSON 另存 `logs/raw/` 排障。
- 预算闸即 SQL:`SELECT COALESCE(SUM(cost_usd),0) FROM calls WHERE ts >= date('now');` 与日预算比较,超限即 kill switch 停止派发并通知协调者。
- 对话平面走订阅、执行平面走程序化额度(2026-06-15 起按 API 价单独计费);为执行平面配独立 API key,启用 prompt caching 摊薄反复重发的系统提示/文件上下文。

### 7.7 安全基线

- 生产凭证与 harness 运行环境物理隔离;agent 可达环境变量白名单化。
- 主分支保护用服务端规则,不依赖本地 hook;合并入主分支前最后一道始终是确定性 CI。
- 第三方技能/插件视同陌生 npm 包,运行前审计源码。
- 自动循环必产生大 diff,传统逐行审查失效;以 pre-commit、属性测试、自动化流水线工程机制兜底。

## 8. 校验门(gate.sh)规格

按序执行,任一失败即返回非零并输出结构化失败报告(供回灌):

1. **构建/类型检查**(如适用):`tsc --noEmit` / `mypy` / `cargo check`。
2. **Lint**:项目既有 linter,零容忍新增告警。
3. **测试**:全量或受影响子集;TDD 风格任务要求 spec 中先列明应通过的测试。
4. **diff 静态审计**:改动是否越出 spec 声明的文件范围、是否触碰禁区路径。
5. **跨模型审查**(可配置开关):将 `git diff` 喂给另一后端(Claude 写→Codex 审,反之亦然),审查 agent 输出结构化判定 `{approve: bool, issues: []}`;不批准则 issues 作回灌材料。

门的输出全部落盘于该任务 worktree 根的 `.gate-report.json`,作为回灌提示与人工抽查依据。

## 9. 渐进落地路线

- **阶段一(第 1 周)· 入口 + 单 agent + 校验门**:实现 `harness-infi`(以协调者配置启动 Claude Code)与 `harness-task` 脚本工具;orchestrator 仅支持单 backend(Claude)、单 worker;写好 AGENTS.md、gate.sh、hooks 安全门。协调者能把对话中明确的任务入队、dumb loop 执行并过门;人盯每次运行,打磨 spec 写法。验收:连续 5 个真实小任务一次过门率 ≥ 60%。
- **阶段二(第 2 周)· 闭环与崩溃恢复**:补齐状态机、错误回灌、重试/重派上限、死 worker 检测、Notification 打扰策略。开始"睡前交代、早上验收"。验收:kill -9 编排器后重启可正确续跑(SQLite 事务保证无半截中间态)。
- **阶段三(第 3 周)· 跨模型审查**:引入 Codex/OpenCode 作裁判(先做审查,不做并行编写——价值更高、风险更低)。
- **阶段四 · 并行 worktree**:多 worker 并行;前提是任务拆分质量已验证。逐步降低人工介入点。

## 10. 使用手册

### 10.1 用户入口与三种交互档位

用户入口固定为 **`harness-infi`**(在项目目录内执行):它在一个 tmux 会话里以协调者配置启动 Claude Code,你的全部交互就是与这个协调者对话。三种"档位"不是三个入口,而是同一个协调者会话的三种使用方式:

- **对话档**:你和协调者来回讨论(探索方案、拆解需求、明确验收标准)。这是把"模糊"变"清晰"的地方。
- **委派档**:讨论清楚后,你让协调者把任务派下去("把这三件事排进队列,夜里跑")。协调者调 `harness-task` 入队,执行平面接管。这是把"清晰"变"代码"的地方。
- **观测/验收档**:你问协调者"做得怎么样了",它查黑板汇报;任务完成它主动找你验收。

关键:三档共享同一协调者上下文与同一 `.harness/` 账本,衔接无缝——讨论档聊出的方案可直接转委派档入队,session 与决策连续(这正是 v0.2"裸 claude 模式 A"做不到、v0.3 修复的核心)。**你永远不裸跑 `claude`;那会绕过协调者、丢失上下文所有权。**

### 10.2 可观测性(执行平面默认隐藏、随时可查)

协调者与执行 agent 的全过程默认不展示给你。需要了解时,两种粒度:

- **快照式**(默认够用):`harness status` 查 `.harness/harness.db`,一屏给出每个任务状态、各 agent 当前 progress、今日花费。结构化真相,无需你解读屏幕。
- **现场式**(想深看时):`harness attach` 接入执行平面 tmux,实时看某 agent 的 pane;看完 detach,车间继续转。

### 10.3 一次性环境搭建(每台机器)

安装并认证各 backend CLI(claude / codex / opencode,OpenCode 按需配第三方 provider);将 harness 工具本体克隆至 `~/tools/harness/`,`bin/` 加入 PATH(**不复制进任何项目**);`harness setup` 校验依赖(sqlite3 ≥ 3.35、jq、git、tmux)并创建 `~/.config/harness/`;`harness doctor` 对每个 backend 做 echo 级自检,确认 adapter 链路全通。

### 10.4 新项目初始化(bootstrap,有人陪跑)

空仓库没有测试与 lint,校验门无门可校,**项目必须先获得"可校验性"才允许进入自动循环**(原则六的使用侧推论)。流程:

1. `cd <project> && harness init`:生成 AGENTS.md 模板(含验收命令)、软链 CLAUDE.md、安装 hooks、创建 `.harness/`(初始化本项目 harness.db)与 `specs/`、追加 gitignore 条目、登记入 `projects.list`。
2. `harness-infi` 启动协调者,在对话档里让它搭脚手架:项目骨架、测试框架、linter、`make test`/`make lint` 等 gate 标准命令;人在场补全 AGENTS.md。
3. `lib/gate.sh` 跑通(至少一个冒烟测试全绿)后,项目方可进入委派档自动循环。

### 10.5 日常一日(典型)

`cd <project> && harness-infi` 启动协调者 → 对话档说清今天要做的几件事 → 协调者拆解、确认验收标准后入队(委派档)→ 你去忙别的;协调者只在需决策/待验收/故障时找你 → 收到决策请求时直接在对话里答复,协调者转交执行平面续接 → 任务完成它来找你验收,你 `harness status` 看快照、抽查 diff 与 `.gate-report.json`。日常质量杠杆在 spec 的可校验性,不在编排参数。

### 10.6 新模型与新 CLI 的接入(两条轴,勿混淆)

**新模型(DeepSeek、Kimi 等)≠ 新 CLI。** 此类模型主流形态是经 OpenAI/Anthropic 兼容端点挂入现有多 provider CLI(首选 OpenCode:provider 配置加 baseURL + key + 模型名),harness 与 adapter 零改动,任务 spec 中以 `backend: opencode, model: <name>` 指定。数据边界须评估:第三方/境外模型默认只用于开源与数据分级允许的仓库,允许的 backend/model 白名单写入各项目 AGENTS.md 并由 gate 强制。

**新 CLI(独立工具)走 adapter 接入合同**,逐项验证:

| # | 能力 | 验证方式 | 缺失时降级 |
|---|------|----------|------------|
| 1 | 非交互模式(硬门槛) | 无 TTY 下管道调用能完成并退出 | 无降级,不接 |
| 2 | 退出码语义(硬门槛) | 成功 0 / 失败非零 | 输出判断成败,慎接 |
| 3 | 可解析输出(硬门槛) | --json 单对象或 NDJSON | 正则提取,标记低可信,仅派低风险任务 |
| 4 | 会话续接 | --resume/--session/--last;ID 可程序化获取 | 仅单发任务;BLOCKED 后重发完整上下文 |
| 5 | 工具权限控制 | allowlist/沙箱/审批模式 | 仅靠 worktree 隔离 + gate 兜底,禁触敏感仓库 |
| 6 | 成本数据 | 输出含 cost/usage | calls 表记 NULL,预算闸按次数估算 |

合同本质:adapter 必须归一化为 `{ok, session_id, result, cost_usd, num_turns, error}`,缺失字段在 backend 能力位图中声明,编排器据此限制可派任务类型。注意:此合同针对**执行平面**的后端;对话平面的协调者引擎当前固定为 Claude Code(也可替换为任何具备良好交互式会话的引擎,但需单独适配,不走此表)。

## 11. 已知风险与权衡备忘

- **协调者引擎绑定**:对话平面当前选 Claude Code 作协调者引擎(取其交互体验与自主编码能力);更换协调者引擎的成本高于更换执行 backend,属架构级决策。
- **协调者可靠性**:协调者是 LLM,其"判断"可能出错(派错任务、误判完成)。对冲:真正的 go/no-go 始终由确定性校验门把关,协调者无权绕过 gate 合并;协调者的入队动作受 spec 模板与 AGENTS 白名单约束。
- Codex session ID 不可程序化获取 → 强制 per-worktree 串行,牺牲部分并行换确定性;上游若增 `--session-id` 可解除。
- OpenCode 服务端模式有子 agent 挂死的已知问题 → 选 `opencode run` CLI 路径绕开;若改用 serve/SDK 须先验证已修复。
- 会话 resume 是上下文重建而非内存快照,长会话恢复有延迟与走形风险 → 续接封顶 + checkpoint 落盘对冲,不可省略。
- 全 bash 复杂度天花板:状态机与 adapter 超过 ~500 行后,考虑 orchestrator 主体迁 Python(保持文件协议与 harness.db schema 不变,对 agent 透明;Python 标准库自带 sqlite3,迁移成本低)。
- SQLite 牺牲状态直接可读性(不能 cat)→ `harness status` 输出当前队列/任务/成本快照弥补;原始调用 JSON 留档 `logs/raw/`。
- 单机限制:tmux 与文件/SQLite 黑板均不跨机;需多机时引入对象存储黑板或任务分发服务,属架构升级,当前明确不做。

## 12. 附录:字段与约定

status / guidance / calls 等 schema 见 4.2;时间戳一律 UTC ISO-8601;JSON 文件 UTF-8 无 BOM;`schema_version` 当前为 1,不向后兼容的变更须递增并在 adapter / 编排器 / 协调者工具三端同步。
