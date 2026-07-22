#!/usr/bin/env bash
#
# install.sh
# subconverter 自动化安装与 Systemd 服务配置脚本
# 从 GitHub Release 下载最新版 subconverter_linux64.tar.gz，解压安装并配置 systemd 服务。

set -e

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

show_help() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  -p, --port PORT     指定 subconverter 监听端口 (默认: 25500)"
  echo "  -h, --help          显示此帮助信息"
  echo ""
  echo "环境变量:"
  echo "  SUBCONVERTER_PORT   指定 subconverter 监听端口 (默认: 25500)"
}

# --- Options Parsing ---
SUBCONVERTER_PORT="${SUBCONVERTER_PORT:-25500}"

while [[ $# -gt 0 ]]; do
  case $1 in
    -p | --port)
      SUBCONVERTER_PORT="$2"
      shift 2
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

# --- Check Root Permissions ---
if [[ $EUID -ne 0 ]]; then
  error "此脚本必须以 root 权限运行，请使用 'sudo bash $0'"
  exit 1
fi

# --- Dependencies Check ---
check_dependencies() {
  local deps=("curl" "tar" "grep" "sed")
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
      error "缺少必要依赖: $dep，请先安装该依赖。"
      exit 1
    fi
  done
}

check_dependencies

# --- Architecture Detection ---
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)
    ARCH_NAME="linux64"
    ;;
  aarch64|arm64)
    ARCH_NAME="aarch64"
    ;;
  armv7l|armhf)
    ARCH_NAME="armv7"
    ;;
  i386|i686)
    ARCH_NAME="linux32"
    ;;
  *)
    ARCH_NAME="linux64"
    warn "未识别的架构 ($ARCH)，默认使用 linux64"
    ;;
esac

GITHUB_REPO="JayYang1991/vps-utils"
DOWNLOAD_FILENAME="subconverter_${ARCH_NAME}.tar.gz"
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/${DOWNLOAD_FILENAME}"

TEMP_DIR=$(mktemp -d /tmp/subconverter_install.XXXXXX)
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

log "正在查询 GitHub 最新 Release 版本信息 (${GITHUB_REPO})..."
LATEST_TAG=$(curl -sL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | grep '"tag_name":' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || echo "latest")
log "检测到 subconverter 最新版本: ${LATEST_TAG}"

log "正在从 GitHub Release 下载 ${DOWNLOAD_FILENAME}..."
if ! curl -4 -L -q --retry 5 --retry-delay 5 -o "${TEMP_DIR}/${DOWNLOAD_FILENAME}" "${DOWNLOAD_URL}"; then
  error "下载 ${DOWNLOAD_FILENAME} 失败，请检查网络连接。"
  exit 1
fi

log "正在解压并安装 subconverter 到 /usr/local/subconverter ..."
mkdir -p /usr/local/subconverter
tar -xzf "${TEMP_DIR}/${DOWNLOAD_FILENAME}" -C /tmp/subconverter_install.XXXXXX 2>/dev/null || tar -xzf "${TEMP_DIR}/${DOWNLOAD_FILENAME}" -C "$TEMP_DIR"

if [[ -d "${TEMP_DIR}/subconverter" ]]; then
  cp -rf "${TEMP_DIR}/subconverter/"* /usr/local/subconverter/
else
  error "解压失败或文件结构异常。"
  exit 1
fi

# Ensure executable permissions
if [[ -f "/usr/local/subconverter/subconverter" ]]; then
  chmod +x /usr/local/subconverter/subconverter
else
  error "未找到可执行文件 /usr/local/subconverter/subconverter"
  exit 1
fi

# Symlink to /usr/local/bin/subconverter
log "创建软链接: /usr/local/bin/subconverter -> /usr/local/subconverter/subconverter"
mkdir -p /usr/local/bin
ln -sf /usr/local/subconverter/subconverter /usr/local/bin/subconverter

# Ensure default pref.ini exists
if [[ ! -f "/usr/local/subconverter/pref.ini" && -f "/usr/local/subconverter/pref.example.ini" ]]; then
  log "未检测到 pref.ini，自动从 pref.example.ini 创建初始配置文件..."
  cp /usr/local/subconverter/pref.example.ini /usr/local/subconverter/pref.ini
fi

# Configure specified port in pref.ini
if [[ -f "/usr/local/subconverter/pref.ini" ]]; then
  log "配置 subconverter 监听端口为: ${SUBCONVERTER_PORT} ..."
  if grep -qE "^[[:space:]]*port[[:space:]]*=" /usr/local/subconverter/pref.ini; then
    sed -i -E "s/^[[:space:]]*port[[:space:]]*=.*/port = ${SUBCONVERTER_PORT}/" /usr/local/subconverter/pref.ini
  elif grep -qE "\[server\]" /usr/local/subconverter/pref.ini; then
    sed -i "/\[server\]/a port = ${SUBCONVERTER_PORT}" /usr/local/subconverter/pref.ini
  else
    echo -e "\n[server]\nport = ${SUBCONVERTER_PORT}" >> /usr/local/subconverter/pref.ini
  fi
fi

# Create Systemd Service Unit
SYSTEMD_SERVICE_FILE="/etc/systemd/system/subconverter.service"
log "创建 Systemd 服务配置文件: ${SYSTEMD_SERVICE_FILE} ..."

cat << 'eof' > "${SYSTEMD_SERVICE_FILE}"
[Unit]
Description=Subconverter Subscription Conversion Service
Documentation=https://github.com/tindy2013/subconverter
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/subconverter
ExecStart=/usr/local/bin/subconverter
Restart=always
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
eof

# Enable and Start Systemd Service
log "重新加载 Systemd 配置并启动 subconverter 服务..."
systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

sleep 2

if systemctl is-active --quiet subconverter; then
  log "subconverter 服务已成功安装并启动！"
  log "监听端口: ${SUBCONVERTER_PORT}"
  log "服务管理命令:"
  log "  查看状态: systemctl status subconverter"
  log "  重启服务: systemctl restart subconverter"
  log "  停止服务: systemctl stop subconverter"
else
  warn "subconverter 服务未能启动，请检查系统日志:"
  systemctl status subconverter --no-pager || true
  journalctl -u subconverter -n 20 --no-pager || true
  exit 1
fi
