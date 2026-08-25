#!/bin/bash
#
# uninstall.sh
# singbox-sub-converter 一键卸载与清理脚本
# 停止并注销 Systemd 服务，清理安装目录、虚拟环境与运行时临时文件。
#
# GitHub: https://github.com/JayYang1991/vps-utils
#

set -eo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

SERVICE_NAME="singbox-sub-converter"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TARGET_DIR="/usr/local/singbox-sub-converter"

FORCE=false
KEEP_DATA=false

show_help() {
  echo -e "${CYAN}${BOLD}singbox-sub-converter 一键卸载脚本${NC}"
  echo ""
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  -y, --yes, -f, --force   跳过确认交互提示，直接执行卸载"
  echo "  --keep-data              保留用户数据与配置目录 (${TARGET_DIR}/data)"
  echo "  -h, --help               显示此帮助信息"
  echo ""
  echo "使用示例:"
  echo "  sudo bash $0"
  echo "  sudo bash $0 -y"
  echo "  sudo bash $0 --keep-data"
}

# --- 参数解析 ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes|-f|--force)
      FORCE=true
      shift 1
      ;;
    --keep-data)
      KEEP_DATA=true
      shift 1
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      warn "未知参数: $1"
      show_help
      exit 1
      ;;
  esac
done

# --- 检查 Root 权限 ---
if [[ $EUID -ne 0 && "$(id -u)" -ne 0 ]]; then
  error "此操作需要 root 权限，请使用 'sudo bash $0' 运行"
  exit 1
fi

echo -e "${CYAN}================================================${NC}"
echo -e "${CYAN}${BOLD}     singbox-sub-converter 一键卸载程序        ${NC}"
echo -e "${CYAN}================================================${NC}"

# --- 交互式确认 ---
if [[ "$FORCE" != true && -t 0 ]]; then
  echo -e "${YELLOW}警告: 此操作将停止 ${SERVICE_NAME} 服务，并删除相关文件与配置！${NC}"
  if [[ "$KEEP_DATA" == true ]]; then
    echo -e "已指定保留数据目录: ${TARGET_DIR}/data"
  else
    echo -e "将完全清除安装目录: ${TARGET_DIR}"
  fi
  echo ""
  read -r -p "确定要继续卸载吗？[y/N]: " confirm
  case "$confirm" in
    [yY][eE][sS]|[yY])
      ;;
    *)
      echo "已取消卸载操作。"
      exit 0
      ;;
  esac
fi

# 1. 停止并禁用 Systemd 服务
log "1. 正在停止并禁用 ${SERVICE_NAME} 服务..."
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
  systemctl stop "$SERVICE_NAME" || true
  log "已停止 ${SERVICE_NAME} 服务。"
fi

if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
  systemctl disable "$SERVICE_NAME" || true
  log "已禁用 ${SERVICE_NAME} 开机自启。"
fi

# 2. 清理可能残留的后台进程
log "2. 检查并清理残留进程..."
pkill -9 -f "app.main" 2>/dev/null || true

# 3. 移除 Systemd 配置文件
log "3. 正在移除 Systemd 服务单元文件..."
if [[ -f "$SERVICE_FILE" ]]; then
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload || true
  systemctl reset-failed 2>/dev/null || true
  log "已移除服务配置文件: $SERVICE_FILE"
else
  log "未检测到服务文件 ($SERVICE_FILE)，跳过。"
fi

# 4. 清理安装目录与文件
log "4. 正在清理程序文件与目录..."
if [[ -d "$TARGET_DIR" ]]; then
  if [[ "$KEEP_DATA" == true && -d "${TARGET_DIR}/data" ]]; then
    log "正在清理程序文件（保留数据目录: ${TARGET_DIR}/data）..."
    find "$TARGET_DIR" -mindepth 1 -maxdepth 1 ! -name 'data' -exec rm -rf {} +
    log "已保留数据目录: ${TARGET_DIR}/data"
  else
    rm -rf "$TARGET_DIR"
    log "已删除安装目录: $TARGET_DIR"
  fi
else
  log "未检测到安装目录 ($TARGET_DIR)，跳过。"
fi

# 5. 清理临时文件
rm -f /tmp/singbox-sub-converter.*.tar.gz 2>/dev/null || true

echo ""
echo -e "${GREEN}------------------------------------------------${NC}"
success "singbox-sub-converter 服务已完全卸载并清理完毕！"
echo -e "${GREEN}------------------------------------------------${NC}"
