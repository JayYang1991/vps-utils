#!/usr/bin/env bash
#
# install.sh
# Cloudflare Access TCP 客户端一键安装与 Systemd 服务管理脚本
# 通过 Docker + Ubuntu 24.04 编译生成容器，并通过 Systemd 实现开机自启与后台守护运行。
# 容器内集成 CloudflareSpeedTest (cfst) 测速引擎与健康检测/故障转移守护进程：
# 1. 每天北京时间凌晨 02:00 ~ 06:00 随机时间自动测速并选取 TOP 20 优选 IP 存入待选列表。
# 2. 容器内定期检测 TCP 连接联通性，当检测不通时从待选列表从前往后验证并自动切换优选 IP。
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

# --- 字符串清洗辅助函数 ---
clean_val() {
  local val="$1"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  while [[ "$val" == \"*\" || "$val" == \'*\' ]]; do
    val="${val:1:-1}"
  done
  val="${val#\"}"
  val="${val%\"}"
  val="${val#\'}"
  val="${val%\'}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}

# --- 基础与默认变量 ---
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")
SERVICE_NAME="cloudflare-access-tcp"
CONTAINER_NAME="cloudflare-access-tcp"
IMAGE_NAME="cloudflare-access-tcp:latest"
CONF_DIR="/etc/cloudflare-access-tcp"
ENV_FILE="${CONF_DIR}/access.env"
CANDIDATES_FILE="${CONF_DIR}/candidates.txt"
STATUS_FILE="${CONF_DIR}/status.json"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

DEFAULT_DOMAINS="movies.19910417.xyz,movies1.19910417.xyz"
DEFAULT_PORTS="5000,5001"
DEFAULT_LISTEN="127.0.0.1"
DEFAULT_NETWORK_MODE="bridge"

SERVICE_TOKEN_ID="${SERVICE_TOKEN_ID:-}"
SERVICE_TOKEN_SECRET="${SERVICE_TOKEN_SECRET:-}"
DOMAINS="${DOMAINS:-}"
PORTS="${PORTS:-}"
LISTEN_HOST="${LISTEN_HOST:-}"
PREFERRED_IP="${PREFERRED_IP:-}"
NETWORK_MODE="${NETWORK_MODE:-$DEFAULT_NETWORK_MODE}"
CF_SUB_URL="${CF_SUB_URL:-https://sub.19910417.xyz}"

FORWARD_RULES=()
ACTION="install"
NO_CACHE=false
MANUAL_SWITCH_IP=""

# --- 显示帮助信息 ---
show_help() {
  echo -e "${CYAN}${BOLD}Cloudflare Access TCP 客户端一键安装与 Systemd 容器管理脚本${NC}"
  echo ""
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "核心操作模式:"
  echo "  --install                   一键构建镜像、配置 Systemd 服务并开机自启 (默认动作)"
  echo "  --uninstall                 停止并卸载 Systemd 服务，清理容器、镜像与配置文件"
  echo "  --restart                   重启 Systemd 服务"
  echo "  --stop                      停止 Systemd 服务"
  echo "  --status                    查看服务运行状态、当前优选 IP、健康检测与定时测速排期"
  echo "  --logs, -l                  查看服务的实时运行日志 (journalctl)"
  echo "  --test                      测试各个本地转发端口与优选 IP 链路连通性"
  echo "  --speedtest, --run-test     在容器内立即触发一次优选测速，更新 TOP 20 待选 IP 列表"
  echo "  --candidates, --list-ips    查看当前 TOP 20 待选优选 IP 列表及测速指标"
  echo "  --switch-ip <IP>            手动将域名解析切换至指定优选 IP 并重载转发"
  echo "  --rebuild, -b               仅重新编译 Docker 镜像 (编译使用宿主机网络 --network host)"
  echo ""
  echo "必选参数 (用于安装或更新配置):"
  echo "  -i, --token-id <ID>         Cloudflare Access Service Token Client ID"
  echo "  -s, --token-secret <SECRET> Cloudflare Access Service Token Client Secret"
  echo "      --service-token <ID:KEY>以 'ID:SECRET' 格式一次性传入 Service Token"
  echo ""
  echo "可选配置参数:"
  echo "  --ip, --preferred-ip <IP>   指定初始 Cloudflare 优选 IP (若不指定将自动从待选池/测速获取)"
  echo "  -d, --domains <D1,D2,...>   目标域名列表，逗号分隔 (默认: movies.19910417.xyz,movies1.19910417.xyz)"
  echo "  -p, --ports <P1,P2,...>     本地监听端口列表，逗号分隔 (默认: 5000,5001)"
  echo "  -f, --forward <D:P,...>     转发规则列表，格式为 'domain1:port1,domain2:port2' (可指定多次)"
  echo "      --listen <HOST>         宿主机监听绑定地址 (默认: 127.0.0.1, 也可设为 0.0.0.0)"
  echo "      --sub-url <URL>         订阅服务器拉取地址 (默认: https://sub.19910417.xyz)"
  echo "      --check-interval <SEC>  TCP 连通性检测间隔秒数 (默认: 15)"
  echo "      --fail-threshold <NUM>  连续失败触发故障转移次数 (默认: 2)"
  echo "  -n, --name <NAME>           自定义服务与容器名称 (默认: cloudflare-access-tcp)"
  echo "      --no-cache              构建 Docker 镜像时不使用缓存 (全新拉取与编译)"
  echo "  -h, --help                  显示此帮助信息"
  echo ""
  echo "使用示例:"
  echo -e "  ${YELLOW}# 1. 默认一键安装 (内置每日凌晨测速与自动故障转移):${NC}"
  echo "  sudo bash $0 -i \"xxx.access\" -s \"yyy\""
  echo ""
  echo -e "  ${YELLOW}# 2. 指定初始优选 IP 与自定义转发规则:${NC}"
  echo "  sudo bash $0 --service-token \"xxx:yyy\" -f \"movies.19910417.xyz:5000,movies1.19910417.xyz:5001\" --ip \"104.16.88.99\""
  echo ""
  echo -e "  ${YELLOW}# 3. 运行状态查看与即时测速:${NC}"
  echo "  sudo bash $0 --status"
  echo "  sudo bash $0 --candidates"
  echo "  sudo bash $0 --speedtest"
}

# --- 严格校验域名格式 ---
validate_domain() {
  local domain="$1"
  if [[ -z "$domain" ]]; then
    error "域名不能为空"
    return 1
  fi
  if [[ ${#domain} -gt 253 || ${#domain} -lt 3 ]]; then
    error "域名长度非法 (${#domain} 字符): $domain"
    return 1
  fi
  if [[ "$domain" != *.* ]]; then
    error "域名必须包含顶级域名 (至少包含一个点): $domain"
    return 1
  fi
  local domain_regex="^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$"
  if [[ ! "$domain" =~ $domain_regex ]]; then
    error "域名格式不符合规范: $domain"
    return 1
  fi
  return 0
}

# --- 严格校验端口号 ---
validate_port() {
  local port="$1"
  if [[ -z "$port" ]]; then
    error "端口号不能为空"
    return 1
  fi
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    error "端口号必须为纯数字整数: $port"
    return 1
  fi
  if (( port < 1 || port > 65535 )); then
    error "端口号超出合法范围 (1-65535): $port"
    return 1
  fi
  if [[ "$port" =~ ^0[0-9]+$ ]]; then
    error "端口号格式非法 (不能包含前导 0): $port"
    return 1
  fi
  return 0
}

# --- 严格校验 IP 地址 ---
validate_ip() {
  local ip="$1"
  [[ -z "$ip" ]] && return 0
  local ipv4_regex="^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
  if [[ "$ip" =~ $ipv4_regex ]]; then
    return 0
  fi
  if [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
    return 0
  fi
  error "优选 IP 格式无效: $ip"
  return 1
}

# --- 检查端口占用 ---
check_port_available() {
  local port="$1"
  if command -v ss &>/dev/null; then
    if ss -tlpn "sport = :$port" 2>/dev/null | grep -q ":$port"; then
      return 1
    fi
  elif command -v netstat &>/dev/null; then
    if netstat -tlpn 2>/dev/null | grep -q ":$port "; then
      return 1
    fi
  elif command -v lsof &>/dev/null; then
    if lsof -iTCP:"$port" -sTCP:LISTEN -P -n &>/dev/null; then
      return 1
    fi
  fi
  return 0
}

# --- 脱敏字符串 ---
mask_string() {
  local str="$1"
  local len=${#str}
  if (( len <= 8 )); then
    echo "******"
  else
    local prefix="${str:0:4}"
    local suffix="${str: -4}"
    echo "${prefix}****${suffix}"
  fi
}

# --- 参数解析 ---
CHECK_INTERVAL_ARG="15"
FAIL_THRESHOLD_ARG="2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      ACTION="install"
      shift 1
      ;;
    --uninstall)
      ACTION="uninstall"
      shift 1
      ;;
    --restart)
      ACTION="restart"
      shift 1
      ;;
    --stop)
      ACTION="stop"
      shift 1
      ;;
    --status)
      ACTION="status"
      shift 1
      ;;
    -l|--logs)
      ACTION="logs"
      shift 1
      ;;
    --test)
      ACTION="test"
      shift 1
      ;;
    --speedtest|--run-test|--test-speed)
      ACTION="speedtest"
      shift 1
      ;;
    --candidates|--list-ips|--list-candidates)
      ACTION="candidates"
      shift 1
      ;;
    --switch-ip)
      ACTION="switch-ip"
      MANUAL_SWITCH_IP=$(clean_val "$2")
      shift 2
      ;;
    -b|--rebuild)
      ACTION="rebuild"
      shift 1
      ;;
    --no-cache)
      NO_CACHE=true
      shift 1
      ;;
    -i|--token-id|--service-token-id)
      SERVICE_TOKEN_ID=$(clean_val "$2")
      shift 2
      ;;
    -s|--token-secret|--service-token-secret)
      SERVICE_TOKEN_SECRET=$(clean_val "$2")
      shift 2
      ;;
    --service-token)
      IFS=':' read -r raw_id raw_sec <<< "$2"
      SERVICE_TOKEN_ID=$(clean_val "$raw_id")
      SERVICE_TOKEN_SECRET=$(clean_val "$raw_sec")
      shift 2
      ;;
    --ip|--preferred-ip|-ip)
      PREFERRED_IP=$(clean_val "$2")
      shift 2
      ;;
    -d|--domains)
      DOMAINS=$(clean_val "$2")
      shift 2
      ;;
    -p|--ports)
      PORTS=$(clean_val "$2")
      shift 2
      ;;
    -f|--forward)
      FORWARD_RULES+=("$2")
      shift 2
      ;;
    --listen)
      LISTEN_HOST=$(clean_val "$2")
      shift 2
      ;;
    --sub-url)
      CF_SUB_URL=$(clean_val "$2")
      shift 2
      ;;
    --check-interval)
      CHECK_INTERVAL_ARG=$(clean_val "$2")
      shift 2
      ;;
    --fail-threshold)
      FAIL_THRESHOLD_ARG=$(clean_val "$2")
      shift 2
      ;;
    --network-mode)
      NETWORK_MODE=$(clean_val "$2")
      shift 2
      ;;
    -n|--name)
      SERVICE_NAME=$(clean_val "$2")
      CONTAINER_NAME="$SERVICE_NAME"
      SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
      shift 2
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
require_root() {
  if [[ $EUID -ne 0 ]]; then
    error "此操作需要 root 权限，请使用 'sudo bash $0 ...' 运行"
    exit 1
  fi
}

