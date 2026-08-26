#!/usr/bin/env bash
# ==============================================================================
# Clash & Sing-box Subscription Manager - Complete Installer
# Installs program files & systemd service into /usr/local/bin
# ==============================================================================

set -e

INSTALL_DIR="/usr/local/bin/clash-singbox-sub-manager"
BIN_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_NAME="clash-singbox-sub-manager"
SERVICE_FILE="${SERVICE_NAME}.service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IS_USER_MODE=false

if [ "$EUID" -ne 0 ]; then
    IS_USER_MODE=true
    INSTALL_DIR="${HOME}/.local/bin/clash-singbox-sub-manager"
    BIN_DIR="${HOME}/.local/bin"
    SYSTEMD_DIR="${HOME}/.config/systemd/user"
fi

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Default Parameters
PORT=8000
USERNAME="admin"
PASSWORD="admin1234"
NODE_IP=""
SUB_URL=""
UPSTREAM_PROXY="socks5h://127.0.0.1:2080"
SINGBOX_CONFIG="/etc/sing-box/config.json"
CLEAN_MODE=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--port)
                PORT="$2"; shift 2 ;;
            -u|--username|--user)
                USERNAME="$2"; shift 2 ;;
            -P|--password|--pass)
                PASSWORD="$2"; shift 2 ;;
            -i|--node-ip|--ip)
                NODE_IP="$2"; shift 2 ;;
            -s|--sub-url|--url)
                SUB_URL="$2"; shift 2 ;;
            --proxy|--upstream-proxy)
                UPSTREAM_PROXY="$2"; shift 2 ;;
            --singbox-config)
                SINGBOX_CONFIG="$2"; shift 2 ;;
            -c|--clean|clean)
                CLEAN_MODE=true; shift ;;
            -h|--help)
                echo "使用方法: $0 [选项]"
                echo ""
                echo "选项列表:"
                echo "  -p, --port <PORT>             监听端口 (默认: 8000)"
                echo "  -u, --username <USER>         Web 管理界面账号 (默认: admin)"
                echo "  -P, --password <PASS>         Web 管理界面密码 (默认: admin1234)"
                echo "  -i, --node-ip <IP>            提取节点的指定公网 IP (默认: 自动探测)"
                echo "  -s, --sub-url <URL>           上游 Clash 原始订阅链接 (默认: 留空)"
                echo "      --proxy <PROXY>           上游拉取优先代理 (默认: socks5h://127.0.0.1:2080)"
                echo "      --singbox-config <PATH>   Sing-box 配置文件路径 (默认: /etc/sing-box/config.json)"
                echo "  -c, --clean                   纯净全新安装 (重置配置文件与历史 UUID)"
                echo "  -h, --help                    显示本帮助信息"
                echo ""
                exit 0
                ;;
            *)
                shift ;;
        esac
    done
}

check_dependencies() {
    info "正在检查运行环境与 Python 依赖..."
    if ! command -v python3 >/dev/null 2>&1; then
        if [ "$EUID" -eq 0 ] && command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y && apt-get install -y python3 python3-pip python3-yaml curl
        else
            error "未找到 Python 3，请先安装: sudo apt-get install -y python3 python3-yaml curl"
            exit 1
        fi
    fi

    if ! python3 -c "import yaml" >/dev/null 2>&1; then
        info "正在安装 PyYAML 依赖..."
        if [ "$EUID" -eq 0 ] && command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y && apt-get install -y python3-yaml || python3 -m pip install pyyaml --break-system-packages 2>/dev/null || true
        else
            python3 -m pip install pyyaml --break-system-packages 2>/dev/null || true
        fi
    fi

    local py_version
    py_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    info "✅ Python 环境就绪: ${py_version}"
}

stop_existing_service() {
    info "正在停止可能运行的旧版本服务..."
    if [ "${IS_USER_MODE}" = true ]; then
        systemctl --user stop --no-block "${SERVICE_NAME}" 2>/dev/null || true
    else
        systemctl stop --no-block "${SERVICE_NAME}" 2>/dev/null || true
    fi
    pkill -9 -f "clash-singbox-sub-manager/main.py" 2>/dev/null || true
}

