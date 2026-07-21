#!/usr/bin/env bash
# shellcheck disable=SC2268

# The files installed by the script conform to the Filesystem Hierarchy Standard:
# https://wiki.linuxfoundation.org/lsb/fhs

# The URL of the upstream install script is:
# https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh

# The URL of the script project is:
# https://github.com/v2fly/fhs-install-v2ray

# Build an offline V2Ray install bundle that includes:
# - V2Ray release zip and digest
# - A selected config template
# - A local-only install script (no network access)

set -e

# Installation mode: standard, proxy-server, proxy-client, reverse-server, bridge-server
INSTALL_MODE=${INSTALL_MODE:-standard}
ALL_MODES=${ALL_MODES:-no}
MODES_LIST=${MODES_LIST:-}

# Optional version override, e.g. v5.10.0
VERSION=${VERSION:-}

# Proxy for downloads, e.g. http://127.0.0.1:8118
PROXY=${PROXY:-}

curl() {
  $(type -P curl) -L -q --retry 5 --retry-delay 10 --retry-max-time 60 "$@"
}

identify_the_operating_system_and_architecture() {
  if [[ "$(uname)" != 'Linux' ]]; then
    echo 'error: This operating system is not supported.'
    exit 1
  fi
  case "$(uname -m)" in
    'i386' | 'i686')
      MACHINE='32'
      ;;
    'amd64' | 'x86_64')
      MACHINE='64'
      ;;
    'armv5tel')
      MACHINE='arm32-v5'
      ;;
    'armv6l')
      MACHINE='arm32-v6'
      grep Features /proc/cpuinfo | grep -qw 'vfp' || MACHINE='arm32-v5'
      ;;
    'armv7' | 'armv7l')
      MACHINE='arm32-v7a'
      grep Features /proc/cpuinfo | grep -qw 'vfp' || MACHINE='arm32-v5'
      ;;
    'armv8' | 'aarch64')
      MACHINE='arm64-v8a'
      ;;
    'mips')
      MACHINE='mips32'
      ;;
    'mipsle')
      MACHINE='mips32le'
      ;;
    'mips64')
      MACHINE='mips64'
      ;;
    'mips64le')
      MACHINE='mips64le'
      ;;
    'ppc64')
      MACHINE='ppc64'
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
      echo 'error: The architecture is not supported.'
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
    'https://api.github.com/repos/v2fly/v2ray-core/releases/latest'; then
    "rm" "$tmp_file"
    echo 'error: Failed to get release list, please check your network.'
    exit 1
  fi
  local http_status_code
  http_status_code=$(awk 'NR==1 {print $2}' "$tmp_file")
  if [[ $http_status_code -lt 200 ]] || [[ $http_status_code -gt 299 ]]; then
    "rm" "$tmp_file"
    echo "error: Failed to get release list, GitHub API response code: $http_status_code"
    exit 1
  fi
  local release_latest
  release_latest="$(sed 'y/,/\n/' "$tmp_file" | grep 'tag_name' | awk -F '"' '{print $4}')"
  "rm" "$tmp_file"
  RELEASE_VERSION="v${release_latest#v}"
}

get_config_link() {
  case "$INSTALL_MODE" in
    'bridge-server')
      DOWNLOAD_CONF_LINK='https://raw.githubusercontent.com/JayYang1991/fhs-install-v2ray/master/server_config.json'
      ;;
    'proxy-server')
      DOWNLOAD_CONF_LINK='https://raw.githubusercontent.com/JayYang1991/fhs-install-v2ray/master/proxy_server_config.json'
      ;;
    'proxy-client')
      DOWNLOAD_CONF_LINK='https://raw.githubusercontent.com/JayYang1991/fhs-install-v2ray/master/proxy_client_config.json'
      ;;
    'reverse-server')
      DOWNLOAD_CONF_LINK='https://raw.githubusercontent.com/JayYang1991/fhs-install-v2ray/master/reverse_server_config.json'
      ;;
    *)
      DOWNLOAD_CONF_LINK='https://raw.githubusercontent.com/JayYang1991/fhs-install-v2ray/master/server_config.json'
      ;;
  esac
}

