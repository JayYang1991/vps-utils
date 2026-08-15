#!/usr/bin/env bash
set -e

# Colors for log output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

WARP_LOG_LEVEL="${WARP_LOG_LEVEL:-warn}"
SINGBOX_LOG_LEVEL="${SINGBOX_LOG_LEVEL:-warn}"

# Helper to ensure container DNS is never blocked by WARP Zero Trust kill-switch firewall
allow_dns_firewall() {
    iptables -C OUTPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -I OUTPUT 1 -p udp --dport 53 -j ACCEPT
    iptables -C OUTPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || iptables -I OUTPUT 1 -p tcp --dport 53 -j ACCEPT
    iptables -C INPUT -p udp --sport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --sport 53 -j ACCEPT
    iptables -C INPUT -p tcp --sport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --sport 53 -j ACCEPT
    if command -v nft >/dev/null 2>&1; then
        nft insert rule inet cloudflare-warp output udp dport 53 accept 2>/dev/null || true
        nft insert rule inet cloudflare-warp output tcp dport 53 accept 2>/dev/null || true
        nft insert rule inet cloudflare-warp input udp sport 53 accept 2>/dev/null || true
        nft insert rule inet cloudflare-warp input tcp sport 53 accept 2>/dev/null || true
    fi
}

# 1. Ensure TUN device node exists & configure container network & DNS
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    log "Creating /dev/net/tun device node..."
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 600 /dev/net/tun 2>/dev/null || true
fi

# Ensure container uses reliable public DNS to prevent inheriting host Clash Fake-IP (198.18.0.2)
if grep -qE "198.18.|127.0.0." /etc/resolv.conf 2>/dev/null || [ ! -s /etc/resolv.conf ]; then
    log "Configuring public DNS nameservers (223.5.5.5, 119.29.29.29, 1.1.1.1)..."
    cat <<EOF > /etc/resolv.conf
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 1.1.1.1
EOF
fi

# Configure network stack inside container
log "Configuring network stack inside container..."
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true

# Start system dbus daemon to silence power_notifier warning logs in container
mkdir -p /run/dbus /var/lib/dbus /etc
rm -f /run/dbus/pid /run/dbus/system_bus_socket 2>/dev/null || true
dbus-uuidgen --ensure 2>/dev/null || true
dbus-daemon --system --fork 2>/dev/null || true
for _ in {1..15}; do
    [ -S /run/dbus/system_bus_socket ] && break
    sleep 0.1
done

# Pre-allow DNS in iptables
allow_dns_firewall

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

# 3. Start warp-svc background daemon (with WARP_LOG_LEVEL filtering via named pipe)
log "Starting Cloudflare WARP daemon (warp-svc) [LogLevel: ${WARP_LOG_LEVEL}]..."
mkdir -p /run/cloudflare-warp
rm -f /run/cloudflare-warp/warp_service /run/cloudflare-warp/warp_service.sock 2>/dev/null || true
rm -f /tmp/warp_log.pipe
mkfifo /tmp/warp_log.pipe

if [[ "$WARP_LOG_LEVEL" == "warn" || "$WARP_LOG_LEVEL" == "warning" ]]; then
    grep --line-buffered -v -E "(DEBUG|INFO)" < /tmp/warp_log.pipe &
elif [[ "$WARP_LOG_LEVEL" == "error" ]]; then
    grep --line-buffered -E "(ERROR|FATAL|panic|Panic)" < /tmp/warp_log.pipe &
else
    cat < /tmp/warp_log.pipe &
fi

/usr/bin/warp-svc --accept-tos > /tmp/warp_log.pipe 2>&1 &

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
        if warp-cli --accept-tos registration show 2>/dev/null | grep -qE "Account: Team|Account type: Team|Organization:|Registration:"; then
            log "Zero Trust MDM enrollment registered successfully."
            REG_SUCCESS=true
            break
        fi
        if [ $((i % 4)) -eq 0 ]; then
            warp-cli --accept-tos mdm refresh 2>/dev/null || true
        fi
        sleep 2
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