install_files() {
    info "正在安装程序文件至 ${INSTALL_DIR} ..."

    local tmp_backup=""
    if [ "${CLEAN_MODE}" != true ]; then
        if [ -f "${INSTALL_DIR}/config.json" ]; then
            tmp_backup=$(mktemp 2>/dev/null || mktemp -t 'clash_sub_cfg')
            cp -f "${INSTALL_DIR}/config.json" "${tmp_backup}" 2>/dev/null || true
        fi
    fi

    mkdir -p "${INSTALL_DIR}"
    mkdir -p "${BIN_DIR}"

    # Copy core modules
    cp -f "${SCRIPT_DIR}/qr_generator.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/config.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/clash_parser.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/web_ui.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/server.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/main.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/service.sh" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/uninstall.sh" "${INSTALL_DIR}/" 2>/dev/null || true
    cp -f "${SCRIPT_DIR}/requirements.txt" "${INSTALL_DIR}/" 2>/dev/null || true

    # Make executables
    chmod +x "${INSTALL_DIR}/main.py"
    chmod +x "${INSTALL_DIR}/server.py"
    chmod +x "${INSTALL_DIR}/service.sh"
    [ -f "${INSTALL_DIR}/uninstall.sh" ] && chmod +x "${INSTALL_DIR}/uninstall.sh"

    # Setup config.json
    if [ -n "${tmp_backup}" ] && [ -f "${tmp_backup}" ]; then
        info "正在保留现有历史配置与 UUID..."
        mv -f "${tmp_backup}" "${INSTALL_DIR}/config.json"
    else
        info "正在初始化配置 (Port: ${PORT}, User: ${USERNAME}, Proxy: ${UPSTREAM_PROXY})..."
        python3 -c "
from config import ConfigManager
cm = ConfigManager('${INSTALL_DIR}/config.json')
cm.set('server', 'port', int('${PORT}'), auto_save=False)
cm.set('auth', 'username', '${USERNAME}', auto_save=False)
cm.set('auth', 'password', '${PASSWORD}', auto_save=False)
cm.set('subscription', 'upstream_proxy', '${UPSTREAM_PROXY}', auto_save=False)
if '${NODE_IP}':
    cm.set('singbox', 'node_ip', '${NODE_IP}', auto_save=False)
if '${SUB_URL}':
    cm.set('subscription', 'clash_sub_url', '${SUB_URL}', auto_save=False)
if '${SINGBOX_CONFIG}':
    cm.set('singbox', 'config_path', '${SINGBOX_CONFIG}', auto_save=False)
cm.save()
"
    fi

    # Create global symlinks
    rm -f "${BIN_DIR}/clash-sub-manager" "${BIN_DIR}/clash-sub-service"
    ln -sf "${INSTALL_DIR}/main.py" "${BIN_DIR}/clash-sub-manager"
    ln -sf "${INSTALL_DIR}/service.sh" "${BIN_DIR}/clash-sub-service"

    info "✅ 全局命令快捷链接已创建: clash-sub-manager, clash-sub-service"
}

setup_systemd() {
    info "正在配置并启动 Systemd 服务 (${SERVICE_FILE})..."
    local python_bin
    python_bin=$(which python3)

    if [ "${IS_USER_MODE}" = true ]; then
        mkdir -p "${SYSTEMD_DIR}"
        rm -f "${SYSTEMD_DIR}/${SERVICE_FILE}"
        cat << SERVICE_EOF > "${SYSTEMD_DIR}/${SERVICE_FILE}"
[Unit]
Description=Clash & Sing-box Subscription Transformer & Web Daemon
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${python_bin} ${INSTALL_DIR}/main.py start
Restart=always
RestartSec=5
TimeoutStopSec=3s
KillMode=mixed
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
SERVICE_EOF

        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user enable "${SERVICE_NAME}" 2>/dev/null || true
        systemctl --user restart --no-block "${SERVICE_NAME}" 2>/dev/null || true
    else
        rm -f "${SYSTEMD_DIR}/${SERVICE_FILE}"
        cat << SERVICE_EOF > "${SYSTEMD_DIR}/${SERVICE_FILE}"
[Unit]
Description=Clash & Sing-box Subscription Transformer & Web Daemon
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${python_bin} ${INSTALL_DIR}/main.py start
Restart=always
RestartSec=5
TimeoutStopSec=3s
KillMode=mixed
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF

        systemctl daemon-reload 2>/dev/null || true
        systemctl enable "${SERVICE_NAME}" 2>/dev/null || true
        systemctl restart --no-block "${SERVICE_NAME}" 2>/dev/null || true
    fi
}

main() {
    parse_args "$@"

    echo -e "${CYAN}==================================================================${NC}"
    echo -e "${CYAN}  ⚡ Clash & Sing-box 订阅同步管理器 - 一键自动化安装脚本         ${NC}"
    echo -e "${CYAN}==================================================================${NC}"

    check_dependencies
    stop_existing_service
    install_files
    setup_systemd

    sleep 1

    echo ""
    info "🎉 服务已成功安装并启动！"
    echo ""
    python3 "${INSTALL_DIR}/main.py" status
    echo ""
    info "💡 常用管理命令:"
    info "   • clash-sub-service status    -> 📊 查看服务运行状态与订阅二维码"
    info "   • clash-sub-service logs      -> 📄 实时查看服务运行日志"
    info "   • clash-sub-service restart   -> 🔄 重启服务"
    info "   • clash-sub-service regen-uuid-> 🎲 重新生成随机 UUID"
    info "   • clash-sub-manager test      -> 🔍 测试 Sing-box 提取与配置转换"
}

main "$@"
