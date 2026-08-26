#!/usr/bin/env bash
# ==============================================================================
# vpngate-singbox-openvpn 一键安装部署脚本
# 将程序及依赖安装至 /usr/local/bin/vpngate-singbox-openvpn 并注册 Systemd 自启服务
# 支持在宿主机安装 generate_ovpn.py 并基于 VPNGate CSV 批量生成 .ovpn 和 nodes_mapping.json
# ==============================================================================

set -e

INSTALL_DIR="/usr/local/bin/vpngate-singbox-openvpn"
CONFIG_DIR="/etc/vpngate-singbox-openvpn"
BIN_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_NAME="vpngate-singbox-openvpn"
SERVICE_FILE="${SERVICE_NAME}.service"
UPDATER_SERVICE_NAME="vpngate-singbox-node-updater"
UPDATER_SERVICE_FILE="${UPDATER_SERVICE_NAME}.service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 自动定位项目根目录
if [ -f "${SCRIPT_DIR}/Dockerfile" ]; then
    PROJECT_DIR="${SCRIPT_DIR}"
else
    PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# 颜色高亮
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
NC="\033[0m"

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 1. 解析命令行参数与环境变量
INPUT_SUB_URL="${SINGBOX_SUBSCRIPTION_URL:-}"
INPUT_OVPN_URL="${OVPN_REMOTE_URL:-}"
INPUT_PUBLIC_PORT="${PUBLIC_SOCKS_PORT:-}"
INPUT_COUNTRY="${VPNGATE_COUNTRY:-}"
INPUT_CSV_SOURCE=""
FORCE_CLEAN=false
FORCE_UPGRADE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--upgrade|upgrade)
            FORCE_UPGRADE=true
            shift
            ;;
        --clean|--reinstall|--fresh)
            FORCE_CLEAN=true
            shift
            ;;
        -s|--sub-url|--singbox-url|--subscription-url)
            INPUT_SUB_URL="$2"
            shift 2
            ;;
        -o|--ovpn-url|--ovpn-remote-url|--remote-ovpn)
            INPUT_OVPN_URL="$2"
            shift 2
            ;;
        -p|--socks-port|--public-port|--port)
            INPUT_PUBLIC_PORT="$2"
            shift 2
            ;;
        -c|--country|--country-code)
            INPUT_COUNTRY="$2"
            shift 2
            ;;
        --csv|--csv-source)
            INPUT_CSV_SOURCE="$2"
            shift 2
            ;;
        -h|--help)
            echo "============================================================"
            echo " VPNGate Sing-box & OpenVPN 隧道服务 安装与平滑升级程序"
            echo "============================================================"
            echo "用法: sudo ./install.sh [选项]"
            echo ""
            echo "选项:"
            echo "  -u, --upgrade          执行平滑升级 (保留现有配置与节点池，预构建镜像零停机重启)"
            echo "      --clean            强制全新安装 (重置配置与派生缓存，重新拉取初始节点池)"
            echo "  -s, --sub-url <URL>    指定 Sing-box 订阅链接 (SINGBOX_SUBSCRIPTION_URL)"
            echo "  -o, --ovpn-url <URL>   指定 OpenVPN 远程节点获取链接 (OVPN_REMOTE_URL)"
            echo "  -p, --socks-port <PORT>指定外部公开 SOCKS 代理监听端口 (默认 2080)"
            echo "  -c, --country <CODE>   指定 VPNGate 目标国家代码 (如 JP, US, KR，留空不过滤)"
            echo "  --csv <PATH/URL>       指定初始 VPNGate CSV 源文件或下载链接"
            echo "  -h, --help             显示帮助信息"
            echo ""
            echo "示例:"
            echo "  sudo ./install.sh --upgrade"
            echo "  sudo ./install.sh -s 'https://sub.example.com/api' -p 2080 -c JP"
            echo "  sudo ./install.sh --csv ./ovpn.csv -c 'JP,US'"
            echo "============================================================"
            exit 0
            ;;
        *)
            log_warn "未知参数: $1，将被忽略"
            shift
            ;;
    esac
