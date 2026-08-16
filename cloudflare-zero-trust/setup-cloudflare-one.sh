#!/usr/bin/env bash
#
# setup-cloudflare-one.sh
# VPS 上 Cloudflare One / Zero Trust 流量出口 NAT 转发配置脚本
# 支持自动开启/清除内核 IP 转发及 iptables NAT MASQUERADE 规则，并通过 Systemd 服务与 netfilter 规则实现双重开机自动持久化。

set -e

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

SYSCTL_CONF="/etc/sysctl.d/99-cloudflare-one-nat.conf"
SERVICE_FILE="/etc/systemd/system/cloudflare-one-nat.service"
DEST_SCRIPT="/usr/local/bin/setup-cloudflare-one.sh"

show_help() {
  echo "Usage: $0 [MODE] [OPTIONS]"
  echo ""
  echo "模式 (默认为 --setup):"
  echo "  -c, --setup, --enable   开启并配置 VPS 上 Cloudflare One NAT 转发规则 (含开机持久化服务)"
  echo "  -u, --unset, --disable   清除并还原 VPS 上 Cloudflare One NAT 转发规则 (并清理开机服务)"
  echo "  -s, --status            查看当前内核转发、iptables NAT 与 Systemd 持久化服务状态"
  echo "  -h, --help              显示此帮助信息"
  echo ""
  echo "选项:"
  echo "  -i, --interface <IF>    指定 VPS 的外网网卡名称 (默认自动检测，如 eth0, ens3)"
  echo "  -w, --warp-if <IF>      指定入站隧道网卡名称 (默认: auto。若存在 warp0 则绑定 warp0，否则使用 any 通用转发)"
  echo ""
  echo "示例:"
  echo "  sudo bash $0 --setup"
  echo "  sudo bash $0 --setup -i eth0 -w warp0"
  echo "  sudo bash $0 --setup -w any"
  echo "  sudo bash $0 --status"
  echo "  sudo bash $0 --unset"
}

# Auto-detect default WAN interface
detect_wan_if() {
  local wan_if=""
  if command -v ip &>/dev/null; then
    wan_if=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n 1)
  fi
  if [[ -z "$wan_if" ]]; then
    wan_if="eth0"
  fi
  echo "$wan_if"
}

MODE="setup"
WAN_IF=""
WARP_IF="auto"

while [[ $# -gt 0 ]]; do
  case $1 in
    -c | --setup | --config | --enable)
      MODE="setup"
      shift 1
      ;;
    -u | --unset | --disable | --clean)
      MODE="unset"
      shift 1
      ;;
    -s | --status)
      MODE="status"
      shift 1
      ;;
    -i | --interface)
      WAN_IF="$2"
      shift 2
      ;;
    -w | --warp-if)
      WARP_IF="$2"
      shift 2
      ;;
    -h | --help)
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

if [[ -z "$WAN_IF" ]]; then
  WAN_IF=$(detect_wan_if)
fi

if [[ $EUID -ne 0 ]]; then
  error "此脚本必须以 root 权限运行，请使用 'sudo bash $0'"
  exit 1
fi

check_command() {
  if ! command -v "$1" &>/dev/null; then
    error "未找到命令 '$1'，请先安装相关工具。"
    exit 1
  fi
}

# 自动尝试安装 iptables 持久化包 (针对 Debian/Ubuntu/CentOS)
install_iptables_persistent_package() {
  if command -v apt-get &>/dev/null; then
    if ! dpkg -s iptables-persistent &>/dev/null; then
      log "检测到 Debian/Ubuntu，自动配置 iptables-persistent 防火墙保存组件..."
      DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
    fi
  elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
    if ! systemctl is-active iptables &>/dev/null; then
      (yum install -y iptables-services || dnf install -y iptables-services) >/dev/null 2>&1 || true
    fi
  fi
}

