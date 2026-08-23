#!/usr/bin/env bash
#
# docker-entrypoint.sh
# Cloudflare Access TCP Client Forwarder Container Entrypoint Script
# 负责在容器内解析环境变量、执行严格的域名与端口校验，并发拉起多个 cloudflared access tcp 进程，
# 并内置进程级热自愈监控与防颠簸重试机制。
#

set -eo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" >&2; }

# --- 默认配置 ---
DEFAULT_DOMAINS="movies.19910417.xyz,movies1.19910417.xyz"
DEFAULT_PORTS="5000,5001"
DOMAINS="${DOMAINS:-$DEFAULT_DOMAINS}"
PORTS="${PORTS:-$DEFAULT_PORTS}"
LISTEN_HOST="${LISTEN_HOST:-localhost}"
SERVICE_TOKEN_ID="${SERVICE_TOKEN_ID:-}"
SERVICE_TOKEN_SECRET="${SERVICE_TOKEN_SECRET:-}"
LOG_LEVEL="${LOG_LEVEL:-info}"

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
  # RFC 1123 规范域名正则
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
  d=$(echo "${DOMAIN_ARRAY[i]}" | xargs)
  p=$(echo "${PORT_ARRAY[i]}" | xargs)
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
log "Listen Host:          $LISTEN_HOST"
log "Forward Rules Count:  ${#DOMAIN_ARRAY[@]}"

for i in "${!DOMAIN_ARRAY[@]}"; do
  log "  -> Rule #$((i+1)): ${LISTEN_HOST}:${PORT_ARRAY[i]}  ===>  ${DOMAIN_ARRAY[i]}"
done
echo -e "${CYAN}------------------------------------------------------${NC}"

# --- 进程级自愈管理与信号捕获 ---
declare -A CHILD_PIDS
declare -A CRASH_COUNTS
declare -A LAST_CRASH_TIMES

start_forward_process() {
  local idx="$1"
  local target_domain="${DOMAIN_ARRAY[idx]}"
  local listen_port="${PORT_ARRAY[idx]}"
  local listen_url="${LISTEN_HOST}:${listen_port}"

  cloudflared access tcp \
    --hostname "${target_domain}" \
    --url "${listen_url}" \
    --service-token-id "${SERVICE_TOKEN_ID}" \
    --service-token-secret "${SERVICE_TOKEN_SECRET}" \
    --loglevel "${LOG_LEVEL}" &
  
  local pid=$!
  CHILD_PIDS[$idx]=$pid
  log "规则 #$((idx+1)) [${listen_url} -> ${target_domain}] 转发进程已成功拉起 (PID: $pid)"
}

cleanup() {
  local exit_code="${1:-0}"
  echo ""
  warn "正在处理退出信号，准备停止所有 cloudflared access tcp 转发进程..."
  for idx in "${!DOMAIN_ARRAY[@]}"; do
    local pid="${CHILD_PIDS[$idx]}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  for idx in "${!DOMAIN_ARRAY[@]}"; do
    local pid="${CHILD_PIDS[$idx]}"
    if [[ -n "$pid" ]]; then
      wait "$pid" 2>/dev/null || true
    fi
  done
  log "所有转发进程已安全退出。"
  exit "$exit_code"
}

trap 'cleanup 0' SIGTERM SIGINT SIGHUP SIGQUIT

# 初始拉起所有 cloudflared 进程
for i in "${!DOMAIN_ARRAY[@]}"; do
  start_forward_process "$i"
  CRASH_COUNTS[$i]=0
  LAST_CRASH_TIMES[$i]=0
done

log "所有 cloudflared TCP 转发进程已成功启动！正在监听连接并开启自愈守护..."

# 持续自愈监控循环
while true; do
  current_time=$(date +%s)
  for i in "${!DOMAIN_ARRAY[@]}"; do
    pid="${CHILD_PIDS[$i]}"
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
      warn "⚠️ 检测到规则 #$((i+1)) [${DOMAIN_ARRAY[i]}:${PORT_ARRAY[i]}] 转发进程 (原 PID: ${pid:-none}) 异常退出！"
      
      # 防颠簸判定 (10秒内连续崩溃超过5次视为致命错误，交由 Systemd 兜底)
      last_crash="${LAST_CRASH_TIMES[$i]:-0}"
      time_diff=$((current_time - last_crash))
      
      if (( time_diff < 10 )); then
        CRASH_COUNTS[$i]=$(( ${CRASH_COUNTS[$i]:-0} + 1 ))
      else
        CRASH_COUNTS[$i]=1
      fi
      LAST_CRASH_TIMES[$i]=$current_time

      if (( ${CRASH_COUNTS[$i]} > 5 )); then
        error "❌ 规则 #$((i+1)) 在 10 秒内连续崩溃超过 5 次，可能存在凭证失效或配置错误！"
        error "正在退出容器以触发 Systemd 容器级自愈守护..."
        cleanup 1
      fi

      log "🔄 正在执行单进程级热自愈，重新拉起规则 #$((i+1)) ..."
      start_forward_process "$i"
    fi
  done
  sleep 2
done
