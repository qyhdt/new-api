#!/usr/bin/env bash
# New API 本地开发一键启动：后端 (Go) + 前端 (Rsbuild)
# 用法:
#   ./dev.sh          # 启动
#   ./dev.sh start    # 启动
#   ./dev.sh stop     # 停止
#   ./dev.sh restart  # 重启
#   ./dev.sh status   # 查看状态
#   ./dev.sh logs     # 查看日志（tail -f）

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="${ROOT_DIR}/web/default"
DEV_DIR="${ROOT_DIR}/.dev"
BACKEND_PID_FILE="${DEV_DIR}/backend.pid"
FRONTEND_PID_FILE="${DEV_DIR}/frontend.pid"
BACKEND_LOG="${DEV_DIR}/backend.log"
FRONTEND_LOG="${DEV_DIR}/frontend.log"

BACKEND_PORT="${BACKEND_PORT:-3000}"
FRONTEND_PORT="${FRONTEND_PORT:-3001}"
GO_MIN_VERSION="1.25"
NODE_MIN_MAJOR=20

# PostgreSQL + Redis（Docker）
DEV_COMPOSE_FILE="${ROOT_DIR}/docker-compose.infra.yml"
POSTGRES_PORT="${POSTGRES_PORT:-5435}"
POSTGRES_USER="${POSTGRES_USER:-root}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-123456}"
POSTGRES_DB="${POSTGRES_DB:-new-api}"
REDIS_PORT="${REDIS_PORT:-6380}"
REDIS_PASSWORD="${REDIS_PASSWORD:-123456}"
DEFAULT_SQL_DSN="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:${POSTGRES_PORT}/${POSTGRES_DB}"
DEFAULT_REDIS_CONN_STRING="redis://:${REDIS_PASSWORD}@127.0.0.1:${REDIS_PORT}/0"
# 设为 sqlite 可退回 SQLite 模式: DEV_DB=sqlite ./dev.sh
DEV_DB="${DEV_DB:-postgres}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[dev]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[dev]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[dev]${NC} $*"; }
log_error() { echo -e "${RED}[dev]${NC} $*" >&2; }

version_ge() {
  local current="$1" required="$2"
  [ "$(printf '%s\n%s\n' "$required" "$current" | sort -V | head -n1)" = "$required" ]
}

go_version() {
  go version 2>/dev/null | sed -nE 's/.*go([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p'
}

node_major() {
  node -v 2>/dev/null | sed -nE 's/^v([0-9]+).*/\1/p'
}

has_brew() { command -v brew >/dev/null 2>&1; }

install_with_brew() {
  local pkg="$1"
  if ! has_brew; then
    log_error "未检测到 Homebrew，请先安装: https://brew.sh"
    log_error "或手动安装 ${pkg} 后重新运行本脚本"
    exit 1
  fi
  log_info "正在通过 Homebrew 安装 ${pkg}..."
  brew install "$pkg"
}

ensure_go() {
  if command -v go >/dev/null 2>&1; then
    local gv
    gv="$(go_version)"
    if version_ge "$gv" "$GO_MIN_VERSION"; then
      log_ok "Go ${gv}"
      return 0
    fi
    log_warn "当前 Go ${gv}，项目要求 >= ${GO_MIN_VERSION}，尝试升级..."
    if has_brew; then
      brew upgrade go || brew install go
    fi
  else
    log_warn "未检测到 Go，正在安装..."
    install_with_brew go
  fi

  if ! command -v go >/dev/null 2>&1; then
    log_error "Go 安装失败"
    exit 1
  fi
  local gv
  gv="$(go_version)"
  if ! version_ge "$gv" "$GO_MIN_VERSION"; then
    log_error "Go 版本 ${gv} 仍低于 ${GO_MIN_VERSION}，请手动升级后重试"
    exit 1
  fi
  log_ok "Go ${gv} 已就绪"
}

