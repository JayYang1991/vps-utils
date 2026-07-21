#!/usr/bin/env bash
# shellcheck disable=SC2317
# Reference:
# - sing-box Clash API endpoint: GET /proxies, PUT /proxies/{group}

set -euo pipefail

# sing-box external controller address (example: http://127.0.0.1:9090)
API_BASE='http://127.0.0.1:9090'
# Proxy group name (optional, auto-discover when empty)
GROUP_NAME=''
# Target node name for manual set
TARGET_NODE=''
# Action: next | set | list-groups | list-nodes | show
ACTION='next'

red=$(tput setaf 1)
green=$(tput setaf 2)
aoi=$(tput setaf 6)
reset=$(tput sgr0)

usage() {
  cat << USAGE
Usage:
  # Switch to next node in group (default action)
  bash switch-singbox-proxy.sh [--api <controller_url>] [--group <group_name>] [--next]

  # Switch to a specific node in group
  bash switch-singbox-proxy.sh [--api <controller_url>] --group <group_name> --set <node_name>

  # Switch to the best node (lowest delay) in group
  bash switch-singbox-proxy.sh [--api <controller_url>] [--group <group_name>] --best

  # Query groups/nodes
  bash switch-singbox-proxy.sh [--api <controller_url>] --list-groups
  bash switch-singbox-proxy.sh [--api <controller_url>] --group <group_name> --list-nodes
  bash switch-singbox-proxy.sh [--api <controller_url>] [--group <group_name>] --show

Default:
  --api http://127.0.0.1:9090
USAGE
}

log_info() {
  echo "${aoi}info:${reset} $*"
}

log_ok() {
  echo "${green}info:${reset} $*"
}

log_error() {
  echo "${red}error:${reset} $*"
}

# URL encode a string using python3
urlencode() {
  python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

# curl wrapper with retry defaults.
curl_with_retry() {
  "$(type -P curl)" -L -q --retry 5 --retry-delay 2 --retry-max-time 30 \
    --user-agent 'singbox-switcher/1.0' --connect-timeout 5 "$@"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --api)
        API_BASE="$2"
        shift 2
        ;;
      --group)
        GROUP_NAME="$2"
        shift 2
        ;;
      --set)
        TARGET_NODE="$2"
        ACTION='set'
        shift 2
        ;;
      --next)
        ACTION='next'
        shift 1
        ;;
      --best)
        ACTION='best'
        shift 1
        ;;
      --list-groups)
        ACTION='list-groups'
        shift 1
        ;;
      --list-nodes)
        ACTION='list-nodes'
        shift 1
        ;;
      --show)
        ACTION='show'
        shift 1
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        log_error "unknown arg: $1"
        usage
        exit 1
        ;;
    esac
  done
}

validate_args() {
  case "$ACTION" in
    set)
      if [[ -z "$GROUP_NAME" || -z "$TARGET_NODE" ]]; then
        log_error '--set requires --group and node name'
        exit 1
      fi
      ;;
    list-nodes)
      if [[ -z "$GROUP_NAME" ]]; then
        log_error '--list-nodes requires --group'
        exit 1
      fi
      ;;
    next | best | show | list-groups) ;;
    *)
      log_error "unsupported action: $ACTION"
      exit 1
      ;;
  esac
}

fetch_proxies_json() {
  local api_url
  api_url="${API_BASE%/}/proxies"
  curl_with_retry -sS -f "$api_url"
}

resolve_group_name() {
  local proxy_json output parse_status
  proxy_json="$1"

  output="$(
    PROXY_JSON="$proxy_json" python3 - "$GROUP_NAME" << 'PY'
import json
import os
import sys

requested = sys.argv[1].strip()
proxies = json.loads(os.environ['PROXY_JSON']).get('proxies', {})

def is_group(node):
    return isinstance(node, dict) and isinstance(node.get('all'), list) and len(node.get('all')) > 0

if requested:
    node = proxies.get(requested)
    if is_group(node):
      print(requested)
      sys.exit(0)
    print('ERROR=requested group not found or has empty all list')
    sys.exit(2)

if is_group(proxies.get('PROXY')):
    print('PROXY')
    sys.exit(0)

for name, node in proxies.items():
    if is_group(node):
        print(name)
        sys.exit(0)

print('ERROR=no proxy group found')
sys.exit(3)
PY
  )"
  parse_status=$?

  if [[ "$parse_status" -ne 0 ]]; then
    log_error "$output"
    return 1
  fi

  GROUP_NAME="$output"
  return 0
}

