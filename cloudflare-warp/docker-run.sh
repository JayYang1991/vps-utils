#!/usr/bin/env bash
#
# docker-run.sh
# Cloudflare WARP + Zero Trust + Sing-box SOCKS5 容器化构建、运行与 Systemd 服务管理脚本
# 支持将容器封装为 Systemd 系统服务，自动在服务启动时添加策略路由 (172.17.0.0/16 走 main 表)，退出时自动清理。
# 敏感凭据独立保存在权限为 600 的配置文件中，完全与 Systemd 单元文件隔离。
#

set -e

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

CONTAINER_NAME="cloudflare-warp-socks5"
SERVICE_NAME="cloudflare-warp-socks5"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONF_DIR="/etc/cloudflare-warp"
ENV_FILE="${CONF_DIR}/warp.env"
IMAGE_NAME="cloudflare-warp-socks5:latest"
HOST_PORT="1080"
POLICY_ROUTE_SRC="172.17.0.0/16"
POLICY_ROUTE_PRIO="8999"
VOLUME_NAME="cloudflare-warp-data"

WARP_TEAM=""
WARP_SERVICE_TOKEN_ID=""
WARP_SERVICE_TOKEN_SECRET=""
WARP_ENDPOINT=""
WARP_SUB_URL="https://sub.19910417.xyz/sub?host=1&uuid=1"
WARP_LICENSE_KEY=""
WARP_AUTH_TOKEN=""
SOCKS_USER=""
SOCKS_PASS=""
ACTION=""
FORCE_BUILD=false
NO_CACHE=false
RECREATE=false

show_help() {
  echo -e "${CYAN}Cloudflare WARP + Sing-box SOCKS5 容器化与 Systemd 服务管理脚本${NC}"
  echo ""
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "核心操作模式:"
  echo "  --service, --install-service     将容器安装为开机自启的 Systemd 服务 (含策略路由管理，凭据隔离加密存储)"
  echo "  --uninstall-service              停止并卸载 Systemd 服务，清理环境配置文件、删除容器与策略路由"
  echo "  --restart                        重启 Systemd 服务或 Docker 容器 (保留容器历史状态与数据)"
  echo "  --stop                           停止运行中的容器或 Systemd 服务 (保留容器状态)"
  echo "  --build, --rebuild, -b           重新编译 Docker 镜像 (仅构建镜像，不启动容器)"
  echo "  --no-cache                       构建 Docker 镜像时不使用缓存 (全新编译)"
  echo "  --recreate                       强制删除已有旧容器并重新创建 (清除旧状态)"
  echo "  --logs                           查看实时运行日志 (优先使用 journalctl)"
  echo "  --status                         查看 Systemd 服务、策略路由、容器与 WARP 连通状态"
  echo "  --test                           快速测试 SOCKS5 代理连通性 (curl Cloudflare trace)"
  echo ""
  echo "配置选项 (用于启动容器或安装服务):"
  echo "  -t, --team <TEAM>                指定 Cloudflare Zero Trust 团队名称 (Team Name)"
  echo "  -i, --token-id <CLIENT_ID>       指定 Cloudflare Access Service Token Client ID"
  echo "  -s, --token-secret <SECRET>      指定 Cloudflare Access Service Token Client Secret"
  echo "      --service-token <ID:SECRET>  使用 ID:SECRET 格式合并指定 Service Token"
  echo "  -e, --endpoint <IP:PORT>         指定自定义 WARP 节点接入点 (例如: 162.159.192.1:2408)"
  echo "  -k, --license <KEY>              指定 Cloudflare WARP+ 许可证密钥 (License Key)"
  echo "  -a, --auth-token <TOKEN>         指定 WARP API 注册鉴权 Token"
  echo "  -p, --port <PORT>                指定宿主机对外映射的 SOCKS5 代理端口 (默认: 1080)"
  echo "  -u, --user <USER>                指定 SOCKS5 代理验证用户名 (可选)"
  echo "  -w, --pass <PASS>                指定 SOCKS5 代理验证密码 (可选)"
  echo "  -n, --name <NAME>                指定容器/服务名称 (默认: cloudflare-warp-socks5)"
  echo "      --route-src <CIDR>           指定策略路由豁免的源地址网段 (默认: 172.17.0.0/16)"
  echo "      --route-prio <PRIO>          指定策略路由规则优先级 (默认: 8999)"
  echo "  -h, --help                       显示帮助信息"
  echo ""
  echo "使用示例:"
  echo -e "  ${YELLOW}# 1. 推荐：一键安装为 Systemd 系统服务 (开机自启 + 策略路由自动管理 + 凭据隔离存储)${NC}"
  echo "  sudo bash $0 --install-service -t my-team --service-token xxxx.access:yyyyy -p 1080"
  echo ""
  echo -e "  ${YELLOW}# 2. 重启服务 (保留容器已有状态，不重新注册)${NC}"
  echo "  sudo bash $0 --restart"
  echo "  sudo systemctl restart cloudflare-warp-socks5"
  echo ""
  echo -e "  ${YELLOW}# 3. 直接运行容器 (独立模式，已存在则复用)${NC}"
  echo "  sudo bash $0 -t my-team --service-token xxxx.access:yyyyy -p 1080"
  echo ""
  echo -e "  ${YELLOW}# 4. 重新编译 Docker 镜像 (支持 --no-cache 无缓存构建)${NC}"
  echo "  bash $0 --rebuild"
  echo "  bash $0 --rebuild --no-cache"
  echo ""
  echo -e "  ${YELLOW}# 5. 查看状态与测试${NC}"
  echo "  sudo bash $0 --status"
  echo "  sudo bash $0 --test"
  echo ""
  echo -e "  ${YELLOW}# 6. 查看日志与停止${NC}"
  echo "  sudo bash $0 --logs"
  echo "  sudo bash $0 --stop"
  echo ""
  echo -e "  ${YELLOW}# 7. 卸载 Systemd 服务${NC}"
  echo "  sudo bash $0 --uninstall-service"
}