ensure_node() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    local major
    major="$(node_major)"
    if [ -n "$major" ] && [ "$major" -ge "$NODE_MIN_MAJOR" ]; then
      log_ok "Node $(node -v) / npm $(npm -v)"
      return 0
    fi
    log_warn "Node 版本过低 ($(node -v))，尝试升级..."
    if has_brew; then
      brew upgrade node || brew install node
    fi
  else
    log_warn "未检测到 Node.js，正在安装..."
    install_with_brew node
  fi

  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    log_error "Node.js / npm 安装失败"
    exit 1
  fi
  local major
  major="$(node_major)"
  if [ -z "$major" ] || [ "$major" -lt "$NODE_MIN_MAJOR" ]; then
    log_error "Node 版本需 >= v${NODE_MIN_MAJOR}，当前: $(node -v 2>/dev/null || echo unknown)"
    exit 1
  fi
  log_ok "Node $(node -v) 已就绪"
}

ensure_env_file() {
  if [ ! -f "${ROOT_DIR}/.env" ] && [ -f "${ROOT_DIR}/.env.example" ]; then
    cp "${ROOT_DIR}/.env.example" "${ROOT_DIR}/.env"
    log_info "已从 .env.example 创建 .env（可按需修改）"
  fi
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log_error "使用 PostgreSQL/Redis 需要 Docker，请先安装: https://www.docker.com/products/docker-desktop/"
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    log_error "Docker 未运行，请先启动 Docker Desktop"
    exit 1
  fi
}

