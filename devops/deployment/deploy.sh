#!/usr/bin/env bash
# 本地一键部署 new-api 到远端 work 用户（需已完成 init_new_node 或配合 one_click_deploy.sh）
#
# 用法：
#   ./deploy.sh
#   HOST=43.155.195.115 ./deploy.sh
#   REMOTE_USER=work REPO_BRANCH=main ./deploy.sh
#
# 前置：本机 ssh 免密 work@${HOST}（create_new_machine.sh 已配置）

set -euo pipefail
cd "$(dirname "$0")"

HOST="${HOST:-43.155.195.115}"
REMOTE_USER="${REMOTE_USER:-work}"
REPO_URL="${REPO_URL:-git@github.com:qyhdt/new-api.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

echo "═══════════════════════════════════════════════════════════════"
echo "  部署目标：${REMOTE_USER}@${HOST}"
echo "  仓库：    ${REPO_URL} (${REPO_BRANCH})"
echo "  数据目录：/home/work/data/{postgres,redis,log,app-data}"
echo "═══════════════════════════════════════════════════════════════"

echo
echo "[1/3] 测试 ssh..."
ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${HOST}" 'echo "  ssh OK ($(whoami)@$(hostname))"'

echo
echo "[2/3] 推送 remote_bootstrap.sh..."
ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${HOST}" 'mkdir -p ~/new-api-bootstrap'
scp "${SSH_OPTS[@]}" remote_bootstrap.sh "${REMOTE_USER}@${HOST}:~/new-api-bootstrap/remote_bootstrap.sh"
ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${HOST}" 'chmod +x ~/new-api-bootstrap/remote_bootstrap.sh'

echo
echo "[3/3] 远端执行 remote_bootstrap.sh（拉代码 + build，可能需数分钟）..."
echo "─── 远端输出 ───"
ssh "${SSH_OPTS[@]}" -t "${REMOTE_USER}@${HOST}" \
    "REPO_URL='${REPO_URL}' REPO_BRANCH='${REPO_BRANCH}' bash ~/new-api-bootstrap/remote_bootstrap.sh"

PORT="${NEW_API_PORT:-3000}"
echo
echo "═══════════════════════════════════════════════════════════════"
echo "  完成。浏览器访问：  http://${HOST}:${PORT}"
echo "  应用日志（host）：  /home/work/data/log"
echo "═══════════════════════════════════════════════════════════════"
echo "排查："
echo "  ssh ${REMOTE_USER}@${HOST} 'docker logs -f new-api'"
echo "  ssh ${REMOTE_USER}@${HOST} 'ls -la /home/work/data/log'"
