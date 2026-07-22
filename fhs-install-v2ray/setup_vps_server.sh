#!/usr/bin/env bash
# shellcheck disable=SC2268
#
# setup_vps_server.sh
# 通用 VPS 远程安装脚本，支持直接指定 IP 或自动创建 Vultr 实例。

# --- Configuration (Externalized with Defaults for Vultr) ---
MY_REGION="${VULTR_REGION:-nrt}"
MY_PLAN="${VULTR_PLAN:-vc2-1c-1gb}"
MY_OS="${VULTR_OS:-2284}" # Ubuntu 24.04
MY_HOST="${VULTR_HOST:-jayyang}"
MY_LABEL="${VULTR_LABEL:-ubuntu_2404}"
MY_TAG="${VULTR_TAG:-v2ray}"
MY_SSH_KEYS="${VULTR_SSH_KEYS:-}"
SCRIPT_ID="${VULTR_SCRIPT_ID:-}"
REPO_BRANCH="${V2RAY_REPO_BRANCH:-master}"

# --- Internal Variables ---
VPS_IP=""
SSH_USER="root"
USE_VULTR=false
FORCE_INSTALL=false
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# --- Helper Functions ---
show_help() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "General Options:"
  echo "  -i, --ip IP           Specify target VPS IP address for direct installation"
  echo "  -u, --user USER       Specify SSH username (default: root)"
  echo "  -f, --force           Force re-install (passed to installation script)"
  echo "  -h, --help            Show this help message"
  echo ""
  echo "Vultr Options:"
  echo "  --vultr               Enable automatic Vultr instance creation (if IP not provided)"
  echo ""
  echo "sing-box Configuration (Env Vars):"
  echo "  SINGBOX_PORT (default: 443)"
  echo "  SINGBOX_DOMAIN (default: www.cloudflare.com)"
  echo "  SINGBOX_UUID, SINGBOX_SHORT_ID, SINGBOX_LOG_LEVEL"
  echo "  SINGBOX_HY2_PORT (default: 123)"
  echo "  SINGBOX_HY2_DOMAIN (default: hy2.jayyang.cn)"
  echo "  SINGBOX_HY2_PASSWORD, SINGBOX_HY2_UP_MBPS, SINGBOX_HY2_DOWN_MBPS, SINGBOX_HY2_MASQUERADE"
}

log() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
  echo -e "${RED}[WARN]${NC} $1"
}

check_dependencies() {
  local deps=("curl" "ssh" "sed" "awk")
  if [[ "$USE_VULTR" == "true" ]]; then
    deps+=("vultr-cli")
  fi
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
      echo "Error: Dependency '$dep' is missing. Please install it."
      exit 1
    fi
  done
}