wait_for_postgres() {
  local retries="${1:-60}"
  log_info "等待 PostgreSQL 就绪 (127.0.0.1:${POSTGRES_PORT})..."
  for i in $(seq 1 "$retries"); do
    if command -v pg_isready >/dev/null 2>&1; then
      if pg_isready -h 127.0.0.1 -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
        return 0
      fi
    elif docker compose -f "$DEV_COMPOSE_FILE" exec -T postgres \
      pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
      return 0
    elif nc -z 127.0.0.1 "$POSTGRES_PORT" 2>/dev/null; then
      # 端口已开，再等几秒让 init 完成
      sleep 2
      if docker compose -f "$DEV_COMPOSE_FILE" exec -T postgres \
        pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

wait_for_redis() {
  local retries="${1:-30}"
  log_info "等待 Redis 就绪 (127.0.0.1:${REDIS_PORT})..."
  for _ in $(seq 1 "$retries"); do
    if command -v redis-cli >/dev/null 2>&1; then
      if redis-cli -h 127.0.0.1 -p "$REDIS_PORT" -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG; then
        return 0
      fi
    elif docker compose -f "$DEV_COMPOSE_FILE" exec -T redis \
      redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG; then
      return 0
    elif nc -z 127.0.0.1 "$REDIS_PORT" 2>/dev/null; then
      sleep 1
      if docker compose -f "$DEV_COMPOSE_FILE" exec -T redis \
        redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

start_dev_infra() {
  ensure_docker
  export POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB
  export REDIS_PORT REDIS_PASSWORD
  log_info "启动 PostgreSQL + Redis (docker compose)..."
  docker compose -f "$DEV_COMPOSE_FILE" up -d
  if ! wait_for_postgres 90; then
    log_error "PostgreSQL 启动超时"
    docker compose -f "$DEV_COMPOSE_FILE" logs --tail 20 postgres >&2 || true
    exit 1
  fi
  log_ok "PostgreSQL 已就绪 → ${DEFAULT_SQL_DSN}"
  if ! wait_for_redis 30; then
    log_error "Redis 启动超时"
    docker compose -f "$DEV_COMPOSE_FILE" logs --tail 20 redis >&2 || true
    exit 1
  fi
  log_ok "Redis 已就绪 → ${DEFAULT_REDIS_CONN_STRING}"
}

stop_dev_infra() {
  if command -v docker >/dev/null 2>&1 && [ -f "$DEV_COMPOSE_FILE" ]; then
    log_info "停止 PostgreSQL / Redis 容器..."
    docker compose -f "$DEV_COMPOSE_FILE" stop >/dev/null 2>&1 || true
  fi
}

load_env_for_backend() {
  # godotenv 由 main.go 加载 .env；此处导出以便子进程一致
  if [ -f "${ROOT_DIR}/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/.env"
    set +a
  fi
  if [ "$DEV_DB" = "postgres" ] && [ -z "${SQL_DSN:-}" ]; then
    export SQL_DSN="$DEFAULT_SQL_DSN"
  fi
  if [ "$DEV_DB" = "postgres" ] && [ -z "${REDIS_CONN_STRING:-}" ]; then
    export REDIS_CONN_STRING="$DEFAULT_REDIS_CONN_STRING"
  fi
  if [ "$DEV_DB" = "postgres" ] && [ -z "${MEMORY_CACHE_ENABLED:-}" ]; then
    export MEMORY_CACHE_ENABLED=true
  fi
}

# go:embed 要求编译时 dist 目录存在；开发模式用占位文件，实际 UI 走前端 dev server
ensure_embed_assets() {
  local stub_html='<!doctype html><html><head><meta charset="UTF-8"><title>New API Dev</title></head><body><p>Dev: use frontend dev server.</p></body></html>'
  local theme
  for theme in default classic; do
    local dist_dir="${ROOT_DIR}/web/${theme}/dist"
    if [ ! -f "${dist_dir}/index.html" ]; then
      mkdir -p "$dist_dir"
      printf '%s\n' "$stub_html" >"${dist_dir}/index.html"
      log_info "已创建占位静态资源: web/${theme}/dist/index.html"
    fi
  done
}

show_log_tail() {
  local log_file="$1"
  local lines="${2:-30}"
  if [ -f "$log_file" ]; then
    echo ""
    log_error "最近日志 (${log_file}):"
    tail -n "$lines" "$log_file" >&2 || true
  fi
}

frontend_install() {
  cd "$FRONTEND_DIR"
  if command -v bun >/dev/null 2>&1; then
    log_info "安装前端依赖 (bun)..."
    bun install
  else
    log_info "安装前端依赖 (npm)..."
    if [ -f package-lock.json ]; then
      npm ci
    else
      npm install
    fi
  fi
}

run_frontend_dev() {
  cd "$FRONTEND_DIR"
  export VITE_REACT_APP_SERVER_URL="http://127.0.0.1:${BACKEND_PORT}"
  export VITE_SSO_API_ORIGIN="${VITE_SSO_API_ORIGIN:-http://127.0.0.1:8081}"
  export VITE_PORTAL_URL="${VITE_PORTAL_URL:-http://127.0.0.1:5174}"
  export BROWSER=none
  if command -v bun >/dev/null 2>&1; then
    exec bun run dev -- --port "${FRONTEND_PORT}"
  else
    exec npm run dev -- --port "${FRONTEND_PORT}"
  fi
}

is_running() {
  local pid_file="$1"
  [ -f "$pid_file" ] || return 1
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

stop_pid_file() {
  local name="$1"
  local pid_file="$2"
  if ! is_running "$pid_file"; then
    rm -f "$pid_file"
    return 0
  fi
  local pid
  pid="$(cat "$pid_file")"
  log_info "停止 ${name} (pid ${pid})..."
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
}

wait_for_port() {
  local port="$1"
  local name="$2"
  local retries="${3:-120}"
  for i in $(seq 1 "$retries"); do
    if curl -fsS "http://127.0.0.1:${port}/api/status" >/dev/null 2>&1 \
      || nc -z 127.0.0.1 "$port" 2>/dev/null; then
      return 0
    fi
    # 每 15 秒提示一次（首次 go run 编译较慢）
    if [ $((i % 15)) -eq 0 ]; then
      log_info "等待 ${name} 就绪... (${i}/${retries}s)"
    fi
    sleep 1
  done
  return 1
}

start_backend() {
  if is_running "$BACKEND_PID_FILE"; then
    log_warn "后端已在运行 (pid $(cat "$BACKEND_PID_FILE"))"
    return 0
  fi

  ensure_embed_assets

  log_info "下载 Go 依赖..."
  cd "$ROOT_DIR"
  go mod download

  load_env_for_backend

  log_info "启动后端 (http://127.0.0.1:${BACKEND_PORT})，首次编译可能需 1-2 分钟..."
  if [ "$DEV_DB" = "postgres" ]; then
    log_info "数据库: PostgreSQL (${SQL_DSN:-$DEFAULT_SQL_DSN})"
    log_info "缓存:   Redis (${REDIS_CONN_STRING:-$DEFAULT_REDIS_CONN_STRING})"
  else
    log_info "数据库: SQLite (${SQLITE_PATH:-one-api.db})"
  fi
  mkdir -p "$DEV_DIR" "${ROOT_DIR}/logs" "${ROOT_DIR}/data"

  (
    cd "$ROOT_DIR"
    load_env_for_backend
    export GIN_MODE=debug
    export DEBUG="${DEBUG:-true}"
    export PORT="${BACKEND_PORT}"
    export ERROR_LOG_ENABLED="${ERROR_LOG_ENABLED:-true}"
    export TZ="${TZ:-Asia/Shanghai}"
    exec go run main.go -port "${BACKEND_PORT}" --log-dir ./logs
  ) >>"$BACKEND_LOG" 2>&1 &
  echo $! >"$BACKEND_PID_FILE"

  if ! wait_for_port "$BACKEND_PORT" "后端"; then
    stop_pid_file "后端" "$BACKEND_PID_FILE"
    log_error "后端未在 ${BACKEND_PORT} 端口就绪"
    show_log_tail "$BACKEND_LOG"
    exit 1
  fi
  log_ok "后端已启动 → http://127.0.0.1:${BACKEND_PORT}/api/status"
}

start_frontend() {
  if is_running "$FRONTEND_PID_FILE"; then
    log_warn "前端已在运行 (pid $(cat "$FRONTEND_PID_FILE"))"
    return 0
  fi

  frontend_install

  log_info "启动前端 (http://127.0.0.1:${FRONTEND_PORT})..."

  (
    run_frontend_dev
  ) >>"$FRONTEND_LOG" 2>&1 &
  echo $! >"$FRONTEND_PID_FILE"

  for _ in $(seq 1 90); do
    if curl -fsS "http://127.0.0.1:${FRONTEND_PORT}/" >/dev/null 2>&1 \
      || nc -z 127.0.0.1 "$FRONTEND_PORT" 2>/dev/null; then
      log_ok "前端已启动 → http://127.0.0.1:${FRONTEND_PORT}"
      return 0
    fi
    sleep 1
  done

  log_warn "前端端口检测超时，可能仍在编译，请查看: ${FRONTEND_LOG}"
}

cmd_start() {
  mkdir -p "$DEV_DIR"
  ensure_go
  ensure_node
  ensure_env_file

  if [ "$DEV_DB" = "postgres" ]; then
    if lsof -ti:"${POSTGRES_PORT}" >/dev/null 2>&1 \
      && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'new-api-dev-pg'; then
      log_error "端口 ${POSTGRES_PORT} 已被占用，请修改 POSTGRES_PORT 或释放端口"
      exit 1
    fi
    if lsof -ti:"${REDIS_PORT}" >/dev/null 2>&1 \
      && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'new-api-dev-redis'; then
      log_error "端口 ${REDIS_PORT} 已被占用，请修改 REDIS_PORT 或释放端口"
      exit 1
    fi
    start_dev_infra
  fi

  if lsof -ti:"${BACKEND_PORT}" >/dev/null 2>&1 && ! is_running "$BACKEND_PID_FILE"; then
    log_error "端口 ${BACKEND_PORT} 已被占用，请修改 BACKEND_PORT 或释放端口"
    exit 1
  fi
  if lsof -ti:"${FRONTEND_PORT}" >/dev/null 2>&1 && ! is_running "$FRONTEND_PID_FILE"; then
    log_error "端口 ${FRONTEND_PORT} 已被占用，请修改 FRONTEND_PORT 或释放端口"
    exit 1
  fi

  start_backend
  start_frontend

  echo ""
  log_ok "开发环境已就绪"
  echo "  ★ 请用浏览器打开控制台: http://127.0.0.1:${FRONTEND_PORT}"
  echo "  后端 API（勿直接当 UI 用）: http://127.0.0.1:${BACKEND_PORT}"
  if [ "$DEV_DB" = "postgres" ]; then
    echo "  PostgreSQL: 127.0.0.1:${POSTGRES_PORT}/${POSTGRES_DB} (用户 ${POSTGRES_USER})"
    echo "  psql:       PGPASSWORD=${POSTGRES_PASSWORD} psql -h 127.0.0.1 -p ${POSTGRES_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB}"
    echo "  Redis:      127.0.0.1:${REDIS_PORT} (密码 ${REDIS_PASSWORD})"
    echo "  redis-cli:  redis-cli -h 127.0.0.1 -p ${REDIS_PORT} -a ${REDIS_PASSWORD}"
  fi
  echo "  日志目录: ${DEV_DIR}"
  echo ""
  echo "  停止服务: ./dev.sh stop"
  echo "  查看日志: ./dev.sh logs"
}

cmd_stop() {
  local with_db="${1:-}"
  stop_pid_file "前端" "$FRONTEND_PID_FILE"
  stop_pid_file "后端" "$BACKEND_PID_FILE"
  if [ "$with_db" = "all" ] || [ "$with_db" = "--all" ]; then
    stop_dev_infra
    log_ok "已停止前后端、PostgreSQL 与 Redis"
  else
    log_ok "已停止前后端（PG/Redis 仍在运行，停止请用: ./dev.sh stop all）"
  fi
}

cmd_status() {
  if is_running "$BACKEND_PID_FILE"; then
    log_ok "后端运行中 (pid $(cat "$BACKEND_PID_FILE"), port ${BACKEND_PORT})"
  else
    log_warn "后端未运行"
  fi
  if is_running "$FRONTEND_PID_FILE"; then
    log_ok "前端运行中 (pid $(cat "$FRONTEND_PID_FILE"), port ${FRONTEND_PORT})"
  else
    log_warn "前端未运行"
  fi
  if [ "$DEV_DB" = "postgres" ]; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'new-api-dev-pg'; then
      log_ok "PostgreSQL 运行中 (127.0.0.1:${POSTGRES_PORT}/${POSTGRES_DB})"
    else
      log_warn "PostgreSQL 未运行"
    fi
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'new-api-dev-redis'; then
      log_ok "Redis 运行中 (127.0.0.1:${REDIS_PORT})"
    else
      log_warn "Redis 未运行"
    fi
  fi
}

cmd_logs() {
  mkdir -p "$DEV_DIR"
  touch "$BACKEND_LOG" "$FRONTEND_LOG"
  tail -f "$BACKEND_LOG" "$FRONTEND_LOG"
}

cmd_restart() {
  cmd_stop
  sleep 1
  cmd_start
}

usage() {
  cat <<EOF
用法: ./dev.sh [start|stop|restart|status|logs]
      ./dev.sh stop all    # 同时停止 PostgreSQL / Redis 容器

环境变量:
  BACKEND_PORT      后端端口 (默认 3000)
  FRONTEND_PORT     前端端口 (默认 3001)
  DEV_DB            postgres | sqlite (默认 postgres)
  POSTGRES_PORT     PG 宿主机端口 (默认 5435)
  POSTGRES_USER     PG 用户 (默认 root)
  POSTGRES_PASSWORD PG 密码 (默认 123456)
  POSTGRES_DB       库名 (默认 new-api)
  REDIS_PORT        Redis 宿主机端口 (默认 6380)
  REDIS_PASSWORD    Redis 密码 (默认 123456)
  SQL_DSN / REDIS_CONN_STRING  可在 .env 覆盖

说明:
  - 默认用 Docker 启动 PostgreSQL(5435) + Redis(6380)
  - 首次运行会自动安装 Go (>= ${GO_MIN_VERSION}) 和 Node (>= v${NODE_MIN_MAJOR})
  - 退回 SQLite: DEV_DB=sqlite ./dev.sh
  - 前端 dev server 会把 /api 代理到后端 ${BACKEND_PORT}
EOF
}

main() {
  local action="${1:-start}"
  case "$action" in
    start|"") cmd_start ;;
    stop) cmd_stop "${2:-}" ;;
    restart) cmd_restart ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    -h|--help|help) usage ;;
    *)
      log_error "未知命令: ${action}"
      usage
      exit 1
      ;;
  esac
}

main "$@"
