#!/usr/bin/env bash
#
# install.sh
# cloudflared-tunnel 自动化安装与 Systemd 服务配置脚本
# 从 Cloudflare 官方 Release 下载对应架构的 cloudflared，安装二进制并配置后台 Systemd 服务，
# 并自动调用 setup-cloudflare-one.sh 配置 VPS 出口 NAT 转发与双重开机持久化。

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

show_help() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  -t, --token TOKEN       Cloudflare Tunnel 密钥 Token (推荐从 Zero Trust 控制台获取)"
  echo "  -u, --url URL           本地需要内网穿透的服务 URL (默认: http://localhost:8000)"
  echo "  -i, --interface IF      指定 VPS 的外网物理网卡 (默认自动检测，传递给 setup-cloudflare-one.sh)"
  echo "  -w, --warp-if IF        指定入站隧道网卡 (默认: auto，若存在 warp0 则绑定 warp0，否则使用 any)"
  echo "      --skip-nat          跳过自动配置 VPS 出口 NAT 转发规则"
  echo "  -h, --help              显示帮助信息"
  echo ""
  echo "环境变量:"
  echo "  CLOUDFLARED_TOKEN       Cloudflare Tunnel Token"
  echo "  LOCAL_SERVICE_URL       本地内网服务地址 (默认: http://localhost:8000)"
  echo "  WAN_INTERFACE           外网物理网卡名称"
  echo "  WARP_INTERFACE          入站隧道网卡名称 (默认: auto)"
  echo "  SKIP_NAT                是否跳过 NAT 规则配置 (设置为 true 则跳过)"
}

TOKEN="${CLOUDFLARED_TOKEN:-}"
SERVICE_URL="${LOCAL_SERVICE_URL:-http://localhost:8000}"
WAN_IF="${WAN_INTERFACE:-}"
WARP_IF="${WARP_INTERFACE:-auto}"
SKIP_NAT_VAL="${SKIP_NAT:-false}"

while [[ $# -gt 0 ]]; do
  case $1 in
    -t | --token)
      TOKEN="$2"
      shift 2
      ;;
    -u | --url)
      SERVICE_URL="$2"
      shift 2
      ;;
    -i | --interface)
      WAN_IF="$2"
      shift 2
      ;;
    -w | --warp-if)
      WARP_IF="$2"
      shift 2
      ;;
    --skip-nat | --no-nat)
      SKIP_NAT_VAL=true
      shift 1
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    *)
      if [[ -z "$TOKEN" ]]; then
        TOKEN="$1"
      fi
      shift 1
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  error "此脚本必须以 root 权限运行，请使用 'sudo bash $0'"
  exit 1
fi

check_dependencies() {
  local deps=("curl")
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
      error "缺少必要依赖: $dep，请先安装。"
      exit 1
    fi
  done
}

check_dependencies

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)
    ARCH_NAME="amd64"
    ;;
  aarch64|arm64)
    ARCH_NAME="arm64"
    ;;
  armv7l|armhf)
    ARCH_NAME="arm"
    ;;
  i386|i686)
    ARCH_NAME="386"
    ;;
  *)
    ARCH_NAME="amd64"
    warn "未识别的架构 ($ARCH)，默认使用 amd64"
    ;;
esac

DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH_NAME}"

if [[ -f "/usr/local/bin/cloudflared" ]] && /usr/local/bin/cloudflared --version &>/dev/null; then
  log "检测到已存在 cloudflared 二进制: $(/usr/local/bin/cloudflared --version | head -n1)"
else
  log "正在从 Cloudflare 官方 GitHub 下载最新版 cloudflared (架构: ${ARCH_NAME})..."
  log "下载地址: ${DOWNLOAD_URL}"

  TMP_BIN=$(mktemp /tmp/cloudflared.XXXXXX)
  if ! curl -4 -L -q --retry 5 --retry-delay 5 -o "${TMP_BIN}" "${DOWNLOAD_URL}"; then
    error "下载 cloudflared 失败，请检查网络连接。"
    rm -f "${TMP_BIN}" 2>/dev/null || true
    exit 1
  fi
  chmod +x "${TMP_BIN}"
  systemctl stop cloudflared 2>/dev/null || true
  mkdir -p /usr/local/bin
  install -m 755 "${TMP_BIN}" /usr/local/bin/cloudflared
  rm -f "${TMP_BIN}" 2>/dev/null || true