save_iptables_persistently() {
  log "保存 iptables 规则文件..."
  install_iptables_persistent_package

  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save >/dev/null 2>&1 || true
    log "已成功通过 netfilter-persistent 保存规则。"
  elif command -v service &>/dev/null && service iptables save &>/dev/null; then
    service iptables save >/dev/null 2>&1 || true
    log "已成功通过 iptables-services 保存规则。"
  elif [[ -d /etc/iptables ]]; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    if command -v ip6tables-save &>/dev/null; then
      ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi
    log "规则已保存至 /etc/iptables/rules.v4 (及 rules.v6)。"
  fi
}

setup_systemd_persistence() {
  if ! command -v systemctl &>/dev/null; then
    warn "当前系统不支持 Systemctl，跳过 Systemd 服务注册。"
    return 0
  fi

  log "4. 配置 Systemd 开机自启服务进行全局持久化保障..."

  local current_script
  current_script=$(readlink -f "$0" 2>/dev/null || echo "$0")
  if [[ -f "$current_script" && "$current_script" != "$DEST_SCRIPT" ]]; then
    cp -f "$current_script" "$DEST_SCRIPT"
    chmod +x "$DEST_SCRIPT"
  elif [[ ! -f "$DEST_SCRIPT" ]]; then
    cp -f "$0" "$DEST_SCRIPT" 2>/dev/null || true
    chmod +x "$DEST_SCRIPT" 2>/dev/null || true
  fi

  local exec_args="--setup -i ${WAN_IF} -w ${WARP_IF}"

  cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Cloudflare One VPS Exit NAT Forwarding Rules
After=network-online.target network.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${DEST_SCRIPT} ${exec_args}
ExecStop=${DEST_SCRIPT} --unset -i ${WAN_IF} -w ${WARP_IF}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload || true
  systemctl enable cloudflare-one-nat.service || true
  log "已成功启用 Systemd 服务: cloudflare-one-nat.service (开机自动还原 IP 转发与 NAT 规则)。"
}

remove_systemd_persistence() {
  if command -v systemctl &>/dev/null; then
    log "3. 停用并移除 Systemd 开机持久化服务..."
    systemctl disable --now cloudflare-one-nat.service 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload || true
    log "已卸载 cloudflare-one-nat.service。"
  else
    rm -f "$SERVICE_FILE"
  fi

  if [[ -f "$DEST_SCRIPT" && "$0" != "$DEST_SCRIPT" ]]; then
    rm -f "$DEST_SCRIPT"
  fi
}

resolve_warp_if() {
  if [[ "$WARP_IF" == "auto" ]]; then
    if ip link show warp0 &>/dev/null; then
      echo "warp0"
    else
      echo "any"
    fi
  else
    echo "$WARP_IF"
  fi
}

