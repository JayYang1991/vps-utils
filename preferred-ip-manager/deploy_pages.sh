#!/usr/bin/env bash
#
# deploy_pages.sh
# Cloudflare Pages 测速网站一键生成、构建与部署脚本
# 专为 CloudflareSpeedTest (cfst) 打造，极致节约资源以满足 Cloudflare 免费版限制。
#
# GitHub: https://github.com/JayYang1991/vps-utils
#

set -eo pipefail

# --- 颜色与输出 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")
SRC_DIR="${SCRIPT_DIR}/speedtest-pages"
PUBLIC_DIR="${SRC_DIR}/public"
FUNCTIONS_DIR="${SRC_DIR}/functions"
DIST_DIR="${SCRIPT_DIR}/dist"
ZIP_FILE="${SCRIPT_DIR}/speedtest-pages.zip"

PROJECT_NAME="cf-speedtest"
ACTION="interactive"

# --- 显示帮助信息 ---
show_help() {
  echo -e "${CYAN}${BOLD}Cloudflare Pages 测速节点一键构建与部署脚本${NC}"
  echo ""
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "选项:"
  echo "  -b, --build-only            仅在本地生成静态测速文件并打包 dist 与 ZIP，不进行线上部署"
  echo "  -d, --deploy                构建并自动通过 Wrangler CLI 部署至 Cloudflare Pages"
  echo "  -n, --name <NAME>           指定 Cloudflare Pages 项目名称 (默认: cf-speedtest)"
  echo "  -h, --help                  显示此帮助信息"
  echo ""
  echo "示例:"
  echo "  bash $0 --build-only        # 本地生成构建包 (可直接在 CF 网页后台拖拽上传)"
  echo "  bash $0 --deploy            # 一键通过 Wrangler 部署上线"
  echo "  bash $0 -n my-speedtest -d  # 指定项目名称部署"
}

# --- 解析参数 ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--build-only)
      ACTION="build"
      shift 1
      ;;
    -d|--deploy)
      ACTION="deploy"
      shift 1
      ;;
    -n|--name|--project-name)
      PROJECT_NAME="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      warn "未知参数: $1"
      show_help
      exit 1
      ;;
  esac
done

# --- 快速生成防压缩二进制测速文件 ---
generate_bin_file() {
  local target_file="$1"
  local size_mb="$2"
  local size_bytes=$((size_mb * 1024 * 1024))

  log "正在生成静态测速文件: $(basename "$target_file") (${size_mb} MB)..."

  if command -v openssl &>/dev/null; then
    openssl rand -out "$target_file" "$size_bytes" 2>/dev/null || true
  elif command -v dd &>/dev/null; then
    dd if=/dev/urandom of="$target_file" bs=1M count="$size_mb" status=none 2>/dev/null || true
  elif command -v python3 &>/dev/null; then
    python3 -c "import os; open('$target_file', 'wb').write(os.urandom($size_bytes))" 2>/dev/null || true
  else
    head -c "$size_bytes" /dev/urandom > "$target_file" 2>/dev/null || true
  fi
}

