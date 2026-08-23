#!/usr/bin/env bash
#
# install.sh
# Cloudflare Access TCP 客户端一键安装与 Systemd 服务管理脚本
# 通过 Docker + Ubuntu 24.04 编译生成容器，并通过 Systemd 实现开机自启与后台守护运行。
#
# GitHub: https://github.com/JayYang1991/vps-utils
#

set -eo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# --- 基础与默认变量 ---
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")
SERVICE_NAME="cloudflare-access-tcp"
CONTAINER_NAME="cloudflare-access-tcp"
IMAGE_NAME="cloudflare-access-tcp:latest"
CONF_DIR="/etc/cloudflare-access-tcp"
ENV_FILE="${CONF_DIR}/access.env"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

DEFAULT_DOMAINS="movies.19910417.xyz,movies1.19910417.xyz"
DEFAULT_PORTS="5000,5001"
DEFAULT_LISTEN="localhost"
DEFAULT_NETWORK_MODE="host"

SERVICE_TOKEN_ID="${SERVICE_TOKEN_ID:-}"
SERVICE_TOKEN_SECRET="${SERVICE_TOKEN_SECRET:-}"
DOMAINS="${DOMAINS:-}"
PORTS="${PORTS:-}"
LISTEN_HOST="${LISTEN_HOST:-}"
NETWORK_MODE="${NETWORK_MODE:-$DEFAULT_NETWORK_MODE}"

FORWARD_RULES=()
ACTION="install"
NO_CACHE=false

# --- 显示帮助信息 ---
show_help() {
  echo -e "${CYAN}${BOLD}Cloudflare Access TCP 客户端一键安装与 Systemd 容器管理脚本${NC}"
  echo ""
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "核心操作模式:"
  echo "  --install                   一键构建镜像、配置 Systemd 服务并开机自启 (默认动作)"
  echo "  --uninstall                 停止并卸载 Systemd 服务，清理容器、镜像与配置文件"
  echo "  --restart                   重启 Systemd 服务"
  echo "  --stop                      停止 Systemd 服务"
  echo "  --status                    查看 Systemd 服务状态、容器运行状态与本地监听端口"
  echo "  --logs, -l                  查看服务的实时运行日志 (优先使用 journalctl)"
  echo "  --test                      测试各个本地转发端口的连通性"
  echo "  --rebuild, -b               仅重新编译 Docker 镜像 (使用宿主机网络)"
  echo ""
  echo "必选参数 (用于安装或更新配置):"
  echo "  -i, --token-id <ID>         Cloudflare Access Service Token Client ID"
  echo "  -s, --token-secret <SECRET> Cloudflare Access Service Token Client Secret"
  echo "      --service-token <ID:KEY>以 'ID:SECRET' 格式一次性传入 Service Token"
  echo ""
  echo "可选配置参数:"
  echo "  -d, --domains <D1,D2,...>   目标域名列表，逗号分隔 (默认: movies.19910417.xyz,movies1.19910417.xyz)"
  echo "  -p, --ports <P1,P2,...>     本地监听端口列表，逗号分隔 (默认: 5000,5001)"
  echo "  -f, --forward <D:P,...>     转发规则列表，格式为 'domain1:port1,domain2:port2' (可指定多次)"
  echo "      --listen <HOST>         本地监听主机绑定地址 (默认: localhost, 也可设为 0.0.0.0)"
  echo "      --network-mode <MODE>   容器网络模式: host(默认) 或 bridge"
  echo "  -n, --name <NAME>           自定义服务与容器名称 (默认: cloudflare-access-tcp)"
  echo "      --no-cache              构建 Docker 镜像时不使用缓存 (全新拉取与编译)"
  echo "  -h, --help                  显示此帮助信息"
  echo ""
  echo "环境变量支持:"
  echo "  SERVICE_TOKEN_ID            Cloudflare Access Service Token ID"
  echo "  SERVICE_TOKEN_SECRET        Cloudflare Access Service Token Secret"
  echo "  DOMAINS                     域名列表 (逗号分隔)"
  echo "  PORTS                       端口列表 (逗号分隔)"
  echo "  LISTEN_HOST                 监听地址 (默认: localhost)"
  echo "  NETWORK_MODE                网络模式 (默认: host)"
  echo ""
  echo "使用示例:"
  echo -e "  ${YELLOW}# 1. 默认参数一键安装 (默认转发 movies.19910417.xyz->5000, movies1.19910417.xyz->5001):${NC}"
  echo "  sudo bash $0 -i \"xxx.access\" -s \"yyy\""
  echo ""
  echo -e "  ${YELLOW}# 2. 自定义域名和端口列表安装:${NC}"
  echo "  sudo bash $0 -i \"xxx.access\" -s \"yyy\" -d \"movies.19910417.xyz,movies1.19910417.xyz\" -p \"5000,5001\""
  echo ""
  echo -e "  ${YELLOW}# 3. 使用 --forward 快捷格式:${NC}"
  echo "  sudo bash $0 --service-token \"xxx.access:yyy\" --forward \"movies.19910417.xyz:5000,movies1.19910417.xyz:5001\""
  echo ""
  echo -e "  ${YELLOW}# 4. 查看状态与日志:${NC}"
  echo "  sudo bash $0 --status"
  echo "  sudo bash $0 --logs"
  echo ""
  echo -e "  ${YELLOW}# 5. 测试端口连通性:${NC}"
  echo "  sudo bash $0 --test"
}

