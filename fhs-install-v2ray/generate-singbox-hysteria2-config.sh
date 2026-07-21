#!/usr/bin/env bash
# shellcheck disable=SC2268
#
# Generate sing-box Hysteria2 (UDP/QUIC) server/client configuration files.
# Reference: https://sing-box.sagernet.org/configuration/inbound/hysteria2/
#
# Environment Variables:
#   HY2_SERVER              - Server address for client config (default: 127.0.0.1)
#   HY2_PORT                - Hysteria2 listen/server port (default: 443)
#   HY2_DOMAIN              - TLS server_name (default: hy2.jayyang.cn)
#   HY2_PASSWORD            - Hysteria2 user password (default: auto-generated)
#   HY2_UP_MBPS             - Server advertised uplink Mbps (default: 200)
#   HY2_DOWN_MBPS           - Server advertised downlink Mbps (default: 200)
#   HY2_CERT_PATH           - TLS certificate path (default: ./hy2_cert.pem)
#   HY2_KEY_PATH            - TLS private key path (default: ./hy2_key.pem)
#   HY2_CERT_DAYS           - Self-signed certificate validity in days (default: 3650)
#   HY2_MASQUERADE          - Masquerade URL/path (default: https://www.cloudflare.com)
#   HY2_LOG_LEVEL           - Log level for both configs (default: info)
#   HY2_MIXED_LISTEN        - Local mixed inbound listen for client (default: 127.0.0.1)
#   HY2_MIXED_PORT          - Local mixed inbound port for client (default: 4000)
#   HY2_SERVER_CONFIG_PATH  - Output path for server config (default: ./singbox_hysteria2_server_config.json)
#   HY2_CLIENT_CONFIG_PATH  - Output path for client config (default: ./singbox_hysteria2_client_config.json)
#
# Usage:
#   bash generate-singbox-hysteria2-config.sh
#   HY2_SERVER=1.2.3.4 HY2_DOMAIN=hy2.example.com bash generate-singbox-hysteria2-config.sh

set -e

