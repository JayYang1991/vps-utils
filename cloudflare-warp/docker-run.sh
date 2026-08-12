#!/usr/bin/env bash
#
# docker-run.sh
# Cloudflare WARP + Zero Trust + Sing-box SOCKS5 容器化构建与运行管理脚本
#

set -e

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

CONTAINER_NAME="cloudflare-warp-socks5"
IMAGE_NAME="cloudflare-warp-socks5:latest"
HOST_PORT="1080"
WARP_TEAM=""
WARP_SERVICE_TOKEN_ID=""
WARP_SERVICE_TOKEN_SECRET=""
WARP_LICENSE_KEY=""
WARP_AUTH_TOKEN=""
SOCKS_USER=""
SOCKS_PASS=""
ACTION="run"
FORCE_BUILD=false
DETACH=true

show_help() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "选项:"
  echo "  -t, --team <TEAM>                指定 Cloudflare Zero Trust 团队名称 (Team Name)"
  echo "  -i, --token-id <CLIENT_ID>       指定 Cloudflare Access Service Token Client ID"
  echo "  -s, --token-secret <SECRET>      指定 Cloudflare Access Service Token Client Secret"
  echo "      --service-token <ID:SECRET>  使用 ID:SECRET 格式合并指定 Service Token"
  echo "  -k, --license <KEY>              指定 Cloudflare WARP+ 许可证密钥 (License Key)"
  echo "  -p, --port <PORT>                指定宿主机对外映射的 SOCKS5 代理端口 (默认: 1080)"
  echo "  -u, --user <USER>                指定 SOCKS5 代理验证用户名 (可选)"
  echo "  -w, --pass <PASS>                指定 SOCKS5 代理验证密码 (可选)"
  echo "  -n, --name <NAME>                指定容器名称 (默认: cloudflare-warp-socks5)"
  echo "      --build                      强行重新构建 Docker 镜像"
  echo "      --stop                       停止并删除正在运行的容器"
  echo "      --logs                       查看容器运行日志"
  echo "      --status                     查看容器运行状态与 WARP 连通状态"
  echo "  -h, --help                       显示帮助信息"
  echo ""
  echo "示例:"
  echo "  # 使用 Zero Trust 团队及 Service Token 启动容器"
  echo "  sudo bash $0 -t my-team -i xxxx.access -s yyyyy -p 1080"
  echo "  # 或使用 ID:SECRET 合并参数:"
  echo "  sudo bash $0 -t my-team --service-token xxxx.access:yyyyy -p 1080"
  echo ""
  echo "  # 查看容器日志"
  echo "  sudo bash $0 --logs"
  echo ""
  echo "  # 停止并清理容器"
  echo "  sudo bash $0 --stop"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -t | --team)
      WARP_TEAM="$2"
      shift 2
      ;;
    -i | --token-id | --service-token-id)
      WARP_SERVICE_TOKEN_ID="$2"
      shift 2
      ;;
    -s | --token-secret | --service-token-secret)
      WARP_SERVICE_TOKEN_SECRET="$2"
      shift 2
      ;;
    --service-token)
      if [[ "$2" == *":"* ]]; then
        WARP_SERVICE_TOKEN_ID="${2%%:*}"
        WARP_SERVICE_TOKEN_SECRET="${2#*:}"
      else
        WARP_SERVICE_TOKEN_ID="$2"
      fi
      shift 2
      ;;
    -k | --license)
      WARP_LICENSE_KEY="$2"
      shift 2
      ;;
    -p | --port)
      HOST_PORT="$2"
      shift 2
      ;;
    -u | --user)
      SOCKS_USER="$2"
      shift 2
      ;;
    -w | --pass)
      SOCKS_PASS="$2"
      shift 2
      ;;
    -n | --name)
      CONTAINER_NAME="$2"
      shift 2
      ;;
    --build)
      FORCE_BUILD=true
      shift 1
      ;;
    --stop)
      ACTION="stop"
      shift 1
      ;;
    --logs)
      ACTION="logs"
      shift 1
      ;;
    --status)
      ACTION="status"
      shift 1
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    *)
      warn "未知参数: $1"
      show_help
      exit 1
      ;;
  esac
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")

check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "此脚本必须以 root 权限运行，请使用 'sudo bash $0 ...'"
    exit 1
  fi
}

check_docker() {
  check_root
  if ! command -v docker &>/dev/null; then
    error "未找到 Docker 命令，请先安装 Docker 环境。"
    exit 1
  fi
}

do_stop() {
  check_docker
  log "停止并清理容器 ${CONTAINER_NAME}..."
  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  docker rm "$CONTAINER_NAME" 2>/dev/null || true
  success "容器已停止并删除。"
}

do_logs() {
  check_docker
  log "获取容器 ${CONTAINER_NAME} 日志:"
  docker logs -f --tail 100 "$CONTAINER_NAME"
}

