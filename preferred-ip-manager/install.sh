#!/usr/bin/env bash
#
# install.sh
# preferred-ip-manager 测速与优选定时任务 Systemd 服务一键安装与管理脚本
#
# 功能：
# 1. 自动检测系统环境，安装 Python 运行依赖与测速核心 (cfst, process_ips.py, warp_tester.py, telegram_tool.py) 到 /usr/local/bin
# 2. 支持在安装时直接指定代理参数 (--proxy / --tg-proxy)，供 Telegram 资源下载与加速
# 3. 部署 Systemd Timer 定时器，每天北京时间凌晨 02:00 至 06:00 随机时间点执行测速
# 4. 测速时默认从 Telegram 频道抓取最新候选 IP，测速后默认自动推送至 Cloudflare Workers 订阅端
# 5. 提供完整生命周期管理 (--install, --uninstall, --status, --run-now, --logs)
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

# ===================== Paths & Constants =====================
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")
SERVICE_NAME="preferred-ip-updater"
CONF_DIR="/etc/preferred-ip-manager"
CONFIG_FILE="${CONF_DIR}/config.env"
DATA_DIR="/var/lib/preferred-ip-manager"
INSTALL_SHARE_DIR="/usr/local/share/preferred-ip-manager"
BIN_DIR="/usr/local/bin"

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"

ACTION="install"
ASSUME_YES=false

# 可选自定义配置项
PROXY_ARG="${PROXY:-${TG_PROXY:-}}"
MODE_ARG="speed"
PORTS_ARG="443"
CONCURRENCY_ARG="200"
MIN_SPEED_ARG="5.0"
MAX_DELAY_ARG="300"
MAX_LOSS_ARG="1.0"
TOP_COUNT_ARG="20"
CFST_URL_ARG="https://movies.jackyang.cc.cd/download?size=200"

show_help() {
  echo -e "${CYAN}${BOLD}preferred-ip-manager 优选测速与 Systemd 定时服务管理脚本${NC}"
  echo ""
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "核心操作命令:"
  echo "  --install                   安装测速组件与 Python 依赖至 /usr/local/bin 并注册每日定时服务 (默认)"
  echo "  --update, --upgrade         平滑升级测速脚本、核心模块与 CLI 工具 (完全保留已有配置与数据)"
  echo "  --uninstall                 停止并卸载 Systemd 定时器与服务，清理安装文件与配置"
  echo "  --run-now, --test           立即触发一次优选测速与订阅端推送任务"
  echo "  --status                    查看 Systemd 服务与定时器运行状态、下一次触发时间"
  echo "  --logs                      查看最近的测速服务执行日志 (journalctl)"
  echo "  -h, --help                  显示本帮助菜单"
  echo ""
  echo "自定义配置选项 (搭配 --install 或独立使用以写入 /etc/preferred-ip-manager/config.env):"
  echo "  -p, --proxy, --tg-proxy URL 指定网络请求代理 (用于 Telegram 频道下载及订阅节点获取/推送，如 socks5h://127.0.0.1:1080、socks5://127.0.0.1:1080 或 http://127.0.0.1:7890)"
  echo "  --ports PORTS               待测试端口列表 (默认: 443)"
  echo "  --mode MODE                 测速模式: speed (大带宽模式) 或 latency (延迟模式) (默认: speed)"
  echo "  --concurrency NUM           并发测速线程数 (默认: 200)"
  echo "  --min-speed SPEED           大带宽测速达标下限 MB/s (默认: 5.0)"
  echo "  --max-delay MS              最大允许延迟上限 (默认: 300)"
  echo "  --top NUM                   最终保留的最优节点数量 (默认: 20)"
  echo "  --url, --speedtest-url URL  自定义测速下载 URL (默认: https://movies.jackyang.cc.cd/download?size=200)"
  echo "  -y, --yes                   非交互模式，跳过确认提示直接执行"
  echo ""
  echo "定时触发规则:"
  echo "  • 触发周期: 每日北京时间 (CST, UTC+8) 凌晨 02:00 ~ 06:00"
  echo "  • 触发策略: RandomizedDelaySec=4h (4小时内随机时刻执行，避免请求峰值)"
  echo "  • 候选来源: 自动从 Telegram 频道拉取最新 IP 列表并合并在线订阅/历史池"
  echo "  • 同步策略: 测速完成后默认自动推送结果至 Cloudflare Workers 订阅服务器"
  echo ""
  echo "使用示例:"
  echo "  1. 默认安装定时测速服务:"
  echo "     sudo bash $0 --install"
  echo ""
  echo "  2. 平滑更新安装最新版本 (保留配置与数据):"
  echo "     sudo bash $0 --update"
  echo ""
  echo "  3. 安装定时服务并指定 SOCKS5 代理用于 Telegram 抓取与订阅同步:"
  echo "     sudo bash $0 --install --proxy socks5h://127.0.0.1:1080"
  echo ""
  echo "  4. 查看定时器计划与下一次触发时间:"
  echo "     sudo bash $0 --status"
}

