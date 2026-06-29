# Git 操作规范

本仓库的 git 使用约定。**适用于本工具仓库本身（`~/tools/harness/`），不是 harness 接管的用户项目**。

> 历史背景：项目最初没有用 git 管理（疏忽），首次接入在 2026-06-25 第一次正式 commit 时回溯整理。后续开发严格按本规范走。

## 1. 何时提交

**每完成一个逻辑单元就提交**，不要攒。判断标准：

- ✅ 一个功能从需求到测试全绿，是一个单元
- ✅ 一次重构（如「db.sh 改成 db.py」）是一个单元
- ✅ 一份文档（如「写 coordinator.md」）是一个单元
- ❌ "写到一半留着明天"不是单元，要么完成要么 stash
- ❌ "改了 10 处 typo + 加了一个功能"是两个单元，分开

经验值：每次会话内通常应该有 2–5 个 commit。一个会话一个巨型 commit 是反模式。

**绝对硬规**：

1. **测试不绿不许 commit**（除非显式标 WIP 且本地分支）
2. **不许 commit 密钥 / .env / API key**（gitignore 已挡，但每次 `git add` 前肉眼扫一眼）
3. **不许 commit `.venv/` / `__pycache__/` / 备份文件**（gitignore 已挡）

## 2. 提交消息格式

```
<type>: <50 字内 summary>

<空行>

<正文：为什么做这个改动，做了哪些事，对外影响>

<空行（可选）>

<尾部：测试结果 / breaking change 标记 / Co-Authored-By>
```

### 2.1 type 词表

| type | 用途 | 例 |
|------|------|----|
| `feat` | 新功能 | `feat: add lib/notify.sh + events table writes` |
| `fix` | 修 bug | `fix: bash ${3:-{}} parsing inflates payload with extra }` |
| `refactor` | 不改外部行为的重写 | `refactor: replace lib/db.sh with src/harness/db.py` |
| `test` | 加/改测试 | `test: cover event_write JSON round-trip` |
| `docs` | 文档 | `docs: write coordinator.md system prompt` |
| `chore` | 工具 / 配置 / 依赖 | `chore: add uv.lock, switch to .venv-managed python` |
| `revert` | 回退 | `revert: revert "feat: add foo"` |

**严禁** `update`、`misc`、`stuff`、`WIP`（除本地分支）。每个 commit 都应该一句话说清楚做了什么。

### 2.2 Summary 行（首行）

- 50 字以内（含 type）
- 祈使句、小写起头（`add` 不是 `Adds` / `Added`）
- 不加句号
- 范围具体：`feat: add harness backup` 比 `feat: add backup feature` 好

### 2.3 正文（body）

正文写 **为什么**，不写 **做了什么**——做了什么 `git show` 自己看 diff。

模板：

```
<问题 / 动机>。
<采取的方案 / 关键决策>。
<对外影响：API 变更 / 配置变更 / 测试新增数>。
```

示例：

```
fix: adapter blocked by claude default permission mode in --print

Real Claude smoke test (T-hello1) hit error_max_turns after 12 turns
of Write/Bash denials. permission_denials in raw log show every file
write rejected. Default permission mode in --print is not configured
to auto-accept edits, and there's no interactive prompt to grant.

Add --permission-mode bypassPermissions to adapter args. Safe because:
worker runs in isolated worktree + pre_tool_use hook is the real
safety floor (CLAUDE.md §4.7 — hard constraints live in hooks).

Also export HARNESS_WORKTREE so hook rule 2 (rm -rf outside worktree)
can resolve the boundary.

Verified: T-hello1 now completes in 3 turns / 12.5s / $0.006.
70/70 mock tests still green.
```

### 2.4 尾部签名

每个 Claude-author 的 commit 末尾加：

```
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

> 已在 Claude Code 的 commit 流程默认行为里；正文末尾留一空行接它。

## 3. 不提交什么

- `.venv/`、`__pycache__/`、`*.pyc`、`.pytest_cache/`（已 gitignore）
- `.harness/`、`.worktrees/`、运行时产物（用户项目里的，工具本仓库通常不出现）
- 备份 `.bak`、`*.orig`、编辑器临时文件 `.swp`、`*~`
- 任何含 API key / token / 私钥 的文件
- 大二进制（>5MB 单文件需 review）

**例外不提交的**：`uv.lock` 必须进 git（CLAUDE.md §8.3）。这点反直觉但是对的——锁文件就是要锁。

## 4. 分支策略

**当前（单人 MVP 阶段）**：

- 直接在 `main` 上提交，不开 feature branch
- 凡需多 commit 的实验，先 `git stash` 或临时分支 `wip/<topic>`，搞定再合回 `main`

**将来（协作或公开后）**：

- `main` 只接 PR
- feature branch 命名：`feat/<topic>` / `fix/<topic>`
- PR 至少自审一遍 diff 再合

## 5. 与 harness 接管的项目的关系

**警惕**：本仓库（`~/tools/harness/`）和 harness 接管的用户项目都是 git 仓库，**绝不混淆**：

| 仓库 | 主分支 | worker 写哪 |
|------|--------|-------------|
| 本工具仓库 | `main`（Claude 直接提交） | 不适用 |
| 接管的用户项目 | 项目自己的主分支 | worker 的 worktree → 编排器 merge |

**禁令**：

- 工具本身的代码改动**绝不**走 worker → 编排器路径。Claude 在本仓库就是普通开发者，直接 `git commit`。
- 用户项目内的代码改动**绝不**让协调者直接 `git commit` 主分支。那是 worker + 编排器的职责。

## 6. 不许做的危险操作

未经用户明确授权一律不做：

- ❌ `git push --force` / `--force-with-lease`（hooks 已挡用户项目内的，本仓库靠自律）
- ❌ `git reset --hard` 到比当前 HEAD 老的 commit
- ❌ `git commit --amend` 已 push 出去的 commit
- ❌ `git rebase -i` 修改历史
- ❌ `git clean -fd` 不读 `git status` 就跑
- ❌ `--no-verify` 跳过 pre-commit hook
- ❌ 删分支前不看 `git log <branch>`

需要做上述操作时**先停下来问用户**。

## 7. 提交前自检清单

每次 `git add` 之前回答四个问题：

1. **测试过了吗？** `bash tests/run.sh` 全绿。
2. **diff 干净吗？** `git diff --staged` 一眼能看完，没有 unrelated 改动。
3. **TODO.md 更新了吗？** 完成项打勾，否则下次会重做。
4. **commit message 能解释「为什么」吗？** 不能就重写 message。

## 8. 推送

**MVP 阶段不推任何远端。** 仓库就在本地 `~/tools/harness/.git/`。

将来推到远端时另行约定（GitHub / GitLab / 私服）。在那之前 `git push` 不可用——也不需要。

## 9. 工具仓库的 `.gitignore`

当前覆盖（[/.gitignore](../.gitignore)）：

```
.venv/
__pycache__/
*.pyc
*.pyo
.pytest_cache/
.ruff_cache/
.mypy_cache/
*.egg-info/
build/
dist/
```

新增依赖时同步更新。

---

**底线**：版本控制不是事后整理，是开发的一部分。每个 commit 都是一个可回退、可解释的检查点。
