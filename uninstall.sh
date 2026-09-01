#!/usr/bin/env bash
# ==============================================================================
# VPS Utils - 全局一键卸载与彻底清理脚本
# 停止并移除所有已部署的 VPS 组件服务、容器、配置文件及 vps-utils 全局命令
# GitHub: https://github.com/JayYang1991/vps-utils
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

if [[ -f "${SCRIPT_DIR}/install.sh" ]]; then
  exec bash "${SCRIPT_DIR}/install.sh" -u all "$@"
elif [[ -f "/usr/local/share/vps-utils/install.sh" ]]; then
  exec bash "/usr/local/share/vps-utils/install.sh" -u all "$@"
else
  echo "[ERROR] 未找到 install.sh 安装与卸载主程序！" >&2
  exit 1
fi