check_if_running_as_root() {
  if [[ $EUID -ne 0 ]]; then
    error "请使用 root 权限运行此脚本 (例如: sudo $0)"
    exit 1
  fi
}

detect_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)
      echo "amd64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    armv7l|armhf)
      echo "arm"
      ;;
    *)
      echo "$arch"
      ;;
  esac
}

install_system_packages() {
  log "正在检查系统基础包管理器与 Python3 环境..."
  if command -v apt-get > /dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y > /dev/null 2>&1 || true
    apt-get install -y python3 python3-pip python3-venv curl tar tzdata > /dev/null 2>&1 || true
  elif command -v dnf > /dev/null 2>&1; then
    dnf install -y python3 python3-pip curl tar tzdata > /dev/null 2>&1 || true
  elif command -v yum > /dev/null 2>&1; then
    yum install -y python3 python3-pip curl tar tzdata > /dev/null 2>&1 || true
  elif command -v pacman > /dev/null 2>&1; then
    pacman -Sy --noconfirm python python-pip curl tar tzdata > /dev/null 2>&1 || true
  elif command -v apk > /dev/null 2>&1; then
    apk add --no-cache python3 py3-pip curl tar tzdata > /dev/null 2>&1 || true
  fi
}

setup_python_environment() {
  log "正在配置 Python 依赖环境 (requests, telethon, python-socks)..."
  mkdir -p "$INSTALL_SHARE_DIR"

  local venv_dir="${INSTALL_SHARE_DIR}/.venv"
  local py_exec="python3"

  # 为保证 Debian 12 / Ubuntu 24.04 (PEP 668) 兼容性，优先使用专用 venv
  if python3 -m venv "$venv_dir" 2>/dev/null; then
    py_exec="${venv_dir}/bin/python"
    log "已创建专用虚拟环境: ${venv_dir}"
  elif [[ -f "/usr/bin/python3" ]]; then
    py_exec="/usr/bin/python3"
  fi

  # 安装依赖
  log "正在安装/更新 Python 依赖库..."
  if ! "$py_exec" -m pip install --upgrade pip > /dev/null 2>&1; then
    true
  fi

  local pip_flags=()
  if "$py_exec" -m pip install --help 2>&1 | grep -q "break-system-packages"; then
    pip_flags+=("--break-system-packages")
  fi

  if ! "$py_exec" -m pip install "${pip_flags[@]}" requests telethon "python-socks[asyncio]" > /dev/null 2>&1; then
    warn "pip 安装遇到警告，尝试直接安装 requests telethon python-socks..."
    "$py_exec" -m pip install requests telethon "python-socks[asyncio]" || true
  fi

  if ! "$py_exec" -c "import requests" > /dev/null 2>&1; then
    error "Python requests 模块安装失败，请手动执行 pip3 install requests"
    exit 1
  fi
  success "Python 依赖环境检查与就绪！"
  echo "$py_exec"
}

