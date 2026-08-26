#!/usr/bin/env bash
# ==============================================================================
# vpngate-singbox-openvpn 服务卸载脚本
# 用法: sudo ./uninstall.sh [--purge]
# ==============================================================================

set -e

INSTALL_DIR="/usr/local/bin/vpngate-singbox-openvpn"
CONFIG_DIR="/etc/vpngate-singbox-openvpn"
BIN_DIR="/usr/local/bin"
SERVICE_NAME="vpngate-singbox-openvpn"
UPDATER_SERVICE_NAME="vpngate-singbox-node-updater"
SERVICE_DEST="/etc/systemd/system/${SERVICE_NAME}.service"
UPDATER_SERVICE_DEST="/etc/systemd/system/${UPDATER_SERVICE_NAME}.service"

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m"

PURGE_MODE=false
for arg in "$@"; do
    case "${arg}" in
        --purge|--all|-f)
            PURGE_MODE=true
            ;;
        -h|--help)
            echo "============================================================"
            echo " vpngate-singbox-openvpn 卸载程序"
            echo "============================================================"
            echo "用法: sudo ./uninstall.sh [选项]"
            echo ""
            echo "选项:"
            echo "  --purge, --all    彻底删除包括 /etc 配置文件与节点池在内的全部数据"
            echo "  -h, --help        显示帮助信息"
            echo "============================================================"
            exit 0
            ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} 请使用 sudo 权限运行此卸载脚本: sudo ./uninstall.sh"
    exit 1
fi

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE} 正在卸载 ${SERVICE_NAME} 与 ${UPDATER_SERVICE_NAME} 服务...  ${NC}"
echo -e "${BLUE}============================================================${NC}"

# 1. 停止并禁用 systemd 服务
if systemctl is-active --quiet "${UPDATER_SERVICE_NAME}" 2>/dev/null; then
    echo "[*] 停止 systemd 服务 ${UPDATER_SERVICE_NAME} ..."
    systemctl stop "${UPDATER_SERVICE_NAME}" || true
fi
if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    echo "[*] 停止 systemd 服务 ${SERVICE_NAME} ..."
    systemctl stop "${SERVICE_NAME}" || true
fi
if systemctl is-active --quiet singbox-vless-reality 2>/dev/null; then
    echo "[*] 停止 systemd 服务 singbox-vless-reality ..."
    systemctl stop singbox-vless-reality || true
fi

if systemctl is-enabled --quiet "${UPDATER_SERVICE_NAME}" 2>/dev/null; then
    echo "[*] 禁用 systemd 服务 ${UPDATER_SERVICE_NAME} ..."
    systemctl disable "${UPDATER_SERVICE_NAME}" || true
fi
if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
    echo "[*] 禁用 systemd 服务 ${SERVICE_NAME} ..."
    systemctl disable "${SERVICE_NAME}" || true
fi
if systemctl is-enabled --quiet singbox-vless-reality 2>/dev/null; then
    echo "[*] 禁用 systemd 服务 singbox-vless-reality ..."
    systemctl disable singbox-vless-reality || true
fi

# 2. 删除服务文件
if [ -f "${SERVICE_DEST}" ]; then
    echo "[*] 删除服务文件 ${SERVICE_DEST} ..."
    rm -f "${SERVICE_DEST}"
fi
if [ -f "${UPDATER_SERVICE_DEST}" ]; then
    echo "[*] 删除服务文件 ${UPDATER_SERVICE_DEST} ..."
    rm -f "${UPDATER_SERVICE_DEST}"
fi
if [ -f "/etc/systemd/system/singbox-vless-reality.service" ]; then
    echo "[*] 删除服务文件 /etc/systemd/system/singbox-vless-reality.service ..."
    rm -f "/etc/systemd/system/singbox-vless-reality.service"
fi
systemctl daemon-reload 2>/dev/null || true

# 3. 停止并移除容器
if docker ps -a --format "{{.Names}}" | grep -Eq "^${SERVICE_NAME}\$"; then
    echo "[*] 停止并删除 Docker 容器 ${SERVICE_NAME} ..."
    docker stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
    docker rm "${SERVICE_NAME}" >/dev/null 2>&1 || true
fi

# 4. 删除全局软链接
echo "[*] 清除 ${BIN_DIR} 全局软链接..."
rm -f "${BIN_DIR}/vpngate-tunnel" "${BIN_DIR}/vpngate-singbox" "${BIN_DIR}/vpngate-reality" "${BIN_DIR}/vpngate-generate-ovpn" "${BIN_DIR}/generate-ovpn" "${BIN_DIR}/vpngate-node-updater"

# 5. 删除 /usr/local/bin 下的安装目录
if [ -d "${INSTALL_DIR}" ]; then
    echo "[*] 删除程序安装目录 ${INSTALL_DIR} ..."
    rm -rf "${INSTALL_DIR}"
fi

# 6. 处理配置目录
if [ "${PURGE_MODE}" = true ]; then
    if [ -d "${CONFIG_DIR}" ]; then
        echo "[*] [Purge 模式] 彻底删除配置文件目录 ${CONFIG_DIR} ..."
        rm -rf "${CONFIG_DIR}"
    fi
else
    if [ -d "${CONFIG_DIR}" ]; then
        echo "[*] 清理运行时临时生成文件..."
        rm -f "${CONFIG_DIR}/singbox_run.json" "${CONFIG_DIR}/openvpn_run.ovpn" "${CONFIG_DIR}/vpn_status.json" "${CONFIG_DIR}/.switch_node" 2>/dev/null || true
    fi
fi

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} [*] 服务与程序已成功卸载！${NC}"
if [ "${PURGE_MODE}" = true ]; then
    echo -e " • 配置文件目录已彻底清理: ${YELLOW}${CONFIG_DIR}${NC}"
else
    echo -e " • 基础配置文件已保留: ${YELLOW}${CONFIG_DIR}/config.env${NC}"
    echo -e "   (如需彻底清理配置，可运行: sudo ./uninstall.sh --purge)"
fi
echo -e "${GREEN}============================================================${NC}"
