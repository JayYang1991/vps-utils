#!/usr/bin/env bash
#
# service.sh
# Cloudflare Access TCP 客户端日常运维与管理 CLI 工具
# 安装后可作为系统全局命令运行: cloudflare-access-tcp <command> 或 cf-access-tcp <command>
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

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success() { echo -e "${GREEN}${BOLD}[SUCCESS]${NC} $1"; }

SERVICE_NAME="cloudflare-access-tcp"
CONTAINER_NAME="cloudflare-access-tcp"
IMAGE_NAME="cloudflare-access-tcp:latest"
CONF_DIR="/etc/cloudflare-access-tcp"
ENV_FILE="${CONF_DIR}/access.env"
CANDIDATES_FILE="${CONF_DIR}/candidates.txt"
STATUS_FILE="${CONF_DIR}/status.json"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "该操作需要 root 权限，请使用: sudo $0 $*"
    exit 1
  fi
}

validate_ip() {
  local ip="$1"
  [[ -z "$ip" ]] && return 1
  local ipv4_regex="^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
  if [[ "$ip" =~ $ipv4_regex ]]; then
    return 0
  fi
  if [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
    return 0
  fi
  error "IP 地址格式无效: $ip"
  return 1
}

show_help() {
  echo -e "${CYAN}${BOLD}Cloudflare Access TCP 客户端日常运维与管理工具${NC}"
  echo ""
  echo "Usage: cloudflare-access-tcp <command> [options]"
  echo "       cf-access-tcp <command> [options]"
  echo ""
  echo "核心运维命令:"
  echo "  status, info                查看 Systemd 服务、Docker 容器、当前优选 IP、健康指标与下次定时测速排期"
  echo "  candidates, list-ips, ips   查看当前 TOP 20 待选优选 IP 列表及测速指标 (延迟/速度/地区)"
  echo "  speedtest, run-test         在容器内立即触发一次全量测速，更新 TOP 20 待选 IP 列表"
  echo "  switch-ip <IP>              手动将域名解析切换至指定优选 IP 并即刻重载转发"
  echo "  test                        测试本地各个 TCP 转发端口与待选 IP 池 443 端口的连通性"
  echo "  logs, log [-f] [-n NUM]     查看运行日志 (默认 50 条，-f 实时跟踪)"
  echo "  start                       启动 Systemd 转发服务"
  echo "  stop                        停止 Systemd 转发服务"
  echo "  restart                     重启 Systemd 转发服务"
  echo "  config, env [--edit]        查看配置文件 (--edit 可使用系统编辑器修改)"
  echo "  rebuild                     重新编译 Docker 镜像 (使用宿主机网络构建)"
  echo "  uninstall                   完全卸载 Systemd 服务、容器、全局命令与配置文件"
  echo "  help, -h, --help            显示本帮助信息"
  echo ""
  echo "使用示例:"
  echo "  cloudflare-access-tcp status          # 查看运行状态与优选指标"
  echo "  cloudflare-access-tcp candidates      # 查看 TOP 20 优选池"
  echo "  cloudflare-access-tcp speedtest       # 立即执行一次优选测速"
  echo "  cloudflare-access-tcp switch-ip 104.16.88.99 # 手动切换优选 IP"
  echo "  cloudflare-access-tcp logs -f         # 实时追踪日志"
  echo "  cloudflare-access-tcp test            # 测试端口与链路连通性"
}

cmd_start() {
  check_root
  log "正在启动 ${SERVICE_NAME} 服务..."
  systemctl start "${SERVICE_NAME}"
  sleep 1
  systemctl status "${SERVICE_NAME}" --no-pager
}

cmd_stop() {
  check_root
  log "正在停止 ${SERVICE_NAME} 服务..."
  systemctl stop "${SERVICE_NAME}" || true
  docker stop "${CONTAINER_NAME}" 2>/dev/null || true
  success "${SERVICE_NAME} 服务已停止。"
}

cmd_restart() {
  check_root
  log "正在重启 ${SERVICE_NAME} 服务..."
  systemctl restart "${SERVICE_NAME}"
  success "${SERVICE_NAME} 重启指令已发送，正在检查状态..."
  sleep 2
  cmd_status
}

cmd_logs() {
  local follow=false
  local lines=50
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--follow)
        follow=true
        shift 1
        ;;
      -n|--lines)
        lines="$2"
        shift 2
        ;;
      *)
        shift 1
        ;;
    esac
  done

  if command -v journalctl &>/dev/null && [[ -f "$SERVICE_FILE" ]]; then
    if [[ "$follow" == "true" ]]; then
      journalctl -u "$SERVICE_NAME" -f -n "$lines"
    else
      journalctl -u "$SERVICE_NAME" -n "$lines" --no-pager
    fi
  else
    if [[ "$follow" == "true" ]]; then
      docker logs -f --tail "$lines" "$CONTAINER_NAME"
    else
      docker logs --tail "$lines" "$CONTAINER_NAME"
    fi
  fi
}

