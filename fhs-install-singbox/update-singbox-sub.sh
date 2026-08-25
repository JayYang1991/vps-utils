#!/usr/bin/env bash
# shellcheck disable=SC2268
#
# sing-box Subscription Update & Auto-Rollback Script
# Reference: https://sing-box.sagernet.org/
#
# Description:
#   通过指定的订阅链接更新 sing-box 配置文件，并在更新失败或服务启动异常时自动回退。
#   支持两种模式：
#     1. Client 模式（默认）：直接作为代理客户端使用（兼容 singbox-sub-converter / subconverter 格式）
#     2. Server 模式（--mode server / --server）：转换为服务端网关转发模式：
#        - 自动清除原有客户端 DNS/Experimental 与默认路由，并配置精准入站分流路由
#        - outbounds 节点仅保留 443 和 8443 端口的 VLESS+Reality 节点
#        - 8443 端口节点重写为 127.0.0.1:5000，443 端口节点重写为 127.0.0.1:5001
#        - 自动新增 SOCKS5 本地入站 (127.0.0.1:1080) 与 2 个 VLESS+Reality 入站 (默认 12345, 12346)
#        - 自动分流路由：SOCKS (1080) 与 VLESS (12345) 路由至 5000 出站；VLESS (12346) 路由至 5001 出站
#        - 支持各项端口映射与入站参数自定义
#
#   1. 备份原配置文件至 /tmp 目录
#   2. 从订阅链接下载新配置文件（Server 模式下通过 convert_sub_to_server.py 进行转换）
#   3. 校验语法无误后更新配置并重启 sing-box 服务
#   4. 若服务启动异常则自动回退至备份配置
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

# ===================== Default Settings =====================
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")
CONFIG_PATH="/etc/sing-box/config.json"
BACKUP_DIR="/tmp"
SUB_URL=""
USER_AGENT="sing-box"
TIMEOUT=30
ASSUME_YES=false

# 模式设置: client (默认) / server
MODE="client"

# Server 模式参数
INBOUND_PORT="12345"
INBOUND_PORT_2="12346"
INBOUND_LISTEN="::"
INBOUND_DOMAIN=""
INBOUND_UUID=""
INBOUND_PRIVKEY=""
INBOUND_SHORTID=""
SOCKS_PORT="1080"
SOCKS_LISTEN="127.0.0.1"
PORT_8443="5000"
PORT_443="5001"
TARGET_IP="127.0.0.1"
PORT_MAP=""

PYTHON_CONVERTER="${SCRIPT_DIR}/convert_sub_to_server.py"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/JayYang1991/vps-utils/main/fhs-install-singbox"
DOWNLOADED_CONVERTER=""

cleanup() {
  if [[ -n "$DOWNLOADED_CONVERTER" && -f "$DOWNLOADED_CONVERTER" ]]; then
    rm -f "$DOWNLOADED_CONVERTER" 2>/dev/null || true
  fi
}
trap cleanup EXIT

