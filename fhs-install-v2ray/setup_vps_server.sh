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
VULTR_VPS_ID=""
SSH_USER="root"
SSH_PASS=""
USE_VULTR=false
FORCE_INSTALL=false
LOCAL_PUB_KEY=""
LOCAL_KEY_PATH=""
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
  echo "  -p, --pass PASS       Specify SSH password (optional for key injection)"
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

get_local_public_key() {
  if [[ -n "$LOCAL_PUB_KEY" ]]; then
    return 0
  fi

  local key_candidates=(
    "$HOME/.ssh/id_ed25519.pub"
    "$HOME/.ssh/id_rsa.pub"
    "$HOME/.ssh/id_ecdsa.pub"
    "$HOME/.ssh/id_dsa.pub"
  )

  for key_file in "${key_candidates[@]}"; do
    if [[ -f "$key_file" ]]; then
      LOCAL_KEY_PATH="$key_file"
      LOCAL_PUB_KEY=$(tr -d '\r\n' < "$key_file")
      return 0
    fi
  done

  log "No local SSH public key found. Generating a new ed25519 key pair..."
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  if ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" > /dev/null 2>&1; then
    LOCAL_KEY_PATH="$HOME/.ssh/id_ed25519.pub"
    LOCAL_PUB_KEY=$(tr -d '\r\n' < "$LOCAL_KEY_PATH")
    log "Generated SSH key at: $LOCAL_KEY_PATH"
    return 0
  else
    warn "Failed to generate local SSH key pair."
    return 1
  fi
}

ensure_vultr_ssh_key() {
  get_local_public_key || return 0
  [[ -z "$LOCAL_PUB_KEY" ]] && return 0

  log "Checking local SSH key in Vultr account..."
  local hostname_str
  hostname_str=$(hostname 2>/dev/null || echo "client")
  local key_name="vps-utils-${hostname_str}"
  local vultr_key_id=""

  vultr_key_id=$(vultr-cli ssh-key list 2>/dev/null | grep "$key_name" | awk '{print $1}' | head -n1)

  if [[ -z "$vultr_key_id" ]]; then
    log "Uploading local SSH key ($LOCAL_KEY_PATH) to Vultr..."
    vultr-cli ssh-key create --name "$key_name" --key "$LOCAL_PUB_KEY" > /dev/null 2>&1 || true
    vultr_key_id=$(vultr-cli ssh-key list 2>/dev/null | grep "$key_name" | awk '{print $1}' | head -n1)
  fi

  if [[ -n "$vultr_key_id" ]]; then
    log "Using Vultr SSH Key ID: $vultr_key_id"
    if [[ -n "$MY_SSH_KEYS" ]]; then
      if [[ ! ",$MY_SSH_KEYS," =~ ,"$vultr_key_id", ]]; then
        MY_SSH_KEYS="${MY_SSH_KEYS},${vultr_key_id}"
      fi
    else
      MY_SSH_KEYS="$vultr_key_id"
    fi
  fi
}