cmd_status() {
  echo -e "${CYAN}${BOLD}=== ${SERVICE_NAME} 运行状态与优选监控 ===${NC}"
  echo ""
  if [[ -f "$SERVICE_FILE" ]]; then
    local svc_active
    svc_active=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "inactive")
    if [[ "$svc_active" == "active" ]]; then
      echo -e "Systemd 服务状态:  ${GREEN}${BOLD}● active (running)${NC}"
    else
      echo -e "Systemd 服务状态:  ${RED}${BOLD}○ $svc_active${NC}"
    fi
  else
    echo -e "Systemd 服务状态:  ${YELLOW}未安装 Systemd 服务${NC}"
  fi

  echo -n "Docker 容器状态:   "
  if docker ps --format '{{.Names}} ({{.Status}})' | grep -E "^${CONTAINER_NAME} " &>/dev/null; then
    echo -e "${GREEN}${BOLD}$(docker ps --format '{{.Names}} ({{.Status}})' | grep -E "^${CONTAINER_NAME} ")${NC}"
  elif docker ps -a --format '{{.Names}} ({{.Status}})' | grep -E "^${CONTAINER_NAME} " &>/dev/null; then
    echo -e "${YELLOW}$(docker ps -a --format '{{.Names}} ({{.Status}})' | grep -E "^${CONTAINER_NAME} ")${NC}"
  else
    echo -e "${RED}容器未运行或未创建${NC}"
  fi

  # 读取容器或宿主机 status.json
  if [[ -f "$STATUS_FILE" ]]; then
    echo ""
    echo -e "${CYAN}优选与健康检测监控指标 (status.json):${NC}"
    local cur_ip
    cur_ip=$(grep -o '"current_preferred_ip": *"[^"]*"' "$STATUS_FILE" | cut -d'"' -f4 || echo "")
    local is_h
    is_h=$(grep -o '"healthy": *[^,]*' "$STATUS_FILE" | awk '{print $2}' || echo "")
    local next_st
    next_st=$(grep -o '"next_scheduled_speedtest": *"[^"]*"' "$STATUS_FILE" | cut -d'"' -f4 || echo "")
    local last_st
    last_st=$(grep -o '"last_speedtest_at": *"[^"]*"' "$STATUS_FILE" | cut -d'"' -f4 || echo "")
    local cand_cnt
    cand_cnt=$(grep -o '"candidates_count": *[0-9]*' "$STATUS_FILE" | awk '{print $2}' || echo "")

    if [[ "$is_h" == "true" ]]; then
      echo -e "  • 转发健康状态:     ${GREEN}${BOLD}✓ 正常 (Healthy)${NC}"
    else
      echo -e "  • 转发健康状态:     ${RED}${BOLD}✗ 异常/检测中${NC}"
    fi
    echo -e "  • 当前生效优选 IP:  ${GREEN}${BOLD}${cur_ip:-未配置/自动}${NC}"
    echo -e "  • 待选池 IP 数量:   ${BOLD}${cand_cnt:-0}${NC} 个 (TOP 20 池)"
    echo -e "  • 上次测速时间:     ${last_st:-暂无记录}"
    echo -e "  • 下次定时测速排期: ${CYAN}${BOLD}${next_st:-未排期}${NC} (北京时间 02:00~06:00 随机触发)"
  fi

  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    echo ""
    echo -e "网络隔离模式:      ${GREEN}${BOLD}Bridge 容器隔离模式${NC} (运行时非宿主机网络，仅通过端口映射暴露)"
    echo ""
    echo -e "${CYAN}当前配置的转发规则:${NC}"
    IFS=',' read -r -a cur_domains <<< "${DOMAINS:-}"
    IFS=',' read -r -a cur_ports <<< "${PORTS:-}"
    local host_listen="${LISTEN_HOST:-127.0.0.1}"
    [[ "$host_listen" == "localhost" ]] && host_listen="127.0.0.1"
    for i in "${!cur_domains[@]}"; do
      local p="${cur_ports[i]}"
      local d="${cur_domains[i]}"
      local port_status="${RED}未监听${NC}"
      local test_ip="$host_listen"
      [[ "$test_ip" == "0.0.0.0" ]] && test_ip="127.0.0.1"

      if ss -tlpn "sport = :$p" 2>/dev/null | grep -q ":$p"; then
        port_status="${GREEN}监听中 (TCP)${NC}"
      elif nc -z "$test_ip" "$p" 2>/dev/null; then
        port_status="${GREEN}连通正常 (TCP)${NC}"
      elif timeout 2 bash -c "cat < /dev/null > /dev/tcp/${test_ip}/${p}" 2>/dev/null; then
        port_status="${GREEN}连通正常 (TCP)${NC}"
      fi
      printf "  [%d] %-18s -> %-35s [状态: %b]\n" "$((i+1))" "${host_listen}:${p}" "$d" "$port_status"
    done
  fi
  echo ""
}

