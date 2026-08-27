#!/usr/bin/env bash
#
# install.sh
# Cloudflare Access TCP 客户端一键安装与 Systemd 容器部署脚本
# 负责安装 Docker 镜像构建、生成 /etc/cloudflare-access-tcp 配置文件、注册 Systemd 开机自启服务，
# 并将日常运维管理 CLI 脚本安装至宿主机系统路径 (/usr/local/bin/cloudflare-access-tcp)。
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

# --- 字符串清洗辅助函数 ---
clean_val() {
  local val="$1"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  while [[ "$val" == \"*\" || "$val" == \'*\' ]]; do
    val="${val:1:-1}"
  done
  val="${val#\"}"
  val="${val%\"}"
  val="${val#\'}"
  val="${val%\'}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}

# --- 基础与默认变量 ---
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")
SERVICE_NAME="cloudflare-access-tcp"
CONTAINER_NAME="cloudflare-access-tcp"
IMAGE_NAME="cloudflare-access-tcp:latest"
CONF_DIR="/etc/cloudflare-access-tcp"
ENV_FILE="${CONF_DIR}/access.env"
CANDIDATES_FILE="${CONF_DIR}/candidates.txt"
STATUS_FILE="${CONF_DIR}/status.json"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BIN_DIR="/usr/local/bin"
CLI_BIN="${BIN_DIR}/cloudflare-access-tcp"
CLI_ALIAS="${BIN_DIR}/cf-access-tcp"
SHARE_DIR="/usr/local/share/cloudflare-access-tcp"

DEFAULT_DOMAINS="movies.19910417.xyz,movies1.19910417.xyz"
DEFAULT_PORTS="5000,5001"
DEFAULT_LISTEN="127.0.0.1"
DEFAULT_NETWORK_MODE="bridge"

SERVICE_TOKEN_ID="${SERVICE_TOKEN_ID:-}"
SERVICE_TOKEN_SECRET="${SERVICE_TOKEN_SECRET:-}"
DOMAINS="${DOMAINS:-}"
PORTS="${PORTS:-}"
LISTEN_HOST="${LISTEN_HOST:-}"
PREFERRED_IP="${PREFERRED_IP:-}"
NETWORK_MODE="${NETWORK_MODE:-$DEFAULT_NETWORK_MODE}"
CF_SUB_URL="${CF_SUB_URL:-https://sub.19910417.xyz}"

FORWARD_RULES=()
ACTION="install"
NO_CACHE=false
CHECK_INTERVAL_ARG="15"
FAIL_THRESHOLD_ARG="2"

# --- 显示帮助信息 ---
show_help() {
  echo -e "${CYAN}${BOLD}Cloudflare Access TCP 客户端一键安装与 Systemd 容器部署脚本${NC}"
  echo ""
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "安装与部署选项:"
  echo "  -i, --token-id <ID>         Cloudflare Access Service Token Client ID"
  echo "  -s, --token-secret <SECRET> Cloudflare Access Service Token Client Secret"
  echo "      --service-token <ID:KEY>以 'ID:SECRET' 格式一次性传入 Service Token"
  echo "  --ip, --preferred-ip <IP>   指定初始 Cloudflare 优选 IP (若不指定将自动通过测速获取)"
  echo "  -d, --domains <D1,D2,...>   目标域名列表，逗号分隔 (默认: movies.19910417.xyz,movies1.19910417.xyz)"
  echo "  -p, --ports <P1,P2,...>     本地监听端口列表，逗号分隔 (默认: 5000,5001)"
  echo "  -f, --forward <D:P,...>     转发规则列表，格式为 'domain1:port1,domain2:port2' (可指定多次)"
  echo "      --listen <HOST>         宿主机监听绑定地址 (默认: 127.0.0.1, 可设为 0.0.0.0 开放局域网)"
  echo "      --sub-url <URL>         订阅服务器拉取地址 (默认: https://sub.19910417.xyz)"
  echo "      --check-interval <SEC>  TCP 连通性检测间隔秒数 (默认: 15)"
  echo "      --fail-threshold <NUM>  连续失败触发故障转移次数 (默认: 2)"
  echo "  -n, --name <NAME>           自定义服务与容器名称 (默认: cloudflare-access-tcp)"
  echo "      --no-cache              构建 Docker 镜像时不使用缓存 (全新编译)"
  echo "  -h, --help                  显示此帮助信息"
  echo ""
  echo "日常运维管理请使用已安装的全局命令: ${BOLD}cloudflare-access-tcp${NC} 或 ${BOLD}cf-access-tcp${NC}"
  echo "  • cloudflare-access-tcp status        # 查看运行状态与优选指标"
  echo "  • cloudflare-access-tcp candidates    # 查看 TOP 20 优选池"
  echo "  • cloudflare-access-tcp speedtest     # 立即触发一次优选测速"
  echo "  • cloudflare-access-tcp logs -f       # 实时追踪日志"
  echo "  • cloudflare-access-tcp test          # 测试端口与链路连通性"
  echo "  • cloudflare-access-tcp restart       # 重启转发服务"
  echo "  • cloudflare-access-tcp uninstall     # 卸载清理服务"
}

# --- 严格校验域名格式 ---
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

# --- 严格校验 IP 地址 ---
validate_ip() {
  local ip="$1"
  [[ -z "$ip" ]] && return 0
  local ipv4_regex="^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
  if [[ "$ip" =~ $ipv4_regex ]]; then
    return 0
  fi
  if [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
    return 0
  fi
  error "优选 IP 格式无效: $ip"
  return 1
}

# --- 检查端口占用 ---
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

# --- 检查 Root 权限 ---
require_root() {
  if [[ $EUID -ne 0 ]]; then
    error "安装操作需要 root 权限，请使用 'sudo bash $0 ...' 运行"
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
  log "开始编译 Cloudflare Access TCP Docker 镜像 (基础镜像: ubuntu:24.04, 构建网络: 宿主机网络 --network host)..."
  local build_cmd=("docker" "build" "--network" "host" "-t" "$IMAGE_NAME" "$SCRIPT_DIR")
  if [[ "$NO_CACHE" == "true" ]]; then
    build_cmd+=("--no-cache")
  fi

  log "执行编译指令: ${build_cmd[*]}"
  "${build_cmd[@]}"
  success "Docker 镜像 [$IMAGE_NAME] 编译完成！"
}

# --- 安装运维管理 CLI 工具至宿主机 ---
install_cli_tools() {
  log "正在安装日常运维管理脚本至宿主机系统路径 (${CLI_BIN}) ..."
  mkdir -p "$BIN_DIR" "$SHARE_DIR"

  # 复制 service.sh 到 /usr/local/bin/cloudflare-access-tcp
  if [[ -f "${SCRIPT_DIR}/service.sh" ]]; then
    cp -f "${SCRIPT_DIR}/service.sh" "$CLI_BIN"
  else
    error "未找到 service.sh 运维脚本文件！"
    exit 1
  fi
  chmod +x "$CLI_BIN"

  # 创建短命令软链接 cf-access-tcp
  ln -sf "$CLI_BIN" "$CLI_ALIAS"

  # 备份 Dockerfile 与依赖至 /usr/local/share/cloudflare-access-tcp 供 rebuild 使用
  cp -rf "${SCRIPT_DIR}"/* "$SHARE_DIR/" 2>/dev/null || true

  success "日常运维管理命令已就绪: ${BOLD}cloudflare-access-tcp${NC} (别名: ${BOLD}cf-access-tcp${NC})"
}

# --- 参数解析 ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      ACTION="install"
      shift 1
      ;;
    --uninstall)
      require_root
      if [[ -f "${SCRIPT_DIR}/service.sh" ]]; then
        bash "${SCRIPT_DIR}/service.sh" uninstall
      elif command -v cloudflare-access-tcp &>/dev/null; then
        cloudflare-access-tcp uninstall
      fi
      exit 0
      ;;
    --status|status)
      if [[ -f "${SCRIPT_DIR}/service.sh" ]]; then
        bash "${SCRIPT_DIR}/service.sh" status
      elif command -v cloudflare-access-tcp &>/dev/null; then
        cloudflare-access-tcp status
      fi
      exit 0
      ;;
    --test|test)
      if [[ -f "${SCRIPT_DIR}/service.sh" ]]; then
        bash "${SCRIPT_DIR}/service.sh" test
      elif command -v cloudflare-access-tcp &>/dev/null; then
        cloudflare-access-tcp test
      fi
      exit 0
      ;;
    --logs|logs|-l)
      if [[ -f "${SCRIPT_DIR}/service.sh" ]]; then
        bash "${SCRIPT_DIR}/service.sh" logs "${@:2}"
      elif command -v cloudflare-access-tcp &>/dev/null; then
        cloudflare-access-tcp logs "${@:2}"
      fi
      exit 0
      ;;
    --restart|restart)
      if [[ -f "${SCRIPT_DIR}/service.sh" ]]; then
        bash "${SCRIPT_DIR}/service.sh" restart
      elif command -v cloudflare-access-tcp &>/dev/null; then
        cloudflare-access-tcp restart
      fi
      exit 0
      ;;
    --speedtest|speedtest|--candidates|candidates)
      if [[ -f "${SCRIPT_DIR}/service.sh" ]]; then
        bash "${SCRIPT_DIR}/service.sh" "$1"
      elif command -v cloudflare-access-tcp &>/dev/null; then
        cloudflare-access-tcp "$1"
      fi
      exit 0
      ;;
    --no-cache)
      NO_CACHE=true
      shift 1
      ;;
    -i|--token-id|--service-token-id)
      SERVICE_TOKEN_ID=$(clean_val "$2")
      shift 2
      ;;
    -s|--token-secret|--service-token-secret)
      SERVICE_TOKEN_SECRET=$(clean_val "$2")
      shift 2
      ;;
    --service-token)
      IFS=':' read -r raw_id raw_sec <<< "$2"
      SERVICE_TOKEN_ID=$(clean_val "$raw_id")
      SERVICE_TOKEN_SECRET=$(clean_val "$raw_sec")
      shift 2
      ;;
    --ip|--preferred-ip|-ip)
      PREFERRED_IP=$(clean_val "$2")
      shift 2
      ;;
    -d|--domains)
      DOMAINS=$(clean_val "$2")
      shift 2
      ;;
    -p|--ports)
      PORTS=$(clean_val "$2")
      shift 2
      ;;
    -f|--forward)
      FORWARD_RULES+=("$2")
      shift 2
      ;;
    --listen)
      LISTEN_HOST=$(clean_val "$2")
      shift 2
      ;;
    --sub-url)
      CF_SUB_URL=$(clean_val "$2")
      shift 2
      ;;
    --check-interval)
      CHECK_INTERVAL_ARG=$(clean_val "$2")
      shift 2
      ;;
    --fail-threshold)
      FAIL_THRESHOLD_ARG=$(clean_val "$2")
      shift 2
      ;;
    --network-mode)
      NETWORK_MODE=$(clean_val "$2")
      shift 2
      ;;
    -n|--name)
      SERVICE_NAME=$(clean_val "$2")
      CONTAINER_NAME="$SERVICE_NAME"
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

# ==================== 执行一键安装流程 ====================
require_root
check_docker

# 1. 尝试继承现有配置文件中的 Token 或参数
if [[ -f "$ENV_FILE" ]]; then
  EXISTING_TOKEN_ID=$(grep -E "^SERVICE_TOKEN_ID=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  EXISTING_TOKEN_SECRET=$(grep -E "^SERVICE_TOKEN_SECRET=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  EXISTING_DOMAINS=$(grep -E "^DOMAINS=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  EXISTING_PORTS=$(grep -E "^PORTS=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  EXISTING_LISTEN=$(grep -E "^LISTEN_HOST=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  EXISTING_PREF_IP=$(grep -E "^PREFERRED_IP=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  EXISTING_NET_MODE=$(grep -E "^NETWORK_MODE=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)

  [[ -z "$SERVICE_TOKEN_ID" && -n "$EXISTING_TOKEN_ID" ]] && SERVICE_TOKEN_ID=$(clean_val "$EXISTING_TOKEN_ID")
  [[ -z "$SERVICE_TOKEN_SECRET" && -n "$EXISTING_TOKEN_SECRET" ]] && SERVICE_TOKEN_SECRET=$(clean_val "$EXISTING_TOKEN_SECRET")
  [[ -z "$DOMAINS" && -n "$EXISTING_DOMAINS" && ${#FORWARD_RULES[@]} -eq 0 ]] && DOMAINS=$(clean_val "$EXISTING_DOMAINS")
  [[ -z "$PORTS" && -n "$EXISTING_PORTS" && ${#FORWARD_RULES[@]} -eq 0 ]] && PORTS=$(clean_val "$EXISTING_PORTS")
  [[ -z "$LISTEN_HOST" && -n "$EXISTING_LISTEN" ]] && LISTEN_HOST=$(clean_val "$EXISTING_LISTEN")
  [[ -z "$PREFERRED_IP" && -n "$EXISTING_PREF_IP" ]] && PREFERRED_IP=$(clean_val "$EXISTING_PREF_IP")
  [[ -z "$NETWORK_MODE" && -n "$EXISTING_NET_MODE" ]] && NETWORK_MODE=$(clean_val "$EXISTING_NET_MODE")
fi

# 2. 检查必选参数
if [[ -z "$SERVICE_TOKEN_ID" ]]; then
  if [[ -t 0 ]]; then
    echo -e "${YELLOW}请输入 Cloudflare Access Service Token Client ID:${NC}"
    read -r -p "Service Token ID: " SERVICE_TOKEN_ID
    SERVICE_TOKEN_ID=$(clean_val "$SERVICE_TOKEN_ID")
  fi
fi

if [[ -z "$SERVICE_TOKEN_SECRET" ]]; then
  if [[ -t 0 ]]; then
    echo -e "${YELLOW}请输入 Cloudflare Access Service Token Client Secret:${NC}"
    read -r -s -p "Service Token Secret: " SERVICE_TOKEN_SECRET
    echo ""
    SERVICE_TOKEN_SECRET=$(clean_val "$SERVICE_TOKEN_SECRET")
  fi
fi

if [[ -z "$SERVICE_TOKEN_ID" || -z "$SERVICE_TOKEN_SECRET" ]]; then
  error "缺少必选参数: SERVICE_TOKEN_ID 与 SERVICE_TOKEN_SECRET！"
  error "可通过参数 -i / -s 传入，详见 '$0 --help'。"
  exit 1
fi

# 3. 处理 --forward 规则 或默认 DOMAINS/PORTS
if [[ ${#FORWARD_RULES[@]} -gt 0 ]]; then
  PARSED_DOMAINS=()
  PARSED_PORTS=()
  for rule_str in "${FORWARD_RULES[@]}"; do
    IFS=',' read -r -a subrules <<< "$rule_str"
    for r in "${subrules[@]}"; do
      r=$(clean_val "$r")
      [[ -z "$r" ]] && continue
      if [[ "$r" != *:* ]]; then
        error "无效的转发规则格式: '$r'，必须为 'domain:port' 格式"
        exit 1
      fi
      d=$(clean_val "${r%%:*}")
      p=$(clean_val "${r##*:}")
      PARSED_DOMAINS+=("$d")
      PARSED_PORTS+=("$p")
    done
  done
  DOMAINS=$(IFS=,; echo "${PARSED_DOMAINS[*]}")
  PORTS=$(IFS=,; echo "${PARSED_PORTS[*]}")
fi

DOMAINS=$(clean_val "${DOMAINS:-$DEFAULT_DOMAINS}")
PORTS=$(clean_val "${PORTS:-$DEFAULT_PORTS}")
LISTEN_HOST=$(clean_val "${LISTEN_HOST:-$DEFAULT_LISTEN}")
PREFERRED_IP=$(clean_val "${PREFERRED_IP:-}")

# 4. 严格解析与校验域名、端口及优选 IP
IFS=',' read -r -a DOMAIN_LIST <<< "$DOMAINS"
IFS=',' read -r -a PORT_LIST <<< "$PORTS"

if [[ ${#DOMAIN_LIST[@]} -ne ${#PORT_LIST[@]} ]]; then
  error "域名列表数量 (${#DOMAIN_LIST[@]}) 与 端口列表数量 (${#PORT_LIST[@]}) 不匹配！"
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
  d=$(clean_val "${DOMAIN_LIST[i]}")
  p=$(clean_val "${PORT_LIST[i]}")

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

  if ! check_port_available "$p"; then
    if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
      warn "宿主机端口 $p 当前已被占用，启动服务时可能会监听冲突，请确认。"
    fi
  fi

  CLEAN_DOMAINS+=("$d")
  CLEAN_PORTS+=("$p")
done

if [[ -n "$PREFERRED_IP" ]]; then
  if ! validate_ip "$PREFERRED_IP"; then
    error "优选 IP 校验失败: '$PREFERRED_IP'"
    exit 1
  fi
fi

DOMAINS=$(IFS=,; echo "${CLEAN_DOMAINS[*]}")
PORTS=$(IFS=,; echo "${CLEAN_PORTS[*]}")

# 5. 编译 Docker 镜像 (使用宿主机网络)
build_docker_image

# 6. 安装运维管理 CLI 脚本至宿主机系统路径
install_cli_tools

# 7. 安全创建独立加密配置文件 (/etc/cloudflare-access-tcp/access.env, 权限 600)
mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"

cat > "$ENV_FILE" <<EOF
# Cloudflare Access TCP Client Configuration
# Created at: $(date '+%Y-%m-%d %H:%M:%S')
SERVICE_TOKEN_ID=${SERVICE_TOKEN_ID}
SERVICE_TOKEN_SECRET=${SERVICE_TOKEN_SECRET}
DOMAINS=${DOMAINS}
PORTS=${PORTS}
LISTEN_HOST=${LISTEN_HOST}
PREFERRED_IP=${PREFERRED_IP}
NETWORK_MODE=${NETWORK_MODE}
CF_SUB_URL=${CF_SUB_URL}
CHECK_INTERVAL=${CHECK_INTERVAL_ARG}
FAIL_THRESHOLD=${FAIL_THRESHOLD_ARG}
LOG_LEVEL=info
EOF

chmod 600 "$ENV_FILE"
log "已安全写入凭据与环境配置文件: $ENV_FILE (权限: 600)"

# 8. 配置并生成 Systemd 服务文件 (持久化映射 /etc/cloudflare-access-tcp 卷)
log "正在配置 Systemd 服务文件: $SERVICE_FILE ..."

BIND_IP="127.0.0.1"
if [[ "$LISTEN_HOST" == "0.0.0.0" || "$LISTEN_HOST" == "all" ]]; then
  BIND_IP="0.0.0.0"
elif [[ "$LISTEN_HOST" == "localhost" || "$LISTEN_HOST" == "127.0.0.1" || -z "$LISTEN_HOST" ]]; then
  BIND_IP="127.0.0.1"
else
  BIND_IP="$LISTEN_HOST"
fi

DOCKER_PORT_FLAGS=()
for p in "${CLEAN_PORTS[@]}"; do
  DOCKER_PORT_FLAGS+=("-p" "${BIND_IP}:${p}:${p}")
done

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
ExecStart=/usr/bin/docker run --rm --name ${CONTAINER_NAME} \\
    --network bridge \\
    -v ${CONF_DIR}:${CONF_DIR} \\
    ${DOCKER_PORT_FLAGS[*]} \\
    --env-file ${ENV_FILE} \\
    ${IMAGE_NAME}
ExecStop=/usr/bin/docker stop -t 5 ${CONTAINER_NAME}

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$SERVICE_FILE"

# 9. 启用并启动 Systemd 服务
log "重载 Systemd 守护进程并启动服务..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

log "等待服务就绪..."
sleep 3

# 10. 校验与输出结果
if systemctl is-active --quiet "$SERVICE_NAME"; then
  echo ""
  echo -e "${GREEN}${BOLD}================================================================${NC}"
  echo -e "${GREEN}${BOLD}  Cloudflare Access TCP 客户端一键安装成功并已开启开机自启！  ${NC}"
  echo -e "${GREEN}${BOLD}================================================================${NC}"
  echo ""
  echo -e "${CYAN}服务配置信息概览:${NC}"
  echo -e "  • 服务名称:         ${BOLD}${SERVICE_NAME}${NC}"
  echo -e "  • 配置文件:         ${BOLD}${ENV_FILE}${NC} (权限 600)"
  echo -e "  • 待选 IP 文件:     ${BOLD}${CANDIDATES_FILE}${NC} (TOP 20 池)"
  echo -e "  • 宿主机管理命令:   ${GREEN}${BOLD}${CLI_BIN}${NC} (全局命令: ${BOLD}cloudflare-access-tcp${NC})"
  echo -e "  • 监听地址:         ${BOLD}${LISTEN_HOST}${NC}"
  echo -e "  • 优选调度策略:     ${GREEN}每日凌晨 02:00~06:00 随机测速 + 实时 TCP 故障自动切换${NC}"
  echo -e "  • Service Token ID: $(mask_string "$SERVICE_TOKEN_ID")"
  echo ""
  echo -e "${CYAN}已配置的 TCP 转发列表:${NC}"
  for i in "${!CLEAN_DOMAINS[@]}"; do
    echo -e "  • 规则 #$((i+1)): ${YELLOW}${LISTEN_HOST}:${CLEAN_PORTS[i]}${NC}  ===>  ${CYAN}${CLEAN_DOMAINS[i]}${NC}"
  done
  echo ""
  echo -e "${CYAN}常用日常运维管理命令 (系统全局命令):${NC}"
  echo -e "  • 查看运行状态与优选监控: ${GREEN}cloudflare-access-tcp status${NC}"
  echo -e "  • 查看当前 TOP 20 待选池: ${GREEN}cloudflare-access-tcp candidates${NC}"
  echo -e "  • 立即执行一次全量测速:   ${GREEN}cloudflare-access-tcp speedtest${NC}"
  echo -e "  • 查看实时运行日志:       ${GREEN}cloudflare-access-tcp logs -f${NC}"
  echo -e "  • 测试本地端口连通性:     ${GREEN}cloudflare-access-tcp test${NC}"
  echo -e "  • 手动切换指定优选 IP:    ${GREEN}sudo cloudflare-access-tcp switch-ip <IP>${NC}"
  echo -e "  • 重启转发服务:           ${GREEN}sudo cloudflare-access-tcp restart${NC}"
  echo -e "  • 停止转发服务:           ${GREEN}sudo cloudflare-access-tcp stop${NC}"
  echo -e "  • 查看或编辑配置文件:     ${GREEN}sudo cloudflare-access-tcp config --edit${NC}"
  echo -e "  • 卸载与清理服务:         ${GREEN}sudo cloudflare-access-tcp uninstall${NC}"
  echo -e "${GREEN}================================================================${NC}"
else
  error "服务启动失败！正在获取最近的错误日志..."
  journalctl -u "$SERVICE_NAME" -n 20 --no-pager || true
  exit 1
fi
