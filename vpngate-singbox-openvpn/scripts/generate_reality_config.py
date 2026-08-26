#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Sing-box VLESS + REALITY 配置文件生成器 (Host Manual Trigger Generator)
- 对外通过 VLESS + REALITY 协议提供服务，默认覆盖常用 HTTPS 端口 (443, 8443, 2053, 2083, 2087, 2096)
- 内部所有入站流量通过 SOCKS5 出站转发至本地 SOCKS 代理 (如 127.0.0.1:2080)
- 支持指定 Inbound 绑定的 IP 地址与出站 SOCKS 代理端口
- 支持更新/指定 VLESS 协议 UUID、Reality 密钥对与伪装 SNI
- 自动输出通用客户端导入链接 (vless://)、Clash Meta YAML 与 Sing-box 客户端配置
"""

import os
import sys
import json
import uuid
import secrets
import argparse
import urllib.parse
import urllib.request
import subprocess
from typing import List, Tuple, Optional

DEFAULT_PORTS = [443, 8443, 2053, 2083, 2087, 2096]
DEFAULT_LISTEN_IP = "0.0.0.0"
DEFAULT_SOCKS_HOST = "127.0.0.1"
DEFAULT_SOCKS_PORT = 2080
DEFAULT_SNI = "www.apple.com"

def find_singbox_bin() -> str:
    """Find sing-box executable on host or local bin directory."""
    for path in ["/usr/local/bin/sing-box", "/usr/bin/sing-box", os.path.expanduser("~/.local/bin/sing-box")]:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    local_bin = os.path.join(project_root, "bin", "sing-box")
    if os.path.isfile(local_bin) and os.access(local_bin, os.X_OK):
        return local_bin
    
    # 尝试从自带压缩包中解压
    bin_dir = os.path.join(project_root, "bin")
    if os.path.isdir(bin_dir):
        for f in os.listdir(bin_dir):
            if f.startswith("sing-box-") and f.endswith(".tar.gz"):
                tar_path = os.path.join(bin_dir, f)
                try:
                    subprocess.run(["tar", "-xzf", tar_path, "-C", "/tmp"], check=True, capture_output=True)
                    for root, _, files in os.walk("/tmp"):
                        if "sing-box" in files:
                            cand = os.path.join(root, "sing-box")
                            if os.access(cand, os.X_OK):
                                return cand
                except Exception:
                    pass

    return "sing-box"

def generate_reality_keypair(singbox_bin: str) -> Tuple[str, str]:
    """Generate x25519 Reality PrivateKey and PublicKey."""
    if singbox_bin and (os.path.isfile(singbox_bin) or shutil_which(singbox_bin)):
        try:
            res = subprocess.run(
                [singbox_bin, "generate", "reality-keypair"],
                capture_output=True,
                text=True,
                check=True
            )
            priv, pub = "", ""
            for line in res.stdout.strip().splitlines():
                if "PrivateKey:" in line:
                    priv = line.split("PrivateKey:", 1)[1].strip()
                elif "PublicKey:" in line:
                    pub = line.split("PublicKey:", 1)[1].strip()
            if priv and pub:
                return priv, pub
        except Exception:
            pass

    # 兜底生成随机 32 字节 Base64 URL-Safe 格式
    import base64
    priv = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("=")
    pub = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("=")
    return priv, pub

def shutil_which(cmd: str) -> bool:
    try:
        res = subprocess.run(["which", cmd], capture_output=True)
        return res.returncode == 0
    except Exception:
        return False

def detect_public_ip() -> str:
    """Detect public IP address of current machine."""
    endpoints = [
        "https://api.ipify.org",
        "https://ifconfig.me/ip",
        "https://icanhazip.com",
        "http://checkip.amazonaws.com"
    ]
    for url in endpoints:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "curl/8.0"})
            with urllib.request.urlopen(req, timeout=3) as resp:
                ip = resp.read().decode().strip()
                if ip and len(ip) <= 45:
                    return ip
        except Exception:
            continue
    return "YOUR_SERVER_IP"

def parse_ports(port_str: str) -> List[int]:
    """Parse comma-separated port string."""
    ports = []
    for p in port_str.split(","):
        p = p.strip()
        if p.isdigit() and 1 <= int(p) <= 65535:
            ports.append(int(p))
    return ports or DEFAULT_PORTS

def build_singbox_config(
    listen_ip: str,
    ports: List[int],
    socks_host: str,
    socks_port: int,
    user_uuid: str,
    sni: str,
    handshake_server: str,
    handshake_port: int,
    private_key: str,
    short_id: str
) -> dict:
    """Build Sing-box server configuration object."""
    inbounds = []
    for p in ports:
        inbound = {
            "type": "vless",
            "tag": f"vless-in-{p}",
            "listen": listen_ip,
            "listen_port": p,
            "users": [
                {
                    "uuid": user_uuid,
                    "flow": "xtls-rprx-vision"
                }
            ],
            "tls": {
                "enabled": True,
                "server_name": sni,
                "reality": {
                    "enabled": True,
                    "handshake": {
                        "server": handshake_server,
                        "server_port": handshake_port
                    },
                    "private_key": private_key,
                    "short_id": [short_id] if short_id else []
                }
            }
        }
        inbounds.append(inbound)

    outbounds = [
        {
            "type": "socks",
            "tag": "socks-out",
            "server": socks_host,
            "server_port": socks_port
        },
        {
            "type": "direct",
            "tag": "direct"
        }
    ]

    route = {
        "rules": [
            {
                "inbound": [f"vless-in-{p}" for p in ports],
                "outbound": "socks-out"
            }
        ],
        "final": "socks-out"
    }

    config = {
        "log": {
            "level": "info",
            "timestamp": True
        },
        "inbounds": inbounds,
        "outbounds": outbounds,
        "route": route
    }
    return config

def main():
    parser = argparse.ArgumentParser(
        description="生成 Sing-box VLESS + REALITY 配置文件 (出站对接本地 SOCKS 代理)"
    )
    parser.add_argument("-l", "--listen", default=DEFAULT_LISTEN_IP, help=f"Inbound 绑定监听 IP 地址 (默认: {DEFAULT_LISTEN_IP})")
    parser.add_argument("-p", "--ports", default=",".join(map(str, DEFAULT_PORTS)), help="开放的 HTTPS 端口列表，逗号分隔 (默认: 443,8443,2053,2083,2087,2096)")
    parser.add_argument("-s", "--socks-port", type=int, default=DEFAULT_SOCKS_PORT, help=f"出站转发的本地 SOCKS5 代理端口 (默认: {DEFAULT_SOCKS_PORT})")
    parser.add_argument("--socks-host", default=DEFAULT_SOCKS_HOST, help=f"出站转发的本地 SOCKS5 代理地址 (默认: {DEFAULT_SOCKS_HOST})")
    parser.add_argument("-u", "--uuid", help="指定 VLESS UUID (留空则自动生成全新 UUIDv4)")
    parser.add_argument("--sni", default=DEFAULT_SNI, help=f"Reality 伪装握手域名 (默认: {DEFAULT_SNI})")
    parser.add_argument("--handshake-server", help="Reality 回落目标服务器 (默认同 --sni)")
    parser.add_argument("--handshake-port", type=int, default=443, help="Reality 回落目标端口 (默认: 443)")
    parser.add_argument("--private-key", help="指定 Reality 私钥 (留空则自动生成)")
    parser.add_argument("--public-key", help="指定 Reality 公钥 (留空则自动根据私钥生成)")
    parser.add_argument("--short-id", help="指定 Reality Short ID (留空则自动生成)")
    parser.add_argument("-o", "--output", default="singbox_reality.json", help="生成的配置文件保存路径 (默认: ./singbox_reality.json)")
    parser.add_argument("--server-ip", help="生成客户端节点链接时指定的服务器公网 IP (默认自动探测)")
    parser.add_argument("--name", default="VLESS-Reality-Residential", help="客户端节点名称前缀 (默认: VLESS-Reality-Residential)")

    args = parser.parse_args()

    singbox_bin = find_singbox_bin()

    # 1. 解析 UUID
    user_uuid = (args.uuid or str(uuid.uuid4())).strip()

    # 2. 解析 Reality 密钥对
    priv_key = args.private_key
    pub_key = args.public_key
    if not priv_key or not pub_key:
        gen_priv, gen_pub = generate_reality_keypair(singbox_bin)
        priv_key = priv_key or gen_priv
        pub_key = pub_key or gen_pub

    # 3. 解析 Short ID
    short_id = (args.short_id or secrets.token_hex(4)).strip()

    # 4. 解析端口与 SNI
    ports = parse_ports(args.ports)
    sni = args.sni.strip()
    handshake_server = (args.handshake_server or sni).strip()
    handshake_port = args.handshake_port
    socks_host = args.socks_host.strip()
    socks_port = args.socks_port
    listen_ip = args.listen.strip()

    # 5. 生成 Sing-box JSON 配置
    config = build_singbox_config(
        listen_ip=listen_ip,
        ports=ports,
        socks_host=socks_host,
        socks_port=socks_port,
        user_uuid=user_uuid,
        sni=sni,
        handshake_server=handshake_server,
        handshake_port=handshake_port,
        private_key=priv_key,
        short_id=short_id
    )

    output_path = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)

    # 6. 配置语法校验
    check_status = "未执行校验"
    if singbox_bin and (os.path.isfile(singbox_bin) or shutil_which(singbox_bin)):
        try:
            res = subprocess.run([singbox_bin, "check", "-c", output_path], capture_output=True, text=True)
            if res.returncode == 0:
                check_status = "PASSED ✅"
            else:
                check_status = f"WARNING: {res.stderr.strip()}"
        except Exception:
            pass

    # 7. 生成客户端信息
    server_ip = args.server_ip or detect_public_ip()
    vless_links = []
    clash_proxies = []
    singbox_outbounds = []

    for p in ports:
        node_name = f"{args.name}-{p}"
        link = (
            f"vless://{user_uuid}@{server_ip}:{p}?"
            f"encryption=none&flow=xtls-rprx-vision&security=reality&"
            f"sni={sni}&fp=chrome&pbk={pub_key}&sid={short_id}&type=tcp#{urllib.parse.quote(node_name)}"
        )
        vless_links.append((p, node_name, link))

        clash_proxies.append({
            "name": node_name,
            "type": "vless",
            "server": server_ip,
            "port": p,
            "uuid": user_uuid,
            "network": "tcp",
            "tls": True,
            "udp": True,
            "flow": "xtls-rprx-vision",
            "servername": sni,
            "reality-opts": {
                "public-key": pub_key,
                "short-id": short_id
            },
            "client-fingerprint": "chrome"
        })

        singbox_outbounds.append({
            "type": "vless",
            "tag": f"vless-out-{p}",
            "server": server_ip,
            "server_port": p,
            "uuid": user_uuid,
            "flow": "xtls-rprx-vision",
            "tls": {
                "enabled": True,
                "server_name": sni,
                "utls": {
                    "enabled": True,
                    "fingerprint": "chrome"
                },
                "reality": {
                    "enabled": True,
                    "public_key": pub_key,
                    "short_id": short_id
                }
            }
        })

    # 8. 打印结果
    print("\n" + "=" * 70)
    print(" 🎉 Sing-box VLESS + REALITY 配置文件已生成！")
    print("=" * 70)
    print(f" • 配置文件输出:     {output_path}")
    print(f" • 语法校验状态:     {check_status}")
    print(f" • 入站监听绑定:     {listen_ip}")
    print(f" • 覆盖开放端口:     {', '.join(map(str, ports))}")
    print(f" • 内部出站转发:     SOCKS5://{socks_host}:{socks_port}")
    print(f" • VLESS UUID:       {user_uuid}")
    print(f" • 伪装域名 (SNI):   {sni}")
    print(f" • Reality 公钥:     {pub_key}")
    print(f" • Reality 私钥:     {priv_key}")
    print(f" • Reality ShortID:  {short_id}")
    print("=" * 70)

    print("\n📋 【通用 VLESS 客户端导入链接 (vless://)】")
    for p, name, url in vless_links:
        print(f"\n[ 端口 {p} ] -> {name}:")
        print(url)

    print("\n" + "-" * 70)
    print("📦 【Clash Meta / Mihomo 节点配置片段 (YAML)】")
    for c in clash_proxies:
        print(f"  - name: \"{c['name']}\"")
        print(f"    type: vless")
        print(f"    server: {c['server']}")
        print(f"    port: {c['port']}")
        print(f"    uuid: {c['uuid']}")
        print(f"    network: tcp")
        print(f"    tls: true")
        print(f"    udp: true")
        print(f"    flow: xtls-rprx-vision")
        print(f"    servername: {c['servername']}")
        print(f"    reality-opts:")
        print(f"      public-key: {c['reality-opts']['public-key']}")
        print(f"      short-id: {c['reality-opts']['short-id']}")
        print(f"    client-fingerprint: chrome\n")

    print("-" * 70)
    print("📦 【Sing-box 客户端出站配置片段 (JSON)】")
    print(json.dumps(singbox_outbounds, indent=2, ensure_ascii=False))
    print("=" * 70)

    print(f"\n💡 【手动运行服务端命令】:")
    print(f"  sudo sing-box run -c {output_path}\n")

if __name__ == "__main__":
    main()
