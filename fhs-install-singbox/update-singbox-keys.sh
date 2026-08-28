#!/usr/bin/env bash
# shellcheck disable=SC2268
#
# sing-box Server Key & Domain Update Script
# Reference: https://sing-box.sagernet.org/
#
# Description:
#   用于更新/重置 sing-box 服务端各项密钥、凭证与网络参数：
#   - VLESS UUID
#   - Reality Keypair (PrivateKey & PublicKey)
#   - Reality Short ID
#   - Reality SNI 伪装域名 (dl.google.com 等)
#   - SOCKS5 入站用户名与密码
#   - SOCKS 出站代理端口与目标
#   - VLESS WS 传输路径与 Host
#
# ===================== Color Output =====================
if [[ -t 1 ]] && [[ -n "$TERM" ]] && [[ "$TERM" != "dumb" ]] && command -v tput > /dev/null 2>&1; then
  red=$(tput setaf 1 2> /dev/null || echo "")
  green=$(tput setaf 2 2> /dev/null || echo "")
  aoi=$(tput setaf 6 2> /dev/null || echo "")
  yellow=$(tput setaf 3 2> /dev/null || echo "")
  reset=$(tput sgr0 2> /dev/null || echo "")
else
  red=""
  green=""
  aoi=""
  yellow=""
  reset=""
fi

set -e

CONFIG_PATH="/etc/sing-box/config.json"
UPDATE_UUID=false
UPDATE_REALITY=false
UPDATE_SHORT_ID=false
UPDATE_DOMAIN=false
UPDATE_SOCKS=false
UPDATE_SOCKS_PORT=false
UPDATE_WS=false
UPDATE_SOCKS_OUT=false

CUSTOM_UUID=""
CUSTOM_SHORT_ID=""
CUSTOM_DOMAIN=""
CUSTOM_SOCKS_USER=""
CUSTOM_SOCKS_PASS=""
CUSTOM_SOCKS_PORT=""
CUSTOM_WS_PATH=""
CUSTOM_WS_HOST=""
CUSTOM_SOCKS_OUT_SERVER=""
CUSTOM_SOCKS_OUT_PORT=""

ASSUME_YES=false
EXPLICIT_OPTION=false

NEW_UUID=""
NEW_PRIVATE_KEY=""
NEW_PUBLIC_KEY=""
NEW_SHORT_ID=""
NEW_SOCKS_USER=""
NEW_SOCKS_PASS=""

show_help() {
  echo "用法: $0 [选项]"
  echo ""
  echo "选项:"
  echo "  -a, --all                      更新所有密钥与凭据 (UUID, Reality 密钥对, Short ID, SOCKS 凭据)"
  echo "  --uuid [UUID]                  更新 VLESS UUID (可选自定义 UUID，默认自动生成)"
  echo "  --reality-key, --private-key    重置 Reality 密钥对 (PrivateKey 与 PublicKey)"
  echo "  --short-id [SHORT_ID]          更新 Reality Short ID (可选自定义 8 位十六进制，默认自动生成)"
  echo "  --domain DOMAIN                更新 Reality SNI 伪装域名 (例如: dl.google.com)"
  echo "  --socks-user USER              更新 SOCKS5 入站用户名"
  echo "  --socks-pass PASS              更新 SOCKS5 入站密码 (不填参数则自动随机生成)"
  echo "  --socks-port PORT              更新 SOCKS5 入站监听端口 (例如: 10086)"
  echo "  --ws-path PATH                 更新 VLESS WS 路径 (例如: /custom-ws-path)"
  echo "  --ws-host HOST                 更新 VLESS WS 伪装 Host (例如: proxy.19910417.xyz)"
  echo "  --socks-out-port PORT          更新 SOCKS 出站代理端口 (默认 2080)"
  echo "  --socks-out-server IP          更新 SOCKS 出站代理 IP (默认 127.0.0.1)"
  echo "  -c, --config PATH              指定配置文件路径 (默认: /etc/sing-box/config.json)"
  echo "  -y, --yes                      跳过确认提示直接执行"
  echo "  -h, --help                     显示本帮助信息"
  echo ""
  echo "示例:"
  echo "  $0                            # 重新生成所有密钥与凭据"
  echo "  $0 -y                         # 非交互式重新生成所有密钥"
  echo "  $0 --domain dl.google.com -y  # 仅更新 Reality SNI 伪装域名"
  echo "  $0 --uuid -y                  # 仅更新 VLESS UUID"
}

check_if_running_as_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "${red}error: 请使用 root 权限运行此脚本${reset}"
    exit 1
  fi
}

