#!/bin/bash
set -e

# 允许 root 或具备 sudo 的用户执行
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo > /dev/null 2>&1; then
        echo "[create_work] not running as root, re-executing with sudo..."
        exec sudo -- bash "$0" "$@"
    else
        echo "[create_work] must be run as root, but 'sudo' is not installed." >&2
        exit 1
    fi
fi

USER_NAME="work"
GROUP_NAME="work"
HOME_DIR="/home/work"
SUDO_FILE="/etc/sudoers.d/${USER_NAME}"
PASSWORD='NewApi@work2026'

if ! getent group "${GROUP_NAME}" > /dev/null; then
    groupadd "${GROUP_NAME}"
fi

if id "${USER_NAME}" > /dev/null 2>&1; then
    echo "User ${USER_NAME} already exists, skip useradd / chpasswd."
else
    useradd -m -d "${HOME_DIR}" -s /bin/bash -g "${GROUP_NAME}" "${USER_NAME}"
    echo "${USER_NAME}:${PASSWORD}" | chpasswd
fi

mkdir -p "${HOME_DIR}"
chown -R "${USER_NAME}:${GROUP_NAME}" "${HOME_DIR}"
chmod 750 "${HOME_DIR}"

echo "${USER_NAME} ALL=(ALL:ALL) NOPASSWD: ALL" > "${SUDO_FILE}"
chmod 440 "${SUDO_FILE}"
if command -v visudo > /dev/null 2>&1; then
    if ! visudo -cf "${SUDO_FILE}"; then
        echo "[create_work] sudoers syntax error, removed ${SUDO_FILE}" >&2
        rm -f "${SUDO_FILE}"
        exit 1
    fi
fi

echo "User ${USER_NAME} initialized (sudo: passwordless / NOPASSWD)."

# -----------------------------------------------------------------------------
# new-api 运行数据目录（与 docker-compose 绑定路径一致）
#   /home/work/data/postgres  ← PostgreSQL 持久化
#   /home/work/data/redis     ← Redis 持久化
#   /home/work/data/log       ← new-api 应用日志
#   /home/work/data/app-data  ← new-api /data 卷（上传文件等）
# -----------------------------------------------------------------------------
DATA_ROOT="${HOME_DIR}/data"

mkdir -p "${DATA_ROOT}/postgres" "${DATA_ROOT}/redis" "${DATA_ROOT}/log" "${DATA_ROOT}/app-data" \
    "${DATA_ROOT}/log/edge-nginx" "${DATA_ROOT}/runtime/edge-proxy"
chown -R "${USER_NAME}:${GROUP_NAME}" "${DATA_ROOT}"
chmod -R 0775 "${DATA_ROOT}"

echo "Data dirs ready: ${DATA_ROOT} (postgres, redis, log, app-data)"