show_help() {
  echo "用法: $0 [选项] [订阅URL]"
  echo ""
  echo "描述:"
  echo "  指定订阅链接更新 sing-box 配置文件，自动备份原有配置至 /tmp 目录。"
  echo "  支持参考 singbox-sub-converter / subconverter 项目的订阅链接格式。"
  echo "  若下载失败、语法错误或服务启动异常，将自动回退至原配置文件。"
  echo ""
  echo "通用选项:"
  echo "  -m, --mode MODE                指定更新模式: client(客户端模式, 默认) 或 server(服务端转发网关模式)"
  echo "      --server                   快捷开启 server 服务端转发模式"
  echo "      --client                   快捷开启 client 客户端模式 (默认)"
  echo "  -u, --url URL                  指定订阅链接 URL"
  echo "  -c, --config PATH              指定 sing-box 配置文件路径 (默认: /etc/sing-box/config.json)"
  echo "  -b, --backup-dir DIR           指定备份目录 (默认: /tmp)"
  echo "  -A, --user-agent AGENT         指定 HTTP 请求 User-Agent (默认: sing-box)"
  echo "  -t, --timeout SECONDS          指定下载超时时间/秒 (默认: 30)"
  echo "  -y, --yes                      非交互模式，不提示直接执行"
  echo "  -h, --help                     显示本帮助信息"
  echo ""
  echo "Server 模式专属参数 (搭配 --mode server 或 --server 使用):"
  echo "  --inbound-port PORT            VLESS Reality 入站 1 监听端口 (默认: 12345, 路由至 5000 出站)"
  echo "  --inbound-port-2 PORT          VLESS Reality 入站 2 监听端口 (默认: 12346, 路由至 5001 出站)"
  echo "  --inbound-listen ADDR          入站监听绑定地址 (默认: ::)"
  echo "  --inbound-domain DOMAIN        入站 Reality 伪装域名/SNI (默认自动继承或从节点提取)"
  echo "  --inbound-uuid UUID            入站 VLESS 用户 UUID (默认自动继承或从节点提取)"
  echo "  --inbound-privkey KEY          入站 Reality PrivateKey (默认自动继承或自动生成)"
  echo "  --inbound-shortid ID           入站 Reality Short ID (默认自动继承或从节点提取)"
  echo "  --socks-port PORT              SOCKS5 入站监听端口 (默认: 1080, 路由至 5000 出站)"
  echo "  --socks-listen ADDR            SOCKS5 入站监听绑定地址 (默认: 127.0.0.1)"
  echo "  --port-8443 PORT               原 8443 节点映射的目标本地端口 (默认: 5000)"
  echo "  --port-443 PORT                原 443 节点映射的目标本地端口 (默认: 5001)"
  echo "  --target-ip IP                 节点重写的目标 IP 地址 (默认: 127.0.0.1)"
  echo "  --port-map RULES               自定义端口映射规则 (格式: '8443:5000,443:5001' 或 '8443:127.0.0.1:5000')"
  echo ""
  echo "使用示例:"
  echo "  1. 默认客户端订阅更新:"
  echo "     $0 http://154.12.34.56:8000/sub?token=my_secret_token"
  echo ""
  echo "  2. 服务端模式订阅更新 (开启 1080 SOCKS + 12345/12346 Reality 入站，自动路由分流至 5000/5001 端口):"
  echo "     $0 http://154.12.34.56:8000/sub?token=my_secret_token --server"
  echo ""
  echo "  3. 自定义 Server 模式入站端口与映射目标:"
  echo "     $0 -u \"http://154.12.34.56:8000/sub?token=my_secret_token\" --server --inbound-port 12345 --inbound-port-2 12346 --port-8443 5000 --port-443 5001 -y"
}

check_if_running_as_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "${red}error: 请使用 root 权限运行此脚本${reset}"
    exit 1
  fi
}

find_singbox_binary() {
  if command -v sing-box > /dev/null 2>&1; then
    echo "sing-box"
  elif [[ -x "/usr/local/bin/sing-box" ]]; then
    echo "/usr/local/bin/sing-box"
  elif [[ -x "/usr/bin/sing-box" ]]; then
    echo "/usr/bin/sing-box"
  else
    echo ""
  fi
}

