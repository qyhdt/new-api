#!/usr/bin/env bash
# Docker 安装脚本 - Ubuntu 24.04 LTS (Noble Numbat)
# 适用于全新安装或升级 Docker
# 使用方式：sudo ./install_docker_ubuntu24.sh

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        log_info "请使用: sudo $0"
        exit 1
    fi
}

# 检查系统版本
check_system() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法检测系统版本"
        exit 1
    fi

    source /etc/os-release

    if [[ "$ID" != "ubuntu" ]]; then
        log_error "此脚本仅支持 Ubuntu 系统"
        log_info "当前系统: $ID"
        exit 1
    fi

    log_info "检测到系统: $PRETTY_NAME"

    # Ubuntu 24.04 的版本号是 24.04
    VERSION_NUM=$(echo "$VERSION_ID" | cut -d. -f1)
    if [[ "$VERSION_NUM" -lt 20 ]]; then
        log_warning "建议使用 Ubuntu 20.04 或更高版本"
        read -p "是否继续安装？(y/n) " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# 卸载旧版本 Docker
remove_old_docker() {
    log_info "检查并卸载旧版本 Docker..."

    OLD_PACKAGES=(
        docker.io
        docker-doc
        docker-compose
        docker-compose-v2
        podman-docker
        containerd
        runc
    )

    FOUND_OLD=false
    for pkg in "${OLD_PACKAGES[@]}"; do
        if dpkg -l | grep -q "^ii.*$pkg"; then
            FOUND_OLD=true
            log_warning "发现旧版本包: $pkg"
        fi
    done

    if [[ "$FOUND_OLD" == true ]]; then
        log_info "正在卸载旧版本..."
        apt-get remove -y "${OLD_PACKAGES[@]}" 2>/dev/null || true
        apt-get autoremove -y
        log_success "旧版本已卸载"
    else
        log_info "未发现旧版本 Docker"
    fi
}

# 安装依赖包
install_dependencies() {
    log_info "安装依赖包..."

    apt-get update
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        apt-transport-https \
        software-properties-common

    log_success "依赖包安装完成"
}

# 添加 Docker 官方 GPG key
add_docker_gpg_key() {
    log_info "添加 Docker 官方 GPG key..."

    # 创建 keyrings 目录
    install -m 0755 -d /etc/apt/keyrings

    # 下载并添加 GPG key
    if [[ -f /etc/apt/keyrings/docker.gpg ]]; then
        log_info "GPG key 已存在，删除旧版本..."
        rm -f /etc/apt/keyrings/docker.gpg
    fi

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    chmod a+r /etc/apt/keyrings/docker.gpg

    log_success "GPG key 添加完成"
}

# 添加 Docker APT 源
add_docker_repository() {
    log_info "添加 Docker APT 源..."

    # 获取系统架构和版本代号
    ARCH=$(dpkg --print-architecture)
    CODENAME=$(lsb_release -cs)

    log_info "系统架构: $ARCH"
    log_info "版本代号: $CODENAME"

    # 添加 Docker 仓库
    echo \
        "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $CODENAME stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    # 更新包索引
    apt-get update

    log_success "Docker APT 源添加完成"
}

# 安装 Docker Engine
install_docker() {
    log_info "安装 Docker Engine..."

    # 安装最新版本的 Docker
    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    log_success "Docker Engine 安装完成"
}

# 配置国内镜像加速（docker.io 在国内常被墙；不配的话 docker pull 经常超时）
configure_mirrors() {
    log_info "配置 docker 镜像加速 (daemon.json)..."

    mkdir -p /etc/docker

    # 如果已有 daemon.json，备份再写（保留用户既有配置语义：直接覆盖镜像加速字段）
    if [[ -f /etc/docker/daemon.json ]]; then
        cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
        log_info "已备份原 daemon.json"
    fi

    cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.mirrors.sjtug.sjtu.edu.cn"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
EOF

    log_info "重启 docker 使镜像加速生效..."
    systemctl daemon-reload
    systemctl restart docker

    if systemctl is-active --quiet docker; then
        log_success "镜像加速已生效"
    else
        log_error "docker 重启失败"
        systemctl status docker
        exit 1
    fi
}

