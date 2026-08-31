#!/usr/bin/env bash
# ==============================================================================
# VPS Utils - 综合运维管理与一键安装脚本
# 支持按角色 (目标VPS / 中转VPS / Client端) 一键部署所需组件与全生命周期管理
#
# GitHub: https://github.com/JayYang1991/vps-utils
# ==============================================================================

set -eo pipefail

# ===================== 颜色与样式定义 =====================
if [[ -t 1 ]] && [[ -n "$TERM" ]] && [[ "$TERM" != "dumb" ]] && command -v tput > /dev/null 2>&1; then
  RED=$(tput setaf 1 2> /dev/null || echo "")
  GREEN=$(tput setaf 2 2> /dev/null || echo "")
  YELLOW=$(tput setaf 3 2> /dev/null || echo "")
  BLUE=$(tput setaf 4 2> /dev/null || echo "")
  PURPLE=$(tput setaf 5 2> /dev/null || echo "")
  CYAN=$(tput setaf 6 2> /dev/null || echo "")
  BOLD=$(tput bold 2> /dev/null || echo "")
  NC=$(tput sgr0 2> /dev/null || echo "")
else
  RED='[0;31m'
  GREEN='[0;32m'
  YELLOW='[0;33m'
  BLUE='[0;34m'
  PURPLE='[0;35m'
  CYAN='[0;36m'
  BOLD='[1m'
  NC='[0m'
fi

# ===================== 日志辅助函数 =====================
log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()    { echo -e "${CYAN}${BOLD}>>> $1${NC}"; }
log_success() { echo -e "${GREEN}${BOLD}✔ $1${NC}"; }

# ===================== 基础路径与环境定位 =====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
GLOBAL_INSTALL_DIR="/usr/local/share/vps-utils"
BIN_DIR="/usr/local/bin"
CLI_BIN="${BIN_DIR}/vps-utils"
CLI_ALIAS="${BIN_DIR}/vps-manager"
REPO_URL="https://github.com/JayYang1991/vps-utils.git"

# 全局参数默认值
ROLE=""
PACKAGE_TYPE="standard"
SINGLE_COMPONENT=""
ACTION="menu"
SERVICE_ACTION=""
ASSUME_YES=false

# 组件通用配置入参 (优先继承系统预设的环境变量)
INPUT_TOKEN="${TUNNEL_TOKEN:-${CF_TUNNEL_TOKEN:-${TOKEN:-${WARP_TEAM_NAME:-${CF_TEAM_NAME:-${TEAM_NAME:-${TEAM:-}}}}}}}"
INPUT_SUB_URL="${SUB_URL:-${SINGBOX_SUB_URL:-${UPSTREAM_SUB_URL:-}}}"
INPUT_SERVICE_TOKEN_ID="${CF_SERVICE_TOKEN_ID:-${CF_ACCESS_CLIENT_ID:-${SERVICE_TOKEN_ID:-}}}"
INPUT_SERVICE_TOKEN_SECRET="${CF_SERVICE_TOKEN_SECRET:-${CF_ACCESS_CLIENT_SECRET:-${SERVICE_TOKEN_SECRET:-}}}"
INPUT_DOMAINS="${DOMAINS:-${CF_DOMAINS:-}}"
INPUT_PORTS="${PORTS:-${CF_PORTS:-}}"
INPUT_SERVER_IP="${SERVER_IP:-${SERVER_HOST:-}}"
INPUT_PROXY="${PROXY:-${PROXY_URL:-}}"
INPUT_COUNTRY="${COUNTRY:-${VPNGATE_COUNTRY:-JP}}"
INPUT_PORT="${PORT:-}"
INPUT_USERNAME="${USERNAME:-${ADMIN_USERNAME:-${SOCKS_USER:-}}}"
INPUT_PASSWORD="${PASSWORD:-${ADMIN_PASSWORD:-${SOCKS_PASS:-}}}"
INPUT_DOMAIN="${SINGBOX_DOMAIN:-${DOMAIN:-}}"
INPUT_UUID="${SINGBOX_UUID:-${UUID:-}}"
INPUT_SHORT_ID="${SINGBOX_SHORT_ID:-${SHORT_ID:-}}"
INPUT_WS_PATH="${SINGBOX_WS_PATH:-${WS_PATH:-}}"
INPUT_WS_HOST="${SINGBOX_WS_HOST:-${WS_HOST:-}}"
INPUT_TG_API_ID="${TG_API_ID:-}"
INPUT_TG_API_HASH="${TG_API_HASH:-}"
INPUT_CF_API_TOKEN="${CF_API_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"

# ===================== 权限与基础环境检查 =====================
check_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "此操作必须以 root 权限运行，请使用 'sudo bash $0' 或切换至 root 用户。"
    exit 1
  fi
}

# 检查当前是否在完整的 vps-utils 源码目录中
ensure_repo_environment() {
  if [[ -f "${SCRIPT_DIR}/fhs-install-singbox/install-singbox-server.sh" ]] && [[ -f "${SCRIPT_DIR}/cloudflared-tunnel/install.sh" ]]; then
    PROJECT_ROOT="${SCRIPT_DIR}"
  elif [[ -f "${GLOBAL_INSTALL_DIR}/fhs-install-singbox/install-singbox-server.sh" ]]; then
    PROJECT_ROOT="${GLOBAL_INSTALL_DIR}"
  else
    log_info "检测到当前未处于完整的 vps-utils 代码仓库中，正在下载完整源码包..."
    mkdir -p "${GLOBAL_INSTALL_DIR}"
    if command -v git &>/dev/null; then
      if [[ -d "${GLOBAL_INSTALL_DIR}/.git" ]]; then
        git -C "${GLOBAL_INSTALL_DIR}" pull --quiet || true
      else
        git clone --depth=1 "${REPO_URL}" "${GLOBAL_INSTALL_DIR}"
      fi
    else
      TMP_ARCHIVE=$(mktemp /tmp/vps-utils.XXXXXX.tar.gz)
      curl -fsSL "https://github.com/JayYang1991/vps-utils/archive/refs/heads/main.tar.gz" -o "${TMP_ARCHIVE}"
      tar -xzf "${TMP_ARCHIVE}" -C "/tmp"
      cp -rf /tmp/vps-utils-main/* "${GLOBAL_INSTALL_DIR}/" 2>/dev/null || cp -rf /tmp/vps-utils-*/* "${GLOBAL_INSTALL_DIR}/"
      rm -rf /tmp/vps-utils-* "${TMP_ARCHIVE}"
    fi
    PROJECT_ROOT="${GLOBAL_INSTALL_DIR}"
  fi

  # 若以 root 运行，自动注册系统全局 CLI 命令软链接
  if [[ $EUID -eq 0 ]] && [[ -n "${PROJECT_ROOT}" ]] && [[ -f "${PROJECT_ROOT}/install.sh" ]]; then
    mkdir -p "${BIN_DIR}"
    ln -sf "${PROJECT_ROOT}/install.sh" "${CLI_BIN}" 2>/dev/null || true
    ln -sf "${PROJECT_ROOT}/install.sh" "${CLI_ALIAS}" 2>/dev/null || true
    chmod +x "${PROJECT_ROOT}/install.sh" 2>/dev/null || true
  fi
}

detect_os_and_arch() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_NAME="${ID:-linux}"
    OS_VERSION="${VERSION_ID:-}"
  else
    OS_NAME="linux"
    OS_VERSION=""
  fi

  ARCH_RAW=$(uname -m)
  case "${ARCH_RAW}" in
    x86_64|amd64)   ARCH="amd64" ;;
    aarch64|arm64)  ARCH="arm64" ;;
    armv7*|armhf)   ARCH="arm" ;;
    *)              ARCH="${ARCH_RAW}" ;;
  esac

  PUBLIC_IPV4=$(curl -4 -s --max-time 3 https://api.ipify.org 2>/dev/null || curl -4 -s --max-time 3 https://ip.sb 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
}

