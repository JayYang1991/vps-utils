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
import socket
import shutil
import logging
import argparse
import threading
import subprocess
import tempfile
from typing import Optional, Tuple

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


def find_openvpn_binary() -> Optional[str]:
    """Finds openvpn binary across standard PATH and system sbin directories."""
    found = shutil.which("openvpn")
    if found:
        return found

    common_paths = [
        "/usr/sbin/openvpn",
        "/usr/bin/openvpn",
        "/usr/local/sbin/openvpn",
        "/usr/local/bin/openvpn",
        "/sbin/openvpn",
        "/bin/openvpn",
    ]
    for p in common_paths:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def try_auto_install_openvpn() -> Optional[str]:
    """Attempts to auto-install openvpn if running as root."""
    if os.geteuid() != 0:
        return None

    logging.info("🔧 正在尝试通过系统包管理器自动安装 OpenVPN...")
    try:
        if shutil.which("apt-get"):
            subprocess.run(["apt-get", "update", "-y"], check=False)
            subprocess.run(["apt-get", "install", "-y", "openvpn"], check=False)
        elif shutil.which("dnf"):
            subprocess.run(["dnf", "install", "-y", "openvpn"], check=False)
        elif shutil.which("yum"):
            subprocess.run(["yum", "install", "-y", "openvpn"], check=False)
        elif shutil.which("apk"):
            subprocess.run(["apk", "add", "openvpn"], check=False)
        elif shutil.which("pacman"):
            subprocess.run(["pacman", "-Sy", "--noconfirm", "openvpn"], check=False)
    except Exception as e:
        logging.warning(f"⚠️ 自动安装 OpenVPN 失败: {e}")

    return find_openvpn_binary()


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


def forward_stream(src: socket.socket, dst: socket.socket):
    """Forwards data bidirectionally between two sockets."""
    try:
        while RUNNING:
            data = src.recv(8192)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        try:
            src.close()
        except Exception:
            pass
        try:
            dst.close()
        except Exception:
            pass


def handle_socks5_client(client_sock: socket.socket):
    """Handles an incoming SOCKS5 client connection."""
    try:
        client_sock.settimeout(10.0)
        # SOCKS5 Greeting: [VER, NMETHODS, METHODS...]
        greeting = client_sock.recv(260)
        if not greeting or greeting[0] != 0x05:
            client_sock.close()
            return

        # Respond with NO AUTH REQUIRED (0x05, 0x00)
        client_sock.sendall(b"\x05\x00")

        # Read Request: [VER, CMD, RSV, ATYP, DST.ADDR, DST.PORT]
        req = client_sock.recv(260)
        if len(req) < 7 or req[0] != 0x05 or req[1] != 0x01:  # 0x01 = CONNECT
            # Command not supported
            client_sock.sendall(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00")
            client_sock.close()
            return

        atyp = req[3]
        if atyp == 0x01:  # IPv4
            dest_host = socket.inet_ntoa(req[4:8])
            dest_port = int.from_bytes(req[8:10], "big")
        elif atyp == 0x03:  # Domain
            domain_len = req[4]
            dest_host = req[5:5 + domain_len].decode("utf-8", errors="ignore")
            dest_port = int.from_bytes(req[5 + domain_len:7 + domain_len], "big")
        elif atyp == 0x04:  # IPv6
            dest_host = socket.inet_ntop(socket.AF_INET6, req[4:20])
            dest_port = int.from_bytes(req[20:22], "big")
        else:
            client_sock.close()
            return

        # Connect to destination
        remote_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        remote_sock.settimeout(10.0)
        remote_sock.connect((dest_host, dest_port))
        remote_sock.settimeout(None)
        client_sock.settimeout(None)

        # Send SOCKS5 Success response: 0x05, 0x00 (SUCCESS), 0x00, 0x01 (IPv4), 0.0.0.0:0
        client_sock.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")

        # Bidirectional forwarder
        t1 = threading.Thread(target=forward_stream, args=(client_sock, remote_sock), daemon=True)
        t2 = threading.Thread(target=forward_stream, args=(remote_sock, client_sock), daemon=True)
        t1.start()
        t2.start()
    except Exception as e:
        try:
            client_sock.close()
        except Exception:
            pass


def start_socks5_server(port: int = 10808, host: str = "0.0.0.0"):
    """Starts local SOCKS5 proxy server listening thread."""
    server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server_sock.bind((host, port))
        server_sock.listen(128)
        logging.info(f"🟢 SOCKS5 代理网关监听已就绪: socks5://127.0.0.1:{port} (全网卡 0.0.0.0:{port})")
    except Exception as e:
        logging.error(f"❌ 绑定 SOCKS5 端口 {port} 失败: {e}")
        return

    while RUNNING:
        try:
            server_sock.settimeout(1.0)
            client, addr = server_sock.accept()
            t = threading.Thread(target=handle_socks5_client, args=(client,), daemon=True)
            t.start()
        except socket.timeout:
            continue
        except Exception:
            break

    try:
        server_sock.close()
    except Exception:
        pass


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

    logging.info("=" * 75)
    logging.info(f"🌉 VPNGATE 本地代理中继网桥正在启动")
    logging.info(f"   • 选定住宅节点: [{country_code}] {ip}:{port} (实测握手延迟: {latency} ms)")
    logging.info(f"   • 本地 SOCKS5 代理网关: socks5://127.0.0.1:{socks_port}")
    logging.info(f"   • 本地 HTTP 代理网关:   http://127.0.0.1:{http_port}")
    logging.info("=" * 75)

    if not ovpn_b64:
        logging.error("❌ 该节点缺少 OpenVPN base64 配置数据。")
        return 1

    # Locate OpenVPN binary
    openvpn_bin = find_openvpn_binary()
    if not openvpn_bin:
        openvpn_bin = try_auto_install_openvpn()

    if not openvpn_bin:
        logging.error("❌ 系统中未找到 openvpn 二进制程序。")
        logging.info("👉 请运行以下命令安装 OpenVPN:")
        logging.info("   • Debian / Ubuntu:  sudo apt-get update && sudo apt-get install -y openvpn")
        logging.info("   • RHEL / CentOS:    sudo dnf install -y epel-release && sudo dnf install -y openvpn")
        logging.info("   • Alpine:           sudo apk add openvpn")
        return 1

    logging.info(f"✅ 找到 OpenVPN 程序路径: {openvpn_bin}")

    ovpn_content = base64.b64decode(ovpn_b64).decode("utf-8", errors="ignore")

    with tempfile.NamedTemporaryFile("w", suffix=".ovpn", delete=False) as ovpn_file:
        ovpn_file.write(ovpn_content)
        ovpn_path = ovpn_file.name

    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as auth_file:
        auth_file.write("vpn\nvpn\n")
        auth_path = auth_file.name

    # Start local SOCKS5 server thread
    socks_thread = threading.Thread(target=start_socks5_server, args=(socks_port,), daemon=True)
    socks_thread.start()

    try:
        logging.info(f"🚀 正在建立到 [{country_code}] {ip}:{port} 的 OpenVPN 加密隧道连接...")
        cmd = [
            openvpn_bin,
            "--config", ovpn_path,
            "--auth-user-pass", auth_path,
            "--redirect-gateway", "def1",
            "--verb", "3"
        ]
        logging.info(f"执行命令: {' '.join(cmd)}")
        logging.info("💡 隧道建立后，即可通过 socks5://127.0.0.1:10808 享受真实住宅宽带出海！")
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
