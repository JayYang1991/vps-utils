#!/usr/bin/env bash
# shellcheck disable=SC2268
#
# sing-box Server Installation Script
# Reference: https://sing-box.sagernet.org/
#
# Environment Variables:
#   SINGBOX_VERSION      - sing-box version to install (default: 1.12.20)
#   SINGBOX_DOMAIN       - Reality SNI Server Name (default: dl.google.com)
#   SINGBOX_UUID         - Client UUID (default: auto-generated)
#   SINGBOX_SHORT_ID     - Reality short ID (default: auto-generated)
#   SINGBOX_LOG_LEVEL    - Log level (default: warning)
#   SINGBOX_SOCKS_PORT   - SOCKS5 inbound port (default: 10086)
#   SINGBOX_SOCKS_USER   - SOCKS5 auth username (default: auto-generated)
#   SINGBOX_SOCKS_PASS   - SOCKS5 auth password (default: auto-generated)
#   SINGBOX_WS_PATH      - VLESS WS transport path (default: /singbox-ws-path)
#   SINGBOX_WS_HOST      - VLESS WS transport host header (default: proxy.19910417.xyz)
#   SOCKS_OUT_SERVER     - SOCKS outbound target server (default: 127.0.0.1)
#   SOCKS_OUT_PORT       - SOCKS outbound target port (default: 2080)
#
# ===================== Default Parameters =====================
SINGBOX_VERSION=${SINGBOX_VERSION:-${VERSION:-1.12.20}}
SINGBOX_DOMAIN=${SINGBOX_DOMAIN:-${DOMAIN:-dl.google.com}}
SINGBOX_UUID=${SINGBOX_UUID:-${UUID:-auto}}
SINGBOX_SHORT_ID=${SINGBOX_SHORT_ID:-${SHORT_ID:-auto}}
SINGBOX_LOG_LEVEL=${SINGBOX_LOG_LEVEL:-${LOG_LEVEL:-warning}}
SINGBOX_SOCKS_PORT=${SINGBOX_SOCKS_PORT:-${SOCKS_PORT:-10086}}
SINGBOX_SOCKS_USER=${SINGBOX_SOCKS_USER:-${SOCKS_USER:-auto}}
SINGBOX_SOCKS_PASS=${SINGBOX_SOCKS_PASS:-${SOCKS_PASS:-auto}}
SINGBOX_WS_PATH=${SINGBOX_WS_PATH:-${WS_PATH:-/singbox-ws-path}}
SINGBOX_WS_HOST=${SINGBOX_WS_HOST:-${WS_HOST:-proxy.19910417.xyz}}
SOCKS_OUT_SERVER=${SOCKS_OUT_SERVER:-127.0.0.1}
SOCKS_OUT_PORT=${SOCKS_OUT_PORT:-2080}
FORCE_INSTALL=false

# ===================== Color Output =====================
if [[ -t 1 ]] && [[ -n "$TERM" ]] && [[ "$TERM" != "dumb" ]] && command -v tput > /dev/null 2>&1; then
  red=$(tput setaf 1 2> /dev/null || echo "")
  green=$(tput setaf 2 2> /dev/null || echo "")
  aoi=$(tput setaf 6 2> /dev/null || echo "")
  yellow=$(tput setaf 3 2> /dev/null || echo "")
  reset=$(tput sgr0 2> /dev/null || echo "")
else
  red=""
  green=""
  aoi=""
  yellow=""
  reset=""
fi

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")

# ===================== Download URLs =====================
SINGBOX_SERVER_TEMPLATE_URL="https://raw.githubusercontent.com/JayYang1991/vps-utils/main/fhs-install-singbox/singbox_server_config.json"

# ===================== Functions =====================

check_if_running_as_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "${red}error: 请使用 root 运行${reset}"
    exit 1
  fi
}

identify_the_operating_system_and_architecture() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS="$ID"
  else
    echo "${red}error: 无法检测操作系统${reset}"
    exit 1
  fi
}