done

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    log_error "请使用 sudo 或 root 权限执行此脚本: sudo ./install.sh"
    exit 1
fi

# 自动检测是否为平滑升级模式
IS_UPGRADE=false
if [ "${FORCE_CLEAN}" = true ]; then
    IS_UPGRADE=false
elif [ "${FORCE_UPGRADE}" = true ]; then
    IS_UPGRADE=true
elif [ -d "${CONFIG_DIR}" ] || [ -d "${INSTALL_DIR}" ] || (command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null); then
    IS_UPGRADE=true
fi

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  VPNGate Sing-box & OpenVPN 隧道服务 安装与升级程序        ${NC}"
echo -e "${BLUE}  安装目录: ${INSTALL_DIR}                                  ${NC}"
echo -e "${BLUE}  配置目录: ${CONFIG_DIR}                                  ${NC}"
echo -e "${BLUE}  服务名称: ${SERVICE_NAME}                                 ${NC}"
if [ "${IS_UPGRADE}" = true ]; then
    echo -e "  运行模式: ${GREEN}🔄 平滑升级模式 (保留现有配置与节点池，预构建镜像零停机重启)${NC}"
else
    echo -e "  运行模式: ${YELLOW}✨ 全新安装模式${NC}"
fi
echo -e "${BLUE}============================================================${NC}"

# 2. 检查 Docker 与 Python 运行环境
log_info "正在检查运行环境..."
if ! command -v docker >/dev/null 2>&1; then
    log_error "未检测到 Docker，请先安装 Docker！"
    exit 1
fi
log_info "✅ Docker 环境已就绪: $(docker --version)"

if ! command -v python3 >/dev/null 2>&1; then
    log_error "未检测到 Python3，请先安装 python3！"
    exit 1
fi
log_info "✅ Python3 环境已就绪: $(python3 --version)"

# 3. 预构建 Docker 镜像 (服务继续在后台运行，实现零停机平滑更新)
mkdir -p "${PROJECT_DIR}/bin"
log_info "正在预构建最新 Docker 镜像 (${SERVICE_NAME}:latest) ..."
docker build -t "${SERVICE_NAME}:latest" "${PROJECT_DIR}"
log_info "✅ Docker 镜像预构建完成！"

# 4. 安装/更新程序文件与依赖至 /usr/local/bin
log_info "正在部署/更新程序文件至 ${INSTALL_DIR} ..."
mkdir -p "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/scripts"
mkdir -p "${INSTALL_DIR}/config"
mkdir -p "${INSTALL_DIR}/bin"
mkdir -p "${BIN_DIR}"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${CONFIG_DIR}/ovpn_nodes"

# 复制核心项目文件
cp -f "${PROJECT_DIR}/Dockerfile" "${INSTALL_DIR}/"
cp -f "${PROJECT_DIR}/entrypoint.sh" "${INSTALL_DIR}/"
cp -f "${PROJECT_DIR}/docker-compose.yml" "${INSTALL_DIR}/" 2>/dev/null || true
cp -f "${PROJECT_DIR}/gen-vless-reality.sh" "${INSTALL_DIR}/" 2>/dev/null || true
cp -f "${PROJECT_DIR}/generate_ovpn.py" "${INSTALL_DIR}/" 2>/dev/null || true
cp -f "${PROJECT_DIR}/README.md" "${INSTALL_DIR}/" 2>/dev/null || true
cp -f "${PROJECT_DIR}/install.sh" "${INSTALL_DIR}/" 2>/dev/null || true

# 复制 scripts 目录
cp -f "${PROJECT_DIR}/scripts/"* "${INSTALL_DIR}/scripts/" 2>/dev/null || true

# 复制 bin 目录（如果存在 sing-box 离线包）
if [ -d "${PROJECT_DIR}/bin" ]; then
    cp -rf "${PROJECT_DIR}/bin/"* "${INSTALL_DIR}/bin/" 2>/dev/null || true
