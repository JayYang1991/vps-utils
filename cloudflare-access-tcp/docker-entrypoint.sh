#!/usr/bin/env bash
#
# docker-entrypoint.sh
# Cloudflare Access TCP Client Forwarder Container Entrypoint Script
# 负责在容器内解析环境变量、校验域名/端口、注入优选 IP 映射，
# 并发拉起 cloudflared access tcp 转发进程与 health_checker 后台健康检测/定时测速守护进程。
#

set -eo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" >&2; }

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

# --- 默认配置 ---
DEFAULT_DOMAINS="movies.19910417.xyz,movies1.19910417.xyz"
DEFAULT_PORTS="5000,5001"
DOMAINS=$(clean_val "${DOMAINS:-$DEFAULT_DOMAINS}")
PORTS=$(clean_val "${PORTS:-$DEFAULT_PORTS}")
LISTEN_HOST=$(clean_val "${LISTEN_HOST:-localhost}")
PREFERRED_IP=$(clean_val "${PREFERRED_IP:-}")
SERVICE_TOKEN_ID=$(clean_val "${SERVICE_TOKEN_ID:-}")
SERVICE_TOKEN_SECRET=$(clean_val "${SERVICE_TOKEN_SECRET:-}")
LOG_LEVEL=$(clean_val "${LOG_LEVEL:-info}")

CONF_DIR="/etc/cloudflare-access-tcp"
CANDIDATES_FILE="${CONF_DIR}/candidates.txt"
mkdir -p "$CONF_DIR"

# 导出供 Python 守护进程读取的环境变量
export DOMAINS
export PORTS
export LISTEN_HOST
export PREFERRED_IP
export SERVICE_TOKEN_ID
export SERVICE_TOKEN_SECRET
export CONF_DIR
export CANDIDATES_FILE
export STATUS_FILE="${CONF_DIR}/status.json"

# --- 校验函数 ---
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
    error "域名格式无效: $domain"
    return 1
  fi
  return 0
}

validate_port() {
  local port="$1"
  if [[ -z "$port" ]]; then
    error "端口不能为空"
    return 1
  fi
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    error "端口必须为纯数字整数: $port"
    return 1
  fi
  if (( port < 1 || port > 65535 )); then
    error "端口号超出有效范围 (1-65535): $port"
    return 1
  fi
  if [[ "$port" =~ ^0[0-9]+$ ]]; then
    error "端口号格式非法 (不能包含前导 0): $port"
    return 1
  fi
  return 0
}

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

# --- 检查必选参数 ---
if [[ -z "$SERVICE_TOKEN_ID" ]]; then
  error "缺少必选参数: SERVICE_TOKEN_ID (Cloudflare Access Service Token ID)"
  exit 1
fi

if [[ -z "$SERVICE_TOKEN_SECRET" ]]; then
  error "缺少必选参数: SERVICE_TOKEN_SECRET (Cloudflare Access Service Token Secret)"
  exit 1
fi

# --- 解析与校验域名/端口列表 ---
IFS=',' read -r -a DOMAIN_ARRAY <<< "$DOMAINS"
IFS=',' read -r -a PORT_ARRAY <<< "$PORTS"