install_dependencies() {
  echo "${aoi}info: 正在安装依赖...${reset}"

  if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    dpkg --configure -a || true
    apt update -y || true
    apt install -y curl gnupg ca-certificates uuid-runtime openssl python3
  elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]] || [[ "$OS" == "fedora" ]]; then
    dnf install -y curl gnupg2 ca-certificates util-linux openssl python3
  elif [[ "$OS" == "arch" ]]; then
    pacman -S --noconfirm --needed curl gnupg ca-certificates util-linux openssl python
  else
    echo "${red}error: 不支持的操作系统: $OS${reset}"
    exit 1
  fi
}

curl_cmd() {
  curl -L -q --retry 5 --retry-delay 10 --retry-max-time 60 "$@"
}

escape_sed_replacement() {
  echo "$1" | sed -e "s/[&|/]/\\&/g"
}

cleanup_temp() {
  if [[ -n "$TEMPLATE_DIR" ]] && [[ -d "$TEMPLATE_DIR" ]]; then
    rm -rf "$TEMPLATE_DIR"
  fi
}

install_singbox() {
  echo "${aoi}info: 正在安装 sing-box (版本: ${SINGBOX_VERSION})...${reset}"

  if curl -fsSL https://sing-box.app/install.sh | sh -s -- --version "${SINGBOX_VERSION}"; then
    local installed_version
    installed_version=$(sing-box version 2> /dev/null | head -n1 || echo "unknown")
    echo "${green}info: sing-box 已安装: $installed_version${reset}"
  else
    echo "${red}error: 安装 sing-box 失败${reset}"
    exit 1
  fi

  if ! command -v sing-box > /dev/null 2>&1; then
    echo "${red}error: sing-box 命令未找到${reset}"
    exit 1
  fi
}

uninstall_singbox() {
  echo "${aoi}info: 正在执行强制卸载...${reset}"

  if systemctl is-active --quiet sing-box; then
    echo "${aoi}info: 正在停止 sing-box 服务...${reset}"
    systemctl stop sing-box || true
  fi

  if systemctl is-enabled --quiet sing-box; then
    echo "${aoi}info: 正在禁用 sing-box 服务...${reset}"
    systemctl disable sing-box || true
  fi

  echo "${aoi}info: 正在清理二进制文件和配置...${reset}"
  rm -f /usr/local/bin/sing-box || true
  rm -f /etc/systemd/system/sing-box.service || true
  systemctl daemon-reload || true
  
  echo "${green}info: 卸载完成${reset}"
}

download_templates() {
  echo "${aoi}info: 正在获取配置模板...${reset}"

  TEMPLATE_DIR=$(mktemp -d)

  if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/singbox_server_config.json" ]]; then
    echo "${aoi}info: 使用本地服务端模板: ${SCRIPT_DIR}/singbox_server_config.json${reset}"
    cp "${SCRIPT_DIR}/singbox_server_config.json" "${TEMPLATE_DIR}/singbox_server_config.json"
  elif curl_cmd -R -H "Cache-Control: no-cache" -o "${TEMPLATE_DIR}/singbox_server_config.json" "$SINGBOX_SERVER_TEMPLATE_URL"; then
    echo "${green}info: 服务端模板下载成功${reset}"
  else
    echo "${red}error: 获取服务端模板失败${reset}"
    exit 1
  fi
}

generate_keys() {
  echo "${aoi}info: 正在生成密钥与用户凭据...${reset}"

  if [[ "$UUID" == "auto" || -z "$UUID" ]]; then
    if command -v uuidgen > /dev/null 2>&1; then
      UUID=$(uuidgen)
    else
      UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
    fi
    if [[ -z "$UUID" ]]; then
      echo "${red}error: 生成 UUID 失败${reset}"
      exit 1
    fi
  fi

  if ! KEY_OUTPUT=$(sing-box generate reality-keypair 2>&1); then
    echo "${red}error: 生成 Reality 密钥失败${reset}"
    exit 1
  fi

  PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk '/PrivateKey/ {print $2}')
  PUBLIC_KEY=$(echo "$KEY_OUTPUT" | awk '/PublicKey/ {print $2}')

  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    echo "${red}error: 解析密钥失败${reset}"
    exit 1
  fi

  if [[ "$SHORT_ID" == "auto" || -z "$SHORT_ID" ]]; then
    SHORT_ID=$(openssl rand -hex 4)
    if [[ -z "$SHORT_ID" ]]; then
      echo "${red}error: 生成 Short ID 失败${reset}"
      exit 1
    fi
  fi

  if [[ "$SOCKS_USER" == "auto" || -z "$SOCKS_USER" ]]; then
    SOCKS_USER="user_$(openssl rand -hex 3)"
  fi

  if [[ "$SOCKS_PASS" == "auto" || -z "$SOCKS_PASS" ]]; then
    SOCKS_PASS=$(openssl rand -hex 8)
  fi
}