# --- 执行构建流程 ---
build_pages() {
  echo -e "${CYAN}${BOLD}=== 开始构建 Cloudflare Pages 测速站点 ===${NC}"
  log "清理旧构建目录..."
  rm -rf "$DIST_DIR" "$ZIP_FILE"
  mkdir -p "$DIST_DIR"

  # 1. 拷贝静态前端与规则配置
  log "拷贝静态资源与自定义规则配置..."
  if [[ -d "$PUBLIC_DIR" ]]; then
    cp -r "${PUBLIC_DIR}/." "$DIST_DIR/"
  else
    error "未找到源码目录: $PUBLIC_DIR"
    exit 1
  fi

  # 2. 生成静态测速大文件 (5MB, 10MB, 20MB)
  generate_bin_file "${DIST_DIR}/5mb.bin" 5
  generate_bin_file "${DIST_DIR}/10mb.bin" 10
  generate_bin_file "${DIST_DIR}/20mb.bin" 20

  # 3. 同步 Functions 目录 (确保根目录与 dist 均包含，以便 Wrangler 100% 识别打包)
  if [[ -d "$FUNCTIONS_DIR" ]]; then
    log "同步 Pages Functions 接口..."
    mkdir -p "${SCRIPT_DIR}/functions" "$DIST_DIR/functions"
    cp -r "${FUNCTIONS_DIR}/." "${SCRIPT_DIR}/functions/"
    cp -r "${FUNCTIONS_DIR}/." "$DIST_DIR/functions/"
  fi

  # 4. 打包为 ZIP 格式
  if command -v zip &>/dev/null; then
    log "打包构建目录为 ZIP 文件: $ZIP_FILE ..."
    (cd "$DIST_DIR" && zip -q -r -u "$ZIP_FILE" . 2>/dev/null || true)
  fi

  success "构建完成！输出目录: ${DIST_DIR}"
  if [[ -f "$ZIP_FILE" ]]; then
    success "ZIP 上传包已生成: ${ZIP_FILE} ($(du -h "$ZIP_FILE" | cut -f1))"
  fi
  echo ""
}

# --- 执行线上部署 ---
deploy_pages() {
  build_pages

  echo -e "${CYAN}${BOLD}=== 部署至 Cloudflare Pages ===${NC}"
  
  local wrangler_cmd=""
  if command -v wrangler &>/dev/null; then
    wrangler_cmd="wrangler"
  elif command -v npx &>/dev/null; then
    wrangler_cmd="npx wrangler"
  fi

  if [[ -n "$wrangler_cmd" ]]; then
    log "检测到 Wrangler 工具 (${wrangler_cmd})，正在执行一键部署..."
    local deploy_args=("$DIST_DIR" "--project-name" "$PROJECT_NAME" "--commit-dirty=true")
    log "执行指令: ${wrangler_cmd} pages deploy ${deploy_args[*]}"
    
    local deploy_output
    local deploy_status=0
    deploy_output=$($wrangler_cmd pages deploy "${deploy_args[@]}" 2>&1) || deploy_status=$?
    echo "$deploy_output"

    # 清理根目录下的临时 functions 副本，避免污染源码树
    rm -rf "${SCRIPT_DIR}/functions" 2>/dev/null || true

    if [[ $deploy_status -eq 0 ]]; then
      # 尝试从 wrangler 输出中提取真实部署分配的域名
      local real_domain=""
      local matched_url
      matched_url=$(echo "$deploy_output" | grep -oE 'https://[a-zA-Z0-9.-]+\.pages\.dev' | tail -n 1 || true)
      if [[ -n "$matched_url" ]]; then
        real_domain=$(echo "$matched_url" | sed 's~https://~~' | sed -E 's~^[a-f0-9]+\.~~')
      fi
      [[ -z "$real_domain" ]] && real_domain="${PROJECT_NAME}.pages.dev"

      echo ""
      success "================================================================"
      success "  🎉 Cloudflare Pages 测速网站部署成功并已全球上线！"
      success "================================================================"
      echo -e "${CYAN}访问与测速信息:${NC}"
      echo -e "  • 项目名称:     ${BOLD}${PROJECT_NAME}${NC}"
      echo -e "  • 生产主页:     ${BOLD}https://${real_domain}${NC}"
      echo -e "  • 静态测速地址: ${GREEN}${BOLD}https://${real_domain}/20mb.bin${NC} (零配额消耗·推荐)"
      echo -e "  • 延迟测试地址: ${GREEN}${BOLD}https://${real_domain}/test${NC} (HTTPing / cfcolo)"
      echo -e "  • 动态流式测速: ${GREEN}${BOLD}https://${real_domain}/download?size=50${NC} (动态 50MB 流)"
      echo ""
      echo -e "${CYAN}常用测速命令示例:${NC}"
      echo -e "  ${YELLOW}# 1. 使用 CloudflareSpeedTest 下载测速 (延迟前 10 个 IP，每个测速 10 秒):${NC}"
      echo "  ./cfst -url \"https://${real_domain}/20mb.bin\" -dn 10 -dt 10"
      echo ""
      echo -e "  ${YELLOW}# 2. HTTPing 延迟与机房地区测速 (匹配 HKG, NRT, SJC 等机房):${NC}"
      echo "  ./cfst -url \"https://${real_domain}/test\" -httping -cfcolo HKG,NRT,SJC"
      echo ""
      echo -e "  ${YELLOW}# 3. 配合 process_ips.py 自动优选并同步:${NC}"
      echo "  python3 process_ips.py --target cdn --mode speed --url \"https://${real_domain}/20mb.bin\""
      echo "================================================================"
      return 0
    else
      warn "Wrangler 自动部署未完成 (可能是未登录或网络受限)。"
    fi
  else
    warn "未检测到 wrangler 或 npx 命令，跳过 CLI 自动上传。"
  fi

  print_manual_deploy_guide
}

