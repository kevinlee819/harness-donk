# 数据库 schema 迁移

文件命名：`V<N>__<short_description>.sql`，其中 `<N>` 是目标 `user_version`。

举例（未来添加任务标签时）：
```
schema/migrations/V2__add_tasks_tags_column.sql
```

`V2__add_tasks_tags_column.sql` 内容：
```sql
ALTER TABLE tasks ADD COLUMN tags TEXT;
-- 不需要 PRAGMA user_version=2，迁移 runner 会自动设置
```

## 流程（见 docs/data-schemas.md §7 完整版本）

1. **CREATE TABLE 改动也写进迁移文件**（用 ALTER），不只改 `schema/harness.sql`
2. `schema/harness.sql` 保持「全新安装能跑出最新版」状态：
   - 加新表 → `CREATE TABLE IF NOT EXISTS` 在 base SQL 加一份
   - 加新列 → `ALTER` 写到 V<N> 文件；base SQL 的 CREATE TABLE 同步加列定义
3. 把 `src/harness/db.py` 的 `SCHEMA_VERSION` 常量改为 N
4. 三端代码同步改（lib/python_env.sh 桥下：db.py / db_cli.py / adapter / coordinator-tool）
5. 重启 orchestrator：`init()` 会自动跑 V<N> 迁移把老 DB 升上来

不删旧列：兼容回退 + 历史快照仍可读。