install_cfst_binary() {
  local target_cfst="${BIN_DIR}/cfst"
  local arch
  arch=$(detect_arch)

  mkdir -p "$BIN_DIR"

  # 1. 若当前目录已有 cfst 且为匹配架构，直接复制
  if [[ -f "${SCRIPT_DIR}/cfst" ]]; then
    cp -f "${SCRIPT_DIR}/cfst" "$target_cfst"
    chmod +x "$target_cfst"
    if "$target_cfst" -v > /dev/null 2>&1 || "$target_cfst" --help > /dev/null 2>&1; then
      log "已成功部署本地 cfst 测速二进制至 ${target_cfst}"
      return 0
    fi
  fi

  # 2. 从 GitHub Releases 自动拉取匹配架构的 CloudflareSpeedTest
  log "正在从 GitHub 获取最新 CloudflareSpeedTest (${arch})..."
  local cfst_tar="/tmp/cfst_${arch}.tar.gz"
  local cfst_url="https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/CloudflareST_linux_${arch}.tar.gz"
  local cfst_mirror="https://ghproxy.net/${cfst_url}"

  if curl -fsSL --connect-timeout 10 -m 60 "$cfst_url" -o "$cfst_tar" 2>/dev/null || \
     curl -fsSL --connect-timeout 10 -m 60 "$cfst_mirror" -o "$cfst_tar" 2>/dev/null; then
    tar -zxf "$cfst_tar" -C /tmp CloudflareST 2>/dev/null || tar -zxf "$cfst_tar" -C /tmp cfst 2>/dev/null || true
    if [[ -f "/tmp/CloudflareST" ]]; then
      mv -f "/tmp/CloudflareST" "$target_cfst"
    elif [[ -f "/tmp/cfst" ]]; then
      mv -f "/tmp/cfst" "$target_cfst"
    fi
    rm -f "$cfst_tar" 2>/dev/null || true
    chmod +x "$target_cfst"
    log "已通过网络成功下载并安装 cfst 至 ${target_cfst}"
    return 0
  fi

  if [[ -f "$target_cfst" ]]; then
    chmod +x "$target_cfst"
    return 0
  fi

  warn "未能自动下载 CloudflareST，若系统中已有 cfst，请放置到 ${target_cfst}"
}

install_scripts() {
  local py_exec="$1"

  mkdir -p "$BIN_DIR"
  mkdir -p "$INSTALL_SHARE_DIR"
  mkdir -p "$DATA_DIR"
  mkdir -p "$CONF_DIR"

  log "正在安装测速脚本与核心模块至 ${BIN_DIR} 与 ${INSTALL_SHARE_DIR} ..."

  # 复制 Python 脚本至共享目录与 /usr/local/bin
  for file in process_ips.py warp_tester.py telegram_tool.py; do
    if [[ -f "${SCRIPT_DIR}/${file}" ]]; then
      cp -f "${SCRIPT_DIR}/${file}" "${INSTALL_SHARE_DIR}/${file}"
      cp -f "${SCRIPT_DIR}/${file}" "${BIN_DIR}/${file}"
      chmod +x "${BIN_DIR}/${file}"
    elif [[ -f "${INSTALL_SHARE_DIR}/${file}" ]]; then
      cp -f "${INSTALL_SHARE_DIR}/${file}" "${BIN_DIR}/${file}"
      chmod +x "${BIN_DIR}/${file}"
    fi
  done

  # 创建全局 CLI 包装命令: /usr/local/bin/preferred-ip-tester
  cat <<EOF > "${BIN_DIR}/preferred-ip-tester"
#!/usr/bin/env bash
# preferred-ip-tester CLI 快捷包装命令
export CFST_BIN="${BIN_DIR}/cfst"

VENV_PYTHON="${INSTALL_SHARE_DIR}/.venv/bin/python3"
if [[ -x "\$VENV_PYTHON" ]]; then
  PYTHON_BIN="\$VENV_PYTHON"
elif [[ -x "${INSTALL_SHARE_DIR}/.venv/bin/python" ]]; then
  PYTHON_BIN="${INSTALL_SHARE_DIR}/.venv/bin/python"
elif command -v python3 > /dev/null 2>&1; then
  PYTHON_BIN="\$(command -v python3)"
else
  PYTHON_BIN="python3"
fi

exec "\$PYTHON_BIN" "${INSTALL_SHARE_DIR}/process_ips.py" "\$@"
EOF
  chmod +x "${BIN_DIR}/preferred-ip-tester"

  # 安装全局运维管理工具: /usr/local/bin/preferred-ip-manager 与 /usr/local/bin/preferred-ip
  if [[ -f "${SCRIPT_DIR}/preferred-ip-manager.sh" ]]; then
    cp -f "${SCRIPT_DIR}/preferred-ip-manager.sh" "${BIN_DIR}/preferred-ip-manager"
    chmod +x "${BIN_DIR}/preferred-ip-manager"
    ln -sf "${BIN_DIR}/preferred-ip-manager" "${BIN_DIR}/preferred-ip"
  fi

  success "核心组件与 CLI 命令安装完成: ${BIN_DIR}/preferred-ip-manager, ${BIN_DIR}/preferred-ip-tester"
}

