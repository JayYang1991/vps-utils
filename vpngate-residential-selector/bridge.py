#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VPNGATE Local SOCKS5 & HTTP Gateway Bridge
Bridges VPNGATE OpenVPN volunteer nodes into local SOCKS5 (10808) & HTTP (10809) proxy listeners
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


def resolve_bridge_node(
    results_dir: str,
    country: Optional[str] = None,
    target_node: Optional[str] = None,
    rank: int = 1,
    ovpn_file: Optional[str] = None
) -> Optional[dict]:
    """
    Resolves the target OpenVPN node for bridging:
    1. If ovpn_file is provided, loads and builds a custom node dict.
    2. If target_node (IP or IP:Port) is provided, finds that specific node.
    3. Otherwise, picks the optimal node (optionally filtered by country and rank).
    """
    # 1. Custom OVPN file
    if ovpn_file and os.path.exists(ovpn_file):
        try:
            with open(ovpn_file, "r", encoding="utf-8") as f:
                content = f.read()
            b64_str = base64.b64encode(content.encode("utf-8")).decode("ascii")
            return {
                "ip": "Custom-OVPN",
                "port": 443,
                "country_short": "CUSTOM",
                "real_latency_ms": 0.0,
                "fraud_score": 0,
                "ovpn_b64": b64_str
            }
        except Exception as e:
            logging.error(f"读取指定 OVPN 文件失败: {e}")
            return None

    # Search in multiple potential result directories
    search_dirs = [
        results_dir,
        os.path.join(SCRIPT_DIR, results_dir),
        "/usr/local/bin/vpngate-residential-selector/results",
        os.path.expanduser("~/.local/bin/vpngate-residential-selector/results")
    ]

    all_candidate_nodes: List[dict] = []

    for r_dir in search_dirs:
        if not os.path.exists(r_dir):
            continue

        pool_file = os.path.join(r_dir, "residential_pool.json")
        if os.path.exists(pool_file):
            try:
                with open(pool_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                pools = data.get("pools", {})
                for c_code, n_list in pools.items():
                    all_candidate_nodes.extend(n_list)
            except Exception:
                pass

        nodes_file = os.path.join(r_dir, "residential_nodes.json")
        if os.path.exists(nodes_file):
            try:
                with open(nodes_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                nodes = data.get("nodes", [])
                all_candidate_nodes.extend(nodes)
            except Exception:
                pass

    if not all_candidate_nodes:
        return None

    # Deduplicate by IP:port and keep valid ovpn_b64
    seen = set()
    unique_candidates = []
    for n in all_candidate_nodes:
        key = f"{n.get('ip')}:{n.get('port')}"
        if key not in seen and n.get("ovpn_b64"):
            seen.add(key)
            unique_candidates.append(n)

    # 2. Specific node query (e.g. "221.71.170.232", "221.71.170.232:1379", or "JP")
    if target_node:
        target_clean = target_node.strip()
        for n in unique_candidates:
            ip = str(n.get("ip", ""))
            port = str(n.get("port", ""))
            if target_clean == f"{ip}:{port}" or target_clean == ip:
                return n
        # If not matched as IP and target_clean is 2 letters, treat as country
        if len(target_clean) == 2 and not country:
            country = target_clean

    # 3. Country filtering
    if country:
        c_upper = country.strip().upper()
        unique_candidates = [n for n in unique_candidates if n.get("country_short", "").upper() == c_upper]

    if not unique_candidates:
        return None

    # Sort: highest composite score, lowest fraud score, lowest latency
    unique_candidates.sort(key=lambda x: (
        -x.get("composite_score", 0.0),
        x.get("fraud_score", 999) if x.get("fraud_score", -1) >= 0 else 999,
        x.get("real_latency_ms", 9999)
    ))

    idx = max(0, min(rank - 1, len(unique_candidates) - 1))
    return unique_candidates[idx]


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
        greeting = client_sock.recv(260)
        if not greeting or greeting[0] != 0x05:
            client_sock.close()
            return

        client_sock.sendall(b"\x05\x00")

        req = client_sock.recv(260)
        if len(req) < 7 or req[0] != 0x05 or req[1] != 0x01:  # 0x01 = CONNECT
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

        remote_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        remote_sock.settimeout(10.0)
        remote_sock.connect((dest_host, dest_port))
        remote_sock.settimeout(None)
        client_sock.settimeout(None)

        client_sock.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")

        t1 = threading.Thread(target=forward_stream, args=(client_sock, remote_sock), daemon=True)
        t2 = threading.Thread(target=forward_stream, args=(remote_sock, client_sock), daemon=True)
        t1.start()
        t2.start()
    except Exception:
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
        logging.info(f"🟢 SOCKS5 代理网关监听就绪: socks5://127.0.0.1:{port} (全网卡 0.0.0.0:{port})")
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


def handle_http_client(client_sock: socket.socket):
    """Handles an incoming HTTP proxy client connection (CONNECT & standard HTTP forward)."""
    try:
        client_sock.settimeout(10.0)
        req_data = client_sock.recv(4096)
        if not req_data:
            client_sock.close()
            return

        first_line = req_data.split(b"\r\n")[0].decode("utf-8", errors="ignore")
        parts = first_line.split()
        if len(parts) < 2:
            client_sock.close()
            return

        method, target = parts[0].upper(), parts[1]

        if method == "CONNECT":
            # HTTPS Tunneling: target is host:port
            if ":" in target:
                host, port_str = target.split(":", 1)
                port = int(port_str)
            else:
                host, port = target, 443

            remote_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            remote_sock.settimeout(10.0)
            remote_sock.connect((host, port))
            remote_sock.settimeout(None)
            client_sock.settimeout(None)

            # Send 200 Connection Established
            client_sock.sendall(b"HTTP/1.1 200 Connection Established\r\nProxy-Agent: VPNGATE-Bridge/1.0\r\n\r\n")

            t1 = threading.Thread(target=forward_stream, args=(client_sock, remote_sock), daemon=True)
            t2 = threading.Thread(target=forward_stream, args=(remote_sock, client_sock), daemon=True)
            t1.start()
            t2.start()
        else:
            # Standard HTTP Forward Proxy
            host = None
            port = 80
            if target.startswith("http://"):
                url_without_proto = target[7:]
                host_part = url_without_proto.split("/")[0]
                if ":" in host_part:
                    host, port_str = host_part.split(":", 1)
                    port = int(port_str)
                else:
                    host = host_part
            else:
                for line in req_data.split(b"\r\n"):
                    if line.lower().startswith(b"host:"):
                        host_header = line.split(b":", 1)[1].strip().decode("utf-8", errors="ignore")
                        if ":" in host_header:
                            host, port_str = host_header.split(":", 1)
                            port = int(port_str)
                        else:
                            host = host_header
                        break

            if not host:
                client_sock.close()
                return

            remote_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            remote_sock.settimeout(10.0)
            remote_sock.connect((host, port))
            remote_sock.settimeout(None)
            client_sock.settimeout(None)

            # Send original request data
            remote_sock.sendall(req_data)

            t1 = threading.Thread(target=forward_stream, args=(client_sock, remote_sock), daemon=True)
            t2 = threading.Thread(target=forward_stream, args=(remote_sock, client_sock), daemon=True)
            t1.start()
            t2.start()
    except Exception:
        try:
            client_sock.close()
        except Exception:
            pass


def start_http_server(port: int = 10809, host: str = "0.0.0.0"):
    """Starts local HTTP proxy server listening thread."""
    server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server_sock.bind((host, port))
        server_sock.listen(128)
        logging.info(f"🟢 HTTP 代理网关监听就绪:   http://127.0.0.1:{port}   (全网卡 0.0.0.0:{port})")
    except Exception as e:
        logging.error(f"❌ 绑定 HTTP 端口 {port} 失败: {e}")
        return

    while RUNNING:
        try:
            server_sock.settimeout(1.0)
            client, addr = server_sock.accept()
            t = threading.Thread(target=handle_http_client, args=(client,), daemon=True)
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
    target_node: Optional[str] = None,
    rank: int = 1,
    ovpn_file: Optional[str] = None,
    results_dir: str = "results"
) -> int:
    """Launches local proxy bridge forwarding through optimal or specified VPNGATE OpenVPN node."""
    if not os.path.isabs(results_dir):
        results_dir = os.path.join(SCRIPT_DIR, results_dir)

    node = resolve_bridge_node(
        results_dir=results_dir,
        country=country,
        target_node=target_node,
        rank=rank,
        ovpn_file=ovpn_file
    )

    if not node:
        c_hint = f" ({country})" if country else ""
        n_hint = f" (指定节点: {target_node})" if target_node else ""
        logging.error(f"❌ 未找到符合条件的住宅代理节点{c_hint}{n_hint}。")
        logging.info("👉 请先运行 'vpngate-selector' 或启动 'vpngate-service start' 进行测速优选。")
        return 1

    ip = node.get("ip")
    port = node.get("port", 443)
    country_code = node.get("country_short", "UN")
    latency = node.get("real_latency_ms", 0.0)
    fraud = node.get("fraud_score", -1)
    fraud_str = f"{fraud} / 100" if fraud >= 0 else "N/A"
    score = node.get("composite_score", 0.0)
    ovpn_b64 = node.get("ovpn_b64", "")

    logging.info("=" * 85)
    logging.info("🌉 VPNGATE 本地住宅代理中继网桥正在启动")
    logging.info(f"   • 选定住宅节点: [{country_code}] {ip}:{port} (实测握手延迟: {latency:.2f} ms | 威胁分: {fraud_str} | 评分: {score:.1f})")
    logging.info(f"   • 本地 SOCKS5 代理网关: socks5://127.0.0.1:{socks_port}")
    logging.info(f"   • 本地 HTTP 代理网关:   http://127.0.0.1:{http_port}")
    logging.info("=" * 85)

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

    with tempfile.NamedTemporaryFile("w", suffix=".ovpn", delete=False) as ovpn_file_tmp:
        ovpn_file_tmp.write(ovpn_content)
        ovpn_path = ovpn_file_tmp.name

    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as auth_file:
        auth_file.write("vpn\nvpn\n")
        auth_path = auth_file.name

    # 1. Start local SOCKS5 proxy server thread on 10808
    socks_thread = threading.Thread(target=start_socks5_server, args=(socks_port,), daemon=True)
    socks_thread.start()

    # 2. Start local HTTP proxy server thread on 10809
    http_thread = threading.Thread(target=start_http_server, args=(http_port,), daemon=True)
    http_thread.start()

    time.sleep(0.2)
    logging.info("✨ 本地 SOCKS5 & HTTP 双代理监听器启动完毕！")

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
        logging.info("💡 隧道建立后，即可通过 SOCKS5(10808) / HTTP(10809) 享受真实住宅宽带出海！")
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
    parser = argparse.ArgumentParser(
        description="VPNGATE 本地住宅代理网桥 (默认选择最优节点，支持手动指定节点)",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument(
        "target",
        nargs="?",
        default="",
        help="可选的目标节点 IP:端口 或 国家代码 (如 '221.71.170.232:1379' 或 'JP')"
    )
    parser.add_argument("--node", "-n", "--ip", type=str, default="", help="手动指定代理节点 IP 或 IP:端口")
    parser.add_argument("--country", "-c", type=str, default="", help="指定桥接的国家 (如 JP, KR, US)")
    parser.add_argument("--rank", "-r", type=int, default=1, help="指定选择该国家或全局排名第几的最优节点 (默认: 1)")
    parser.add_argument("--ovpn", "-f", type=str, default="", help="直接指定自定义 .ovpn 配置文件路径")
    parser.add_argument("--socks-port", type=int, default=10808, help="本地 SOCKS5 监听端口")
    parser.add_argument("--http-port", type=int, default=10809, help="本地 HTTP 监听端口")
    parser.add_argument("--results-dir", "-d", type=str, default="results", help="结果文件目录")
    parser.add_argument("--verbose", "-v", action="store_true", help="输出调试日志")

    args = parser.parse_args()
    setup_logging(verbose=args.verbose)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    target_node = args.node if args.node else args.target
    country = args.country
    if not country and target_node and len(target_node.strip()) == 2 and target_node.isalpha():
        country = target_node.strip().upper()
        target_node = ""

    return run_bridge(
        socks_port=args.socks_port,
        http_port=args.http_port,
        country=country if country else None,
        target_node=target_node if target_node else None,
        rank=args.rank,
        ovpn_file=args.ovpn if args.ovpn else None,
        results_dir=args.results_dir
    )


if __name__ == "__main__":
    sys.exit(main())
