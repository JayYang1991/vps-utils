#!/usr/bin/env bash
#
# preferred-ip-manager.sh
# preferred-ip-updater Systemd 定时服务与优选测速日常运维 CLI 工具
#
# 安装后可作为全局命令运行: preferred-ip-manager [COMMAND] 或 preferred-ip [COMMAND]
#
# GitHub: https://github.com/JayYang1991/vps-utils
#

set -eo pipefail

# ===================== Color Output =====================
if [[ -t 1 ]] && [[ -n "$TERM" ]] && [[ "$TERM" != "dumb" ]] && command -v tput > /dev/null 2>&1; then
  RED=$(tput setaf 1 2> /dev/null || echo "")
  GREEN=$(tput setaf 2 2> /dev/null || echo "")
  YELLOW=$(tput setaf 3 2> /dev/null || echo "")
  CYAN=$(tput setaf 6 2> /dev/null || echo "")
  BOLD=$(tput bold 2> /dev/null || echo "")
  NC=$(tput sgr0 2> /dev/null || echo "")
else
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'
fi

log() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success() { echo -e "${GREEN}${BOLD}[SUCCESS]${NC} $1" >&2; }

SERVICE_NAME="preferred-ip-updater"
CONF_DIR="/etc/preferred-ip-manager"
CONFIG_FILE="${CONF_DIR}/config.env"
DATA_DIR="/var/lib/preferred-ip-manager"
INSTALL_SHARE_DIR="/usr/local/share/preferred-ip-manager"
BIN_DIR="/usr/local/bin"

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"

check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "该操作需要 root 权限，请使用: sudo $0 $*"
    exit 1
  fi
}

show_help() {
  echo -e "${CYAN}${BOLD}preferred-ip-manager 优选测速与 Systemd 定时服务运维工具${NC}"
  echo ""
  echo "Usage: preferred-ip-manager <command> [options]"
  echo "       preferred-ip <command> [options]"
  echo ""
  echo "日常运维命令:"
  echo "  status, info                查看定时器与服务运行状态、下次触发时刻及当前配置"
  echo "  run, run-now, test          立即触发一次测速同步任务并实时跟踪 journalctl 日志"
  echo "  logs, log [-f] [-n NUM]     查看最近的测速运行日志 (默认 50 条，-f 实时跟踪)"
  echo "  restart                     重启 Systemd 定时器与服务"
  echo "  start                       启动定时器 (启用定时计划)"
  echo "  stop                        停止定时器 (暂停定时计划)"
  echo "  enable                      设置定时器开机自启"
  echo "  disable                     取消定时器开机自启"
  echo "  config, env [--edit]        查看当前任务配置环境文件 (--edit 可直接编辑)"
  echo "  speedtest, test-cli [ARGS]  在前台直接运行交互式测速工具 (调用 preferred-ip-tester)"
  echo "  uninstall [-y]              一键卸载定时器、服务与安装组件"
  echo "  help, -h, --help            显示本帮助信息"
  echo ""
  echo "使用示例:"
  echo "  preferred-ip-manager status           # 查看定时器计划与服务状态"
  echo "  preferred-ip-manager run              # 立即执行一次测速与订阅端推送"
  echo "  preferred-ip-manager logs -f          # 实时查看测速运行日志"
  echo "  preferred-ip-manager config           # 查看当前配置文件内容"
  echo "  preferred-ip-manager restart          # 重启定时器"
}

