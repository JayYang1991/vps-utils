#!/usr/bin/env bash
# ==============================================================================
# Clash & Sing-box Subscription Manager - Complete Uninstaller
# ==============================================================================

set -e

INSTALL_DIR="/usr/local/bin/clash-singbox-sub-manager"
BIN_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_NAME="clash-singbox-sub-manager"
SERVICE_FILE="${SERVICE_NAME}.service"

if [ "$EUID" -ne 0 ]; then
    INSTALL_DIR="${HOME}/.local/bin/clash-singbox-sub-manager"
    BIN_DIR="${HOME}/.local/bin"
    SYSTEMD_DIR="${HOME}/.config/systemd/user"
fi

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${YELLOW}==================================================================${NC}"
echo -e "${YELLOW}  🗑️ Clash & Sing-box 订阅同步管理器 - 完全卸载脚本              ${NC}"
echo -e "${YELLOW}==================================================================${NC}"

info "正在停止并禁用 Systemd 服务..."
if [ "$EUID" -ne 0 ]; then
    systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl --user disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/${SERVICE_FILE}"
    systemctl --user daemon-reload 2>/dev/null || true
else
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/${SERVICE_FILE}"
    systemctl daemon-reload 2>/dev/null || true
fi

pkill -9 -f "clash-singbox-sub-manager/main.py" 2>/dev/null || true

info "正在删除快捷命令软链接..."
rm -f "${BIN_DIR}/clash-sub-manager" "${BIN_DIR}/clash-sub-service"

info "正在删除安装目录: ${INSTALL_DIR} ..."
rm -rf "${INSTALL_DIR}"

info "✅ 卸载完成！所有相关文件与服务已成功清理。"