get_group_detail() {
  local proxy_json output parse_status
  proxy_json="$1"

  output="$(
    PROXY_JSON="$proxy_json" python3 - "$GROUP_NAME" << 'PY'
import json
import os
import sys

group = sys.argv[1]
proxies = json.loads(os.environ['PROXY_JSON']).get('proxies', {})
node = proxies.get(group)

if not isinstance(node, dict):
    print('ERROR=group not found')
    sys.exit(2)

all_nodes = node.get('all')
if not isinstance(all_nodes, list) or len(all_nodes) == 0:
    print('ERROR=group has empty node list')
    sys.exit(3)

clean_nodes = [x for x in all_nodes if isinstance(x, str) and x]
if len(clean_nodes) == 0:
    print('ERROR=group has no valid node name')
    sys.exit(4)

current = node.get('now', '')
if not isinstance(current, str):
    current = ''

try:
    idx = clean_nodes.index(current)
except ValueError:
    idx = -1

if idx >= 0:
    next_node = clean_nodes[(idx + 1) % len(clean_nodes)]
else:
    next_node = clean_nodes[0]

print(f'GROUP={group}')
print(f'CURRENT={current}')
print(f'NEXT={next_node}')
print(f'NODES={"|".join(clean_nodes)}')
PY
  )"
  parse_status=$?

  if [[ "$parse_status" -ne 0 ]]; then
    log_error "$output"
    return 1
  fi

  GROUP_CURRENT=''
  GROUP_NEXT=''
  GROUP_NODES=''
  while IFS='=' read -r key value; do
    case "$key" in
      CURRENT)
        GROUP_CURRENT="$value"
        ;;
      NEXT)
        GROUP_NEXT="$value"
        ;;
      NODES)
        GROUP_NODES="$value"
        ;;
      *) ;;
    esac
  done <<< "$output"

  return 0
}

list_groups() {
  local proxy_json output parse_status
  proxy_json="$1"

  output="$(
    PROXY_JSON="$proxy_json" python3 - << 'PY'
import json
import os
import sys

proxies = json.loads(os.environ['PROXY_JSON']).get('proxies', {})
rows = []
for name, node in proxies.items():
    if not isinstance(node, dict):
        continue
    members = node.get('all')
    if not isinstance(members, list) or len(members) == 0:
        continue
    type_name = node.get('type', 'unknown')
    now = node.get('now', '')
    if not isinstance(now, str):
        now = ''
    rows.append((name, type_name, now, len([x for x in members if isinstance(x, str) and x])))

if not rows:
    print('ERROR=no groups found')
    sys.exit(2)

rows.sort(key=lambda x: x[0].lower())
for i, (name, type_name, now, count) in enumerate(rows, start=1):
    current = now if now else '-'
    print(f'[{i}] group={name} type={type_name} current={current} nodes={count}')
PY
  )"
  parse_status=$?

  if [[ "$parse_status" -ne 0 ]]; then
    log_error "$output"
    return 1
  fi

  echo "$output"
  return 0
}

list_nodes_in_group() {
  local node
  if [[ -z "$GROUP_NODES" ]]; then
    log_error 'group node list is empty'
    return 1
  fi

  IFS='|' read -r -a NODE_ARRAY <<< "$GROUP_NODES"
  log_info "group '${GROUP_NAME}' nodes:"
  for node in "${NODE_ARRAY[@]}"; do
    if [[ "$node" == "$GROUP_CURRENT" ]]; then
      echo "  - $node (current)"
    else
      echo "  - $node"
    fi
  done

  return 0
}

