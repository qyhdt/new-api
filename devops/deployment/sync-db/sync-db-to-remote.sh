#!/usr/bin/env bash
# 一键：本地导出 → 上传远端 → 覆盖远端数据库（依次执行 01 + 02）
#
# 用法：
#   ./sync-db-to-remote.sh
#   ./sync-db-to-remote.sh --postgres-only
#   ./sync-db-to-remote.sh --yes    # 跳过确认

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKIP_CONFIRM=0
DUMP_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --yes|-y) SKIP_CONFIRM=1 ;;
        -h|--help)
            echo "用法: $0 [--yes] [--postgres-only|--redis-only]"
            echo "  1) ./01-dump-local.sh"
            echo "  2) ./02-restore-remote.sh <最新导出目录>"
            exit 0
            ;;
        *) DUMP_ARGS+=("$arg") ;;
    esac
done

echo ">>> 步骤 1：本地导出"
"${SCRIPT_DIR}/01-dump-local.sh" "${DUMP_ARGS[@]}"
OUT_DIR="$(cat "${SCRIPT_DIR}/out/.latest")"

echo
echo ">>> 步骤 2：上传并覆盖远端"
CONFIRM_ARGS=()
[[ "${SKIP_CONFIRM}" -eq 1 ]] && CONFIRM_ARGS=(--yes)
"${SCRIPT_DIR}/02-restore-remote.sh" "${CONFIRM_ARGS[@]}" "${DUMP_ARGS[@]}" "${OUT_DIR}"
