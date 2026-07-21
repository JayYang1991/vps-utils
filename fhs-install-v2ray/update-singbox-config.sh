#!/usr/bin/env bash

# sing-box configuration update script with auto-rollback and cleanup
# Usage: sudo bash update-singbox-config.sh

set -euo pipefail

# Configuration
CONFIG_URL="https://jayyang.us.ci/sub?token=10c7806a90d2c6b148ec0ca67d3ece46&target=singbox"
TMP_CONFIG="/tmp/config_test.json"
REAL_CONFIG="/etc/sing-box/config.json"
BACKUP_CONFIG="/tmp/singbox_config_backup.json" # Moved out of /etc/sing-box/
SERVICE_NAME="sing-box"
SINGBOX_BIN="/usr/bin/sing-box"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Cleanup function to be called on exit
cleanup() {
    log_info "Cleaning up temporary files..."
    rm -f "$TMP_CONFIG" "$BACKUP_CONFIG" "/tmp/singbox_check.log"
}

# Trap exit signal to ensure cleanup
trap cleanup EXIT

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (use sudo)"
   exit 1
fi

# 1. Download configuration
log_info "Downloading configuration from URL..."
if ! curl -L -s -o "$TMP_CONFIG" "$CONFIG_URL"; then
    log_error "Failed to download configuration."
    exit 1
fi

# 2. Check syntax
log_info "Checking configuration syntax..."
if ! "$SINGBOX_BIN" check -c "$TMP_CONFIG" > /tmp/singbox_check.log 2>&1; then
    log_error "Configuration syntax check failed:"
    cat /tmp/singbox_check.log
    exit 1
fi
log_info "Syntax check passed."

# 3. Backup existing config to /tmp
if [[ -f "$REAL_CONFIG" ]]; then
    log_info "Backing up existing configuration to $BACKUP_CONFIG..."
    cp "$REAL_CONFIG" "$BACKUP_CONFIG"
fi

# 4. Apply new config
log_info "Applying new configuration..."
mkdir -p "$(dirname "$REAL_CONFIG")"
cp "$TMP_CONFIG" "$REAL_CONFIG"

# 5. Restart service and verify
log_info "Restarting $SERVICE_NAME service..."
if systemctl restart "$SERVICE_NAME"; then
    # Wait a bit to ensure it doesn't crash immediately
    sleep 3
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_info "Service restarted successfully and is active."
        exit 0
    else
        log_warn "Service started but is not active after 3 seconds."
    fi
else
    log_error "Failed to restart $SERVICE_NAME service."
fi

# 6. Rollback if failed
log_warn "Starting rollback process..."
if [[ -f "$BACKUP_CONFIG" ]]; then
    cp "$BACKUP_CONFIG" "$REAL_CONFIG"
    log_info "Restored backup configuration from $BACKUP_CONFIG."
    if systemctl restart "$SERVICE_NAME"; then
        log_info "Service successfully rolled back and restarted."
    else
        log_error "Critical: Failed to restart service even after rollback!"
        exit 1
    fi
else
    log_error "Rollback failed: Backup configuration not found."
    exit 1
fi

exit 1
