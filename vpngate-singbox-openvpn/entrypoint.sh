#!/usr/bin/env bash
set -e

echo "============================================================"
echo " Starting vpngate-singbox-openvpn container..."
echo " System Architecture: $(uname -m)"
echo " Sing-box Version: $(sing-box version 2>/dev/null | head -n1 || echo 'unknown')"
echo " OpenVPN Version: $(openvpn --version 2>/dev/null | head -n1 || echo 'unknown')"
echo " Config Directory: ${CONFIG_DIR:-/config}"
echo "============================================================"

# Ensure /dev/net/tun exists inside container
if [ ! -c /dev/net/tun ]; then
    echo "[Init] Creating /dev/net/tun device..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 || true
    chmod 600 /dev/net/tun || true
fi

# Load config.env if present
if [ -f "/config/config.env" ]; then
    echo "[Init] Loading environment variables from /config/config.env..."
    set -a
    # shellcheck disable=SC1091
    source /config/config.env
    set +a
fi

# Hand over process control to python supervisor
exec python3 /app/scripts/health_checker.py