install_base_dependencies() {
  if [[ $EUID -ne 0 ]]; then
    return 0
  fi
  log_info "检查并安装系统基础依赖 (curl, wget, jq, tar, python3, lsof, ca-certificates)..."
  if [[ "$OS_NAME" == "ubuntu" ]] || [[ "$OS_NAME" == "debian" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -q > /dev/null 2>&1 || true
    apt-get install -y -q curl wget jq tar gzip unzip git python3 python3-pip python3-venv lsof ca-certificates net-tools > /dev/null 2>&1 || true
  elif [[ "$OS_NAME" == "centos" ]] || [[ "$OS_NAME" == "rhel" ]] || [[ "$OS_NAME" == "fedora" ]] || [[ "$OS_NAME" == "almalinux" ]] || [[ "$OS_NAME" == "rocky" ]]; then
    yum install -y -q curl wget jq tar gzip unzip git python3 python3-pip lsof ca-certificates net-tools > /dev/null 2>&1 || true
  elif [[ "$OS_NAME" == "arch" ]] || [[ "$OS_NAME" == "manjaro" ]]; then
    pacman -Sy --noconfirm --needed curl wget jq tar gzip unzip git python python-pip lsof ca-certificates net-tools > /dev/null 2>&1 || true
  fi
}

ensure_docker() {
  if command -v docker &>/dev/null; then
    if ! systemctl is-active --quiet docker 2>/dev/null; then
      systemctl start docker 2>/dev/null || true
    fi
    return 0
  fi

  log_warn "检测到当前系统尚未安装 Docker，部分容器化组件需要 Docker 支持。"
  if [[ "$ASSUME_YES" == "true" ]]; then
    INSTALL_DOCKER="y"
  else
    read -r -p "是否立即自动安装官方 Docker 运行环境? [Y/n] " INSTALL_DOCKER
    INSTALL_DOCKER="${INSTALL_DOCKER:-y}"
  fi

  if [[ "$INSTALL_DOCKER" =~ ^[Yy]$ ]]; then
    log_info "正在通过官方脚本安装 Docker..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable --now docker 2>/dev/null || true
    log_success "Docker 安装完成！"
  else
    log_warn "已跳过 Docker 安装。依赖 Docker 的组件将无法正常运行。"
  fi
}

# ===================== 组件注册表与状态探针 =====================

check_service_state() {
  local sname="$1"
  if ! systemctl list-unit-files "${sname}.service" 2>/dev/null | grep -q "${sname}.service" && [[ ! -f "/etc/systemd/system/${sname}.service" ]]; then
    echo "not_installed"
  elif systemctl is-active --quiet "$sname" 2>/dev/null; then
    echo "active"
  else
    echo "inactive"
  fi
}

check_container_state() {
  local cname="$1"
  if ! command -v docker &>/dev/null; then
    echo "not_installed"
    return
  fi
  local cstate
  cstate=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo "")
  if [[ "$cstate" == "running" ]]; then
    echo "active"
  elif [[ -n "$cstate" ]]; then
    echo "inactive"
  else
    echo "not_installed"
  fi
}

get_component_status() {
  local comp="$1"
  case "$comp" in
    singbox)
      if command -v sing-box &>/dev/null || [[ -f "/usr/local/bin/sing-box" ]]; then
        check_service_state "sing-box"
      else
        echo "not_installed"
      fi
      ;;
    tunnel)
      if command -v cloudflared &>/dev/null || [[ -f "/usr/local/bin/cloudflared" ]]; then
        check_service_state "cloudflared"
      else
        echo "not_installed"
      fi
      ;;
    subconverter)
      if [[ -f "/usr/local/subconverter/subconverter" ]] || [[ -f "/usr/local/bin/subconverter" ]]; then
        check_service_state "subconverter"
      else
        echo "not_installed"
      fi
      ;;
    singbox-sub-converter)
      if [[ -d "/usr/local/singbox-sub-converter" ]]; then
        check_service_state "singbox-sub-converter"
      else
        echo "not_installed"
      fi
      ;;
    clash-sub-manager)
      if [[ -d "/usr/local/bin/clash-singbox-sub-manager" ]] || [[ -f "/etc/systemd/system/clash-singbox-sub-manager.service" ]]; then
        check_service_state "clash-singbox-sub-manager"
      else
        echo "not_installed"
      fi
      ;;
    vpngate)
      if check_container_state "vpngate-singbox-openvpn" | grep -q "active"; then
        echo "active"
      elif [[ -f "/etc/systemd/system/vpngate-singbox-node-updater.service" ]] || [[ -d "/usr/local/bin/vpngate-singbox-openvpn" ]]; then
        check_service_state "vpngate-singbox-node-updater"
      else
        echo "not_installed"
      fi
      ;;
    cf-access-tcp)
      if check_container_state "cloudflare-access-tcp" | grep -q "active"; then
        echo "active"
      elif [[ -f "/etc/systemd/system/cloudflare-access-tcp.service" ]] || [[ -f "/usr/local/bin/cloudflare-access-tcp" ]]; then
        check_service_state "cloudflare-access-tcp"
      else
        echo "not_installed"
      fi
      ;;
    cf-warp)
      if check_container_state "cloudflare-warp-socks5" | grep -q "active"; then
        echo "active"
      elif check_service_state "warp-svc" | grep -q "active"; then
        echo "active"
      elif [[ -f "/etc/systemd/system/cloudflare-warp-socks5.service" ]]; then
        check_service_state "cloudflare-warp-socks5"
      elif [[ -f "/etc/systemd/system/warp-svc.service" ]]; then
        check_service_state "warp-svc"
      else
        echo "not_installed"
      fi
      ;;
    preferred-ip)
      if systemctl list-timers 2>/dev/null | grep -q "preferred-ip-updater.timer"; then
        if systemctl is-active --quiet preferred-ip-updater.timer 2>/dev/null; then
          echo "active"
        else
          echo "inactive"
        fi
      elif [[ -f "/etc/systemd/system/preferred-ip-updater.timer" ]]; then
        echo "inactive"
      else
        echo "not_installed"
      fi
      ;;
    *)
      echo "not_installed"
      ;;
  esac
}

# ===================== 单组件安装函数 =====================

install_component_singbox() {
  local target_mode="${1:-$PACKAGE_TYPE}"
  if [[ "$ROLE" == "client" ]]; then
    target_mode="client"
  fi

  if [[ "$target_mode" == "client" ]]; then
    log_step "正在以 [Client 客户端模式] 安装与配置 sing-box..."
    local installer="${PROJECT_ROOT}/fhs-install-singbox/install-singbox-server.sh"
    local sub_updater="${PROJECT_ROOT}/fhs-install-singbox/update-singbox-sub.sh"

    # 1. 确保 sing-box 二进制与系统服务已就绪
    if ! command -v sing-box &>/dev/null && [[ ! -f "/usr/local/bin/sing-box" ]]; then
      if [[ -f "$installer" ]]; then
        chmod +x "$installer"
        bash "$installer"
      fi
    fi

    # 2. 检查/拉取客户端订阅
    local sub_url="${INPUT_SUB_URL:-}"
    if [[ -z "$sub_url" ]] && [[ "$ASSUME_YES" != "true" ]]; then
      echo ""
      echo -e "${YELLOW}提示: Client 模式需要传入订阅链接以自动配置客户端入站、出站及路由分流规则。${NC}"
      read -r -p "请输入 sing-box 订阅链接 URL (如 http://<IP>:8000/sub?token=...): " user_sub
      sub_url="${user_sub:-}"
    fi

    if [[ -n "$sub_url" && -f "$sub_updater" ]]; then
      chmod +x "$sub_updater"
      bash "$sub_updater" --client -u "$sub_url" -y
      log_success "sing-box 客户端订阅已拉取并成功应用至 /etc/sing-box/config.json！"
    else
      log_info "未传入订阅链接，sing-box 核心已安装，后续可执行 'update-singbox-sub.sh --client -u <URL>' 随时同步订阅。"
    fi
  else
    log_step "正在安装 sing-box 服务端 (VLESS Reality / gRPC / SOCKS5 / 多协议入站)..."
    local installer="${PROJECT_ROOT}/fhs-install-singbox/install-singbox-server.sh"
    if [[ ! -f "$installer" ]]; then
      log_error "未找到脚本: $installer"
      return 1
    fi
    chmod +x "$installer"

    local cmd=(bash "$installer")
    [[ -n "$INPUT_DOMAIN" ]] && cmd+=("--domain" "$INPUT_DOMAIN")
    [[ -n "$INPUT_PORT" ]] && cmd+=("--socks-port" "$INPUT_PORT")
    [[ -n "$INPUT_USERNAME" ]] && cmd+=("--socks-user" "$INPUT_USERNAME")
    [[ -n "$INPUT_PASSWORD" ]] && cmd+=("--socks-pass" "$INPUT_PASSWORD")

    "${cmd[@]}"
    log_success "sing-box 服务端安装与配置完成！"
  fi
}

