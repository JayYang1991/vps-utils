#!/usr/bin/env bash
# shellcheck disable=SC2268
#
# sing-box Server Installation Script
# Reference: https://sing-box.sagernet.org/
#
# Environment Variables:
#   SINGBOX_PORT      - Listening port (default: 443)
#   SINGBOX_DOMAIN    - Server Name Indication (default: www.cloudflare.com)
#   SINGBOX_UUID      - Client UUID (default: auto-generated)
#   SINGBOX_SHORT_ID  - Reality short ID (default: auto-generated)
#   SINGBOX_LOG_LEVEL - Log level (default: info)
#   SINGBOX_HY2_PORT       - Hysteria2 listen port (default: 123)
#   SINGBOX_HY2_DOMAIN     - Hysteria2 TLS server name (default: hy2.jayyang.cn)
#   SINGBOX_HY2_PASSWORD   - Hysteria2 password (default: auto-generated)
#   SINGBOX_HY2_UP_MBPS    - Hysteria2 uplink Mbps (default: 200)
#   SINGBOX_HY2_DOWN_MBPS  - Hysteria2 downlink Mbps (default: 200)
#   SINGBOX_HY2_MASQUERADE - Hysteria2 masquerade URL (default: https://www.cloudflare.com)
#
# ===================== Default Parameters =====================
SINGBOX_PORT=${SINGBOX_PORT:-${PORT:-443}}
SINGBOX_DOMAIN=${SINGBOX_DOMAIN:-${DOMAIN:-www.cloudflare.com}}
SINGBOX_UUID=${SINGBOX_UUID:-${UUID:-auto}}
SINGBOX_SHORT_ID=${SINGBOX_SHORT_ID:-${SHORT_ID:-auto}}
SINGBOX_LOG_LEVEL=${SINGBOX_LOG_LEVEL:-${LOG_LEVEL:-info}}
SINGBOX_HY2_PORT=${SINGBOX_HY2_PORT:-${HY2_PORT:-123}}
SINGBOX_HY2_DOMAIN=${SINGBOX_HY2_DOMAIN:-${HY2_DOMAIN:-hy2.jayyang.cn}}
SINGBOX_HY2_PASSWORD=${SINGBOX_HY2_PASSWORD:-${HY2_PASSWORD:-auto}}
SINGBOX_HY2_UP_MBPS=${SINGBOX_HY2_UP_MBPS:-${HY2_UP_MBPS:-200}}
SINGBOX_HY2_DOWN_MBPS=${SINGBOX_HY2_DOWN_MBPS:-${HY2_DOWN_MBPS:-200}}
SINGBOX_HY2_MASQUERADE=${SINGBOX_HY2_MASQUERADE:-${HY2_MASQUERADE:-https://www.cloudflare.com}}
SINGBOX_HY2_CERT_PATH="/etc/cert/hy2_cert.pem"
SINGBOX_HY2_KEY_PATH="/etc/cert/hy2_key.pem"
FORCE_INSTALL=false

# ===================== Color Output =====================
# Initialize color variables safely before set -e
if [[ -t 1 ]] && [[ -n "$TERM" ]] && [[ "$TERM" != "dumb" ]] && command -v tput > /dev/null 2>&1; then
  red=$(tput setaf 1 2> /dev/null || echo "")
  green=$(tput setaf 2 2> /dev/null || echo "")
  aoi=$(tput setaf 6 2> /dev/null || echo "")
  reset=$(tput sgr0 2> /dev/null || echo "")
else
  red=""
  green=""
  aoi=""
  reset=""
fi

set -e

# ===================== Download URLs =====================
SINGBOX_SERVER_TEMPLATE_URL="https://raw.githubusercontent.com/JayYang1991/fhs-install-v2ray/master/singbox_server_config.json"
SINGBOX_CLIENT_TEMPLATE_URL="https://raw.githubusercontent.com/JayYang1991/fhs-install-v2ray/master/singbox_client_config.json"

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
    apt install -y curl gnupg ca-certificates uuid-runtime openssl
  elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]] || [[ "$OS" == "fedora" ]]; then
    dnf install -y curl gnupg2 ca-certificates util-linux openssl
  elif [[ "$OS" == "arch" ]]; then
    pacman -S --noconfirm --needed curl gnupg ca-certificates util-linux openssl
  else
    echo "${red}error: 不支持的操作系统: $OS${reset}"
    exit 1
  fi
}

curl() {
  $(type -P curl) -L -q --retry 5 --retry-delay 10 --retry-max-time 60 "$@"
}

escape_sed_replacement() {
  echo "$1" | sed -e 's/[&|/]/\\&/g'
}

