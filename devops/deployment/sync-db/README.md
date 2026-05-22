# 本地数据库 → 远端覆盖同步

把**本地开发** Docker 里的 PostgreSQL / Redis 数据，导出后覆盖到**线上** `work@43.155.195.115`。

| 环境 | PostgreSQL | Redis |
|------|------------|-------|
| 本地 | `127.0.0.1:5435` 容器 `new-api-dev-pg` | `127.0.0.1:6380` 容器 `new-api-dev-redis` |
| 远端 | 容器 `new-api-postgres` | 容器 `new-api-redis`，数据目录 `/home/work/data/redis` |

默认账号与 `docker-compose.infra.yml` 一致（`root` / `123456`）。远端导入密码从 `~/new-api/devops/deployment/.env` 读取。

---

## 两步执行（推荐先理解再操作）

### 步骤 1：本地导出

```bash
cd new-api/devops/deployment/sync-db
chmod +x *.sh
./01-dump-local.sh
```

生成目录：`out/20260522-153045/`

- `postgres.sql` — `pg_dump --clean`
- `redis.rdb` — Redis RDB 快照
- `manifest.txt` — 元信息

仅导出其一：

```bash
./01-dump-local.sh --postgres-only
./01-dump-local.sh --redis-only
```

**前提**：本地 infra 已启动（`./dev.sh` 或 `docker compose -f docker-compose.infra.yml up -d`）。

### 步骤 2：上传并在远端导入

```bash
./02-restore-remote.sh
# 或指定目录
./02-restore-remote.sh ./out/20260522-153045
```

会：

1. `scp` 到远端 `/tmp/new-api-db-sync-*`
2. 停止 `new-api` 容器
3. **覆盖**远端 PostgreSQL（`psql` 执行 dump）
4. **覆盖**远端 Redis（停容器 → 替换 `/home/work/data/redis` → 再起）
5. 启动 `new-api`

执行前需输入 `y` 确认（会清空远端对应数据）。

---

## 一键（1 + 2）

```bash
./sync-db-to-remote.sh
./sync-db-to-remote.sh --yes   # 跳过确认（慎用）
```

---

## 注意

- **会覆盖远端库**，操作前请确认线上无需要保留的新数据。
- 远端 `.env` 里 `POSTGRES_PASSWORD` / `REDIS_PASSWORD` 可与本地不同；导入用远端密码连库，**数据内容**来自本地。
- 若仅改业务表、不需要 Redis 缓存，用 `--postgres-only`。
- `out/` 已 gitignore，勿把 dump 提交进仓库。