install_component_tunnel() {
  log_step "正在安装 Cloudflare Tunnel 隧道穿透与 VPS 出口 NAT 转发规则..."
  local installer="${PROJECT_ROOT}/cloudflared-tunnel/install.sh"
  if [[ ! -f "$installer" ]]; then
    log_error "未找到脚本: $installer"
    return 1
  fi
  chmod +x "$installer"

  local token="$INPUT_TOKEN"
  if [[ -z "$token" ]] && [[ "$ASSUME_YES" != "true" ]]; then
    echo ""
    echo -e "${YELLOW}提示: Cloudflare Tunnel Token 可在 Cloudflare Zero Trust 控制台 (Networks -> Tunnels) 创建获取。${NC}"
    read -r -p "请输入 Cloudflare Tunnel Token (若留空则以 Quick Tunnel 模式运行): " token
  fi

  local cmd=(bash "$installer")
  if [[ -n "$token" ]]; then
    cmd+=("-t" "$token")
  fi
  "${cmd[@]}"
  log_success "Cloudflare Tunnel 与 NAT 转发规则配置完成！"
}

install_component_subconverter() {
  log_step "正在安装 subconverter 通用订阅转换后端引擎 (默认端口 25500)..."
  local installer="${PROJECT_ROOT}/subconverter/install.sh"
  if [[ ! -f "$installer" ]]; then
    log_error "未找到脚本: $installer"
    return 1
  fi
  chmod +x "$installer"

  local port="${INPUT_PORT:-25500}"
  bash "$installer" -p "$port"
  log_success "subconverter 订阅转换后端已成功安装并启动！"
}

install_component_singbox_sub_converter() {
  log_step "正在安装 singbox-sub-converter 自适应订阅前端与 Web 管理面板 (端口 8000)..."
  local installer="${PROJECT_ROOT}/singbox-sub-converter/install.sh"
  if [[ ! -f "$installer" ]]; then
    log_error "未找到脚本: $installer"
    return 1
  fi
  chmod +x "$installer"

  local ip="${INPUT_SERVER_IP:-}"
  local port="${INPUT_PORT:-8000}"

  if [[ -z "$INPUT_SERVER_IP" ]] && [[ "$ASSUME_YES" != "true" ]]; then
    echo ""
    read -r -p "请输入本服务器公网 IP 地址 (用于订阅节点生成, 默认: $PUBLIC_IPV4): " user_ip
    ip="${user_ip:-$PUBLIC_IPV4}"
  fi

  bash "$installer" -i "$ip" -p "$port"
  log_success "singbox-sub-converter 自适应订阅服务安装完成！"
}

install_component_clash_sub_manager() {
  log_step "正在安装 clash-singbox-sub-manager (中转 VPS 本地订阅同步与注入管理器)..."
  local installer="${PROJECT_ROOT}/clash-singbox-sub-manager/install.sh"
  if [[ ! -f "$installer" ]]; then
    log_error "未找到脚本: $installer"
    return 1
  fi
  chmod +x "$installer"

  local port="${INPUT_PORT:-8000}"
  local sub_url="${INPUT_SUB_URL:-}"
  local proxy="${INPUT_PROXY:-socks5h://127.0.0.1:2080}"

  if [[ -z "$INPUT_SUB_URL" ]] && [[ "$ASSUME_YES" != "true" ]]; then
    echo ""
    read -r -p "请输入上游 Clash 订阅链接 (可留空，后续在 Web 界面或配置文件设置): " user_sub
    sub_url="${user_sub:-}"
  fi

  local cmd=(bash "$installer" -p "$port" --proxy "$proxy")
  if [[ -n "$sub_url" ]]; then
    cmd+=("-s" "$sub_url")
  fi
  if [[ -n "$INPUT_USERNAME" ]]; then
    cmd+=("-u" "$INPUT_USERNAME")
  fi
  if [[ -n "$INPUT_PASSWORD" ]]; then
    cmd+=("-P" "$INPUT_PASSWORD")
  fi

  "${cmd[@]}"
  log_success "clash-singbox-sub-manager 中转订阅管理器安装完成！"
}

install_component_vpngate() {
  log_step "正在安装 vpngate-singbox-openvpn (纯净住宅 IP 链式代理与节点轮询守护服务)..."
  ensure_docker

  local installer="${PROJECT_ROOT}/vpngate-singbox-openvpn/install.sh"
  if [[ ! -f "$installer" ]]; then
    log_error "未找到脚本: $installer"
    return 1
  fi
  chmod +x "$installer"

  local sub_url="${INPUT_SUB_URL:-}"
  local country="${INPUT_COUNTRY:-JP}"
  local port="${INPUT_PORT:-2080}"

  if [[ -z "$INPUT_SUB_URL" ]] && [[ "$ASSUME_YES" != "true" ]]; then
    echo ""
    read -r -p "请输入 Sing-box 上游节点订阅链接 (用于连接 VPNGate 节点, 可选): " user_sub
    sub_url="${user_sub:-}"
    read -r -p "请输入住宅节点筛选国家代码 (如 JP, US, KR，默认: JP): " user_country
    country="${user_country:-JP}"
  fi

  local cmd=(bash "$installer" -p "$port" -c "$country")
  if [[ -n "$sub_url" ]]; then
    cmd+=("-s" "$sub_url")
  fi

  "${cmd[@]}"
  log_success "vpngate-singbox-openvpn 纯净住宅代理服务安装完成！"
}

install_component_cf_access_tcp() {
  log_step "正在安装 cloudflare-access-tcp (Cloudflare Access TCP 转发与自动优选 IP 容器)..."
  ensure_docker

  local installer="${PROJECT_ROOT}/cloudflare-access-tcp/install.sh"
  if [[ ! -f "$installer" ]]; then
    log_error "未找到脚本: $installer"
    return 1
  fi
  chmod +x "$installer"

  local token_id="${INPUT_SERVICE_TOKEN_ID:-}"
  local token_secret="${INPUT_SERVICE_TOKEN_SECRET:-}"
  local domains="${INPUT_DOMAINS:-movies.19910417.xyz,movies1.19910417.xyz}"
  local ports="${INPUT_PORTS:-5000,5001}"

  if [[ -z "$token_id" ]] && [[ "$ASSUME_YES" != "true" ]]; then
    echo ""
    echo -e "${YELLOW}提示: Service Token 用于安全鉴权穿透 Cloudflare Access 保护的 TCP 服务。${NC}"
    read -r -p "请输入 Cloudflare Access Service Token Client ID: " token_id
    read -r -p "请输入 Cloudflare Access Service Token Client Secret: " token_secret
    read -r -p "请输入转发目标域名列表 (英文逗号分隔, 默认: $domains): " user_domains
    domains="${user_domains:-$domains}"
    read -r -p "请输入本地映射端口列表 (英文逗号分隔, 默认: $ports): " user_ports
    ports="${user_ports:-$ports}"
  fi

  local cmd=(bash "$installer" --domains "$domains" --ports "$ports")
  if [[ -n "$token_id" ]]; then
    cmd+=("--service-token-id" "$token_id")
  fi
  if [[ -n "$token_secret" ]]; then
    cmd+=("--service-token-secret" "$token_secret")
  fi

  "${cmd[@]}"
  log_success "cloudflare-access-tcp 客户端转发服务安装完成！"
}

