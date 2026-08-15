#!/usr/bin/env bash
#
# generate-singbox-server-config.sh
# 
# 用于国内中转 VPS 结合 Cloudflare WARP 自动生成 sing-box 服务端配置文件的专用脚本。
# 特性:
#   1. 入站: VLESS + Reality 协议 (XTLS Vision 流控，防探测防封锁)
#   2. 端口: 默认开放多组常用 TLS/Cloudflare 端口 (443, 8443, 2053, 2083, 2087, 2096, 8080)，防单端口阻断
#   3. 出站: 全局转发至 Cloudflare WARP 本地代理 (socks5://127.0.0.1:1080)，实现极速解锁与安全中转出海
#   4. 客户端导出: 自动生成并彩色打印各端口客户端连接链接 (vless://...)、Clash Meta YAML 与 sing-box JSON
#

set -e

# --- 颜色与输出函数 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# --- 默认配置 ---
DEFAULT_PORTS=("443" "8443" "2053" "2083" "2087" "2096" "8080")
DEFAULT_SNI="itunes.apple.com"
DEFAULT_SOCKS_HOST="127.0.0.1"
DEFAULT_SOCKS_PORT="1080"
OUTPUT_FILE="./singbox-server-config.json"
APPLY_TO_SYSTEM=false
SERVER_IP=""
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
SNI="$DEFAULT_SNI"
SOCKS_PORT="$DEFAULT_SOCKS_PORT"
CUSTOM_PORTS=()

# --- 打印帮助信息 ---
show_help() {
  cat <<EOF
用法: bash generate-singbox-server-config.sh [选项]

专为国内中转 VPS 打造的 sing-box 服务端配置生成器 (VLESS+Reality 入站 -> WARP SOCKS5 出站)

选项:
  -p, --port <端口>         指定单个开放端口 (例如: -p 443)
  --ports <端口列表>        指定多个开放端口，逗号分隔 (例如: --ports 443,8443,2053,2083,2087,2096,8080)
  -s, --sni <伪装域名>      指定 Reality 伪装域名 (默认: ${DEFAULT_SNI})
  -u, --uuid <UUID>         指定客户端认证 UUID (默认: 自动随机生成)
  --short-id <ShortID>      指定 Reality Short ID (默认: 自动随机生成)
  --private-key <私钥>      指定 Reality Private Key (默认: 自动生成密钥对)
  --public-key <公钥>       指定 Reality Public Key
  --socks-port <端口>       指定本地 WARP SOCKS5 代理端口 (默认: ${DEFAULT_SOCKS_PORT})
  --server-ip <IP>          指定客户端连接的目标 VPS IP (默认: 自动探测公网 IPv4)
  -o, --output <文件路径>   指定生成的服务端配置文件保存路径 (默认: ${OUTPUT_FILE})
  -a, --apply               一键将配置写入系统 /etc/sing-box/config.json 并平滑重启 sing-box
  -h, --help                显示本帮助信息

使用示例:
  1. 零配置自动生成并打印所有常用端口客户端链接:
     bash generate-singbox-server-config.sh

  2. 自定义端口和伪装域名:
     bash generate-singbox-server-config.sh --ports 443,8443,2053 --sni gateway.icloud.com

  3. 生成并直接应用到宿主机 sing-box 服务:
     sudo bash generate-singbox-server-config.sh --apply
EOF
}

# --- 依赖检测与工具生成 ---
ensure_uuid() {
  if [[ -n "$UUID" ]]; then
    return
  fi
  if command -v sing-box &>/dev/null; then
    UUID=$(sing-box generate uuid 2>/dev/null || true)
  fi
  if [[ -z "$UUID" ]] && command -v uuidgen &>/dev/null; then
    UUID=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
  fi
  if [[ -z "$UUID" ]] && [[ -f /proc/sys/kernel/random/uuid ]]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
  fi
  if [[ -z "$UUID" ]]; then
    UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || true)
  fi
  if [[ -z "$UUID" ]]; then
    UUID="0580e757-ce23-4771-88ac-d41a6220a92a"
  fi
}

ensure_short_id() {
  if [[ -n "$SHORT_ID" ]]; then
    return
  fi
  if command -v openssl &>/dev/null; then
    SHORT_ID=$(openssl rand -hex 8 2>/dev/null || true)
  fi
  if [[ -z "$SHORT_ID" ]]; then
    SHORT_ID=$(python3 -c "import secrets; print(secrets.token_hex(8))" 2>/dev/null || true)
  fi
  if [[ -z "$SHORT_ID" ]]; then
    SHORT_ID="1a2b3c4d5e6f7a8b"
  fi
}