set_config_value() {
  local key="$1"
  local val="$2"
  local file="$3"

  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$file"
  else
    echo "${key}=\"${val}\"" >> "$file"
  fi
}

configure_env() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log "正在生成配置文件: ${CONFIG_FILE} ..."
    cat <<EOF > "$CONFIG_FILE"
# ==============================================================================
# preferred-ip-manager 定时任务配置环境文件
# 路径: /etc/preferred-ip-manager/config.env
# ==============================================================================

# 优选目标模式: cdn (默认) 或 warp
TARGET="cdn"

# 测速模式: speed (大带宽模式) 或 latency (延迟模式)
MODE="${MODE_ARG}"

# 待测端口列表 (逗号分隔，默认测试 443 端口)
PORTS="${PORTS_ARG}"

# 并发测速线程数 (默认 200)
CONCURRENCY="${CONCURRENCY_ARG}"

# 带宽测速下限阀值 (MB/s，默认 5.0)
MIN_SPEED="${MIN_SPEED_ARG}"

# 延迟上限过滤 (ms，默认 300)
MAX_DELAY="${MAX_DELAY_ARG}"

# 丢包率上限过滤 (0.0~1.0，默认 1.0)
MAX_LOSS="${MAX_LOSS_ARG}"

# 保留的最优节点数量
TOP_COUNT="${TOP_COUNT_ARG}"

# 单 IP 下载测速时长 (秒)
DOWNLOAD_TIME="10"

# 下载测速达标数量
TEST_COUNT="20"

# 附加执行参数 (默认非交互自动推送)
EXTRA_ARGS="-y"

# 网络请求代理 (可选，用于 Telegram 频道下载及订阅节点获取/推送，如: socks5h://127.0.0.1:1080 或 http://127.0.0.1:7890)
PROXY="${PROXY_ARG}"

# 自定义测速文件下载 URL
CFST_URL="${CFST_URL_ARG}"

# Cloudflare Workers 订阅管理地址与更新 Token (用于测速完成后自动推送)
CF_SUB_URL="https://sub.19910417.xyz"
CF_SUB_TOKEN=""