fi

# 复制配置模板与默认订阅配置
cp -f "${PROJECT_DIR}/config/"*.example "${INSTALL_DIR}/config/" 2>/dev/null || true
cp -f "${PROJECT_DIR}/config/"*.example "${CONFIG_DIR}/" 2>/dev/null || true
if [ -f "${PROJECT_DIR}/config/singbox_subscription.raw.json" ]; then
    cp -f "${PROJECT_DIR}/config/singbox_subscription.raw.json" "${INSTALL_DIR}/config/" 2>/dev/null || true
    if [ ! -f "${CONFIG_DIR}/singbox_subscription.raw.json" ]; then
        log_info "初始化安装默认 Sing-box 订阅配置 ${CONFIG_DIR}/singbox_subscription.raw.json ..."
        cp -f "${PROJECT_DIR}/config/singbox_subscription.raw.json" "${CONFIG_DIR}/singbox_subscription.raw.json"
    fi
fi

# 辅助函数：更新或追加配置键值
update_config_key() {
    local key="$1"
    local value="$2"
    local file="$3"

    if grep -qE "^[# ]*${key}=" "${file}"; then
        local escaped_val
        escaped_val=$(printf "%s\n" "${value}" | sed -e "s/[\/&]/\\&/g")
        sed -i -E "s|^[# ]*${key}=.*|${key}=\"${escaped_val}\"|" "${file}"
    else
        echo "${key}=\"${value}\"" >> "${file}"
    fi
}