fi

log "验证 cloudflared 可执行文件..."
/usr/local/bin/cloudflared --version

SYSTEMD_SERVICE_FILE="/etc/systemd/system/cloudflared.service"
log "配置 Systemd 服务配置文件: ${SYSTEMD_SERVICE_FILE} ..."

mkdir -p /etc/cloudflared

if [[ -n "$TOKEN" ]]; then
  log "检测到指定 Token，将以 Cloudflare Tunnel Token 模式进行配置..."
  cat << eof > "${SYSTEMD_SERVICE_FILE}"
[Unit]
Description=Cloudflare Tunnel Agent
Documentation=https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${TOKEN}
Restart=always
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
eof

else
  warn "未指定 Cloudflare Tunnel Token，将配置为 Quick Tunnel 模式 (自动穿透目标: ${SERVICE_URL})..."
  cat << eof > "${SYSTEMD_SERVICE_FILE}"
[Unit]
Description=Cloudflare Quick Tunnel Agent
Documentation=https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cloudflared tunnel --url ${SERVICE_URL} --no-autoupdate
Restart=always
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
eof
fi

log "重新加载 Systemd 配置并启动 cloudflared 服务..."
systemctl daemon-reload
systemctl enable cloudflared
systemctl restart cloudflared

sleep 2

if systemctl is-active --quiet cloudflared; then
  log "cloudflared 服务已成功安装并启动！"
else
  warn "cloudflared 服务未能启动，请检查系统日志:"
  systemctl status cloudflared --no-pager || true
  journalctl -u cloudflared -n 20 --no-pager || true
  exit 1
fi

# 配置 VPS 出口 NAT 转发
if [[ "$SKIP_NAT_VAL" == "true" ]]; then
  log "用户指定 --skip-nat，跳过 VPS 出口 NAT 转发配置。"
else
  log "正在自动配置目标端 VPS 出口 NAT 转发规则与双重开机持久化..."
  
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  SETUP_SCRIPT="${SCRIPT_DIR}/setup-cloudflare-one.sh"

  if [[ ! -f "$SETUP_SCRIPT" ]]; then
    SETUP_SCRIPT="/usr/local/bin/setup-cloudflare-one.sh"
    if [[ ! -f "$SETUP_SCRIPT" ]]; then
      log "本地未检测到 setup-cloudflare-one.sh，正在从远程下载..."
      curl -fsSL --retry 3 "https://raw.githubusercontent.com/JayYang1991/vps-utils/main/cloudflared-tunnel/setup-cloudflare-one.sh" -o "$SETUP_SCRIPT"
      chmod +x "$SETUP_SCRIPT"
    fi
  fi

  NAT_ARGS=("--setup")
  if [[ -n "$WAN_IF" ]]; then
    NAT_ARGS+=("-i" "$WAN_IF")
  fi
  if [[ -n "$WARP_IF" ]]; then
    NAT_ARGS+=("-w" "$WARP_IF")
  fi

  bash "$SETUP_SCRIPT" "${NAT_ARGS[@]}"
fi

log "=========================================="
success "cloudflared-tunnel 全套服务部署完成！"
log "=========================================="
echo ""
echo "服务管理命令:"
echo "  - 查看 cloudflared 状态 : systemctl status cloudflared"
echo "  - 重启 cloudflared 服务 : systemctl restart cloudflared"
echo "  - 查看 cloudflared 日志 : journalctl -u cloudflared -n 50 --no-pager"
if [[ "$SKIP_NAT_VAL" != "true" ]]; then
  echo "  - 查看 NAT 转发规则状态 : setup-cloudflare-one.sh --status"
  echo "  - 查看 NAT 持久化服务   : systemctl status cloudflare-one-nat.service"
fi
