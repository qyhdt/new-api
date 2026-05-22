#!/usr/bin/env bash
# 本机执行 → SSH 到远端 work 用户 → 拉代码、Docker 编译、启动 new-api + edge-nginx
#
# 用法（在仓库任意目录）：
#   ./devops/deployment/deploy-remote.sh
#   ./devops/deployment/deploy-remote.sh --skip-build
#   REMOTE_HOST=43.155.195.115 GIT_BRANCH=main ./devops/deployment/deploy-remote.sh
#
# 环境变量：
#   REMOTE_HOST      默认 43.155.195.115
#   REMOTE_USER      默认 work
#   REMOTE_REPO_PATH 默认 /home/work/new-api
#   GIT_BRANCH       默认 main
#   GIT_REMOTE_URL   默认 git@github.com:qyhdt/new-api.git
#
# 前置：本机可免密 ssh work@${REMOTE_HOST}（见 devops/init_new_node/create_new_machine.sh）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

REMOTE_HOST="${REMOTE_HOST:-43.155.195.115}"
REMOTE_USER="${REMOTE_USER:-work}"
REMOTE_REPO_PATH="${REMOTE_REPO_PATH:-/home/work/new-api}"
GIT_BRANCH="${GIT_BRANCH:-main}"
GIT_REMOTE_URL="${GIT_REMOTE_URL:-git@github.com:qyhdt/new-api.git}"
EDGE_DOMAIN="${EDGE_DOMAIN:-aiapi.thyseed.com}"
EDGE_DOMAIN_ALT="${EDGE_DOMAIN_ALT:-aicenter.thyseed.com}"

REMOTE="${REMOTE_USER}@${REMOTE_HOST}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o ServerAliveInterval=30)
REMOTE_ARGS=()

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; }

usage() {
    cat <<EOF
用法: deploy-remote.sh [选项]

  从本机 SSH 到远端，执行 deploy-online.sh（git pull + compose build/up + edge-nginx）。

选项：
  --skip-build    远端不 docker build，仅 compose up -d（改 .env 后快速重启）
  -h, --help      显示帮助

示例：
  ./deploy-remote.sh
  ./deploy-remote.sh --skip-build
  GIT_BRANCH=dev REMOTE_HOST=1.2.3.4 ./deploy-remote.sh
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) REMOTE_ARGS+=(--skip-build) ;;
        -h|--help) usage; exit 0 ;;
        *) err "未知参数: $1"; usage; exit 1 ;;
    esac
    shift
done

if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1; then
    err "需要 ssh 与 scp"
    exit 1
fi

[[ -f "${SCRIPT_DIR}/deploy-online.sh" ]] || { err "缺少 ${SCRIPT_DIR}/deploy-online.sh"; exit 1; }

echo "═══════════════════════════════════════════════════════════════"
echo "  new-api 远程部署（本机 → 远端）"
echo "  目标：    ${REMOTE}"
echo "  仓库：    ${GIT_REMOTE_URL} @ ${GIT_BRANCH}"
echo "  远端路径：${REMOTE_REPO_PATH}"
echo "  访问：    https://${EDGE_DOMAIN}  https://${EDGE_DOMAIN_ALT}"
echo "═══════════════════════════════════════════════════════════════"

log "[1/4] 测试 SSH..."
if ! ssh "${SSH_OPTS[@]}" "${REMOTE}" 'echo "  ssh OK ($(whoami)@$(hostname))"'; then
    err "无法连接 ${REMOTE}，请先跑 devops/init_new_node/create_new_machine.sh"
    exit 1
fi

log "[2/4] 同步 deploy-online.sh 到远端..."
scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/deploy-online.sh" "${REMOTE}:/tmp/deploy-online.sh"
ssh "${SSH_OPTS[@]}" "${REMOTE}" 'chmod +x /tmp/deploy-online.sh'
ok "已更新 /tmp/deploy-online.sh"

log "[3/4] 远端执行部署（日志如下）..."
echo "───────────────────────────────────────────────────────────────"
REMOTE_SHELL="REPO_URL=$(printf '%q' "${GIT_REMOTE_URL}") REPO_BRANCH=$(printf '%q' "${GIT_BRANCH}") REPO_DIR=$(printf '%q' "${REMOTE_REPO_PATH}") DATA_ROOT=/home/work/data bash /tmp/deploy-online.sh"
if ((${#REMOTE_ARGS[@]} > 0)); then
    for _a in "${REMOTE_ARGS[@]}"; do
        REMOTE_SHELL+=" $(printf '%q' "${_a}")"
    done
fi
set +e
ssh "${SSH_OPTS[@]}" -t "${REMOTE}" "${REMOTE_SHELL}"
REMOTE_STATUS=$?
set -e
echo "───────────────────────────────────────────────────────────────"

if [[ ${REMOTE_STATUS} -ne 0 ]]; then
    err "远端部署失败（exit ${REMOTE_STATUS}）"
    echo "排查："
    echo "  ssh ${REMOTE} 'docker logs --tail 80 new-api'"
    echo "  ssh ${REMOTE} 'docker exec edge-nginx nginx -t'"
    exit "${REMOTE_STATUS}"
fi

log "[4/4] 远端容器状态..."
ssh "${SSH_OPTS[@]}" "${REMOTE}" bash -s <<'STATUS_EOF'
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' \
  | grep -E '^(NAMES|edge-nginx|new-api|new-api-postgres|new-api-redis)' || docker ps
STATUS_EOF

echo
echo "═══════════════════════════════════════════════════════════════"
ok "远程部署完成"
echo "  访问：     https://${EDGE_DOMAIN}  https://${EDGE_DOMAIN_ALT}"
echo "  应用日志： ssh ${REMOTE} 'ls -la /home/work/data/log'"
echo "  Edge 日志：ssh ${REMOTE} 'tail -f /home/work/data/log/edge-nginx/proxy.log'"
echo "  跟踪应用： ssh ${REMOTE} 'docker logs -f new-api'"
echo "═══════════════════════════════════════════════════════════════"
