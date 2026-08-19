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

clean_history() {
    info "正在彻底清理历史节点沉淀库、7国保活状态池与 Scamalytics 威胁分缓存..."
    
    # 1. 停止后台服务与相关进程
    ${SYSTEMCTL_CMD} stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
    pkill -f "daemon.py" 2>/dev/null || true
    pkill -f "bridge.py" 2>/dev/null || true
    sleep 0.5

    # 2. 清除所有已知的可能安装路径和工作路径的 results 目录
    local clean_dirs=(
        "${INSTALL_DIR}/results"
        "${SCRIPT_DIR}/results"
        "/usr/local/bin/vpngate-residential-selector/results"
        "${HOME}/.local/bin/vpngate-residential-selector/results"
        "/root/.local/bin/vpngate-residential-selector/results"
        "${HOME}/vps-utils/vpngate-residential-selector/results"
        "/root/vps-utils/vpngate-residential-selector/results"
        "./results"
    )

    for dir in "${clean_dirs[@]}"; do
        if [ -d "${dir}" ]; then
            rm -rf "${dir:?}"/* 2>/dev/null || true
            mkdir -p "${dir}"
        fi
    done

    # 3. 同时调用 Python 内部全面清理逻辑
    if [ -x "${INSTALL_DIR}/main.py" ]; then
        python3 "${INSTALL_DIR}/main.py" --clean >/dev/null 2>&1 || true
    elif [ -x "${SCRIPT_DIR}/main.py" ]; then
        python3 "${SCRIPT_DIR}/main.py" --clean >/dev/null 2>&1 || true
    fi

    info "✅ 所有目录下的历史节点数据库、状态池与威胁分缓存已彻底清空！"
    info "💡 后台服务已停止。若需开始全新初始化，请运行: vpngate-service start (或 vpngate-selector 重新测速优选)"
}

list_nodes() {
    shift || true
    if [ -x "${INSTALL_DIR}/main.py" ]; then
        python3 "${INSTALL_DIR}/main.py" --list "$@"
    elif [ -x "${SCRIPT_DIR}/main.py" ]; then
        python3 "${SCRIPT_DIR}/main.py" --list "$@"
    else
        error "未找到主程序 main.py"
        exit 1
    fi
}

usage() {
    echo -e "${BLUE}VPNGATE 7国住宅代理 Systemd 后台服务管理脚本${NC}"
    echo "用法: $0 {list|clean|status|logs|start|stop|restart|install|uninstall} [参数]"
    echo ""
    echo "命令选项:"
    echo "  list|nodes 查看当前已选出的全部保活住宅节点列表 (支持 -c JP,US 筛选)"
    echo "  clean      清理历史节点沉淀库、7国状态池与 Scamalytics 威胁分缓存并重置"
    echo "  status     查看后台服务运行状态与进程信息"
    echo "  logs       实时追踪查看 5 分钟健康检查与节点热替换日志"
    echo "  start      启动后台保活服务"
    echo "  stop       停止后台保活服务"
    echo "  restart    重启后台保活服务"
    echo "  install    一键安装并配置为 Systemd 系统后台服务 (开机自启, 每5分钟检测)"
    echo "  uninstall  停止并彻底卸载 Systemd 服务"
    echo ""
    echo "示例:"
    echo "  $0 list           # 查看当前全部 7 国已选出的节点"
    echo "  $0 clean          # 清理全部历史数据库并重新初始化"
    echo "  $0 logs           # 实时跟踪日志"
    echo ""
}

case "$1" in
    list|nodes|show)
        list_nodes "$@"
        ;;
    clean|clear)
        clean_history
        ;;
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