install_component_cf_warp() {
  log_step "正在安装 Cloudflare Zero Trust (WARP) 客户端套件..."
  local warp_type="docker"

  if [[ "$ASSUME_YES" != "true" ]]; then
    echo ""
    echo "请选择 Cloudflare WARP 部署模式:"
    echo "  1) Docker SOCKS5 代理客户端 (推荐, 策略路由隔离, 端口 1080)"
    echo "  2) Linux 官方原生 cloudflare-warp 客户端 (全局 VPN / WARP Connector)"
    read -r -p "请输入选择 [1-2] (默认: 1): " warp_choice
    warp_choice="${warp_choice:-1}"
    if [[ "$warp_choice" == "2" ]]; then
      warp_type="native"
    fi
  fi

  if [[ "$warp_type" == "docker" ]]; then
    ensure_docker
    local installer="${PROJECT_ROOT}/cloudflare-zero-trust/docker-run.sh"
    if [[ ! -f "$installer" ]]; then
      log_error "未找到脚本: $installer"
      return 1
    fi
    if [[ -z "$INPUT_TOKEN" ]] && [[ "$ASSUME_YES" != "true" ]]; then
      echo ""
      echo -e "${YELLOW}提示: Cloudflare Zero Trust WARP 需要配置 Team 组织名称与 Service Token 进行设备注册与策略授权。${NC}"
      read -r -p "请输入 Cloudflare Zero Trust Team 组织名称 (例如 myteam): " INPUT_TOKEN
    fi
    if [[ -z "$INPUT_SERVICE_TOKEN_ID" ]] && [[ "$ASSUME_YES" != "true" ]]; then
      read -r -p "请输入 Cloudflare Access Service Token Client ID: " INPUT_SERVICE_TOKEN_ID
      read -r -p "请输入 Cloudflare Access Service Token Client Secret: " INPUT_SERVICE_TOKEN_SECRET
    fi

    local cmd=(bash "$installer" --service)
    if [[ -n "$INPUT_TOKEN" ]]; then
      cmd+=("--team" "$INPUT_TOKEN")
    fi
    if [[ -n "$INPUT_SERVICE_TOKEN_ID" ]]; then
      cmd+=("--service-token-id" "$INPUT_SERVICE_TOKEN_ID")
    fi
    if [[ -n "$INPUT_SERVICE_TOKEN_SECRET" ]]; then
      cmd+=("--service-token-secret" "$INPUT_SERVICE_TOKEN_SECRET")
    fi

    "${cmd[@]}"
    log_success "Cloudflare WARP Docker SOCKS5 服务已启动并注册开机自启！"
  else
    local installer="${PROJECT_ROOT}/cloudflare-zero-trust/install.sh"
    if [[ ! -f "$installer" ]]; then
      log_error "未找到脚本: $installer"
      return 1
    fi
    chmod +x "$installer"
    bash "$installer"
    log_success "Cloudflare WARP 原生客户端安装完成！"
  fi
}

install_component_preferred_ip() {
  log_step "正在安装 preferred-ip-manager (优选 IP 定时测速与推送服务)..."
  local installer="${PROJECT_ROOT}/preferred-ip-manager/install.sh"
  if [[ ! -f "$installer" ]]; then
    log_error "未找到脚本: $installer"
    return 1
  fi
  chmod +x "$installer"

  local proxy="${INPUT_PROXY:-}"
  local cmd=(bash "$installer" --install -y)
  if [[ -n "$proxy" ]]; then
    cmd+=("--proxy" "$proxy")
  fi

  "${cmd[@]}"
  log_success "preferred-ip-manager 定时优选测速服务安装完成！"
}

# ===================== 角色方案一键部署 =====================

# 1. 目标 VPS (Target VPS): sing-box + Tunnel/NAT + subconverter + singbox-sub-converter (+ 选装 vpngate)
deploy_role_target() {
  echo ""
  echo -e "${CYAN}================================================================${NC}"
  echo -e "${BOLD}${PURPLE}  🚀 开始部署: 目标 VPS (Target / 出口网关服务器) 套件${NC}"
  echo -e "${CYAN}================================================================${NC}"
  echo -e "预设组件清单:"
  echo -e "  1. ${GREEN}sing-box 服务端${NC} (VLESS Reality / gRPC 8088 / SOCKS 10086 / 原生出口)"
  echo -e "  2. ${GREEN}Cloudflare Tunnel & NAT 转发${NC} (Tunnel 穿透 + 出口 NAT MASQUERADE 规则)"
  echo -e "  3. ${GREEN}subconverter${NC} (通用订阅转换后端, 端口 25500)"
  echo -e "  4. ${GREEN}singbox-sub-converter${NC} (自适应订阅前端与 Web 管理面板, 端口 8000)"
  if [[ "$PACKAGE_TYPE" == "full" ]]; then
    echo -e "  5. ${GREEN}vpngate-singbox-openvpn${NC} (纯净住宅 IP 链式代理, 端口 2080)"
  fi
  echo ""

  if [[ "$ASSUME_YES" != "true" ]]; then
    read -r -p "确认开始执行部署? [Y/n] " confirm
    confirm="${confirm:-y}"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      log_warn "用户取消部署。"
      return 0
    fi
  fi

  install_component_singbox
  install_component_tunnel
  install_component_subconverter
  install_component_singbox_sub_converter

  if [[ "$PACKAGE_TYPE" == "full" ]]; then
    install_component_vpngate
  fi

  show_deployment_summary "target"
}

# 2. 中转 VPS (Relay VPS): sing-box + clash-singbox-sub-manager + cloudflare-access-tcp
deploy_role_relay() {
  echo ""
  echo -e "${CYAN}================================================================${NC}"
  echo -e "${BOLD}${PURPLE}  🚀 开始部署: 中转 VPS (Relay / 流量中继与受限分发) 套件${NC}"
  echo -e "${CYAN}================================================================${NC}"
  echo -e "预设组件清单:"
  echo -e "  1. ${GREEN}sing-box 服务端 / 核心${NC} (入站提取 / 转发网关)"
  echo -e "  2. ${GREEN}clash-singbox-sub-manager${NC} (本地 Clash 订阅同步/注入管理器, 零外部 Subapi 依赖, 端口 8000)"
  echo -e "  3. ${GREEN}cloudflare-access-tcp${NC} (Cloudflare Access TCP 转发与自动优选 IP 容器, 端口 5000/5001)"
  echo ""

  if [[ "$ASSUME_YES" != "true" ]]; then
    read -r -p "确认开始执行部署? [Y/n] " confirm
    confirm="${confirm:-y}"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      log_warn "用户取消部署。"
      return 0
    fi
  fi

  install_component_singbox
  install_component_clash_sub_manager
  install_component_cf_access_tcp

  show_deployment_summary "relay"
}

# 3. Client 端 (Client): cloudflare-access-tcp + cloudflare-zero-trust WARP
deploy_role_client() {
  echo ""
  echo -e "${CYAN}================================================================${NC}"
  echo -e "${BOLD}${PURPLE}  🚀 开始部署: Client 端 (Client / 本地网关 / 个人客户端) 套件${NC}"
  echo -e "${CYAN}================================================================${NC}"
  echo -e "预设组件清单:"
  echo -e "  1. ${GREEN}cloudflare-access-tcp${NC} (Cloudflare Access TCP 转发与自动优选 IP 容器, 端口 5000/5001)"
  echo -e "  2. ${GREEN}cloudflare-zero-trust${NC} (Docker WARP SOCKS5 代理客户端 + 策略路由隔离, 端口 1080)"
  echo ""

  # 检查并提示 Client 模式必须配置的 Service Token 与 Team 组织名
  if [[ -z "$INPUT_SERVICE_TOKEN_ID" || -z "$INPUT_SERVICE_TOKEN_SECRET" || -z "$INPUT_TOKEN" ]] && [[ "$ASSUME_YES" != "true" ]]; then
    echo -e "${YELLOW}【必填凭据设置】Client 端运行需连接 Cloudflare Zero Trust，请提供以下凭据:${NC}"
    if [[ -z "$INPUT_SERVICE_TOKEN_ID" ]]; then
      read -r -p "请输入 Cloudflare Access Service Token Client ID: " INPUT_SERVICE_TOKEN_ID
    fi
    if [[ -z "$INPUT_SERVICE_TOKEN_SECRET" ]]; then
      read -r -p "请输入 Cloudflare Access Service Token Client Secret: " INPUT_SERVICE_TOKEN_SECRET
    fi
    if [[ -z "$INPUT_TOKEN" ]]; then
      read -r -p "请输入 Cloudflare Zero Trust Team 组织名称 (例如 myteam): " INPUT_TOKEN
    fi
    echo ""
  fi

  if [[ "$ASSUME_YES" != "true" ]]; then
    read -r -p "确认开始执行部署? [Y/n] " confirm
    confirm="${confirm:-y}"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      log_warn "用户取消部署。"
      return 0
    fi
  fi

  install_component_cf_access_tcp
  install_component_cf_warp

  show_deployment_summary "client"
}

