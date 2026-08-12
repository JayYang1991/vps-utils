#!/usr/bin/env bash
set -e

# Colors for log output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 1. Ensure TUN device exists
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    log "Creating /dev/net/tun node..."
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# 2. Extract and configure Zero Trust Service Token if provided
TEAM_NAME="${WARP_TEAM:-${ZERO_TRUST_TEAM:-$WARP_ORGANIZATION}}"
ST_ID="${WARP_SERVICE_TOKEN_ID:-${SERVICE_TOKEN_ID:-$CF_ACCESS_CLIENT_ID}}"
ST_SECRET="${WARP_SERVICE_TOKEN_SECRET:-${SERVICE_TOKEN_SECRET:-$CF_ACCESS_CLIENT_SECRET}}"

# Support ID:SECRET combined format in ST_ID
if [ -n "$ST_ID" ] && [ -z "$ST_SECRET" ] && [[ "$ST_ID" == *":"* ]]; then
    ST_SECRET="${ST_ID#*:}"
    ST_ID="${ST_ID%%:*}"
fi

if [ -n "$TEAM_NAME" ] && [ -n "$ST_ID" ] && [ -n "$ST_SECRET" ]; then
    log "Configuring Zero Trust Service Token MDM profile (Team: ${TEAM_NAME})..."
    mkdir -p /var/lib/cloudflare-warp /etc/cloudflare-warp
    cat <<EOF > /var/lib/cloudflare-warp/mdm.xml
<dict>
    <key>organization</key>
    <string>${TEAM_NAME}</string>
    <key>auth_client_id</key>
    <string>${ST_ID}</string>
    <key>auth_client_secret</key>
    <string>${ST_SECRET}</string>
</dict>
EOF
    cp -f /var/lib/cloudflare-warp/mdm.xml /etc/cloudflare-warp/mdm.xml
elif [ -n "$TEAM_NAME" ]; then
    log "Configuring Zero Trust Organization MDM profile (Team: ${TEAM_NAME})..."
    mkdir -p /var/lib/cloudflare-warp /etc/cloudflare-warp
    cat <<EOF > /var/lib/cloudflare-warp/mdm.xml
<dict>
    <key>organization</key>
    <string>${TEAM_NAME}</string>
</dict>
EOF
    cp -f /var/lib/cloudflare-warp/mdm.xml /etc/cloudflare-warp/mdm.xml
fi

# 3. Start warp-svc background process
log "Starting Cloudflare WARP daemon (warp-svc)..."
/usr/bin/warp-svc --accept-tos &
WARP_PID=$!

# Wait for warp-svc socket to be ready
log "Waiting for warp-svc socket..."
MAX_RETRIES=30
RETRY=0
while [ ! -S /run/cloudflare-warp/warp_service ]; do
    sleep 1
    RETRY=$((RETRY+1))
    if [ $RETRY -ge $MAX_RETRIES ]; then
        error "Timed out waiting for warp-svc socket."
        exit 1
    fi
done
log "warp-svc is ready."

# 4. WARP Registration & Zero Trust Configuration
if ! warp-cli --accept-tos registration show 2>/dev/null | grep -q "Account type"; then
    if [ -n "$ST_ID" ] && [ -n "$ST_SECRET" ]; then
        log "Registering WARP with Zero Trust Service Token..."
        warp-cli --accept-tos mdm refresh 2>/dev/null || true
        warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos registration new "$TEAM_NAME" 2>/dev/null || true
    elif [ -n "$WARP_AUTH_TOKEN" ]; then
        log "Registering WARP with Auth Token..."
        warp-cli --accept-tos registration token "$WARP_AUTH_TOKEN" || warp-cli registration token "$WARP_AUTH_TOKEN" || true
    elif [ -n "$TEAM_NAME" ]; then
        log "Registering WARP with Zero Trust Team: ${TEAM_NAME}..."
        warp-cli --accept-tos registration organization "$TEAM_NAME" || warp-cli registration organization "$TEAM_NAME" || warp-cli organization "$TEAM_NAME" || warp-cli --accept-tos registration new "$TEAM_NAME" || true
    elif [ -n "$WARP_LICENSE_KEY" ]; then
        log "Registering WARP with License Key..."
        warp-cli --accept-tos registration license "$WARP_LICENSE_KEY" || warp-cli registration license "$WARP_LICENSE_KEY" || true
    else
        log "Registering WARP with free account..."
        warp-cli --accept-tos registration new || warp-cli registration new || true
    fi
else
    log "WARP account is already registered."
fi

# 5. Set custom tunnel endpoint if provided
if [ -n "$WARP_ENDPOINT" ]; then
    log "Setting custom WARP tunnel endpoint: ${WARP_ENDPOINT}..."
    warp-cli --accept-tos tunnel endpoint set "$WARP_ENDPOINT" 2>/dev/null || true
fi

log "Connecting to Cloudflare WARP..."
warp-cli --accept-tos connect || warp-cli connect || true

# Wait up to 30 seconds for connection status
for i in $(seq 1 30); do
    STATUS=$(warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null || echo "")
    if echo "$STATUS" | grep -q "Connected"; then
        log "Cloudflare WARP connected successfully!"
        break
    fi
    log "Waiting for WARP connection... ($i/30)"
    sleep 1
done

# 5. Generate sing-box configuration (SOCKS5 inbound, direct outbound)
SOCKS_PORT="${SOCKS_PORT:-1080}"
CONFIG_FILE="/etc/sing-box/config.json"
mkdir -p /etc/sing-box

log "Generating sing-box configuration (SOCKS5 listen: ::${SOCKS_PORT}, outbound: direct)..."

if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
    log "Enabling SOCKS5 user/password authentication for user '${SOCKS_USER}'..."
    cat <<EOF > "$CONFIG_FILE"
{
  "log": {
    "level": "${SINGBOX_LOG_LEVEL:-info}",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "::",
      "listen_port": ${SOCKS_PORT},
      "users": [
        {
          "username": "${SOCKS_USER}",
          "password": "${SOCKS_PASS}"
        }
      ],
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
else
    cat <<EOF > "$CONFIG_FILE"
{
  "log": {
    "level": "${SINGBOX_LOG_LEVEL:-info}",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "::",
      "listen_port": ${SOCKS_PORT},
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
fi

# 6. Graceful shutdown signal handler
cleanup() {
    log "Shutting down services..."
    if [ -n "$SINGBOX_PID" ]; then
        kill -TERM "$SINGBOX_PID" 2>/dev/null || true
    fi
    if [ -n "$WARP_PID" ]; then
        kill -TERM "$WARP_PID" 2>/dev/null || true
    fi
    exit 0
}

trap cleanup SIGINT SIGTERM

# 7. Start sing-box process
log "Starting sing-box SOCKS5 proxy..."
sing-box run -c "$CONFIG_FILE" &
SINGBOX_PID=$!

log "=========================================================="
log "Container initialized and services are running!"
log "WARP Status  : $(warp-cli --accept-tos status 2>/dev/null | grep -i "Status" || echo "Running")"
log "SOCKS5 Proxy : Listening on port ${SOCKS_PORT} (Direct outbound via WARP)"
log "=========================================================="

wait "$SINGBOX_PID"
