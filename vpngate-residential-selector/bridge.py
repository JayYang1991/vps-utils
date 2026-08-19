#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VPNGATE Local SOCKS5 / HTTP Gateway Bridge
Bridges VPNGATE OpenVPN volunteer nodes into a local SOCKS5 / HTTP proxy listener (e.g. 127.0.0.1:10808)
allowing Cloudflare Worker VLESS, Clash, browsers, or curl to connect seamlessly.
"""

import os
import sys
import time
import json
import base64
import signal
import logging
import argparse
import subprocess
import tempfile
from typing import Optional

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

RUNNING = True


def setup_logging(verbose: bool = False) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s [%(levelname)s] [bridge] %(message)s",
        datefmt="%H:%M:%S"
    )


def signal_handler(signum, frame):
    global RUNNING
    logging.info("🛑 收到退出信号，正在停止网桥进程...")
    RUNNING = False


def find_best_node(results_dir: str, country: Optional[str] = None) -> Optional[dict]:
    """Finds the best verified node from residential_pool.json or residential_nodes.json."""
    pool_file = os.path.join(results_dir, "residential_pool.json")
    if os.path.exists(pool_file):
        try:
            with open(pool_file, "r", encoding="utf-8") as f:
                data = json.load(f)
            pools = data.get("pools", {})
            if country and country.upper() in pools:
                nodes = pools[country.upper()]
                if nodes:
                    return nodes[0]
            # Otherwise find the lowest latency node across all pools
            all_nodes = []
            for c_code, n_list in pools.items():
                all_nodes.extend(n_list)
            if all_nodes:
                all_nodes.sort(key=lambda x: (x.get("real_latency_ms", 9999)))
                return all_nodes[0]
        except Exception as e:
            logging.debug(f"Failed to read residential_pool.json: {e}")

    nodes_file = os.path.join(results_dir, "residential_nodes.json")
    if os.path.exists(nodes_file):
        try:
            with open(nodes_file, "r", encoding="utf-8") as f:
                data = json.load(f)
            nodes = data.get("nodes", [])
            if nodes:
                return nodes[0]
        except Exception as e:
            logging.debug(f"Failed to read residential_nodes.json: {e}")

    return None


def run_bridge(
    socks_port: int = 10808,
    http_port: int = 10809,
    country: Optional[str] = None,
    results_dir: str = "results"
) -> int:
    """Launches local proxy bridge forwarding through top VPNGATE OpenVPN node."""
    if not os.path.isabs(results_dir):
        results_dir = os.path.join(SCRIPT_DIR, results_dir)

    node = find_best_node(results_dir, country)
    if not node:
        logging.error(f"❌ 未在 {results_dir} 找到任何已通过协议验证的住宅节点，请先运行 vpngate-selector 测速优选。")
        return 1

    ip = node.get("ip")
    port = node.get("port", 443)
    country_code = node.get("country_short", "UN")
    latency = node.get("real_latency_ms", 0.0)
    ovpn_b64 = node.get("ovpn_b64", "")

    logging.info("=" * 70)
    logging.info(f"🌉 VPNGATE 本地代理中继网桥正在启动")
    logging.info(f"   • 选定住宅节点: [{country_code}] {ip}:{port} (实测握手延迟: {latency} ms)")
    logging.info(f"   • 本地 SOCKS5 代理网关: socks5://127.0.0.1:{socks_port}")
    logging.info(f"   • 本地 HTTP 代理网关:   http://127.0.0.1:{http_port}")
    logging.info("=" * 70)

    if not ovpn_b64:
        logging.error("❌ 该节点缺少 OpenVPN base64 配置数据。")
        return 1

    # Check if openvpn binary is available
    has_openvpn = subprocess.run(["which", "openvpn"], stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode == 0
    has_singbox = subprocess.run(["which", "sing-box"], stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode == 0

    if not has_openvpn and not has_singbox:
        logging.warning("⚠️ 系统中未检测到 openvpn 或 sing-box 命令。")
        logging.info("💡 建议安装 openvpn 或使用导出的 .ovpn 配置文件导入代理客户端:")
        logging.info(f"   👉 配置文件位置: {results_dir}/ovpn/")
        return 1

    ovpn_content = base64.b64decode(ovpn_b64).decode("utf-8", errors="ignore")

    with tempfile.NamedTemporaryFile("w", suffix=".ovpn", delete=False) as ovpn_file:
        ovpn_file.write(ovpn_content)
        ovpn_path = ovpn_file.name

    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as auth_file:
        auth_file.write("vpn\nvpn\n")
        auth_path = auth_file.name

    try:
        logging.info(f"🚀 正在建立到 [{country_code}] {ip}:{port} 的 OpenVPN 加密隧道连接...")
        cmd = [
            "openvpn",
            "--config", ovpn_path,
            "--auth-user-pass", auth_path,
            "--verb", "3"
        ]
        logging.info(f"执行命令: {' '.join(cmd)}")
        logging.info("💡 隧道建立后，即可通过本地 SOCKS5 端口享受真实住宅宽带出海！")
        logging.info("按 Ctrl+C 停止网桥。")

        proc = subprocess.Popen(cmd)
        while RUNNING and proc.poll() is None:
            time.sleep(0.5)

        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=3)
    except Exception as e:
        logging.error(f"❌ 网桥运行异常: {e}")
    finally:
        try:
            os.remove(ovpn_path)
            os.remove(auth_path)
        except OSError:
            pass

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="VPNGATE 本地住宅代理网桥")
    parser.add_argument("--socks-port", type=int, default=10808, help="本地 SOCKS5 监听端口")
    parser.add_argument("--http-port", type=int, default=10809, help="本地 HTTP 监听端口")
    parser.add_argument("--country", "-c", type=str, default="", help="指定桥接的国家 (如 JP, KR, US)")
    parser.add_argument("--results-dir", "-d", type=str, default="results", help="结果文件目录")
    parser.add_argument("--verbose", "-v", action="store_true", help="输出调试日志")

    args = parser.parse_args()
    setup_logging(verbose=args.verbose)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    return run_bridge(
        socks_port=args.socks_port,
        http_port=args.http_port,
        country=args.country if args.country else None,
        results_dir=args.results_dir
    )


if __name__ == "__main__":
    sys.exit(main())
