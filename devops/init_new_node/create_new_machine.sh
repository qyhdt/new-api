#!/usr/bin/env bash
# 一键初始化新机（new-api 运维）：
#   1. 读 machine.list / passwd.txt
#   2. 用 ubuntu 用户 + 密码登入，创建 work 用户 (NOPASSWD sudo)
#   3. 推本机 ~/.ssh/id_rsa.pub 到 work@<ip> 实现免密
#   4. 校验 work 免密 ssh 可用
#   5. 装 docker
#   6. 在远端 work 用户下生成 ssh key（如不存在），把公钥拉回本地 ./keys/<ip>/work_id_rsa.pub
#
# 用法：
#   cd devops/init_new_node && ./create_new_machine.sh
#
#   # 单机模式（不读 passwd.txt / machine.list，直接传参；供 backend 触发）：
#   ./create_new_machine.sh --single <ip> <user> <password>
#
# 失败策略：单机失败不中断整体，最后汇总成功/失败列表。

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

MACHINE_LIST="${HERE}/machine.list"
PASSWD_FILE="${HERE}/passwd.txt"
CREATE_WORK_SH="${HERE}/create_work.sh"
INSTALL_DOCKER_SH="${HERE}/install_docker_ubuntu24.sh"
KEYS_DIR="${HERE}/keys"
LOGS_DIR="${HERE}/logs"

WORK_USER="work"
TS="$(date +%Y%m%d-%H%M%S)"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; }

# ------------------------------------------------------------------
# 1. 依赖与前置文件检查
# ------------------------------------------------------------------
preflight() {
    local missing=0
    for cmd in sshpass ssh scp ssh-keygen; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            err "缺少命令: $cmd"
            [[ "$cmd" == "sshpass" ]] && echo "  安装: brew install hudochenkov/sshpass/sshpass"
            missing=1
        fi
    done
    [[ ! -f "$MACHINE_LIST"  ]] && { err "缺少 $MACHINE_LIST"; missing=1; }
    [[ ! -f "$PASSWD_FILE"   ]] && { err "缺少 $PASSWD_FILE"; missing=1; }
    [[ ! -f "$CREATE_WORK_SH"    ]] && { err "缺少 $CREATE_WORK_SH"; missing=1; }
    [[ ! -f "$INSTALL_DOCKER_SH" ]] && { err "缺少 $INSTALL_DOCKER_SH"; missing=1; }
    [[ $missing -eq 1 ]] && exit 1

    # 本机 ssh key
    if [[ ! -f "${HOME}/.ssh/id_rsa" ]]; then
        log "本机 ~/.ssh/id_rsa 不存在，生成中（无 passphrase）..."
        ssh-keygen -t rsa -b 4096 -N "" -f "${HOME}/.ssh/id_rsa" -C "$(whoami)@$(hostname)"
    fi

    mkdir -p "$KEYS_DIR" "$LOGS_DIR"
}

# ------------------------------------------------------------------
# 2. 解析 passwd.txt
#    格式：每行一台机器，三列空白分隔：
#        <ip>  <user>  <password>
#    例：
#        82.157.96.180  ubuntu  #w4b#Eue!yQEYR
#    约定：
#      - 密码不含空白字符
#      - 以 # 开头的整行视作注释跳过（注意：密码本身可以以 # 开头，因为前面有 ip 列）
#      - 空行跳过
#
#    输出：填充并行数组 IPS / USRS / PWDS
#    （不用关联数组，兼容 macOS 自带 bash 3.2）
# ------------------------------------------------------------------
IPS=()
USRS=()
PWDS=()

parse_passwd() {
    local line ip user pwd
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 去掉行首尾空白
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        # 跳过空行 / 整行注释
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        # 用空白拆三列
        # shellcheck disable=SC2086
        read -r ip user pwd <<< "$line"
        if [[ -z "$ip" || -z "$user" || -z "$pwd" ]]; then
            warn "passwd.txt 这行解析不齐 (ip/user/password)，跳过: $line"
            continue
        fi
        # 简单校验 ip 形状
        if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            warn "第一列不是 ipv4，跳过: $line"
            continue
        fi
        IPS+=("$ip")
        USRS+=("$user")
        PWDS+=("$pwd")
    done < "$PASSWD_FILE"
}

