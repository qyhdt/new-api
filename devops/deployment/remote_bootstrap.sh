#!/usr/bin/env bash
# 远端引导：在 work@<host> 上拉代码并 docker compose 起 new-api 全栈。
#
# 数据目录（与 init_new_node/create_work.sh 一致）：
#   /home/work/data/postgres
#   /home/work/data/redis
#   /home/work/data/log
#   /home/work/data/app-data

set -euo pipefail

REPO_URL="${REPO_URL:-git@github.com:qyhdt/new-api.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
HOME_DIR="${HOME:-/home/work}"
REPO_DIR="${HOME_DIR}/new-api"
DEPLOY_DIR="${REPO_DIR}/devops/deployment"
DATA_ROOT="${DATA_ROOT:-${HOME_DIR}/data}"

log()  { echo -e "\033[34m[$(date +%H:%M:%S)]\033[0m $*"; }
ok()   { echo -e "\033[32m[OK]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR]\033[0m $*" >&2; }

rand_hex() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

log "→ 检查 docker / docker compose"
command -v docker >/dev/null || { err "docker 未安装"; exit 1; }
docker compose version >/dev/null || { err "docker compose plugin 未装"; exit 1; }

if ! ssh-keygen -F github.com >/dev/null 2>&1; then
    log "→ 把 github.com 加进 ~/.ssh/known_hosts"
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    ssh-keyscan -H github.com >> ~/.ssh/known_hosts 2>/dev/null || true
fi

if [ ! -d "${REPO_DIR}" ]; then
    log "→ git clone ${REPO_URL}"
    git clone --branch "${REPO_BRANCH}" "${REPO_URL}" "${REPO_DIR}"
else
    log "→ git fetch + reset --hard origin/${REPO_BRANCH}"
    cd "${REPO_DIR}"
    git fetch origin "${REPO_BRANCH}"
    git reset --hard "origin/${REPO_BRANCH}"
fi
ok "代码就位：${REPO_DIR}"

cd "${DEPLOY_DIR}"

if [ ! -f .env ]; then
    log "→ 首次部署：从 .env.example 生成 .env（自动填充随机密钥）"
    cp .env.example .env
    PG_PASS="$(rand_hex | head -c 24)"
    REDIS_PASS="$(rand_hex | head -c 24)"
    SESSION="$(rand_hex)"
    sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${PG_PASS}/" .env
    sed -i "s/^REDIS_PASSWORD=.*/REDIS_PASSWORD=${REDIS_PASS}/" .env
    sed -i "s/^SESSION_SECRET=.*/SESSION_SECRET=${SESSION}/" .env
    ok ".env 已生成（密钥已随机化，请备份 ${DEPLOY_DIR}/.env）"
else
    ok ".env 已存在，保留"
fi

if grep -qE '^POSTGRES_PASSWORD=CHANGE_ME$|^REDIS_PASSWORD=CHANGE_ME$|^SESSION_SECRET=CHANGE_ME$' .env; then
    err ".env 里仍有 CHANGE_ME 占位符"
    exit 2
fi

log "→ 准备数据目录"
mkdir -p "${DATA_ROOT}/postgres" "${DATA_ROOT}/redis" "${DATA_ROOT}/log" "${DATA_ROOT}/app-data"
chmod -R 0775 "${DATA_ROOT}/postgres" "${DATA_ROOT}/redis" "${DATA_ROOT}/log" "${DATA_ROOT}/app-data" 2>/dev/null || true
ok "数据目录：${DATA_ROOT}"

log "→ 启动 infra（postgres + redis）"
docker compose -f docker-compose.infra.yml --env-file .env up -d

log "→ 等 postgres healthy（最长 60s）"
for _ in $(seq 1 30); do
    if docker inspect --format='{{.State.Health.Status}}' new-api-postgres 2>/dev/null | grep -q healthy; then
        ok "postgres healthy"
        break
    fi
    sleep 2
done

log "→ build + up new-api"
docker compose -f docker-compose.app.yml --env-file .env build
docker compose -f docker-compose.app.yml --env-file .env up -d

echo
log "→ 容器状态"
docker compose -f docker-compose.infra.yml --env-file .env ps
docker compose -f docker-compose.app.yml --env-file .env ps

echo
log "→ new-api 最近 40 行日志"
docker logs --tail 40 new-api 2>&1 || true

PORT="$(grep -E '^NEW_API_PORT=' .env | cut -d= -f2- || echo 3000)"
PUBLIC_IP="$(curl -sf --max-time 3 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo
ok "部署完成。访问：http://${PUBLIC_IP}:${PORT}"
echo
echo "日志目录（host）：${DATA_ROOT}/log"
echo "常用：docker logs -f new-api"