switch_group_to_node() {
  local api_url request_body encoded_group
  encoded_group=$(urlencode "$GROUP_NAME")
  api_url="${API_BASE%/}/proxies/${encoded_group}"
  request_body="{\"name\":\"${TARGET_NODE}\"}"

  if curl_with_retry -sS -f -X PUT "$api_url" \
    -H 'Content-Type: application/json' \
    -d "$request_body" > /dev/null; then
    log_ok "group '${GROUP_NAME}' switched to '${TARGET_NODE}'"
    return 0
  fi

  log_error "failed to switch group '${GROUP_NAME}' to '${TARGET_NODE}'"
  return 1
}

find_best_node() {
  local output parse_status
  log_info "finding best node in group '${GROUP_NAME}' (testing ${#NODE_ARRAY[@]} nodes)..."

  output="$(
    API_BASE="$API_BASE" GROUP_NODES="$GROUP_NODES" python3 - << 'PY'
import json
import os
import sys
import urllib.request
import urllib.parse
import concurrent.futures

api_base = os.environ.get('API_BASE', '').rstrip('/')
nodes = os.environ.get('GROUP_NODES', '').split('|')
nodes = [n for n in nodes if n]

def get_delay(node):
    encoded_node = urllib.parse.quote(node)
    # Use a common connectivity check URL
    test_url = "http://www.gstatic.com/generate_204"
    api_url = f"{api_base}/proxies/{encoded_node}/delay?timeout=2000&url={urllib.parse.quote(test_url)}"
    try:
        req = urllib.request.Request(api_url)
        with urllib.request.urlopen(req, timeout=3) as response:
            data = json.loads(response.read().decode())
            delay = data.get('delay', 999999)
            if delay == 0: delay = 999999
            return node, delay
    except Exception:
        return node, 999999

best_node = None
min_delay = 999998

with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
    future_to_node = {executor.submit(get_delay, node): node for node in nodes}
    for future in concurrent.futures.as_completed(future_to_node):
        node, delay = future.result()
        if delay < 999999:
            print(f"DEBUG: {node} -> {delay}ms", file=sys.stderr)
        if delay < min_delay:
            min_delay = delay
            best_node = node

if best_node:
    print(best_node)
    sys.exit(0)
else:
    print("ERROR=no reachable nodes found")
    sys.exit(1)
PY
  )"
  parse_status=$?

  if [[ "$parse_status" -ne 0 ]]; then
    log_error "failed to find best node: $output"
    return 1
  fi

  # Extract the last line as the node name, others might be DEBUG logs
  TARGET_NODE=$(echo "$output" | tail -n 1)
  log_info "best node found: ${TARGET_NODE}"
  return 0
}

main() {
  local proxy_json

  parse_args "$@"
  validate_args

  proxy_json="$(fetch_proxies_json)" || {
    log_error "failed to fetch proxies from ${API_BASE%/}/proxies"
    exit 1
  }

  if [[ "$ACTION" == 'list-groups' ]]; then
    list_groups "$proxy_json"
    exit 0
  fi

  resolve_group_name "$proxy_json"
  get_group_detail "$proxy_json"

  case "$ACTION" in
    list-nodes)
      list_nodes_in_group
      ;;
    show)
      log_info "group: $GROUP_NAME"
      log_info "current: ${GROUP_CURRENT:--}"
      log_info "next: $GROUP_NEXT"
      list_nodes_in_group
      ;;
    set)
      switch_group_to_node
      ;;
    next)
      TARGET_NODE="$GROUP_NEXT"
      log_info "current='${GROUP_CURRENT:--}', switching to next='${TARGET_NODE}'"
      switch_group_to_node
      ;;
    best)
      IFS='|' read -r -a NODE_ARRAY <<< "$GROUP_NODES"
      find_best_node || exit 1
      switch_group_to_node
      ;;
  esac
}

main "$@"