log "Generating sing-box configuration (SOCKS5 listen: ::${SOCKS_PORT}, LogLevel: ${SINGBOX_LOG_LEVEL}, sniff enabled)..."

if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
    log "Enabling SOCKS5 authentication for user '${SOCKS_USER}'..."
    cat <<EOF > "$CONFIG_FILE"
{
  "log": {
    "level": "${SINGBOX_LOG_LEVEL}",
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
      "tag": "direct",
      "domain_strategy": "prefer_ipv4"
    }
  ]
}
EOF
else
    cat <<EOF > "$CONFIG_FILE"
{
  "log": {
    "level": "${SINGBOX_LOG_LEVEL}",
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
      "tag": "direct",
      "domain_strategy": "prefer_ipv4"
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

CACHE_FILE="/var/lib/cloudflare-warp/endpoints.txt"

# Helper to fetch preferred WARP endpoints from subscription URL and/or persistent cache
fetch_preferred_endpoints() {
    local sub_url="${WARP_SUB_URL:-https://sub.19910417.xyz/sub?host=1&uuid=1}"
    local endpoints=()
    local fetched=false

    # 1. Try fetching online via SOCKS5 proxy or direct
    if [ -n "$sub_url" ]; then
        log "Fetching preferred WARP endpoints from subscription: ${sub_url}..."
        local raw_data=""
        raw_data=$(curl -sSL -m 8 -x socks5h://127.0.0.1:${SOCKS_PORT:-1080} "$sub_url" 2>/dev/null || curl -sSL -m 8 "$sub_url" 2>/dev/null || true)

        if [ -n "$raw_data" ]; then
            local decoded=""
            decoded=$(echo "$raw_data" | base64 -d 2>/dev/null || echo "$raw_data")

            # Extract @IP:PORT patterns from vless:// subscription nodes
            while IFS= read -r line; do
                if [[ -n "$line" && "$line" != *"example.com"* ]]; then
                    endpoints+=("$line")
                fi
            done < <(echo "$decoded" | grep -oE '@[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' | tr -d '@')

            # Fallback to plain IP:PORT pattern if no @IP:PORT found
            if [ ${#endpoints[@]} -eq 0 ]; then
                while IFS= read -r line; do
                    if [[ -n "$line" && "$line" != *"127.0.0.1"* && "$line" != *"0.0.0.0"* ]]; then
                        endpoints+=("$line")
                    fi
                done < <(echo "$decoded" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{2,5}')
            fi

            if [ ${#endpoints[@]} -gt 0 ]; then
                fetched=true
                mkdir -p /var/lib/cloudflare-warp
                printf "%s\n" "${endpoints[@]}" > "$CACHE_FILE" 2>/dev/null || true
            fi
        fi
    fi

    # 2. If online fetch failed (e.g. cold boot before proxy), load from persistent cache
    if [ "$fetched" = "false" ] && [ -f "$CACHE_FILE" ]; then
        log "Loading preferred endpoints from local cache: ${CACHE_FILE}..."
        while IFS= read -r line; do
            [ -n "$line" ] && endpoints+=("$line")
        done < "$CACHE_FILE"
    fi

    # 3. Append static endpoints from WARP_ENDPOINT if specified
    if [ -n "$WARP_ENDPOINT" ]; then
        local IFS=','
        for sep in $WARP_ENDPOINT; do
            sep=$(echo "$sep" | xargs)
            if [ -n "$sep" ]; then
                endpoints+=("$sep")
            fi
        done
    fi

    # Output list (one per line)
    printf "%s\n" "${endpoints[@]}"
}

# 7. Set WARP mode, Connect to official default endpoint first
if [ "$HAS_MDM" != "true" ]; then
    WARP_MODE="${WARP_MODE:-warp}"
    log "Setting WARP mode to ${WARP_MODE}..."
    warp-cli --accept-tos mode "$WARP_MODE" 2>/dev/null || true
fi

warp-cli --accept-tos debug connectivity-check disable 2>/dev/null || true

# 优先重置并尝试连接官方默认接入点 (等待最多 2 分钟 / 120 秒)
log "Attempting initial connection using official default endpoint..."
warp-cli --accept-tos tunnel endpoint reset 2>/dev/null || true
warp-cli --accept-tos connect 2>/dev/null || true
allow_dns_firewall

CONNECTED=false
log "Waiting for default endpoint connection (timeout: 120s / 2 minutes)..."
for i in {1..24}; do
    sleep 5
    STATUS=$(warp-cli --accept-tos status 2>/dev/null || echo "")
    if echo "$STATUS" | grep -qE "Connected|Success"; then
        log "✅ Successfully connected using official default endpoint!"
        CONNECTED=true
        break
    fi
    allow_dns_firewall
    if [ $((i % 6)) -eq 0 ]; then
        log "Still connecting to official default endpoint ($((i * 5))/120s)..."
    fi
done

# 如果持续 2 分钟仍无法建立连接，再切换尝试优选接入点列表
if [ "$CONNECTED" != "true" ]; then
    warn "Official default endpoint failed to connect within 2 minutes. Switching to preferred endpoint list..."
    warp-cli --accept-tos disconnect 2>/dev/null || true

    mapfile -t ENDPOINT_LIST < <(fetch_preferred_endpoints)
    TOTAL_EPS=${#ENDPOINT_LIST[@]}
    CURRENT_EP_INDEX=0

    if [ "$TOTAL_EPS" -gt 0 ]; then
        log "Loaded ${TOTAL_EPS} preferred edge endpoints, attempting connection sequentially..."
        for i in "${!ENDPOINT_LIST[@]}"; do
            EP="${ENDPOINT_LIST[$i]}"
            log "[$((i+1))/${TOTAL_EPS}] Trying preferred edge endpoint: ${EP}..."
            warp-cli --accept-tos tunnel endpoint set "$EP" 2>/dev/null || true
            warp-cli --accept-tos connect 2>/dev/null || true
            allow_dns_firewall

            # Check status for up to 6 seconds per node
            for check in {1..3}; do
                sleep 2
                STATUS=$(warp-cli --accept-tos status 2>/dev/null || echo "")
                if echo "$STATUS" | grep -qE "Connected|Success"; then
                    log "✅ Successfully connected to preferred endpoint: ${EP}"
                    CONNECTED=true
                    CURRENT_EP_INDEX=$i
                    break 2
                fi
            done

            warn "Preferred endpoint ${EP} connection timed out, trying next..."
            warp-cli --accept-tos disconnect 2>/dev/null || true
        done
    fi

    if [ "$CONNECTED" != "true" ]; then
        warn "All preferred endpoints also failed, resetting back to official default endpoint..."
        warp-cli --accept-tos tunnel endpoint reset 2>/dev/null || true
        warp-cli --accept-tos connect 2>/dev/null || true
        allow_dns_firewall
    fi
else
    # 已成功连接官方节点，后台预加载优选列表供后续故障转移备用
    mapfile -t ENDPOINT_LIST < <(fetch_preferred_endpoints)
    CURRENT_EP_INDEX=0
fi

# Continuous WARP connection health checker daemon (checks every 10s)
(
    CONNECTING_COUNT=0
    while true; do
        allow_dns_firewall
        sleep 10
        STATUS=$(warp-cli --accept-tos status 2>/dev/null || echo "")

        # 1. Connected successfully: reset connecting counter
        if echo "$STATUS" | grep -qE "Connected|Success"; then
            CONNECTING_COUNT=0
            continue
        fi

        # 2. In Connecting state: track duration and force failover if stuck >= 30s (3 consecutive checks)
        if echo "$STATUS" | grep -qE "Connecting"; then
            CONNECTING_COUNT=$((CONNECTING_COUNT + 1))
            if [ "$CONNECTING_COUNT" -ge 3 ]; then
                warn "WARP stuck in Connecting state for >=30s, initiating endpoint failover..."
                if [ ${#ENDPOINT_LIST[@]} -gt 1 ]; then
                    CURRENT_EP_INDEX=$(( (CURRENT_EP_INDEX + 1) % ${#ENDPOINT_LIST[@]} ))
                    NEXT_EP="${ENDPOINT_LIST[$CURRENT_EP_INDEX]}"
                    warn "Switching to next preferred endpoint [$((CURRENT_EP_INDEX+1))/${#ENDPOINT_LIST[@]}]: ${NEXT_EP}..."
                    warp-cli --accept-tos tunnel endpoint set "$NEXT_EP" 2>/dev/null || true
                elif [ ${#ENDPOINT_LIST[@]} -eq 1 ]; then
                    warp-cli --accept-tos tunnel endpoint set "${ENDPOINT_LIST[0]}" 2>/dev/null || true
                else
                    warp-cli --accept-tos tunnel endpoint reset 2>/dev/null || true
                fi
                warp-cli --accept-tos disconnect 2>/dev/null || true
                sleep 1
                warp-cli --accept-tos connect 2>/dev/null || true
                CONNECTING_COUNT=0
            fi
            continue
        fi

        CONNECTING_COUNT=0

        # 3. If registration is missing or invalidated in API, automatically re-enroll
        if echo "$STATUS" | grep -qE "Registration Missing|Does not exist in API|Missing registration|Unable"; then
            warn "WARP registration missing/invalidated in API, re-triggering enrollment..."
            if [ "$HAS_MDM" = "true" ]; then
                warp-cli --accept-tos mdm refresh 2>/dev/null || true
            else
                warp-cli --accept-tos registration new 2>/dev/null || true
            fi
            sleep 3
        fi

        # 4. If disconnected or in unexpected state, actively failover and reconnect
        warn "WARP disconnected (${STATUS:-Unknown}), attempting failover and reconnect..."
        if [ ${#ENDPOINT_LIST[@]} -gt 1 ]; then
            CURRENT_EP_INDEX=$(( (CURRENT_EP_INDEX + 1) % ${#ENDPOINT_LIST[@]} ))
            NEXT_EP="${ENDPOINT_LIST[$CURRENT_EP_INDEX]}"
            warn "Switching to next preferred endpoint [$((CURRENT_EP_INDEX+1))/${#ENDPOINT_LIST[@]}]: ${NEXT_EP}..."
            warp-cli --accept-tos tunnel endpoint set "$NEXT_EP" 2>/dev/null || true
        fi
        warp-cli --accept-tos disconnect 2>/dev/null || true
        sleep 1
        warp-cli --accept-tos connect 2>/dev/null || true
    done
) &
CHECKER_PID=$!

# 8. Graceful shutdown signal handler
cleanup() {
    log "Received shutdown signal, terminating processes gracefully..."
    if [ -n "$CHECKER_PID" ]; then
        kill -TERM "$CHECKER_PID" 2>/dev/null || true
    fi
    pkill -TERM -x sing-box 2>/dev/null || true
    pkill -TERM -x warp-svc 2>/dev/null || true
    rm -f /tmp/warp_log.pipe 2>/dev/null || true
    wait 2>/dev/null || true
    log "All container services stopped."
    exit 0
}

trap cleanup SIGINT SIGTERM SIGHUP

log "=========================================================="
log "Container initialized and services running!"
log "SOCKS5 Proxy : Listening on port ${SOCKS_PORT} (Direct outbound via WARP)"
log "Logging      : sing-box=${SINGBOX_LOG_LEVEL}, warp-svc=${WARP_LOG_LEVEL}"
log "=========================================================="

wait "$SINGBOX_PID"