usage() {
  echo "usage: $0 [OPTIONS]"
  echo ''
  echo 'Options:'
  echo '  --mode MODE        standard|proxy-server|proxy-client|reverse-server|bridge-server'
  echo '  --modes LIST       Comma-separated modes, e.g., standard,proxy-server'
  echo '  --all-modes        Build bundles for all modes'
  echo '  --version VERSION  Specify V2Ray version, e.g., --version v5.10.0'
  echo '  --proxy PROXY      Download via proxy, e.g., http://127.0.0.1:8118'
  echo '  --output FILE      Output tar.gz path (optional)'
  echo '  -h, --help         Show this help'
  exit 0
}

parse_args() {
  while [[ "$#" -gt '0' ]]; do
    case "$1" in
      '--mode')
        INSTALL_MODE="${2:-standard}"
        shift
        ;;
      '--modes')
        MODES_LIST="${2:?error: Please specify the modes list.}"
        shift
        ;;
      '--all-modes')
        ALL_MODES='yes'
        ;;
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
      '-h' | '--help')
        usage
        ;;
      *)
        echo "$0: unknown option -- -"
        exit 1
        ;;
    esac
    shift
  done
}

write_offline_installer() {
  cat > "${BUNDLE_DIR}/install-offline.sh" << 'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC2268

# The files installed by the script conform to the Filesystem Hierarchy Standard:
# https://wiki.linuxfoundation.org/lsb/fhs

# This installer is fully offline and only uses local bundle files.

set -e

# You can set this variable whatever you want in shell session right before running this script by issuing:
# export DAT_PATH='/usr/local/share/v2ray'
DAT_PATH=${DAT_PATH:-/usr/local/share/v2ray}

# You can set this variable whatever you want in shell session right before running this script by issuing:
# export JSON_PATH='/usr/local/etc/v2ray'
JSON_PATH=${JSON_PATH:-/usr/local/etc/v2ray}

# Set this variable only if you are starting v2ray with multiple configuration files:
# export JSONS_PATH='/usr/local/etc/v2ray'

# Set this variable only if you want this script to check all the systemd unit file:
# export check_all_service_files='yes'
check_all_service_files=${check_all_service_files:-no}

# Bundle mode is fixed when the bundle is created.
BUNDLE_MODE='__BUNDLE_MODE__'
BUNDLE_VERSION='__BUNDLE_VERSION__'

curl() {
  $(type -P curl) -L -q --retry 5 --retry-delay 10 --retry-max-time 60 "$@"
}

systemd_cat_config() {
  if systemd-analyze --help | grep -qw 'cat-config'; then
    systemd-analyze --no-pager cat-config "$@"
    echo
  else
    echo "${aoi}~~~~~~~~~~~~~~~~"
    cat "$@" "$1".d/*
    echo "${aoi}~~~~~~~~~~~~~~~~"
    echo "${red}warning: ${green}The systemd version on the current operating system is too low."
    echo "${red}warning: ${green}Please consider to upgrade the systemd or the operating system.${reset}"
    echo
  fi
}

check_if_running_as_root() {
  if [[ "$UID" -ne '0' ]]; then
    echo 'error: Please run as root.'
    exit 1
  fi
}

identify_the_operating_system_and_architecture() {
  if [[ "$(uname)" == 'Linux' ]]; then
    case "$(uname -m)" in
      'i386' | 'i686')
        MACHINE='32'
        ;;
      'amd64' | 'x86_64')
        MACHINE='64'
        ;;
      'armv5tel')
        MACHINE='arm32-v5'
        ;;
      'armv6l')
        MACHINE='arm32-v6'
        grep Features /proc/cpuinfo | grep -qw 'vfp' || MACHINE='arm32-v5'
        ;;
      'armv7' | 'armv7l')
        MACHINE='arm32-v7a'
        grep Features /proc/cpuinfo | grep -qw 'vfp' || MACHINE='arm32-v5'
        ;;
      'armv8' | 'aarch64')
        MACHINE='arm64-v8a'
        ;;
      'mips')
        MACHINE='mips32'
        ;;
      'mipsle')
        MACHINE='mips32le'
        ;;
      'mips64')
        MACHINE='mips64'
        ;;
      'mips64le')
        MACHINE='mips64le'
        ;;
      'ppc64')
        MACHINE='ppc64'
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
        echo 'error: The architecture is not supported.'
        exit 1
        ;;
    esac
    if [[ ! -f '/etc/os-release' ]]; then
      echo "error: Don't use outdated Linux distributions."
      exit 1
    fi
    if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc' /proc/1/cgroup && [[ "$(type -P systemctl)" ]]; then
      true
    elif [[ -d /run/systemd/system ]] || grep -q systemd <(ls -l /sbin/init); then
      true
    else
      echo 'error: Only Linux distributions using systemd are supported.'
      exit 1
    fi
  else
    echo 'error: This operating system is not supported.'
    exit 1
  fi
}

check_dependencies() {
  local missing='0'
  for bin in tput unzip sha256sum systemctl; do
    if ! type -P "$bin" > /dev/null 2>&1; then
      echo "error: Missing dependency: $bin"
      missing='1'
    fi
  done
  if [[ "$missing" -eq '1' ]]; then
    echo 'error: Please install missing dependencies offline, then retry.'
    exit 1
  fi
}

decompression() {
  if ! unzip -q "$1" -d "$TMP_DIRECTORY"; then
    echo 'error: V2Ray decompression failed.'
    "rm" -r "$TMP_DIRECTORY"
    echo "removed: $TMP_DIRECTORY"
    exit 1
  fi
  echo "info: Extract V2Ray package to $TMP_DIRECTORY and prepare it for installation."
}

install_file() {
  NAME="$1"
  if [[ "$NAME" == 'v2ray' ]] || [[ "$NAME" == 'v2ctl' ]]; then
    mkdir -p '/usr/local/bin'
    install -m 755 "${TMP_DIRECTORY}/$NAME" "/usr/local/bin/$NAME"
  elif [[ "$NAME" == 'geoip.dat' ]] || [[ "$NAME" == 'geosite.dat' ]]; then
    install -m 644 "${TMP_DIRECTORY}/$NAME" "${DAT_PATH}/$NAME"
  fi
}

install_v2ray() {
  install_file v2ray
  if [[ -f "${TMP_DIRECTORY}/v2ctl" ]]; then
    install_file v2ctl
  else
    if [[ -f '/usr/local/bin/v2ctl' ]]; then
      rm '/usr/local/bin/v2ctl'
    fi
  fi
  install -d "$DAT_PATH"
  if [[ ! -f "${DAT_PATH}/.undat" ]]; then
    install_file geoip.dat
    install_file geosite.dat
  fi
  if [[ -z "$JSONS_PATH" ]] && [[ ! -d "$JSON_PATH" ]]; then
    install -d "$JSON_PATH"
    echo '{}' > "${JSON_PATH}/config.json"
    CONFIG_NEW='1'
  fi
  if [[ -n "$JSONS_PATH" ]] && [[ ! -d "$JSONS_PATH" ]]; then
    install -d "$JSONS_PATH"
    for BASE in 00_log 01_api 02_dns 03_routing 04_policy 05_inbounds 06_outbounds 07_transport 08_stats 09_reverse; do
      echo '{}' > "${JSONS_PATH}/${BASE}.json"
    done
    CONFDIR='1'
  fi
  if [[ ! -d '/var/log/v2ray/' ]]; then
    if id nobody | grep -qw 'nogroup'; then
      install -d -m 700 -o nobody -g nogroup /var/log/v2ray/
      install -m 600 -o nobody -g nogroup /dev/null /var/log/v2ray/access.log
      install -m 600 -o nobody -g nogroup /dev/null /var/log/v2ray/error.log
    else
      install -d -m 700 -o nobody -g nobody /var/log/v2ray/
      install -m 600 -o nobody -g nobody /dev/null /var/log/v2ray/access.log
      install -m 600 -o nobody -g nobody /dev/null /var/log/v2ray/error.log
    fi
    LOG='1'
  fi
}

install_startup_service_file() {
  CURRENT_VERSION="$BUNDLE_VERSION"
  if [[ "$(echo "${CURRENT_VERSION#v}" | sed 's/-.*//' | awk -F'.' '{print $1}')" -gt "4" ]]; then
    START_COMMAND="/usr/local/bin/v2ray run"
  else
    START_COMMAND="/usr/local/bin/v2ray"
  fi
  install -m 644 "${TMP_DIRECTORY}/systemd/system/v2ray.service" /etc/systemd/system/v2ray.service
  install -m 644 "${TMP_DIRECTORY}/systemd/system/v2ray@.service" /etc/systemd/system/v2ray@.service
  mkdir -p '/etc/systemd/system/v2ray.service.d'
  mkdir -p '/etc/systemd/system/v2ray@.service.d/'
  if [[ -n "$JSONS_PATH" ]]; then
    "rm" -f '/etc/systemd/system/v2ray.service.d/10-donot_touch_single_conf.conf' \
      '/etc/systemd/system/v2ray@.service.d/10-donot_touch_single_conf.conf'
    echo "# In case you have a good reason to do so, duplicate this file in same directory and make your customizes there.
# Or all changes you made will be lost!  # Refer: https://www.freedesktop.org/software/systemd/man/systemd.unit.html
[Service]
ExecStart=
ExecStart=${START_COMMAND} -confdir $JSONS_PATH" |
      tee '/etc/systemd/system/v2ray.service.d/10-donot_touch_multi_conf.conf' > '/etc/systemd/system/v2ray@.service.d/10-donot_touch_multi_conf.conf'
  else
    "rm" -f '/etc/systemd/system/v2ray.service.d/10-donot_touch_multi_conf.conf' \
      '/etc/systemd/system/v2ray@.service.d/10-donot_touch_single_conf.conf'
    echo "# In case you have a good reason to do so, duplicate this file in same directory and make your customizes there.
# Or all changes you made will be lost!  # Refer: https://www.freedesktop.org/software/systemd/man/systemd.unit.html
[Service]
ExecStart=
ExecStart=${START_COMMAND} -config ${JSON_PATH}/config.json" > '/etc/systemd/system/v2ray.service.d/10-donot_touch_single_conf.conf'
    echo "# In case you have a good reason to do so, duplicate this file in same directory and make your customizes there.
# Or all changes you made will be lost!  # Refer: https://www.freedesktop.org/software/systemd/man/systemd.unit.html
[Service]
ExecStart=
ExecStart=${START_COMMAND} -config ${JSON_PATH}/%i.json" > '/etc/systemd/system/v2ray@.service.d/10-donot_touch_single_conf.conf'
  fi
  echo 'info: Systemd service files have been installed successfully!'
  echo "${red}warning: ${green}The following are the actual parameters for the v2ray service startup."
  echo "${red}warning: ${green}Please make sure the configuration file path is correctly set.${reset}"
  systemd_cat_config /etc/systemd/system/v2ray.service
  if [[ x"${check_all_service_files:0:1}" = x'y' ]]; then
    echo
    echo
    systemd_cat_config /etc/systemd/system/v2ray@.service
  fi
  systemctl daemon-reload
  SYSTEMD='1'
}

stop_v2ray() {
  V2RAY_CUSTOMIZE="$(systemctl list-units | grep 'v2ray@' | awk -F ' ' '{print $1}')"
  if [[ -z "$V2RAY_CUSTOMIZE" ]]; then
    local v2ray_daemon_to_stop='v2ray.service'
  else
    local v2ray_daemon_to_stop="$V2RAY_CUSTOMIZE"
  fi
  if ! systemctl stop "$v2ray_daemon_to_stop"; then
    echo 'error: Stopping the V2Ray service failed.'
    exit 1
  fi
  echo 'info: Stop the V2Ray service.'
}

show_help() {
  echo "usage: $0 [--mode MODE]"
  echo ''
  echo 'Installation Modes:'
  echo "  --mode ${BUNDLE_MODE} (bundle default)"
  echo ''
  echo 'Environment Variables (for proxy-client, reverse-server and bridge-server modes):'
  echo '  V2RAY_PROXY_SERVER_IP     Proxy server IP address (required for proxy-client)'
  echo '  V2RAY_PROXY_ID          VMess user ID (required for proxy-server, proxy-client, and bridge-server)'
  echo '  V2RAY_REVERSE_SERVER_IP  Reverse proxy server IP address (optional for proxy-client)'
  echo '  V2RAY_REVERSE_ID         Reverse proxy user ID (required for reverse-server and bridge-server)'
  exit 0
}

parse_args() {
  while [[ "$#" -gt '0' ]]; do
    case "$1" in
      '--mode')
        INSTALL_MODE="${2:-${BUNDLE_MODE}}"
        shift
        ;;
      '-h' | '--help')
        show_help
        ;;
      *)
        echo "$0: unknown option -- -"
        exit 1
        ;;
    esac
    shift
  done
}

