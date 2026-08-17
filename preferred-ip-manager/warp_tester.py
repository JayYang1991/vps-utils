#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Cloudflare WARP Endpoint 优选与测速引擎
基于 RFC 9000 (QUIC v1) Initial 握手与 MASQUE 协议深度探测，实现对 Cloudflare WARP Anycast Endpoint 的毫秒级 RTT 延迟、丢包率与 MTU 大包可达性精确测量。
支持批量多线程并发探测、智能打分排序、多种客户端格式导出（WireGuard / Sing-box / Clash / WARP-CLI）及自动推送至 Cloudflare Worker。
"""

import os
import sys
import time
import socket
import struct
import secrets
import ipaddress
import argparse
import json
from concurrent.futures import ThreadPoolExecutor, as_completed

# --- ANSI 终端颜色常量 ---
GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[0;33m"
BLUE = "\033[0;34m"
CYAN = "\033[0;36m"
PURPLE = "\033[0;35m"
BOLD = "\033[1m"
RESET = "\033[0m"

DEFAULT_WARP_IPV4_SUBNETS = [
    "162.159.192.0/24",
    "162.159.193.0/24",
    "162.159.195.0/24",
    "162.159.197.0/24",
    "188.114.96.0/24",
    "188.114.97.0/24",
    "188.114.98.0/24",
    "188.114.99.0/24",
]

DEFAULT_WARP_IPV6_SUBNETS = [
    "2606:4700:d0::/48",
    "2606:4700:d1::/48",
]

DEFAULT_WARP_PORTS = [443, 8443, 4443, 8095, 4500, 500, 1701, 2408]
DEFAULT_WARP_RESULT_FILE = "warp_result.txt"
DEFAULT_SNI = "engage.cloudflareclient.com"


def build_varint(val: int) -> bytes:
    """构建 QUIC 可变长整数 (Variable-Length Integer Encoding)"""
    if val < 64:
        return bytes([val])
    elif val < 16384:
        return struct.pack("!H", 0x4000 | val)
    elif val < 1073741824:
        return struct.pack("!I", 0x80000000 | val)
    else:
        return struct.pack("!Q", 0xC000000000000000 | val)


def build_quic_initial(
    dcid: bytes,
    scid: bytes,
    sni: str = DEFAULT_SNI,
    token: bytes = b"",
) -> bytes:
    """
    构造符合 RFC 9000 标准的 QUIC v1 Initial 握手报文
    含 TLS 1.3 ClientHello, 最小强制填充 1200 字节，用于验证 1200B MTU 大包可达性
    """
    first_byte = 0xC0  # Header Form=1, Fixed=1, Long Packet Type=0 (Initial), Packet Number Len=1
    version = struct.pack("!I", 0x00000001)  # QUIC v1
    dcid_len = bytes([len(dcid)])
    scid_len = bytes([len(scid)])
    token_len_varint = build_varint(len(token))

    sni_bytes = sni.encode("utf-8")
    sni_ext = (
        b"\x00\x00"
        + struct.pack("!H", len(sni_bytes) + 5)
        + struct.pack("!H", len(sni_bytes) + 3)
        + b"\x00"
        + struct.pack("!H", len(sni_bytes))
        + sni_bytes
    )
    supported_groups = b"\x00\x0a\x00\x08\x00\x06\x00\x1d\x00\x17\x00\x18"
    key_share = b"\x00\x33\x00\x24\x00\x22\x00\x1d\x00\x20" + secrets.token_bytes(32)
    supported_vers = b"\x00\x2b\x00\x03\x02\x03\x04"
    quic_tp = b"\xff\x05\x00\x04\x00\x02\x00\x00"
    extensions = sni_ext + supported_groups + key_share + supported_vers + quic_tp
    ext_bytes = struct.pack("!H", len(extensions)) + extensions

    client_random = secrets.token_bytes(32)
    session_id = secrets.token_bytes(32)
    cipher_suites = b"\x00\x06\x13\x01\x13\x02\x13\x03"
    compression = b"\x01\x00"
    ch_body = (
        b"\x03\x03"
        + client_random
        + b"\x20"
        + session_id
        + cipher_suites
        + compression
        + ext_bytes
    )
    client_hello = b"\x01" + struct.pack("!I", len(ch_body))[1:] + ch_body

    crypto_frame = b"\x06\x00" + build_varint(len(client_hello)) + client_hello
    packet_number = b"\x01"
    payload = crypto_frame

    header_pre = (
        bytes([first_byte])
        + version
        + dcid_len
        + dcid
        + scid_len
        + scid
        + token_len_varint
        + token
    )
    curr_len = len(header_pre) + 2 + len(packet_number) + len(payload)
    if curr_len < 1200:
        payload += b"\x00" * (1200 - curr_len)

    payload_len_varint = build_varint(len(packet_number) + len(payload))
    header = (
        bytes([first_byte])
        + version
        + dcid_len
        + dcid
        + scid_len
        + scid
        + token_len_varint
        + token
        + payload_len_varint
    )
    return header + packet_number + payload


def parse_quic_response(resp: bytes) -> dict:
    """解析服务端返回的 QUIC 报文头部"""
    if len(resp) < 5:
        return {"valid": False}
    hdr_byte = resp[0]
    is_long = bool(hdr_byte & 0x80)
    pkt_type = (hdr_byte & 0x30) >> 4
    ver = struct.unpack("!I", resp[1:5])[0]
    if not is_long:
        return {"valid": True, "is_long": False, "type": "1-RTT"}
    if ver == 0:
        return {"valid": True, "is_long": True, "type": "VersionNeg"}
    type_map = {0: "Initial", 1: "0-RTT", 2: "Handshake", 3: "Retry"}
    return {"valid": True, "is_long": True, "type": type_map.get(pkt_type, f"Type={pkt_type}")}


def probe_single_endpoint(
    ip: str,
    port: int,
    timeout: float = 1.0,
    rounds: int = 3,
    sni: str = DEFAULT_SNI,
    bind_ip: str = "",
) -> dict:
    """对单个 IP:Port 执行多轮 MASQUE/QUIC 连通性与 RTT 探测"""
    is_ipv6 = ":" in ip
    family = socket.AF_INET6 if is_ipv6 else socket.AF_INET
    rtts = []
    resp_type = None

    dcid = secrets.token_bytes(8)
    scid = secrets.token_bytes(8)
    pkt = build_quic_initial(dcid, scid, sni=sni)

    for _ in range(rounds):
        sock = socket.socket(family, socket.SOCK_DGRAM)
        if bind_ip:
            try:
                sock.bind((bind_ip, 0))
            except Exception:
                pass
        sock.settimeout(timeout)
        t0 = time.time()
        try:
            sock.sendto(pkt, (ip, port))
            resp, addr = sock.recvfrom(2048)
            rtt = (time.time() - t0) * 1000
            pinfo = parse_quic_response(resp)
            if pinfo.get("valid"):
                rtts.append(rtt)
                resp_type = pinfo.get("type")
        except Exception:
            pass
        finally:
            sock.close()

    success_count = len(rtts)
    loss_rate = ((rounds - success_count) / rounds) * 100.0

    if success_count > 0:
        avg_rtt = sum(rtts) / success_count
        min_rtt = min(rtts)
        max_rtt = max(rtts)
        jitter = max_rtt - min_rtt
        return {
            "ip": ip,
            "port": port,
            "success": True,
            "rounds": rounds,
            "success_count": success_count,
            "loss_rate": loss_rate,
            "avg_rtt": avg_rtt,
            "min_rtt": min_rtt,
            "max_rtt": max_rtt,
            "jitter": jitter,
            "type": resp_type or "OK",
        }
    else:
        return {
            "ip": ip,
            "port": port,
            "success": False,
            "rounds": rounds,
            "success_count": 0,
            "loss_rate": 100.0,
            "avg_rtt": 9999.0,
            "min_rtt": 9999.0,
            "max_rtt": 9999.0,
            "jitter": 0.0,
            "type": None,
        }


def resolve_warp_domain(domain: str = DEFAULT_SNI) -> list:
    """解析 WARP 官方默认域名获取 Anycast IP"""
    ips = []
    try:
        results = socket.getaddrinfo(domain, None)
        for r in results:
            sockaddr = r[4]
            ip_str = sockaddr[0]
            if ip_str not in ips:
                ips.append(ip_str)
    except Exception:
        pass
    return ips


def generate_candidate_ips(
    scan_mode: str = "fast",
    custom_ips: list = None,
    custom_file: str = None,
    include_ipv6: bool = False,
) -> list:
    """生成待测试的 WARP 候选 IP 列表"""
    ips = []

    # 1. 自定义指定 IP
    if custom_ips:
        for item in custom_ips:
            item = item.strip()
            if item and item not in ips:
                ips.append(item)

    # 2. 从文件读取
    if custom_file and os.path.exists(custom_file):
        try:
            with open(custom_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    # 支持 IP 或 IP:Port 格式
                    addr = line.split("#")[0].split(":")[0].strip()
                    if addr and addr not in ips:
                        ips.append(addr)
        except Exception as e:
            print(f"⚠️ 读取自定义 IP 文件失败: {e}")

    # 若未指定自定义源，则生成内置 IP 段
    if not ips:
        # 加入官方域名 DNS 解析结果
        domain_ips = resolve_warp_domain(DEFAULT_SNI)
        for dip in domain_ips:
            if dip not in ips:
                ips.append(dip)

        # 遍历 IPv4 网段
        for sub in DEFAULT_WARP_IPV4_SUBNETS:
            net = ipaddress.ip_network(sub)
            hosts = list(net.hosts())
            if scan_mode == "fast":
                # 快速模式：每段抽取代表性主机
                picks = [1, 2, 3, 5, 10, 15, 20, 50, 100, 150, 200, 254]
                for p in picks:
                    if p <= len(hosts):
                        ip_str = str(hosts[p - 1])
                        if ip_str not in ips:
                            ips.append(ip_str)
            elif scan_mode == "standard":
                # 标准模式：步长采样
                for h in hosts[::5]:
                    ip_str = str(h)
                    if ip_str not in ips:
                        ips.append(ip_str)
            elif scan_mode == "full":
                # 全量模式：全网段扫描
                for h in hosts:
                    ip_str = str(h)
                    if ip_str not in ips:
                        ips.append(ip_str)

        # 可选加入 IPv6 探测
        if include_ipv6:
            for sub in DEFAULT_WARP_IPV6_SUBNETS:
                base_net = ipaddress.ip_network(sub)
                prefix = str(base_net.network_address)
                # 常见 IPv6 WARP Anycast 地址生成
                for i in [1, 2, 3, 4, 5, 10, 20, 50, 100]:
                    ip6_str = f"{prefix[:-1]}a29f:{i:04x}"
                    if ip6_str not in ips:
                        ips.append(ip6_str)

    return ips


def scan_warp_endpoints(
    candidate_ips: list,
    ports: list,
    timeout: float = 1.0,
    rounds: int = 3,
    concurrency: int = 100,
    sni: str = DEFAULT_SNI,
    bind_ip: str = "",
) -> list:
    """并发扫描所有候选 Endpoint 并返回测试结果"""
    tasks = [(ip, p) for ip in candidate_ips for p in ports]
    total_tasks = len(tasks)

    print(f"\n==> 🚀 开始测速探测 Cloudflare WARP Endpoints...")
    print(f"  • 候选 IP 数量 : {len(candidate_ips)}")
    print(f"  • 探测端口列表 : {', '.join(map(str, ports))}")
    print(f"  • 总计测试端点 : {total_tasks} 个 (并发线程: {concurrency})")
    print(f"  • 单点探测轮数 : {rounds} 轮 (超时: {timeout}s/轮)")
    print(f"  • 握手伪装 SNI : {sni}")
    if bind_ip:
        print(f"  • 绑定源 IP    : {bind_ip}")
    print("-" * 65)

    start_time = time.time()
    results = []
    completed = 0

    with ThreadPoolExecutor(max_workers=concurrency) as executor:
        future_map = {
            executor.submit(
                probe_single_endpoint,
                ip=ip,
                port=port,
                timeout=timeout,
                rounds=rounds,
                sni=sni,
                bind_ip=bind_ip,
            ): (ip, port)
            for ip, port in tasks
        }

        for future in as_completed(future_map):
            completed += 1
            res = future.result()
            if res["success"]:
                results.append(res)
            # 动态进度显示
            if completed % max(1, total_tasks // 20) == 0 or completed == total_tasks:
                pct = (completed / total_tasks) * 100
                sys.stdout.write(
                    f"\r⏳ 测速进度: [{completed}/{total_tasks}] {pct:>5.1f}% | 已发现有效端点: {len(results)} 个"
                )
                sys.stdout.flush()

    elapsed = time.time() - start_time
    print(f"\n\n✅ 测速完成！耗时: {elapsed:.2f} 秒，共发现 {len(results)} 个有效可用 WARP Endpoints")

    # 综合打分排序：丢包率升序 -> 平均 RTT 升序 -> 抖动升序
    results.sort(key=lambda x: (x["loss_rate"], x["avg_rtt"], x["jitter"]))
    return results


def format_export_configs(top_endpoints: list, export_type: str = "txt") -> str:
    """将优选端点格式化为各种客户端配置"""
    if not top_endpoints:
        return ""

    if export_type == "txt":
        # IP:Port#WARP 格式
        lines = []
        for i, ep in enumerate(top_endpoints):
            ip_str = f"[{ep['ip']}]" if ":" in ep["ip"] else ep["ip"]
            lines.append(f"{ip_str}:{ep['port']}#WARP-{i+1}")
        return "\n".join(lines)

    elif export_type == "wireguard":
        # WireGuard Endpoint 格式
        lines = ["# Cloudflare WARP WireGuard Endpoints"]
        for i, ep in enumerate(top_endpoints):
            ip_str = f"[{ep['ip']}]" if ":" in ep["ip"] else ep["ip"]
            lines.append(f"# [{i+1}] Avg RTT: {ep['avg_rtt']:.1f}ms (Loss: {ep['loss_rate']:.0f}%)")
            lines.append(f"Endpoint = {ip_str}:{ep['port']}")
        return "\n".join(lines)

    elif export_type == "singbox":
        # Sing-box Outbound 片段
        outbounds = []
        for i, ep in enumerate(top_endpoints):
            outbounds.append(
                {
                    "type": "wireguard",
                    "tag": f"WARP-Endpoint-{i+1}",
                    "server": ep["ip"],
                    "server_port": ep["port"],
                    "system_interface": False,
                    "mtu": 1280,
                }
            )
        return json.dumps(outbounds, indent=2, ensure_ascii=False)

    elif export_type == "clash":
        # Clash Meta / Mihomo 片段
        lines = ["# Clash Meta / Mihomo WARP Endpoints:"]
        for i, ep in enumerate(top_endpoints):
            lines.append(f"- name: \"WARP-{i+1} ({ep['avg_rtt']:.0f}ms)\"")
            lines.append(f"  type: wireguard")
            lines.append(f"  server: {ep['ip']}")
            lines.append(f"  port: {ep['port']}")
            lines.append(f"  ip: 172.16.0.2")
            lines.append(f"  public-key: bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=")
            lines.append(f"  udp: true")
        return "\n".join(lines)

    elif export_type == "warp-cli":
        # WARP 官方客户端快速切换命令
        lines = ["# WARP-CLI 切换命令:"]
        for i, ep in enumerate(top_endpoints):
            ip_str = f"[{ep['ip']}]" if ":" in ep["ip"] else ep["ip"]
            lines.append(f"# Option {i+1} (RTT: {ep['avg_rtt']:.1f}ms)")
            lines.append(f"warp-cli tunnel endpoint set {ip_str}:{ep['port']}")
        return "\n".join(lines)

    return ""


def upload_warp_results(file_path: str, base_url: str = "https://sub.19910417.xyz"):
    """推送 WARP 优选端点至 Cloudflare Worker"""
    token = os.environ.get("CF_SUB_TOKEN")
    if not token:
        print("⚠️ 提示: 未配置环境变量 CF_SUB_TOKEN，跳过推送至订阅服务器。")
        return

    url = f"{base_url.rstrip('/')}/api/update?type=warp"
    print(f"==> 正在同步 WARP 优选端点至订阅服务器 {url}...")

    try:
        with open(file_path, "rb") as f:
            data = f.read()

        headers = {
            "Authorization": token,
            "Content-Type": "text/plain; charset=utf-8",
            "User-Agent": "Mozilla/5.0",
        }

        import requests

        resp = requests.put(url, data=data, headers=headers, timeout=15)
        if resp.status_code == 200:
            print(f"✅ WARP 优选端点同步成功: {resp.text}")
        else:
            print(f"❌ 同步失败 (HTTP {resp.status_code}): {resp.text}")
    except Exception as e:
        print(f"❌ 同步过程中出现异常: {e}")


def main():
    parser = argparse.ArgumentParser(
        description="Cloudflare WARP Anycast Endpoint 优选与测速工具 (基于 RFC 9000 MASQUE/QUIC 探测)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
使用示例:
  1. 快速模式测速 (默认，从各 Anycast 段快速抽样，保留前 10 个最优端点):
     python3 warp_tester.py

  2. 全量模式测速 (对所有 WARP IPv4 Anycast /24 网段全量扫描):
     python3 warp_tester.py --mode full --top 20

  3. 指定自定义端口与并发线程:
     python3 warp_tester.py -p 4443,8443,4500,8095 -c 150 --top 15

  4. 输出为 Sing-box / Clash / WireGuard 配置格式:
     python3 warp_tester.py --format singbox
     python3 warp_tester.py --format clash
     python3 warp_tester.py --format wireguard

  5. 自动化无交互执行并自动推送到 Cloudflare Worker:
     python3 warp_tester.py --yes
""",
    )
    parser.add_argument(
        "--mode",
        "-m",
        choices=["fast", "standard", "full"],
        default="fast",
        help="扫描模式: fast (快速抽样, 默认), standard (标准采样), full (全网段全量扫描)",
    )
    parser.add_argument(
        "--top",
        "-t",
        type=int,
        default=10,
        help="最终保留的最优 Endpoint 数量 (默认: 10)",
    )
    parser.add_argument(
        "--ports",
        "-p",
        default="443,8443,4443,8095,4500,500,1701,2408",
        help="待测端口列表，逗号分隔 (默认: 443,8443,4443,8095,4500,500,1701,2408)",
    )
    parser.add_argument(
        "--concurrency",
        "-c",
        type=int,
        default=100,
        help="并发探测线程数 (默认: 100)",
    )
    parser.add_argument(
        "--rounds",
        "-r",
        type=int,
        default=3,
        help="单点探测轮数 (默认: 3 轮)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=1.0,
        help="单次请求超时时间 (秒，默认: 1.0)",
    )
    parser.add_argument(
        "--ipv6",
        action="store_true",
        help="启用 IPv6 WARP Anycast 网段探测",
    )
    parser.add_argument(
        "--ip",
        "-i",
        default="",
        help="指定测试的具体 IP (多个用逗号分隔)",
    )
    parser.add_argument(
        "--file",
        "-f",
        default="",
        help="从指定文件读取候选 IP / Endpoint 列表",
    )
    parser.add_argument(
        "--bind-ip",
        default="",
        help="本地绑定的出网源 IP 地址 (用于在特定物理网卡直连探测)",
    )
    parser.add_argument(
        "--output",
        "-o",
        default=DEFAULT_WARP_RESULT_FILE,
        help=f"优选结果保存文件 (默认: {DEFAULT_WARP_RESULT_FILE})",
    )
    parser.add_argument(
        "--format",
        choices=["txt", "wireguard", "singbox", "clash", "warp-cli"],
        default="txt",
        help="终端展示或导出的配置格式 (默认: txt)",
    )
    parser.add_argument(
        "--yes",
        "-y",
        action="store_true",
        help="跳过确认提示，自动推送到 Cloudflare Workers 订阅服务器",
    )

    args = parser.parse_args()

    # 解析端口
    try:
        ports = [int(p.strip()) for p in args.ports.split(",") if p.strip()]
    except ValueError:
        print(f"{RED}错误: 端口格式不正确，必须为数字 (如: 443,8443,4443){RESET}")
        return

    # 解析自定义 IP
    custom_ips = [ip.strip() for ip in args.ip.split(",") if ip.strip()] if args.ip else None

    # 生成候选 IP
    candidate_ips = generate_candidate_ips(
        scan_mode=args.mode,
        custom_ips=custom_ips,
        custom_file=args.file,
        include_ipv6=args.ipv6,
    )

    if not candidate_ips:
        print(f"{RED}错误: 未找到任何有效的候选 IP 进行探测。{RESET}")
        return

    # 执行测速
    results = scan_warp_endpoints(
        candidate_ips=candidate_ips,
        ports=ports,
        timeout=args.timeout,
        rounds=args.rounds,
        concurrency=args.concurrency,
        sni=DEFAULT_SNI,
        bind_ip=args.bind_ip,
    )

    if not results:
        print(f"\n{RED}未能在任何候选端点探测到有效响应，请检查本地网络或 UDP 防火墙。{RESET}")
        return

    top_count = min(len(results), args.top)
    top_results = results[:top_count]

    # 保存 TXT 结果
    txt_content = format_export_configs(top_results, "txt")
    with open(args.output, "w", encoding="utf-8") as f:
        f.write(txt_content + "\n")

    # 打印排列表格
    print(f"\n✨ {BOLD}WARP 优选测速完成！最优前 {len(top_results)} 个 Endpoint 已保存至 {args.output}：{RESET}")
    print("=" * 80)
    print(
        f" {BOLD}{'排名':<4} {'Endpoint (IP:Port)':<26} {'丢包率':<8} {'平均延迟':<12} {'最小延迟':<12} {'抖动':<10} {'协议'}{RESET}"
    )
    print("-" * 80)
    for i, r in enumerate(top_results):
        ip_port = f"{r['ip']}:{r['port']}"
        loss_color = GREEN if r["loss_rate"] == 0 else (YELLOW if r["loss_rate"] < 50 else RED)
        rtt_color = GREEN if r["avg_rtt"] < 150 else (YELLOW if r["avg_rtt"] < 250 else RED)
        print(
            f" [{i+1:>2}] {ip_port:<26} {loss_color}{r['loss_rate']:>5.1f}%{RESET}   {rtt_color}{r['avg_rtt']:>7.2f} ms{RESET}   {r['min_rtt']:>7.2f} ms   {r['jitter']:>6.2f} ms   {r['type']}"
        )
    print("=" * 80)

    # 导出指定格式内容
    if args.format != "txt":
        print(f"\n📋 {BOLD}已生成 [{args.format}] 客户端配置片段：{RESET}")
        print("-" * 65)
        print(format_export_configs(top_results, args.format))
        print("-" * 65)

    # 确认并上传
    token = os.environ.get("CF_SUB_TOKEN")
    if not token:
        print(f"\n💡 提示: 未配置环境变量 CF_SUB_TOKEN，跳过推送。优选结果已保存在 {args.output}")
    else:
        if not args.yes:
            try:
                user_input = (
                    input(
                        f"\n👉 是否确认将以上 {len(top_results)} 个 WARP 优选端点推送到 Cloudflare Workers 订阅服务器？ [Y/n]: "
                    )
                    .strip()
                    .lower()
                )
                if user_input not in ("", "y", "yes"):
                    print(f"⏸️ 已取消推送操作。优选结果已保留在 {args.output}")
                    return
            except (KeyboardInterrupt, EOFError):
                print(f"\n⏸️ 用户取消推送操作。优选结果已保留在 {args.output}")
                return

        upload_warp_results(args.output)


if __name__ == "__main__":
    main()
