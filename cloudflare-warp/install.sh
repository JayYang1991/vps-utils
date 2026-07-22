#!/usr/bin/env bash
#
# install.sh
# cloudflare-warp 自动化安装与 Systemd 服务配置脚本
# 仅下载、安装 Cloudflare 官方 cloudflare-warp 软件包并启动后台 warp-svc 服务，支持 -r/--reinstall 重新安装模式。

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
  echo "  -r, --reinstall       强制重新安装 Cloudflare WARP (停止服务并重新安装软件包)"
  echo "  -h, --help            显示此帮助信息"
  echo ""
  echo "环境变量:"
  echo "  REINSTALL             设置为 true 时开启重新安装模式"
}

REINSTALL="${REINSTALL:-false}"

while [[ $# -gt 0 ]]; do
  case $1 in
    -r | --reinstall)
      REINSTALL="true"
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

if [[ $EUID -ne 0 ]]; then
  error "此脚本必须以 root 权限运行，请使用 'sudo bash $0'"
  exit 1
fi

if [[ "$REINSTALL" == "true" ]]; then
  log "开启重新安装模式，正在停止现有 warp-svc 服务..."
  systemctl stop warp-svc 2>/dev/null || true
fi

log "检查系统与软件包管理器环境..."

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS_ID=$ID
  OS_LIKE=${ID_LIKE:-""}
else
  error "无法确认 Linux 发行版类型 (/etc/os-release 不存在)。"
  exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)
    ARCH_NAME="amd64"
    ;;
  aarch64|arm64)
    ARCH_NAME="arm64"
    ;;
  *)
    ARCH_NAME="amd64"
    warn "目标架构 ($ARCH) 可能不在 Cloudflare 官方仓库优先支持列表中，默认使用 amd64 尝试继续..."
    ;;
esac

install_apt() {
  log "检测到 Debian/Ubuntu 体系，配置 Cloudflare Apt 官方源..."

  local missing_deps=()
  command -v curl &>/dev/null || missing_deps+=("curl")
  command -v gpg &>/dev/null || missing_deps+=("gnupg")
  command -v lsb_release &>/dev/null || missing_deps+=("lsb-release")

  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    log "正在安装缺失的依赖程序: ${missing_deps[*]}..."
    apt-get update -y || true
    apt-get install -y "${missing_deps[@]}" || true
  fi

  mkdir -p /usr/share/keyrings
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

  CODENAME=""
  if command -v lsb_release &>/dev/null; then
    CODENAME=$(lsb_release -cs 2>/dev/null || true)
  fi
  if [[ -z "$CODENAME" && -n "${VERSION_CODENAME:-}" ]]; then
    CODENAME="$VERSION_CODENAME"
  fi
  if [[ -z "$CODENAME" ]]; then
    CODENAME="bookworm"
    warn "无法自动检测 OS Codename，默认使用 '${CODENAME}'"
  fi

  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" | tee /etc/apt/sources.list.d/cloudflare-client.list

  apt-get update -y || true

  local apt_cmd="apt-get install -y"
  if [[ "$REINSTALL" == "true" ]]; then
    log "正在以重新安装模式执行 apt-get install --reinstall..."
    apt_cmd="apt-get install --reinstall -y"
  else
    log "尝试通过 apt-get 安装 cloudflare-warp..."
  fi

  if ! $apt_cmd cloudflare-warp; then
    warn "apt-get 安装受阻（可能是由于系统中存在其他未完成或损坏的独立软件包，如 DKMS/内核头文件构建错误）。"
    log "正在尝试直接从 Cloudflare 官方源下载 .deb 软件包进行独立安装/重装..."

    PKG_INDEX_URL="https://pkg.cloudflareclient.com/dists/${CODENAME}/main/binary-${ARCH_NAME}/Packages"
    DEB_PATH=$(curl -fsSL "$PKG_INDEX_URL" 2>/dev/null | grep -E '^Filename:' | tail -n 1 | awk '{print $2}')

    if [[ -n "$DEB_PATH" ]]; then
      DEB_URL="https://pkg.cloudflareclient.com/${DEB_PATH}"
      TEMP_DEB="/tmp/cloudflare-warp-latest.deb"
      log "下载最新 Cloudflare WARP deb 包: ${DEB_URL}..."
      curl -fsSL -o "$TEMP_DEB" "$DEB_URL"

      log "使用 dpkg 独立安装/重装 ${TEMP_DEB}..."
      if ! dpkg -i "$TEMP_DEB"; then
        warn "dpkg 标准安装受阻，尝试以 --force-depends 强制配置安装..."
        dpkg -i --force-depends "$TEMP_DEB" || true
      fi

      rm -f "$TEMP_DEB"
    else
      error "无法从官方源检索到 cloudflare-warp .deb 软件包下载地址。"
      exit 1
    fi
  fi
}

install_yum() {
  log "检测到 RHEL/CentOS/Fedora/Enterprise Linux 体系，配置 Cloudflare Yum/Dnf 源..."
  curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | tee /etc/yum.repos.d/cloudflare-warp.repo

  if command -v dnf &>/dev/null; then
    if [[ "$REINSTALL" == "true" ]]; then
      dnf reinstall -y cloudflare-warp || yum reinstall -y cloudflare-warp || dnf install -y cloudflare-warp
    else
      dnf install -y cloudflare-warp || yum install -y cloudflare-warp
    fi
  else
    if [[ "$REINSTALL" == "true" ]]; then
      yum reinstall -y cloudflare-warp || yum install -y cloudflare-warp
    else
      yum install -y cloudflare-warp
    fi
  fi
}

case "$OS_ID" in
  ubuntu|debian|raspbian|linuxmint|pop)
    install_apt
    ;;
  centos|rhel|rocky|almalinux|fedora|ol)
    install_yum
    ;;
  *)
    if [[ "$OS_LIKE" == *"debian"* || "$OS_LIKE" == *"ubuntu"* ]]; then
      install_apt
    elif [[ "$OS_LIKE" == *"rhel"* || "$OS_LIKE" == *"fedora"* || "$OS_LIKE" == *"centos"* ]]; then
      install_yum
    else
      error "不支持的操作系统发行版: $OS_ID ($OS_LIKE)"
      exit 1
    fi
    ;;
esac

log "启动并启用 Systemd 服务 warp-svc..."
systemctl daemon-reload || true
systemctl enable --now warp-svc
systemctl restart warp-svc || true

log "等待 warp-svc 后台服务建立 Socket 端口..."
sleep 2

if ! command -v warp-cli &>/dev/null; then
  error "cloudflare-warp 安装失败或 warp-cli 未出现在 PATH 中。"
  exit 1
fi

log "=========================================="
if [[ "$REINSTALL" == "true" ]]; then
  log "Cloudflare WARP 软件包重新安装完成！"
else
  log "Cloudflare WARP 软件包安装完成！"
fi
log "=========================================="
echo ""
echo -e "后续配置提示（可以手动使用 warp-cli 命令进行设置）:"
echo -e "  1. 初始化注册账户 : ${YELLOW}warp-cli registration new${NC}"
echo -e "  2. 设置代理模式   : ${YELLOW}warp-cli mode proxy${NC} （开启 SOCKS5 本地代理模式，默认端口 40000）"
echo -e "  3. 设置全局模式   : ${YELLOW}warp-cli mode warp${NC} （开启全局虚拟网卡模式）"
echo -e "  4. 建立连接       : ${YELLOW}warp-cli connect${NC}"
echo -e "  5. 断开连接       : ${YELLOW}warp-cli disconnect${NC}"
echo -e "  6. 查看状态       : ${YELLOW}warp-cli status${NC}"
