#!/bin/bash
# Refactored remove_vultr_instance.sh

# --- Configuration (Externalized with Defaults) ---
MY_LABEL="${VULTR_LABEL:-ubuntu_2404}"

# --- Internal Variables ---
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# --- Helper Functions ---
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -l, --label <label>   Specify the label of the instance to remove (default: ubuntu_2204)"
    echo "  -h, --help            Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  VULTR_LABEL           Default label if not provided via arguments"
}

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${RED}[WARN]${NC} $1"
}

check_dependencies() {
    local deps=("vultr-cli" "awk" "grep")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo "Error: Dependency '$dep' is missing. Please install it."
            exit 1
        fi
    done
}

# --- Main Logic ---
main() {
    # Parse Arguments
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -l|--label) MY_LABEL="$2"; shift 2 ;;
            -h|--help) show_help; exit 0 ;;
            *) warn "Unknown parameter passed: $1"; show_help; exit 1 ;;
        esac
    done

    check_dependencies

    log "Searching for instances with label: $MY_LABEL..."
    
    # Get all matching instance IDs
    local vps_ids
    vps_ids=$(vultr-cli instance list | grep "$MY_LABEL" | awk '{print $1}')

    if [[ -z "$vps_ids" ]]; then
        warn "No instance found with label: $MY_LABEL"
        exit 0
    fi

    echo "Following instances will be removed:"
    echo "$vps_ids"
    echo ""
    read -p "Are you sure you want to delete these instances? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Operation cancelled."
        exit 0
    fi

    for id in $vps_ids; do
        log "Removing instance ID: $id"
        if vultr-cli instance delete "$id"; then
            log "Successfully removed instance $id"
        else
            warn "Failed to remove instance $id"
        fi
    done
}

main "$@"
