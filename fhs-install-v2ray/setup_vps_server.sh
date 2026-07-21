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
MY_SSH_KEYS="${VULTR_SSH_KEYS:-c5e8bf26-ab13-454a-a827-c2afff006a67,fa784b8e-c8d9-40d3-ab66-c7b0177a4013}"
SCRIPT_ID="${VULTR_SCRIPT_ID:-89005eb6-6e67-40fb-b873-c8399295f05e}"
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
  local vps_id=$(vultr-cli instance list | grep "$MY_LABEL" | awk '{print $1}')

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
  local force_flag=""
  [[ "$FORCE_INSTALL" == "true" ]] && force_flag="--force"

  log "Starting remote installation on ${VPS_IP}..."
  
  local output
  output=$(
    ssh -T -o StrictHostKeyChecking=no "${SSH_USER}@${VPS_IP}" << eof
    sudo dpkg --configure -a || true
    curl -4 -L -q --retry 5 --retry-delay 10 -H 'Cache-Control: no-cache' -o /tmp/install-singbox-server.sh https://raw.githubusercontent.com/JayYang1991/fhs-install-v2ray/${REPO_BRANCH}/install-singbox-server.sh
    sudo bash /tmp/install-singbox-server.sh --port ${port} --domain ${domain} --uuid ${uuid} --short-id ${short_id} --log-level ${log_level} ${force_flag}
eof
  )
  local ret_val=$?

  if [[ $ret_val -ne 0 ]]; then
    warn "远端安装 sing-box 失败"
    return 1
  fi

  local remote_client_config=$(echo "$output" | awk -F': ' '/客户端配置文件/ {print $2}' | tail -n 1 | tr -d '\r')
  if [[ -n "$remote_client_config" ]]; then
    local local_dest
    local_dest=$(mktemp -p /tmp singbox_client_config.XXXXXX.json)
    log "Downloading client config from remote..."
    if scp -o StrictHostKeyChecking=no "${SSH_USER}@${VPS_IP}:${remote_client_config}" "$local_dest" > /dev/null 2>&1; then
      log "Done. Client config saved at: $(readlink -f "$local_dest")"
    else
      warn "Failed to download client config from ${VPS_IP}"
    fi
  fi
}

main() {
  while [[ "$#" -gt 0 ]]; do
    case $1 in
      -i | --ip) VPS_IP="$2"; shift ;;
      -u | --user) SSH_USER="$2"; shift ;;
      -f | --force) FORCE_INSTALL=true ;;
      --vultr) USE_VULTR=true ;;
      -h | --help) show_help; exit 0 ;;
      *) warn "Unknown parameter: $1"; show_help; exit 1 ;;
    esac
    shift
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
      vultr-cli instance create --region="$MY_REGION" --plan="$MY_PLAN" --os="$MY_OS" --script-id="$SCRIPT_ID" --host="$MY_HOST" --label="$MY_LABEL" --tags="$MY_TAG" --ssh-keys="$MY_SSH_KEYS" --ipv6 || exit 1
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
