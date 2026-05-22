#!/usr/bin/env bash
# 步骤 1：从本地开发环境导出 PostgreSQL + Redis 数据
#
# 用法：
#   ./01-dump-local.sh
#   ./01-dump-local.sh --postgres-only
#   ./01-dump-local.sh --redis-only
#   OUT_DIR=./out/my-dump ./01-dump-local.sh
#
# 默认连接（与 docker-compose.infra.yml / dev.sh 一致）：
#   PG  127.0.0.1:5435  root/123456  db=new-api  容器 new-api-dev-pg
#   Redis 127.0.0.1:6380  密码 123456  容器 new-api-dev-redis

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/out/${TS}}"

PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5435}"
PG_USER="${PG_USER:-root}"
PG_PASSWORD="${PG_PASSWORD:-123456}"
PG_DB="${PG_DB:-new-api}"
PG_CONTAINER="${PG_CONTAINER:-new-api-dev-pg}"

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6380}"
REDIS_PASSWORD="${REDIS_PASSWORD:-123456}"
REDIS_CONTAINER="${REDIS_CONTAINER:-new-api-dev-redis}"

DUMP_PG=1
DUMP_REDIS=1

for arg in "$@"; do
    case "$arg" in
        --postgres-only) DUMP_REDIS=0 ;;
        --redis-only) DUMP_PG=0 ;;
        -h|--help)
            sed -n '2,14p' "$0"
            exit 0
            ;;
        *) echo "未知参数: $arg" >&2; exit 1 ;;
    esac
done

mkdir -p "${OUT_DIR}"
echo "${TS}" > "${OUT_DIR}/.dump_time"
cat > "${OUT_DIR}/manifest.txt" <<EOF
dump_time=${TS}
pg_host=${PG_HOST}
pg_port=${PG_PORT}
pg_db=${PG_DB}
redis_host=${REDIS_HOST}
redis_port=${REDIS_PORT}
dump_pg=${DUMP_PG}
dump_redis=${DUMP_REDIS}
EOF

log() { echo "[$(date +%H:%M:%S)] $*"; }

dump_pg() {
    log "导出 PostgreSQL → ${OUT_DIR}/postgres.sql"
    if docker ps --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
        docker exec -e PGPASSWORD="${PG_PASSWORD}" "${PG_CONTAINER}" \
            pg_dump -U "${PG_USER}" -d "${PG_DB}" \
            --clean --if-exists --no-owner --no-acl \
            > "${OUT_DIR}/postgres.sql"
    elif command -v pg_dump >/dev/null 2>&1; then
        PGPASSWORD="${PG_PASSWORD}" pg_dump -h "${PG_HOST}" -p "${PG_PORT}" \
            -U "${PG_USER}" -d "${PG_DB}" \
            --clean --if-exists --no-owner --no-acl \
            > "${OUT_DIR}/postgres.sql"
    else
        echo "ERROR: 未找到容器 ${PG_CONTAINER} 或本机 pg_dump" >&2
        exit 1
    fi
    [[ -s "${OUT_DIR}/postgres.sql" ]] || { echo "ERROR: postgres.sql 为空" >&2; exit 1; }
    log "PostgreSQL 导出完成 ($(wc -c < "${OUT_DIR}/postgres.sql" | tr -d ' ') bytes)"
}

dump_redis() {
    log "导出 Redis RDB → ${OUT_DIR}/redis.rdb"
    if docker ps --format '{{.Names}}' | grep -qx "${REDIS_CONTAINER}"; then
        docker exec "${REDIS_CONTAINER}" redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning BGSAVE >/dev/null
        for _ in $(seq 1 30); do
            if docker exec "${REDIS_CONTAINER}" redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning \
                INFO persistence 2>/dev/null | grep -q 'rdb_bgsave_in_progress:0'; then
                break
            fi
            sleep 1
        done
        docker cp "${REDIS_CONTAINER}:/data/dump.rdb" "${OUT_DIR}/redis.rdb"
    elif command -v redis-cli >/dev/null 2>&1; then
        redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" --no-auth-warning \
            --rdb "${OUT_DIR}/redis.rdb"
    else
        echo "ERROR: 未找到容器 ${REDIS_CONTAINER} 或本机 redis-cli" >&2
        exit 1
    fi
    [[ -s "${OUT_DIR}/redis.rdb" ]] || { echo "ERROR: redis.rdb 为空" >&2; exit 1; }
    log "Redis 导出完成 ($(wc -c < "${OUT_DIR}/redis.rdb" | tr -d ' ') bytes)"
}

echo "═══════════════════════════════════════════════════════════════"
echo "  步骤 1/2 · 本地导出"
echo "  输出目录：${OUT_DIR}"
echo "═══════════════════════════════════════════════════════════════"

[[ "${DUMP_PG}" -eq 1 ]] && dump_pg
[[ "${DUMP_REDIS}" -eq 1 ]] && dump_redis

echo "${OUT_DIR}" > "${SCRIPT_DIR}/out/.latest"
echo
echo "完成。下一步："
echo "  ./02-restore-remote.sh ${OUT_DIR}"
echo "  或：./02-restore-remote.sh   # 自动使用最新导出"
