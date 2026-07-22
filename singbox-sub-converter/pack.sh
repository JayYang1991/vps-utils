#!/usr/bin/env bash
#
# pack.sh
# singbox-sub-converter 项目打包脚本
# 将项目文件打包为 tar.gz，排除 install.sh 脚本、打包脚本自身及临时/缓存文件。

set -e

# --- Visual Colors ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
OUTPUT_NAME="singbox-sub-converter.tar.gz"
OUTPUT_PATH="${SCRIPT_DIR}/${OUTPUT_NAME}"

cd "${SCRIPT_DIR}"

log "正在打包 singbox-sub-converter 项目..."

# Perform tar packing with exclusions
tar --exclude="./install.sh" \
    --exclude="./install*.sh" \
    --exclude="./${SCRIPT_NAME}" \
    --exclude="./*.tar.gz" \
    --exclude="./.git" \
    --exclude="./__pycache__" \
    --exclude="./*/__pycache__" \
    --exclude="./*/*/__pycache__" \
    --exclude="./.pytest_cache" \
    --exclude="./.DS_Store" \
    --exclude="./venv" \
    --exclude="./.venv" \
    -czf "${OUTPUT_PATH}" .

if [[ -f "${OUTPUT_PATH}" ]]; then
  log "项目打包成功！产物绝对路径:"
  log "  ${OUTPUT_PATH}"
  echo ""
  log "打包内容归档清单 preview:"
  tar -tzf "${OUTPUT_PATH}" | head -n 20
  echo "..."
else
  error "打包失败，未找到生成产物！"
  exit 1
fi
