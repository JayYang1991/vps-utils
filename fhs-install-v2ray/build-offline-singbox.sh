#!/usr/bin/env bash
# shellcheck disable=SC2268
#
# Build an offline sing-box Server install bundle.
# Reference: https://sing-box.sagernet.org/
#
# Environment Variables:
#   VERSION           - sing-box version, e.g. v1.12.19 (default: latest)
#   PROXY             - Download via proxy, e.g., http://127.0.0.1:8118
#   OUTPUT_FILE       - Output tar.gz path (optional)
#   PORT              - Listening port (default: 443)
#   DOMAIN            - Server SNI (default: www.cloudflare.com)
#   UUID              - Client UUID (default: auto)
#   SHORT_ID          - Reality short ID (default: auto)
#   LOG_LEVEL         - Log level (default: info)
#
# The bundle includes:
# - sing-box release tar.gz + sha256
# - offline installer script
#
# The offline installer does not use any network access.

# ===================== Default Parameters =====================
VERSION=${VERSION:-}
PROXY=${PROXY:-}
OUTPUT_FILE=${OUTPUT_FILE:-}

PORT=${PORT:-443}
DOMAIN=${DOMAIN:-www.cloudflare.com}
UUID=${UUID:-auto}
SHORT_ID=${SHORT_ID:-auto}
LOG_LEVEL=${LOG_LEVEL:-info}

# ===================== Color Output =====================
# Initialize color variables safely before set -e
if [[ -t 1 ]] && [[ -n "$TERM" ]] && [[ "$TERM" != "dumb" ]] && command -v tput > /dev/null 2>&1; then
  red=$(tput setaf 1 2> /dev/null || echo "")
  green=$(tput setaf 2 2> /dev/null || echo "")
  aoi=$(tput setaf 6 2> /dev/null || echo "")
  reset=$(tput sgr0 2> /dev/null || echo "")
else
  red=""
  green=""
  aoi=""
  reset=""
fi

set -e

curl() {
  $(type -P curl) -L -q --retry 5 --retry-delay 10 --retry-max-time 60 "$@"
}

check_dependencies() {
  local missing=0
  for bin in curl tar sha256sum mktemp sed awk grep; do
    if ! command -v "$bin" > /dev/null 2>&1; then
      echo "${red}error: 缺少依赖: $bin${reset}"
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
}

identify_the_operating_system_and_architecture() {
  if [[ "$(uname)" != 'Linux' ]]; then
    echo "${red}error: This operating system is not supported.${reset}"
    exit 1
  fi

  case "$(uname -m)" in
    'x86_64' | 'amd64')
      MACHINE='amd64'
      ;;
    'aarch64' | 'arm64')
      MACHINE='arm64'
      ;;
    'armv7' | 'armv7l')
      MACHINE='armv7'
      ;;
    'armv6l')
      MACHINE='armv6'
      ;;
    'armv5tel')
      MACHINE='armv5'
      ;;
    'mips')
      MACHINE='mips'
      ;;
    'mipsle')
      MACHINE='mipsle'
      ;;
    'mips64')
      MACHINE='mips64'
      ;;
    'mips64le')
      MACHINE='mips64le'
      ;;
    'ppc64le')
      MACHINE='ppc64le'
      ;;
    'riscv64')
      MACHINE='riscv64'
      ;;
    's390x')
      MACHINE='s390x'
      ;;
    *)
      echo "${red}error: The architecture is not supported.${reset}"
      exit 1
      ;;
  esac
}

get_latest_version() {
  if [[ -n "$VERSION" ]]; then
    RELEASE_VERSION="v${VERSION#v}"
    return 0
  fi
  local tmp_file
  tmp_file="$(mktemp)"
  if ! curl -x "${PROXY}" -sS -i -H "Accept: application/vnd.github.v3+json" -o "$tmp_file" \
    'https://api.github.com/repos/SagerNet/sing-box/releases/latest'; then
    "rm" "$tmp_file"
    echo "${red}error: Failed to get release list, please check your network.${reset}"
    exit 1
  fi
  local http_status_code
  http_status_code=$(awk 'NR==1 {print $2}' "$tmp_file")
  if [[ $http_status_code -lt 200 ]] || [[ $http_status_code -gt 299 ]]; then
    "rm" "$tmp_file"
    echo "${red}error: Failed to get release list, GitHub API response code: $http_status_code${reset}"
    exit 1
  fi
  local release_latest
  release_latest="$(sed 'y/,/\n/' "$tmp_file" | grep 'tag_name' | awk -F '"' '{print $4}')"
  "rm" "$tmp_file"
  RELEASE_VERSION="v${release_latest#v}"
}