if [[ ${#DOMAIN_ARRAY[@]} -ne ${#PORT_ARRAY[@]} ]]; then
  error "域名列表数量 (${#DOMAIN_ARRAY[@]}) 与 端口列表数量 (${#PORT_ARRAY[@]}) 不匹配！"
  error "DOMAINS: $DOMAINS"
  error "PORTS: $PORTS"
  exit 1
fi

if [[ ${#DOMAIN_ARRAY[@]} -eq 0 ]]; then
  error "转发规则列表不能为空！"
  exit 1
fi

# 严格校验每一个域名与端口
declare -A SEEN_PORTS
for i in "${!DOMAIN_ARRAY[@]}"; do
  d=$(clean_val "${DOMAIN_ARRAY[i]}")
  p=$(clean_val "${PORT_ARRAY[i]}")
  DOMAIN_ARRAY[i]="$d"
  PORT_ARRAY[i]="$p"

  if ! validate_domain "$d"; then
    error "规则 #$((i+1)) 域名校验失败: $d"
    exit 1
  fi

  if ! validate_port "$p"; then
    error "规则 #$((i+1)) 端口校验失败: $p"
    exit 1
  fi

  if [[ -n "${SEEN_PORTS[$p]}" ]]; then
    error "发现冲突重复的端口: $p (已被规则 #${SEEN_PORTS[$p]} 使用)"
    exit 1
  fi
  SEEN_PORTS[$p]=$((i+1))
done

# 校验优选 IP (若配置)
if [[ -n "$PREFERRED_IP" ]]; then
  if ! validate_ip "$PREFERRED_IP"; then
    error "优选 IP 校验失败: $PREFERRED_IP"
    exit 1
  fi
fi

# 脱敏打印 Token 信息
mask_token() {
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

echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}  Cloudflare Access TCP Client Forwarder Starting...  ${NC}"
echo -e "${CYAN}======================================================${NC}"
log "Service Token ID:     $(mask_token "$SERVICE_TOKEN_ID")"
log "Service Token Secret: ********************"
log "Container Listen:     0.0.0.0 (Bridge Isolation Mode)"
log "Host Listen Binding:  $LISTEN_HOST"
if [[ -n "$PREFERRED_IP" ]]; then
  log "Preferred IP (优选):  $PREFERRED_IP (所有域名共用解析)"
else
  log "Preferred IP (优选):  自动探测/待选池管理模式"
fi
log "Forward Rules Count:  ${#DOMAIN_ARRAY[@]}"

for i in "${!DOMAIN_ARRAY[@]}"; do
  log "  -> Rule #$((i+1)): 0.0.0.0:${PORT_ARRAY[i]} (Host: ${LISTEN_HOST}:${PORT_ARRAY[i]})  ===>  ${DOMAIN_ARRAY[i]}"
done
echo -e "${CYAN}------------------------------------------------------${NC}"

# --- 注入初始优选 IP 静态域名映射 (若配置) ---
if [[ -n "$PREFERRED_IP" ]]; then
  log "⚡ 正在向容器 /etc/hosts 注入初始优选 IP 映射 (${PREFERRED_IP}) ..."
  for target_d in "${DOMAIN_ARRAY[@]}"; do
    sed -i "/[[:space:]]${target_d}\$/d" /etc/hosts 2>/dev/null || true
    echo "${PREFERRED_IP} ${target_d}" >> /etc/hosts
    log "  -> [优选 DNS 映射] ${target_d}  ===>  ${PREFERRED_IP}"
  done
fi

# --- 进程级管理与信号捕获 ---
declare -A CHILD_PIDS
declare -A CRASH_COUNTS
declare -A LAST_CRASH_TIMES
HEALTH_CHECKER_PID=""

start_forward_process() {
  local idx="$1"
  local target_domain="${DOMAIN_ARRAY[idx]}"
  local listen_port="${PORT_ARRAY[idx]}"
  local listen_url="0.0.0.0:${listen_port}"

  cloudflared access tcp \
    --hostname "${target_domain}" \
    --url "${listen_url}" \
    --service-token-id "${SERVICE_TOKEN_ID}" \
    --service-token-secret "${SERVICE_TOKEN_SECRET}" \
    --loglevel "${LOG_LEVEL}" &
  
  local pid=$!
  CHILD_PIDS[$idx]=$pid
  log "规则 #$((idx+1)) [0.0.0.0:${listen_port} -> ${target_domain}] 转发进程已拉起 (PID: $pid)"
}

start_health_checker() {
  log "正在拉起健康检测与自动故障转移守护进程 (health_checker.py)..."
  python3 /app/health_checker.py &
  HEALTH_CHECKER_PID=$!
  log "健康检测与优选 IP 守护进程已启动 (PID: $HEALTH_CHECKER_PID)"
}

cleanup() {
  local exit_code="${1:-0}"
  echo ""
  warn "正在处理退出信号，准备停止所有子进程..."
  
  if [[ -n "$HEALTH_CHECKER_PID" ]] && kill -0 "$HEALTH_CHECKER_PID" 2>/dev/null; then
    kill -TERM "$HEALTH_CHECKER_PID" 2>/dev/null || true
  fi

  for idx in "${!DOMAIN_ARRAY[@]}"; do
    local pid="${CHILD_PIDS[$idx]}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  # 等待子进程退出
  for idx in "${!DOMAIN_ARRAY[@]}"; do
    local pid="${CHILD_PIDS[$idx]}"
    if [[ -n "$pid" ]]; then
      wait "$pid" 2>/dev/null || true
    fi
  done
  if [[ -n "$HEALTH_CHECKER_PID" ]]; then
    wait "$HEALTH_CHECKER_PID" 2>/dev/null || true
  fi

  log "所有转发与监控进程已安全退出。"
  exit "$exit_code"
}

trap 'cleanup 0' SIGTERM SIGINT SIGHUP SIGQUIT

# 初始拉起所有 cloudflared 进程
for i in "${!DOMAIN_ARRAY[@]}"; do
  start_forward_process "$i"
  CRASH_COUNTS[$i]=0
  LAST_CRASH_TIMES[$i]=0
done

# 启动后台健康检测守护进程
start_health_checker

log "所有 cloudflared TCP 转发进程与健康检测守护已就绪！开启运行监听..."

# 持续自愈监控循环
while true; do
  current_time=$(date +%s)
  
  # 监控 cloudflared 转发进程
  for i in "${!DOMAIN_ARRAY[@]}"; do
    pid="${CHILD_PIDS[$i]}"
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
      # 重新拉起
      start_forward_process "$i"
    fi
  done

  # 监控 health_checker 进程
  if [[ -z "$HEALTH_CHECKER_PID" ]] || ! kill -0 "$HEALTH_CHECKER_PID" 2>/dev/null; then
    warn "⚠️ 检测到 health_checker.py 异常退出，正在重新拉起..."
    start_health_checker
  fi

  sleep 1.5
done
