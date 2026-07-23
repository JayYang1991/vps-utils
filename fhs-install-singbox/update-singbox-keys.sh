#!/usr/bin/env bash
# shellcheck disable=SC2268
#
# sing-box Server Key Update Script
# Reference: https://sing-box.sagernet.org/
#
# Description:
#   用于更新/重置 sing-box 服务端各项密钥与凭证：
#   - VLESS UUID
#   - Reality Keypair (PrivateKey & PublicKey)
#   - Reality Short ID
#   - Hysteria2 Password
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
UPDATE_HY2=false
CUSTOM_UUID=""
CUSTOM_SHORT_ID=""
CUSTOM_HY2_PASS=""
ASSUME_YES=false
EXPLICIT_OPTION=false

NEW_UUID=""
NEW_PRIVATE_KEY=""
NEW_PUBLIC_KEY=""
NEW_SHORT_ID=""
NEW_HY2_PASS=""

show_help() {
  echo "用法: $0 [选项]"
  echo ""
  echo "选项:"
  echo "  -a, --all                      更新所有密钥 (默认操作)"
  echo "  --uuid [UUID]                  更新 VLESS UUID (可选自定义 UUID，默认自动生成)"
  echo "  --reality-key, --private-key    重置 Reality 密钥对 (PrivateKey 与 PublicKey)"
  echo "  --short-id [SHORT_ID]          更新 Reality Short ID (可选自定义 8 位十六进制，默认自动生成)"
  echo "  --hy2-password [PASSWORD]      更新 Hysteria2 密码 (可选自定义密码，默认自动生成)"
  echo "  -c, --config PATH              指定配置文件路径 (默认: /etc/sing-box/config.json)"
  echo "  -y, --yes                      跳过确认提示直接执行"
  echo "  -h, --help                     显示本帮助信息"
  echo ""
  echo "示例:"
  echo "  $0                            # 交互式重置所有密钥"
  echo "  $0 -y                         # 非交互式重新生成所有密钥"
  echo "  $0 --uuid -y                  # 仅重新生成 UUID"
  echo "  $0 --reality-key -y           # 仅重置 Reality 密钥对"
  echo "  $0 --uuid auto --short-id -y  # 重新生成 UUID 和 Short ID"
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
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

generate_short_id() {
  if command -v openssl > /dev/null 2>&1; then
    openssl rand -hex 4
  else
    python3 -c 'import secrets; print(secrets.token_hex(4))'
  fi
}

generate_hy2_pass() {
  if command -v openssl > /dev/null 2>&1; then
    openssl rand -hex 16
  else
    python3 -c 'import secrets; print(secrets.token_hex(16))'
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
        UPDATE_HY2=true
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
      --hy2-password|--hy2-pass)
        UPDATE_HY2=true
        EXPLICIT_OPTION=true
        if [[ -n "$2" && "$2" != -* ]]; then
          CUSTOM_HY2_PASS="$2"
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
    UPDATE_HY2=true
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

  # 准备需要更新的新密钥
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

  if [[ "$UPDATE_HY2" == "true" ]]; then
    if [[ -z "$CUSTOM_HY2_PASS" || "$CUSTOM_HY2_PASS" == "auto" ]]; then
      NEW_HY2_PASS=$(generate_hy2_pass)
    else
      NEW_HY2_PASS="$CUSTOM_HY2_PASS"
    fi
  fi

  echo "${aoi}▶ 准备更新服务端 sing-box 密钥${reset}"
  echo "配置文件: $CONFIG_PATH"
  [[ "$UPDATE_UUID" == "true" ]] && echo "  - VLESS UUID: $NEW_UUID"
  [[ "$UPDATE_REALITY" == "true" ]] && echo "  - Reality PrivateKey: $NEW_PRIVATE_KEY"
  [[ "$UPDATE_REALITY" == "true" ]] && echo "  - Reality PublicKey : $NEW_PUBLIC_KEY"
  [[ "$UPDATE_SHORT_ID" == "true" ]] && echo "  - Reality Short ID  : $NEW_SHORT_ID"
  [[ "$UPDATE_HY2" == "true" ]] && echo "  - Hysteria2 Password: $NEW_HY2_PASS"
  echo ""

  if [[ "$ASSUME_YES" == "false" ]] && [[ -t 0 ]]; then
    read -r -p "是否确认更新上述密钥并重启 sing-box 服务？[y/N] " confirm
    case "$confirm" in
      [yY][eE][sS]|[yY])
        ;;
      *)
        echo "${yellow}操作已取消${reset}"
        exit 0
        ;;
    esac
  fi

  # 备份原配置文件
  local timestamp
  timestamp=$(date +%Y%m%d%H%M%S)
  local backup_path="${CONFIG_PATH}.bak.${timestamp}"
  echo "${aoi}info: 正在创建系统配置文件备份: $backup_path${reset}"
  cp "$CONFIG_PATH" "$backup_path"

  # 备份当前配置至用户家目录
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

  # 使用 Python 3 修改 JSON 配置
  echo "${aoi}info: 正在更新配置文件...${reset}"
  local py_output
  py_output=$(python3 - "$CONFIG_PATH" \
    "$UPDATE_UUID" "$NEW_UUID" \
    "$UPDATE_REALITY" "$NEW_PRIVATE_KEY" \
    "$UPDATE_SHORT_ID" "$NEW_SHORT_ID" \
    "$UPDATE_HY2" "$NEW_HY2_PASS" << 'EOF'
import sys, json

config_path = sys.argv[1]
up_uuid = sys.argv[2] == 'true'
val_uuid = sys.argv[3]
up_reality = sys.argv[4] == 'true'
val_priv_key = sys.argv[5]
up_short_id = sys.argv[6] == 'true'
val_short_id = sys.argv[7]
up_hy2 = sys.argv[8] == 'true'
val_hy2_pass = sys.argv[9]

with open(config_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

cur_uuid = None
cur_priv_key = None
cur_short_id = None
cur_hy2_pass = None

for ib in data.get('inbounds', []):
    ib_type = ib.get('type')
    if ib_type == 'vless':
        if 'users' in ib and ib['users']:
            if not cur_uuid:
                cur_uuid = ib['users'][0].get('uuid')
            if up_uuid:
                for u in ib['users']:
                    u['uuid'] = val_uuid

        tls = ib.get('tls', {})
        reality = tls.get('reality', {})
        if reality:
            if not cur_priv_key:
                cur_priv_key = reality.get('private_key')
            if not cur_short_id:
                s_ids = reality.get('short_id', [])
                cur_short_id = s_ids[0] if s_ids else None

            if up_reality:
                reality['private_key'] = val_priv_key
            if up_short_id:
                reality['short_id'] = [val_short_id]

    elif ib_type == 'hysteria2':
        if 'users' in ib and ib['users']:
            if not cur_hy2_pass:
                cur_hy2_pass = ib['users'][0].get('password')
            if up_hy2:
                for u in ib['users']:
                    u['password'] = val_hy2_pass

with open(config_path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

res = {
    "uuid": val_uuid if up_uuid else (cur_uuid or "未设/未改变"),
    "uuid_updated": up_uuid,
    "private_key": val_priv_key if up_reality else (cur_priv_key or "未设/未改变"),
    "private_key_updated": up_reality,
    "short_id": val_short_id if up_short_id else (cur_short_id or "未设/未改变"),
    "short_id_updated": up_short_id,
    "hy2_password": val_hy2_pass if up_hy2 else (cur_hy2_pass or "未设/未改变"),
    "hy2_password_updated": up_hy2
}
print(json.dumps(res))
EOF
  )

  # 校验更新后的配置文件
  local check_err
  if ! check_err=$(sing-box check -c "$CONFIG_PATH" 2>&1); then
    echo "${red}error: 配置文件校验失败，还原原配置！${reset}"
    echo "$check_err"
    cp "$backup_path" "$CONFIG_PATH"
    exit 1
  fi
  echo "${green}info: 配置文件校验通过${reset}"

  # 重启服务
  if systemctl is-active --quiet sing-box || systemctl is-enabled --quiet sing-box; then
    echo "${aoi}info: 正在重启 sing-box 服务...${reset}"
    if ! systemctl restart sing-box; then
      echo "${red}error: 启动 sing-box 服务失败，正在还原配置...${reset}"
      cp "$backup_path" "$CONFIG_PATH"
      systemctl restart sing-box || true
      exit 1
    fi
    echo "${green}info: sing-box 服务重启成功${reset}"
  fi

  # 解析有效密钥
  local eff_uuid eff_priv_key eff_short_id eff_hy2_pass
  eff_uuid=$(python3 -c "import sys, json; print(json.loads(sys.argv[1])['uuid'])" "$py_output")
  eff_priv_key=$(python3 -c "import sys, json; print(json.loads(sys.argv[1])['private_key'])" "$py_output")
  eff_short_id=$(python3 -c "import sys, json; print(json.loads(sys.argv[1])['short_id'])" "$py_output")
  eff_hy2_pass=$(python3 -c "import sys, json; print(json.loads(sys.argv[1])['hy2_password'])" "$py_output")

  echo ""
  echo "${green}================================================================${reset}"
  echo "${green}           sing-box 服务端密钥更新成功！${reset}"
  echo "${green}================================================================${reset}"
  echo " 配置文件: $CONFIG_PATH"
  echo " 系统备份: $backup_path"
  echo " 用户备份: $user_backup_path"
  echo ""
  echo " 🔑 当前生效密钥与凭证信息:"
  echo " --------------------------------------------------------------"
  if [[ "$UPDATE_UUID" == "true" ]]; then
    echo "  VLESS UUID         : ${green}${eff_uuid}${reset} (已更新)"
  else
    echo "  VLESS UUID         : ${eff_uuid} (未变动)"
  fi

  if [[ "$UPDATE_REALITY" == "true" ]]; then
    echo "  Reality PrivateKey : ${green}${eff_priv_key}${reset} (已更新)"
    echo "  Reality PublicKey  : ${green}${NEW_PUBLIC_KEY}${reset} (用于客户端配置)"
  else
    echo "  Reality PrivateKey : ${eff_priv_key} (未变动)"
  fi

  if [[ "$UPDATE_SHORT_ID" == "true" ]]; then
    echo "  Reality Short ID   : ${green}${eff_short_id}${reset} (已更新)"
  else
    echo "  Reality Short ID   : ${eff_short_id} (未变动)"
  fi

  if [[ "$UPDATE_HY2" == "true" ]]; then
    echo "  Hysteria2 Password : ${green}${eff_hy2_pass}${reset} (已更新)"
  else
    echo "  Hysteria2 Password : ${eff_hy2_pass} (未变动)"
  fi
  echo "${green}================================================================${reset}"
}

main "$@"
