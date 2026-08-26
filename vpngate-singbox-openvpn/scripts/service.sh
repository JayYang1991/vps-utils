#!/usr/bin/env bash
# ==============================================================================
# vpngate-singbox-openvpn 全局管理控制工具
# 用法: vpngate-tunnel {start|stop|restart|status|logs|updater-logs|exec|test|next-node|list-nodes|update-nodes|update-ovpn|upgrade|build}
# ==============================================================================

SERVICE_NAME="vpngate-singbox-openvpn"
UPDATER_SERVICE_NAME="vpngate-singbox-node-updater"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 自动判断配置目录位置 (优先 /etc/vpngate-singbox-openvpn)
if [ -d "/etc/vpngate-singbox-openvpn" ]; then
    CONFIG_DIR="/etc/vpngate-singbox-openvpn"
elif [ -d "${SCRIPT_DIR}/../config" ]; then
    CONFIG_DIR="$(cd "${SCRIPT_DIR}/../config" && pwd)"
elif [ -d "${SCRIPT_DIR}/config" ]; then
    CONFIG_DIR="$(cd "${SCRIPT_DIR}/config" && pwd)"
else
    CONFIG_DIR="/etc/vpngate-singbox-openvpn"
fi

STATUS_FILE="${CONFIG_DIR}/vpn_status.json"
MAPPING_FILE="${CONFIG_DIR}/nodes_mapping.json"
PUBLIC_PORT=$(grep -E "^PUBLIC_SOCKS_PORT=" "${CONFIG_DIR}/config.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "2080")
[ -z "${PUBLIC_PORT}" ] && PUBLIC_PORT="2080"

# 查找 generate_ovpn.py 路径 (优先项目根目录或安装目录)
if [ -f "${SCRIPT_DIR}/../generate_ovpn.py" ]; then
    GENERATE_PY="${SCRIPT_DIR}/../generate_ovpn.py"
elif [ -f "/usr/local/bin/vpngate-singbox-openvpn/generate_ovpn.py" ]; then
    GENERATE_PY="/usr/local/bin/vpngate-singbox-openvpn/generate_ovpn.py"
elif [ -f "./generate_ovpn.py" ]; then
    GENERATE_PY="./generate_ovpn.py"
else
    GENERATE_PY="generate_ovpn.py"
fi

case "$1" in
    start)
        echo "[*] 启动服务 ${SERVICE_NAME} 与自动更新守护 (外部 SOCKS 端口: ${PUBLIC_PORT}) ..."
        if command -v systemctl >/dev/null 2>&1 && [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
            sudo systemctl start "${SERVICE_NAME}"
            [ -f "/etc/systemd/system/${UPDATER_SERVICE_NAME}.service" ] && sudo systemctl start "${UPDATER_SERVICE_NAME}" || true
        else
            docker start "${SERVICE_NAME}" 2>/dev/null || \
            docker run -d --name "${SERVICE_NAME}" \
                --restart unless-stopped \
                --cap-add=NET_ADMIN \
                --device=/dev/net/tun:/dev/net/tun \
                -v "${CONFIG_DIR}":/config \
                -p "${PUBLIC_PORT}:${PUBLIC_PORT}" \
                "${SERVICE_NAME}:latest"
        fi
        echo "[*] 已发送启动指令。"
        ;;

    stop)
        echo "[*] 停止服务 ${SERVICE_NAME} ..."
        if command -v systemctl >/dev/null 2>&1 && [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
            [ -f "/etc/systemd/system/${UPDATER_SERVICE_NAME}.service" ] && sudo systemctl stop "${UPDATER_SERVICE_NAME}" || true
            sudo systemctl stop "${SERVICE_NAME}"
        else
            docker stop "${SERVICE_NAME}"
        fi
        ;;

    restart)
        echo "[*] 重启服务 ${SERVICE_NAME} 与自动更新守护 ..."
        if command -v systemctl >/dev/null 2>&1 && [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
            sudo systemctl restart "${SERVICE_NAME}"
            [ -f "/etc/systemd/system/${UPDATER_SERVICE_NAME}.service" ] && sudo systemctl restart "${UPDATER_SERVICE_NAME}" || true
        else
            docker restart "${SERVICE_NAME}"
        fi
        ;;

    status)
        echo "==================== [服务运行状态] ===================="
        if command -v systemctl >/dev/null 2>&1 && [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
            systemctl status "${SERVICE_NAME}" --no-pager
            if [ -f "/etc/systemd/system/${UPDATER_SERVICE_NAME}.service" ]; then
                echo ""
                echo "================ [宿主机自动更新守护状态] ================"
                systemctl status "${UPDATER_SERVICE_NAME}" --no-pager || true
            fi
        else
            docker ps -a --filter "name=${SERVICE_NAME}"
        fi

        echo ""
        echo "==================== [VPN 连通性状态] ===================="
        if [ -f "${STATUS_FILE}" ]; then
            cat "${STATUS_FILE}" | jq . 2>/dev/null || cat "${STATUS_FILE}"
        else
            echo "未找到状态文件 ${STATUS_FILE} (可能容器尚未运行完成初始化)"
        fi
        echo ""
        ;;

    logs)
        docker logs -f --tail 100 "${SERVICE_NAME}"
        ;;

    updater-logs|daemon-logs)
        if command -v journalctl >/dev/null 2>&1 && [ -f "/etc/systemd/system/${UPDATER_SERVICE_NAME}.service" ]; then
            journalctl -u "${UPDATER_SERVICE_NAME}" -f --tail 100
        else
            echo "未找到 systemd 服务日志: ${UPDATER_SERVICE_NAME}"
        fi
        ;;

    exec)
        docker exec -it "${SERVICE_NAME}" /bin/bash
        ;;

    test)
        echo "[*] 在容器内测试 tun0 接口网络出口 IP..."
        docker exec -it "${SERVICE_NAME}" curl --interface tun0 -s https://api.ipify.org || echo "tun0 网络测试失败"
        echo ""
        ;;

    next-node|switch-node)
        echo "[*] 正在触发容器切换至下一个可用节点..."
        if docker ps --format '{{.Names}}' | grep -Eq "^${SERVICE_NAME}\$"; then
            docker exec "${SERVICE_NAME}" touch /config/.switch_node 2>/dev/null || touch "${CONFIG_DIR}/.switch_node"
            echo "[*] 切换信号已发送，等待节点切换生效..."
            sleep 3
            if [ -f "${STATUS_FILE}" ]; then
                cat "${STATUS_FILE}" | jq .active_node 2>/dev/null || true
            fi
        else
            echo "[!] 容器 ${SERVICE_NAME} 未在运行中！"
        fi
        ;;

    list-nodes|nodes)
        echo "==================== [VPNGate 节点池清单] ===================="
        if [ -f "${MAPPING_FILE}" ]; then
            python3 -c "