# Telegram API 与 Session 配置 (可选，用于拉取 TG 频道测速文件)
# TG_API_ID=""
# TG_API_HASH=""
# TG_SESSION_PATH="/var/lib/preferred-ip-manager/tg_session"
EOF
    chmod 644 "$CONFIG_FILE"
    log "已生成配置: ${CONFIG_FILE}"
  else
    log "正在更新已有配置文件: ${CONFIG_FILE} ..."
    if [[ -n "$PROXY_ARG" ]]; then
      set_config_value "PROXY" "$PROXY_ARG" "$CONFIG_FILE"
      log "已更新网络请求代理配置: ${PROXY_ARG}"
    fi
    if [[ "$PORTS_ARG" != "443" ]]; then
      set_config_value "PORTS" "$PORTS_ARG" "$CONFIG_FILE"
    fi
    if [[ "$MODE_ARG" != "speed" ]]; then
      set_config_value "MODE" "$MODE_ARG" "$CONFIG_FILE"
    fi
    if [[ -n "$CFST_URL_ARG" ]]; then
      set_config_value "CFST_URL" "$CFST_URL_ARG" "$CONFIG_FILE"
    fi
  fi
}

install_systemd_service() {
  log "正在配置 Systemd 服务与定时器 (${SERVICE_NAME}) ..."

  # 确定 OnCalendar 语法 (优先使用 Asia/Shanghai，次选 18:00 UTC)
  local on_calendar="*-*-* 02:00:00 Asia/Shanghai"
  if command -v systemd-analyze > /dev/null 2>&1; then
    if ! systemd-analyze calendar "$on_calendar" > /dev/null 2>&1; then
      on_calendar="*-*-* 18:00:00 UTC"
    fi
  fi

  # 1. 编写 Service 文件
  cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Preferred IP Daily Speed Test & Worker Sync Service
Documentation=https://github.com/JayYang1991/vps-utils
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${DATA_DIR}
EnvironmentFile=-${CONFIG_FILE}
ExecStart=/usr/local/bin/preferred-ip-tester --target \$TARGET --mode \$MODE --ports \$PORTS --concurrency \$CONCURRENCY --min-speed \$MIN_SPEED --max-delay \$MAX_DELAY --max-loss \$MAX_LOSS --top \$TOP_COUNT --download-time \$DOWNLOAD_TIME --test-count \$TEST_COUNT --url "\$CFST_URL" \$EXTRA_ARGS
TimeoutStartSec=1800
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SERVICE_FILE"

  # 2. 编写 Timer 文件 (北京时间 02:00~06:00 随机时间点)
  cat <<EOF > "$TIMER_FILE"
[Unit]
Description=Daily Preferred IP Speed Test & Worker Sync Timer (02:00 - 06:00 CST)
Documentation=https://github.com/JayYang1991/vps-utils

[Timer]
OnCalendar=${on_calendar}
RandomizedDelaySec=4h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  chmod 644 "$TIMER_FILE"

  # 3. 重载并启动 Timer
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.timer"
  systemctl restart "${SERVICE_NAME}.timer"

  success "Systemd 服务与定时器配置成功！"
}

uninstall_service() {
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

  # 提示是否清理二进制与数据文件
  if [[ "$ASSUME_YES" == "true" ]]; then
    rm -f "${BIN_DIR}/preferred-ip-tester" "${BIN_DIR}/preferred-ip-manager" "${BIN_DIR}/preferred-ip" 2>/dev/null || true
    rm -rf "$INSTALL_SHARE_DIR" "$DATA_DIR" "$CONF_DIR" 2>/dev/null || true
    log "已清理所有安装组件、配置与数据文件。"
  else
    rm -f "${BIN_DIR}/preferred-ip-tester" "${BIN_DIR}/preferred-ip-manager" "${BIN_DIR}/preferred-ip" 2>/dev/null || true
    read -r -p "是否同时删除配置文件与数据目录 (${CONF_DIR}, ${DATA_DIR})? [y/N]: " del_data
    if [[ "$del_data" =~ ^[Yy]$ ]]; then
      rm -rf "$INSTALL_SHARE_DIR" "$DATA_DIR" "$CONF_DIR" 2>/dev/null || true
      log "已清理所有配置与数据文件。"
    else
      log "已保留配置文件: ${CONF_DIR}"
    fi
  fi

  success "${SERVICE_NAME} 定时服务卸载完成！"
}