# --- 检查并安装 Docker 环境 ---
check_docker() {
  if ! command -v docker &>/dev/null; then
    warn "未检测到 Docker 环境，正在尝试自动安装 Docker..."
    if command -v curl &>/dev/null; then
      curl -fsSL https://get.docker.com | bash
    else
      error "未找到 curl，无法自动安装 Docker。请先手动安装 Docker。"
      exit 1
    fi
  fi

  if ! systemctl is-active --quiet docker; then
    log "正在启动 Docker 守护进程..."
    systemctl enable --now docker || true
  fi
}

# --- 编译 Docker 镜像 (使用宿主机网络) ---
build_docker_image() {
  log "开始编译 Cloudflare Access TCP Docker 镜像 (基础镜像: ubuntu:24.04, 构建网络: 宿主机网络 --network host)..."
  local build_cmd=("docker" "build" "--network" "host" "-t" "$IMAGE_NAME" "$SCRIPT_DIR")
  if [[ "$NO_CACHE" == "true" ]]; then
    build_cmd+=("--no-cache")
  fi

  log "执行编译指令: ${build_cmd[*]}"
  "${build_cmd[@]}"
  success "Docker 镜像 [$IMAGE_NAME] 编译完成！"
}

# --- 卸载服务 ---
do_uninstall() {
  require_root
  log "正在停止并卸载 ${SERVICE_NAME} Systemd 服务..."
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

  if [[ -d "$CONF_DIR" ]]; then
    rm -rf "$CONF_DIR"
    log "已清理配置文件目录: $CONF_DIR"
  fi

  success "${SERVICE_NAME} 已完全卸载并清理完毕！"
  exit 0
}

