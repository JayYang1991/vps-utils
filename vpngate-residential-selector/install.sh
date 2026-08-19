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

install_openvpn_dependency() {
    info "正在检查并安装 OpenVPN 核心依赖..."
    if command -v openvpn >/dev/null 2>&1 || [ -x "/usr/sbin/openvpn" ] || [ -x "/usr/bin/openvpn" ] || [ -x "/usr/local/sbin/openvpn" ]; then
        info "✅ 检测到 OpenVPN 已安装就绪"
        return 0
    fi

    info "🔧 正在自动通过系统包管理器安装 OpenVPN..."
    if [ "$EUID" -eq 0 ]; then
        if command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y && apt-get install -y openvpn ca-certificates
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y epel-release || true
            dnf install -y openvpn ca-certificates
        elif command -v yum >/dev/null 2>&1; then
            yum install -y epel-release || true
            yum install -y openvpn ca-certificates
        elif command -v apk >/dev/null 2>&1; then
            apk add openvpn ca-certificates
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Sy --noconfirm openvpn ca-certificates
        fi
    elif command -v sudo >/dev/null 2>&1; then
        info "检测到非 root 用户，尝试通过 sudo 自动安装 OpenVPN..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update -y && sudo apt-get install -y openvpn ca-certificates
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y epel-release || true
            sudo dnf install -y openvpn ca-certificates
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y epel-release || true
            sudo yum install -y openvpn ca-certificates
        fi
    fi

    if command -v openvpn >/dev/null 2>&1 || [ -x "/usr/sbin/openvpn" ] || [ -x "/usr/bin/openvpn" ] || [ -x "/usr/local/sbin/openvpn" ]; then
        info "✅ OpenVPN 依赖安装成功！"
    else
        warn "⚠️ OpenVPN 自动安装未完成，若需使用网桥请手动运行: sudo apt-get install -y openvpn"
    fi
}

check_dependencies() {
    info "正在检查运行环境依赖..."
    if ! command -v python3 >/dev/null 2>&1; then
        if [ "$EUID" -eq 0 ] && command -v apt-get >/dev/null 2>&1; then
            apt-get update -y && apt-get install -y python3
        else
            error "未找到 Python 3，请先安装: sudo apt-get install -y python3"
            exit 1
        fi
    fi

    local py_version
    py_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    info "检测到 Python 版本: ${py_version}"

    # 安装并确保 OpenVPN 就绪
    install_openvpn_dependency

    if [ "${IS_USER_MODE}" = true ]; then
        warn "当前以普通用户身份运行，将安装至 ${INSTALL_DIR} 与 ${BIN_DIR} (无需 sudo)"
    else
        info "当前以 root 权限运行，将安装至系统全局 /usr/local/bin 目录"
    fi
}

stop_existing_service() {
    info "正在停止可能正在运行的旧版本服务与进程..."
    if [ "${IS_USER_MODE}" = true ]; then
        systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
    else
        systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    fi
    # 终止可能遗留的旧版独立前台后台进程
    pkill -f "${INSTALL_DIR}/daemon.py" 2>/dev/null || true
    sleep 0.5
}