# --- 严格校验域名格式 (RFC 1123 规范) ---
validate_domain() {
  local domain="$1"
  if [[ -z "$domain" ]]; then
    error "域名不能为空"
    return 1
  fi
  if [[ ${#domain} -gt 253 || ${#domain} -lt 3 ]]; then
    error "域名长度非法 (${#domain} 字符): $domain"
    return 1
  fi
  if [[ "$domain" != *.* ]]; then
    error "域名必须包含顶级域名 (至少包含一个点): $domain"
    return 1
  fi
  local domain_regex="^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$"
  if [[ ! "$domain" =~ $domain_regex ]]; then
    error "域名格式不符合规范: $domain"
    return 1
  fi
  return 0
}

# --- 严格校验端口号 ---
validate_port() {
  local port="$1"
  if [[ -z "$port" ]]; then
    error "端口号不能为空"
    return 1
  fi
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    error "端口号必须为纯数字整数: $port"
    return 1
  fi
  if (( port < 1 || port > 65535 )); then
    error "端口号超出合法范围 (1-65535): $port"
    return 1
  fi
  if [[ "$port" =~ ^0[0-9]+$ ]]; then
    error "端口号格式非法 (不能包含前导 0): $port"
    return 1
  fi
  return 0
}

# --- 检查端口是否已被宿主机其他服务占用 ---
check_port_available() {
  local port="$1"
  if command -v ss &>/dev/null; then
    if ss -tlpn "sport = :$port" 2>/dev/null | grep -q ":$port"; then
      return 1
    fi
  elif command -v netstat &>/dev/null; then
    if netstat -tlpn 2>/dev/null | grep -q ":$port "; then
      return 1
    fi
  elif command -v lsof &>/dev/null; then
    if lsof -iTCP:"$port" -sTCP:LISTEN -P -n &>/dev/null; then
      return 1
    fi
  fi
  return 0
}

# --- 脱敏字符串 ---
mask_string() {
  local str="$1"
  local len=${#str}
  if (( len <= 8 )); then
    echo "******"
  else
    local prefix="${str:0:4}"
    local suffix="${str: -4}"
    echo "${prefix}****${suffix}"
  fi
}

# --- 参数解析 ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      ACTION="install"
      shift 1
      ;;
    --uninstall)
      ACTION="uninstall"
      shift 1
      ;;
    --restart)
      ACTION="restart"
      shift 1
      ;;
    --stop)
      ACTION="stop"
      shift 1
      ;;
    --status)
      ACTION="status"
      shift 1
      ;;
    -l|--logs)
      ACTION="logs"
      shift 1
      ;;
    --test)
      ACTION="test"
      shift 1
      ;;
    -b|--rebuild)
      ACTION="rebuild"
      shift 1
      ;;
    --no-cache)
      NO_CACHE=true
      shift 1
      ;;
    -i|--token-id|--service-token-id)
      SERVICE_TOKEN_ID="$2"
      shift 2
      ;;
    -s|--token-secret|--service-token-secret)
      SERVICE_TOKEN_SECRET="$2"
      shift 2
      ;;
    --service-token)
      IFS=':' read -r SERVICE_TOKEN_ID SERVICE_TOKEN_SECRET <<< "$2"
      shift 2
      ;;
    -d|--domains)
      DOMAINS="$2"
      shift 2
      ;;
    -p|--ports)
      PORTS="$2"
      shift 2
      ;;
    -f|--forward)
      FORWARD_RULES+=("$2")
      shift 2
      ;;
    --listen)
      LISTEN_HOST="$2"
      shift 2
      ;;
    --network-mode)
      NETWORK_MODE="$2"
      shift 2
      ;;
    -n|--name)
      SERVICE_NAME="$2"
      CONTAINER_NAME="$2"
      SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
      shift 2
      ;;
    -h|--help)
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