show_deployment_summary() {
  local role="$1"
  echo ""
  echo -e "${GREEN}================================================================${NC}"
  echo -e "${BOLD}${GREEN}  🎉 角色 [${role^^}] 套件部署已全部顺利完成！${NC}"
  echo -e "${GREEN}================================================================${NC}"
  echo ""
  echo -e "${BOLD}常用日常运维管理命令:${NC}"
  echo -e "  • 查看全局组件运行状态: ${CYAN}vps-utils status${NC}"
  echo -e "  • 重新打开主管理面板  : ${CYAN}vps-utils${NC}"
  echo ""
  if [[ "$role" == "target" ]]; then
    echo -e "${BOLD}已就绪服务概览:${NC}"
    echo -e "  • 自适应订阅 Web 面板 : ${YELLOW}http://${PUBLIC_IPV4}:8000${NC} (默认账号: ${GREEN}jayyang${NC} / 密码: ${GREEN}admin1234${NC})"
    echo -e "  • subconverter 转换后端: ${YELLOW}http://${PUBLIC_IPV4}:25500${NC}"
    echo -e "  • sing-box 服务端入站  : VLESS Reality (${YELLOW}443${NC} / ${YELLOW}8443${NC}), SOCKS5 (${YELLOW}10086${NC}), gRPC (${YELLOW}8088${NC})"
    echo -e "  • Cloudflare Tunnel  : 请在 Zero Trust 后台配置公共域名映射 (sub, subapi, grpc)"
  elif [[ "$role" == "relay" ]]; then
    echo -e "${BOLD}已就绪服务概览:${NC}"
    echo -e "  • 中转订阅 Web 面板   : ${YELLOW}http://${PUBLIC_IPV4}:8000${NC} (默认账号: ${GREEN}admin${NC} / 密码: ${GREEN}admin1234${NC})"
    echo -e "  • 订阅管理 CLI 工具   : ${CYAN}clash-singbox-sub-manager status${NC}"
    echo -e "  • Access TCP 本地映射  : ${YELLOW}127.0.0.1:5000${NC} / ${YELLOW}127.0.0.1:5001${NC}"
    echo -e "  • Access TCP 管理 CLI : ${CYAN}cloudflare-access-tcp status${NC}"
    echo -e "  • sing-box 服务端状态  : ${CYAN}systemctl status sing-box${NC}"
  elif [[ "$role" == "client" ]]; then
    echo -e "${BOLD}已就绪服务概览:${NC}"
    echo -e "  • Access TCP 本地映射  : ${YELLOW}127.0.0.1:5000${NC} / ${YELLOW}127.0.0.1:5001${NC}"
    echo -e "  • Access TCP 管理 CLI : ${CYAN}cloudflare-access-tcp status${NC}"
    echo -e "  • WARP SOCKS5 代理端口 : ${YELLOW}127.0.0.1:1080${NC}"
  fi
  echo -e "${GREEN}================================================================${NC}"
  echo ""
}

# ===================== 全局状态仪表盘 =====================
show_system_status() {
  echo ""
  echo -e "${CYAN}================================================================================${NC}"
  echo -e "${BOLD}${CYAN}               📊 VPS Utils 全局组件运行状态与网络监听汇总                      ${NC}"
  echo -e "${CYAN}================================================================================${NC}"
  printf " %-24s %-24s %-16s %-20s
" "组件名称" "当前运行状态" "监听/映射端口" "日常管理命令"
  echo -e "--------------------------------------------------------------------------------"

  local rows=(
    "singbox:1. sing-box 服务端:443,8443,10086:systemctl status sing-box"
    "tunnel:2. Cloudflare Tunnel:NAT Masquerade:setup-cloudflare-one.sh -s"
    "subconverter:3. subconverter 转换后端:25500:systemctl status subconverter"
    "singbox-sub-converter:4. singbox-sub-converter:8000 (Web UI):systemctl status singbox-sub-converter"
    "clash-sub-manager:5. clash-sub-manager:8000 (Web UI):clash-singbox-sub-manager status"
    "vpngate:6. vpngate 住宅IP代理:2080 (SOCKS5):vpngate-tunnel status"
    "cf-access-tcp:7. cloudflare-access-tcp:5000, 5001:cloudflare-access-tcp status"
    "cf-warp:8. Zero Trust WARP 代理:1080 (SOCKS5):docker-run.sh / warp-cli"
    "preferred-ip:9. preferred-ip-manager:Systemd Timer:preferred-ip-manager status"
  )

  for row in "${rows[@]}"; do
    IFS=":" read -r key name port cmd <<< "$row"
    local st
    st=$(get_component_status "$key")
    local badge=""
    case "$st" in
      active)        badge="${GREEN}● 运行中 (Active)${NC}" ;;
      inactive)      badge="${YELLOW}○ 已停止 (Inactive)${NC}" ;;
      not_installed) badge="${NC}- 未安装 (Not Installed)${NC}" ;;
      *)             badge="${NC}- 未安装${NC}" ;;
    esac
    printf " %-24b %-34b %-16b %-20b
" "$name" "$badge" "$port" "$cmd"
  done

  echo -e "${CYAN}================================================================================${NC}"
  echo ""
}

# ===================== 服务生命周期管理 =====================
manage_service() {
  local op="$1"
  local target="$2"

  if [[ -z "$target" ]]; then
    target="all"
  fi

  case "$target" in
    singbox)
      case "$op" in
        start|stop|restart) systemctl "$op" sing-box && log_success "sing-box 服务已 ${op}" ;;
        status)             systemctl status sing-box ;;
        logs)               journalctl -u sing-box -f -n 50 ;;
      esac
      ;;
    tunnel)
      case "$op" in
        start|stop|restart) systemctl "$op" cloudflared && log_success "cloudflared 服务已 ${op}" ;;
        status)             systemctl status cloudflared ;;
        logs)               journalctl -u cloudflared -f -n 50 ;;
      esac
      ;;
    subconverter)
      case "$op" in
        start|stop|restart) systemctl "$op" subconverter && log_success "subconverter 服务已 ${op}" ;;
        status)             systemctl status subconverter ;;
        logs)               journalctl -u subconverter -f -n 50 ;;
      esac
      ;;
    singbox-sub-converter)
      case "$op" in
        start|stop|restart) systemctl "$op" singbox-sub-converter && log_success "singbox-sub-converter 服务已 ${op}" ;;
        status)             systemctl status singbox-sub-converter ;;
        logs)               journalctl -u singbox-sub-converter -f -n 50 ;;
      esac
      ;;
    clash-sub-manager)
      case "$op" in
        start|stop|restart) systemctl "$op" clash-singbox-sub-manager && log_success "clash-singbox-sub-manager 服务已 ${op}" ;;
        status)             clash-singbox-sub-manager status 2>/dev/null || systemctl status clash-singbox-sub-manager ;;
        logs)               journalctl -u clash-singbox-sub-manager -f -n 50 ;;
      esac
      ;;
    vpngate)
      case "$op" in
        start|stop|restart)
          docker "$op" vpngate-singbox-openvpn 2>/dev/null || true
          systemctl "$op" vpngate-singbox-node-updater 2>/dev/null || true
          log_success "vpngate 服务已 ${op}"
          ;;
        status) vpngate-tunnel status 2>/dev/null || docker ps -f name=vpngate-singbox-openvpn ;;
        logs)   docker logs -f --tail 50 vpngate-singbox-openvpn ;;
      esac
      ;;
    cf-access-tcp)
      case "$op" in
        start|stop|restart)
          if command -v cloudflare-access-tcp &>/dev/null; then
            cloudflare-access-tcp "$op"
          else
            systemctl "$op" cloudflare-access-tcp
          fi
          log_success "cloudflare-access-tcp 服务已 ${op}"
          ;;
        status) cloudflare-access-tcp status 2>/dev/null || systemctl status cloudflare-access-tcp ;;
        logs)   cloudflare-access-tcp logs 2>/dev/null || docker logs -f --tail 50 cloudflare-access-tcp ;;
      esac
      ;;
    cf-warp)
      case "$op" in
        start|stop|restart)
          systemctl "$op" cloudflare-warp-socks5 2>/dev/null || systemctl "$op" warp-svc 2>/dev/null || true
          log_success "Cloudflare WARP 服务已 ${op}"
          ;;
        status) systemctl status cloudflare-warp-socks5 2>/dev/null || warp-cli status 2>/dev/null ;;
        logs)   docker logs -f --tail 50 cloudflare-warp-socks5 2>/dev/null || journalctl -u warp-svc -f -n 50 ;;
      esac
      ;;
    preferred-ip)
      case "$op" in
        start|stop|restart) systemctl "$op" preferred-ip-updater.timer && log_success "preferred-ip 定时器已 ${op}" ;;
        status)             preferred-ip-manager status 2>/dev/null || systemctl status preferred-ip-updater.timer ;;
        logs)               preferred-ip-manager logs 2>/dev/null || journalctl -u preferred-ip-updater.service -f -n 50 ;;
      esac
      ;;
    all)
      for s in singbox tunnel subconverter singbox-sub-converter clash-sub-manager vpngate cf-access-tcp cf-warp preferred-ip; do
        if [[ $(get_component_status "$s") != "not_installed" ]]; then
          manage_service "$op" "$s"
        fi
      done
      ;;
    *)
      log_error "未知服务组件: $target"
      ;;
  esac
}