main() {
  check_if_running_as_root
  identify_the_operating_system_and_architecture
  parse_args "$@"
  check_dependencies

  if [[ "$INSTALL_MODE" != "$BUNDLE_MODE" ]]; then
    echo "error: This bundle only supports mode: ${BUNDLE_MODE}"
    exit 1
  fi

  red=$(tput setaf 1)
  green=$(tput setaf 2)
  aoi=$(tput setaf 6)
  reset=$(tput sgr0)

  BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd)"
  ZIP_FILE="${BUNDLE_DIR}/payload/v2ray-linux-${MACHINE}.zip"
  DGST_FILE="${ZIP_FILE}.dgst"
  CONFIG_FILE="${BUNDLE_DIR}/payload/config.json"

  if [[ ! -f "$ZIP_FILE" ]]; then
    echo "error: Missing V2Ray archive: $ZIP_FILE"
    exit 1
  fi
  if [[ ! -f "$DGST_FILE" ]]; then
    echo "error: Missing digest file: $DGST_FILE"
    exit 1
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "error: Missing config file: $CONFIG_FILE"
    exit 1
  fi

  CHECKSUM=$(awk -F '= ' '/256=/ {print $2}' < "${DGST_FILE}")
  LOCALSUM=$(sha256sum "$ZIP_FILE" | awk '{printf $1}')
  if [[ "$CHECKSUM" != "$LOCALSUM" ]]; then
    echo 'error: SHA256 check failed! Please re-create the bundle.'
    exit 1
  fi

  TMP_DIRECTORY="$(mktemp -d)"
  decompression "$ZIP_FILE"

  if systemctl list-unit-files | grep -qw 'v2ray'; then
    if [[ -n "$(pidof v2ray)" ]]; then
      stop_v2ray
      V2RAY_RUNNING='1'
    fi
  fi

  install_v2ray
  install_startup_service_file
  echo 'installed: /usr/local/bin/v2ray'
  if [[ -f '/usr/local/bin/v2ctl' ]]; then
    echo 'installed: /usr/local/bin/v2ctl'
  fi
  if [[ ! -f "${DAT_PATH}/.undat" ]]; then
    echo "installed: ${DAT_PATH}/geoip.dat"
    echo "installed: ${DAT_PATH}/geosite.dat"
  fi
  if [[ "$CONFIG_NEW" -eq '1' ]]; then
    echo "installed: ${JSON_PATH}/config.json"
  fi
  if [[ "$CONFDIR" -eq '1' ]]; then
    echo "installed: ${JSON_PATH}/00_log.json"
    echo "installed: ${JSON_PATH}/01_api.json"
    echo "installed: ${JSON_PATH}/02_dns.json"
    echo "installed: ${JSON_PATH}/03_routing.json"
    echo "installed: ${JSON_PATH}/04_policy.json"
    echo "installed: ${JSON_PATH}/05_inbounds.json"
    echo "installed: ${JSON_PATH}/06_outbounds.json"
    echo "installed: ${JSON_PATH}/07_transport.json"
    echo "installed: ${JSON_PATH}/08_stats.json"
    echo "installed: ${JSON_PATH}/09_reverse.json"
  fi
  if [[ "$LOG" -eq '1' ]]; then
    echo 'installed: /var/log/v2ray/'
    echo 'installed: /var/log/v2ray/access.log'
    echo 'installed: /var/log/v2ray/error.log'
  fi
  if [[ "$SYSTEMD" -eq '1' ]]; then
    echo 'installed: /etc/systemd/system/v2ray.service'
    echo 'installed: /etc/systemd/system/v2ray@.service'
  fi

  cp -f "$CONFIG_FILE" "${JSON_PATH}/config.json"

  "rm" -r "$TMP_DIRECTORY"
  echo "removed: $TMP_DIRECTORY"

  case "$INSTALL_MODE" in
    'proxy-server')
      sed -i "s|{V2RAY_PROXY_ID}|${V2RAY_PROXY_ID}|g" "${JSON_PATH}/config.json"
      echo 'info: Proxy server mode installed.'
      ;;
    'proxy-client')
      sed -i "s|{V2RAY_PROXY_SERVER_IP}|${V2RAY_PROXY_SERVER_IP}|g" "${JSON_PATH}/config.json"
      sed -i "s|{V2RAY_PROXY_ID}|${V2RAY_PROXY_ID}|g" "${JSON_PATH}/config.json"
      [[ -n "$V2RAY_REVERSE_SERVER_IP" ]] && sed -i "s|{V2RAY_REVERSE_SERVER_IP}|${V2RAY_REVERSE_SERVER_IP}|g" "${JSON_PATH}/config.json"
      [[ -n "$V2RAY_REVERSE_ID" ]] && sed -i "s|{V2RAY_REVERSE_ID}|${V2RAY_REVERSE_ID}|g" "${JSON_PATH}/config.json"
      echo 'info: Proxy client mode installed.'
      ;;
    'reverse-server')
      sed -i "s|{V2RAY_REVERSE_ID}|${V2RAY_REVERSE_ID}|g" "${JSON_PATH}/config.json"
      echo 'info: Reverse proxy server mode installed.'
      ;;
    'bridge-server')
      sed -i "s|{V2RAY_PROXY_ID}|${V2RAY_PROXY_ID}|g" "${JSON_PATH}/config.json"
      sed -i "s|{V2RAY_REVERSE_ID}|${V2RAY_REVERSE_ID}|g" "${JSON_PATH}/config.json"
      echo 'info: Bridge server mode installed.'
      ;;
    *)
      echo 'info: Standard mode installed.'
      ;;
  esac

  if [[ "$V2RAY_RUNNING" -eq '1' ]]; then
    systemctl start v2ray
  else
    sed -i '/RestartPreventExitStatus/a\Environment="V2RAY_VMESS_AEAD_FORCED=false"' /etc/systemd/system/v2ray.service
    systemctl daemon-reload
    systemctl enable v2ray
    systemctl start v2ray
    if [[ "$INSTALL_MODE" != 'standard' ]]; then
      ufw disable 2> /dev/null || true
      iptables -F 2> /dev/null || true
    fi
  fi

  echo "info: V2Ray $BUNDLE_VERSION is installed."
}