# --- 检查 Root 权限 ---
require_root() {
  if [[ $EUID -ne 0 ]]; then
    error "此操作需要 root 权限，请使用 'sudo bash $0 ...' 运行"
    exit 1
  fi
}

# --- 检查并安装 Docker 环境 ---
check_docker() {
  if ! command -v docker &>/dev/null; then
    warn "未检测到 Docker 环境，正在尝试自动安装 Docker..."
    if command -v curl &>/dev/null; then
      curl -fsSL https://get.docker.com | bash
    else
      error "未找到 curl，无法自动安装 Docker。请先手动安装 Docker。"
      exit 1
    fi
  fi

  if ! systemctl is-active --quiet docker; then
    log "正在启动 Docker 守护进程..."
    systemctl enable --now docker || true
  fi
}

# --- 编译 Docker 镜像 (使用宿主机网络) ---
build_docker_image() {
  log "开始编译 Cloudflare Access TCP Docker 镜像 (基础镜像: ubuntu:24.04, 模式: 宿主机网络)..."
  local build_cmd=("docker" "build" "--network" "host" "-t" "$IMAGE_NAME" "$SCRIPT_DIR")
  if [[ "$NO_CACHE" == "true" ]]; then
    build_cmd+=("--no-cache")
  fi

  log "执行编译指令: ${build_cmd[*]}"
  "${build_cmd[@]}"
  success "Docker 镜像 [$IMAGE_NAME] 编译完成！"
}

# --- 卸载服务 ---
do_uninstall() {
  require_root
  log "正在停止并卸载 ${SERVICE_NAME} Systemd 服务..."
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl stop "$SERVICE_NAME" || true
  fi
  if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl disable "$SERVICE_NAME" || true
  fi

  if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    log "已移除 Systemd 服务文件: $SERVICE_FILE"
  fi

  if docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}\$"; then
    log "正在删除 Docker 容器: $CONTAINER_NAME..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  fi

  if [[ -d "$CONF_DIR" ]]; then
    rm -rf "$CONF_DIR"
    log "已清理配置文件目录: $CONF_DIR"
  fi

  success "${SERVICE_NAME} 已完全卸载并清理完毕！"
  exit 0
}

# --- 重启服务 ---
do_restart() {
  require_root
  log "正在重启 ${SERVICE_NAME} 服务..."
  systemctl restart "$SERVICE_NAME"
  success "${SERVICE_NAME} 重启指令已发送，正在检查状态..."
  sleep 2
  do_status
}

# --- 停止服务 ---
do_stop() {
  require_root
  log "正在停止 ${SERVICE_NAME} 服务..."
  systemctl stop "$SERVICE_NAME" || true
  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  success "${SERVICE_NAME} 服务已停止。"
  exit 0
}

