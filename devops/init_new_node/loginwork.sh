#!/usr/bin/env bash
# 免密 ssh 进 work 账号
#
# 用法：
#   ./loginwork.sh             # 单机时直接登；多机时列出让选
#   ./loginwork.sh <ip>        # 直接登指定 ip
#   ./loginwork.sh -i 0        # 按 machine.list 索引登（0 = 第一行）
#
# 前提：已用 create_new_machine.sh 完成初始化，本机 ~/.ssh/id_rsa 已加进远端 work 的 authorized_keys

set -uo pipefail
cd "$(dirname "$0")"

MACHINE_LIST="machine.list"
WORK_USER="work"

[[ ! -f "$MACHINE_LIST" ]] && { echo "缺少 $MACHINE_LIST"; exit 1; }

# 读 machine.list 进数组（跳空行和注释）
IPS=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(echo "$line" | tr -d '[:space:]')"
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    IPS+=("$line")
done < "$MACHINE_LIST"

[[ ${#IPS[@]} -eq 0 ]] && { echo "$MACHINE_LIST 里没有可用 ip"; exit 1; }

# 解析参数
TARGET=""
if [[ $# -eq 0 ]]; then
    if [[ ${#IPS[@]} -eq 1 ]]; then
        TARGET="${IPS[0]}"
    else
        echo "选择要登的机器："
        for i in "${!IPS[@]}"; do
            printf "  [%d] %s\n" "$i" "${IPS[$i]}"
        done
        read -rp "序号: " idx
        [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -lt "${#IPS[@]}" ]] || { echo "序号无效"; exit 1; }
        TARGET="${IPS[$idx]}"
    fi
elif [[ "$1" == "-i" ]]; then
    idx="${2:-}"
    [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -lt "${#IPS[@]}" ]] || { echo "序号无效，machine.list 里只有 ${#IPS[@]} 台"; exit 1; }
    TARGET="${IPS[$idx]}"
else
    TARGET="$1"
fi

echo "→ ssh ${WORK_USER}@${TARGET}"
exec ssh -o StrictHostKeyChecking=accept-new "${WORK_USER}@${TARGET}"