usage() {
  echo "usage: $0 [OPTIONS]"
  echo ''
  echo 'Options:'
  echo '  --version VERSION  Specify sing-box version, e.g., --version v1.12.19 (default: latest)'
  echo '  --proxy PROXY      Download via proxy, e.g., http://127.0.0.1:8118'
  echo '  --output FILE      Output tar.gz path (optional)'
  echo '  --port PORT        Listening port (default: 443)'
  echo '  --domain DOMAIN    Server SNI (default: www.cloudflare.com)'
  echo '  --uuid UUID        Client UUID (default: auto)'
  echo '  --short-id ID      Reality short ID (default: auto)'
  echo '  --log-level LEVEL  Log level (default: info)'
  echo '  -h, --help         Show this help'
  exit 0
}

parse_args() {
  while [[ "$#" -gt '0' ]]; do
    case "$1" in
      '--version')
        VERSION="${2:?error: Please specify the correct version.}"
        shift
        ;;
      '--proxy')
        PROXY="${2:?error: Please specify the proxy server address.}"
        shift
        ;;
      '--output')
        OUTPUT_FILE="${2:?error: Please specify the output file.}"
        shift
        ;;
      '--port')
        PORT="${2:?error: Please specify the port.}"
        shift
        ;;
      '--domain')
        DOMAIN="${2:?error: Please specify the domain.}"
        shift
        ;;
      '--uuid')
        UUID="${2:?error: Please specify the uuid.}"
        shift
        ;;
      '--short-id')
        SHORT_ID="${2:?error: Please specify the short id.}"
        shift
        ;;
      '--log-level')
        LOG_LEVEL="${2:?error: Please specify the log level.}"
        shift
        ;;
      '-h' | '--help')
        usage
        ;;
      *)
        echo "${red}error: 未知参数: $1${reset}"
        exit 1
        ;;
    esac
    shift
  done
}

write_offline_installer() {
  cat > "${BUNDLE_DIR}/install-offline.sh" << 'OFFLINE_EOF'
#!/usr/bin/env bash
# shellcheck disable=SC2268
#
# Offline sing-box Server Installation Script
# Reference: https://sing-box.sagernet.org/
#
# This installer is fully offline and only uses local bundle files.

set -e

PORT=${PORT:-__BUNDLE_PORT__}
DOMAIN=${DOMAIN:-__BUNDLE_DOMAIN__}
UUID=${UUID:-__BUNDLE_UUID__}
SHORT_ID=${SHORT_ID:-__BUNDLE_SHORT_ID__}
LOG_LEVEL=${LOG_LEVEL:-__BUNDLE_LOG_LEVEL__}

if [[ -t 1 ]] && [[ -n "$TERM" ]] && [[ "$TERM" != "dumb" ]] && command -v tput > /dev/null 2>&1; then
  red=$(tput setaf 1 2> /dev/null || echo "")
  green=$(tput setaf 2 2> /dev/null || echo "")
  aoi=$(tput setaf 6 2> /dev/null || echo "")
  reset=$(tput sgr0 2> /dev/null || echo "")
else
  red=""
  green=""
  aoi=""
  reset=""
fi

check_if_running_as_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "${red}error: 请使用 root 运行${reset}"
    exit 1
  fi
}

check_dependencies() {
  local missing='0'
  for bin in tar sha256sum systemctl openssl uuidgen; do
    if ! type -P "$bin" > /dev/null 2>&1; then
      echo "${red}error: 缺少依赖: $bin${reset}"
      missing='1'
    fi
  done
  if [[ "$missing" -eq '1' ]]; then
    echo "${red}error: 请离线安装缺失依赖后重试${reset}"
    exit 1
  fi
}

