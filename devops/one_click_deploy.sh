#!/usr/bin/env bash
# new-api 真正一键：新机初始化（work 用户 + docker + 免密）+ 应用部署
#
# 用法（在 new-api 仓库根目录或 devops 下）：
#   ./devops/one_click_deploy.sh
#   ./devops/one_click_deploy.sh --skip-init    # 机器已初始化过，只部署应用
#   HOST=1.2.3.4 ./devops/one_click_deploy.sh
#
# 依赖（mac）：brew install hudochenkov/sshpass/sshpass

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INIT_DIR="${ROOT}/devops/init_new_node"
DEPLOY_DIR="${ROOT}/devops/deployment"

HOST="${HOST:-43.155.195.115}"
SKIP_INIT=0

for arg in "$@"; do
    case "$arg" in
        --skip-init) SKIP_INIT=1 ;;
        -h|--help)
            echo "用法: $0 [--skip-init]"
            echo "  默认：先跑 init_new_node/create_new_machine.sh --single，再 deployment/deploy.sh"
            exit 0
            ;;
    esac
done

if [[ ! -f "${INIT_DIR}/passwd.txt" ]]; then
    echo "[ERR] 缺少 ${INIT_DIR}/passwd.txt（可复制 passwd.txt.example）" >&2
    exit 1
fi

# 从 passwd.txt 解析该 IP 的 ubuntu 密码
read -r _ip _user _pwd <<< "$(grep -E "^[0-9]" "${INIT_DIR}/passwd.txt" | grep "${HOST}" | head -1)"
if [[ -z "${_pwd:-}" ]]; then
    echo "[ERR] passwd.txt 中找不到 ${HOST} 的记录" >&2
    exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  new-api 一键部署"
echo "  目标：${HOST}"
echo "  初始化：$([[ $SKIP_INIT -eq 1 ]] && echo 跳过 || echo 执行)"
echo "═══════════════════════════════════════════════════════════════"

if [[ $SKIP_INIT -eq 0 ]]; then
    echo
    echo ">>> [阶段 1/2] 初始化新机（work 用户 + docker + ssh 免密）..."
    chmod +x "${INIT_DIR}/create_new_machine.sh" \
        "${INIT_DIR}/create_work.sh" \
        "${INIT_DIR}/install_docker_ubuntu24.sh"
    "${INIT_DIR}/create_new_machine.sh" --single "${HOST}" "${_user:-ubuntu}" "${_pwd}"
fi

echo
echo ">>> [阶段 2/2] 部署 new-api 应用..."
chmod +x "${DEPLOY_DIR}/deploy.sh" "${DEPLOY_DIR}/remote_bootstrap.sh"
HOST="${HOST}" "${DEPLOY_DIR}/deploy.sh"

echo
echo "全部完成。"
