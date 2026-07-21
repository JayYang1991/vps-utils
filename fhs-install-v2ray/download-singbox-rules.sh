#!/usr/bin/env bash
# shellcheck disable=SC2268
#
# Download latest sing-box rule sets (.srs) to target directory.
# Geosite source: https://github.com/SagerNet/sing-geosite
# Geoip source:   https://github.com/MetaCubeX/meta-rules-dat

set -e

TARGET_DIR=${TARGET_DIR:-}
RULES=("google" "youtube" "telegram" "discord" "cn" "openai")

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

curl() {
  $(type -P curl) -L -q --retry 5 --retry-delay 10 --retry-max-time 60 "$@"
}

usage() {
  echo "Usage: $0 --dir <target_dir>"
  echo
  echo "Example:"
  echo "  $0 --dir /usr/local/etc/sing-box/rule-set"
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      '--dir' | '-d')
        TARGET_DIR="${2:?error: Please specify target directory.}"
        shift
        ;;
      '-h' | '--help')
        usage
        exit 0
        ;;
      *)
        echo "${red}error: Unknown argument: $1${reset}"
        usage
        exit 1
        ;;
    esac
    shift
  done

  if [[ -z "$TARGET_DIR" ]]; then
    echo "${red}error: Target directory is required.${reset}"
    usage
    exit 1
  fi
}

download_geosite() {
  local rule="$1"
  local out_file="${TARGET_DIR}/geosite-${rule}.srs"
  local url="https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-${rule}.srs"

  echo "${aoi}info: downloading geosite-${rule}.srs${reset}"
  if curl -fsS -H 'Cache-Control: no-cache' -o "$out_file" "$url"; then
    echo "${green}info: saved -> $out_file${reset}"
    return 0
  fi

  echo "${red}error: failed to download geosite-${rule}.srs${reset}"
  "rm" -f "$out_file"
  return 1
}

download_geoip() {
  local rule="$1"
  local out_file="${TARGET_DIR}/geoip-${rule}.srs"
  local primary_url="https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/${rule}.srs"
  local fallback_url="https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-${rule}.srs"

  echo "${aoi}info: downloading geoip-${rule}.srs${reset}"
  if curl -fsS -H 'Cache-Control: no-cache' -o "$out_file" "$primary_url"; then
    echo "${green}info: saved -> $out_file (MetaCubeX)${reset}"
    return 0
  fi

  echo "${aoi}info: primary failed, trying fallback source for geoip-${rule}.srs${reset}"
  if curl -fsS -H 'Cache-Control: no-cache' -o "$out_file" "$fallback_url"; then
    echo "${green}info: saved -> $out_file (SagerNet fallback)${reset}"
    return 0
  fi

  echo "${red}error: failed to download geoip-${rule}.srs${reset}"
  "rm" -f "$out_file"
  return 1
}

main() {
  parse_args "$@"

  if ! mkdir -p "$TARGET_DIR"; then
    echo "${red}error: failed to create target directory: $TARGET_DIR${reset}"
    exit 1
  fi

  local failed='0'
  local rule
  echo "${aoi}info: target directory: $TARGET_DIR${reset}"
  for rule in "${RULES[@]}"; do
    download_geosite "$rule" || failed='1'
    download_geoip "$rule" || failed='1'
  done

  if [[ "$failed" == '1' ]]; then
    echo "${red}error: some sing-box rules failed to download.${reset}"
    exit 1
  fi

  echo "${green}info: sing-box rules download completed successfully.${reset}"
}

main "$@"