# --- 查看日志 ---
do_logs() {
  if command -v journalctl &>/dev/null && [[ -f "$SERVICE_FILE" ]]; then
    journalctl -u "$SERVICE_NAME" -f -n 50
  else
    docker logs -f --tail 50 "$CONTAINER_NAME"
  fi
  exit 0
}

# --- 查看状态 ---
do_status() {
  echo -e "${CYAN}${BOLD}=== ${SERVICE_NAME} 运行状态监控 ===${NC}"
  echo ""
  if [[ -f "$SERVICE_FILE" ]]; then
    local svc_active
    svc_active=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "inactive")
    if [[ "$svc_active" == "active" ]]; then
      echo -e "Systemd 服务状态:  ${GREEN}${BOLD}● active (running)${NC}"
    else
      echo -e "Systemd 服务状态:  ${RED}${BOLD}○ $svc_active${NC}"
    fi
  else
    echo -e "Systemd 服务状态:  ${YELLOW}未安装 Systemd 服务${NC}"
  fi

  echo -n "Docker 容器状态:   "
  if docker ps --format '{{.Names}} ({{.Status}})' | grep -E "^${CONTAINER_NAME} " &>/dev/null; then
    echo -e "${GREEN}${BOLD}$(docker ps --format '{{.Names}} ({{.Status}})' | grep -E "^${CONTAINER_NAME} ")${NC}"
  elif docker ps -a --format '{{.Names}} ({{.Status}})' | grep -E "^${CONTAINER_NAME} " &>/dev/null; then
    echo -e "${YELLOW}$(docker ps -a --format '{{.Names}} ({{.Status}})' | grep -E "^${CONTAINER_NAME} ")${NC}"
  else
    echo -e "${RED}容器未运行或未创建${NC}"
  fi

  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    echo ""
    echo -e "${CYAN}当前配置的转发规则:${NC}"
    IFS=',' read -r -a cur_domains <<< "${DOMAINS:-}"
    IFS=',' read -r -a cur_ports <<< "${PORTS:-}"
    local host_listen="${LISTEN_HOST:-localhost}"
    for i in "${!cur_domains[@]}"; do
      local p="${cur_ports[i]}"
      local d="${cur_domains[i]}"
      local port_status="${RED}未监听${NC}"
      if ss -tlpn "sport = :$p" 2>/dev/null | grep -q ":$p"; then
        port_status="${GREEN}监听中 (TCP)${NC}"
      elif nc -z 127.0.0.1 "$p" 2>/dev/null; then
        port_status="${GREEN}连通正常 (TCP)${NC}"
      fi
      printf "  [%d] %-15s -> %-30s [状态: %b]\n" "$((i+1))" "${host_listen}:${p}" "$d" "$port_status"
    done
  fi
  echo ""
  exit 0
}

# --- 测试连通性 ---
do_test() {
  if [[ ! -f "$ENV_FILE" ]]; then
    error "未找到配置文件 ($ENV_FILE)，请先执行安装配置。"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  IFS=',' read -r -a cur_domains <<< "${DOMAINS:-}"
  IFS=',' read -r -a cur_ports <<< "${PORTS:-}"
  local host_listen="${LISTEN_HOST:-127.0.0.1}"
  [[ "$host_listen" == "localhost" || "$host_listen" == "0.0.0.0" ]] && host_listen="127.0.0.1"

  echo -e "${CYAN}${BOLD}=== 测试本地 TCP 转发端口连通性 ===${NC}"
  for i in "${!cur_domains[@]}"; do
    local p="${cur_ports[i]}"
    local d="${cur_domains[i]}"
    echo -n "测试规则 #$((i+1)) [${host_listen}:${p} -> ${d}] ... "
    
    if command -v nc &>/dev/null; then
      if nc -z -w 3 "$host_listen" "$p" &>/dev/null; then
        echo -e "${GREEN}✓ 端口已开放且可连接${NC}"
      else
        echo -e "${RED}✗ 连接失败 (端口未监听或超时)${NC}"
      fi
    elif timeout 3 bash -c "cat < /dev/null > /dev/tcp/${host_listen}/${p}" 2>/dev/null; then
      echo -e "${GREEN}✓ 端口已开放且可连接${NC}"
    else
      echo -e "${RED}✗ 连接失败 (端口未监听或超时)${NC}"
    fi
  done
  exit 0
}

