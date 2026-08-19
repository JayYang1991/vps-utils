#!/usr/bin/env bash
# ==============================================================================
# VPNGATE Residential Proxy Selector - Complete Installer
# Installs all program files & dependencies into /usr/local/bin for global access
# ==============================================================================

set -e

INSTALL_DIR="/usr/local/bin/vpngate-residential-selector"
BIN_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_NAME="vpngate-residential-selector"
SERVICE_FILE="${SERVICE_NAME}.service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IS_USER_MODE=false

if [ "$EUID" -ne 0 ]; then
    IS_USER_MODE=true
    INSTALL_DIR="${HOME}/.local/bin/vpngate-residential-selector"
    BIN_DIR="${HOME}/.local/bin"
    SYSTEMD_DIR="${HOME}/.config/systemd/user"
fi

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_dependencies() {
    info "正在检查运行环境依赖..."
    if ! command -v python3 >/dev/null 2>&1; then
        error "未找到 Python 3，请先安装: sudo apt-get install -y python3"
        exit 1
    fi

    local py_version
    py_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    info "检测到 Python 版本: ${py_version}"
    if [ "${IS_USER_MODE}" = true ]; then
        warn "当前以普通用户身份运行，将安装至 ${INSTALL_DIR} 与 ${BIN_DIR} (无需 sudo)"
    else
        info "当前以 root 权限运行，将安装至系统全局 /usr/local/bin 目录"
    fi
}

install_files() {
    info "正在安装所有依赖与程序文件至 ${INSTALL_DIR} ..."

    mkdir -p "${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}/results"

    # 复制所有核心 python 模块与脚本
    cp -f "${SCRIPT_DIR}/fetcher.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/filter.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/tester.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/exporter.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/pool_manager.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/daemon.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/bridge.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/main.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/service.sh" "${INSTALL_DIR}/"

    # 如果有历史状态文件则保留同步
    if [ -f "${SCRIPT_DIR}/results/residential_pool.json" ]; then
        cp -f "${SCRIPT_DIR}/results/residential_pool.json" "${INSTALL_DIR}/results/" || true
    fi

    # 设置可执行权限
    chmod +x "${INSTALL_DIR}/main.py"
    chmod +x "${INSTALL_DIR}/daemon.py"
    chmod +x "${INSTALL_DIR}/bridge.py"
    chmod +x "${INSTALL_DIR}/service.sh"
    chmod -R 755 "${INSTALL_DIR}"

    # 创建全局终端调用命令软链接至 /usr/local/bin
    info "正在创建全局快捷命令软链接至 ${BIN_DIR} ..."
    ln -sf "${INSTALL_DIR}/main.py" "${BIN_DIR}/vpngate-selector"
    ln -sf "${INSTALL_DIR}/daemon.py" "${BIN_DIR}/vpngate-daemon"
    ln -sf "${INSTALL_DIR}/bridge.py" "${BIN_DIR}/vpngate-bridge"
    ln -sf "${INSTALL_DIR}/service.sh" "${BIN_DIR}/vpngate-service"
    chmod +x "${BIN_DIR}/vpngate-selector" "${BIN_DIR}/vpngate-daemon" "${BIN_DIR}/vpngate-bridge" "${BIN_DIR}/vpngate-service"

    info "✅ 全局快捷命令已就绪:"
    info "   • vpngate-selector  -> 手动单次协议测速与提取 TOP 住宅节点"
    info "   • vpngate-daemon    -> 运行 7 国守护保活进程"
    info "   • vpngate-bridge    -> 启动本地 SOCKS5/HTTP 住宅中继网桥"
    info "   • vpngate-service   -> 管理后台 systemd 服务"
}

setup_systemd() {
    info "正在配置 Systemd 后台自愈服务 (${SERVICE_FILE})..."
    mkdir -p "${SYSTEMD_DIR}"

    if [ "${IS_USER_MODE}" = true ]; then
        cat << SERVICE_EOF > "${SYSTEMD_DIR}/${SERVICE_FILE}"
[Unit]
Description=VPNGATE Multi-Country Residential Proxy Selector & Health Daemon
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=$(which python3) ${INSTALL_DIR}/daemon.py --interval 300 --top-per-country 20
Restart=always
RestartSec=10
KillMode=process
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
SERVICE_EOF

        systemctl --user daemon-reload
        systemctl --user enable "${SERVICE_NAME}"
        systemctl --user restart "${SERVICE_NAME}"
        info "✅ ${SERVICE_NAME} 用户级服务已启动并配置为开机自启！"
    else
        cat << SERVICE_EOF > "${SYSTEMD_DIR}/${SERVICE_FILE}"
[Unit]
Description=VPNGATE Multi-Country Residential Proxy Selector & Health Daemon
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=$(which python3) ${INSTALL_DIR}/daemon.py --interval 300 --top-per-country 20
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
        info "✅ ${SERVICE_NAME} 系统级服务已启动并配置为开机自启！"
    fi
}

main() {
    echo -e "${BLUE}==================================================================${NC}"
    echo -e "${BLUE}  🌐 VPNGATE 7国住宅 IP 优选与 Systemd 服务一键安装脚本          ${NC}"
    echo -e "${BLUE}==================================================================${NC}"

    check_dependencies
    install_files
    setup_systemd

    echo ""
    info "🎉 安装全部完成！"
    if [ "${IS_USER_MODE}" = true ]; then
        systemctl --user status "${SERVICE_NAME}" --no-pager || true
    else
        systemctl status "${SERVICE_NAME}" --no-pager || true
    fi
    echo ""
    info "📁 代理文件保存路径: ${INSTALL_DIR}/results/proxies.txt"
    info "📊 7国看板文件路径: ${INSTALL_DIR}/results/summary.md"
    info "💡 随时可在终端运行 'vpngate-service status' 或 'vpngate-service logs' 查看运行日志！"
}

main "$@"