do_setup() {
  local target_warp_if
  target_warp_if=$(resolve_warp_if)

  log "开始配置 VPS 上 Cloudflare One NAT 出口转发环境..."
  log "检测到的外网网卡 (WAN_IF)  : ${YELLOW}${WAN_IF}${NC}"
  log "入站转发模式/网卡 (WARP_IF): ${YELLOW}${target_warp_if}${NC}"

  check_command iptables

  # 1. 内核转发设置
  log "1. 配置 Linux 内核 IP 转发参数 (${SYSCTL_CONF})..."
  mkdir -p /etc/sysctl.d
  cat <<EOF > "$SYSCTL_CONF"
# Cloudflare One NAT Egress Configuration
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.all.accept_ra = 2
EOF

  sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
  log "内核 IP 转发参数应用完成。"

  # 2. IPv4 iptables 配置
  log "2. 配置 IPv4 iptables NAT MASQUERADE 与 FORWARD 链..."
  
  # NAT MASQUERADE
  if iptables -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null; then
    log "IPv4 POSTROUTING MASQUERADE 规则已存在，跳过重复添加。"
  else
    iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
    log "已添加 IPv4 NAT MASQUERADE 规则 (-o ${WAN_IF})。"
  fi

  # FORWARD
  if [[ "$target_warp_if" == "any" || "$target_warp_if" == "all" ]]; then
    if iptables -C FORWARD -o "$WAN_IF" -j ACCEPT 2>/dev/null; then
      log "IPv4 FORWARD (* -> ${WAN_IF}) 通用规则已存在，跳过。"
    else
      iptables -A FORWARD -o "$WAN_IF" -j ACCEPT
      log "已添加 IPv4 FORWARD 通用转发规则 (* -> ${WAN_IF})。"
    fi
  else
    if iptables -C FORWARD -i "$target_warp_if" -o "$WAN_IF" -j ACCEPT 2>/dev/null; then
      log "IPv4 FORWARD (${target_warp_if} -> ${WAN_IF}) 规则已存在，跳过。"
    else
      iptables -A FORWARD -i "$target_warp_if" -o "$WAN_IF" -j ACCEPT
      log "已添加 IPv4 FORWARD 规则 (-i ${target_warp_if} -o ${WAN_IF})。"
    fi
  fi

  if iptables -C FORWARD -i "$WAN_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -C FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
    log "IPv4 FORWARD 响应跟踪规则已存在，跳过。"
  else
    iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
    log "已添加 IPv4 FORWARD 响应跟踪规则。"
  fi

  # 3. IPv6 ip6tables 配置 (可选)
  if command -v ip6tables &>/dev/null; then
    log "3. 配置 IPv6 ip6tables 规则..."
    if ip6tables -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null; then
      log "IPv6 POSTROUTING MASQUERADE 规则已存在，跳过。"
    else
      ip6tables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true
    fi

    if [[ "$target_warp_if" == "any" || "$target_warp_if" == "all" ]]; then
      ip6tables -A FORWARD -o "$WAN_IF" -j ACCEPT 2>/dev/null || true
    else
      ip6tables -A FORWARD -i "$target_warp_if" -o "$WAN_IF" -j ACCEPT 2>/dev/null || true
    fi
    ip6tables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  fi

  # 4. 持久化 (文件规则 + Systemd 自启服务双重保障)
  save_iptables_persistently
  setup_systemd_persistence

  log "=========================================="
  success "Cloudflare One VPS NAT 出口配置完成 (已开启开机双重持久化)！"
  log "=========================================="
  echo ""
  echo "当前配置摘要:"
  echo -e "  - 外网出口网卡 (WAN_IF) : ${YELLOW}${WAN_IF}${NC}"
  echo -e "  - 入站转发模式 (WARP_IF): ${YELLOW}${target_warp_if}${NC}"
  echo -e "  - 内核 IPv4 转发状态    : ${GREEN}$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 1)${NC}"
  echo -e "  - 开机自启服务状态      : ${GREEN}cloudflare-one-nat.service (active/enabled)${NC}"
}

