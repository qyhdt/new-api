#!/usr/bin/env bash
# 在远端 work 账户下执行：拉代码 → Docker 编译 new-api → 启动全栈
#
# 用法（SSH 登录 work 后）：
#   cd ~/new-api/devops/deployment && ./deploy-online.sh
#
# 或本机触发：
#   ssh work@43.155.195.115 'bash ~/new-api/devops/deployment/deploy-online.sh'
#
# 数据与日志目录（host，与 create_work.sh 一致）：
#   /home/work/data/postgres   ← PostgreSQL 数据卷
#   /home/work/data/redis      ← Redis 数据卷
#   /home/work/data/log        ← new-api 应用日志（容器 /app/logs）
#   /home/work/data/app-data   ← new-api /data

set -euo pipefail

REPO_URL="${REPO_URL:-git@github.com:qyhdt/new-api.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
HOME_DIR="${HOME:-/home/work}"
REPO_DIR="${REPO_DIR:-${HOME_DIR}/new-api}"
DEPLOY_DIR="${REPO_DIR}/devops/deployment"
DATA_ROOT="${DATA_ROOT:-/home/work/data}"
SKIP_BUILD="${SKIP_BUILD:-0}"

INFRA_COMPOSE="${DEPLOY_DIR}/docker-compose.infra.yml"
APP_COMPOSE="${DEPLOY_DIR}/docker-compose.app.yml"
ENV_FILE="${DEPLOY_DIR}/.env"

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

for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        -h|--help)
            cat <<'EOF'
用法: deploy-online.sh [--skip-build]

  在 work 用户下拉取代码，用 Docker 编译并启动 new-api + postgres + redis。
  持久化目录固定为 /home/work/data/{postgres,redis,log,app-data}。

  --skip-build  不重新 docker build，仅 compose up -d（改配置时用）
EOF
            exit 0
            ;;
    esac
done

if [[ "$(whoami)" != "work" ]]; then
    err "建议在 work 用户下执行（当前: $(whoami)）"
fi

log "→ 检查 docker / docker compose"
command -v docker >/dev/null || { err "docker 未安装"; exit 1; }
docker compose version >/dev/null || { err "docker compose 未安装"; exit 1; }

if ! ssh-keygen -F github.com >/dev/null 2>&1; then
    log "→ 添加 github.com 到 known_hosts"
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    ssh-keyscan -H github.com >> ~/.ssh/known_hosts 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# 1. 拉代码
# -----------------------------------------------------------------------------
if [[ ! -d "${REPO_DIR}/.git" ]]; then
    if [[ -d "${REPO_DIR}" ]] && [[ -n "$(ls -A "${REPO_DIR}" 2>/dev/null)" ]]; then
        err "${REPO_DIR} 已存在但不是 git 仓库，请清空或改 REPO_DIR"
        exit 1
    fi
    log "→ 首次：git clone ${REPO_URL} (${REPO_BRANCH})"
    git clone --branch "${REPO_BRANCH}" "${REPO_URL}" "${REPO_DIR}"
else
    log "→ git fetch + reset --hard origin/${REPO_BRANCH}"
    cd "${REPO_DIR}"
    git fetch origin "${REPO_BRANCH}"
    git reset --hard "origin/${REPO_BRANCH}"
fi
ok "代码：${REPO_DIR}"

if [[ ! -f "${DEPLOY_DIR}/docker-compose.infra.yml" ]]; then
    err "缺少 ${DEPLOY_DIR}/docker-compose.infra.yml，请确认仓库结构"
    exit 1
fi

cd "${DEPLOY_DIR}"

# -----------------------------------------------------------------------------
# 2. .env（DATA_ROOT 必须指向 /home/work/data，供 compose 挂载）
# -----------------------------------------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
    log "→ 首次：从 .env.example 生成 .env"
    cp .env.example .env
    PG_PASS="$(rand_hex | head -c 24)"
    REDIS_PASS="$(rand_hex | head -c 24)"
    SESSION="$(rand_hex)"
    sed -i "s|^DATA_ROOT=.*|DATA_ROOT=${DATA_ROOT}|" .env
    sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${PG_PASS}/" .env
    sed -i "s/^REDIS_PASSWORD=.*/REDIS_PASSWORD=${REDIS_PASS}/" .env
    sed -i "s/^SESSION_SECRET=.*/SESSION_SECRET=${SESSION}/" .env
    ok ".env 已生成，请备份 ${ENV_FILE}"
else
    # 确保 DATA_ROOT 正确（不覆盖其它密钥）
    if ! grep -q "^DATA_ROOT=${DATA_ROOT}" "${ENV_FILE}"; then
        if grep -q '^DATA_ROOT=' "${ENV_FILE}"; then
            sed -i "s|^DATA_ROOT=.*|DATA_ROOT=${DATA_ROOT}|" .env
        else
            echo "DATA_ROOT=${DATA_ROOT}" >> .env
        fi
        ok "已更新 .env 中 DATA_ROOT=${DATA_ROOT}"
    fi
fi

if grep -qE '^POSTGRES_PASSWORD=CHANGE_ME$|^REDIS_PASSWORD=CHANGE_ME$|^SESSION_SECRET=CHANGE_ME$' "${ENV_FILE}"; then
    err ".env 仍有 CHANGE_ME，请先编辑 ${ENV_FILE}"
    exit 2
fi