show_status() {
  echo ""
  echo "================================================================"
  echo -e "       ${CYAN}${BOLD}preferred-ip-updater Systemd 定时器与服务状态${NC}"
  echo "================================================================"

  if [[ -f "$TIMER_FILE" ]]; then
    echo -e " 定时器状态   : $(systemctl is-active "${SERVICE_NAME}.timer" 2>/dev/null || echo '未激活')"
    echo -e " 定时器开机自启: $(systemctl is-enabled "${SERVICE_NAME}.timer" 2>/dev/null || echo '未启用')"
    echo ""
    echo -e "${YELLOW}--- 定时器计划时间列表 (systemctl list-timers) ---${NC}"
    systemctl list-timers "${SERVICE_NAME}.timer" --no-pager || true
  else
    echo -e " 定时器状态   : ${RED}未安装${NC}"
  fi

  echo ""
  echo "================================================================"
  if [[ -f "$SERVICE_FILE" ]]; then
    echo -e " 服务状态     : $(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || echo 'inactive')"
    echo -e " 配置文件     : ${CONFIG_FILE}"
    if [[ -f "$CONFIG_FILE" ]]; then
      local proxy_cfg
      proxy_cfg=$(grep '^PROXY=' "$CONFIG_FILE" | cut -d= -f2- | tr -d '"' || echo "")
      if [[ -z "$proxy_cfg" ]]; then
        proxy_cfg=$(grep '^TG_PROXY=' "$CONFIG_FILE" | cut -d= -f2- | tr -d '"' || echo "")
      fi
      if [[ -n "$proxy_cfg" ]]; then
        echo -e " 网络请求代理 : ${GREEN}${proxy_cfg}${NC}"
      else
        echo -e " 网络请求代理 : 未配置 (直连)"
      fi
      local cfst_url_cfg
      cfst_url_cfg=$(grep '^CFST_URL=' "$CONFIG_FILE" | cut -d= -f2- | tr -d '"' || echo "")
      echo -e " 测速 URL     : ${cfst_url_cfg:-$CFST_URL_ARG}"
    fi
    echo -e " CLI 测试命令 : preferred-ip-tester"
  fi
  echo "================================================================"
}

run_test_now() {
  log "正在立即触发一次优选测速与订阅端推送任务..."
  if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    warn "检测到当前有测速服务正在运行中..."
  fi

  systemctl start "${SERVICE_NAME}.service"
  log "任务已触发，正在跟踪实时运行日志 (按 Ctrl+C 可退出跟踪，后台任务不受影响)..."
  journalctl -u "${SERVICE_NAME}.service" -f -n 50 --no-pager
}

show_logs() {
  log "查看 ${SERVICE_NAME} 最近运行日志..."
  journalctl -u "${SERVICE_NAME}.service" -f -n 50 --no-pager
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install)
        ACTION="install"
        shift
        ;;
      --update|--upgrade)
        ACTION="update"
        shift
        ;;
      --uninstall)
        ACTION="uninstall"
        shift
        ;;
      --status)
        ACTION="status"
        shift
        ;;
      --run-now|--test)
        ACTION="run-now"
        shift
        ;;
      --logs)
        ACTION="logs"
        shift
        ;;
      -p|--proxy|--tg-proxy)
        PROXY_ARG="$2"
        shift 2
        ;;
      --ports)
        PORTS_ARG="$2"
        shift 2
        ;;
      --mode)
        MODE_ARG="$2"
        shift 2
        ;;
      --concurrency)
        CONCURRENCY_ARG="$2"
        shift 2
        ;;
      --min-speed)
        MIN_SPEED_ARG="$2"
        shift 2
        ;;
      --max-delay)
        MAX_DELAY_ARG="$2"
        shift 2
        ;;
      --top)
        TOP_COUNT_ARG="$2"
        shift 2
        ;;
      --url|--speedtest-url)
        CFST_URL_ARG="$2"
        shift 2
        ;;
      -y|--yes)
        ASSUME_YES=true
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        error "未知参数: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