cmd_status() {
  echo ""
  echo "================================================================"
  echo -e "       ${CYAN}${BOLD}preferred-ip-updater Systemd 定时器与服务状态${NC}"
  echo "================================================================"

  if [[ -f "$TIMER_FILE" ]]; then
    local timer_active
    local timer_enabled
    timer_active=$(systemctl is-active "${SERVICE_NAME}.timer" 2>/dev/null || echo 'inactive')
    timer_enabled=$(systemctl is-enabled "${SERVICE_NAME}.timer" 2>/dev/null || echo 'disabled')
    
    if [[ "$timer_active" == "active" ]]; then
      echo -e " 定时器状态   : ${GREEN}active (运行中)${NC}"
    else
      echo -e " 定时器状态   : ${YELLOW}${timer_active}${NC}"
    fi
    echo -e " 开机自启     : ${timer_enabled}"
    echo ""
    echo -e "${YELLOW}--- 定时器计划触发列表 (systemctl list-timers) ---${NC}"
    systemctl list-timers "${SERVICE_NAME}.timer" --no-pager 2>/dev/null || true
  else
    echo -e " 定时器状态   : ${RED}未安装${NC}"
  fi

  echo ""
  echo "================================================================"
  if [[ -f "$SERVICE_FILE" ]]; then
    local srv_active
    srv_active=$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || echo 'inactive')
    echo -e " 服务状态     : ${srv_active}"
    echo -e " 配置文件     : ${CONFIG_FILE}"
    if [[ -f "$CONFIG_FILE" ]]; then
      local tg_proxy_cfg
      tg_proxy_cfg=$(grep '^TG_PROXY=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "")
      if [[ -n "$tg_proxy_cfg" ]]; then
        echo -e " Telegram 代理: ${GREEN}${tg_proxy_cfg}${NC}"
      else
        echo -e " Telegram 代理: 未配置 (直连)"
      fi
      local mode_cfg
      mode_cfg=$(grep '^MODE=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "speed")
      local ports_cfg
      ports_cfg=$(grep '^PORTS=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "443")
      local min_speed_cfg
      min_speed_cfg=$(grep '^MIN_SPEED=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "5.0")
      echo -e " 测速策略     : 模式=${mode_cfg}, 端口=${ports_cfg}, 达标速度=${min_speed_cfg}MB/s"
    fi
    echo -e " CLI 测试命令 : preferred-ip-tester"
  fi
  echo "================================================================"
}

cmd_run() {
  check_root
  log "正在立即触发一次优选测速与订阅端推送任务..."
  if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    warn "检测到当前有测速服务正在运行中..."
  fi

  systemctl start "${SERVICE_NAME}.service"
  log "任务已触发，正在跟踪实时运行日志 (按 Ctrl+C 可退出跟踪，后台任务不受影响)..."
  journalctl -u "${SERVICE_NAME}.service" -f -n 50 --no-pager
}

cmd_logs() {
  local follow=false
  local lines=50

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--follow)
        follow=true
        shift
        ;;
      -n|--lines)
        lines="$2"
        shift 2
        ;;
      *)
        if [[ "$1" =~ ^[0-9]+$ ]]; then
          lines="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ "$follow" == "true" ]]; then
    log "正在实时查看 ${SERVICE_NAME} 运行日志 (按 Ctrl+C 退出)..."
    journalctl -u "${SERVICE_NAME}.service" -f -n "$lines" --no-pager
  else
    log "正在查看最近 ${lines} 条 ${SERVICE_NAME} 运行日志..."
    journalctl -u "${SERVICE_NAME}.service" -n "$lines" --no-pager
  fi
}

cmd_restart() {
  check_root
  log "正在重启 ${SERVICE_NAME} 定时器与服务..."
  systemctl restart "${SERVICE_NAME}.timer"
  success "定时器已成功重启！"
  cmd_status
}

cmd_start() {
  check_root
  log "正在启动 ${SERVICE_NAME} 定时器..."
  systemctl start "${SERVICE_NAME}.timer"
  success "定时器已启动！"
}

cmd_stop() {
  check_root
  log "正在停止 ${SERVICE_NAME} 定时器..."
  systemctl stop "${SERVICE_NAME}.timer"
  warn "定时器已暂停调度。"
}

cmd_enable() {
  check_root
  systemctl enable "${SERVICE_NAME}.timer"
  success "定时器开机自启已启用。"
}

cmd_disable() {
  check_root
  systemctl disable "${SERVICE_NAME}.timer"
  warn "定时器开机自启已禁用。"
}