do_unset() {
  local target_warp_if
  target_warp_if=$(resolve_warp_if)

  log "开始清除 VPS 上 Cloudflare One NAT 转发规则..."
  log "目标外网网卡 (WAN_IF)  : ${YELLOW}${WAN_IF}${NC}"
  log "目标 WARP 网卡 (WARP_IF): ${YELLOW}${target_warp_if}${NC}"

  check_command iptables

  # 1. 删除 IPv4 iptables 规则
  log "1. 删除 IPv4 iptables 转发规则..."
  while iptables -t nat -D POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null; do
    log "已删除一条 IPv4 NAT MASQUERADE 规则 (-o ${WAN_IF})。"
  done

  while iptables -D FORWARD -o "$WAN_IF" -j ACCEPT 2>/dev/null; do
    log "已删除一条 IPv4 FORWARD 通用规则 (-o ${WAN_IF})。"
  done

  if [[ "$target_warp_if" != "any" && "$target_warp_if" != "all" ]]; then
    while iptables -D FORWARD -i "$target_warp_if" -o "$WAN_IF" -j ACCEPT 2>/dev/null; do
      log "已删除一条 IPv4 FORWARD 规则 (-i ${target_warp_if} -o ${WAN_IF})。"
    done
  fi

  while iptables -D FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do
    log "已删除一条 IPv4 FORWARD 响应跟踪规则。"
  done
  while iptables -D FORWARD -i "$WAN_IF" -o "$target_warp_if" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do :; done

  # 2. 删除 IPv6 ip6tables 规则
  if command -v ip6tables &>/dev/null; then
    log "2. 删除 IPv6 ip6tables 转发规则..."
    while ip6tables -t nat -D POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null; do :; done
    while ip6tables -D FORWARD -o "$WAN_IF" -j ACCEPT 2>/dev/null; do :; done
    if [[ "$target_warp_if" != "any" && "$target_warp_if" != "all" ]]; then
      while ip6tables -D FORWARD -i "$target_warp_if" -o "$WAN_IF" -j ACCEPT 2>/dev/null; do :; done
    fi
    while ip6tables -D FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do :; done
  fi

  # 3. 移除 Systemd 持久化服务
  remove_systemd_persistence

  # 4. 删除 sysctl 配置
  if [[ -f "$SYSCTL_CONF" ]]; then
    log "4. 删除 sysctl 配置文件 (${SYSCTL_CONF})...."
    rm -f "$SYSCTL_CONF"
    sysctl --system >/dev/null 2>&1 || true
  fi

  # 5. 持久化清理后的状态
  save_iptables_persistently

  log "=========================================="
  success "Cloudflare One VPS NAT 转发配置及持久化服务已成功清除并还原！"
  log "=========================================="
}

do_status() {
  local target_warp_if
  target_warp_if=$(resolve_warp_if)

  log "=== Cloudflare One VPS NAT 状态检查 ==="
  echo -e "外网出口网卡 (WAN_IF)  : ${YELLOW}${WAN_IF}${NC}"
  echo -e "入站网卡/模式 (WARP_IF) : ${YELLOW}${target_warp_if}${NC}"
  echo ""

  echo "[内核转发设置 status]"
  if [[ -f "$SYSCTL_CONF" ]]; then
    echo -e "  配置文件: ${GREEN}${SYSCTL_CONF} 存在${NC}"
  else
    echo -e "  配置文件: ${YELLOW}${SYSCTL_CONF} 不存在${NC}"
  fi
  echo -e "  net.ipv4.ip_forward               = $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '0')"
  echo -e "  net.ipv6.conf.all.forwarding      = $(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo '0')"
  echo -e "  net.ipv6.conf.all.accept_ra       = $(sysctl -n net.ipv6.conf.all.accept_ra 2>/dev/null || echo '0')"
  echo ""

  echo "[Systemd 开机持久化服务 status]"
  if command -v systemctl &>/dev/null; then
    if systemctl is-enabled cloudflare-one-nat.service &>/dev/null; then
      echo -e "  cloudflare-one-nat.service        : ${GREEN}已启用 (enabled)${NC}"
    else
      echo -e "  cloudflare-one-nat.service        : ${YELLOW}未启用 (disabled/not found)${NC}"
    fi
  fi
  echo ""

  echo "[iptables NAT POSTROUTING 规则]"
  iptables -t nat -L POSTROUTING -v -n --line-numbers | grep -E "MASQUERADE|Chain" || echo "  (无相关 MASQUERADE 规则)"
  echo ""

  echo "[iptables FORWARD 链规则]"
  iptables -L FORWARD -v -n --line-numbers | grep -E "${WAN_IF}|${target_warp_if}|Chain" || echo "  (无相关 FORWARD 规则)"
}

case "$MODE" in
  setup)
    do_setup
    ;;
  unset)
    do_unset
    ;;
  status)
    do_status
    ;;
  *)
    error "未知的运行模式: $MODE"
    show_help
    exit 1
    ;;
esac