main() {
  parse_arguments "$@"

  case "$ACTION" in
    install)
      check_if_running_as_root
      install_system_packages
      local py_exec
      py_exec=$(setup_python_environment)
      install_cfst_binary
      install_scripts "$py_exec"
      configure_env
      install_systemd_service
      show_status
      echo ""
      echo -e "${GREEN}================================================================${NC}"
      echo -e "${GREEN}      preferred-ip-manager 优选测速定时任务安装成功！${NC}"
      echo -e "${GREEN}================================================================${NC}"
      echo -e " • 执行周期 : 每天北京时间 02:00 ~ 06:00 随机时刻自动测速"
      echo -e " • 候选数据 : 自动从 Telegram 频道拉取最新 IP 并合并在线/历史源"
      echo -e " • 测速地址 : ${CFST_URL_ARG}"
      echo -e " • 订阅同步 : 测速完成后默认自动推送结果至 Cloudflare Workers 订阅端"
      if [[ -n "$PROXY_ARG" ]]; then
        echo -e " • 网络请求代理 : ${GREEN}${PROXY_ARG}${NC}"
      else
        echo -e " • 网络请求代理 : 未配置 (直连)"
      fi
      echo -e " • 运维管理 : ${CYAN}preferred-ip-manager status | run | logs | restart${NC}"
      echo -e " • 快速测速 : ${CYAN}preferred-ip-tester${NC}"
      echo -e " • 配置文件 : ${CONFIG_FILE}"
      echo -e "${GREEN}================================================================${NC}"
      ;;
    update|upgrade)
      check_if_running_as_root
      log "正在平滑升级 preferred-ip-manager 核心组件 (保留现有配置与数据)..."
      local py_exec
      py_exec=$(setup_python_environment)
      install_cfst_binary
      install_scripts "$py_exec"
      # 若配置文件已存在，确保兼容升级旧配置项 (如 TG_PROXY -> PROXY)
      if [[ -f "$CONFIG_FILE" ]]; then
        if grep -q "^TG_PROXY=" "$CONFIG_FILE" 2>/dev/null && ! grep -q "^PROXY=" "$CONFIG_FILE" 2>/dev/null; then
          sed -i 's/^TG_PROXY=/PROXY=/g' "$CONFIG_FILE"
          log "已自动兼容升级配置文件代理项: TG_PROXY -> PROXY"
        fi
      else
        configure_env
      fi
      # 刷新 systemd 并保证定时器状态正常
      if [[ -f "$SERVICE_FILE" ]] && [[ -f "$TIMER_FILE" ]]; then
        systemctl daemon-reload
        if systemctl is-enabled --quiet "${SERVICE_NAME}.timer" 2>/dev/null; then
          systemctl restart "${SERVICE_NAME}.timer" 2>/dev/null || true
        fi
      else
        install_systemd_service
      fi
      show_status
      echo ""
      echo -e "${GREEN}================================================================${NC}"
      echo -e "${GREEN}      preferred-ip-manager 核心组件与命令已平滑升级成功！${NC}"
      echo -e "${GREEN}================================================================${NC}"
      echo -e " • 配置保护 : 已完好保留现有配置文件 (${CONFIG_FILE})"
      echo -e " • 数据保护 : 已完好保留历史测速数据 (${DATA_DIR})"
      echo -e " • 定时计划 : 守护定时器正常保持运行"
      echo -e " • 运维命令 : ${CYAN}preferred-ip-manager status | run | update${NC}"
      echo -e "${GREEN}================================================================${NC}"
      ;;
    uninstall)
      check_if_running_as_root
      uninstall_service
      ;;
    status)
      show_status
      ;;
    run-now)
      check_if_running_as_root
      run_test_now
      ;;
    logs)
      show_logs
      ;;
  esac
}

main "$@"