identify_the_operating_system() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS="$ID"
  else
    echo "${red}error: 无法检测操作系统类型${reset}"
    exit 1
  fi
}

install_dependencies() {
  if ! command -v python3 > /dev/null 2>&1 || ! command -v openssl > /dev/null 2>&1; then
    echo "${aoi}info: 正在检查与安装必要依赖...${reset}"
    if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
      export DEBIAN_FRONTEND=noninteractive
      dpkg --configure -a || true
      apt update -y && apt install -y python3 openssl uuid-runtime
    elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]] || [[ "$OS" == "fedora" ]]; then
      dnf install -y python3 openssl util-linux
    elif [[ "$OS" == "arch" ]]; then
      pacman -S --noconfirm --needed python openssl util-linux
    fi
  fi
}

generate_uuid() {
  if command -v uuidgen > /dev/null 2>&1; then
    uuidgen
  else
    python3 -c "import uuid; print(uuid.uuid4())"
  fi
}

generate_short_id() {
  if command -v openssl > /dev/null 2>&1; then
    openssl rand -hex 4
  else
    python3 -c "import secrets; print(secrets.token_hex(4))"
  fi
}

generate_reality_keypair() {
  if ! command -v sing-box > /dev/null 2>&1; then
    echo "${red}error: 未找到 sing-box 命令，无法生成 Reality 密钥对${reset}"
    exit 1
  fi
  local key_output
  key_output=$(sing-box generate reality-keypair 2>&1)
  NEW_PRIVATE_KEY=$(echo "$key_output" | awk '/PrivateKey/ {print $2}')
  NEW_PUBLIC_KEY=$(echo "$key_output" | awk '/PublicKey/ {print $2}')
  if [[ -z "$NEW_PRIVATE_KEY" || -z "$NEW_PUBLIC_KEY" ]]; then
    echo "${red}error: 解析 sing-box Reality 密钥对失败${reset}"
    exit 1
  fi
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--all)
        UPDATE_UUID=true
        UPDATE_REALITY=true
        UPDATE_SHORT_ID=true
        UPDATE_SOCKS=true
        EXPLICIT_OPTION=true
        shift
        ;;
      --uuid)
        UPDATE_UUID=true
        EXPLICIT_OPTION=true
        if [[ -n "$2" && "$2" != -* ]]; then
          CUSTOM_UUID="$2"
          shift 2
        else
          shift 1
        fi
        ;;
      --reality-key|--reality|--private-key)
        UPDATE_REALITY=true
        EXPLICIT_OPTION=true
        shift
        ;;
      --short-id)
        UPDATE_SHORT_ID=true
        EXPLICIT_OPTION=true
        if [[ -n "$2" && "$2" != -* ]]; then
          CUSTOM_SHORT_ID="$2"
          shift 2
        else
          shift 1
        fi
        ;;
      --domain|--reality-domain)
        UPDATE_DOMAIN=true
        EXPLICIT_OPTION=true
        if [[ -n "$2" && "$2" != -* ]]; then
          CUSTOM_DOMAIN="$2"
          shift 2
        else
          echo "${red}error: --domain 需要指定域名参数 (例如: --domain dl.google.com)${reset}"
          exit 1
        fi
        ;;
      --socks-user)
        UPDATE_SOCKS=true
        EXPLICIT_OPTION=true
        if [[ -n "$2" && "$2" != -* ]]; then
          CUSTOM_SOCKS_USER="$2"
          shift 2
        else
          shift 1
        fi
        ;;
      --socks-pass)
        UPDATE_SOCKS=true
        EXPLICIT_OPTION=true
        if [[ -n "$2" && "$2" != -* ]]; then
          CUSTOM_SOCKS_PASS="$2"
          shift 2
        else
          shift 1
        fi
        ;;
      --socks-port)
        UPDATE_SOCKS_PORT=true
        EXPLICIT_OPTION=true
        if [[ -n "$2" && "$2" != -* ]]; then
          CUSTOM_SOCKS_PORT="$2"
          shift 2
        else
          shift 1
        fi
        ;;
      --ws-path)
        UPDATE_WS=true
        EXPLICIT_OPTION=true
        if [[ -n "$2" && "$2" != -* ]]; then
          CUSTOM_WS_PATH="$2"
          shift 2
        else
          shift 1
        fi
        ;;
      --ws-host)
        UPDATE_WS=true
        EXPLICIT_OPTION=true
        if [[ -n "$2" && "$2" != -* ]]; then
          CUSTOM_WS_HOST="$2"
          shift 2
        else
          shift 1
        fi
        ;;
      --socks-out-port)
        UPDATE_SOCKS_OUT=true
        EXPLICIT_OPTION=true
        if [[ -n "$2" && "$2" != -* ]]; then
          CUSTOM_SOCKS_OUT_PORT="$2"
          shift 2
        else
          shift 1
        fi
        ;;
      --socks-out-server)
        UPDATE_SOCKS_OUT=true
        EXPLICIT_OPTION=true
        if [[ -n "$2" && "$2" != -* ]]; then
          CUSTOM_SOCKS_OUT_SERVER="$2"
          shift 2
        else
          shift 1
        fi
        ;;
      -c|--config)
        CONFIG_PATH="$2"
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
        echo "${red}error: 未知参数: $1${reset}"
        show_help
        exit 1
        ;;
    esac
  done

  if [[ "$EXPLICIT_OPTION" == "false" ]]; then
    UPDATE_UUID=true
    UPDATE_REALITY=true
    UPDATE_SHORT_ID=true
    UPDATE_SOCKS=true
  fi
}

