#!/usr/bin/env bash
#
# install.sh
# cloudflared-tunnel 自动化安装与 Systemd 服务配置脚本
# 从 Cloudflare 官方 Release 下载对应架构的 cloudflared，安装二进制并配置后台 Systemd 服务。

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

show_help() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  -t, --token TOKEN     Cloudflare Tunnel 密钥 Token (推荐从 Zero Trust 控制台获取)"
  echo "  -u, --url URL         本地需要内网穿透的服务 URL (默认: http://localhost:8000)"
  echo "  -h, --help            显示帮助信息"
  echo ""
  echo "环境变量:"
  echo "  CLOUDFLARED_TOKEN     Cloudflare Tunnel Token"
  echo "  LOCAL_SERVICE_URL     本地内网服务地址 (默认: http://localhost:8000)"
}

TOKEN="${CLOUDFLARED_TOKEN:-}"
SERVICE_URL="${LOCAL_SERVICE_URL:-http://localhost:8000}"

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

log "正在从 Cloudflare 官方 GitHub 下载最新版 cloudflared (架构: ${ARCH_NAME})..."
log "下载地址: ${DOWNLOAD_URL}"

mkdir -p /usr/local/bin
if ! curl -4 -L -q --retry 5 --retry-delay 5 -o /usr/local/bin/cloudflared "${DOWNLOAD_URL}"; then
  error "下载 cloudflared 失败，请检查网络连接。"
  exit 1
fi

chmod +x /usr/local/bin/cloudflared

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
  log "服务管理命令:"
  log "  查看状态: systemctl status cloudflared"
  log "  重启服务: systemctl restart cloudflared"
  log "  查看日志: journalctl -u cloudflared -n 50 --no-pager"
else
  warn "cloudflared 服务未能启动，请检查系统日志:"
  systemctl status cloudflared --no-pager || true
  journalctl -u cloudflared -n 20 --no-pager || true
  exit 1
fi