# --- 重启服务 ---
do_restart() {
  require_root
  log "正在重启 ${SERVICE_NAME} 服务..."
  systemctl restart "$SERVICE_NAME"
  success "${SERVICE_NAME} 重启指令已发送，正在检查状态..."
  sleep 2
  do_status
}

# --- 停止服务 ---
do_stop() {
  require_root
  log "正在停止 ${SERVICE_NAME} 服务..."
  systemctl stop "$SERVICE_NAME" || true
  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  success "${SERVICE_NAME} 服务已停止。"
  exit 0
}

# --- 查看日志 ---
do_logs() {
  if command -v journalctl &>/dev/null && [[ -f "$SERVICE_FILE" ]]; then
    journalctl -u "$SERVICE_NAME" -f -n 50
  else
    docker logs -f --tail 50 "$CONTAINER_NAME"
  fi
  exit 0
}

# --- 立即触发测速 ---
do_speedtest() {
  if ! docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}\$"; then
    error "容器 ${CONTAINER_NAME} 未运行，无法触发测速！"
    exit 1
  fi
  log "正在在容器内触发全量优选 IP 测速任务..."
  docker exec -it "$CONTAINER_NAME" python3 /app/speedtest_runner.py --run
  exit 0
}

# --- 查看候选 IP 列表 ---
do_candidates() {
  echo -e "${CYAN}${BOLD}=== 当前 TOP 20 待选优选 IP 列表 ===${NC}"
  echo "文件路径: ${CANDIDATES_FILE}"
  echo ""
  if [[ -f "$CANDIDATES_FILE" ]]; then
    cat "$CANDIDATES_FILE"
  elif docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}\$"; then
    docker exec "$CONTAINER_NAME" cat /etc/cloudflare-access-tcp/candidates.txt 2>/dev/null || echo "（暂无候选 IP 记录）"
  else
    echo "（暂无候选 IP 记录，请先启动服务或运行测速）"
  fi
  echo ""
  exit 0
}