normalize_sub_url() {
  local url="$1"

  # 适配 singbox-sub-converter / subconverter 路径与参数格式
  # 1. 若订阅链接包含 /v2ray、/base64 或 /clash 路径，自动转换为 /singbox 以获取 sing-box JSON 格式配置
  if [[ "$url" =~ /v2ray(\?|#|$) ]]; then
    url=$(echo "$url" | sed -E 's|/v2ray(\?|#|$)|/singbox\1|')
    echo "${aoi}info: 检测到 v2ray 节点路径，已自动转换为 sing-box 接口 (/singbox)${reset}" >&2
  elif [[ "$url" =~ /base64(\?|#|$) ]]; then
    url=$(echo "$url" | sed -E 's|/base64(\?|#|$)|/singbox\1|')
    echo "${aoi}info: 检测到 base64 节点路径，已自动转换为 sing-box 接口 (/singbox)${reset}" >&2
  elif [[ "$url" =~ /clash(\?|#|$) ]]; then
    url=$(echo "$url" | sed -E 's|/clash(\?|#|$)|/singbox\1|')
    echo "${aoi}info: 检测到 clash 节点路径，已自动转换为 sing-box 接口 (/singbox)${reset}" >&2
  fi

  # 2. 若订阅链接为自适应 /sub 接口且未提供 target= 或 flag= 参数，自动追加 target=singbox
  if [[ "$url" == *"/sub"* ]] && [[ "$url" != *"target="* ]] && [[ "$url" != *"flag="* ]]; then
    if [[ "$url" == *"?"* ]]; then
      url="${url}&target=singbox"
    else
      url="${url}?target=singbox"
    fi
    echo "${aoi}info: 检测到 /sub 订阅转换接口，已自动添加 target=singbox 参数${reset}" >&2
  fi

  echo "$url"
}

rollback_config() {
  local config_path="$1"
  local backup_path="$2"

  echo ""
  echo "${yellow}================================================================${reset}"
  echo "${yellow}                    触发配置文件自动回退                       ${reset}"
  echo "${yellow}================================================================${reset}"

  if [[ -n "$backup_path" && -f "$backup_path" ]]; then
    echo "${aoi}info: 正在从备份恢复配置文件: ${backup_path} -> ${config_path}${reset}"
    if cp "$backup_path" "$config_path"; then
      echo "${green}info: 原配置文件恢复成功${reset}"
      if command -v systemctl > /dev/null 2>&1; then
        echo "${aoi}info: 正在重启 sing-box 服务以恢复原配置...${reset}"
        if systemctl restart sing-box && systemctl is-active --quiet sing-box; then
          echo "${green}info: sing-box 服务已成功恢复原配置并正常运行${reset}"
        else
          echo "${red}error: 恢复原配置后重启 sing-box 服务依然失败，请检查 journalctl -u sing-box 日志！${reset}"
        fi
      fi
    else
      echo "${red}error: 复制备份配置文件失败！备份路径: ${backup_path}${reset}"
    fi
  else
    echo "${red}error: 未找到有效备份文件，无法自动回退！${reset}"
  fi
  echo "${yellow}================================================================${reset}"
}

ensure_python_converter() {
  if ! command -v python3 > /dev/null 2>&1; then
    echo "${red}error: Server 模式转换需要 python3 环境，请先安装 python3${reset}"
    exit 1
  fi

  if [[ -f "$PYTHON_CONVERTER" ]]; then
    return 0
  fi

  # 检查常见系统目录
  if [[ -f "/usr/local/sing-box/convert_sub_to_server.py" ]]; then
    PYTHON_CONVERTER="/usr/local/sing-box/convert_sub_to_server.py"
    return 0
  elif [[ -f "/etc/sing-box/convert_sub_to_server.py" ]]; then
    PYTHON_CONVERTER="/etc/sing-box/convert_sub_to_server.py"
    return 0
  fi

  # 尝试从 GitHub Release/Raw 自动拉取
  echo "${aoi}info: 本地未找到 convert_sub_to_server.py，正在从 GitHub 自动下载...${reset}"
  DOWNLOADED_CONVERTER=$(mktemp /tmp/convert_sub_to_server_XXXXXX.py)
  if curl -fsSL "${GITHUB_RAW_BASE}/convert_sub_to_server.py" -o "$DOWNLOADED_CONVERTER"; then
    chmod +x "$DOWNLOADED_CONVERTER"
    PYTHON_CONVERTER="$DOWNLOADED_CONVERTER"
    echo "${green}info: convert_sub_to_server.py 下载成功${reset}"
  else
    rm -f "$DOWNLOADED_CONVERTER" 2>/dev/null || true
    echo "${red}error: 无法下载 convert_sub_to_server.py，请确认网络连接或手动放置该脚本。${reset}"
    exit 1
  fi
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--mode)
        MODE="$2"
        shift 2
        ;;
      --server)
        MODE="server"
        shift 1
        ;;
      --client)
        MODE="client"
        shift 1
        ;;
      -u|--url)
        SUB_URL="$2"
        shift 2
        ;;
      -c|--config)
        CONFIG_PATH="$2"
        shift 2
        ;;
      -b|--backup-dir)
        BACKUP_DIR="$2"
        shift 2
        ;;
      -A|--user-agent)
        USER_AGENT="$2"
        shift 2
        ;;
      -t|--timeout)
        TIMEOUT="$2"
        shift 2
        ;;
      --inbound-port|--inbound-port-1|--inbound-port1)
        INBOUND_PORT="$2"
        shift 2
        ;;
      --inbound-port-2|--inbound-port2)
        INBOUND_PORT_2="$2"
        shift 2
        ;;
      --inbound-listen)
        INBOUND_LISTEN="$2"
        shift 2
        ;;
      --inbound-domain|--inbound-sni)
        INBOUND_DOMAIN="$2"
        shift 2
        ;;
      --inbound-uuid)
        INBOUND_UUID="$2"
        shift 2
        ;;
      --inbound-privkey|--inbound-private-key)
        INBOUND_PRIVKEY="$2"
        shift 2
        ;;
      --inbound-shortid|--inbound-short-id)
        INBOUND_SHORTID="$2"
        shift 2
        ;;
      --socks-port)
        SOCKS_PORT="$2"
        shift 2
        ;;
      --socks-listen)
        SOCKS_LISTEN="$2"
        shift 2
        ;;
      --port-8443)
        PORT_8443="$2"
        shift 2
        ;;
      --port-443)
        PORT_443="$2"
        shift 2
        ;;
      --target-ip)
        TARGET_IP="$2"
        shift 2
        ;;
      --port-map)
        PORT_MAP="$2"
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
        if [[ -z "$SUB_URL" && "$1" != -* ]]; then
          SUB_URL="$1"
          shift
        else
          echo "${red}error: 未知参数: $1${reset}"
          show_help
          exit 1
        fi
        ;;
    esac
  done
}

