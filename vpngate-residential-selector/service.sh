#!/usr/bin/env bash
# ==============================================================================
# VPNGATE Residential Proxy Daemon - Systemd Service Management Script
# ==============================================================================

set -e

SERVICE_NAME="vpngate-residential-selector"
SERVICE_FILE="${SERVICE_NAME}.service"
SYSTEMD_DIR="/etc/systemd/system"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "此操作需要 root 权限，请使用 sudo 运行: sudo $0 $1"
        exit 1
    fi
}

INSTALL_DIR="/usr/local/bin/vpngate-residential-selector"
BIN_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
if [ "$EUID" -ne 0 ]; then
    INSTALL_DIR="${HOME}/.local/bin/vpngate-residential-selector"
    BIN_DIR="${HOME}/.local/bin"
    SYSTEMD_DIR="${HOME}/.config/systemd/user"
fi

install_service() {
    "${SCRIPT_DIR}/install.sh"
}

SYSTEMCTL_CMD="systemctl"
JOURNALCTL_CMD="journalctl"
if [ "$EUID" -ne 0 ]; then
    SYSTEMCTL_CMD="systemctl --user"
    JOURNALCTL_CMD="journalctl --user"
fi

start_service() {
    ${SYSTEMCTL_CMD} start "${SERVICE_NAME}"
    info "✅ ${SERVICE_NAME} 服务已启动"
}

stop_service() {
    ${SYSTEMCTL_CMD} stop "${SERVICE_NAME}"
    info "🛑 ${SERVICE_NAME} 服务已停止"
}

restart_service() {
    ${SYSTEMCTL_CMD} restart "${SERVICE_NAME}"
    info "🔄 ${SERVICE_NAME} 服务已重启"
}

status_service() {
    ${SYSTEMCTL_CMD} status "${SERVICE_NAME}" --no-pager
}

show_logs() {
    ${JOURNALCTL_CMD} -u "${SERVICE_NAME}" -f -n 50
}

uninstall_service() {
    info "正在卸载 ${SERVICE_NAME} 服务..."
    ${SYSTEMCTL_CMD} stop "${SERVICE_NAME}" || true
    ${SYSTEMCTL_CMD} disable "${SERVICE_NAME}" || true
    rm -f "${SYSTEMD_DIR}/${SERVICE_FILE}"
    rm -f "${BIN_DIR}/vpngate-selector" "${BIN_DIR}/vpngate-daemon" "${BIN_DIR}/vpngate-service"
    rm -rf "${INSTALL_DIR}"
    ${SYSTEMCTL_CMD} daemon-reload
    info "✅ ${SERVICE_NAME} 服务与 ${BIN_DIR} 依赖文件已彻底清理卸载！"
}

usage() {
    echo -e "${BLUE}VPNGATE 7国住宅代理 Systemd 后台服务管理脚本${NC}"
    echo "用法: $0 {install|start|stop|restart|status|logs|uninstall}"
    echo ""
    echo "命令选项:"
    echo "  install    一键安装并配置为 Systemd 系统后台服务 (开机自启, 每5分钟检测)"
    echo "  start      启动后台服务"
    echo "  stop       停止后台服务"
    echo "  restart    重启后台服务"
    echo "  status     查看后台服务运行状态与统计"
    echo "  logs       实时追踪查看服务运行日志"
    echo "  uninstall  停止并彻底卸载 Systemd 服务"
    echo ""
}

case "$1" in
    install)
        install_service
        ;;
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    restart)
        restart_service
        ;;
    status)
        status_service
        ;;
    logs)
        show_logs
        ;;
    uninstall)
        uninstall_service
        ;;
    *)
        usage
        exit 1
        ;;
esac