# --- 手动切换优选 IP ---
do_switch_ip() {
  if [[ -z "$MANUAL_SWITCH_IP" ]]; then
    error "请指定目标优选 IP: $0 --switch-ip <IP>"
    exit 1
  fi
  if ! validate_ip "$MANUAL_SWITCH_IP"; then
    exit 1
  fi
  if ! docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}\$"; then
    error "容器 ${CONTAINER_NAME} 未运行，无法执行切换！"
    exit 1
  fi
  log "正在将容器内域名解析切换至: ${MANUAL_SWITCH_IP} ..."
  docker exec "$CONTAINER_NAME" python3 -c "
from health_checker import HostsManager, ForwarderController, Config
domains = Config.get_domains()
HostsManager.update_preferred_ip('${MANUAL_SWITCH_IP}', domains)
ForwarderController.restart_forwarders()
print('已成功切换优选 IP 并重载转发进程！')
"
  exit 0
}

# --- 查看状态 ---
do_status() {
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
  exit 0
}

# --- 测试连通性 ---
do_test() {
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
        ((cnt++))
        ((cnt >= 5)) && break
      fi
    done < "$CANDIDATES_FILE"
  fi
  echo ""
  exit 0
}

# --- 仅重新编译镜像模式 ---
if [[ "$ACTION" == "rebuild" ]]; then
  require_root
  check_docker
  build_docker_image
  exit 0
fi