validate_runtime_parameters() {
  if ! [[ "$SOCKS_PORT" =~ ^[0-9]+$ ]] || ((SOCKS_PORT < 1)) || ((SOCKS_PORT > 65535)); then
    echo "${red}error: SOCKS 端口无效: $SOCKS_PORT${reset}"
    exit 1
  fi

  if ! [[ "$SOCKS_OUT_PORT" =~ ^[0-9]+$ ]] || ((SOCKS_OUT_PORT < 1)) || ((SOCKS_OUT_PORT > 65535)); then
    echo "${red}error: SOCKS 出站端口无效: $SOCKS_OUT_PORT${reset}"
    exit 1
  fi
}

write_config() {
  echo "${aoi}info: 正在写入配置文件...${reset}"

  local server_template
  local server_config_path="/etc/sing-box/config.json"

  server_template="${TEMPLATE_DIR}/singbox_server_config.json"

  if [[ ! -f "$server_template" ]]; then
    echo "${red}error: 未找到服务端模板: $server_template${reset}"
    exit 1
  fi

  mkdir -p /etc/sing-box || {
    echo "${red}error: 创建配置目录失败${reset}"
    exit 1
  }

  if ! sed     -e "s|{SINGBOX_LOG_LEVEL}|$(escape_sed_replacement "${LOG_LEVEL}")|g"     -e "s|"{SINGBOX_SOCKS_PORT}"|${SOCKS_PORT}|g"     -e "s|{SINGBOX_SOCKS_PORT}|${SOCKS_PORT}|g"     -e "s|{SINGBOX_SOCKS_USER}|$(escape_sed_replacement "${SOCKS_USER}")|g"     -e "s|{SINGBOX_SOCKS_PASS}|$(escape_sed_replacement "${SOCKS_PASS}")|g"     -e "s|{SINGBOX_UUID}|$(escape_sed_replacement "${UUID}")|g"     -e "s|{SINGBOX_DOMAIN}|$(escape_sed_replacement "${DOMAIN}")|g"     -e "s|{SINGBOX_PRIVATE_KEY}|$(escape_sed_replacement "${PRIVATE_KEY}")|g"     -e "s|{SINGBOX_SHORT_ID}|$(escape_sed_replacement "${SHORT_ID}")|g"     -e "s|{SINGBOX_WS_PATH}|$(escape_sed_replacement "${WS_PATH}")|g"     -e "s|{SINGBOX_WS_HOST}|$(escape_sed_replacement "${WS_HOST}")|g"     -e "s|{SOCKS_OUT_SERVER}|$(escape_sed_replacement "${SOCKS_OUT_SERVER}")|g"     -e "s|"{SOCKS_OUT_PORT}"|${SOCKS_OUT_PORT}|g"     -e "s|{SOCKS_OUT_PORT}|${SOCKS_OUT_PORT}|g"     "$server_template" > "$server_config_path"; then
    echo "${red}error: 写入配置文件失败${reset}"
    exit 1
  fi

  local check_err
  if ! check_err=$(sing-box check -c "$server_config_path" 2>&1); then
    echo "${red}error: 配置文件验证失败:${reset}"
    echo "$check_err"
    exit 1
  fi

  echo "${green}info: 配置文件验证通过${reset}"
}