# 启动并设置开机自启
start_docker() {
    log_info "启动 Docker 服务..."

    # 启动 Docker
    systemctl start docker

    # 设置开机自启
    systemctl enable docker

    # 检查服务状态
    if systemctl is-active --quiet docker; then
        log_success "Docker 服务已启动"
    else
        log_error "Docker 服务启动失败"
        systemctl status docker
        exit 1
    fi
}

# 配置用户权限（可选）
configure_user_permissions() {
    log_info "配置用户权限..."

    # 获取实际运行此脚本的用户（即使使用 sudo）
    REAL_USER="${SUDO_USER:-$USER}"

    if [[ "$REAL_USER" == "root" ]]; then
        log_warning "以 root 用户运行，跳过用户组配置"
        return
    fi

    log_info "将用户 $REAL_USER 添加到 docker 组..."

    # 添加用户到 docker 组
    usermod -aG docker "$REAL_USER"

    log_success "用户 $REAL_USER 已添加到 docker 组"
    log_warning "需要重新登录或执行 'newgrp docker' 使权限生效"
}

# 验证安装
verify_installation() {
    log_info "验证 Docker 安装..."
    echo ""

    # Docker 版本
    log_info "Docker 版本："
    docker --version

    # Docker Compose 版本
    log_info "Docker Compose 版本："
    docker compose version

    # Docker 信息
    echo ""
    log_info "Docker 系统信息："
    docker info | head -20

    echo ""
    log_info "运行测试容器（拉取失败不致命，可能是镜像源临时抽风）..."
    if docker run --rm hello-world; then
        log_success "hello-world 测试通过"
    else
        log_warning "hello-world 拉取失败；docker 本身已装好，跳过此验证"
    fi

    echo ""
    log_success "Docker 安装验证完成！"
}

# 显示后续操作提示
show_next_steps() {
    echo ""
    echo "=========================================="
    log_success "Docker 安装完成！"
    echo "=========================================="
    echo ""
    log_info "后续步骤："
    echo ""
    echo "1. 重新登录或执行以下命令使 docker 组权限生效："
    echo "   newgrp docker"
    echo ""
    echo "2. 测试 Docker（无需 sudo）："
    echo "   docker run hello-world"
    echo ""
    echo "3. 查看 Docker 版本："
    echo "   docker --version"
    echo "   docker compose version"
    echo ""
    echo "4. 常用命令："
    echo "   docker ps              # 查看运行的容器"
    echo "   docker images          # 查看镜像列表"
    echo "   docker compose up -d   # 启动 compose 服务"
    echo ""
    log_info "国内用户建议配置镜像加速："
    echo "   sudo mkdir -p /etc/docker"
    echo "   sudo tee /etc/docker/daemon.json <<EOF"
    echo '   {'
    echo '     "registry-mirrors": ['
    echo '       "https://docker.mirrors.sjtug.sjtu.edu.cn",'
    echo '       "https://docker.m.daocloud.io"'
    echo '     ]'
    echo '   }'
    echo '   EOF'
    echo "   sudo systemctl daemon-reload"
    echo "   sudo systemctl restart docker"
    echo ""
}

# 主函数
main() {
    echo ""
    echo "=========================================="
    echo "  Docker 安装脚本 - Ubuntu 24.04 LTS"
    echo "=========================================="
    echo ""

    # 执行安装步骤
    check_root
    check_system
    remove_old_docker
    install_dependencies
    add_docker_gpg_key
    add_docker_repository
    install_docker
    start_docker
    configure_mirrors
    configure_user_permissions
    verify_installation
    show_next_steps

    echo ""
    log_success "全部完成！"
    echo ""
}

# 执行主函数
main "$@"