cmd_candidates() {
  echo -e "${CYAN}${BOLD}=== 当前 TOP 20 待选优选 IP 列表 ===${NC}"
  echo "文件路径: ${CANDIDATES_FILE}"
  echo ""
  if [[ -f "$CANDIDATES_FILE" ]]; then
    echo "--------------------------------------------------------------------------------"
    printf " %-4s %-22s %-16s %-12s %-12s\n" "序号" "优选 IP:端口" "测速带宽" "平均延迟" "地区/丢包"
    echo "--------------------------------------------------------------------------------"
    local idx=1
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      local addr
      local remark
      addr=$(echo "$line" | cut -d'#' -f1)
      remark=$(echo "$line" | cut -d'#' -f2-)
      # 从 remark 解析 speed, latency, loss
      local sp="N/A"
      local lat="N/A"
      local extra="$remark"
      if [[ "$remark" =~ ([A-Za-z0-9]+)_([0-9\.]+)MBs_([0-9\.]+)ms_(.*) ]]; then
        extra="${BASH_REMATCH[1]} / ${BASH_REMATCH[4]}"
        sp="${BASH_REMATCH[2]} MB/s"
        lat="${BASH_REMATCH[3]} ms"
      fi
      printf " [%2d] %-22s %-16s %-12s %-12s\n" "$idx" "$addr" "$sp" "$lat" "$extra"
      ((idx++))
    done < "$CANDIDATES_FILE"
    echo "--------------------------------------------------------------------------------"
  elif docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}\$"; then
    docker exec "$CONTAINER_NAME" cat /etc/cloudflare-access-tcp/candidates.txt 2>/dev/null || echo "（暂无候选 IP 记录）"
  else
    echo "（暂无候选 IP 记录，请先启动服务或运行测速: cloudflare-access-tcp speedtest）"
  fi
  echo ""
}