# 在 IPS 里找 ip，echo 它的 user 和 pwd（用 tab 分隔），找不到返回非零
lookup_passwd() {
    local target="$1" i
    for i in "${!IPS[@]}"; do
        if [[ "${IPS[$i]}" == "$target" ]]; then
            printf '%s\t%s\n' "${USRS[$i]}" "${PWDS[$i]}"
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------------
# 3. 单机初始化
# ------------------------------------------------------------------
SSH_OPTS=(
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile="${HOME}/.ssh/known_hosts"
    -o ConnectTimeout=10
    -o ServerAliveInterval=30
)

init_one() {
    local ip="$1" user="$2" pwd="$3"

    # ---- Step 1-2: 上传 + 执行 create_work.sh
    log "[$ip] (1/6) 上传 create_work.sh"
    sshpass -p "$pwd" scp "${SSH_OPTS[@]}" "$CREATE_WORK_SH" "${user}@${ip}:/tmp/create_work.sh" || { err "[$ip] scp create_work.sh 失败"; return 1; }

    log "[$ip] (2/6) 远端执行 create_work.sh (sudo 创建 work 用户)"
    sshpass -p "$pwd" ssh "${SSH_OPTS[@]}" "${user}@${ip}" \
        "sudo bash /tmp/create_work.sh && rm -f /tmp/create_work.sh" \
        || { err "[$ip] create_work.sh 执行失败"; return 1; }

    # ---- Step 3: 推本机公钥到 work 的 authorized_keys（幂等去重）
    log "[$ip] (3/6) 推送本机公钥到 work 用户"
    local pub_content
    pub_content="$(cat "${HOME}/.ssh/id_rsa.pub")"
    # shellcheck disable=SC2087
    sshpass -p "$pwd" ssh "${SSH_OPTS[@]}" "${user}@${ip}" "sudo bash -s" <<EOF || { err "[$ip] 推公钥失败"; return 1; }
set -e
install -d -o ${WORK_USER} -g ${WORK_USER} -m 700 /home/${WORK_USER}/.ssh
touch /home/${WORK_USER}/.ssh/authorized_keys
chown ${WORK_USER}:${WORK_USER} /home/${WORK_USER}/.ssh/authorized_keys
chmod 600 /home/${WORK_USER}/.ssh/authorized_keys
# 用 grep -qxF 判断是否已存在，避免重复追加
PUB='${pub_content}'
if ! grep -qxF "\$PUB" /home/${WORK_USER}/.ssh/authorized_keys 2>/dev/null; then
    echo "\$PUB" >> /home/${WORK_USER}/.ssh/authorized_keys
fi
EOF

    # ---- Step 4: 校验 work 免密
    log "[$ip] (4/6) 校验 work@${ip} 免密 ssh"
    local who
    who=$(ssh "${SSH_OPTS[@]}" -i "${HOME}/.ssh/id_rsa" -o BatchMode=yes "${WORK_USER}@${ip}" whoami 2>&1) || {
        err "[$ip] work 免密 ssh 失败: $who"
        return 1
    }
    [[ "$who" != "$WORK_USER" ]] && { err "[$ip] whoami 返回 '$who'，期望 '$WORK_USER'"; return 1; }

    # ---- Step 5: 装 docker
    log "[$ip] (5/6) 安装 docker"
    scp "${SSH_OPTS[@]}" "$INSTALL_DOCKER_SH" "${WORK_USER}@${ip}:/tmp/install_docker.sh" \
        || { err "[$ip] scp docker 脚本失败"; return 1; }
    # 远端跑 docker 安装；hello-world 验证步骤可能因网络/镜像源失败，先放宽
    ssh "${SSH_OPTS[@]}" "${WORK_USER}@${ip}" \
        "sudo bash /tmp/install_docker.sh && rm -f /tmp/install_docker.sh" \
        || { err "[$ip] docker 安装失败"; return 1; }

    # ---- Step 6: 远端 work 生成 sshkey + 拉回公钥
    log "[$ip] (6/6) 生成 work 用户 ssh key 并拉回公钥"
    ssh "${SSH_OPTS[@]}" "${WORK_USER}@${ip}" \
        '[[ -f ~/.ssh/id_rsa ]] || ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa -C "work@'"${ip}"'"' \
        || { err "[$ip] 远端 ssh-keygen 失败"; return 1; }

    mkdir -p "${KEYS_DIR}/${ip}"
    ssh "${SSH_OPTS[@]}" "${WORK_USER}@${ip}" 'cat ~/.ssh/id_rsa.pub' > "${KEYS_DIR}/${ip}/work_id_rsa.pub" \
        || { err "[$ip] 拉回公钥失败"; return 1; }

    if [[ ! -s "${KEYS_DIR}/${ip}/work_id_rsa.pub" ]]; then
        err "[$ip] 拉回的公钥文件为空"
        return 1
    fi

    ok "[$ip] 完成。公钥已保存到 ${KEYS_DIR}/${ip}/work_id_rsa.pub"
    return 0
}

# ------------------------------------------------------------------
# 4. 主流程
# ------------------------------------------------------------------
main() {
    preflight

    local OK_LIST=() FAIL_LIST=()
    local ip log_file row user pwd

    # ---------- 单机模式（backend 调用走这条分支）-----------
    if [[ "${1:-}" == "--single" ]]; then
        ip="${2:-}"
        user="${3:-}"
        pwd="${4:-}"
        if [[ -z "$ip" || -z "$user" || -z "$pwd" ]]; then
            err "--single 模式参数不全；用法：--single <ip> <user> <password>"
            exit 1
        fi
        if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            err "ip 非 ipv4: $ip"
            exit 1
        fi

        log_file="${LOGS_DIR}/${TS}-${ip}.log"
        echo "========== ${ip} (single mode) ==========" | tee "$log_file"
        init_one "$ip" "$user" "$pwd" 2>&1 | tee -a "$log_file"
        if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
            OK_LIST+=("$ip")
        else
            FAIL_LIST+=("$ip")
        fi
    else
        # ---------- 批量模式 ----------
        parse_passwd

        if [[ ${#IPS[@]} -eq 0 ]]; then
            err "passwd.txt 没解析到任何机器，检查格式（每行需为：<ip> <user> <password>）"
            exit 1
        fi

        while IFS= read -r ip || [[ -n "$ip" ]]; do
            ip="$(echo "$ip" | tr -d '[:space:]')"
            [[ -z "$ip" || "$ip" =~ ^# ]] && continue

            if ! row=$(lookup_passwd "$ip"); then
                err "[$ip] passwd.txt 里查不到密码，跳过"
                FAIL_LIST+=("$ip")
                continue
            fi
            user="${row%%$'\t'*}"
            pwd="${row#*$'\t'}"

            log_file="${LOGS_DIR}/${TS}-${ip}.log"
            echo "========== ${ip} ==========" | tee "$log_file"
            # 单机内的输出同时写日志和终端；tee 的 exit code 不反映 init_one，用 PIPESTATUS
            init_one "$ip" "$user" "$pwd" 2>&1 | tee -a "$log_file"
            if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
                OK_LIST+=("$ip")
            else
                FAIL_LIST+=("$ip")
            fi
            echo ""
        done < "$MACHINE_LIST"
    fi

    echo "============================================"
    echo "         汇总  (${TS})"
    echo "============================================"
    if [[ ${#OK_LIST[@]} -gt 0 ]]; then
        ok "成功 (${#OK_LIST[@]}): ${OK_LIST[*]}"
    fi
    if [[ ${#FAIL_LIST[@]} -gt 0 ]]; then
        err "失败 (${#FAIL_LIST[@]}): ${FAIL_LIST[*]}"
        echo "  详细日志: ${LOGS_DIR}/${TS}-<ip>.log"
        exit 2
    fi
    echo ""
    echo "下一步：把 keys/<ip>/work_id_rsa.pub 内容添加到 GitHub → Settings → SSH Keys（私库 git clone 需要）"
    echo "然后在本机执行：  ./devops/one_click_deploy.sh --skip-init"
}

main "$@"
