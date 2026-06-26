# `hooks/stop.sh` — 设计决定：暂不实装

记于 2026-06-25。

## 原 TODO 描述

> `hooks/stop.sh` — 完成度强制（需 task state 关联）

意图：worker 结束本轮 turn 时，hook 检查任务是否真完成（gate 全绿 / 文件改动符合 spec），否则阻止退出，逼模型继续。

## 为什么不做

1. **gate.sh 已是完成度的权威**。worker 退出后编排器跑 gate.sh；不过门 → 回灌错误 → 续 turn；max_retries 耗尽 → FAILED。这条路径覆盖了"完成度判定 + 强制返工 + 限重试"。stop hook 会重复这套逻辑且**更早**触发——但 stop hook 没有 gate 的全部上下文（gate 还要看 worker 之外的 build/lint/test、cross_review），所以判定一定弱于 gate。

2. **强制不退出会爆 token 预算**。`claude --print --max-turns 12` 是硬上限；强逼模型不退会让单 turn 烧光配额。当前的"轻量退出 → gate 评 → 回灌"循环每轮独立计费，更可控。

3. **PreToolUse hook 已经覆盖了越界写**（写非本 worker `.harness/`、主分支 git merge、worktree 外 `rm -rf`、prod/secret 路径）。worker 走非 happy path 的"危险"动作早被拦截，不需要 stop 再过一次。

4. **hooks 设计原则是确定性、低延迟、stateless**（CLAUDE.md §4.7 / §10）。stop hook 要做"完成度"判断必然得查 DB、读 spec、跑 grep——这违反 hook 的轻量原则，应该放编排平面。

## 何时重新评估

- 出现"worker 反复退出但 gate 反复不过"的真实病例（即 worker 知道没做完但硬要退）。当前 `--permission-mode bypassPermissions` 下没看到这种行为，sonnet-4.6 任务结束都会自然走到 git commit + 退出。
- 阶段四并行 worker：多 worker 互相干扰，stop 时需做 worktree 边界最终一致性检查。可能那时 stop hook 有意义。

## 不做的副作用

- `templates/settings.json.tmpl` 中**不**注册 Stop hook（hooks 数组保留 PreToolUse 项即可）。
- `bin/harness doctor` 不检查 stop hook 存在性。
- 文档：CLAUDE.md §4.7 PreToolUse 列表不变，本文件用作设计决定的存档。

阶段四真要做时，参考 PreToolUse 实现风格：bash + stderr + exit 2 拦截，输出原因到 stderr。