# --- 各种非安装模式分流 ---
case "$ACTION" in
  uninstall)   do_uninstall ;;
  restart)     do_restart ;;
  stop)        do_stop ;;
  logs)        do_logs ;;
  status)      do_status ;;
  test)        do_test ;;
  speedtest)   do_speedtest ;;
  candidates)  do_candidates ;;
  switch-ip)   do_switch_ip ;;
esac

# ==================== 执行一键安装流程 ====================
require_root
check_docker

# 1. 尝试继承现有配置文件中的 Token 或参数
if [[ -f "$ENV_FILE" ]]; then
  EXISTING_TOKEN_ID=$(grep -E "^SERVICE_TOKEN_ID=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  EXISTING_TOKEN_SECRET=$(grep -E "^SERVICE_TOKEN_SECRET=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  EXISTING_DOMAINS=$(grep -E "^DOMAINS=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  EXISTING_PORTS=$(grep -E "^PORTS=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  EXISTING_LISTEN=$(grep -E "^LISTEN_HOST=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  EXISTING_PREF_IP=$(grep -E "^PREFERRED_IP=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  EXISTING_NET_MODE=$(grep -E "^NETWORK_MODE=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)

  [[ -z "$SERVICE_TOKEN_ID" && -n "$EXISTING_TOKEN_ID" ]] && SERVICE_TOKEN_ID=$(clean_val "$EXISTING_TOKEN_ID")
  [[ -z "$SERVICE_TOKEN_SECRET" && -n "$EXISTING_TOKEN_SECRET" ]] && SERVICE_TOKEN_SECRET=$(clean_val "$EXISTING_TOKEN_SECRET")
  [[ -z "$DOMAINS" && -n "$EXISTING_DOMAINS" && ${#FORWARD_RULES[@]} -eq 0 ]] && DOMAINS=$(clean_val "$EXISTING_DOMAINS")
  [[ -z "$PORTS" && -n "$EXISTING_PORTS" && ${#FORWARD_RULES[@]} -eq 0 ]] && PORTS=$(clean_val "$EXISTING_PORTS")
  [[ -z "$LISTEN_HOST" && -n "$EXISTING_LISTEN" ]] && LISTEN_HOST=$(clean_val "$EXISTING_LISTEN")
  [[ -z "$PREFERRED_IP" && -n "$EXISTING_PREF_IP" ]] && PREFERRED_IP=$(clean_val "$EXISTING_PREF_IP")
  [[ -z "$NETWORK_MODE" && -n "$EXISTING_NET_MODE" ]] && NETWORK_MODE=$(clean_val "$EXISTING_NET_MODE")
fi

# 2. 检查必选参数
if [[ -z "$SERVICE_TOKEN_ID" ]]; then
  if [[ -t 0 ]]; then
    echo -e "${YELLOW}请输入 Cloudflare Access Service Token Client ID:${NC}"
    read -r -p "Service Token ID: " SERVICE_TOKEN_ID
    SERVICE_TOKEN_ID=$(clean_val "$SERVICE_TOKEN_ID")
  fi
fi

if [[ -z "$SERVICE_TOKEN_SECRET" ]]; then
  if [[ -t 0 ]]; then
    echo -e "${YELLOW}请输入 Cloudflare Access Service Token Client Secret:${NC}"
    read -r -s -p "Service Token Secret: " SERVICE_TOKEN_SECRET
    echo ""
    SERVICE_TOKEN_SECRET=$(clean_val "$SERVICE_TOKEN_SECRET")
  fi
fi

if [[ -z "$SERVICE_TOKEN_ID" || -z "$SERVICE_TOKEN_SECRET" ]]; then
  error "缺少必选参数: SERVICE_TOKEN_ID 与 SERVICE_TOKEN_SECRET！"
  error "可通过参数 -i / -s 传入，详见 '$0 --help'。"
  exit 1
fi

# 3. 处理 --forward 规则 或默认 DOMAINS/PORTS
if [[ ${#FORWARD_RULES[@]} -gt 0 ]]; then
  PARSED_DOMAINS=()
  PARSED_PORTS=()
  for rule_str in "${FORWARD_RULES[@]}"; do
    IFS=',' read -r -a subrules <<< "$rule_str"
    for r in "${subrules[@]}"; do
      r=$(clean_val "$r")
      [[ -z "$r" ]] && continue
      if [[ "$r" != *:* ]]; then
        error "无效的转发规则格式: '$r'，必须为 'domain:port' 格式"
        exit 1
      fi
      d=$(clean_val "${r%%:*}")
      p=$(clean_val "${r##*:}")
      PARSED_DOMAINS+=("$d")
      PARSED_PORTS+=("$p")
    done
  done
  DOMAINS=$(IFS=,; echo "${PARSED_DOMAINS[*]}")
  PORTS=$(IFS=,; echo "${PARSED_PORTS[*]}")
fi

DOMAINS=$(clean_val "${DOMAINS:-$DEFAULT_DOMAINS}")
PORTS=$(clean_val "${PORTS:-$DEFAULT_PORTS}")
LISTEN_HOST=$(clean_val "${LISTEN_HOST:-$DEFAULT_LISTEN}")
PREFERRED_IP=$(clean_val "${PREFERRED_IP:-}")

# 4. 严格解析与校验域名、端口及优选 IP
IFS=',' read -r -a DOMAIN_LIST <<< "$DOMAINS"
IFS=',' read -r -a PORT_LIST <<< "$PORTS"

if [[ ${#DOMAIN_LIST[@]} -ne ${#PORT_LIST[@]} ]]; then
  error "域名列表数量 (${#DOMAIN_LIST[@]}) 与 端口列表数量 (${#PORT_LIST[@]}) 不匹配！"
  exit 1
fi

if [[ ${#DOMAIN_LIST[@]} -eq 0 ]]; then
  error "配置的转发规则列表不能为空！"
  exit 1
fi

CLEAN_DOMAINS=()
CLEAN_PORTS=()
declare -A SEEN_PORTS

for i in "${!DOMAIN_LIST[@]}"; do
  d=$(clean_val "${DOMAIN_LIST[i]}")
  p=$(clean_val "${PORT_LIST[i]}")

  if ! validate_domain "$d"; then
    error "规则 #$((i+1)) 域名校验失败: '$d'"
    exit 1
  fi

  if ! validate_port "$p"; then
    error "规则 #$((i+1)) 端口校验失败: '$p'"
    exit 1
  fi

  if [[ -n "${SEEN_PORTS[$p]}" ]]; then
    error "规则 #$((i+1)) 端口 $p 与 规则 #${SEEN_PORTS[$p]} 重复冲突！"
    exit 1
  fi
  SEEN_PORTS[$p]=$((i+1))

  if ! check_port_available "$p"; then
    if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
      warn "宿主机端口 $p 当前已被占用，启动服务时可能会监听冲突，请确认。"
    fi
  fi

  CLEAN_DOMAINS+=("$d")
  CLEAN_PORTS+=("$p")
done

if [[ -n "$PREFERRED_IP" ]]; then
  if ! validate_ip "$PREFERRED_IP"; then
    error "优选 IP 校验失败: '$PREFERRED_IP'"
    exit 1
  fi
fi

DOMAINS=$(IFS=,; echo "${CLEAN_DOMAINS[*]}")
PORTS=$(IFS=,; echo "${CLEAN_PORTS[*]}")

# 5. 编译 Docker 镜像 (使用宿主机网络)
build_docker_image

# 6. 安全创建独立加密配置文件 (/etc/cloudflare-access-tcp/access.env, 权限 600)
mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"

cat > "$ENV_FILE" <<EOF
# Cloudflare Access TCP Client Configuration
# Created at: $(date '+%Y-%m-%d %H:%M:%S')
SERVICE_TOKEN_ID=${SERVICE_TOKEN_ID}
SERVICE_TOKEN_SECRET=${SERVICE_TOKEN_SECRET}
DOMAINS=${DOMAINS}
PORTS=${PORTS}
LISTEN_HOST=${LISTEN_HOST}
PREFERRED_IP=${PREFERRED_IP}
NETWORK_MODE=${NETWORK_MODE}
CF_SUB_URL=${CF_SUB_URL}
CHECK_INTERVAL=${CHECK_INTERVAL_ARG}
FAIL_THRESHOLD=${FAIL_THRESHOLD_ARG}
LOG_LEVEL=info
EOF

chmod 600 "$ENV_FILE"
log "已安全写入凭据与环境配置文件: $ENV_FILE (权限: 600)"

# 7. 配置并生成 Systemd 服务文件 (持久化映射 /etc/cloudflare-access-tcp 卷)
log "正在配置 Systemd 服务文件: $SERVICE_FILE ..."

BIND_IP="127.0.0.1"
if [[ "$LISTEN_HOST" == "0.0.0.0" || "$LISTEN_HOST" == "all" ]]; then
  BIND_IP="0.0.0.0"
elif [[ "$LISTEN_HOST" == "localhost" || "$LISTEN_HOST" == "127.0.0.1" || -z "$LISTEN_HOST" ]]; then
  BIND_IP="127.0.0.1"
else
  BIND_IP="$LISTEN_HOST"
fi

DOCKER_PORT_FLAGS=()
for p in "${CLEAN_PORTS[@]}"; do
  DOCKER_PORT_FLAGS+=("-p" "${BIND_IP}:${p}:${p}")
done

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Access TCP Client Forwarder (${SERVICE_NAME})
Documentation=https://github.com/JayYang1991/vps-utils
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5s
TimeoutStartSec=0
KillMode=control-group
EnvironmentFile=${ENV_FILE}

ExecStartPre=-/usr/bin/docker rm -f ${CONTAINER_NAME}
ExecStart=/usr/bin/docker run --rm --name ${CONTAINER_NAME} \\
    --network bridge \\
    -v ${CONF_DIR}:${CONF_DIR} \\
    ${DOCKER_PORT_FLAGS[*]} \\
    --env-file ${ENV_FILE} \\
    ${IMAGE_NAME}
ExecStop=/usr/bin/docker stop -t 5 ${CONTAINER_NAME}

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$SERVICE_FILE"

# 8. 启用并启动 Systemd 服务
log "重载 Systemd 守护进程并启动服务..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

log "等待服务就绪..."
sleep 3

# 9. 校验与输出结果
if systemctl is-active --quiet "$SERVICE_NAME"; then
  echo ""
  echo -e "${GREEN}${BOLD}================================================================${NC}"
  echo -e "${GREEN}${BOLD}  Cloudflare Access TCP 客户端一键安装成功并已开启开机自启！  ${NC}"
  echo -e "${GREEN}${BOLD}================================================================${NC}"
  echo ""
  echo -e "${CYAN}服务配置信息概览:${NC}"
  echo -e "  • 服务名称:         ${BOLD}${SERVICE_NAME}${NC}"
  echo -e "  • 配置文件:         ${BOLD}${ENV_FILE}${NC} (权限 600)"
  echo -e "  • 待选 IP 文件:     ${BOLD}${CANDIDATES_FILE}${NC} (TOP 20 池)"
  echo -e "  • 监听地址:         ${BOLD}${LISTEN_HOST}${NC}"
  echo -e "  • 优选调度策略:     ${GREEN}每日凌晨 02:00~06:00 随机测速 + 实时 TCP 故障自动切换${NC}"
  echo -e "  • Service Token ID: $(mask_string "$SERVICE_TOKEN_ID")"
  echo ""
  echo -e "${CYAN}已配置的 TCP 转发列表:${NC}"
  for i in "${!CLEAN_DOMAINS[@]}"; do
    echo -e "  • 规则 #$((i+1)): ${YELLOW}${LISTEN_HOST}:${CLEAN_PORTS[i]}${NC}  ===>  ${CYAN}${CLEAN_DOMAINS[i]}${NC}"
  done
  echo ""
  echo -e "${CYAN}常用运维管理命令:${NC}"
  echo "  • 查看服务与优选状态: sudo bash $0 --status"
  echo "  • 查看 TOP 20 待选池: sudo bash $0 --candidates"
  echo "  • 立即执行全量测速:   sudo bash $0 --speedtest"
  echo "  • 查看实时运行日志:   sudo bash $0 --logs"
  echo "  • 测试端口连通性:     sudo bash $0 --test"
  echo "  • 重启转发服务:       sudo bash $0 --restart"
  echo "  • 卸载与清理:         sudo bash $0 --uninstall"
  echo -e "${GREEN}================================================================${NC}"
else
  error "服务启动失败！正在获取最近的错误日志..."
  journalctl -u "$SERVICE_NAME" -n 20 --no-pager || true
  exit 1
fi