ensure_reality_keys() {
  if [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]]; then
    return
  fi

  # 方式 1: sing-box 官方 CLI
  if command -v sing-box &>/dev/null; then
    local kp
    kp=$(sing-box generate reality-keypair 2>/dev/null || true)
    if [[ -n "$kp" ]]; then
      PRIVATE_KEY=$(echo "$kp" | grep -i "PrivateKey" | awk '{print $2}' | tr -d '\r\n')
      PUBLIC_KEY=$(echo "$kp" | grep -i "PublicKey" | awk '{print $2}' | tr -d '\r\n')
    fi
  fi

  # 方式 2: Python cryptography 库
  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    local py_res
    py_res=$(python3 -c '
try:
    import base64
    from cryptography.hazmat.primitives.asymmetric import x25519
    from cryptography.hazmat.primitives import serialization
    priv = x25519.X25519PrivateKey.generate()
    pub = priv.public_key()
    priv_bytes = priv.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
    pub_bytes = pub.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    priv_b64 = base64.urlsafe_b64encode(priv_bytes).decode("utf-8").rstrip("=")
    pub_b64 = base64.urlsafe_b64encode(pub_bytes).decode("utf-8").rstrip("=")
    print(f"{priv_b64} {pub_b64}")
except Exception:
    pass
' 2>/dev/null || true)
    if [[ -n "$py_res" ]]; then
      PRIVATE_KEY=$(echo "$py_res" | awk '{print $1}')
      PUBLIC_KEY=$(echo "$py_res" | awk '{print $2}')
    fi
  fi

  # 兜底降级
  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    error "未能自动生成 X25519 密钥对，请确保安装了 sing-box 或 python3-cryptography。"
    exit 1
  fi
}

detect_server_ip() {
  if [[ -n "$SERVER_IP" ]]; then
    return
  fi
  log "正在探测本机公网 IP 地址..."
  for api in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me/ip" "https://ip.sb"; do
    local ip
    ip=$(curl -s4 -m 3 "$api" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      SERVER_IP="$ip"
      break
    fi
  done
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="YOUR_SERVER_IP"
  fi
}

# --- 解析命令行参数 ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p | --port)
      CUSTOM_PORTS+=("$2")
      shift 2
      ;;
    --ports)
      IFS=',' read -r -a parsed_ports <<< "$2"
      for p in "${parsed_ports[@]}"; do
        CUSTOM_PORTS+=("$(echo "$p" | tr -d '[:space:]')")
      done
      shift 2
      ;;
    -s | --sni)
      SNI="$2"
      shift 2
      ;;
    -u | --uuid)
      UUID="$2"
      shift 2
      ;;
    --short-id)
      SHORT_ID="$2"
      shift 2
      ;;
    --private-key)
      PRIVATE_KEY="$2"
      shift 2
      ;;
    --public-key)
      PUBLIC_KEY="$2"
      shift 2
      ;;
    --socks-port)
      SOCKS_PORT="$2"
      shift 2
      ;;
    --server-ip)
      SERVER_IP="$2"
      shift 2
      ;;
    -o | --output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    -a | --apply)
      APPLY_TO_SYSTEM=true
      OUTPUT_FILE="/etc/sing-box/config.json"
      shift 1
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    *)
      warn "未知参数: $1"
      shift 1
      ;;
  esac
done