# -----------------------------------------------------------------------------
# 3. 数据 / 日志目录（与 docker-compose 绑定路径一致）
# -----------------------------------------------------------------------------
log "→ 准备 host 目录"
EDGE_RUNTIME="${DATA_ROOT}/runtime/edge-proxy"
mkdir -p "${DATA_ROOT}/postgres" "${DATA_ROOT}/redis" "${DATA_ROOT}/log" "${DATA_ROOT}/app-data" \
    "${DATA_ROOT}/log/edge-nginx" "${EDGE_RUNTIME}"
chmod -R 0775 "${DATA_ROOT}/postgres" "${DATA_ROOT}/redis" "${DATA_ROOT}/log" "${DATA_ROOT}/app-data" 2>/dev/null || true
if [[ ! -f "${EDGE_RUNTIME}/upstreams.conf" ]]; then
    cp "${REPO_DIR}/devops/edge-proxy/upstreams.conf.example" "${EDGE_RUNTIME}/upstreams.conf"
    ok "edge upstreams → ${EDGE_RUNTIME}/upstreams.conf"
fi
if ! docker network inspect new_api_edge_net >/dev/null 2>&1; then
    docker network create new_api_edge_net >/dev/null
    ok "docker network new_api_edge_net 已创建"
fi
ok "postgres → ${DATA_ROOT}/postgres"
ok "redis    → ${DATA_ROOT}/redis"
ok "log      → ${DATA_ROOT}/log (含 edge-nginx/)"
ok "app-data → ${DATA_ROOT}/app-data"

# -----------------------------------------------------------------------------
# 4. infra：postgres + redis（volume 挂 /home/work/data）
# -----------------------------------------------------------------------------
log "→ 启动 postgres + redis"
docker compose -f "${INFRA_COMPOSE}" --env-file "${ENV_FILE}" up -d

log "→ 等待 postgres healthy（最长 60s）"
for _ in $(seq 1 30); do
    if docker inspect --format='{{.State.Health.Status}}' new-api-postgres 2>/dev/null | grep -q healthy; then
        ok "postgres healthy"
        break
    fi
    sleep 2
done

# -----------------------------------------------------------------------------
# 5. app：容器内编译 new-api 并启动（日志挂 /home/work/data/log）
# -----------------------------------------------------------------------------
if [[ "${SKIP_BUILD}" == "1" ]]; then
    log "→ 跳过 build，直接 up -d new-api"
    docker compose -f "${APP_COMPOSE}" --env-file "${ENV_FILE}" up -d
else
    log "→ docker compose build new-api（在容器构建上下文内编译）"
    docker compose -f "${APP_COMPOSE}" --env-file "${ENV_FILE}" build --pull
    log "→ 启动 new-api"
    docker compose -f "${APP_COMPOSE}" --env-file "${ENV_FILE}" up -d
fi

# -----------------------------------------------------------------------------
# 6. edge-nginx：80/443 → new-api:3000（aiapi.thyseed.com）
# -----------------------------------------------------------------------------
EDGE_COMPOSE="${REPO_DIR}/devops/edge-proxy/docker-compose.yml"
log "→ 启动 edge-nginx（公网 80/443）"
DATA_ROOT="${DATA_ROOT}" EDGE_RUNTIME_DIR="${EDGE_RUNTIME}" \
    docker compose -f "${EDGE_COMPOSE}" up -d

if docker exec edge-nginx nginx -t >/dev/null 2>&1; then
    docker exec edge-nginx nginx -s reload 2>/dev/null || true
    ok "edge-nginx 配置校验通过"
else
    err "edge-nginx 配置有误，执行: docker exec edge-nginx nginx -t"
    exit 1
fi

echo
log "→ 容器状态"
docker compose -f "${INFRA_COMPOSE}" --env-file "${ENV_FILE}" ps
docker compose -f "${APP_COMPOSE}" --env-file "${ENV_FILE}" ps
docker compose -f "${EDGE_COMPOSE}" ps 2>/dev/null || true

echo
log "→ new-api 最近 40 行（docker logs）"
docker logs --tail 40 new-api 2>&1 || true

EDGE_DOMAIN="$(grep -E '^EDGE_DOMAIN=' "${ENV_FILE}" | cut -d= -f2- || echo aiapi.thyseed.com)"
EDGE_DOMAIN_ALT="$(grep -E '^EDGE_DOMAIN_ALT=' "${ENV_FILE}" | cut -d= -f2- || echo aicenter.thyseed.com)"

echo
echo "═══════════════════════════════════════════════════════════════"
ok "部署完成"
echo "  公网入口： https://${EDGE_DOMAIN}  https://${EDGE_DOMAIN_ALT}  （edge-nginx :443）"
echo "  后端容器： new-api:3000（仅 Docker 网络，不映射公网端口）"
echo "  应用日志： ${DATA_ROOT}/log"
echo "  Edge 日志：${DATA_ROOT}/log/edge-nginx/"
echo "  PG 数据：  ${DATA_ROOT}/postgres"
echo "  Redis：    ${DATA_ROOT}/redis"
echo "  DNS：      ${EDGE_DOMAIN}、${EDGE_DOMAIN_ALT} A 记录 → 本机公网 IP；安全组放行 80/443"
echo "═══════════════════════════════════════════════════════════════"
echo "常用："
echo "  tail -f ${DATA_ROOT}/log/*.log"
echo "  docker logs -f new-api"
echo "  docker compose -f ${APP_COMPOSE} --env-file ${ENV_FILE} restart new-api"
