#!/usr/bin/env bash
# 步骤 2：上传导出包到远端，在远端覆盖 PostgreSQL / Redis 数据
#
# 用法：
#   ./02-restore-remote.sh                    # 使用 out/.latest 指向的目录
#   ./02-restore-remote.sh ./out/20260522-120000
#   ./02-restore-remote.sh --postgres-only ./out/20260522-120000
#
# 环境变量（与 deploy-remote.sh 一致）：
#   REMOTE_HOST REMOTE_USER REMOTE_REPO_PATH

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

REMOTE_HOST="${REMOTE_HOST:-43.155.195.115}"
REMOTE_USER="${REMOTE_USER:-work}"
REMOTE_REPO_PATH="${REMOTE_REPO_PATH:-/home/work/new-api}"
DATA_ROOT="${DATA_ROOT:-/home/work/data}"
REMOTE="${REMOTE_USER}@${REMOTE_HOST}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)

RESTORE_PG=1
RESTORE_REDIS=1
DUMP_DIR=""
AUTO_YES=0

for arg in "$@"; do
    case "$arg" in
        --postgres-only) RESTORE_REDIS=0 ;;
        --redis-only) RESTORE_PG=0 ;;
        --yes|-y) AUTO_YES=1 ;;
        -h|--help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *)
            if [[ -z "${DUMP_DIR}" ]]; then
                DUMP_DIR="$arg"
            else
                echo "多余参数: $arg" >&2; exit 1
            fi
            ;;
    esac
done

if [[ -z "${DUMP_DIR}" ]]; then
    if [[ -f "${SCRIPT_DIR}/out/.latest" ]]; then
        DUMP_DIR="$(cat "${SCRIPT_DIR}/out/.latest")"
    else
        echo "ERROR: 请指定导出目录，或先执行 ./01-dump-local.sh" >&2
        exit 1
    fi
fi

[[ -d "${DUMP_DIR}" ]] || { echo "ERROR: 目录不存在: ${DUMP_DIR}" >&2; exit 1; }
[[ "${RESTORE_PG}" -eq 1 && -f "${DUMP_DIR}/postgres.sql" ]] || [[ "${RESTORE_PG}" -eq 0 ]] || {
    echo "ERROR: 缺少 ${DUMP_DIR}/postgres.sql" >&2; exit 1
}
[[ "${RESTORE_REDIS}" -eq 1 && -f "${DUMP_DIR}/redis.rdb" ]] || [[ "${RESTORE_REDIS}" -eq 0 ]] || {
    echo "ERROR: 缺少 ${DUMP_DIR}/redis.rdb" >&2; exit 1
}

REMOTE_STAGING="/tmp/new-api-db-sync-$$"
REMOTE_RESTORE="${SCRIPT_DIR}/restore-on-remote.sh"

log() { echo "[$(date +%H:%M:%S)] $*"; }

echo "═══════════════════════════════════════════════════════════════"
echo "  步骤 2/2 · 上传并覆盖远端数据库"
echo "  本地包：  ${DUMP_DIR}"
echo "  远端：    ${REMOTE}"
echo "  ⚠️  将覆盖远端 ${DATA_ROOT} 中 postgres / redis 数据"
echo "═══════════════════════════════════════════════════════════════"

if [[ "${AUTO_YES}" -ne 1 ]]; then
    read -rp "确认继续？[y/N] " confirm
    [[ "${confirm}" =~ ^[yY]$ ]] || { echo "已取消"; exit 0; }
fi

log "测试 SSH..."
ssh "${SSH_OPTS[@]}" "${REMOTE}" 'echo "  ssh OK"'

log "上传数据包..."
ssh "${SSH_OPTS[@]}" "${REMOTE}" "rm -rf '${REMOTE_STAGING}' && mkdir -p '${REMOTE_STAGING}'"
scp "${SSH_OPTS[@]}" "${REMOTE_RESTORE}" "${REMOTE}:${REMOTE_STAGING}/restore-on-remote.sh"
[[ "${RESTORE_PG}" -eq 1 ]] && scp "${SSH_OPTS[@]}" "${DUMP_DIR}/postgres.sql" "${REMOTE}:${REMOTE_STAGING}/"
[[ "${RESTORE_REDIS}" -eq 1 ]] && scp "${SSH_OPTS[@]}" "${DUMP_DIR}/redis.rdb" "${REMOTE}:${REMOTE_STAGING}/"

log "远端执行导入..."
echo "───────────────────────────────────────────────────────────────"
ssh "${SSH_OPTS[@]}" -t "${REMOTE}" bash -s <<REMOTE
set -euo pipefail
chmod +x '${REMOTE_STAGING}/restore-on-remote.sh'
export REMOTE_REPO_PATH='${REMOTE_REPO_PATH}'
export DATA_ROOT='${DATA_ROOT}'
export RESTORE_PG='${RESTORE_PG}'
export RESTORE_REDIS='${RESTORE_REDIS}'
export STAGING_DIR='${REMOTE_STAGING}'
'${REMOTE_STAGING}/restore-on-remote.sh'
rm -rf '${REMOTE_STAGING}'
REMOTE
echo "───────────────────────────────────────────────────────────────"

echo
echo "完成。建议检查："
echo "  ssh ${REMOTE} 'docker logs --tail 30 new-api'"
echo "  浏览器打开 https://aiapi.thyseed.com"