install_singbox_binary() {
  local bundle_dir
  bundle_dir="$(cd "$(dirname "$0")" && pwd)"
  local tar_file="${bundle_dir}/payload/__BUNDLE_ARCHIVE__"
  local sha_file="${bundle_dir}/payload/__BUNDLE_ARCHIVE__.sha256"

  if [[ ! -f "$tar_file" ]]; then
    echo "${red}error: 未找到离线包: $tar_file${reset}"
    exit 1
  fi

  if [[ ! -f "$sha_file" ]]; then
    echo "${aoi}info: 未找到校验文件，按官方脚本逻辑跳过校验${reset}"
  else
    (
      cd "${bundle_dir}/payload" || exit 1
      if ! sha256sum -c "$(basename "$sha_file")"; then
        local checksum
        checksum="$(grep -Eo '[a-fA-F0-9]{64}' "$(basename "$sha_file")" | head -n 1)"
        if [[ -z "$checksum" ]]; then
          echo "${aoi}info: SHA256 格式异常，按官方脚本逻辑跳过校验${reset}"
        else
          local actual_checksum
          actual_checksum="$(sha256sum "$(basename "$tar_file")" | awk '{print $1}')"
          if [[ "$checksum" != "$actual_checksum" ]]; then
            echo "${red}error: 校验失败，请重新生成离线包${reset}"
            exit 1
          fi
        fi
      fi
    )
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  tar -xzf "$tar_file" -C "$tmp_dir"

  local bin_path
  bin_path="$(find "$tmp_dir" -type f -name sing-box | head -n1)"
  if [[ -z "$bin_path" ]]; then
    echo "${red}error: 未找到 sing-box 二进制文件${reset}"
    "rm" -r "$tmp_dir"
    exit 1
  fi

  install -d /usr/local/bin
  install -m 755 "$bin_path" /usr/local/bin/sing-box
  "rm" -r "$tmp_dir"
}

generate_keys() {
  if [[ "$UUID" == "auto" ]]; then
    UUID=$(uuidgen)
    if [[ -z "$UUID" ]]; then
      echo "${red}error: 生成 UUID 失败${reset}"
      exit 1
    fi
  fi

  if ! KEY_OUTPUT=$(/usr/local/bin/sing-box generate reality-keypair 2>&1); then
    echo "${red}error: 生成 Reality 密钥失败${reset}"
    exit 1
  fi

  PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk '/PrivateKey/ {print $2}')
  PUBLIC_KEY=$(echo "$KEY_OUTPUT" | awk '/PublicKey/ {print $2}')

  if [[ -z "$PRIVATE_KEY" ]] || [[ -z "$PUBLIC_KEY" ]]; then
    echo "${red}error: 解析密钥失败${reset}"
    exit 1
  fi

  if [[ "$SHORT_ID" == "auto" ]]; then
    SHORT_ID=$(openssl rand -hex 4)
    if [[ -z "$SHORT_ID" ]]; then
      echo "${red}error: 生成 Short ID 失败${reset}"
      exit 1
    fi
  fi
}

