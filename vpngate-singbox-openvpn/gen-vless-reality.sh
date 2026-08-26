#!/usr/bin/env bash
# ==============================================================================
# Sing-box VLESS + REALITY 配置文件手动生成脚本
# ==============================================================================
# 用法:
#   ./gen-vless-reality.sh [选项]
#
# 常用示例:
#   1. 默认生成 (监听 0.0.0.0, 端口 443/8443/2053/2083/2087/2096, 出站 127.0.0.1:2080):
#      ./gen-vless-reality.sh
#
#   2. 指定自定义 UUID 与出站 SOCKS 端口:
#      ./gen-vless-reality.sh -u "11111111-2222-3333-4444-555555555555" -s 2080
#
#   3. 指定入站监听 IP 与自定义端口列表:
#      ./gen-vless-reality.sh -l "0.0.0.0" -p "443,8443,2053"
#
#   4. 自定义伪装域名 SNI 与配置文件输出路径:
#      ./gen-vless-reality.sh --sni "itunes.apple.com" -o "/etc/vpngate-singbox-openvpn/reality.json"
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN_PY="${SCRIPT_DIR}/scripts/generate_reality_config.py"
PYTHON_BIN="$(command -v python3 || echo "python3")"

# 检查 sing-box 程序（若宿主机 PATH 没有则从自带 bin/ 解压到 ~/.local/bin/）
if ! command -v sing-box >/dev/null 2>&1; then
    for p in /usr/local/bin/sing-box /usr/bin/sing-box "${HOME}/.local/bin/sing-box"; do
        if [ -x "${p}" ]; then
            export PATH="$(dirname "${p}"):${PATH}"
            break
        fi
    done
fi

if ! command -v sing-box >/dev/null 2>&1; then
    tar_pkg=$(find "${SCRIPT_DIR}/bin" -name "sing-box-*.tar.gz" | head -n 1)
    if [ -n "${tar_pkg}" ] && [ -f "${tar_pkg}" ]; then
        tmp_dir="/tmp/sing-box-extract-$$"
        mkdir -p "${tmp_dir}"
        tar -xzf "${tar_pkg}" -C "${tmp_dir}"
        extracted=$(find "${tmp_dir}" -name "sing-box" -type f | head -n 1)
        if [ -n "${extracted}" ] && [ -f "${extracted}" ]; then
            mkdir -p "${HOME}/.local/bin"
            cp -f "${extracted}" "${HOME}/.local/bin/sing-box"
            chmod +x "${HOME}/.local/bin/sing-box"
            export PATH="${HOME}/.local/bin:${PATH}"
        fi
        rm -rf "${tmp_dir}"
    fi
fi

# 执行 Python 生成器并传递所有入参
exec "${PYTHON_BIN}" "${GEN_PY}" "$@"