# ===================== 一键卸载与清理 =====================
uninstall_component() {
  local comp="$1"
  case "$comp" in
    singbox)
      log_warn "正在卸载 sing-box 服务端..."
      systemctl stop sing-box 2>/dev/null || true
      systemctl disable sing-box 2>/dev/null || true
      rm -f /etc/systemd/system/sing-box.service /usr/local/bin/sing-box
      systemctl daemon-reload
      log_success "sing-box 已卸载！"
      ;;
    tunnel)
      log_warn "正在卸载 Cloudflare Tunnel 与清理 NAT 转发..."
      systemctl stop cloudflared 2>/dev/null || true
      systemctl disable cloudflared 2>/dev/null || true
      rm -f /etc/systemd/system/cloudflared.service /usr/local/bin/cloudflared
      if [[ -f "${PROJECT_ROOT}/cloudflared-tunnel/setup-cloudflare-one.sh" ]]; then
        bash "${PROJECT_ROOT}/cloudflared-tunnel/setup-cloudflare-one.sh" --unset || true
      fi
      systemctl daemon-reload
      log_success "Cloudflare Tunnel 已卸载！"
      ;;
    subconverter)
      log_warn "正在卸载 subconverter..."
      systemctl stop subconverter 2>/dev/null || true
      systemctl disable subconverter 2>/dev/null || true
      rm -rf /etc/systemd/system/subconverter.service /usr/local/subconverter /usr/local/bin/subconverter
      systemctl daemon-reload
      log_success "subconverter 已卸载！"
      ;;
    singbox-sub-converter)
      log_warn "正在卸载 singbox-sub-converter..."
      if [[ -f "${PROJECT_ROOT}/singbox-sub-converter/uninstall.sh" ]]; then
        bash "${PROJECT_ROOT}/singbox-sub-converter/uninstall.sh" || true
      else
        systemctl stop singbox-sub-converter 2>/dev/null || true
        systemctl disable singbox-sub-converter 2>/dev/null || true
        rm -rf /etc/systemd/system/singbox-sub-converter.service /usr/local/singbox-sub-converter
        systemctl daemon-reload
      fi
      log_success "singbox-sub-converter 已卸载！"
      ;;
    clash-sub-manager)
      log_warn "正在卸载 clash-singbox-sub-manager..."
      if [[ -f "${PROJECT_ROOT}/clash-singbox-sub-manager/uninstall.sh" ]]; then
        bash "${PROJECT_ROOT}/clash-singbox-sub-manager/uninstall.sh" || true
      else
        systemctl stop clash-singbox-sub-manager 2>/dev/null || true
        systemctl disable clash-singbox-sub-manager 2>/dev/null || true
        rm -rf /etc/systemd/system/clash-singbox-sub-manager.service /usr/local/bin/clash-singbox-sub-manager*
        systemctl daemon-reload
      fi
      log_success "clash-singbox-sub-manager 已卸载！"
      ;;
    vpngate)
      log_warn "正在卸载 vpngate-singbox-openvpn..."
      if [[ -f "${PROJECT_ROOT}/vpngate-singbox-openvpn/uninstall.sh" ]]; then
        bash "${PROJECT_ROOT}/vpngate-singbox-openvpn/uninstall.sh" || true
      else
        docker stop vpngate-singbox-openvpn 2>/dev/null || true
        docker rm -f vpngate-singbox-openvpn 2>/dev/null || true
        systemctl stop vpngate-singbox-node-updater 2>/dev/null || true
        systemctl disable vpngate-singbox-node-updater 2>/dev/null || true
        rm -rf /etc/systemd/system/vpngate-singbox-* /etc/vpngate-singbox-openvpn /usr/local/bin/vpngate-tunnel
        systemctl daemon-reload
      fi
      log_success "vpngate-singbox-openvpn 已卸载！"
      ;;
    cf-access-tcp)
      log_warn "正在卸载 cloudflare-access-tcp..."
      if command -v cloudflare-access-tcp &>/dev/null; then
        cloudflare-access-tcp uninstall || true
      elif [[ -f "${PROJECT_ROOT}/cloudflare-access-tcp/service.sh" ]]; then
        bash "${PROJECT_ROOT}/cloudflare-access-tcp/service.sh" uninstall || true
      else
        docker stop cloudflare-access-tcp 2>/dev/null || true
        docker rm -f cloudflare-access-tcp 2>/dev/null || true
        systemctl stop cloudflare-access-tcp 2>/dev/null || true
        systemctl disable cloudflare-access-tcp 2>/dev/null || true
        rm -rf /etc/systemd/system/cloudflare-access-tcp.service /etc/cloudflare-access-tcp /usr/local/bin/cloudflare-access-tcp /usr/local/bin/cf-access-tcp
        systemctl daemon-reload
      fi
      log_success "cloudflare-access-tcp 已卸载！"
      ;;
    cf-warp)
      log_warn "正在卸载 Cloudflare WARP 客户端..."
      if [[ -f "${PROJECT_ROOT}/cloudflare-zero-trust/docker-run.sh" ]]; then
        bash "${PROJECT_ROOT}/cloudflare-zero-trust/docker-run.sh" --uninstall-service || true
      fi
      systemctl stop warp-svc 2>/dev/null || true
      systemctl disable warp-svc 2>/dev/null || true
      log_success "Cloudflare WARP 已卸载！"
      ;;
    preferred-ip)
      log_warn "正在卸载 preferred-ip-manager..."
      if [[ -f "${PROJECT_ROOT}/preferred-ip-manager/install.sh" ]]; then
        bash "${PROJECT_ROOT}/preferred-ip-manager/install.sh" --uninstall -y || true
      else
        systemctl stop preferred-ip-updater.timer preferred-ip-updater.service 2>/dev/null || true
        systemctl disable preferred-ip-updater.timer preferred-ip-updater.service 2>/dev/null || true
        rm -rf /etc/systemd/system/preferred-ip-updater.* /etc/preferred-ip-manager /usr/local/share/preferred-ip-manager /usr/local/bin/preferred-ip-manager*
        systemctl daemon-reload
      fi
      log_success "preferred-ip-manager 已卸载！"
      ;;
    all)
      log_warn "即将卸载所有已部署的 vps-utils 组件..."
      for c in singbox tunnel subconverter singbox-sub-converter clash-sub-manager vpngate cf-access-tcp cf-warp preferred-ip; do
        uninstall_component "$c"
      done
      log_success "所有组件已全部彻底卸载并清理完毕！"
      ;;
    *)
      log_error "未知卸载组件: $comp"
      ;;
  esac
}