cmd_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    error "配置文件不存在: ${CONFIG_FILE}"
    exit 1
  fi

  if [[ "$1" == "--edit" || "$1" == "-e" ]]; then
    check_root
    local editor="${EDITOR:-nano}"
    if ! command -v "$editor" > /dev/null 2>&1; then
      editor="vi"
    fi
    "$editor" "$CONFIG_FILE"
  else
    echo -e "${CYAN}${BOLD}--- 配置文件路径: ${CONFIG_FILE} ---${NC}"
    cat "$CONFIG_FILE"
    echo -e "${CYAN}${BOLD}------------------------------------------------${NC}"
    echo "💡 提示: 可通过 'sudo preferred-ip-manager config --edit' 直接编辑配置文件。"
  fi
}

cmd_speedtest() {
  if command -v preferred-ip-tester > /dev/null 2>&1; then
    exec preferred-ip-tester "$@"
  elif [[ -x "${BIN_DIR}/preferred-ip-tester" ]]; then
    exec "${BIN_DIR}/preferred-ip-tester" "$@"
  else
    error "未找到 preferred-ip-tester 可执行文件，请先安装服务。"
    exit 1
  fi
}

cmd_uninstall() {
  check_root
  local assume_yes=false
  if [[ "$1" == "-y" || "$1" == "--yes" ]]; then
    assume_yes=true
  fi

  log "正在停止并卸载 ${SERVICE_NAME} 服务与定时器..."
  if systemctl is-active --quiet "${SERVICE_NAME}.timer" 2>/dev/null; then
    systemctl stop "${SERVICE_NAME}.timer" || true
  fi
  if systemctl is-enabled --quiet "${SERVICE_NAME}.timer" 2>/dev/null; then
    systemctl disable "${SERVICE_NAME}.timer" || true
  fi

  if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    systemctl stop "${SERVICE_NAME}.service" || true
  fi
  if systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    systemctl disable "${SERVICE_NAME}.service" || true
  fi

  rm -f "$SERVICE_FILE" "$TIMER_FILE" 2>/dev/null || true
  systemctl daemon-reload

  rm -f "${BIN_DIR}/preferred-ip-manager" "${BIN_DIR}/preferred-ip" 2>/dev/null || true
  rm -f "${BIN_DIR}/preferred-ip-tester" "${BIN_DIR}/preferred-ip-sync" 2>/dev/null || true

  if [[ "$assume_yes" == "true" ]]; then
    rm -rf "$INSTALL_SHARE_DIR" "$DATA_DIR" "$CONF_DIR" 2>/dev/null || true
    log "已清理所有安装组件、配置与数据文件。"
  else
    read -r -p "是否同时删除配置文件与数据目录 (${CONF_DIR}, ${DATA_DIR})? [y/N]: " del_data
    if [[ "$del_data" =~ ^[Yy]$ ]]; then
      rm -rf "$INSTALL_SHARE_DIR" "$DATA_DIR" "$CONF_DIR" 2>/dev/null || true
      log "已清理所有配置与数据文件。"
    else
      log "已保留配置文件: ${CONF_DIR}"
    fi
  fi

  success "${SERVICE_NAME} 定时服务与运维工具卸载完成！"
}

main() {
  local cmd="${1:-status}"
  shift || true

  case "$cmd" in
    status|info|--status)
      cmd_status "$@"
      ;;
    run|run-now|test|--run-now|--test)
      cmd_run "$@"
      ;;
    logs|log|--logs)
      cmd_logs "$@"
      ;;
    restart)
      cmd_restart "$@"
      ;;
    start)
      cmd_start "$@"
      ;;
    stop)
      cmd_stop "$@"
      ;;
    enable)
      cmd_enable "$@"
      ;;
    disable)
      cmd_disable "$@"
      ;;
    config|env)
      cmd_config "$@"
      ;;
    speedtest|test-cli)
      cmd_speedtest "$@"
      ;;
    uninstall|--uninstall)
      cmd_uninstall "$@"
      ;;
    help|-h|--help)
      show_help
      ;;
    *)
      error "未知命令: $cmd"
      show_help
      exit 1
      ;;
  esac
}

main "$@"
