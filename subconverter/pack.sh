#!/usr/bin/env bash
#
# pack.sh
# subconverter 自动化打包脚本
# 将 subconverter 二进制程序与规则、模板等基础资源打包为标准 tar.gz 压缩包，
# 生成 install.sh 可直接离线使用的 subconverter_${ARCH_NAME}.tar.gz。
#
# GitHub: https://github.com/JayYang1991/vps-utils
#

set -eo pipefail

# --- 视觉颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success() { echo -e "${GREEN}${BOLD}✔ $1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${SCRIPT_DIR}/base"

# --- 架构检测 ---
ARCH_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--arch)
      ARCH_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      echo "用法: $0 [选项]"
      echo ""
      echo "选项:"
      echo "  -a, --arch ARCH    指定目标架构 (linux64, aarch64, armv7, linux32, 默认自动检测)"
      echo "  -h, --help         显示本帮助信息"
      exit 0
      ;;
    *)
      warn "未知参数: $1"
      shift
      ;;
  esac
done

if [[ -n "$ARCH_OVERRIDE" ]]; then
  ARCH_NAME="$ARCH_OVERRIDE"
else
  SYS_ARCH=$(uname -m)
  case "$SYS_ARCH" in
    x86_64|amd64)   ARCH_NAME="linux64" ;;
    aarch64|arm64)  ARCH_NAME="aarch64" ;;
    armv7*|armhf)   ARCH_NAME="armv7" ;;
    i386|i686)      ARCH_NAME="linux32" ;;
    *)              ARCH_NAME="linux64" ;;
  esac
fi

OUTPUT_FILENAME="subconverter_${ARCH_NAME}.tar.gz"
OUTPUT_PATH="${SCRIPT_DIR}/${OUTPUT_FILENAME}"
GENERIC_OUTPUT_PATH="${SCRIPT_DIR}/subconverter.tar.gz"

log "正在为架构 [${BOLD}${CYAN}${ARCH_NAME}${NC}] 打包 subconverter..."

TEMP_BUILD_DIR=$(mktemp -d /tmp/subconverter_pack.XXXXXX)
cleanup() {
  rm -rf "$TEMP_BUILD_DIR" 2>/dev/null || true
}
trap cleanup EXIT

PACK_TARGET_DIR="${TEMP_BUILD_DIR}/subconverter"
mkdir -p "${PACK_TARGET_DIR}"

# --- 1. 获取 subconverter 可执行二进制文件 ---
SUBCONVERTER_BIN=""

# 优先级 1: 本地 subconverter/bin/subconverter 或当前目录 subconverter
if [[ -f "${SCRIPT_DIR}/bin/subconverter" && -x "${SCRIPT_DIR}/bin/subconverter" ]]; then
  SUBCONVERTER_BIN="${SCRIPT_DIR}/bin/subconverter"
  log "使用本地二进制: ${SUBCONVERTER_BIN}"
elif [[ -f "${SCRIPT_DIR}/subconverter" && -x "${SCRIPT_DIR}/subconverter" ]]; then
  SUBCONVERTER_BIN="${SCRIPT_DIR}/subconverter"
  log "使用本地二进制: ${SUBCONVERTER_BIN}"
elif [[ -f "/usr/local/subconverter/subconverter" && -x "/usr/local/subconverter/subconverter" ]]; then
  SUBCONVERTER_BIN="/usr/local/subconverter/subconverter"
  log "使用系统已安装的二进制: ${SUBCONVERTER_BIN}"
elif [[ -f "${SCRIPT_DIR}/build/subconverter" && -x "${SCRIPT_DIR}/build/subconverter" ]]; then
  SUBCONVERTER_BIN="${SCRIPT_DIR}/build/subconverter"
  log "使用 CMake 编译产物: ${SUBCONVERTER_BIN}"
else
  # 优先级 2: 从官方 Release 下载对应架构的二进制核心
  log "未检测到本地编译的 subconverter 二进制，正在从 Release 获取对应架构 (${ARCH_NAME}) 核心..."
  DOWNLOAD_URL="https://github.com/tindy2013/subconverter/releases/latest/download/subconverter_${ARCH_NAME}.tar.gz"
  TMP_DL_ARCHIVE="${TEMP_BUILD_DIR}/download_${ARCH_NAME}.tar.gz"
  
  if curl -4 -sSL --retry 3 --retry-delay 3 -o "${TMP_DL_ARCHIVE}" "${DOWNLOAD_URL}"; then
    tar -xzf "${TMP_DL_ARCHIVE}" -C "${TEMP_BUILD_DIR}"
    if [[ -f "${TEMP_BUILD_DIR}/subconverter/subconverter" ]]; then
      SUBCONVERTER_BIN="${TEMP_BUILD_DIR}/subconverter/subconverter"
      log "官方 Release 二进制获取成功！"
    fi
  fi
fi

if [[ -z "$SUBCONVERTER_BIN" || ! -f "$SUBCONVERTER_BIN" ]]; then
  error "未能获取有效的 subconverter 二进制文件，打包终止！"
  exit 1
fi

# 复制二进制至打包目录
if [[ "$SUBCONVERTER_BIN" != "${PACK_TARGET_DIR}/subconverter" ]]; then
  cp -f "$SUBCONVERTER_BIN" "${PACK_TARGET_DIR}/subconverter"
fi
chmod +x "${PACK_TARGET_DIR}/subconverter"

# --- 2. 复制规则库、模板与基础配置文件 ---
if [[ -d "$BASE_DIR" ]]; then
  log "正在同步 base 规则库、配置模板与预设文件..."
  cp -rf "$BASE_DIR"/* "${PACK_TARGET_DIR}/"
else
  warn "未找到 ${BASE_DIR} 目录，请确认源码完整性！"
fi

# 确保默认示例配置文件存在
if [[ ! -f "${PACK_TARGET_DIR}/pref.example.ini" && -f "${BASE_DIR}/pref.example.ini" ]]; then
  cp -f "${BASE_DIR}/pref.example.ini" "${PACK_TARGET_DIR}/pref.example.ini"
fi

# --- 3. 执行打包压缩 ---
log "正在生成标准压缩归档: ${OUTPUT_FILENAME} ..."
rm -f "${OUTPUT_PATH}" "${GENERIC_OUTPUT_PATH}"

TMP_ARCHIVE=$(mktemp /tmp/subconverter_out.XXXXXX.tar.gz)
tar -C "${TEMP_BUILD_DIR}" -czf "${TMP_ARCHIVE}" subconverter
mv "${TMP_ARCHIVE}" "${OUTPUT_PATH}"
cp -f "${OUTPUT_PATH}" "${GENERIC_OUTPUT_PATH}"

if [[ -f "${OUTPUT_PATH}" ]]; then
  FILE_SIZE=$(du -h "${OUTPUT_PATH}" | awk '{print $1}')
  success "打包成功！产物已生成:"
  echo -e "  • 架构产物: ${CYAN}${OUTPUT_PATH}${NC} (${FILE_SIZE})"
  echo -e "  • 通用链接: ${CYAN}${GENERIC_OUTPUT_PATH}${NC}"
  echo ""
  log "压缩包内容预览:"
  (tar -tzf "${OUTPUT_PATH}" | head -n 25) || true
  echo "..."
else
  error "打包失败，未能生成产物文件！"
  exit 1
fi