# ===================== 交互式主菜单 =====================
show_main_menu() {
  clear 2>/dev/null || true
  echo -e "${CYAN}"
  echo "  ██╗   ██╗██████╗ ███████╗      ██╗   ██╗████████╗██╗██╗     ███████╗"
  echo "  ██║   ██║██╔══██╗██╔════╝      ██║   ██║╚══██╔══╝██║██║     ██╔════╝"
  echo "  ██║   ██║██████╔╝███████╗█████╗██║   ██║   ██║   ██║██║     ███████╗"
  echo "  ╚██╗ ██╔╝██╔═══╝ ╚════██║╚════╝██║   ██║   ██║   ██║██║     ╚════██║"
  echo "   ╚████╔╝ ██║     ███████║      ╚██████╔╝   ██║   ██║███████╗███████║"
  echo "    ╚═══╝  ╚═╝     ╚══════╝       ╚═════╝    ╚═╝   ╚═╝╚══════╝╚══════╝"
  echo -e "${NC}"
  echo -e "${BOLD}VPS Utils 综合运维管理工具箱${NC} | 操作系统: ${GREEN}${OS_NAME} ${OS_VERSION} (${ARCH})${NC} | 本机IP: ${YELLOW}${PUBLIC_IPV4}${NC}"
  echo -e "${CYAN}--------------------------------------------------------------------------------${NC}"
  echo -e "${BOLD}【🚀 按角色一键安装部署】${NC}"
  echo -e "  ${GREEN}1)${NC} ${BOLD}目标 VPS (Target VPS)${NC}       - 代理服务端 + Tunnel穿透 + 订阅转换 (+ 选装住宅代理)"
  echo -e "  ${GREEN}2)${NC} ${BOLD}中转 VPS (Relay VPS)${NC}        - 本地轻量订阅提取 + 中转转发 + Access TCP 转发"
  echo -e "  ${GREEN}3)${NC} ${BOLD}Client 端 (Client / 本地网关)${NC} - Access TCP 转发 + Zero Trust WARP 代理"
  echo ""
  echo -e "${BOLD}【🛠️ 单组件与日常运维】${NC}"
  echo -e "  ${GREEN}4)${NC} 自定义选择单组件安装 / 升级 (sing-box, Tunnel, subconverter, Access TCP...)"
  echo -e "  ${GREEN}5)${NC} 查看全局组件运行状态与端口监听 (Status Dashboard)"
  echo -e "  ${GREEN}6)${NC} 服务生命周期管理 (启动 / 停止 / 重启 / 查看实时日志)"
  echo -e "  ${GREEN}7)${NC} 组件一键卸载与环境清理 (Uninstall)"
  echo ""
  echo -e "  ${RED}0)${NC} 退出脚本 (Exit)"
  echo -e "${CYAN}--------------------------------------------------------------------------------${NC}"
  read -r -p "请输入选项编号 [0-7]: " menu_choice

  case "$menu_choice" in
    1)
      echo ""
      echo -e "${BOLD}选择目标 VPS (Target VPS) 套件规格:${NC}"
      echo -e "  1) ${GREEN}标准套件 (Standard)${NC}: sing-box + Tunnel/NAT + subconverter + singbox-sub-converter"
      echo -e "  2) ${PURPLE}全功能套件 (Full)${NC}   : 标准套件 + vpngate 住宅IP链式代理 (端口 2080)"
      read -r -p "请选择规格 [1-2] (默认: 1): " target_type_choice
      if [[ "$target_type_choice" == "2" ]]; then
        PACKAGE_TYPE="full"
      else
        PACKAGE_TYPE="standard"
      fi
      deploy_role_target
      ;;
    2)
      deploy_role_relay
      ;;
    3)
      deploy_role_client
      ;;
    4)
      show_custom_component_menu
      ;;
    5)
      show_system_status
      ;;
    6)
      show_service_manage_menu
      ;;
    7)
      show_uninstall_menu
      ;;
    0)
      log_info "已退出脚本。"
      exit 0
      ;;
    *)
      log_warn "无效选项，请重新输入。"
      sleep 1
      show_main_menu
      ;;
  esac
}

show_service_manage_menu() {
  echo ""
  echo -e "${CYAN}----------------------------------------------------------------${NC}"
  echo -e "${BOLD}【服务生命周期管理】${NC}"
  echo -e "  1) 重启所有已安装组件 (Restart All)"
  echo -e "  2) 停止所有组件 (Stop All)"
  echo -e "  3) 启动所有组件 (Start All)"
  echo -e "  4) 管理单个组件服务 (Start / Stop / Restart / Logs)"
  echo -e "  0) 返回上级菜单"
  echo -e "${CYAN}----------------------------------------------------------------${NC}"
  read -r -p "请选择操作编号 [0-4]: " s_choice

  case "$s_choice" in
    1) manage_service "restart" "all" ;;
    2) manage_service "stop" "all" ;;
    3) manage_service "start" "all" ;;
    4)
      echo ""
      echo -e "选择目标组件:"
      echo -e "  1) sing-box 服务端       2) Cloudflare Tunnel"
      echo -e "  3) subconverter 转换后端 4) singbox-sub-converter"
      echo -e "  5) clash-sub-manager     6) vpngate 住宅代理"
      echo -e "  7) cf-access-tcp 转发    8) Zero Trust WARP"
      echo -e "  9) preferred-ip-manager"
      read -r -p "请输入组件编号 [1-9]: " sc_target
      local comp_map=("" "singbox" "tunnel" "subconverter" "singbox-sub-converter" "clash-sub-manager" "vpngate" "cf-access-tcp" "cf-warp" "preferred-ip")
      local target_comp="${comp_map[$sc_target]}"
      if [[ -n "$target_comp" ]]; then
        echo -e "请选择动作: 1) 重启 (restart)  2) 启动 (start)  3) 停止 (stop)  4) 查看实时日志 (logs)"
        read -r -p "请输入动作 [1-4]: " sa_action
        case "$sa_action" in
          1) manage_service "restart" "$target_comp" ;;
          2) manage_service "start" "$target_comp" ;;
          3) manage_service "stop" "$target_comp" ;;
          4) manage_service "logs" "$target_comp" ;;
          *) log_warn "无效动作" ;;
        esac
      fi
      ;;
    0) show_main_menu ;;
    *) log_warn "无效输入"; show_service_manage_menu ;;
  esac
}

show_custom_component_menu() {
  echo ""
  echo -e "${CYAN}----------------------------------------------------------------${NC}"
  echo -e "${BOLD}【单组件定制安装列表】${NC}"
  echo -e "  1) sing-box 核心 (Server 服务端模式 / Client 客户端订阅模式)"
  echo -e "  2) Cloudflare Tunnel 隧道穿透与 VPS 出口 NAT 转发"
  echo -e "  3) subconverter 通用订阅转换后端 (端口 25500)"
  echo -e "  4) singbox-sub-converter 自适应订阅前端与 Web 后台 (端口 8000)"
  echo -e "  5) clash-singbox-sub-manager 中转 VPS 本地订阅管理器"
  echo -e "  6) vpngate-singbox-openvpn 纯净住宅 IP 链式代理 (端口 2080)"
  echo -e "  7) cloudflare-access-tcp 客户端 TCP 转发与自动优选 IP 容器"
  echo -e "  8) cloudflare-zero-trust WARP 客户端 (Docker SOCKS5 / 原生)"
  echo -e "  9) preferred-ip-manager 优选 IP 定时测速与推送"
  echo -e "  0) 返回上级菜单"
  echo -e "${CYAN}----------------------------------------------------------------${NC}"
  read -r -p "请选择要安装的组件编号 [0-9]: " comp_choice

  case "$comp_choice" in
    1)
      echo ""
      echo -e "${BOLD}请选择 sing-box 部署模式:${NC}"
      echo -e "  1) ${GREEN}Server 服务端模式${NC} (VLESS Reality / gRPC / SOCKS5 多协议入站)"
      echo -e "  2) ${PURPLE}Client 客户端模式${NC} (通过订阅 URL 同步节点与路由分流规则)"
      read -r -p "请输入选项 [1-2] (默认: 1): " sb_mode_choice
      if [[ "$sb_mode_choice" == "2" ]]; then
        install_component_singbox "client"
      else
        install_component_singbox "server"
      fi
      ;;
    2) install_component_tunnel ;;
    3) install_component_subconverter ;;
    4) install_component_singbox_sub_converter ;;
    5) install_component_clash_sub_manager ;;
    6) install_component_vpngate ;;
    7) install_component_cf_access_tcp ;;
    8) install_component_cf_warp ;;
    9) install_component_preferred_ip ;;
    0) show_main_menu ;;
    *) log_warn "无效输入"; show_custom_component_menu ;;
  esac
}