is_private_ip() {
  local ip=$1
  if [[ $ip =~ ^10\. ]] ||
    [[ $ip =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] ||
    [[ $ip =~ ^192\.168\. ]] ||
    [[ $ip =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
    return 0
  fi
  return 1
}

get_vultr_ip() {
  log "Fetching Vultr VPS IP for label: $MY_LABEL..."
  VPS_IP=$(vultr-cli instance list | grep "$MY_LABEL" | awk '{print $2}')
  local vps_id
  vps_id=$(vultr-cli instance list | grep "$MY_LABEL" | awk '{print $1}')

  if [[ -n "$VPS_IP" && "$VPS_IP" != "0.0.0.0" ]] && is_private_ip "$VPS_IP"; then
    log "IPv4 ($VPS_IP) is invalid or private. Attempting to fetch IPv6..."
    if [[ -n "$vps_id" ]]; then
      VPS_IP=$(vultr-cli instance ipv6 list "$vps_id" | grep -v "IP" | grep -v "==" | head -n1 | awk '{print $1}')
      if [[ -z "$VPS_IP" ]]; then
        VPS_IP=$(vultr-cli instance get "$vps_id" | grep "V6 MAIN IP" | awk '{print $4}')
      fi
    fi
  fi
  [[ -z "$VPS_IP" || "$VPS_IP" == "0.0.0.0" ]] && return 1
  return 0
}

check_ssh_until_success() {
  local host="$1"
  local user="$2"
  local port="${3:-22}"
  local timeout="${4:-4}"
  local max_attempts="${5:-60}"
  local interval="${6:-5}"

  log "Waiting for SSH to become available on $host:$port as $user..."
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    local output
    if output=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout="$timeout" -l "$user" -p "$port" "$host" "whoami" 2> /dev/null); then
      if [[ "$output" == "$user" ]]; then
        log "SSH connection successful."
        return 0
      fi
    fi
    [[ $attempt -lt $max_attempts ]] && sleep "$interval"
  done
  return 1
}

install_singbox() {
  local port="${SINGBOX_PORT:-443}"
  local domain="${SINGBOX_DOMAIN:-www.cloudflare.com}"
  local uuid="${SINGBOX_UUID:-auto}"
  local short_id="${SINGBOX_SHORT_ID:-auto}"
  local log_level="${SINGBOX_LOG_LEVEL:-info}"
  local hy2_port="${SINGBOX_HY2_PORT:-123}"
  local hy2_domain="${SINGBOX_HY2_DOMAIN:-hy2.jayyang.cn}"
  local hy2_password="${SINGBOX_HY2_PASSWORD:-auto}"
  local hy2_up_mbps="${SINGBOX_HY2_UP_MBPS:-200}"
  local hy2_down_mbps="${SINGBOX_HY2_DOWN_MBPS:-200}"
  local hy2_masquerade="${SINGBOX_HY2_MASQUERADE:-https://www.cloudflare.com}"
  local force_flag=""
  [[ "$FORCE_INSTALL" == "true" ]] && force_flag="--force"

  log "Starting remote installation on ${VPS_IP}..."
  
  local output
  output=$(
    ssh -T -o StrictHostKeyChecking=no "${SSH_USER}@${VPS_IP}" << eof
    sudo dpkg --configure -a || true
    curl -4 -L -q --retry 5 --retry-delay 10 -H 'Cache-Control: no-cache' -o /tmp/install-singbox-server.sh https://raw.githubusercontent.com/JayYang1991/fhs-install-v2ray/${REPO_BRANCH}/install-singbox-server.sh
    sudo bash /tmp/install-singbox-server.sh --port ${port} --domain ${domain} --uuid ${uuid} --short-id ${short_id} --log-level ${log_level} --hy2-port ${hy2_port} --hy2-domain ${hy2_domain} --hy2-password ${hy2_password} --hy2-up-mbps ${hy2_up_mbps} --hy2-down-mbps ${hy2_down_mbps} --hy2-masquerade '${hy2_masquerade}' ${force_flag}
eof
  )
  local ret_val=$?

  if [[ $ret_val -ne 0 ]]; then
    warn "远端安装 sing-box 失败"
    return 1
  fi
  log "远端 sing-box 安装成功！"
}

main() {
  while [[ "$#" -gt 0 ]]; do
    case $1 in
      -i | --ip) VPS_IP="$2"; shift 2 ;;
      -u | --user) SSH_USER="$2"; shift 2 ;;
      -f | --force) FORCE_INSTALL=true; shift ;;
      --vultr) USE_VULTR=true; shift ;;
      -h | --help) show_help; exit 0 ;;
      *) warn "Unknown parameter: $1"; show_help; exit 1 ;;
    esac
  done

  check_dependencies

  if [[ -n "$VPS_IP" ]]; then
    log "Using provided IP for installation: $VPS_IP"
  elif [[ "$USE_VULTR" == "true" ]]; then
    log "Starting Vultr automation..."
    if get_vultr_ip; then
      log "Instance already exists with IP: $VPS_IP"
    else
      log "Creating new Vultr instance..."
      local vultr_cmd=("vultr-cli" "instance" "create" "--region=$MY_REGION" "--plan=$MY_PLAN" "--os=$MY_OS" "--host=$MY_HOST" "--label=$MY_LABEL" "--tags=$MY_TAG" "--ipv6")
      [[ -n "$SCRIPT_ID" ]] && vultr_cmd+=("--script-id=$SCRIPT_ID")
      [[ -n "$MY_SSH_KEYS" ]] && vultr_cmd+=("--ssh-keys=$MY_SSH_KEYS")
      "${vultr_cmd[@]}" || exit 1
      while ! get_vultr_ip; do sleep 2; done
      log "New VPS IP: $VPS_IP"
    fi
  else
    warn "No IP provided and --vultr not specified. Nothing to do."
    show_help
    exit 1
  fi

  check_ssh_until_success "$VPS_IP" "$SSH_USER" || exit 1
  install_singbox
}

main "$@"
