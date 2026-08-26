#!/usr/bin/env bash
# ==============================================================================
# Service control script for Clash & Sing-box Subscription Manager
# ==============================================================================

set -e

SERVICE_NAME="clash-singbox-sub-manager"
SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
PYTHON_BIN="$(which python3)"

# Detect user vs system mode
SYSTEMCTL_CMD="systemctl"
if [ "$EUID" -ne 0 ]; then
    SYSTEMCTL_CMD="systemctl --user"
fi

cmd_start() {
    echo -e "🚀 正在启动 ${SERVICE_NAME} 服务..."
    ${SYSTEMCTL_CMD} start "${SERVICE_NAME}"
    ${SYSTEMCTL_CMD} status "${SERVICE_NAME}" --no-pager
}

cmd_stop() {
    echo -e "🛑 正在停止 ${SERVICE_NAME} 服务..."
    ${SYSTEMCTL_CMD} stop "${SERVICE_NAME}"
}

cmd_restart() {
    echo -e "🔄 正在重启 ${SERVICE_NAME} 服务..."
    ${SYSTEMCTL_CMD} restart "${SERVICE_NAME}"
    ${SYSTEMCTL_CMD} status "${SERVICE_NAME}" --no-pager
}

cmd_status() {
    ${SYSTEMCTL_CMD} status "${SERVICE_NAME}" --no-pager || true
    echo ""
    ${PYTHON_BIN} "${SCRIPT_DIR}/main.py" status
}

cmd_logs() {
    echo -e "📄 实时查看服务日志 (按 Ctrl+C 退出):"
    if [ "$EUID" -ne 0 ]; then
        journalctl --user -u "${SERVICE_NAME}" -f -n 50
    else
        journalctl -u "${SERVICE_NAME}" -f -n 50
    fi
}

cmd_regen_uuid() {
    ${PYTHON_BIN} "${SCRIPT_DIR}/main.py" gen-uuid
}

cmd_test() {
    ${PYTHON_BIN} "${SCRIPT_DIR}/main.py" test
}

show_help() {
    echo "用法: $0 {start|stop|restart|status|logs|regen-uuid|test}"
    echo ""
    echo "命令选项:"
    echo "  start       启动 systemd 后台服务"
    echo "  stop        停止 systemd 后台服务"
    echo "  restart     重启 systemd 后台服务"
    echo "  status      查看服务状态与当前订阅二维码"
    echo "  logs        实时查看后台日志"
    echo "  regen-uuid  重新生成随机 UUID"
    echo "  test        测试 Sing-box 提取与 Clash 配置转换"
    echo ""
}

case "$1" in
    start)      cmd_start ;;
    stop)       cmd_stop ;;
    restart)    cmd_restart ;;
    status)     cmd_status ;;
    logs)       cmd_logs ;;
    regen-uuid) cmd_regen_uuid ;;
    test)       cmd_test ;;
    *)          show_help; exit 1 ;;
esac