install_files() {
    info "正在执行完全覆盖安装至 ${INSTALL_DIR} ..."

    # 1. 临时备份现有历史状态与缓存数据
    local tmp_backup_dir
    tmp_backup_dir=$(mktemp -d 2>/dev/null || mktemp -d -t 'vpngate_bak')

    if [ -d "${INSTALL_DIR}/results" ]; then
        [ -f "${INSTALL_DIR}/results/residential_pool.json" ] && cp -f "${INSTALL_DIR}/results/residential_pool.json" "${tmp_backup_dir}/" 2>/dev/null || true
        [ -f "${INSTALL_DIR}/results/all_discovered_nodes.json" ] && cp -f "${INSTALL_DIR}/results/all_discovered_nodes.json" "${tmp_backup_dir}/" 2>/dev/null || true
        [ -f "${INSTALL_DIR}/results/scamalytics_cache.json" ] && cp -f "${INSTALL_DIR}/results/scamalytics_cache.json" "${tmp_backup_dir}/" 2>/dev/null || true
    fi

    if [ -d "${SCRIPT_DIR}/results" ]; then
        [ -f "${SCRIPT_DIR}/results/residential_pool.json" ] && cp -f "${SCRIPT_DIR}/results/residential_pool.json" "${tmp_backup_dir}/" 2>/dev/null || true
        [ -f "${SCRIPT_DIR}/results/all_discovered_nodes.json" ] && cp -f "${SCRIPT_DIR}/results/all_discovered_nodes.json" "${tmp_backup_dir}/" 2>/dev/null || true
        [ -f "${SCRIPT_DIR}/results/scamalytics_cache.json" ] && cp -f "${SCRIPT_DIR}/results/scamalytics_cache.json" "${tmp_backup_dir}/" 2>/dev/null || true
    fi

    # 2. 完全清除旧版安装目录
    rm -rf "${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}/results"
    mkdir -p "${BIN_DIR}"

    # 3. 复制所有核心 python 模块与脚本
    cp -f "${SCRIPT_DIR}/fetcher.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/filter.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/fraud_checker.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/tester.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/exporter.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/pool_manager.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/daemon.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/bridge.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/main.py" "${INSTALL_DIR}/"
    cp -f "${SCRIPT_DIR}/service.sh" "${INSTALL_DIR}/"

    # 4. 恢复历史状态与缓存
    if [ -f "${tmp_backup_dir}/residential_pool.json" ]; then
        cp -f "${tmp_backup_dir}/residential_pool.json" "${INSTALL_DIR}/results/"
    fi
    if [ -f "${tmp_backup_dir}/all_discovered_nodes.json" ]; then
        cp -f "${tmp_backup_dir}/all_discovered_nodes.json" "${INSTALL_DIR}/results/"
    fi
    if [ -f "${tmp_backup_dir}/scamalytics_cache.json" ]; then
        cp -f "${tmp_backup_dir}/scamalytics_cache.json" "${INSTALL_DIR}/results/"
    fi
    rm -rf "${tmp_backup_dir}" 2>/dev/null || true

    # 5. 清理可能存在的 __pycache__ 缓存
    find "${INSTALL_DIR}" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

    # 6. 设置权限
    chmod +x "${INSTALL_DIR}/main.py"
    chmod +x "${INSTALL_DIR}/daemon.py"
    chmod +x "${INSTALL_DIR}/bridge.py"
    chmod +x "${INSTALL_DIR}/service.sh"
    chmod -R 755 "${INSTALL_DIR}"

    # 7. 清理旧软链接并重新创建全局终端调用命令软链接至 BIN_DIR
    info "正在重新创建全局快捷命令软链接至 ${BIN_DIR} ..."
    rm -f "${BIN_DIR}/vpngate-selector" "${BIN_DIR}/vpngate-nodes" "${BIN_DIR}/vpngate-daemon" "${BIN_DIR}/vpngate-bridge" "${BIN_DIR}/vpngate-service"

    ln -sf "${INSTALL_DIR}/main.py" "${BIN_DIR}/vpngate-selector"
    ln -sf "${INSTALL_DIR}/main.py" "${BIN_DIR}/vpngate-nodes"
    ln -sf "${INSTALL_DIR}/daemon.py" "${BIN_DIR}/vpngate-daemon"
    ln -sf "${INSTALL_DIR}/bridge.py" "${BIN_DIR}/vpngate-bridge"
    ln -sf "${INSTALL_DIR}/service.sh" "${BIN_DIR}/vpngate-service"
    chmod +x "${BIN_DIR}/vpngate-selector" "${BIN_DIR}/vpngate-nodes" "${BIN_DIR}/vpngate-daemon" "${BIN_DIR}/vpngate-bridge" "${BIN_DIR}/vpngate-service"

    info "✅ 全局快捷命令已重新绑定就绪:"
    info "   • vpngate-nodes     -> 查看当前已选出的全部 7 国住宅代理节点列表 (支持 -c JP)"
    info "   • vpngate-selector  -> 手动单次协议测速与提取 TOP 住宅节点 (可带 -l/--list 查看列表)"
    info "   • vpngate-service   -> 管理后台 systemd 服务 (支持 vpngate-service list/status/logs)"
    info "   • vpngate-bridge    -> 启动本地 SOCKS5/HTTP 住宅中继网桥"
    info "   • vpngate-daemon    -> 前台运行 7 国守护保活进程"
}

setup_systemd() {
    info "正在重新配置并加载 Systemd 服务 (${SERVICE_FILE})..."
    mkdir -p "${SYSTEMD_DIR}"

    local python_bin
    python_bin=$(which python3)

    if [ "${IS_USER_MODE}" = true ]; then
        rm -f "${SYSTEMD_DIR}/${SERVICE_FILE}"
        cat << SERVICE_EOF > "${SYSTEMD_DIR}/${SERVICE_FILE}"
[Unit]
Description=VPNGATE Multi-Country Residential Proxy Selector & Health Daemon
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${python_bin} ${INSTALL_DIR}/daemon.py --interval 300 --top-per-country 20
Restart=always
RestartSec=10
KillMode=process
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
SERVICE_EOF

        systemctl --user daemon-reload || true
        systemctl --user enable "${SERVICE_NAME}" || true
        systemctl --user restart --no-block "${SERVICE_NAME}" || true
        info "✅ ${SERVICE_NAME} 用户级服务已重新加载并启动！"
    else
        rm -f "${SYSTEMD_DIR}/${SERVICE_FILE}"
        cat << SERVICE_EOF > "${SYSTEMD_DIR}/${SERVICE_FILE}"
[Unit]
Description=VPNGATE Multi-Country Residential Proxy Selector & Health Daemon
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${python_bin} ${INSTALL_DIR}/daemon.py --interval 300 --top-per-country 20
Restart=always
RestartSec=10
KillMode=process
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF

        systemctl daemon-reload || true
        systemctl enable "${SERVICE_NAME}" || true
        systemctl restart --no-block "${SERVICE_NAME}" || true
        info "✅ ${SERVICE_NAME} 系统级服务已重新加载并启动！"
    fi
}

main() {
    echo -e "${BLUE}==================================================================${NC}"
    echo -e "${BLUE}  🌐 VPNGATE 7国住宅 IP 优选与 Systemd 服务完全覆盖安装脚本       ${NC}"
    echo -e "${BLUE}==================================================================${NC}"

    check_dependencies
    stop_existing_service
    install_files
    setup_systemd

    echo ""
    info "🎉 完全覆盖安装全部完成！"
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