show_uninstall_menu() {
  echo ""
  echo -e "${RED}----------------------------------------------------------------${NC}"
  echo -e "${BOLD}${RED}【组件一键卸载列表】${NC}"
  echo -e "  1) 卸载 sing-box 服务端"
  echo -e "  2) 卸载 Cloudflare Tunnel 并清理 NAT 转发"
  echo -e "  3) 卸载 subconverter"
  echo -e "  4) 卸载 singbox-sub-converter"
  echo -e "  5) 卸载 clash-singbox-sub-manager"
  echo -e "  6) 卸载 vpngate-singbox-openvpn"
  echo -e "  7) 卸载 cloudflare-access-tcp"
  echo -e "  8) 卸载 cloudflare-zero-trust WARP"
  echo -e "  9) 卸载 preferred-ip-manager"
  echo -e "  A) ${BOLD}${RED}彻底卸载所有 vps-utils 组件 (全部清除)${NC}"
  echo -e "  0) 返回上级菜单"
  echo -e "${RED}----------------------------------------------------------------${NC}"
  read -r -p "请选择要卸载的项目 [0-9/A]: " un_choice

  case "$un_choice" in
    1) uninstall_component "singbox" ;;
    2) uninstall_component "tunnel" ;;
    3) uninstall_component "subconverter" ;;
    4) uninstall_component "singbox-sub-converter" ;;
    5) uninstall_component "clash-sub-manager" ;;
    6) uninstall_component "vpngate" ;;
    7) uninstall_component "cf-access-tcp" ;;
    8) uninstall_component "cf-warp" ;;
    9) uninstall_component "preferred-ip" ;;
    [Aa]) uninstall_component "all" ;;
    0) show_main_menu ;;
    *) log_warn "无效输入"; show_uninstall_menu ;;
  esac
}

# ===================== CLI 帮助与参数解析 =====================
show_help() {
  echo "使用方法: $0 [选项|子命令]"
  echo ""
  echo "按角色一键安装部署:"
  echo "  -r, --role <ROLE>             指定安装角色: target (目标VPS) | relay (中转VPS) | client (Client端)"
  echo "  -t, --type <TYPE>             指定套件规格: standard (标准套件, 默认) | full (全功能套件)"
  echo ""
  echo "单组件按需安装与管理:"
  echo "  -c, --component <NAME>        单独安装指定组件:"
  echo "                                singbox | tunnel | subconverter | singbox-sub-converter"
  echo "                                clash-sub-manager | vpngate | cf-access-tcp | cf-warp | preferred-ip"
  echo "  -s, --status                  查看所有组件的实时运行与端口监听状态"
  echo "  -u, --uninstall <NAME|all>    卸载指定组件或全部组件"
  echo ""
  echo "快捷子命令:"
  echo "  status                        查看所有组件运行状态"
  echo "  restart <NAME|all>            重启指定或全部服务"
  echo "  start <NAME|all>              启动指定或全部服务"
  echo "  stop <NAME|all>               停止指定或全部服务"
  echo "  logs <NAME>                   查看指定服务的实时运行日志"
  echo ""
  echo "配置参数 (非交互静默安装):"
  echo "  -y, --yes                     自动确认所有提示 (非交互模式)"
  echo "      --token <TOKEN>           Cloudflare Tunnel Token / WARP Team 凭证"
  echo "      --service-token-id <ID>   Cloudflare Access Service Token Client ID"
  echo "      --service-token-secret <SECRET> Cloudflare Access Service Token Client Secret"
  echo "      --domains <DOMAINS>       Access TCP 转发目标域名列表 (逗号分隔)"
  echo "      --ports <PORTS>           Access TCP 转发端口列表 (逗号分隔)"
  echo "      --sub-url <URL>           上游节点订阅链接"
  echo "      --server-ip <IP>          当前服务器公网 IP"
  echo "      --proxy <PROXY>           上游或测速代理 (如 socks5h://127.0.0.1:2080)"
  echo "      --country <COUNTRY>       VPNGate 住宅节点国家代码 (默认: JP)"
  echo "      --port <PORT>             自定义服务监听端口"
  echo "  -h, --help                    显示本帮助信息"
  echo ""
  echo "示例:"
  echo "  1. 交互式主菜单:               sudo bash install.sh"
  echo "  2. 目标 VPS 标准套件一键安装:   sudo bash install.sh --role target"
  echo "  3. 目标 VPS 全功能套件(含住宅代理): sudo bash install.sh --role target --type full -y"
  echo "  4. 中转 VPS 套件一键安装:       sudo bash install.sh --role relay"
  echo "  5. Client 端 Access+WARP 部署:  sudo bash install.sh --role client"
  echo "  6. 查看全局运行状态:           vps-utils status  或  sudo bash install.sh -s"
  echo "  7. 重启指定组件服务:           vps-utils restart cf-access-tcp"
  echo ""
}

parse_cli_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      status|-s|--status)
        ACTION="status"; shift ;;
      restart|start|stop|logs)
        ACTION="service_control"
        SERVICE_ACTION="$1"
        if [[ -n "$2" && ! "$2" =~ ^- ]]; then
          SINGLE_COMPONENT="$2"
          shift 2
        else
          SINGLE_COMPONENT="all"
          shift 1
        fi
        ;;
      -r|--role)
        ROLE="$2"; ACTION="role"; shift 2 ;;
      -t|--type|-m|--mode)
        PACKAGE_TYPE="$2"; shift 2 ;;
      -c|--component)
        SINGLE_COMPONENT="$2"; ACTION="component"; shift 2 ;;
      -u|--uninstall|uninstall)
        if [[ -n "$2" && ! "$2" =~ ^- ]]; then
          SINGLE_COMPONENT="$2"
          shift 2
        else
          SINGLE_COMPONENT="all"
          shift 1
        fi
        ACTION="uninstall"
        ;;
      -y|--yes)
        ASSUME_YES=true; shift ;;
      --token)
        INPUT_TOKEN="$2"; shift 2 ;;
      --service-token-id)
        INPUT_SERVICE_TOKEN_ID="$2"; shift 2 ;;
      --service-token-secret)
        INPUT_SERVICE_TOKEN_SECRET="$2"; shift 2 ;;
      --domains)
        INPUT_DOMAINS="$2"; shift 2 ;;
      --ports)
        INPUT_PORTS="$2"; shift 2 ;;
      --sub-url)
        INPUT_SUB_URL="$2"; shift 2 ;;
      --server-ip|--ip)
        INPUT_SERVER_IP="$2"; shift 2 ;;
      --proxy)
        INPUT_PROXY="$2"; shift 2 ;;
      --country)
        INPUT_COUNTRY="$2"; shift 2 ;;
      --port|-p)
        INPUT_PORT="$2"; shift 2 ;;
      -u|--username)
        INPUT_USERNAME="$2"; shift 2 ;;
      -P|--password)
        INPUT_PASSWORD="$2"; shift 2 ;;
      -h|--help)
        show_help; exit 0 ;;
      *)
        log_warn "未知参数: $1"
        show_help; exit 1 ;;
    esac
  done
}

# ===================== 主入口流程 =====================
main() {
  parse_cli_args "$@"

  ensure_repo_environment
  detect_os_and_arch

  if [[ "$ACTION" == "status" ]]; then
    show_system_status
    exit 0
  fi

  if [[ "$ACTION" == "service_control" ]]; then
    check_root
    manage_service "$SERVICE_ACTION" "$SINGLE_COMPONENT"
    exit 0
  fi

  check_root
  install_base_dependencies

  case "$ACTION" in
    menu)
      show_main_menu
      ;;
    role)
      case "$ROLE" in
        target|target-vps|server) deploy_role_target ;;
        relay|relay-vps|transit)  deploy_role_relay ;;
        client|local|gateway)     deploy_role_client ;;
        *)
          log_error "不支持的角色类型: $ROLE (可选: target, relay, client)"
          exit 1
          ;;
      esac
      ;;
    component)
      case "$SINGLE_COMPONENT" in
        singbox|sing-box)               install_component_singbox ;;
        tunnel|cloudflared|cloudflared-tunnel) install_component_tunnel ;;
        subconverter)                   install_component_subconverter ;;
        singbox-sub-converter|sub-converter) install_component_singbox_sub_converter ;;
        clash-sub-manager|clash-singbox-sub-manager) install_component_clash_sub_manager ;;
        vpngate|vpngate-singbox-openvpn) install_component_vpngate ;;
        cf-access-tcp|cloudflare-access-tcp) install_component_cf_access_tcp ;;
        cf-warp|cloudflare-zero-trust|warp) install_component_cf_warp ;;
        preferred-ip|preferred-ip-manager) install_component_preferred_ip ;;
        *)
          log_error "不支持的组件名称: $SINGLE_COMPONENT"
          exit 1
          ;;
      esac
      ;;
    uninstall)
      uninstall_component "$SINGLE_COMPONENT"
      ;;
    *)
      show_main_menu
      ;;
  esac
}

main "$@"