cleanup_temp() {
  if [[ -n "$TEMPLATE_DIR" ]] && [[ -d "$TEMPLATE_DIR" ]]; then
    "rm" -r "$TEMPLATE_DIR"
  fi
}

install_singbox() {
  echo "${aoi}info: 正在安装 sing-box...${reset}"

  if curl -fsSL https://sing-box.app/install.sh | sh; then
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
  
  # 注意：这里我们保留 /etc/sing-box 目录，安装过程中会自动覆盖其中的 config.json
  # 但会清理旧的验证通过标志等
  echo "${green}info: 卸载完成${reset}"
}

download_templates() {
  echo "${aoi}info: 正在下载配置模板...${reset}"

  TEMPLATE_DIR=$(mktemp -d)

  if ! curl -R -H 'Cache-Control: no-cache' -o "${TEMPLATE_DIR}/singbox_server_config.json" "$SINGBOX_SERVER_TEMPLATE_URL"; then
    echo "${red}error: 下载服务端模板失败: $SINGBOX_SERVER_TEMPLATE_URL${reset}"
    exit 1
  fi

  if ! curl -R -H 'Cache-Control: no-cache' -o "${TEMPLATE_DIR}/singbox_client_config.json" "$SINGBOX_CLIENT_TEMPLATE_URL"; then
    echo "${red}error: 下载客户端模板失败: $SINGBOX_CLIENT_TEMPLATE_URL${reset}"
    exit 1
  fi
}

generate_keys() {
  echo "${aoi}info: 正在生成密钥...${reset}"

  if [[ "$UUID" == "auto" ]]; then
    UUID=$(uuidgen)
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

  if [[ -z "$PRIVATE_KEY" ]] || [[ -z "$PUBLIC_KEY" ]]; then
    echo "${red}error: 解析密钥失败${reset}"
    exit 1
  fi

  if [[ "$SHORT_ID" == "auto" ]]; then
    SHORT_ID=$(openssl rand -hex 4)
    if [[ -z "$SHORT_ID" ]]; then
      echo "${red}error: 生成 Short ID 失败${reset}"
      exit 1
    fi
  fi

  if [[ "$HY2_PASSWORD" == "auto" ]]; then
    HY2_PASSWORD=$(openssl rand -hex 16)
    if [[ -z "$HY2_PASSWORD" ]]; then
      echo "${red}error: 生成 Hysteria2 密码失败${reset}"
      exit 1
    fi
  fi
}

validate_runtime_parameters() {
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1)) || ((PORT > 65535)); then
    echo "${red}error: 端口无效: $PORT${reset}"
    exit 1
  fi

  if ! [[ "$HY2_PORT" =~ ^[0-9]+$ ]] || ((HY2_PORT < 1)) || ((HY2_PORT > 65535)); then
    echo "${red}error: HY2 端口无效: $HY2_PORT${reset}"
    exit 1
  fi

  if ! [[ "$HY2_UP_MBPS" =~ ^[0-9]+$ ]] || ((HY2_UP_MBPS < 1)); then
    echo "${red}error: HY2_UP_MBPS 无效: $HY2_UP_MBPS${reset}"
    exit 1
  fi

  if ! [[ "$HY2_DOWN_MBPS" =~ ^[0-9]+$ ]] || ((HY2_DOWN_MBPS < 1)); then
    echo "${red}error: HY2_DOWN_MBPS 无效: $HY2_DOWN_MBPS${reset}"
    exit 1
  fi
}

ensure_hy2_certificates() {
  local cert_dir="/etc/cert"
  local cert_path="$SINGBOX_HY2_CERT_PATH"
  local key_path="$SINGBOX_HY2_KEY_PATH"

  if ! mkdir -p "$cert_dir"; then
    echo "${red}error: 创建证书目录失败: $cert_dir${reset}"
    exit 1
  fi

  if [[ -f "$cert_path" ]] && [[ -f "$key_path" ]]; then
    echo "${green}info: 已检测到 Hysteria2 证书: $cert_path${reset}"
    return
  fi

  echo "${aoi}info: 正在生成 Hysteria2 自签名证书...${reset}"
  if ! openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
    -days 3650 \
    -subj "/CN=${HY2_DOMAIN}" \
    -addext "subjectAltName=DNS:${HY2_DOMAIN}" \
    -keyout "$key_path" \
    -out "$cert_path" > /dev/null 2>&1; then
    echo "${red}error: 生成 Hysteria2 证书失败${reset}"
    exit 1
  fi

  chmod 600 "$key_path" || true
  chmod 644 "$cert_path" || true
  echo "${green}info: Hysteria2 证书已生成: $cert_path${reset}"
}