configure_firewall() {
  echo "${aoi}info: 正在配置防火墙...${reset}"

  local tcp_ports=(443 8443 "${SOCKS_PORT}" 8088)

  if command -v ufw > /dev/null 2>&1; then
    for p in "${tcp_ports[@]}"; do ufw allow "${p}/tcp" || true; done
  elif command -v firewall-cmd > /dev/null 2>&1; then
    for p in "${tcp_ports[@]}"; do firewall-cmd --permanent --add-port="${p}/tcp" || true; done
    firewall-cmd --reload || true
  fi
}

start_service() {
  echo "${aoi}info: 正在启动 sing-box 服务...${reset}"

  if ! systemctl enable sing-box; then
    echo "${red}error: 启用 sing-box 服务失败${reset}"
    exit 1
  fi

  if ! systemctl restart sing-box; then
    echo "${red}error: 启动 sing-box 服务失败${reset}"
    systemctl status sing-box --no-pager
    journalctl -u sing-box -n 20 --no-pager
    exit 1
  fi

  sleep 2

  if ! systemctl is-active --quiet sing-box; then
    echo "${red}error: sing-box 服务未运行${reset}"
    systemctl status sing-box --no-pager
    journalctl -u sing-box -n 20 --no-pager
    exit 1
  fi

  echo "${green}info: sing-box 服务已启动${reset}"
}

print_info() {
  local ip
  ip=$(curl -s4 --connect-timeout 3 https://api.ipify.org 2>/dev/null || curl -s4 --connect-timeout 3 https://ifconfig.me 2>/dev/null || echo "YOUR_SERVER_IP")

  echo ""
  echo "${green}================================================================${reset}"
  echo "${green}            sing-box 服务端自动化部署成功！                     ${reset}"
  echo "${green}================================================================${reset}"
  echo "配置文件: /etc/sing-box/config.json"
  echo "服务器 IP: ${ip}"
  echo ""
  echo "${aoi}【节点 1：VLESS Reality (链式路由至本地 2080 住宅 IP 出口)】${reset}"
  echo "  - 监听端口 : 443 (TCP)"
  echo "  - 用户 UUID: ${UUID}"
  echo "  - Flow    : xtls-rprx-vision"
  echo "  - SNI 域名 : ${DOMAIN}"
  echo "  - 公钥 (PBK): ${PUBLIC_KEY}"
  echo "  - Short ID: ${SHORT_ID}"
  echo "  - 路由出口 : socks-2028 (${SOCKS_OUT_SERVER}:${SOCKS_OUT_PORT})"
  echo ""
  echo "${aoi}【节点 2：VLESS Reality (VPS 原生 IP 直连出口)】${reset}"
  echo "  - 监听端口 : 8443 (TCP)"
  echo "  - 用户 UUID: ${UUID}"
  echo "  - Flow    : xtls-rprx-vision"
  echo "  - SNI 域名 : ${DOMAIN}"
  echo "  - 公钥 (PBK): ${PUBLIC_KEY}"
  echo "  - Short ID: ${SHORT_ID}"
  echo "  - 路由出口 : direct (直连 VPS 原生网络)"
  echo ""
  echo "${aoi}【节点 3：SOCKS5 入站代理 (带账号密码认证)】${reset}"
  echo "  - 监听端口 : ${SOCKS_PORT} (TCP/UDP)"
  echo "  - 用户名   : ${SOCKS_USER}"
  echo "  - 密码     : ${SOCKS_PASS}"
  echo "  - 路由出口 : direct"
  echo ""
  echo "${aoi}【节点 4：VLESS WS/gRPC (Cloudflare Tunnel 优选穿透)】${reset}"
  echo "  - 本地监听 : 127.0.0.1:8088"
  echo "  - 用户 UUID: ${UUID}"
  echo "  - WS Path : ${WS_PATH}"
  echo "  - Host    : ${WS_HOST}"
  echo "${green}================================================================${reset}"
  echo ""
}

show_help() {
  echo "用法: $0 [选项]"
  echo ""
  echo "选项:"
  echo "  -v, --version VERSION        sing-box 安装版本 (默认: 1.12.20)"
  echo "  --domain DOMAIN              Reality 目标 SNI 伪装域名 (默认: dl.google.com)"
  echo "  --uuid UUID                  VLESS 用户 UUID (默认: 自动生成)"
  echo "  --short-id SHORT_ID          Reality Short ID (默认: 自动生成)"
  echo "  --log-level LEVEL            日志级别: debug, info, warning, error (默认: warning)"
  echo "  --socks-port PORT            SOCKS5 入站监听端口 (默认: 10086)"
  echo "  --socks-user USER            SOCKS5 认证用户名 (默认: 自动生成)"
  echo "  --socks-pass PASS            SOCKS5 认证密码 (默认: 自动生成)"
  echo "  --ws-path PATH               VLESS WS 传输路径 (默认: /singbox-ws-path)"
  echo "  --ws-host HOST               VLESS WS 头部 Host (默认: proxy.19910417.xyz)"
  echo "  --socks-out-server IP        SOCKS 出站代理目标 IP (默认: 127.0.0.1)"
  echo "  --socks-out-port PORT        SOCKS 出站代理目标端口 (默认: 2080)"
  echo "  -f, --force                  强制清理现有 sing-box 服务与配置后重装"
  echo "  -h, --help                   显示本帮助信息"
}

# ===================== Parse Arguments =====================
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version)
      SINGBOX_VERSION="$2"
      shift 2
      ;;
    --domain)
      SINGBOX_DOMAIN="$2"
      shift 2
      ;;
    --uuid)
      SINGBOX_UUID="$2"
      shift 2
      ;;
    --short-id)
      SINGBOX_SHORT_ID="$2"
      shift 2
      ;;
    --log-level)
      SINGBOX_LOG_LEVEL="$2"
      shift 2
      ;;
    --socks-port)
      SINGBOX_SOCKS_PORT="$2"
      shift 2
      ;;
    --socks-user)
      SINGBOX_SOCKS_USER="$2"
      shift 2
      ;;
    --socks-pass)
      SINGBOX_SOCKS_PASS="$2"
      shift 2
      ;;
    --ws-path)
      SINGBOX_WS_PATH="$2"
      shift 2
      ;;
    --ws-host)
      SINGBOX_WS_HOST="$2"
      shift 2
      ;;
    --socks-out-server)
      SOCKS_OUT_SERVER="$2"
      shift 2
      ;;
    --socks-out-port)
      SOCKS_OUT_PORT="$2"
      shift 2
      ;;
    -f|--force)
      FORCE_INSTALL=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "${red}error: 未知参数: $1${reset}"
      show_help
      exit 1
      ;;
  esac