# 解析命令行参数
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
    -e | --endpoint)
      WARP_ENDPOINT="$2"
      shift 2
      ;;
    --sub-url)
      WARP_SUB_URL="$2"
      shift 2
      ;;
    -k | --license)
      WARP_LICENSE_KEY="$2"
      shift 2
      ;;
    -a | --auth-token)
      WARP_AUTH_TOKEN="$2"
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
      SERVICE_NAME="$2"
      SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
      shift 2
      ;;
    --route-src)
      POLICY_ROUTE_SRC="$2"
      shift 2
      ;;
    --route-prio)
      POLICY_ROUTE_PRIO="$2"
      shift 2
      ;;
    --service | --install-service | -S)
      ACTION="install_service"
      shift 1
      ;;
    --uninstall-service)
      ACTION="uninstall_service"
      shift 1
      ;;
    --restart)
      ACTION="restart"
      shift 1
      ;;
    --recreate)
      RECREATE=true
      shift 1
      ;;
    -b | --build | --rebuild)
      FORCE_BUILD=true
      RECREATE=true
      [[ -z "$ACTION" ]] && ACTION="rebuild"
      shift 1
      ;;
    --no-cache)
      NO_CACHE=true
      FORCE_BUILD=true
      RECREATE=true
      [[ -z "$ACTION" ]] && ACTION="rebuild"
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
    --test)
      ACTION="test"
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

# 如果指定了 --rebuild/--no-cache 重新编译镜像，则启动时自动重建容器以应用新镜像
if [[ "$FORCE_BUILD" == "true" ]]; then
  RECREATE=true
fi

# 如果指定了 build 且同时携带了运行参数，则默认模式转为 run (先编译再运行)
if [[ "$ACTION" == "build" ]]; then
  if [[ -n "$WARP_TEAM" || -n "$WARP_SERVICE_TOKEN_ID" || -n "$WARP_LICENSE_KEY" || -n "$WARP_AUTH_TOKEN" || -n "$WARP_ENDPOINT" || -n "$SOCKS_USER" || -n "$SOCKS_PASS" ]]; then
    ACTION="run"
  fi
elif [[ -z "$ACTION" ]]; then
  ACTION="run"
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")

check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "当前操作需要 root 权限，请使用 'sudo bash $0 ...' 运行。"
    exit 1
  fi
}

