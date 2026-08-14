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

# 1. Ensure TUN device node exists & configure container network & DNS
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    log "Creating /dev/net/tun device node..."
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 600 /dev/net/tun 2>/dev/null || true
fi

# Ensure container uses reliable public DNS to prevent inheriting host Clash Fake-IP (198.18.0.2)
if grep -qE "198.18.|127.0.0." /etc/resolv.conf 2>/dev/null || [ ! -s /etc/resolv.conf ]; then
    log "Configuring public DNS nameservers (1.1.1.1, 8.8.8.8, 223.5.5.5)..."
    cat <<EOF > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 223.5.5.5
EOF
fi

# Disable IPv6 stack inside container to prevent WARP IPv6 Happy Eyeballs timeouts
log "Configuring network stack inside container..."
sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=1 2>/dev/null || true

# Start system dbus daemon to silence power_notifier warning logs in container
mkdir -p /run/dbus
dbus-daemon --system --fork 2>/dev/null || true

# 2. Extract and configure Zero Trust Service Token if provided
TEAM_NAME="${WARP_TEAM:-${ZERO_TRUST_TEAM:-$WARP_ORGANIZATION}}"
ST_ID="${WARP_SERVICE_TOKEN_ID:-${SERVICE_TOKEN_ID:-$CF_ACCESS_CLIENT_ID}}"
ST_SECRET="${WARP_SERVICE_TOKEN_SECRET:-${SERVICE_TOKEN_SECRET:-$CF_ACCESS_CLIENT_SECRET}}"

# Support ID:SECRET combined format in ST_ID
if [ -n "$ST_ID" ] && [ -z "$ST_SECRET" ] && [[ "$ST_ID" == *":"* ]]; then
    ST_SECRET="${ST_ID#*:}"
    ST_ID="${ST_ID%%:*}"
fi

HAS_MDM=false
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
    HAS_MDM=true
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
    HAS_MDM=true
fi

# 3. Start warp-svc background daemon
log "Starting Cloudflare WARP daemon (warp-svc)..."
/usr/bin/warp-svc --accept-tos &
WARP_PID=$!

# Wait for warp-svc socket to be ready
log "Waiting for warp-svc socket connection..."
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
log "warp-svc daemon is ready."

# 4. WARP Registration & Zero Trust Configuration
log "Checking WARP registration status..."
REG_SUCCESS=false

if [ "$HAS_MDM" = "true" ]; then
    log "MDM profile detected, triggering MDM sync..."
    warp-cli --accept-tos mdm refresh 2>/dev/null || true
    for i in $(seq 1 15); do
        if warp-cli --accept-tos registration show 2>/dev/null | grep -qE "Account type: Team"; then
            log "Zero Trust MDM enrollment registered successfully."
            REG_SUCCESS=true
            break
        fi
        sleep 1
        warp-cli --accept-tos mdm refresh 2>/dev/null || true
    done
else
    for i in $(seq 1 10); do
        if warp-cli --accept-tos registration show 2>/dev/null | grep -qE "Account type: Free|Account type: Plus|Account type: Team"; then
            log "WARP account is registered successfully."
            REG_SUCCESS=true
            break
        fi
        if [ -n "$WARP_AUTH_TOKEN" ]; then
            warp-cli --accept-tos registration token "$WARP_AUTH_TOKEN" 2>/dev/null || true
        elif [ -n "$WARP_LICENSE_KEY" ]; then
            warp-cli --accept-tos registration license "$WARP_LICENSE_KEY" 2>/dev/null || true
        else
            warp-cli --accept-tos registration new 2>/dev/null || true
        fi
        sleep 2
    done
fi

if [ "$REG_SUCCESS" != "true" ]; then
    warn "Initial registration check pending, proceeding to start services..."
fi

# 5. Generate sing-box configuration (SOCKS5 inbound with domain sniffing, direct outbound)
SOCKS_PORT="${SOCKS_PORT:-1080}"
CONFIG_FILE="/etc/sing-box/config.json"
mkdir -p /etc/sing-box

log "Generating sing-box configuration (SOCKS5 listen: ::${SOCKS_PORT}, sniff & destination override enabled)..."

if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
    log "Enabling SOCKS5 authentication for user '${SOCKS_USER}'..."
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
      "sniff": true,
      "sniff_override_destination": true
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
      "sniff": true,
      "sniff_override_destination": true
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

# 6. Validate and start sing-box process
log "Validating sing-box configuration..."
if ! sing-box check -c "$CONFIG_FILE"; then
    error "sing-box configuration check failed!"
    exit 1
fi

log "Starting sing-box SOCKS5 proxy..."
sing-box run -c "$CONFIG_FILE" &
SINGBOX_PID=$!

# 7. Set WARP mode, Tunnel Endpoint & Connect
WARP_MODE="${WARP_MODE:-warp}"
log "Setting WARP mode to ${WARP_MODE}..."
warp-cli --accept-tos mode "$WARP_MODE" 2>/dev/null || true

if [ -n "$WARP_ENDPOINT" ]; then
    log "Setting custom WARP tunnel endpoint: ${WARP_ENDPOINT}..."
    warp-cli --accept-tos tunnel endpoint set "$WARP_ENDPOINT" 2>/dev/null || true
else
    log "Using WARP native default Endpoint..."
    warp-cli --accept-tos tunnel endpoint reset 2>/dev/null || true
fi

log "Connecting to Cloudflare WARP..."
warp-cli --accept-tos connect 2>/dev/null || true

# Continuous WARP connection health checker daemon
(
    while true; do
        sleep 5
        STATUS=$(warp-cli --accept-tos status 2>/dev/null || echo "")
        if echo "$STATUS" | grep -qE "Connected|Success"; then
            continue
        fi
        log "WARP not connected (${STATUS:-Disconnected}), attempting reconnect..."
        warp-cli --accept-tos connect 2>/dev/null || true
        sleep 5
    done
) &
CHECKER_PID=$!

# 8. Graceful shutdown signal handler
cleanup() {
    log "Received shutdown signal, terminating processes gracefully..."
    if [ -n "$CHECKER_PID" ]; then
        kill -TERM "$CHECKER_PID" 2>/dev/null || true
    fi
    if [ -n "$SINGBOX_PID" ] && kill -0 "$SINGBOX_PID" 2>/dev/null; then
        kill -TERM "$SINGBOX_PID" 2>/dev/null || true
    fi
    if [ -n "$WARP_PID" ] && kill -0 "$WARP_PID" 2>/dev/null; then
        kill -TERM "$WARP_PID" 2>/dev/null || true
    fi
    wait 2>/dev/null || true
    log "All container services stopped."
    exit 0
}

trap cleanup SIGINT SIGTERM SIGHUP

log "=========================================================="
log "Container initialized and services running!"
log "SOCKS5 Proxy : Listening on port ${SOCKS_PORT} (Direct outbound via WARP)"
log "SNI Sniffing : Enabled (Resolves Host Fake-IP to Real Domain automatically)"
log "=========================================================="

wait "$SINGBOX_PID"