done

# ===================== Main Function =====================
main() {
  VERSION="$SINGBOX_VERSION"
  DOMAIN="$SINGBOX_DOMAIN"
  UUID="$SINGBOX_UUID"
  SHORT_ID="$SINGBOX_SHORT_ID"
  LOG_LEVEL="$SINGBOX_LOG_LEVEL"
  SOCKS_PORT="$SINGBOX_SOCKS_PORT"
  SOCKS_USER="$SINGBOX_SOCKS_USER"
  SOCKS_PASS="$SINGBOX_SOCKS_PASS"
  WS_PATH="$SINGBOX_WS_PATH"
  WS_HOST="$SINGBOX_WS_HOST"

  trap cleanup_temp EXIT

  echo "${aoi}▶ sing-box Server 自动安装开始${reset}"
  echo "版本: $VERSION"
  echo "SNI 域名: $DOMAIN"
  echo "SOCKS5 端口: $SOCKS_PORT"
  echo "SOCKS 出站: ${SOCKS_OUT_SERVER}:${SOCKS_OUT_PORT}"
  echo "WS Path: $WS_PATH"
  echo ""

  validate_runtime_parameters
  check_if_running_as_root
  identify_the_operating_system_and_architecture
  install_dependencies

  if [[ "$FORCE_INSTALL" == "true" ]]; then
    uninstall_singbox
  fi

  install_singbox
  download_templates
  generate_keys
  write_config
  configure_firewall
  start_service
  print_info
}

main "$@"
