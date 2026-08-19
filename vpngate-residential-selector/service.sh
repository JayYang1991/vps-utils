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

install_service() {
    check_root "install"
    info "正在安装 ${SERVICE_NAME} Systemd 守护服务..."

    # 替换服务文件中的工作目录与执行路径为当前脚本所在绝对路径
    mkdir -p "${SCRIPT_DIR}/results"
    
    cat << SERVICE_EOF > "${SYSTEMD_DIR}/${SERVICE_FILE}"
[Unit]
Description=VPNGATE Multi-Country Residential Proxy Selector & Health Daemon
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${SCRIPT_DIR}
ExecStart=$(which python3) ${SCRIPT_DIR}/daemon.py --interval 300 --top-per-country 20
Restart=always
RestartSec=10
KillMode=process
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}"

    info "✅ ${SERVICE_NAME} 服务已成功安装并已设置为开机自启！"
    echo ""
    systemctl status "${SERVICE_NAME}" --no-pager || true
}

start_service() {
    check_root "start"
    systemctl start "${SERVICE_NAME}"
    info "✅ ${SERVICE_NAME} 服务已启动"
}

stop_service() {
    check_root "stop"
    systemctl stop "${SERVICE_NAME}"
    info "🛑 ${SERVICE_NAME} 服务已停止"
}

restart_service() {
    check_root "restart"
    systemctl restart "${SERVICE_NAME}"
    info "🔄 ${SERVICE_NAME} 服务已重启"
}

status_service() {
    systemctl status "${SERVICE_NAME}" --no-pager
}

show_logs() {
    journalctl -u "${SERVICE_NAME}" -f -n 50
}

uninstall_service() {
    check_root "uninstall"
    info "正在卸载 ${SERVICE_NAME} 服务..."
    systemctl stop "${SERVICE_NAME}" || true
    systemctl disable "${SERVICE_NAME}" || true
    rm -f "${SYSTEMD_DIR}/${SERVICE_FILE}"
    systemctl daemon-reload
    info "✅ ${SERVICE_NAME} 服务已彻底卸载！"
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