# --- 打印网页端手动上传指南 ---
print_manual_deploy_guide() {
  echo ""
  echo -e "${GREEN}${BOLD}================================================================${NC}"
  echo -e "${GREEN}${BOLD}  📦 本地构建与静态测速包已就绪！可通过网页控制台直接上传部署  ${NC}"
  echo -e "${GREEN}${BOLD}================================================================${NC}"
  echo ""
  echo -e "${CYAN}网页一键上传指南 (无需安装任何 CLI 工具):${NC}"
  echo "  1. 登录 Cloudflare Dashboard: https://dash.cloudflare.com/"
  echo "  2. 进入左侧菜单: [Workers & Pages] -> 点击 [Create application] -> 选择 [Pages] 页签"
  echo "  3. 点击 [Upload assets] (直接上传资产)"
  echo "  4. 设置项目名称 (如: ${PROJECT_NAME})"
  if [[ -f "$ZIP_FILE" ]]; then
    echo -e "  5. 上传已打包的 ZIP 文件: ${BOLD}${ZIP_FILE}${NC}"
  else
    echo -e "  5. 拖拽上传文件夹: ${BOLD}${DIST_DIR}${NC}"
  fi
  echo "  6. 点击 [Deploy site] 即可在 5 秒内完成全球部署！"
  echo ""
  echo -e "${CYAN}部署上线后的测速地址:${NC}"
  echo -e "  • 静态测速文件: ${GREEN}https://${PROJECT_NAME}.pages.dev/20mb.bin${NC} (完全免费，无请求上限)"
  echo -e "  • 延迟测试接口: ${GREEN}https://${PROJECT_NAME}.pages.dev/test${NC} (支持 HTTPing 与机房识别)"
  echo ""
  echo -e "${CYAN}手动测试命令说明:${NC}"
  echo "  • curl 测试连通性:   curl -I https://${PROJECT_NAME}.pages.dev/20mb.bin"
  echo "  • cfst 下载测速:     ./cfst -url https://${PROJECT_NAME}.pages.dev/20mb.bin -dn 10 -dt 10"
  echo "  • cfst 延迟测试:     ./cfst -url https://${PROJECT_NAME}.pages.dev/test -httping -cfcolo HKG,NRT"
  echo -e "${GREEN}================================================================${NC}"
}

# --- 路由执行动作 ---
case "$ACTION" in
  build)
    build_pages
    print_manual_deploy_guide
    ;;
  deploy)
    deploy_pages
    ;;
  interactive)
    build_pages
    echo -e "${YELLOW}是否尝试使用 Wrangler CLI 自动部署至 Cloudflare Pages？ [y/N]: ${NC}"
    read -r -p "请输入 [y/N] (默认 N): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
      deploy_pages
    else
      print_manual_deploy_guide
    fi
    ;;
esac