main() {
  parse_arguments "$@"

  check_if_running_as_root
  identify_the_operating_system
  install_dependencies

  if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "${red}error: 未找到配置文件: $CONFIG_PATH${reset}"
    exit 1
  fi

  if ! command -v sing-box > /dev/null 2>&1; then
    echo "${red}error: 未找到 sing-box 执行程序${reset}"
    exit 1
  fi

  if [[ "$UPDATE_UUID" == "true" ]]; then
    if [[ -z "$CUSTOM_UUID" || "$CUSTOM_UUID" == "auto" ]]; then
      NEW_UUID=$(generate_uuid)
    else
      if ! [[ "$CUSTOM_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        echo "${red}error: 无效的 UUID 格式: $CUSTOM_UUID${reset}"
        exit 1
      fi
      NEW_UUID="$CUSTOM_UUID"
    fi
  fi

  if [[ "$UPDATE_REALITY" == "true" ]]; then
    generate_reality_keypair
  fi

  if [[ "$UPDATE_SHORT_ID" == "true" ]]; then
    if [[ -z "$CUSTOM_SHORT_ID" || "$CUSTOM_SHORT_ID" == "auto" ]]; then
      NEW_SHORT_ID=$(generate_short_id)
    else
      if ! [[ "$CUSTOM_SHORT_ID" =~ ^[0-9a-fA-F]+$ ]]; then
        echo "${red}error: 无效的 Short ID 格式 (需为十六进制字符串): $CUSTOM_SHORT_ID${reset}"
        exit 1
      fi
      NEW_SHORT_ID="$CUSTOM_SHORT_ID"
    fi
  fi

  if [[ "$UPDATE_SOCKS" == "true" ]]; then
    if [[ -n "$CUSTOM_SOCKS_USER" ]]; then
      NEW_SOCKS_USER="$CUSTOM_SOCKS_USER"
    else
      NEW_SOCKS_USER="user_$(openssl rand -hex 3)"
    fi
    if [[ -n "$CUSTOM_SOCKS_PASS" ]]; then
      NEW_SOCKS_PASS="$CUSTOM_SOCKS_PASS"
    else
      NEW_SOCKS_PASS=$(openssl rand -hex 8)
    fi
  fi

  echo "${aoi}▶ 准备更新服务端 sing-box 配置${reset}"
  echo "配置文件: $CONFIG_PATH"
  [[ "$UPDATE_UUID" == "true" ]] && echo "  - VLESS UUID        : $NEW_UUID"
  [[ "$UPDATE_REALITY" == "true" ]] && echo "  - Reality PrivateKey: $NEW_PRIVATE_KEY"
  [[ "$UPDATE_REALITY" == "true" ]] && echo "  - Reality PublicKey : $NEW_PUBLIC_KEY"
  [[ "$UPDATE_SHORT_ID" == "true" ]] && echo "  - Reality Short ID  : $NEW_SHORT_ID"
  [[ "$UPDATE_DOMAIN" == "true" ]] && echo "  - Reality SNI 域名  : $CUSTOM_DOMAIN"
  [[ "$UPDATE_SOCKS" == "true" ]] && echo "  - SOCKS5 用户名/密码 : ${NEW_SOCKS_USER} / ${NEW_SOCKS_PASS}"
  [[ "$UPDATE_SOCKS_PORT" == "true" ]] && echo "  - SOCKS5 监听端口   : $CUSTOM_SOCKS_PORT"
  [[ "$UPDATE_WS" == "true" ]] && echo "  - WS Path / Host    : ${CUSTOM_WS_PATH:-未变} / ${CUSTOM_WS_HOST:-未变}"
  [[ "$UPDATE_SOCKS_OUT" == "true" ]] && echo "  - SOCKS 出站代理    : ${CUSTOM_SOCKS_OUT_SERVER:-127.0.0.1}:${CUSTOM_SOCKS_OUT_PORT:-2080}"
  echo ""

  if [[ "$ASSUME_YES" == "false" ]] && [[ -t 0 ]]; then
    read -r -p "是否确认更新上述配置并重启 sing-box 服务？[y/N] " confirm
    case "$confirm" in
      [yY][eE][sS]|[yY])
        ;;
      *)
        echo "${yellow}操作已取消${reset}"
        exit 0
        ;;
    esac
  fi

  local timestamp
  timestamp=$(date +%Y%m%d%H%M%S)

  local user_home="${HOME:-/root}"
  if [[ -n "$SUDO_USER" && "$SUDO_USER" != "root" ]]; then
    local sudo_user_home
    sudo_user_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || echo "")
    if [[ -n "$sudo_user_home" && -d "$sudo_user_home" ]]; then
      user_home="$sudo_user_home"
    fi
  fi

  local user_backup_dir="${user_home}/singbox-backups"
  mkdir -p "$user_backup_dir" || true
  local user_backup_path="${user_backup_dir}/config.json.bak.${timestamp}"
  cp "$CONFIG_PATH" "$user_backup_path" || true
  if [[ -n "$SUDO_USER" && "$SUDO_USER" != "root" ]]; then
    chown -R "$SUDO_USER" "$user_backup_dir" 2>/dev/null || true
  fi
  echo "${green}info: 已备份当前配置至用户目录: $user_backup_path${reset}"

  local tmp_backup_path
  tmp_backup_path=$(mktemp /tmp/singbox_config_XXXXXX.json)
  cp "$CONFIG_PATH" "$tmp_backup_path"
  trap 'rm -f "$tmp_backup_path"' EXIT

  echo "${aoi}info: 正在更新配置文件...${reset}"
  local py_output
  py_output=$(python3 - "$CONFIG_PATH"     "$UPDATE_UUID" "$NEW_UUID"     "$UPDATE_REALITY" "$NEW_PRIVATE_KEY"     "$UPDATE_SHORT_ID" "$NEW_SHORT_ID"     "$UPDATE_DOMAIN" "$CUSTOM_DOMAIN"     "$UPDATE_SOCKS" "$NEW_SOCKS_USER" "$NEW_SOCKS_PASS"     "$UPDATE_SOCKS_PORT" "$CUSTOM_SOCKS_PORT"     "$UPDATE_WS" "$CUSTOM_WS_PATH" "$CUSTOM_WS_HOST"     "$UPDATE_SOCKS_OUT" "$CUSTOM_SOCKS_OUT_SERVER" "$CUSTOM_SOCKS_OUT_PORT" << 'EOF'
import sys, json

config_path = sys.argv[1]
up_uuid = sys.argv[2] == "true"
val_uuid = sys.argv[3]
up_reality = sys.argv[4] == "true"
val_priv_key = sys.argv[5]
up_short_id = sys.argv[6] == "true"
val_short_id = sys.argv[7]
up_domain = sys.argv[8] == "true"
val_domain = sys.argv[9]
up_socks = sys.argv[10] == "true"
val_socks_user = sys.argv[11]
val_socks_pass = sys.argv[12]
up_socks_port = sys.argv[13] == "true"
val_socks_port = sys.argv[14]
up_ws = sys.argv[15] == "true"
val_ws_path = sys.argv[16]
val_ws_host = sys.argv[17]
up_socks_out = sys.argv[18] == "true"
val_socks_out_srv = sys.argv[19]
val_socks_out_prt = sys.argv[20]

with open(config_path, "r", encoding="utf-8") as f:
    data = json.load(f)

cur_uuid = None
cur_priv_key = None
cur_short_id = None
cur_domain = None
cur_socks_user = None
cur_socks_pass = None

for ib in data.get("inbounds", []):
    ib_type = ib.get("type")
    if ib_type == "vless":
        if "users" in ib and ib["users"]:
            if not cur_uuid:
                cur_uuid = ib["users"][0].get("uuid")
            if up_uuid:
                for u in ib["users"]:
                    u["uuid"] = val_uuid

        tls = ib.get("tls", {})
        reality = tls.get("reality", {}) if isinstance(tls, dict) else {}
        if reality:
            if not cur_priv_key:
                cur_priv_key = reality.get("private_key")
            if not cur_short_id:
                s_ids = reality.get("short_id", [])
                cur_short_id = s_ids[0] if s_ids else None
            if not cur_domain:
                cur_domain = tls.get("server_name")

            if up_reality:
                reality["private_key"] = val_priv_key
            if up_short_id:
                reality["short_id"] = [val_short_id]
            if up_domain:
                tls["server_name"] = val_domain
                if "handshake" in reality:
                    reality["handshake"]["server"] = val_domain

        if up_ws and "transport" in ib:
            t = ib["transport"]
            if val_ws_path:
                t["path"] = val_ws_path
            if val_ws_host:
                if "headers" not in t:
                    t["headers"] = {}
                t["headers"]["Host"] = val_ws_host

    elif ib_type == "socks":
        if "users" in ib and ib["users"]:
            if not cur_socks_user:
                cur_socks_user = ib["users"][0].get("username")
            if not cur_socks_pass:
                cur_socks_pass = ib["users"][0].get("password")
            if up_socks:
                for u in ib["users"]:
                    u["username"] = val_socks_user
                    u["password"] = val_socks_pass
        if up_socks_port and val_socks_port:
            ib["listen_port"] = int(val_socks_port)

if up_socks_out:
    for ob in data.get("outbounds", []):
        if ob.get("type") == "socks" or ob.get("tag") == "socks-2028":
            if val_socks_out_srv:
                ob["server"] = val_socks_out_srv
            if val_socks_out_prt:
                ob["server_port"] = int(val_socks_out_prt)

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

res = {
    "uuid": val_uuid if up_uuid else (cur_uuid or "未变"),
    "uuid_updated": up_uuid,
    "private_key": val_priv_key if up_reality else (cur_priv_key or "未变"),
    "private_key_updated": up_reality,
    "short_id": val_short_id if up_short_id else (cur_short_id or "未变"),
    "short_id_updated": up_short_id,
    "domain": val_domain if up_domain else (cur_domain or "未变"),
    "domain_updated": up_domain,
    "socks_user": val_socks_user if up_socks else (cur_socks_user or "未变"),
    "socks_pass": val_socks_pass if up_socks else (cur_socks_pass or "未变"),
    "socks_updated": up_socks
}
print(json.dumps(res))
EOF
)

  local check_err
  if ! check_err=$(sing-box check -c "$CONFIG_PATH" 2>&1); then
    echo "${red}error: 配置文件校验失败，还原原配置！${reset}"
    echo "$check_err"
    cp "$tmp_backup_path" "$CONFIG_PATH"
    exit 1
  fi
  echo "${green}info: 配置文件校验通过${reset}"

  if systemctl is-active --quiet sing-box || systemctl is-enabled --quiet sing-box; then
    echo "${aoi}info: 正在重启 sing-box 服务...${reset}"
    if ! systemctl restart sing-box; then
      echo "${red}error: 启动 sing-box 服务失败，正在还原配置...${reset}"
      cp "$tmp_backup_path" "$CONFIG_PATH"
      systemctl restart sing-box || true
      exit 1
    fi
    echo "${green}info: sing-box 服务重启成功${reset}"
  fi

  echo ""
  echo "${green}================================================================${reset}"
  echo "${green}              sing-box 服务端配置更新完成！                     ${reset}"
  echo "${green}================================================================${reset}"
  local pub_key_display="${NEW_PUBLIC_KEY:-<未变>}"
  [[ "$UPDATE_UUID" == "true" ]] && echo "  - 新 VLESS UUID     : $NEW_UUID"
  [[ "$UPDATE_REALITY" == "true" ]] && echo "  - 新 Reality 公钥   : $pub_key_display"
  [[ "$UPDATE_REALITY" == "true" ]] && echo "  - 新 Reality 私钥   : $NEW_PRIVATE_KEY"
  [[ "$UPDATE_SHORT_ID" == "true" ]] && echo "  - 新 Short ID       : $NEW_SHORT_ID"
  [[ "$UPDATE_DOMAIN" == "true" ]] && echo "  - 新 Reality SNI    : $CUSTOM_DOMAIN"
  [[ "$UPDATE_SOCKS" == "true" ]] && echo "  - 新 SOCKS5 用户/密码: ${NEW_SOCKS_USER} / ${NEW_SOCKS_PASS}"
  echo "${green}================================================================${reset}"
}

main "$@"