main() {
  parse_arguments "$@"

  check_if_running_as_root

  # 寻找 sing-box 可执行程序
  SINGBOX_BIN=$(find_singbox_binary)
  if [[ -z "$SINGBOX_BIN" ]]; then
    echo "${red}error: 未检测到 sing-box 可执行文件，请先安装 sing-box！${reset}"
    exit 1
  fi

  # 检查 curl
  if ! command -v curl > /dev/null 2>&1; then
    echo "${red}error: 未找到 curl 工具，请先安装 curl${reset}"
    exit 1
  fi

  # 获取订阅链接
  if [[ -z "$SUB_URL" ]]; then
    if [[ "$ASSUME_YES" == "true" ]] || [[ ! -t 0 ]]; then
      echo "${red}error: 未指定订阅链接 (URL)，请使用 -u 参数指定或传入订阅链接${reset}"
      exit 1
    fi
    read -r -p "请输入 sing-box 订阅链接 URL: " SUB_URL
    if [[ -z "$SUB_URL" ]]; then
      echo "${red}error: 订阅链接不能为空${reset}"
      exit 1
    fi
  fi

  # 规范化订阅链接 (针对 singbox-sub-converter 等自适应接口进行参数修正)
  SUB_URL=$(normalize_sub_url "$SUB_URL")

  echo "${aoi}info: 准备更新 sing-box 配置文件...${reset}"
  echo " 订阅链接 : ${SUB_URL}"
  echo " 配置路径 : ${CONFIG_PATH}"
  echo " 备份目录 : ${BACKUP_DIR}"
  if [[ "$MODE" == "server" ]]; then
    echo " 更新模式 : ${green}Server 转发模式${reset} (SOCKS: ${SOCKS_LISTEN}:${SOCKS_PORT} -> ${PORT_8443}, Reality1: ${INBOUND_LISTEN}:${INBOUND_PORT} -> ${PORT_8443}, Reality2: ${INBOUND_LISTEN}:${INBOUND_PORT_2} -> ${PORT_443})"
  else
    echo " 更新模式 : ${aoi}Client 客户端模式${reset}"
  fi
  echo ""

  # 1. 备份原有配置文件
  mkdir -p "$BACKUP_DIR"
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  BACKUP_FILE="${BACKUP_DIR}/sing-box_config_backup_${TIMESTAMP}.json"

  if [[ -f "$CONFIG_PATH" ]]; then
    echo "${aoi}info: [步骤 1/4] 正在备份原配置文件至 ${BACKUP_FILE} ...${reset}"
    if ! cp "$CONFIG_PATH" "$BACKUP_FILE"; then
      echo "${red}error: 备份原配置文件失败，放弃更新！${reset}"
      exit 1
    fi
    echo "${green}info: 原配置文件备份成功: ${BACKUP_FILE}${reset}"
  else
    echo "${yellow}warning: [步骤 1/4] 目标配置文件 ${CONFIG_PATH} 不存在，跳过备份${reset}"
    BACKUP_FILE=""
  fi

  # 2. 下载新配置文件
  TEMP_CONFIG=$(mktemp /tmp/singbox_sub_XXXXXX.json)

  echo "${aoi}info: [步骤 2/4] 正在从订阅链接下载新配置文件...${reset}"
  if ! curl -fsSL -A "$USER_AGENT" --connect-timeout 15 -m "$TIMEOUT" "$SUB_URL" -o "$TEMP_CONFIG"; then
    echo "${red}error: 下载订阅配置文件失败，请检查网络连接或订阅链接是否正确${reset}"
    rm -f "$TEMP_CONFIG"
    exit 1
  fi

  if [[ ! -s "$TEMP_CONFIG" ]]; then
    echo "${red}error: 下载的新配置文件内容为空，取消更新！${reset}"
    rm -f "$TEMP_CONFIG"
    exit 1
  fi

  # 检查是否为 Base64 编码，若为 Base64 则尝试自动解码
  if ! grep -q '^{' "$TEMP_CONFIG" && ! grep -q '^\[' "$TEMP_CONFIG"; then
    if command -v base64 > /dev/null 2>&1; then
      TEMP_DECODED=$(mktemp /tmp/singbox_sub_decoded_XXXXXX.json)
      if base64 -d "$TEMP_CONFIG" > "$TEMP_DECODED" 2>/dev/null && (grep -q '^{' "$TEMP_DECODED" || grep -q '^\[' "$TEMP_DECODED"); then
        echo "${aoi}info: 检测到 Base64 编码数据，已自动完成解码${reset}"
        mv "$TEMP_DECODED" "$TEMP_CONFIG"
      else
        rm -f "$TEMP_DECODED"
      fi
    fi
  fi

  # Server 模式转换流程
  if [[ "$MODE" == "server" ]]; then
    echo "${aoi}info: 正在执行 Server 模式转换 (分流路由: SOCKS/${INBOUND_PORT}->${PORT_8443}, ${INBOUND_PORT_2}->${PORT_443})...${reset}"
    ensure_python_converter

    local py_cmd=("python3" "$PYTHON_CONVERTER" "-i" "$TEMP_CONFIG" "-o" "$TEMP_CONFIG" "-e" "$CONFIG_PATH")
    [[ -n "$INBOUND_PORT" ]] && py_cmd+=("--inbound-port" "$INBOUND_PORT")
    [[ -n "$INBOUND_PORT_2" ]] && py_cmd+=("--inbound-port-2" "$INBOUND_PORT_2")
    [[ -n "$INBOUND_LISTEN" ]] && py_cmd+=("--inbound-listen" "$INBOUND_LISTEN")
    [[ -n "$INBOUND_DOMAIN" ]] && py_cmd+=("--inbound-domain" "$INBOUND_DOMAIN")
    [[ -n "$INBOUND_UUID" ]] && py_cmd+=("--inbound-uuid" "$INBOUND_UUID")
    [[ -n "$INBOUND_PRIVKEY" ]] && py_cmd+=("--inbound-privkey" "$INBOUND_PRIVKEY")
    [[ -n "$INBOUND_SHORTID" ]] && py_cmd+=("--inbound-shortid" "$INBOUND_SHORTID")
    [[ -n "$SOCKS_PORT" ]] && py_cmd+=("--socks-port" "$SOCKS_PORT")
    [[ -n "$SOCKS_LISTEN" ]] && py_cmd+=("--socks-listen" "$SOCKS_LISTEN")
    [[ -n "$PORT_8443" ]] && py_cmd+=("--port-8443" "$PORT_8443")
    [[ -n "$PORT_443" ]] && py_cmd+=("--port-443" "$PORT_443")
    [[ -n "$TARGET_IP" ]] && py_cmd+=("--target-ip" "$TARGET_IP")
    [[ -n "$PORT_MAP" ]] && py_cmd+=("--port-map" "$PORT_MAP")

    if ! "${py_cmd[@]}"; then
      echo "${red}error: Server 模式配置转换失败！${reset}"
      rm -f "$TEMP_CONFIG"
      exit 1
    fi
  else
    # Client 模式: 自动修正 sing-box 1.8+ 兼容性问题 (如 Reality 客户端缺少 utls 配置)
    if command -v python3 > /dev/null 2>&1; then
      local fix_msg
      fix_msg=$(python3 -c '
import sys, json

config_file = sys.argv[1]
try:
    with open(config_file, "r", encoding="utf-8") as f:
        data = json.load(f)
    
    modified = False
    if isinstance(data, dict) and "outbounds" in data and isinstance(data["outbounds"], list):
        for ob in data["outbounds"]:
            if isinstance(ob, dict) and ob.get("type") == "vless":
                tls = ob.get("tls")
                if isinstance(tls, dict) and tls.get("enabled"):
                    reality = tls.get("reality")
                    if isinstance(reality, dict) and reality.get("enabled"):
                        utls = tls.get("utls")
                        if not isinstance(utls, dict) or not utls.get("enabled"):
                            tls["utls"] = {"enabled": True, "fingerprint": "chrome"}
                            modified = True
    
    if modified:
        with open(config_file, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        print("fixed")
except Exception:
    pass
' "$TEMP_CONFIG" 2>&1 || true)
      if [[ "$fix_msg" == *"fixed"* ]]; then
        echo "${aoi}info: 已自动修正 Reality 出站节点缺失的 utls (fingerprint: chrome) 配置${reset}"
      fi
    fi
  fi

  # 校验新配置文件语法
  echo "${aoi}info: [步骤 3/4] 正在校验新配置文件语法与格式...${reset}"
  local check_output
  if ! check_output=$("$SINGBOX_BIN" check -c "$TEMP_CONFIG" 2>&1); then
    echo "${red}error: 新配置文件语法或结构校验失败，放弃更新！${reset}"
    echo "${yellow}--- sing-box check 错误详情 ---${reset}"
    echo "$check_output"
    echo "${yellow}--------------------------------${reset}"
    rm -f "$TEMP_CONFIG"
    exit 1
  fi
  echo "${green}info: 新配置文件语法校验通过${reset}"

  # 3. 覆盖配置文件并重启服务
  echo "${aoi}info: [步骤 4/4] 正在更新配置文件并重启 sing-box 服务...${reset}"
  mkdir -p "$(dirname "$CONFIG_PATH")"
  cp "$TEMP_CONFIG" "$CONFIG_PATH"
  rm -f "$TEMP_CONFIG"

  if command -v systemctl > /dev/null 2>&1; then
    # 重启 sing-box 服务
    if ! systemctl restart sing-box; then
      echo "${red}error: 重启 sing-box 服务失败！${reset}"
      rollback_config "$CONFIG_PATH" "$BACKUP_FILE"
      exit 1
    fi

    # 等待 2 秒检测服务是否稳定处于 running 状态
    sleep 2
    if ! systemctl is-active --quiet sing-box; then
      echo "${red}error: sing-box 服务重启后异常退出 (状态非 active)！${reset}"
      if command -v journalctl > /dev/null 2>&1; then
        echo "${yellow}--- 最近 10 条 sing-box 日志 ---${reset}"
        journalctl -u sing-box -n 10 --no-pager || true
        echo "${yellow}--------------------------------${reset}"
      fi
      rollback_config "$CONFIG_PATH" "$BACKUP_FILE"
      exit 1
    fi

    echo ""
    echo "${green}================================================================${reset}"
    echo "${green}           sing-box 配置文件更新成功，服务运行正常！${reset}"
    echo "${green}================================================================${reset}"
    echo " 配置文件路径 : ${CONFIG_PATH}"
    if [[ "$MODE" == "server" ]]; then
      echo " 运行模式     : ${green}Server 转发网关模式 (SOCKS5: ${SOCKS_PORT} -> ${PORT_8443}, Reality: ${INBOUND_PORT} -> ${PORT_8443}, Reality: ${INBOUND_PORT_2} -> ${PORT_443})${reset}"
    else
      echo " 运行模式     : ${aoi}Client 客户端模式${reset}"
    fi
    if [[ -n "$BACKUP_FILE" ]]; then
      echo " 备份文件路径 : ${BACKUP_FILE}"
    fi
    echo " 服务状态     : ${green}active (running)${reset}"
    echo "${green}================================================================${reset}"
  else
    echo "${yellow}warning: 未检测到 systemctl 命令，无法自动重启服务。请手动重启 sing-box 服务。${reset}"
    echo " 配置文件路径 : ${CONFIG_PATH}"
    if [[ "$MODE" == "server" ]]; then
      echo " 运行模式     : ${green}Server 转发网关模式 (SOCKS5: ${SOCKS_PORT} -> ${PORT_8443}, Reality: ${INBOUND_PORT} -> ${PORT_8443}, Reality: ${INBOUND_PORT_2} -> ${PORT_443})${reset}"
    else
      echo " 运行模式     : ${aoi}Client 客户端模式${reset}"
    fi
    if [[ -n "$BACKUP_FILE" ]]; then
      echo " 备份文件路径 : ${BACKUP_FILE}"
    fi
  fi
}

main "$@"