main "$@"
EOF

  sed -i "s|__BUNDLE_MODE__|${INSTALL_MODE}|g" "${BUNDLE_DIR}/install-offline.sh"
  sed -i "s|__BUNDLE_VERSION__|${RELEASE_VERSION}|g" "${BUNDLE_DIR}/install-offline.sh"
  chmod +x "${BUNDLE_DIR}/install-offline.sh"
}

build_bundle() {
  local mode="$1"
  INSTALL_MODE="$mode"
  get_config_link

  local tmp_directory
  tmp_directory="$(mktemp -d)"
  BUNDLE_DIR="${tmp_directory}/v2ray-offline"
  PAYLOAD_DIR="${BUNDLE_DIR}/payload"
  mkdir -p "$PAYLOAD_DIR"

  ZIP_FILE="${PAYLOAD_DIR}/v2ray-linux-${MACHINE}.zip"

  echo "info: Downloading V2Ray archive for ${MACHINE}: ${RELEASE_VERSION}"
  if ! curl -x "${PROXY}" -R -H 'Cache-Control: no-cache' -o "$ZIP_FILE" \
    "https://github.com/v2fly/v2ray-core/releases/download/${RELEASE_VERSION}/v2ray-linux-${MACHINE}.zip"; then
    echo 'error: Download failed! Please check your network or try again.'
    exit 1
  fi

  echo "info: Downloading V2Ray digest for ${MACHINE}: ${RELEASE_VERSION}"
  if ! curl -x "${PROXY}" -sSR -H 'Cache-Control: no-cache' -o "${ZIP_FILE}.dgst" \
    "https://github.com/v2fly/v2ray-core/releases/download/${RELEASE_VERSION}/v2ray-linux-${MACHINE}.zip.dgst"; then
    echo 'error: Download failed! Please check your network or try again.'
    exit 1
  fi

  if [[ "$(cat "${ZIP_FILE}.dgst")" == 'Not Found' ]]; then
    echo 'error: This version does not support verification. Please replace with another version.'
    exit 1
  fi

  echo "info: Downloading V2Ray config: ${DOWNLOAD_CONF_LINK}"
  if ! curl -x "${PROXY}" -R -H 'Cache-Control: no-cache' -o "${PAYLOAD_DIR}/config.json" \
    "$DOWNLOAD_CONF_LINK"; then
    echo 'error: Download failed! Please check your network or try again.'
    exit 1
  fi

  CHECKSUM=$(awk -F '= ' '/256=/ {print $2}' < "${ZIP_FILE}.dgst")
  LOCALSUM=$(sha256sum "$ZIP_FILE" | awk '{printf $1}')
  if [[ "$CHECKSUM" != "$LOCALSUM" ]]; then
    echo 'error: SHA256 check failed! Please check your network or try again.'
    exit 1
  fi

  write_offline_installer

  local output_file
  if [[ -n "$OUTPUT_FILE" ]]; then
    output_file="$OUTPUT_FILE"
  else
    output_file="v2ray-offline-${RELEASE_VERSION}-${MACHINE}-${INSTALL_MODE}.tar.gz"
  fi

  tar -czf "$output_file" -C "$tmp_directory" v2ray-offline
  echo "info: Offline bundle created: $output_file"

  "rm" -r "$tmp_directory"
}

split_modes() {
  local modes_raw="$1"
  local modes_clean
  modes_clean="$(echo "$modes_raw" | tr ',' ' ')"
  echo "$modes_clean"
}

main() {
  parse_args "$@"
  identify_the_operating_system_and_architecture
  get_latest_version

  if [[ "$ALL_MODES" == 'yes' ]]; then
    MODES_LIST='standard,proxy-server,proxy-client,reverse-server,bridge-server'
  fi

  if [[ -n "$MODES_LIST" ]]; then
    local modes
    modes="$(split_modes "$MODES_LIST")"
    for mode in $modes; do
      build_bundle "$mode"
    done
  else
    build_bundle "$INSTALL_MODE"
  fi
}

main "$@"