get_vultr_instance_password() {
  local vps_id="$1"
  [[ -z "$vps_id" ]] && return 1

  local pass=""
  if command -v python3 >/dev/null 2>&1; then
    pass=$(vultr-cli instance get "$vps_id" -o json 2>/dev/null | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    inst = data.get("instance", data)
    for k in ["default_password", "main_pass", "password", "kvm"]:
        v = inst.get(k)
        if v and isinstance(v, str) and not v.startswith("Error"):
            print(v)
            sys.exit(0)
except Exception:
    pass
' 2>/dev/null)
  fi

  if [[ -z "$pass" ]]; then
    pass=$(vultr-cli instance get "$vps_id" 2>/dev/null | grep -iE "(password|main pass)" | head -n1 | awk -F':' '{print $2}' | tr -d ' \r\n\t')
  fi

  if [[ "$pass" =~ "Error" || "$pass" =~ "error" ]]; then
    pass=""
  fi

  echo "$pass"
}

copy_ssh_key_with_password() {
  local user="$1"
  local host="$2"
  local password="$3"
  local pub_key="$4"

  if [[ -z "$password" ]]; then
    return 1
  fi

  local remote_cmd="mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qF '${pub_key}' ~/.ssh/authorized_keys || echo '${pub_key}' >> ~/.ssh/authorized_keys"

  # Method 1: sshpass if installed
  if command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$password" ssh -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      "${user}@${host}" "$remote_cmd" >/dev/null 2>&1
    return $?
  fi

  # Method 2: Base64-safe OpenSSH native SSH_ASKPASS
  local pass_b64
  pass_b64=$(echo -n "$password" | base64 -w0 2>/dev/null || echo -n "$password" | base64 2>/dev/null)

  local askpass_script
  askpass_script=$(mktemp -t vps_askpass.XXXXXX 2>/dev/null || mktemp /tmp/vps_askpass.XXXXXX)
  cat << eof > "$askpass_script"
#!/bin/sh
echo -n "${pass_b64}" | base64 -d 2>/dev/null || echo -n "${pass_b64}" | base64 --decode
echo ""
eof
  chmod 700 "$askpass_script"

  SSH_ASKPASS="$askpass_script" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" \
  ssh -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      "${user}@${host}" "$remote_cmd" >/dev/null 2>&1
  local res=$?
  rm -f "$askpass_script"
  return $res
}

ensure_remote_authorized_keys() {
  get_local_public_key || return 1
  [[ -z "$LOCAL_PUB_KEY" ]] && return 1

  if ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${VPS_IP}" "whoami" >/dev/null 2>&1; then
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes "${SSH_USER}@${VPS_IP}" bash -s << eof > /dev/null 2>&1
      mkdir -p ~/.ssh
      chmod 700 ~/.ssh
      touch ~/.ssh/authorized_keys
      chmod 600 ~/.ssh/authorized_keys
      if ! grep -qF "${LOCAL_PUB_KEY}" ~/.ssh/authorized_keys; then
        echo "${LOCAL_PUB_KEY}" >> ~/.ssh/authorized_keys
      fi
eof
    log "Local SSH public key verified on remote server (passwordless login active)."
    return 0
  fi

  local vps_pass="${SSH_PASS:-}"

  if [[ -z "$vps_pass" && "$USE_VULTR" == "true" && -n "$VULTR_VPS_ID" ]]; then
    log "Fetching instance default password from Vultr for SSH key injection..."
    vps_pass=$(get_vultr_instance_password "$VULTR_VPS_ID")
  fi

  if [[ -n "$vps_pass" ]]; then
    log "Attempting SSH public key injection using retrieved password..."
    if copy_ssh_key_with_password "$SSH_USER" "$VPS_IP" "$vps_pass" "$LOCAL_PUB_KEY"; then
      log "Local SSH public key successfully installed on remote server!"
      return 0
    fi
  fi

  if [[ -t 0 ]]; then
    warn "Automated password retrieval failed or token expired."
    echo -n "Please enter SSH password for ${SSH_USER}@${VPS_IP}: "
    read -r -s vps_pass
    echo ""
    if [[ -n "$vps_pass" ]]; then
      log "Installing SSH public key using user-provided password..."
      if copy_ssh_key_with_password "$SSH_USER" "$VPS_IP" "$vps_pass" "$LOCAL_PUB_KEY"; then
        log "Local SSH public key successfully installed on remote server!"
        return 0
      fi
    fi
  fi

  warn "Could not automatically inject SSH key using password."
  return 1
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
  VULTR_VPS_ID=$(vultr-cli instance list | grep "$MY_LABEL" | awk '{print $1}')

  if [[ -n "$VPS_IP" && "$VPS_IP" != "0.0.0.0" ]] && is_private_ip "$VPS_IP"; then
    log "IPv4 ($VPS_IP) is invalid or private. Attempting to fetch IPv6..."
    if [[ -n "$VULTR_VPS_ID" ]]; then
      VPS_IP=$(vultr-cli instance ipv6 list "$VULTR_VPS_ID" | grep -v "IP" | grep -v "==" | head -n1 | awk '{print $1}')
      if [[ -z "$VPS_IP" ]]; then
        VPS_IP=$(vultr-cli instance get "$VULTR_VPS_ID" | grep "V6 MAIN IP" | awk '{print $4}')
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

  log "Waiting for SSH service on $host:$port as $user..."
  local key_injected=false

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    # 1. Check if key auth already works
    if ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout="$timeout" -l "$user" -p "$port" "$host" "whoami" 2>/dev/null | grep -q "^${user}$"; then
      log "SSH connection successful (key authentication active)."
      ensure_remote_authorized_keys >/dev/null 2>&1 || true
      return 0
    fi

    # 2. Check if SSH port 22 is open and accepting logins
    local ssh_check
    ssh_check=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout="$timeout" -l "$user" -p "$port" "$host" "exit" 2>&1 || true)
    if [[ "$ssh_check" =~ "Permission denied" ]] || [[ "$ssh_check" =~ "password" ]]; then
      if [[ "$key_injected" == "false" ]]; then
        key_injected=true
        if ensure_remote_authorized_keys; then
          if ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout="$timeout" -l "$user" -p "$port" "$host" "whoami" 2>/dev/null | grep -q "^${user}$"; then
            log "SSH connection successful after key injection."
            return 0
          fi
        fi
      fi
    fi

    [[ $attempt -lt $max_attempts ]] && sleep "$interval"
  done

  warn "Failed to establish SSH connection to $host:$port"
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
    ssh -T -o StrictHostKeyChecking=no -o BatchMode=yes "${SSH_USER}@${VPS_IP}" << eof
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
      -p | --pass) SSH_PASS="$2"; shift 2 ;;
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
    ensure_vultr_ssh_key
    if get_vultr_ip; then
      log "Instance already exists with IP: $VPS_IP (ID: $VULTR_VPS_ID)"
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
