#!/usr/bin/env bash
# 在远端 work 机器上执行：用上传的 dump 覆盖 postgres / redis（由 02-restore-remote.sh 调用）

set -euo pipefail

STAGING_DIR="${STAGING_DIR:?}"
DATA_ROOT="${DATA_ROOT:-/home/work/data}"
REMOTE_REPO_PATH="${REMOTE_REPO_PATH:-/home/work/new-api}"
DEPLOY_DIR="${REMOTE_REPO_PATH}/devops/deployment"
ENV_FILE="${DEPLOY_DIR}/.env"
RESTORE_PG="${RESTORE_PG:-1}"
RESTORE_REDIS="${RESTORE_REDIS:-1}"

PG_CONTAINER="${PG_CONTAINER:-new-api-postgres}"
REDIS_CONTAINER="${REDIS_CONTAINER:-new-api-redis}"
APP_CONTAINER="${APP_CONTAINER:-new-api}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

load_env() {
    if [[ -f "${ENV_FILE}" ]]; then
        # shellcheck disable=SC1090
        set -a
        source "${ENV_FILE}"
        set +a
    fi
    PG_USER="${POSTGRES_USER:-root}"
    PG_PASSWORD="${POSTGRES_PASSWORD:?请在 ${ENV_FILE} 配置 POSTGRES_PASSWORD}"
    PG_DB="${POSTGRES_DB:-new-api}"
    REDIS_PASSWORD="${REDIS_PASSWORD:?请在 ${ENV_FILE} 配置 REDIS_PASSWORD}"
}

stop_app() {
    if docker ps --format '{{.Names}}' | grep -qx "${APP_CONTAINER}"; then
        log "停止 ${APP_CONTAINER}（避免写入冲突）"
        docker stop "${APP_CONTAINER}" >/dev/null
    fi
}

start_app() {
    if docker ps -a --format '{{.Names}}' | grep -qx "${APP_CONTAINER}"; then
        log "启动 ${APP_CONTAINER}"
        docker start "${APP_CONTAINER}" >/dev/null || true
    fi
}

restore_postgres() {
    local sql="${STAGING_DIR}/postgres.sql"
    [[ -f "${sql}" ]] || { echo "缺少 ${sql}" >&2; exit 1; }

    if ! docker ps --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
        log "postgres 未运行，尝试启动 infra..."
        cd "${DEPLOY_DIR}"
        docker compose -f docker-compose.infra.yml --env-file .env up -d postgres
        sleep 3
    fi

    log "导入 PostgreSQL（覆盖库 ${PG_DB}）..."
    docker exec -i -e PGPASSWORD="${PG_PASSWORD}" "${PG_CONTAINER}" \
        psql -v ON_ERROR_STOP=1 -U "${PG_USER}" -d "${PG_DB}" < "${sql}"
    log "PostgreSQL 导入完成"
}

restore_redis() {
    local rdb="${STAGING_DIR}/redis.rdb"
    [[ -f "${rdb}" ]] || { echo "缺少 ${rdb}" >&2; exit 1; }

    log "停止 ${REDIS_CONTAINER}..."
    docker stop "${REDIS_CONTAINER}" 2>/dev/null || true

    local bak="${DATA_ROOT}/redis.bak.$(date +%Y%m%d-%H%M%S)"
    if [[ -d "${DATA_ROOT}/redis" ]]; then
        log "备份原 redis 数据 → ${bak}"
        mv "${DATA_ROOT}/redis" "${bak}"
    fi
    mkdir -p "${DATA_ROOT}/redis"
    cp "${rdb}" "${DATA_ROOT}/redis/dump.rdb"
    chmod 0775 "${DATA_ROOT}/redis" "${DATA_ROOT}/redis/dump.rdb" 2>/dev/null || true

    log "启动 ${REDIS_CONTAINER}（从 dump.rdb 加载）..."
    docker start "${REDIS_CONTAINER}" >/dev/null
    sleep 2
    if docker exec "${REDIS_CONTAINER}" redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning ping | grep -q PONG; then
        log "Redis 导入完成"
    else
        echo "WARN: Redis ping 未成功，请检查 docker logs ${REDIS_CONTAINER}" >&2
    fi
}

load_env
stop_app

[[ "${RESTORE_PG}" -eq 1 ]] && restore_postgres
[[ "${RESTORE_REDIS}" -eq 1 ]] && restore_redis

start_app

log "全部完成"