do_status() {
  check_docker
  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log "容器 ${CONTAINER_NAME} 正在运行:"
    docker ps --filter "name=${CONTAINER_NAME}"
    echo ""
    log "容器内 Cloudflare WARP 连通状态:"
    docker exec "$CONTAINER_NAME" warp-cli --accept-tos status 2>/dev/null || docker exec "$CONTAINER_NAME" warp-cli status 2>/dev/null || true
    echo ""
    log "容器内 SOCKS5 端口监听状态:"
    docker exec "$CONTAINER_NAME" netstat -tlpn 2>/dev/null || docker exec "$CONTAINER_NAME" ss -tlpn 2>/dev/null || true
  else
    warn "容器 ${CONTAINER_NAME} 未运行。"
  fi
}

do_run() {
  check_docker

  # Build image if forced or does not exist
  if [[ "$FORCE_BUILD" == "true" ]] || ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    log "构建 Docker 镜像 ${IMAGE_NAME}..."
    docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
    success "Docker 镜像构建完成。"
  fi

  # Stop old container if exists
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log "移除现有同名容器 ${CONTAINER_NAME}..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
  fi

  # Check /dev/net/tun on host
  if [[ ! -c /dev/net/tun ]]; then
    warn "宿主机 /dev/net/tun 不存在，正在自动创建..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 600 /dev/net/tun 2>/dev/null || true
  fi

  DOCKER_ENV_ARGS=()
  if [[ -n "$WARP_TEAM" ]]; then
    DOCKER_ENV_ARGS+=("-e" "WARP_TEAM=${WARP_TEAM}")
  fi
  if [[ -n "$WARP_SERVICE_TOKEN_ID" ]]; then
    DOCKER_ENV_ARGS+=("-e" "WARP_SERVICE_TOKEN_ID=${WARP_SERVICE_TOKEN_ID}")
  fi
  if [[ -n "$WARP_SERVICE_TOKEN_SECRET" ]]; then
    DOCKER_ENV_ARGS+=("-e" "WARP_SERVICE_TOKEN_SECRET=${WARP_SERVICE_TOKEN_SECRET}")
  fi
  if [[ -n "$WARP_LICENSE_KEY" ]]; then
    DOCKER_ENV_ARGS+=("-e" "WARP_LICENSE_KEY=${WARP_LICENSE_KEY}")
  fi
  if [[ -n "$WARP_AUTH_TOKEN" ]]; then
    DOCKER_ENV_ARGS+=("-e" "WARP_AUTH_TOKEN=${WARP_AUTH_TOKEN}")
  fi
  if [[ -n "$SOCKS_USER" ]]; then
    DOCKER_ENV_ARGS+=("-e" "SOCKS_USER=${SOCKS_USER}")
  fi
  if [[ -n "$SOCKS_PASS" ]]; then
    DOCKER_ENV_ARGS+=("-e" "SOCKS_PASS=${SOCKS_PASS}")
  fi

  log "启动容器 ${CONTAINER_NAME} (端口映射: ${HOST_PORT}:1080)..."
  docker run -d \
    --name "$CONTAINER_NAME" \
    --cap-add=NET_ADMIN \
    --device /dev/net/tun \
    -p "${HOST_PORT}:1080" \
    "${DOCKER_ENV_ARGS[@]}" \
    --restart unless-stopped \
    "$IMAGE_NAME"

  success "容器已成功启动！"
  log "查看初始化日志 (等待 WARP 连接与 sing-box 启动):"
  sleep 3
  docker logs --tail 20 "$CONTAINER_NAME"

  echo ""
  echo "=========================================================="
  echo -e "SOCKS5 代理节点配置信息:"
  echo -e "  - 代理地址 : ${YELLOW}127.0.0.1${NC} 或 ${YELLOW}宿主机公网IP${NC}"
  echo -e "  - 代理端口 : ${YELLOW}${HOST_PORT}${NC}"
  if [[ -n "$SOCKS_USER" && -n "$SOCKS_PASS" ]]; then
    echo -e "  - 代理认证 : 用户名=${YELLOW}${SOCKS_USER}${NC}, 密码=${YELLOW}${SOCKS_PASS}${NC}"
  else
    echo -e "  - 代理认证 : ${GREEN}无需认证 (匿名 SOCKS5)${NC}"
  fi
  echo -e "  - 流量出口 : ${GREEN}Cloudflare WARP / Zero Trust 节点流量${NC}"
  echo "=========================================================="
}

case "$ACTION" in
  run)
    do_run
    ;;
  stop)
    do_stop
    ;;
  logs)
    do_logs
    ;;
  status)
    do_status
    ;;
  *)
    error "未知操作: $ACTION"
    show_help
    exit 1
    ;;
esac