cmd_speedtest() {
  if ! docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}\$"; then
    error "容器 ${CONTAINER_NAME} 未运行，无法触发测速！"
    exit 1
  fi
  log "正在在容器内触发全量优选 IP 测速任务..."
  docker exec -it "$CONTAINER_NAME" python3 /app/speedtest_runner.py --run
}

cmd_switch_ip() {
  local target_ip="$1"
  if [[ -z "$target_ip" ]]; then
    error "请指定目标优选 IP: cloudflare-access-tcp switch-ip <IP>"
    exit 1
  fi
  if ! validate_ip "$target_ip"; then
    exit 1
  fi
  if ! docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}\$"; then
    error "容器 ${CONTAINER_NAME} 未运行，无法执行切换！"
    exit 1
  fi
  log "正在将容器内域名解析切换至: ${target_ip} ..."
  docker exec "$CONTAINER_NAME" python3 -c "
from health_checker import HostsManager, ForwarderController, Config
domains = Config.get_domains()
HostsManager.update_preferred_ip('${target_ip}', domains)
ForwarderController.restart_forwarders()
print('已成功切换优选 IP 并重载转发进程！')
"
}

cmd_test() {
  if [[ ! -f "$ENV_FILE" ]]; then
    error "未找到配置文件 ($ENV_FILE)，请先执行安装配置。"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  IFS=',' read -r -a cur_domains <<< "${DOMAINS:-}"
  IFS=',' read -r -a cur_ports <<< "${PORTS:-}"
  local host_listen="${LISTEN_HOST:-127.0.0.1}"
  [[ "$host_listen" == "localhost" || "$host_listen" == "0.0.0.0" ]] && host_listen="127.0.0.1"

  echo -e "${CYAN}${BOLD}=== 测试本地 TCP 转发端口连通性 ===${NC}"
  for i in "${!cur_domains[@]}"; do
    local p="${cur_ports[i]}"
    local d="${cur_domains[i]}"
    echo -n "测试规则 #$((i+1)) [${host_listen}:${p} -> ${d}] ... "
    
    if command -v nc &>/dev/null; then
      if nc -z -w 3 "$host_listen" "$p" &>/dev/null; then
        echo -e "${GREEN}✓ 端口已开放且可连接${NC}"
      else
        echo -e "${RED}✗ 连接失败 (端口未监听或超时)${NC}"
      fi
    elif timeout 3 bash -c "cat < /dev/null > /dev/tcp/${host_listen}/${p}" 2>/dev/null; then
      echo -e "${GREEN}✓ 端口已开放且可连接${NC}"
    else
      echo -e "${RED}✗ 连接失败 (端口未监听或超时)${NC}"
    fi
  done

  if [[ -f "$CANDIDATES_FILE" ]]; then
    echo ""
    echo -e "${CYAN}${BOLD}=== 测试待选优选 IP 池 443 端口可用性 (前 5 个) ===${NC}"
    local cnt=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      local ip_test
      ip_test=$(echo "$line" | cut -d: -f1 | cut -d'#' -f1 | tr -d ' ')
      if [[ -n "$ip_test" ]]; then
        echo -n "测试候选 IP [${ip_test}:443] ... "
        if nc -z -w 2 "$ip_test" 443 2>/dev/null || timeout 2 bash -c "cat < /dev/null > /dev/tcp/${ip_test}/443" 2>/dev/null; then
          echo -e "${GREEN}✓ 正常可用${NC}"
        else
          echo -e "${YELLOW}⚠️ 超时/不可达${NC}"
        fi
        cnt=$((cnt + 1))
        [[ $cnt -ge 5 ]] && break
      fi
    done < "$CANDIDATES_FILE"
  fi
  echo ""
}