# --- 仅重新编译镜像模式 ---
if [[ "$ACTION" == "rebuild" ]]; then
  require_root
  check_docker
  build_docker_image
  exit 0
fi

# --- 各种非安装模式分流 ---
case "$ACTION" in
  uninstall) do_uninstall ;;
  restart)   do_restart ;;
  stop)      do_stop ;;
  logs)      do_logs ;;
  status)    do_status ;;
  test)      do_test ;;
esac

# ==================== 执行一键安装流程 ====================
require_root
check_docker

# 1. 尝试继承现有配置文件中的 Token 或参数 (若用户未显式传入)
if [[ -f "$ENV_FILE" ]]; then
  EXISTING_TOKEN_ID=$(grep -E "^SERVICE_TOKEN_ID=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' || true)
  EXISTING_TOKEN_SECRET=$(grep -E "^SERVICE_TOKEN_SECRET=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' || true)
  EXISTING_DOMAINS=$(grep -E "^DOMAINS=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' || true)
  EXISTING_PORTS=$(grep -E "^PORTS=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' || true)
  EXISTING_LISTEN=$(grep -E "^LISTEN_HOST=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' || true)
  EXISTING_NET_MODE=$(grep -E "^NETWORK_MODE=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' || true)

  [[ -z "$SERVICE_TOKEN_ID" && -n "$EXISTING_TOKEN_ID" ]] && SERVICE_TOKEN_ID="$EXISTING_TOKEN_ID"
  [[ -z "$SERVICE_TOKEN_SECRET" && -n "$EXISTING_TOKEN_SECRET" ]] && SERVICE_TOKEN_SECRET="$EXISTING_TOKEN_SECRET"
  [[ -z "$DOMAINS" && -n "$EXISTING_DOMAINS" && ${#FORWARD_RULES[@]} -eq 0 ]] && DOMAINS="$EXISTING_DOMAINS"
  [[ -z "$PORTS" && -n "$EXISTING_PORTS" && ${#FORWARD_RULES[@]} -eq 0 ]] && PORTS="$EXISTING_PORTS"
  [[ -z "$LISTEN_HOST" && -n "$EXISTING_LISTEN" ]] && LISTEN_HOST="$EXISTING_LISTEN"
  [[ -z "$NETWORK_MODE" && -n "$EXISTING_NET_MODE" ]] && NETWORK_MODE="$EXISTING_NET_MODE"
fi

# 2. 检查与交互式输入必选参数: SERVICE_TOKEN_ID 与 SERVICE_TOKEN_SECRET
if [[ -z "$SERVICE_TOKEN_ID" ]]; then
  if [[ -t 0 ]]; then
    echo -e "${YELLOW}请输入 Cloudflare Access Service Token Client ID:${NC}"
    read -r -p "Service Token ID: " SERVICE_TOKEN_ID
  fi
fi

if [[ -z "$SERVICE_TOKEN_SECRET" ]]; then
  if [[ -t 0 ]]; then
    echo -e "${YELLOW}请输入 Cloudflare Access Service Token Client Secret:${NC}"
    read -r -s -p "Service Token Secret: " SERVICE_TOKEN_SECRET
    echo ""
  fi
fi

if [[ -z "$SERVICE_TOKEN_ID" || -z "$SERVICE_TOKEN_SECRET" ]]; then
  error "缺少必选参数: SERVICE_TOKEN_ID 与 SERVICE_TOKEN_SECRET！"
  error "可通过参数 -i / -s 传入，或通过环境变量注入。详见 '$0 --help'。"
  exit 1
fi

# 3. 处理 --forward 规则 或默认 DOMAINS/PORTS
if [[ ${#FORWARD_RULES[@]} -gt 0 ]]; then
  PARSED_DOMAINS=()
  PARSED_PORTS=()
  for rule_str in "${FORWARD_RULES[@]}"; do
    IFS=',' read -r -a subrules <<< "$rule_str"
    for r in "${subrules[@]}"; do
      r=$(echo "$r" | xargs)
      [[ -z "$r" ]] && continue
      if [[ "$r" != *:* ]]; then
        error "无效的转发规则格式: '$r'，必须为 'domain:port' 格式"
        exit 1
      fi
      d="${r%%:*}"
      p="${r##*:}"
      PARSED_DOMAINS+=("$d")
      PARSED_PORTS+=("$p")
    done
  done
  DOMAINS=$(IFS=,; echo "${PARSED_DOMAINS[*]}")
  PORTS=$(IFS=,; echo "${PARSED_PORTS[*]}")
fi

DOMAINS="${DOMAINS:-$DEFAULT_DOMAINS}"
PORTS="${PORTS:-$DEFAULT_PORTS}"
LISTEN_HOST="${LISTEN_HOST:-$DEFAULT_LISTEN}"

# 4. 严格解析与校验域名与端口
IFS=',' read -r -a DOMAIN_LIST <<< "$DOMAINS"
IFS=',' read -r -a PORT_LIST <<< "$PORTS"

if [[ ${#DOMAIN_LIST[@]} -ne ${#PORT_LIST[@]} ]]; then
  error "域名列表数量 (${#DOMAIN_LIST[@]}) 与 端口列表数量 (${#PORT_LIST[@]}) 不匹配！"
  error "域名列表: $DOMAINS"
  error "端口列表: $PORTS"
  exit 1
fi

if [[ ${#DOMAIN_LIST[@]} -eq 0 ]]; then
  error "配置的转发规则列表不能为空！"
  exit 1
fi

CLEAN_DOMAINS=()
CLEAN_PORTS=()
declare -A SEEN_PORTS

for i in "${!DOMAIN_LIST[@]}"; do
  d=$(echo "${DOMAIN_LIST[i]}" | xargs)
  p=$(echo "${PORT_LIST[i]}" | xargs)

  if ! validate_domain "$d"; then
    error "规则 #$((i+1)) 域名校验失败: '$d'"
    exit 1
  fi

  if ! validate_port "$p"; then
    error "规则 #$((i+1)) 端口校验失败: '$p'"
    exit 1
  fi

  if [[ -n "${SEEN_PORTS[$p]}" ]]; then
    error "规则 #$((i+1)) 端口 $p 与 规则 #${SEEN_PORTS[$p]} 重复冲突！"
    exit 1
  fi
  SEEN_PORTS[$p]=$((i+1))

  # 检查宿主机端口是否被其他非当前容器进程占用
  if ! check_port_available "$p"; then
    # 如果是当前服务已在运行，则不视为冲突
    if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
      warn "宿主机端口 $p 当前已被占用，启动服务时可能会监听冲突，请确认。"
    fi
  fi

  CLEAN_DOMAINS+=("$d")
  CLEAN_PORTS+=("$p")
done

DOMAINS=$(IFS=,; echo "${CLEAN_DOMAINS[*]}")
PORTS=$(IFS=,; echo "${CLEAN_PORTS[*]}")

# 5. 编译 Docker 镜像 (使用宿主机网络)
build_docker_image

# 6. 安全创建独立加密配置文件 (/etc/cloudflare-access-tcp/access.env, 权限 600)
mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"

cat > "$ENV_FILE" <<EOF
# Cloudflare Access TCP Client Configuration
# Created at: $(date '+%Y-%m-%d %H:%M:%S')
SERVICE_TOKEN_ID="${SERVICE_TOKEN_ID}"
SERVICE_TOKEN_SECRET="${SERVICE_TOKEN_SECRET}"
DOMAINS="${DOMAINS}"
PORTS="${PORTS}"
LISTEN_HOST="${LISTEN_HOST}"
NETWORK_MODE="${NETWORK_MODE}"
LOG_LEVEL="info"
EOF

chmod 600 "$ENV_FILE"
log "已安全写入凭据与环境配置文件: $ENV_FILE (权限: 600)"

# 7. 配置并生成 Systemd 服务文件
log "正在配置 Systemd 服务文件: $SERVICE_FILE ..."

DOCKER_PORT_FLAGS=()
if [[ "$NETWORK_MODE" == "bridge" ]]; then
  for p in "${CLEAN_PORTS[@]}"; do
    DOCKER_PORT_FLAGS+=("-p" "${p}:${p}")
  done
  DOCKER_NET_FLAG="--network bridge ${DOCKER_PORT_FLAGS[*]}"
else
  DOCKER_NET_FLAG="--network host"
fi

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Access TCP Client Forwarder (${SERVICE_NAME})
Documentation=https://github.com/JayYang1991/vps-utils
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5s
TimeoutStartSec=0
KillMode=control-group
EnvironmentFile=${ENV_FILE}

ExecStartPre=-/usr/bin/docker rm -f ${CONTAINER_NAME}
ExecStart=/usr/bin/docker run --rm --name ${CONTAINER_NAME} \
    ${DOCKER_NET_FLAG} \
    --env-file ${ENV_FILE} \
    ${IMAGE_NAME}
ExecStop=/usr/bin/docker stop -t 5 ${CONTAINER_NAME}

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$SERVICE_FILE"

# 8. 启用并启动 Systemd 服务
log "重载 Systemd 守护进程并启动服务..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

log "等待服务就绪..."
sleep 3

# 9. 校验与输出结果
if systemctl is-active --quiet "$SERVICE_NAME"; then
  echo ""
  echo -e "${GREEN}${BOLD}================================================================${NC}"
  echo -e "${GREEN}${BOLD}  Cloudflare Access TCP 客户端一键安装成功并已开启开机自启！  ${NC}"
  echo -e "${GREEN}${BOLD}================================================================${NC}"
  echo ""
  echo -e "${CYAN}服务配置信息概览:${NC}"
  echo -e "  • 服务名称:         ${BOLD}${SERVICE_NAME}${NC}"
  echo -e "  • 配置文件:         ${BOLD}${ENV_FILE}${NC} (权限 600)"
  echo -e "  • 监听地址:         ${BOLD}${LISTEN_HOST}${NC}"
  echo -e "  • 网络模式:         ${BOLD}${NETWORK_MODE}${NC}"
  echo -e "  • Service Token ID: $(mask_string "$SERVICE_TOKEN_ID")"
  echo ""
  echo -e "${CYAN}已配置的 TCP 转发列表:${NC}"
  for i in "${!CLEAN_DOMAINS[@]}"; do
    echo -e "  • 规则 #$((i+1)): ${YELLOW}${LISTEN_HOST}:${CLEAN_PORTS[i]}${NC}  ===>  ${CYAN}${CLEAN_DOMAINS[i]}${NC}"
  done
  echo ""
  echo -e "${CYAN}常用运维管理命令:${NC}"
  echo "  • 查看服务状态:   sudo systemctl status ${SERVICE_NAME}  或  sudo bash $0 --status"
  echo "  • 查看实时日志:   sudo journalctl -u ${SERVICE_NAME} -f  或  sudo bash $0 --logs"
  echo "  • 重启转发服务:   sudo systemctl restart ${SERVICE_NAME} 或  sudo bash $0 --restart"
  echo "  • 停止转发服务:   sudo systemctl stop ${SERVICE_NAME}    或  sudo bash $0 --stop"
  echo "  • 测试端口连通性: sudo bash $0 --test"
  echo "  • 卸载与清理:     sudo bash $0 --uninstall"
  echo ""
  echo -e "${GREEN}客户端使用示例:${NC}"
  echo "  在代理客户端 (如 Clash / sing-box / Emby / Jellyfin / 浏览器代理) 中，"
  echo "  直接连接本机的 127.0.0.1:${CLEAN_PORTS[0]} 即可直达远程 ${CLEAN_DOMAINS[0]}。"
  echo -e "${GREEN}================================================================${NC}"
else
  error "服务启动失败！正在获取最近的错误日志..."
  journalctl -u "$SERVICE_NAME" -n 20 --no-pager || true
  exit 1
fi