write_config() {
  echo "${aoi}info: 正在写入配置文件...${reset}"

  local server_template
  local client_template
  local server_ip
  local server_config_path="/etc/sing-box/config.json"
  local client_config_path

  server_template="${TEMPLATE_DIR}/singbox_server_config.json"
  client_template="${TEMPLATE_DIR}/singbox_client_config.json"

  if [[ ! -f "$server_template" ]]; then
    echo "${red}error: 未找到服务端模板: $server_template${reset}"
    exit 1
  fi

  if [[ ! -f "$client_template" ]]; then
    echo "${red}error: 未找到客户端模板: $client_template${reset}"
    exit 1
  fi

  mkdir -p /etc/sing-box || {
    echo "${red}error: 创建配置目录失败${reset}"
    exit 1
  }

  if ! sed \
    -e "s|{SINGBOX_LOG_LEVEL}|$(escape_sed_replacement "${LOG_LEVEL}")|g" \
    -e "s|\"{SINGBOX_PORT}\"|${PORT}|g" \
    -e "s|{SINGBOX_PORT}|${PORT}|g" \
    -e "s|\"listen_port\"[[:space:]]*:[[:space:]]*\"${PORT}\"|\"listen_port\": ${PORT}|g" \
    -e "s|{SINGBOX_UUID}|$(escape_sed_replacement "${UUID}")|g" \
    -e "s|{SINGBOX_DOMAIN}|$(escape_sed_replacement "${DOMAIN}")|g" \
    -e "s|{SINGBOX_PRIVATE_KEY}|$(escape_sed_replacement "${PRIVATE_KEY}")|g" \
    -e "s|{SINGBOX_SHORT_ID}|$(escape_sed_replacement "${SHORT_ID}")|g" \
    -e "s|\"{SINGBOX_HY2_PORT}\"|${HY2_PORT}|g" \
    -e "s|{SINGBOX_HY2_PORT}|${HY2_PORT}|g" \
    -e "s|\"up_mbps\"[[:space:]]*:[[:space:]]*\"{SINGBOX_HY2_UP_MBPS}\"|\"up_mbps\": ${HY2_UP_MBPS}|g" \
    -e "s|\"down_mbps\"[[:space:]]*:[[:space:]]*\"{SINGBOX_HY2_DOWN_MBPS}\"|\"down_mbps\": ${HY2_DOWN_MBPS}|g" \
    -e "s|{SINGBOX_HY2_PASSWORD}|$(escape_sed_replacement "${HY2_PASSWORD}")|g" \
    -e "s|{SINGBOX_HY2_UP_MBPS}|${HY2_UP_MBPS}|g" \
    -e "s|{SINGBOX_HY2_DOWN_MBPS}|${HY2_DOWN_MBPS}|g" \
    -e "s|{SINGBOX_HY2_DOMAIN}|$(escape_sed_replacement "${HY2_DOMAIN}")|g" \
    -e "s|{SINGBOX_HY2_CERT_PATH}|$(escape_sed_replacement "${SINGBOX_HY2_CERT_PATH}")|g" \
    -e "s|{SINGBOX_HY2_KEY_PATH}|$(escape_sed_replacement "${SINGBOX_HY2_KEY_PATH}")|g" \
    -e "s|{SINGBOX_HY2_MASQUERADE}|$(escape_sed_replacement "${HY2_MASQUERADE}")|g" \
    "$server_template" > "$server_config_path"; then
    echo "${red}error: 写入配置文件失败${reset}"
    exit 1
  fi

  if ! sing-box check -c "$server_config_path" 2> /dev/null; then
    echo "${red}error: 配置文件验证失败${reset}"
    exit 1
  fi

  echo "${green}info: 配置文件验证通过${reset}"

  server_ip=$(get_server_ip)
  if [[ -z "$server_ip" ]]; then
    echo "${red}error: 无法获取服务器 IP 地址${reset}"
    exit 1
  fi

  client_config_path=$(mktemp -p /tmp singbox_client_config.XXXXXX.json)
  if ! sed \
    -e "s|{SINGBOX_SERVER_IP}|$(escape_sed_replacement "${server_ip}")|g" \
    -e "s|\"{SINGBOX_PORT}\"|${PORT}|g" \
    -e "s|{SINGBOX_PORT}|${PORT}|g" \
    -e "s|\"server_port\"[[:space:]]*:[[:space:]]*\"${PORT}\"|\"server_port\": ${PORT}|g" \
    -e "s|{SINGBOX_UUID}|$(escape_sed_replacement "${UUID}")|g" \
    -e "s|{SINGBOX_DOMAIN}|$(escape_sed_replacement "${DOMAIN}")|g" \
    -e "s|{SINGBOX_PUBLIC_KEY}|$(escape_sed_replacement "${PUBLIC_KEY}")|g" \
    -e "s|{SINGBOX_SHORT_ID}|$(escape_sed_replacement "${SHORT_ID}")|g" \
    "$client_template" > "$client_config_path"; then
    echo "${red}error: 写入客户端配置文件失败${reset}"
    exit 1
  fi

  CLIENT_CONFIG_PATH="$client_config_path"
}