check_docker() {
  if ! command -v docker &>/dev/null; then
    error "未检测到 Docker 命令，请先安装 Docker 环境。"
    exit 1
  fi
}

ensure_tun_device() {
  if [[ ! -c /dev/net/tun ]]; then
    log "宿主机 /dev/net/tun 不存在，加载 tun 模块并创建字符设备节点..."
    modprobe tun 2>/dev/null || true
    mkdir -p /dev/net
    [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 600 /dev/net/tun 2>/dev/null || true
  fi
}

do_build() {
  check_docker
  if [[ ! -f "${SCRIPT_DIR}/Dockerfile" ]]; then
    error "未在脚本同级目录找到 Dockerfile: ${SCRIPT_DIR}/Dockerfile"
    exit 1
  fi
  log "构建/重新编译 Docker 镜像 ${IMAGE_NAME}..."
  local build_opts=("--network" "host" "-t" "$IMAGE_NAME")
  if [[ "$NO_CACHE" == "true" ]]; then
    build_opts+=("--no-cache")
    log "已启用 --no-cache 模式 (无缓存全新编译)"
  fi
  docker build "${build_opts[@]}" "$SCRIPT_DIR"
  success "Docker 镜像 ${IMAGE_NAME} 编译完成！"
}

do_rebuild() {
  do_build

  # 编译完成后，若存在正在运行的容器或服务，自动重建并平滑重启
  if docker container inspect "$CONTAINER_NAME" &>/dev/null; then
    log "检测到已有旧容器 ${CONTAINER_NAME}，正在删除以应用新编译镜像..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true

    if command -v systemctl &>/dev/null && (systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null || [[ -f "$SERVICE_FILE" ]]); then
      log "检测到 Systemd 服务 ${SERVICE_NAME}，正在使用新镜像重启服务..."
      systemctl restart "$SERVICE_NAME"
      success "服务已根据新镜像成功重启并运行！"
    elif [[ -f "$ENV_FILE" ]]; then
      log "正在根据新镜像重新创建并启动容器..."
      ensure_tun_device
      add_policy_route
      docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        --cap-add=NET_ADMIN \
        --device /dev/net/tun \
        --dns 223.5.5.5 --dns 119.29.29.29 --dns 1.1.1.1 \
        -p "${HOST_PORT}:1080" \
        -v "${VOLUME_NAME}:/var/lib/cloudflare-warp" \
        --env-file "$ENV_FILE" \
        "$IMAGE_NAME" >/dev/null
      success "容器 ${CONTAINER_NAME} 已成功根据新镜像重建并启动！"
    fi
  else
    log "当前无运行中的旧容器。镜像已就绪，您可直接启动或使用 '--install-service' 安装服务。"
  fi
}

build_image_if_needed() {
  if [[ "$FORCE_BUILD" == "true" ]] || ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    do_build
  fi
}

add_policy_route() {
  if command -v ip &>/dev/null; then
    if ! ip rule show | grep -q "${POLICY_ROUTE_PRIO}:"; then
      log "添加策略路由规则 (优先级 ${POLICY_ROUTE_PRIO}: 源地址 ${POLICY_ROUTE_SRC} 走 main 路由表)..."
      ip rule add from "$POLICY_ROUTE_SRC" priority "$POLICY_ROUTE_PRIO" lookup main 2>/dev/null || true
      success "策略路由规则已添加。"
    else
      log "策略路由规则 (优先级 ${POLICY_ROUTE_PRIO}) 已存在，跳过添加。"
    fi
  fi
}

remove_policy_route() {
  if command -v ip &>/dev/null; then
    if ip rule show | grep -q "${POLICY_ROUTE_PRIO}:"; then
      log "清理策略路由规则 (优先级 ${POLICY_ROUTE_PRIO}: from ${POLICY_ROUTE_SRC})..."
      while ip rule show | grep -q "${POLICY_ROUTE_PRIO}:"; do
        ip rule del from "$POLICY_ROUTE_SRC" priority "$POLICY_ROUTE_PRIO" lookup main 2>/dev/null || break
      done
      success "策略路由规则已清理。"
    fi
  fi
}

# --- 核心功能实现 ---

do_install_service() {
  check_root
  check_docker
  ensure_tun_device
  build_image_if_needed

  if [[ "$RECREATE" == "true" ]]; then
    log "检测到 --recreate 参数，清理旧容器 ${CONTAINER_NAME}..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
  fi

  log "1. 将敏感认证参数安全写入独立凭据文件 (权限 600): ${ENV_FILE}..."
  mkdir -p "$CONF_DIR"
  cat <<EOF > "$ENV_FILE"
# Cloudflare WARP + SOCKS5 独立环境变量文件
# 敏感凭据独立存储，完全与 Systemd 配置文件隔离
WARP_TEAM=${WARP_TEAM}
WARP_SERVICE_TOKEN_ID=${WARP_SERVICE_TOKEN_ID}
WARP_SERVICE_TOKEN_SECRET=${WARP_SERVICE_TOKEN_SECRET}
WARP_ENDPOINT=${WARP_ENDPOINT}
WARP_SUB_URL=${WARP_SUB_URL}
WARP_LICENSE_KEY=${WARP_LICENSE_KEY}
WARP_AUTH_TOKEN=${WARP_AUTH_TOKEN}
SOCKS_USER=${SOCKS_USER}
SOCKS_PASS=${SOCKS_PASS}
SOCKS_PORT=1080
SINGBOX_LOG_LEVEL=${SINGBOX_LOG_LEVEL:-warn}
WARP_LOG_LEVEL=${WARP_LOG_LEVEL:-warn}
EOF
  chmod 600 "$ENV_FILE"
  if getent group docker >/dev/null 2>&1; then
    chgrp docker "$ENV_FILE" 2>/dev/null || true
    chmod 640 "$ENV_FILE" 2>/dev/null || true
  fi

  log "2. 生成干净的 Systemd 服务单元文件 (无任何敏感凭据，重启保留容器状态): ${SERVICE_FILE}..."
  cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Cloudflare WARP + Sing-box SOCKS5 Proxy Service (Docker Container)
Documentation=https://github.com/JayYang1991/vps-utils/tree/main/cloudflare-warp
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple

# 1. 确保宿主机 /dev/net/tun 设备与内核模块正常
ExecStartPre=/bin/bash -c "modprobe tun 2>/dev/null || true; mkdir -p /dev/net; [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null || true; chmod 600 /dev/net/tun 2>/dev/null || true"

# 2. 确保容器已创建 (若不存在则创建，若已存在则保留其已有状态与数据)
ExecStartPre=/bin/bash -c "docker container inspect ${CONTAINER_NAME} >/dev/null 2>&1 || docker create --name ${CONTAINER_NAME} --cap-add=NET_ADMIN --device /dev/net/tun --dns 223.5.5.5 --dns 119.29.29.29 --dns 1.1.1.1 -p ${HOST_PORT}:1080 -v ${VOLUME_NAME}:/var/lib/cloudflare-warp --env-file ${ENV_FILE} ${IMAGE_NAME}"

# 3. 前台启动并附加到容器 (保留容器历史状态，不使用 --rm)
ExecStart=/usr/bin/docker start -a ${CONTAINER_NAME}

# 4. 服务启动后：自动配置策略路由 (源地址 ${POLICY_ROUTE_SRC} 查 main 表，防止与宿主机 Clash 形成流量循环)
ExecStartPost=/bin/bash -c "ip rule show | grep -q '${POLICY_ROUTE_PRIO}:' || /sbin/ip rule add from ${POLICY_ROUTE_SRC} priority ${POLICY_ROUTE_PRIO} lookup main || true"

# 5. 优雅停止容器 (保留容器状态)
ExecStop=-/usr/bin/docker stop -t 10 ${CONTAINER_NAME}

# 6. 服务退出后：自动清理策略路由规则
ExecStopPost=/bin/bash -c "while ip rule show | grep -q '${POLICY_ROUTE_PRIO}:'; do /sbin/ip rule del from ${POLICY_ROUTE_SRC} priority ${POLICY_ROUTE_PRIO} lookup main || break; done"

Restart=always
RestartSec=5s
TimeoutStopSec=15s

[Install]
WantedBy=multi-user.target
EOF

  log "3. 重新加载 Systemd 配置并启动服务..."
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"

  success "Systemd 服务 ${SERVICE_NAME} 已成功安装并启动！"
  echo ""
  echo "=========================================================="
  echo -e "安全说明与服务管理:"
  echo -e "  - 敏感凭据文件 : ${GREEN}${ENV_FILE}${NC} (权限: 0600, 仅 root 可读)"
  echo -e "  - Systemd 单元 : ${GREEN}${SERVICE_FILE}${NC} (无敏感信息)"
  echo -e "  - 查看服务状态 : ${YELLOW}systemctl status ${SERVICE_NAME}${NC}"
  echo -e "  - 查看实时日志 : ${YELLOW}journalctl -u ${SERVICE_NAME} -f${NC}"
  echo -e "  - 重启服务     : ${YELLOW}systemctl restart ${SERVICE_NAME}${NC}"
  echo -e "  - 停止服务     : ${YELLOW}systemctl stop ${SERVICE_NAME}${NC}"
  echo -e "  - 卸载服务     : ${YELLOW}sudo bash $0 --uninstall-service${NC}"
  echo "=========================================================="
}

do_uninstall_service() {
  check_root
  log "正在卸载 Systemd 服务 ${SERVICE_NAME}..."

  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    log "停止服务 ${SERVICE_NAME}..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  fi

  if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    log "禁用服务 ${SERVICE_NAME}..."
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  fi

  if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE"
    log "删除服务配置文件: ${SERVICE_FILE}"
  fi

  if [[ -f "$ENV_FILE" ]]; then
    rm -f "$ENV_FILE"
    log "删除独立凭据文件: ${ENV_FILE}"
  fi

  systemctl daemon-reload || true
  remove_policy_route
  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  docker rm "$CONTAINER_NAME" 2>/dev/null || true

  success "Systemd 服务 ${SERVICE_NAME} 及关联规则已完全卸载。"
}

do_stop() {
  check_root
  if command -v systemctl &>/dev/null && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    log "停止 Systemd 服务 ${SERVICE_NAME}..."
    systemctl stop "$SERVICE_NAME"
    success "Systemd 服务已停止 (容器状态已保留，策略路由已由 ExecStopPost 自动清理)。"
  else
    log "停止 Docker 容器 ${CONTAINER_NAME} (保留容器状态)..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    remove_policy_route
    success "容器已停止 (容器数据与状态已保留)，策略路由已清理。"
  fi
}

do_restart() {
  check_root
  if command -v systemctl &>/dev/null && (systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null || [[ -f "$SERVICE_FILE" ]]); then
    log "重启 Systemd 服务 ${SERVICE_NAME} (保留容器状态)..."
    systemctl restart "$SERVICE_NAME"
    success "Systemd 服务已重启！"
  else
    check_docker
    add_policy_route
    log "重启 Docker 容器 ${CONTAINER_NAME} (保留容器状态)..."
    docker restart "$CONTAINER_NAME"
    success "Docker 容器已重启！"
  fi
}

do_logs() {
  if command -v systemctl &>/dev/null && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    log "获取 Systemd 服务 ${SERVICE_NAME} 日志 (journalctl):"
    journalctl -u "$SERVICE_NAME" -f -n 100
  else
    check_docker
    log "获取容器 ${CONTAINER_NAME} 日志 (docker logs):"
    docker logs -f --tail 100 "$CONTAINER_NAME"
  fi
}

do_status() {
  echo -e "${CYAN}=================== 服务与网络状态概览 ===================${NC}"

  # 1. Systemd 状态
  if command -v systemctl &>/dev/null; then
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
      success "Systemd 服务状态: 正在运行 (active) [开机自启: $(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo 'unknown')]"
    elif [[ -f "$SERVICE_FILE" ]]; then
      warn "Systemd 服务状态: 已配置但未运行 (inactive)"
    else
      log "Systemd 服务状态: 未安装为 Systemd 服务"
    fi
  fi

  # 2. 策略路由状态
  if command -v ip &>/dev/null; then
    echo ""
    log "策略路由检查 (ip rule):"
    if ip rule show | grep -q "${POLICY_ROUTE_PRIO}:"; then
      RULE_LINE=$(ip rule show | grep "${POLICY_ROUTE_PRIO}:")
      success "策略路由已生效: ${RULE_LINE}"
    else
      warn "策略路由规则 (优先级 ${POLICY_ROUTE_PRIO}) 未激活。"
    fi
  fi

  # 3. Docker 容器状态
  echo ""
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    success "Docker 容器状态 : 正在运行 (${CONTAINER_NAME})"
    docker ps --filter "name=${CONTAINER_NAME}"

    echo ""
    log "容器内 Cloudflare WARP 连通状态:"
    docker exec "$CONTAINER_NAME" warp-cli --accept-tos status 2>/dev/null || docker exec "$CONTAINER_NAME" warp-cli status 2>/dev/null || true

    echo ""
    log "容器内 sing-box 进程与配置状态:"
    if docker exec "$CONTAINER_NAME" pgrep -x sing-box &>/dev/null; then
      SINGBOX_VER=$(docker exec "$CONTAINER_NAME" sing-box version 2>/dev/null | head -n 1 || echo "Running")
      success "sing-box 状态   : 已启动 (${SINGBOX_VER})"
    else
      error "sing-box 状态   : 未运行 (进程异常)"
    fi

    echo ""
    log "容器内 SOCKS5 端口监听状态:"
    docker exec "$CONTAINER_NAME" ss -tlpn 2>/dev/null | grep -E "1080|sing-box" || true
  else
    warn "Docker 容器 ${CONTAINER_NAME} 未运行。"
  fi
  echo -e "${CYAN}==========================================================${NC}"
}

do_test() {
  local target_port="${HOST_PORT:-1080}"
  log "测试 SOCKS5 代理连通性 (127.0.0.1:${target_port})..."
  local curl_cmd=(curl -s -m 8 -x "socks5h://127.0.0.1:${target_port}" "https://www.cloudflare.com/cdn-cgi/trace")

  if [[ -n "$SOCKS_USER" && -n "$SOCKS_PASS" ]]; then
    curl_cmd=(curl -s -m 8 -x "socks5h://${SOCKS_USER}:${SOCKS_PASS}@127.0.0.1:${target_port}" "https://www.cloudflare.com/cdn-cgi/trace")
  elif [[ -f "$ENV_FILE" ]]; then
    local env_user env_pass
    env_user=$(grep "^SOCKS_USER=" "$ENV_FILE" | cut -d= -f2- || true)
    env_pass=$(grep "^SOCKS_PASS=" "$ENV_FILE" | cut -d= -f2- || true)
    if [[ -n "$env_user" && -n "$env_pass" ]]; then
      curl_cmd=(curl -s -m 8 -x "socks5h://${env_user}:${env_pass}@127.0.0.1:${target_port}" "https://www.cloudflare.com/cdn-cgi/trace")
    fi
  fi

  local result
  result=$("${curl_cmd[@]}" 2>/dev/null || echo "")

  if [[ -n "$result" ]] && echo "$result" | grep -q "warp="; then
    success "SOCKS5 代理测试成功！Cloudflare Trace 返回:"
    echo -e "${YELLOW}${result}${NC}"
  else
    error "SOCKS5 代理连接测试失败，请检查服务日志与 WARP 连通状态。"
  fi
}

do_run() {
  check_root
  check_docker
  ensure_tun_device
  build_image_if_needed
  add_policy_route

  local container_exists=false
  if docker container inspect "$CONTAINER_NAME" &>/dev/null; then
    container_exists=true
  fi

  if [[ "$container_exists" == "true" ]]; then
    if [[ "$RECREATE" == "true" ]]; then
      log "检测到 --recreate 参数，删除旧容器 ${CONTAINER_NAME} 并重新创建..."
      docker stop "$CONTAINER_NAME" 2>/dev/null || true
      docker rm "$CONTAINER_NAME" 2>/dev/null || true
    else
      local is_running=false
      if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        is_running=true
      fi

      if [[ "$is_running" == "true" ]]; then
        log "容器 ${CONTAINER_NAME} 已经在运行中 (状态已保留)。"
      else
        log "发现已有容器 ${CONTAINER_NAME}，直接启动现有容器 (保留上次运行状态)..."
        docker start "$CONTAINER_NAME"
        success "容器 ${CONTAINER_NAME} 已成功启动！"
      fi

      echo ""
      echo "=========================================================="
      echo -e "SOCKS5 代理配置信息:"
      echo -e "  - 容器名称 : ${YELLOW}${CONTAINER_NAME}${NC}"
      echo -e "  - 运行状态 : ${GREEN}运行中 (保留已有状态与注册信息)${NC}"
      echo -e "  - 策略路由 : ${GREEN}优先级 ${POLICY_ROUTE_PRIO} (${POLICY_ROUTE_SRC} 走 main 表)${NC}"
      echo -e "  - 如需重建 : 可使用 ${YELLOW}sudo bash $0 --recreate ...${NC}"
      echo "=========================================================="
      return 0
    fi
  fi

  DOCKER_ENV_ARGS=()
  [[ -n "$WARP_TEAM" ]] && DOCKER_ENV_ARGS+=("-e" "WARP_TEAM=${WARP_TEAM}")
  [[ -n "$WARP_SERVICE_TOKEN_ID" ]] && DOCKER_ENV_ARGS+=("-e" "WARP_SERVICE_TOKEN_ID=${WARP_SERVICE_TOKEN_ID}")
  [[ -n "$WARP_SERVICE_TOKEN_SECRET" ]] && DOCKER_ENV_ARGS+=("-e" "WARP_SERVICE_TOKEN_SECRET=${WARP_SERVICE_TOKEN_SECRET}")
  [[ -n "$WARP_ENDPOINT" ]] && DOCKER_ENV_ARGS+=("-e" "WARP_ENDPOINT=${WARP_ENDPOINT}")
  [[ -n "$WARP_LICENSE_KEY" ]] && DOCKER_ENV_ARGS+=("-e" "WARP_LICENSE_KEY=${WARP_LICENSE_KEY}")
  [[ -n "$WARP_AUTH_TOKEN" ]] && DOCKER_ENV_ARGS+=("-e" "WARP_AUTH_TOKEN=${WARP_AUTH_TOKEN}")
  [[ -n "$SOCKS_USER" ]] && DOCKER_ENV_ARGS+=("-e" "SOCKS_USER=${SOCKS_USER}")
  [[ -n "$SOCKS_PASS" ]] && DOCKER_ENV_ARGS+=("-e" "SOCKS_PASS=${SOCKS_PASS}")

  log "以独立容器模式启动 ${CONTAINER_NAME} (宿主机端口: ${HOST_PORT}:1080)..."
  docker run -d \
    --name "$CONTAINER_NAME" \
    --cap-add=NET_ADMIN \
    --device /dev/net/tun \
    --dns 223.5.5.5 \
    --dns 119.29.29.29 \
    --dns 1.1.1.1 \
    -p "${HOST_PORT}:1080" \
    -v "${VOLUME_NAME}:/var/lib/cloudflare-warp" \
    "${DOCKER_ENV_ARGS[@]}" \
    --restart unless-stopped \
    "$IMAGE_NAME"

  success "容器已成功启动！"
  sleep 2
  docker logs --tail 20 "$CONTAINER_NAME"

  echo ""
  echo "=========================================================="
  echo -e "SOCKS5 代理配置信息:"
  echo -e "  - 代理地址 : ${YELLOW}127.0.0.1${NC} 或 ${YELLOW}宿主机IP${NC}"
  echo -e "  - 代理端口 : ${YELLOW}${HOST_PORT}${NC}"
  echo -e "  - 策略路由 : ${GREEN}优先级 ${POLICY_ROUTE_PRIO} (${POLICY_ROUTE_SRC} 走 main 表)${NC}"
  echo -e "  - 提示     : 如需开机自动管理策略路由，推荐使用 ${YELLOW}sudo bash $0 --install-service${NC}"
  echo "=========================================================="
}

# 动作分发
case "$ACTION" in
  build)
    do_build
    ;;
  rebuild)
    do_rebuild
    ;;
  install_service)
    do_install_service
    ;;
  uninstall_service)
    do_uninstall_service
    ;;
  run)
    do_run
    ;;
  restart)
    do_restart
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
  test)
    do_test
    ;;
  *)
    error "未知动作: $ACTION"
    show_help
    exit 1
    ;;
esac