HY2_SERVER=${HY2_SERVER:-127.0.0.1}
HY2_PORT=${HY2_PORT:-443}
HY2_DOMAIN=${HY2_DOMAIN:-hy2.jayyang.cn}
HY2_PASSWORD=${HY2_PASSWORD:-auto}
HY2_UP_MBPS=${HY2_UP_MBPS:-200}
HY2_DOWN_MBPS=${HY2_DOWN_MBPS:-200}
HY2_CERT_PATH=${HY2_CERT_PATH:-./hy2_cert.pem}
HY2_KEY_PATH=${HY2_KEY_PATH:-./hy2_key.pem}
HY2_CERT_DAYS=${HY2_CERT_DAYS:-3650}
HY2_MASQUERADE=${HY2_MASQUERADE:-https://www.cloudflare.com}
HY2_LOG_LEVEL=${HY2_LOG_LEVEL:-info}
HY2_MIXED_LISTEN=${HY2_MIXED_LISTEN:-127.0.0.1}
HY2_MIXED_PORT=${HY2_MIXED_PORT:-4000}
HY2_SERVER_CONFIG_PATH=${HY2_SERVER_CONFIG_PATH:-./singbox_hysteria2_server_config.json}
HY2_CLIENT_CONFIG_PATH=${HY2_CLIENT_CONFIG_PATH:-./singbox_hysteria2_client_config.json}

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

generate_random_hex() {
  if command -v openssl > /dev/null 2>&1; then
    openssl rand -hex 16
  elif command -v uuidgen > /dev/null 2>&1; then
    uuidgen | tr -d '-'
  else
    echo "change-this-password-now"
  fi
}

validate_input() {
  if ! [[ "$HY2_PORT" =~ ^[0-9]+$ ]] || ((HY2_PORT < 1)) || ((HY2_PORT > 65535)); then
    echo "${red}error: HY2_PORT must be an integer in [1, 65535], got: ${HY2_PORT}${reset}"
    exit 1
  fi

  if ! [[ "$HY2_MIXED_PORT" =~ ^[0-9]+$ ]] || ((HY2_MIXED_PORT < 1)) || ((HY2_MIXED_PORT > 65535)); then
    echo "${red}error: HY2_MIXED_PORT must be an integer in [1, 65535], got: ${HY2_MIXED_PORT}${reset}"
    exit 1
  fi

  if ! [[ "$HY2_UP_MBPS" =~ ^[0-9]+$ ]] || ((HY2_UP_MBPS < 1)); then
    echo "${red}error: HY2_UP_MBPS must be a positive integer, got: ${HY2_UP_MBPS}${reset}"
    exit 1
  fi

  if ! [[ "$HY2_DOWN_MBPS" =~ ^[0-9]+$ ]] || ((HY2_DOWN_MBPS < 1)); then
    echo "${red}error: HY2_DOWN_MBPS must be a positive integer, got: ${HY2_DOWN_MBPS}${reset}"
    exit 1
  fi

  if ! [[ "$HY2_CERT_DAYS" =~ ^[0-9]+$ ]] || ((HY2_CERT_DAYS < 1)); then
    echo "${red}error: HY2_CERT_DAYS must be a positive integer, got: ${HY2_CERT_DAYS}${reset}"
    exit 1
  fi
}

ensure_tls_cert_and_key() {
  if ! command -v openssl > /dev/null 2>&1; then
    echo "${red}error: openssl is required to generate self-signed cert/key${reset}"
    exit 1
  fi

  local cert_dir key_dir
  cert_dir=$(dirname "$HY2_CERT_PATH")
  key_dir=$(dirname "$HY2_KEY_PATH")
  mkdir -p "$cert_dir" "$key_dir"

  echo "${aoi}info: generating self-signed certificate for ${HY2_DOMAIN}${reset}"
  if ! openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
    -days "$HY2_CERT_DAYS" \
    -subj "/CN=${HY2_DOMAIN}" \
    -addext "subjectAltName=DNS:${HY2_DOMAIN}" \
    -keyout "$HY2_KEY_PATH" \
    -out "$HY2_CERT_PATH" > /dev/null 2>&1; then
    echo "${red}error: failed to generate cert/key at ${HY2_CERT_PATH} and ${HY2_KEY_PATH}${reset}"
    exit 1
  fi

  chmod 600 "$HY2_KEY_PATH" || true
  chmod 644 "$HY2_CERT_PATH" || true
  echo "${green}info: generated self-signed cert/key${reset}"
}

write_server_config() {
  cat > "$HY2_SERVER_CONFIG_PATH" <<SERVER_CONFIG_EOF
{
  "log": {
    "level": "${HY2_LOG_LEVEL}",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [
        {
          "password": "${HY2_PASSWORD}"
        }
      ],
      "up_mbps": ${HY2_UP_MBPS},
      "down_mbps": ${HY2_DOWN_MBPS},
      "tls": {
        "enabled": true,
        "server_name": "${HY2_DOMAIN}",
        "alpn": [
          "h3"
        ],
        "certificate_path": "${HY2_CERT_PATH}",
        "key_path": "${HY2_KEY_PATH}"
      },
      "masquerade": "${HY2_MASQUERADE}"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
SERVER_CONFIG_EOF
}

write_client_config() {
  cat > "$HY2_CLIENT_CONFIG_PATH" <<CLIENT_CONFIG_EOF
{
  "log": {
    "level": "${HY2_LOG_LEVEL}",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns-direct",
        "server": "223.5.5.5",
        "detour": "direct"
      },
      {
        "type": "udp",
        "tag": "dns-remote",
        "server": "1.1.1.1",
        "detour": "hy2-out"
      }
    ],
    "final": "dns-remote"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "${HY2_MIXED_LISTEN}",
      "listen_port": ${HY2_MIXED_PORT},
      "udp_timeout": "5m"
    }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-out",
      "server": "${HY2_SERVER}",
      "server_port": ${HY2_PORT},
      "password": "${HY2_PASSWORD}",
      "tls": {
        "enabled": true,
        "server_name": "${HY2_DOMAIN}",
        "alpn": [
          "h3"
        ]
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "hy2-out",
    "auto_detect_interface": true
  }
}
CLIENT_CONFIG_EOF
}

check_config_if_possible() {
  if ! command -v sing-box > /dev/null 2>&1; then
    echo "${aoi}info: sing-box command not found, skip syntax checks${reset}"
    return
  fi

  if sing-box check -c "$HY2_CLIENT_CONFIG_PATH" > /dev/null 2>&1; then
    echo "${green}info: client config check passed${reset}"
  else
    echo "${red}error: client config check failed: ${HY2_CLIENT_CONFIG_PATH}${reset}"
    exit 1
  fi

  if sing-box check -c "$HY2_SERVER_CONFIG_PATH" > /dev/null 2>&1; then
    echo "${green}info: server config check passed${reset}"
  else
    echo "${red}error: server config check failed: ${HY2_SERVER_CONFIG_PATH}${reset}"
    exit 1
  fi
}

main() {
  if [[ "$HY2_PASSWORD" == "auto" ]]; then
    HY2_PASSWORD=$(generate_random_hex)
  fi

  validate_input
  ensure_tls_cert_and_key

  echo "${aoi}info: writing server config -> ${HY2_SERVER_CONFIG_PATH}${reset}"
  write_server_config
  echo "${aoi}info: writing client config -> ${HY2_CLIENT_CONFIG_PATH}${reset}"
  write_client_config

  check_config_if_possible

  echo "${green}info: done${reset}"
  echo "info: HY2_SERVER=${HY2_SERVER}"
  echo "info: HY2_PORT=${HY2_PORT}"
  echo "info: HY2_DOMAIN=${HY2_DOMAIN}"
  echo "info: HY2_PASSWORD=${HY2_PASSWORD}"
}

main "$@"