# --- 确定开放端口列表 ---
PORTS_TO_USE=()
if [[ ${#CUSTOM_PORTS[@]} -gt 0 ]]; then
  PORTS_TO_USE=("${CUSTOM_PORTS[@]}")
else
  PORTS_TO_USE=("${DEFAULT_PORTS[@]}")
fi

# 去重并排序
readarray -t PORTS_TO_USE < <(printf '%s\n' "${PORTS_TO_USE[@]}" | sort -n -u)

# --- 自动补全参数 ---
ensure_uuid
ensure_short_id
ensure_reality_keys
detect_server_ip

log "配置参数概览:"
echo -e "  - 客户端连接 UUID  : ${CYAN}${UUID}${NC}"
echo -e "  - Reality 伪装域名 : ${CYAN}${SNI}${NC}"
echo -e "  - Reality 公钥(pbk): ${CYAN}${PUBLIC_KEY}${NC}"
echo -e "  - Reality Short ID : ${CYAN}${SHORT_ID}${NC}"
echo -e "  - 开放服务端口列表 : ${CYAN}${PORTS_TO_USE[*]}${NC}"
echo -e "  - 本地出站 WARP    : ${CYAN}socks5://${DEFAULT_SOCKS_HOST}:${SOCKS_PORT}${NC}"
echo -e "  - 目标 VPS 公网 IP : ${CYAN}${SERVER_IP}${NC}"
echo -e "  - 输出配置文件路径 : ${CYAN}${OUTPUT_FILE}${NC}"

# --- 生成 Inbounds JSON 结构 ---
generate_inbounds_json() {
  local inbounds_json="["
  local first=true

  for port in "${PORTS_TO_USE[@]}"; do
    if [[ "$first" == "true" ]]; then
      first=false
    else
      inbounds_json+=","
    fi

    inbounds_json+=$(cat <<EOF

    {
      "type": "vless",
      "tag": "vless-reality-in-${port}",
      "listen": "::",
      "listen_port": ${port},
      "sniff": true,
      "sniff_override_destination": true,
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    }
EOF
)
  done

  inbounds_json+=$'\n  ]'
  echo "$inbounds_json"
}

# --- 组装完整的 sing-box 服务端配置文件 ---
log "正在生成 sing-box 服务端配置 (VLESS+Reality -> WARP SOCKS5)..."

INBOUNDS_PAYLOAD=$(generate_inbounds_json)

OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
if [[ ! -d "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

cat <<EOF > "$OUTPUT_FILE"
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-direct",
        "address": "223.5.5.5",
        "detour": "direct"
      }
    ],
    "strategy": "prefer_ipv4"
  },
  "inbounds": ${INBOUNDS_PAYLOAD},
  "outbounds": [
    {
      "type": "socks",
      "tag": "warp-out",
      "server": "${DEFAULT_SOCKS_HOST}",
      "server_port": ${SOCKS_PORT}
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-direct"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      }
    ],
    "final": "warp-out",
    "auto_detect_interface": true
  }
}
EOF

success "sing-box 服务端配置文件已成功生成至: ${OUTPUT_FILE}"

# --- 如果开启了 --apply，自动写入系统并平滑重启 ---
if [[ "$APPLY_TO_SYSTEM" == "true" ]]; then
  log "正在应用配置并平滑重启系统 sing-box 服务..."
  if command -v systemctl &>/dev/null; then
    if systemctl is-active --quiet sing-box 2>/dev/null || [[ -f /etc/systemd/system/sing-box.service ]]; then
      systemctl restart sing-box
      success "系统 sing-box 服务已成功应用配置并重启！"
    else
      warn "未检测到运行中的 sing-box systemd 服务，配置已写入 /etc/sing-box/config.json，请手动启动。"
    fi
  fi
fi

# --- 打印客户端各协议连接格式 ---
echo ""
echo -e "${PURPLE}========================================================================${NC}"
echo -e "${PURPLE}                🎉 客户端连接节点信息与导入链接                        ${NC}"
echo -e "${PURPLE}========================================================================${NC}"
echo ""
echo -e "${BLUE}【1. VLESS + Reality 客户端标准链接 (v2rayN / Shadowrocket / sing-box)】:${NC}"
echo ""

for port in "${PORTS_TO_USE[@]}"; do
  encoded_remarks=$(python3 -c "import urllib.parse; print(urllib.parse.quote('中转VPS-WARP-${port}'))" 2>/dev/null || echo "中转VPS-WARP-${port}")
  vless_uri="vless://${UUID}@${SERVER_IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${encoded_remarks}"
  echo -e "${YELLOW}端口 ${port}:${NC}"
  echo -e "${CYAN}${vless_uri}${NC}"
  echo ""
done

echo -e "${BLUE}【2. Clash Meta / Mihomo 客户端 Proxies 配置片段】:${NC}"
cat <<EOF
proxies:
EOF
for port in "${PORTS_TO_USE[@]}"; do
cat <<EOF
  - name: 中转VPS-WARP-${port}
    type: vless
    server: ${SERVER_IP}
    port: ${port}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
EOF
done

echo ""
echo -e "${BLUE}【3. sing-box 客户端 Outbounds 配置片段】:${NC}"
cat <<EOF
[
EOF
first_sb=true
for port in "${PORTS_TO_USE[@]}"; do
  if [[ "$first_sb" == "true" ]]; then
    first_sb=false
  else
    echo "  ,"
  fi
cat <<EOF
  {
    "type": "vless",
    "tag": "中转VPS-WARP-${port}",
    "server": "${SERVER_IP}",
    "server_port": ${port},
    "uuid": "${UUID}",
    "flow": "xtls-rprx-vision",
    "network": "tcp",
    "tls": {
      "enabled": true,
      "server_name": "${SNI}",
      "utls": {
        "enabled": true,
        "fingerprint": "chrome"
      },
      "reality": {
        "enabled": true,
        "public_key": "${PUBLIC_KEY}",
        "short_id": "${SHORT_ID}"
      }
    }
  }
EOF
done
echo "]"

echo ""
echo -e "${PURPLE}========================================================================${NC}"
echo -e "${GREEN}说明: 国内中转流量进入本 VPS 的 sing-box 后，将全部通过本地 Cloudflare WARP${NC}"
echo -e "${GREEN}      (127.0.0.1:1080) 出口转发，实现安全防护、解锁与低延迟中转出海！${NC}"
echo -e "${PURPLE}========================================================================${NC}"
echo ""