import json
with open('${MAPPING_FILE}') as f:
    d = json.load(f)
nodes = d.get('nodes', [])
print(f'总节点数: {len(nodes)} | 更新时间: {d.get(\"updated_at\", \"N/A\")}\n')
print(f'{\"序号\":<5} {\"国家\":<12} {\"IP:端口\":<24} {\"带宽(Mbps)\":<12} {\"威胁分\":<8} {\"Ping\":<8} {\"节点标识\"}')
print('-' * 90)
for idx, n in enumerate(nodes[:25]):
    ip_port = f\"{n.get('ip')}:{n.get('port')}\"
    threat = n.get('threat_score', n.get('fraud_score', 'N/A'))
    print(f'{idx+1:<5} {n.get(\"country\", \"Unknown\")[:10]:<12} {ip_port:<24} {n.get(\"speed_mbps\", 0):<12} {str(threat):<8} {n.get(\"ping\", 0):<8} {n.get(\"id\")}')
if len(nodes) > 25:
    print(f'... 其余 {len(nodes) - 25} 个节点已省略 (查看完整文件: ${MAPPING_FILE})')
"
        else
            echo "未找到节点映射清单: ${MAPPING_FILE}"
            echo "请运行: vpngate-tunnel update-nodes 生成节点池"
        fi
        echo ""
        ;;

    update-nodes|generate-ovpn)
        echo "[*] 基于 VPNGate 节点数据生成 .ovpn 文件及映射清单..."
        shift
        EXTRA_ARGS=("$@")
        HAS_COUNTRY=false
        for arg in "$@"; do
            if [[ "$arg" == "-c" || "$arg" == "--country" || "$arg" == "--country-code" || "$arg" == *"--country="* ]]; then
                HAS_COUNTRY=true
                break
            fi
        done
        if [ "$HAS_COUNTRY" = false ]; then
            VPNGATE_COUNTRY=$(grep -E "^VPNGATE_COUNTRY=" "${CONFIG_DIR}/config.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
            if [ -n "${VPNGATE_COUNTRY}" ]; then
                EXTRA_ARGS+=("-c" "${VPNGATE_COUNTRY}")
            fi
        fi
        python3 "${GENERATE_PY}" -d "${CONFIG_DIR}/ovpn_nodes" -m "${MAPPING_FILE}" "${EXTRA_ARGS[@]}"
        ;;

    update-ovpn)
        echo "[*] 触发手动获取远程 .ovpn 配置并重载..."
        docker exec -it "${SERVICE_NAME}" python3 -c "import sys; sys.path.insert(0, '/app/scripts'); from health_checker import ServiceManager; sm = ServiceManager(); sm.fetch_remote_ovpn(); sm.restart_openvpn()"
        ;;

    build)
        echo "[*] 重新构建 Docker 镜像..."
        PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
        [ -f "${PROJECT_DIR}/Dockerfile" ] && docker build -t "${SERVICE_NAME}:latest" "${PROJECT_DIR}"
        ;;

    upgrade)
        echo "==================== [平滑升级服务] ===================="
        INSTALL_SCRIPT=""
        if [ -f "${SCRIPT_DIR}/../install.sh" ]; then
            INSTALL_SCRIPT="${SCRIPT_DIR}/../install.sh"
        elif [ -f "/usr/local/bin/vpngate-singbox-openvpn/install.sh" ]; then
            INSTALL_SCRIPT="/usr/local/bin/vpngate-singbox-openvpn/install.sh"
        elif [ -f "./install.sh" ]; then
            INSTALL_SCRIPT="./install.sh"
        fi

        shift
        if [ -n "${INSTALL_SCRIPT}" ] && [ -f "${INSTALL_SCRIPT}" ]; then
            echo "[*] 正在调用安装与升级程序执行平滑升级..."
            if [ "$EUID" -ne 0 ]; then
                sudo bash "${INSTALL_SCRIPT}" --upgrade "$@"
            else
                bash "${INSTALL_SCRIPT}" --upgrade "$@"
            fi
        else
            echo "[*] 正在执行内置平滑升级流程..."
            PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
            if [ -f "${PROJECT_DIR}/Dockerfile" ]; then
                docker build -t "${SERVICE_NAME}:latest" "${PROJECT_DIR}"
            fi
            if command -v systemctl >/dev/null 2>&1 && [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
                sudo systemctl daemon-reload
                sudo systemctl restart "${SERVICE_NAME}"
                [ -f "/etc/systemd/system/${UPDATER_SERVICE_NAME}.service" ] && sudo systemctl restart "${UPDATER_SERVICE_NAME}" || true
            else
                docker restart "${SERVICE_NAME}"
            fi
            echo "✅ 平滑升级完成！"
        fi
        ;;

    *)
        echo "使用方法: vpngate-tunnel {start|stop|restart|status|logs|updater-logs|exec|test|next-node|list-nodes|update-nodes|update-ovpn|upgrade|build}"
        exit 1
        ;;
esac