write_config() {
  mkdir -p /etc/sing-box || {
    echo "${red}error: 创建配置目录失败${reset}"
    exit 1
  }

  if ! cat > /etc/sing-box/config.json << CONFIG_JSON_EOF; then
{
  "log": {
    "level": "$LOG_LEVEL",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$DOMAIN",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
CONFIG_JSON_EOF
    echo "${red}error: 写入配置文件失败${reset}"
    exit 1
  fi

  if ! /usr/local/bin/sing-box check -c /etc/sing-box/config.json 2> /dev/null; then
    echo "${red}error: 配置文件验证失败${reset}"
    exit 1
  fi
}

install_systemd_service() {
  cat > /etc/systemd/system/sing-box.service << UNIT_EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT_EOF
  systemctl daemon-reload
}

configure_firewall() {
  if command -v ufw > /dev/null 2>&1; then
    ufw allow "${PORT}/tcp" || true
  elif command -v firewall-cmd > /dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" || true
    firewall-cmd --reload || true
  fi
}

start_service() {
  if ! systemctl enable sing-box; then
    echo "${red}error: 启用 sing-box 服务失败${reset}"
    exit 1
  fi

  if ! systemctl restart sing-box; then
    echo "${red}error: 启动 sing-box 服务失败${reset}"
    systemctl status sing-box --no-pager
    journalctl -u sing-box -n 20 --no-pager
    exit 1
  fi

  sleep 2
  if ! systemctl is-active --quiet sing-box; then
    echo "${red}error: sing-box 服务未运行${reset}"
    systemctl status sing-box --no-pager
    journalctl -u sing-box -n 20 --no-pager
    exit 1
  fi
}

get_local_ip() {
  local server_ip=""
  if command -v ip > /dev/null 2>&1; then
    server_ip=$(ip -4 route get 1.1.1.1 2> /dev/null | awk '/src/ {print $7}')
  fi
  if [[ -z "$server_ip" ]] && command -v hostname > /dev/null 2>&1; then
    server_ip=$(hostname -I 2> /dev/null | awk '{print $1}')
  fi
  echo "$server_ip"
}

urlencode() {
  local string="${1}"
  local strlen=${#string}
  local encoded=""
  local pos c o

  for ((pos = 0; pos < strlen; pos++)); do
    c=${string:$pos:1}
    case "$c" in
      [-_.~a-zA-Z0-9]) o="${c}" ;;
      *) printf -v o '%%%02x' "'$c" ;;
    esac
    encoded+="${o}"
  done
  echo "${encoded}"
}

generate_clash_verge_config() {
  local server_ip
  server_ip=$(get_local_ip)
  if [[ -z "$server_ip" ]]; then
    echo "${red}error: 无法获取服务器 IP 地址${reset}"
    return 1
  fi

  cat << EOF
proxies:
  - name: "sing-box-${server_ip}"
    type: vless
    server: ${server_ip}
    port: ${PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${DOMAIN}
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    client-fingerprint: chrome

proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - sing-box-${server_ip}
      - DIRECT

rules:
  - MATCH,PROXY
EOF
}

generate_vless_link() {
  local server_ip
  server_ip=$(get_local_ip)

  local remark
  remark=$(urlencode "sing-box-${server_ip}")

  echo "vless://${UUID}@${server_ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${remark}"
}

generate_clash_uri() {
  local clash_config
  clash_config=$(generate_clash_verge_config)
  if [[ -z "$clash_config" ]]; then
    return 1
  fi

  local encoded_config
  encoded_config=$(urlencode "$clash_config")
  echo "clash://install-config?content=${encoded_config}"
}

print_info() {
  local server_ip
  server_ip=$(get_local_ip)

  echo ""
  echo "========================================"
  echo "${green}✅ sing-box Server 安装完成${reset}"
  echo ""
  echo "📌 客户端参数："
  echo "协议: VLESS"
  echo "地址: $server_ip"
  echo "端口: $PORT"
  echo "UUID: $UUID"
  echo "Reality 公钥: $PUBLIC_KEY"
  echo "SNI: $DOMAIN"
  echo "short_id: $SHORT_ID"
  echo "传输: TCP"
  echo ""
  echo "📌 Clash Verge 导入方式："
  echo ""
  echo "方式1 - 手动添加节点："
  echo "  点击「添加节点」→ 选择「VLESS」"
  echo "  填写上述参数"
  echo ""
  echo "方式2 - VLESS 链接 (通用)："
  generate_vless_link
  echo ""
  echo "方式3 - Clash 导入链接 (Clash Verge)："
  generate_clash_uri
  echo ""
  echo "方式4 - 手动复制 Clash 配置内容："
  echo "--- 配置开始 ---"
  generate_clash_verge_config
  echo "--- 配置结束 ---"
  echo ""
  echo "========================================"
}

main() {
  echo "${aoi}info: ▶ sing-box Server 离线安装开始${reset}"
  echo "info: 端口: $PORT"
  echo "info: SNI: $DOMAIN"
  echo ""

  check_if_running_as_root
  check_dependencies

  install_singbox_binary
  generate_keys
  write_config
  install_systemd_service
  configure_firewall
  start_service
  print_info
}

main "$@"
OFFLINE_EOF

  sed -i "s|__BUNDLE_PORT__|${PORT}|g" "${BUNDLE_DIR}/install-offline.sh"
  sed -i "s|__BUNDLE_DOMAIN__|${DOMAIN}|g" "${BUNDLE_DIR}/install-offline.sh"
  sed -i "s|__BUNDLE_UUID__|${UUID}|g" "${BUNDLE_DIR}/install-offline.sh"
  sed -i "s|__BUNDLE_SHORT_ID__|${SHORT_ID}|g" "${BUNDLE_DIR}/install-offline.sh"
  sed -i "s|__BUNDLE_LOG_LEVEL__|${LOG_LEVEL}|g" "${BUNDLE_DIR}/install-offline.sh"
  sed -i "s|__BUNDLE_ARCHIVE__|${ARCHIVE_NAME}|g" "${BUNDLE_DIR}/install-offline.sh"
  chmod +x "${BUNDLE_DIR}/install-offline.sh"
}

main() {
  parse_args "$@"
  check_dependencies
  identify_the_operating_system_and_architecture
  get_latest_version

  TMP_DIRECTORY="$(mktemp -d)"
  BUNDLE_DIR="${TMP_DIRECTORY}/singbox-offline"
  PAYLOAD_DIR="${BUNDLE_DIR}/payload"
  mkdir -p "$PAYLOAD_DIR"

  ARCHIVE_NAME="sing-box-${RELEASE_VERSION#v}-linux-${MACHINE}.tar.gz"
  ARCHIVE_URL="https://github.com/SagerNet/sing-box/releases/download/${RELEASE_VERSION}/${ARCHIVE_NAME}"
  SHA_URL="${ARCHIVE_URL}.sha256"

  echo "${aoi}info: Downloading sing-box archive for ${MACHINE}: ${RELEASE_VERSION}${reset}"
  if ! curl -x "${PROXY}" -R -H 'Cache-Control: no-cache' -o "${PAYLOAD_DIR}/${ARCHIVE_NAME}" "$ARCHIVE_URL"; then
    echo "${red}error: Download failed! Please check your network or try again.${reset}"
    exit 1
  fi

  echo "${aoi}info: Downloading sing-box sha256 for ${MACHINE}: ${RELEASE_VERSION}${reset}"
  if ! curl -x "${PROXY}" -sSR -H 'Cache-Control: no-cache' -o "${PAYLOAD_DIR}/${ARCHIVE_NAME}.sha256" "$SHA_URL"; then
    echo "${aoi}info: SHA256 文件下载失败，按官方脚本逻辑跳过校验${reset}"
  else
    (
      cd "${PAYLOAD_DIR}" || exit 1
      if ! sha256sum -c "${ARCHIVE_NAME}.sha256"; then
        # Fallback for non-standard checksum formats (e.g., only hash or BSD format)
        local checksum
        checksum="$(grep -Eo '[a-fA-F0-9]{64}' "${ARCHIVE_NAME}.sha256" | head -n 1)"
        if [[ -z "$checksum" ]]; then
          echo "${aoi}info: SHA256 格式异常，按官方脚本逻辑跳过校验${reset}"
        else
          local actual_checksum
          actual_checksum="$(sha256sum "${ARCHIVE_NAME}" | awk '{print $1}')"
          if [[ "$checksum" != "$actual_checksum" ]]; then
            echo "${red}error: SHA256 check failed! Please check your network or try again.${reset}"
            exit 1
          fi
        fi
      fi
    )
  fi

  write_offline_installer

  if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="singbox-offline-${RELEASE_VERSION}-${MACHINE}.tar.gz"
  fi

  tar -czf "$OUTPUT_FILE" -C "$TMP_DIRECTORY" singbox-offline
  echo "${green}info: Offline bundle created: $OUTPUT_FILE${reset}"

  "rm" -r "$TMP_DIRECTORY"
}

main "$@"