cmd_config() {
  if [[ ! -f "$ENV_FILE" ]]; then
    error "未找到配置文件: $ENV_FILE"
    exit 1
  fi
  if [[ "$1" == "--edit" || "$1" == "-e" ]]; then
    check_root
    local editor="${EDITOR:-nano}"
    command -v "$editor" &>/dev/null || editor="vi"
    "$editor" "$ENV_FILE"
    log "配置文件已修改，建议重启服务生效: sudo cloudflare-access-tcp restart"
  else
    echo -e "${CYAN}=== 配置文件内容 (${ENV_FILE}) ===${NC}"
    cat "$ENV_FILE"
    echo ""
    echo "提示: 可使用 'sudo cloudflare-access-tcp config --edit' 直接编辑配置文件。"
  fi
}

cmd_rebuild() {
  check_root
  log "正在重新编译 Docker 镜像 (使用宿主机网络 --network host)..."
  local target_dir="$SCRIPT_DIR"
  if [[ ! -f "${target_dir}/Dockerfile" ]]; then
    if [[ -f "/usr/local/share/cloudflare-access-tcp/Dockerfile" ]]; then
      target_dir="/usr/local/share/cloudflare-access-tcp"
    elif [[ -f "/etc/cloudflare-access-tcp/Dockerfile" ]]; then
      target_dir="/etc/cloudflare-access-tcp"
    fi
  fi

  if [[ ! -f "${target_dir}/Dockerfile" ]]; then
    error "未找到 Dockerfile 构建文件 (目录: ${target_dir})！"
    exit 1
  fi

  docker build --network host -t "$IMAGE_NAME" "$target_dir"
  success "Docker 镜像 [$IMAGE_NAME] 重新编译成功！"
  log "重启服务以加载新镜像: sudo cloudflare-access-tcp restart"
}

cmd_uninstall() {
  check_root
  echo -e "${YELLOW}警告: 即将完全停止并卸载 ${SERVICE_NAME} 服务，清理容器与相关配置！${NC}"
  read -r -p "确认卸载？[y/N]: " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log "已取消卸载。"
    exit 0
  fi

  log "正在停止并禁用 Systemd 服务..."
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl stop "$SERVICE_NAME" || true
  fi
  if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl disable "$SERVICE_NAME" || true
  fi

  if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    log "已移除 Systemd 服务文件: $SERVICE_FILE"
  fi

  if docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}\$"; then
    log "正在删除 Docker 容器: $CONTAINER_NAME..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  fi

  rm -f /usr/local/bin/cloudflare-access-tcp /usr/local/bin/cf-access-tcp 2>/dev/null || true
  log "已移除全局管理命令链接: /usr/local/bin/cloudflare-access-tcp"

  if [[ -d "$CONF_DIR" ]]; then
    rm -rf "$CONF_DIR"
    log "已清理配置与数据目录: $CONF_DIR"
  fi

  success "${SERVICE_NAME} 已完全卸载并清理完毕！"
  exit 0
}

# ===================== 命令分流路由 =====================
ACTION="${1:-status}"
shift || true

case "$ACTION" in
  status|info)
    cmd_status
    ;;
  candidates|list-ips|list-candidates|ips)
    cmd_candidates
    ;;
  speedtest|run-test|test-speed)
    cmd_speedtest
    ;;
  switch-ip|switch)
    cmd_switch_ip "$1"
    ;;
  test)
    cmd_test
    ;;
  start)
    cmd_start
    ;;
  stop)
    cmd_stop
    ;;
  restart)
    cmd_restart
    ;;
  logs|log)
    cmd_logs "$@"
    ;;
  config|env)
    cmd_config "$@"
    ;;
  rebuild)
    cmd_rebuild
    ;;
  uninstall)
    cmd_uninstall
    ;;
  help|-h|--help)
    show_help
    ;;
  *)
    warn "未知命令: $ACTION"
    show_help
    exit 1
    ;;
esac