configure_firewall() {
  echo "${aoi}info: 正在配置防火墙...${reset}"

  if command -v ufw > /dev/null 2>&1; then
    ufw allow "${PORT}/tcp" || true
    ufw allow "${HY2_PORT}/udp" || true
  elif command -v firewall-cmd > /dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" || true
    firewall-cmd --permanent --add-port="${HY2_PORT}/udp" || true
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

get_server_ip() {
  local server_ip=""

  if command -v curl > /dev/null 2>&1; then
    server_ip=$(curl -s -4 ifconfig.me 2> /dev/null) ||
      server_ip=$(curl -s -4 icanhazip.com 2> /dev/null) ||
      server_ip=$(curl -s -4 ipecho.net/plain 2> /dev/null)
  fi

  if [[ -z "$server_ip" ]] && command -v wget > /dev/null 2>&1; then
    server_ip=$(wget -q -O - ifconfig.me 2> /dev/null) ||
      server_ip=$(wget -q -O - icanhazip.com 2> /dev/null)
  fi

  echo "$server_ip"
}

print_info() {
  if [[ -n "$CLIENT_CONFIG_PATH" ]]; then
    echo "客户端配置文件: $CLIENT_CONFIG_PATH"
  else
    echo "${red}error: 未生成客户端配置文件${reset}"
    exit 1
  fi
}

# ===================== Parse Arguments =====================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      SINGBOX_PORT="$2"
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
    --hy2-port)
      SINGBOX_HY2_PORT="$2"
      shift 2
      ;;
    --hy2-domain)
      SINGBOX_HY2_DOMAIN="$2"
      shift 2
      ;;
    --hy2-password)
      SINGBOX_HY2_PASSWORD="$2"
      shift 2
      ;;
    --hy2-up-mbps)
      SINGBOX_HY2_UP_MBPS="$2"
      shift 2
      ;;
    --hy2-down-mbps)
      SINGBOX_HY2_DOWN_MBPS="$2"
      shift 2
      ;;
    --hy2-masquerade)
      SINGBOX_HY2_MASQUERADE="$2"
      shift 2
      ;;
    -f|--force)
      FORCE_INSTALL=true
      shift
      ;;
    *)
      echo "${red}error: 未知参数: $1${reset}"
      exit 1
      ;;
  esac
done

# ===================== Main Function =====================
main() {
  PORT="$SINGBOX_PORT"
  DOMAIN="$SINGBOX_DOMAIN"
  UUID="$SINGBOX_UUID"
  SHORT_ID="$SINGBOX_SHORT_ID"
  LOG_LEVEL="$SINGBOX_LOG_LEVEL"
  HY2_PORT="$SINGBOX_HY2_PORT"
  HY2_DOMAIN="$SINGBOX_HY2_DOMAIN"
  HY2_PASSWORD="$SINGBOX_HY2_PASSWORD"
  HY2_UP_MBPS="$SINGBOX_HY2_UP_MBPS"
  HY2_DOWN_MBPS="$SINGBOX_HY2_DOWN_MBPS"
  HY2_MASQUERADE="$SINGBOX_HY2_MASQUERADE"

  trap cleanup_temp EXIT

  echo "${aoi}▶ sing-box Server 自动安装开始${reset}"
  echo "端口: $PORT"
  echo "SNI: $DOMAIN"
  echo "HY2 端口: $HY2_PORT"
  echo "HY2 域名: $HY2_DOMAIN"
  echo ""

  validate_runtime_parameters
  check_if_running_as_root
  identify_the_operating_system_and_architecture

  if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
    apt update
  elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]] || [[ "$OS" == "fedora" ]]; then
    dnf check-update || true
  elif [[ "$OS" == "arch" ]]; then
    pacman -Sy --noconfirm
  fi

  install_dependencies

  if [[ "$FORCE_INSTALL" == "true" ]]; then
    uninstall_singbox
  fi

  install_singbox
  download_templates
  generate_keys
  ensure_hy2_certificates
  write_config
  configure_firewall
  start_service
  print_info
}

main "$@"