# 辅助函数：增量合并新版新增配置项（保留用户原有全部修改）
merge_config_env() {
    local target_file="$1"
    local example_file="$2"
    [ -f "${target_file}" ] || return 0
    [ -f "${example_file}" ] || return 0

    local added_keys=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^[#[:space:]]*([A-Z0-9_]+)= ]]; then
            local key="${BASH_REMATCH[1]}"
            if ! grep -qE "^[#[:space:]]*${key}=" "${target_file}"; then
                if [ $added_keys -eq 0 ]; then
                    echo "" >> "${target_file}"
                    echo "# --- [版本升级自动追加的新增配置项] ---" >> "${target_file}"
                fi
                echo "${line}" >> "${target_file}"
                added_keys=$((added_keys + 1))
            fi
        fi
    done < "${example_file}"

    if [ $added_keys -gt 0 ]; then
        log_info "📝 从配置模板向现有 config.env 增量合并了 ${added_keys} 个新配置项"
    fi
}

# 5. 初始化或增量合并 /etc/vpngate-singbox-openvpn/config.env 配置文件
if [ ! -f "${CONFIG_DIR}/config.env" ]; then
    if [ -f "${PROJECT_DIR}/config/config.env" ]; then
        log_info "迁移现有 config.env 至 ${CONFIG_DIR}/config.env ..."
        cp -f "${PROJECT_DIR}/config/config.env" "${CONFIG_DIR}/config.env"
    else
        log_info "初始化创建默认配置文件 ${CONFIG_DIR}/config.env ..."
        cp -f "${CONFIG_DIR}/config.env.example" "${CONFIG_DIR}/config.env"
    fi
else
    log_info "保留现有配置文件: ${CONFIG_DIR}/config.env"
    merge_config_env "${CONFIG_DIR}/config.env" "${CONFIG_DIR}/config.env.example"
fi

# 持久化显式传入的命令行配置项
if [ -n "${INPUT_SUB_URL}" ]; then
    log_info "📝 正在持久化写入 Sing-box 订阅链接 (SINGBOX_SUBSCRIPTION_URL)..."
    update_config_key "SINGBOX_SUBSCRIPTION_URL" "${INPUT_SUB_URL}" "${CONFIG_DIR}/config.env"
    [ -f "${PROJECT_DIR}/config/config.env" ] && update_config_key "SINGBOX_SUBSCRIPTION_URL" "${INPUT_SUB_URL}" "${PROJECT_DIR}/config/config.env" || true
fi

if [ -n "${INPUT_OVPN_URL}" ]; then
    log_info "📝 正在持久化写入 OpenVPN 远程配置下载链接 (OVPN_REMOTE_URL)..."
    update_config_key "OVPN_REMOTE_URL" "${INPUT_OVPN_URL}" "${CONFIG_DIR}/config.env"
    [ -f "${PROJECT_DIR}/config/config.env" ] && update_config_key "OVPN_REMOTE_URL" "${INPUT_OVPN_URL}" "${PROJECT_DIR}/config/config.env" || true
fi

if [ -n "${INPUT_PUBLIC_PORT}" ]; then
    log_info "📝 正在持久化写入外部 SOCKS 代理端口 (PUBLIC_SOCKS_PORT=${INPUT_PUBLIC_PORT})..."
    update_config_key "PUBLIC_SOCKS_PORT" "${INPUT_PUBLIC_PORT}" "${CONFIG_DIR}/config.env"
    [ -f "${PROJECT_DIR}/config/config.env" ] && update_config_key "PUBLIC_SOCKS_PORT" "${INPUT_PUBLIC_PORT}" "${PROJECT_DIR}/config/config.env" || true
else
    if ! grep -qE "^[# ]*PUBLIC_SOCKS_PORT=" "${CONFIG_DIR}/config.env"; then
        update_config_key "PUBLIC_SOCKS_PORT" "2080" "${CONFIG_DIR}/config.env"
    fi
fi

if [ -n "${INPUT_COUNTRY}" ]; then
    log_info "📝 正在持久化写入目标国家代码过滤 (VPNGATE_COUNTRY=${INPUT_COUNTRY})..."
    update_config_key "VPNGATE_COUNTRY" "${INPUT_COUNTRY}" "${CONFIG_DIR}/config.env"
    [ -f "${PROJECT_DIR}/config/config.env" ] && update_config_key "VPNGATE_COUNTRY" "${INPUT_COUNTRY}" "${PROJECT_DIR}/config/config.env" || true
fi

if [ ! -f "${CONFIG_DIR}/auth.txt" ] && [ -f "${CONFIG_DIR}/auth.txt.example" ]; then
    cp -f "${CONFIG_DIR}/auth.txt.example" "${CONFIG_DIR}/auth.txt"
fi

# 在安装目录下创建 config 软链接指向 /etc 统一配置目录
rm -rf "${INSTALL_DIR}/config"
ln -sf "${CONFIG_DIR}" "${INSTALL_DIR}/config"

# 设置可执行权限
chmod +x "${INSTALL_DIR}/entrypoint.sh" 2>/dev/null || true
chmod +x "${INSTALL_DIR}/gen-vless-reality.sh" 2>/dev/null || true
chmod +x "${INSTALL_DIR}/generate_ovpn.py" 2>/dev/null || true
chmod +x "${INSTALL_DIR}/install.sh" 2>/dev/null || true
chmod +x "${INSTALL_DIR}/scripts/"*.sh 2>/dev/null || true
chmod +x "${INSTALL_DIR}/scripts/"*.py 2>/dev/null || true

# 6. 创建全局快捷指令到 /usr/local/bin
log_info "正在创建全局快捷管理命令软链接至 ${BIN_DIR} ..."
rm -f "${BIN_DIR}/vpngate-tunnel" "${BIN_DIR}/vpngate-singbox" "${BIN_DIR}/vpngate-reality" "${BIN_DIR}/vpngate-generate-ovpn" "${BIN_DIR}/generate-ovpn" "${BIN_DIR}/vpngate-node-updater"

ln -sf "${INSTALL_DIR}/scripts/service.sh" "${BIN_DIR}/vpngate-tunnel"
ln -sf "${INSTALL_DIR}/scripts/service.sh" "${BIN_DIR}/vpngate-singbox"
ln -sf "${INSTALL_DIR}/gen-vless-reality.sh" "${BIN_DIR}/vpngate-reality"
ln -sf "${INSTALL_DIR}/generate_ovpn.py" "${BIN_DIR}/vpngate-generate-ovpn"
ln -sf "${INSTALL_DIR}/generate_ovpn.py" "${BIN_DIR}/generate-ovpn"
ln -sf "${INSTALL_DIR}/scripts/node_updater.py" "${BIN_DIR}/vpngate-node-updater"

chmod +x "${BIN_DIR}/vpngate-tunnel" "${BIN_DIR}/vpngate-singbox" "${BIN_DIR}/vpngate-reality" "${BIN_DIR}/vpngate-generate-ovpn" "${BIN_DIR}/generate-ovpn" "${BIN_DIR}/vpngate-node-updater" 2>/dev/null || true
ln -sf "${INSTALL_DIR}/scripts/service.sh" "${INSTALL_DIR}/service.sh" || true

# 7. 基于 VPNGate 批量生成初始 .ovpn 节点池与 nodes_mapping.json (升级模式保留现有节点)
HAS_VALID_NODES=false
if [ "${IS_UPGRADE}" = true ] && [ "${FORCE_CLEAN}" != true ] && [ -z "${INPUT_CSV_SOURCE}" ]; then
    if [ -s "${CONFIG_DIR}/nodes_mapping.json" ] && [ -f "${CONFIG_DIR}/client.ovpn" ]; then
        HAS_VALID_NODES=true
    fi
fi

if [ "${HAS_VALID_NODES}" = true ]; then
    log_info "✅ [平滑升级] 保留现有节点池与 client.ovpn (无需耗时重新拉取)"
else
    log_info "正在基于 VPNGate 数据源生成节点池与映射关系清单..."
    CSV_ARG=""
    if [ -n "${INPUT_CSV_SOURCE}" ]; then
        CSV_ARG="-s ${INPUT_CSV_SOURCE}"
    elif [ -f "${PROJECT_DIR}/ovpn.csv" ]; then
        CSV_ARG="-s ${PROJECT_DIR}/ovpn.csv"
    elif [ -f "${CONFIG_DIR}/ovpn.csv" ]; then
        CSV_ARG="-s ${CONFIG_DIR}/ovpn.csv"
    fi

    COUNTRY_ARG=""
    TARGET_COUNTRY_INITIAL="${INPUT_COUNTRY}"
    if [ -z "${TARGET_COUNTRY_INITIAL}" ]; then
        TARGET_COUNTRY_INITIAL=$(grep -E "^VPNGATE_COUNTRY=" "${CONFIG_DIR}/config.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    fi
    if [ -n "${TARGET_COUNTRY_INITIAL}" ]; then
        COUNTRY_ARG="-c ${TARGET_COUNTRY_INITIAL}"
        log_info "📍 节点池仅选取指定国家节点: ${TARGET_COUNTRY_INITIAL}"
    fi

    set +e
    python3 "${INSTALL_DIR}/generate_ovpn.py" ${CSV_ARG} ${COUNTRY_ARG} \
        -d "${CONFIG_DIR}/ovpn_nodes" \
        -m "${CONFIG_DIR}/nodes_mapping.json" \
        --limit 100
    GEN_STATUS=$?
    set -e

    if [ ${GEN_STATUS} -eq 0 ] && [ -f "${CONFIG_DIR}/nodes_mapping.json" ]; then
        log_info "✅ VPNGate 节点池与映射关系生成成功 (${CONFIG_DIR}/nodes_mapping.json)"
    else
        log_warn "⚠️ 节点池生成跳过或未完成，容器仍可使用 client.ovpn 或 OVPN_REMOTE_URL。"
    fi
fi

# 读取外部 SOCKS 端口配置 (默认 2080)
PUBLIC_PORT=$(grep -E "^PUBLIC_SOCKS_PORT=" "${CONFIG_DIR}/config.env" 2>/dev/null | cut -d"=" -f2- | tr -d "\"" | tr -d "'" || echo "2080")
[ -z "${PUBLIC_PORT}" ] && PUBLIC_PORT="2080"

# 8. 配置并更新 Systemd 系统自启服务
log_info "正在配置并更新 Systemd 服务文件至 ${SYSTEMD_DIR}/${SERVICE_FILE} 与 ${SYSTEMD_DIR}/${UPDATER_SERVICE_FILE} ..."

# 8.1 主隧道服务 (容器)
cat <<UNIT_EOF > "${SYSTEMD_DIR}/${SERVICE_FILE}"
[Unit]
Description=VPNGate Sing-box & OpenVPN Tunnel Service
Documentation=https://github.com/JayYang1991/vpngate-residential-tools
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target ${UPDATER_SERVICE_NAME}.service

[Service]
Type=simple
TimeoutStartSec=0
Restart=always
RestartSec=10
WorkingDirectory=${INSTALL_DIR}

# 启动前清理残留同名容器
ExecStartPre=-/usr/bin/docker stop ${SERVICE_NAME}
ExecStartPre=-/usr/bin/docker rm ${SERVICE_NAME}

# 启动容器并挂载 /etc 配置目录、tun 虚拟网卡与外部 SOCKS 端口映射
ExecStart=/usr/bin/docker run --name ${SERVICE_NAME} \
    --cap-add=NET_ADMIN \
    --device=/dev/net/tun:/dev/net/tun \
    -v ${CONFIG_DIR}:/config \
    -p ${PUBLIC_PORT}:${PUBLIC_PORT} \
    ${SERVICE_NAME}:latest

# 优雅停止
ExecStop=/usr/bin/docker stop -t 10 ${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
UNIT_EOF

# 8.2 宿主机节点定时刷新与重启常驻守护进程
cat <<UPDATER_EOF > "${SYSTEMD_DIR}/${UPDATER_SERVICE_FILE}"
[Unit]
Description=VPNGate Node Daily Auto-Updater Daemon (Beijing Time 00:00-06:00)
Documentation=https://github.com/JayYang1991/vpngate-residential-tools
After=network-online.target docker.service
Wants=network-online.target
PartOf=${SERVICE_NAME}.service

[Service]
Type=simple
Restart=always
RestartSec=15
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/scripts/node_updater.py --config-dir ${CONFIG_DIR} --container ${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
UPDATER_EOF

chmod 644 "${SYSTEMD_DIR}/${SERVICE_FILE}" 2>/dev/null || true
chmod 644 "${SYSTEMD_DIR}/${UPDATER_SERVICE_FILE}" 2>/dev/null || true

# 9. 重新加载 systemd 并平滑重启服务 (基于预构建镜像，秒级完成切换)
log_info "正在重新加载 systemd 并平滑重启 ${SERVICE_NAME} 与 ${UPDATER_SERVICE_NAME} 服务..."
if command -v systemctl >/dev/null 2>&1 && (systemctl is-system-running >/dev/null 2>&1 || [ -d "/run/systemd/system" ]); then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "${SERVICE_NAME}" 2>/dev/null || true
    systemctl enable "${UPDATER_SERVICE_NAME}" 2>/dev/null || true
    systemctl restart "${SERVICE_NAME}"
    systemctl restart "${UPDATER_SERVICE_NAME}"
else
    docker stop "${SERVICE_NAME}" 2>/dev/null || true
    docker rm "${SERVICE_NAME}" 2>/dev/null || true
    docker run -d --name "${SERVICE_NAME}" \
        --restart unless-stopped \
        --cap-add=NET_ADMIN \
        --device=/dev/net/tun:/dev/net/tun \
        -v "${CONFIG_DIR}":/config \
        -p "${PUBLIC_PORT}:${PUBLIC_PORT}" \
        "${SERVICE_NAME}:latest"
fi

# 读取并展示当前生效的关键配置
CURRENT_SUB=$(grep -E "^SINGBOX_SUBSCRIPTION_URL=" "${CONFIG_DIR}/config.env" 2>/dev/null | cut -d"=" -f2- | tr -d "\"" || echo "未配置")
CURRENT_OVPN=$(grep -E "^OVPN_REMOTE_URL=" "${CONFIG_DIR}/config.env" 2>/dev/null | cut -d"=" -f2- | tr -d "\"" || echo "未配置")
CURRENT_CTRY=$(grep -E "^VPNGATE_COUNTRY=" "${CONFIG_DIR}/config.env" 2>/dev/null | cut -d"=" -f2- | tr -d "\"" || echo "全部国家 (不过滤)")
[ -z "${CURRENT_CTRY}" ] && CURRENT_CTRY="全部国家 (不过滤)"

echo ""
echo -e "${GREEN}============================================================${NC}"
if [ "${IS_UPGRADE}" = true ]; then
    echo -e "${GREEN} ✅ 平滑升级完成！服务已无缝切换至最新版本！${NC}"
else
    echo -e "${GREEN} ✅ 安装与配置完成！服务已成功启动！${NC}"
fi
echo -e "${GREEN}============================================================${NC}"
echo -e " • 核心依赖安装目录: ${BLUE}${INSTALL_DIR}${NC}"
echo -e " • 配置文件存放目录: ${BLUE}${CONFIG_DIR}${NC} (主要配置: ${CONFIG_DIR}/config.env)"
echo -e " • 节点池映射清单:   ${BLUE}${CONFIG_DIR}/nodes_mapping.json${NC}"
echo -e " • 当前 Sing-box 订阅: ${CYAN}${CURRENT_SUB}${NC}"
echo -e " • 当前 OVPN 下载源:   ${CYAN}${CURRENT_OVPN}${NC}"
echo -e " • 当前目标国家代码:   ${CYAN}${CURRENT_CTRY}${NC}"
echo -e " • 外部公开 SOCKS 端口: ${YELLOW}0.0.0.0:${PUBLIC_PORT}${NC} (可供宿主机/外部直接连接代理)"
echo -e " • 宿主机自动刷新守护: ${GREEN}已启用${NC} (每天北京时间 00:00-06:00 随机时间自动刷新并重启容器)"
echo -e " • 全局管理命令:     ${YELLOW}vpngate-tunnel${NC} 或 ${YELLOW}vpngate-generate-ovpn${NC} 或 ${YELLOW}vpngate-node-updater${NC}"
echo ""
echo -e "常用指令示例:"
echo -e "   • ${YELLOW}vpngate-tunnel upgrade${NC}     -> 🔄 平滑升级至最新版本 (零停机预构建与秒级切换)"
echo -e "   • ${YELLOW}vpngate-tunnel status${NC}      -> 📊 查看隧道运行状态、连通性出口 IP 与更新守护状态"
echo -e "   • ${YELLOW}vpngate-tunnel list-nodes${NC}  -> 📋 查看当前映射的 VPNGate 节点池清单"
echo -e "   • ${YELLOW}vpngate-tunnel next-node${NC}   -> ⚡ 立即切换至下一个可用节点"
echo -e "   • ${YELLOW}vpngate-tunnel update-nodes${NC} -> 🔄 手动重新拉取 VPNGate 节点并更新映射清单"
echo -e "   • ${YELLOW}vpngate-node-updater --run-now${NC} -> ⚡ 立即刷新节点并重启容器生效"
echo -e "   • ${YELLOW}vpngate-tunnel logs${NC}        -> 📜 查看实时运行日志"
echo -e "   • ${YELLOW}vpngate-tunnel restart${NC}     -> 🔄 重启隧道服务与自动更新守护"
echo -e "   • ${YELLOW}sudo nano ${CONFIG_DIR}/config.env${NC} -> ⚙️ 编辑配置文件"
echo -e "${GREEN}============================================================${NC}"
