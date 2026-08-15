#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Cloudflare WARP MASQUE (QUIC / HTTP3) 协议协商与连通性深度测试工具
基于 RFC 9000 (QUIC v1) 协议标准实现纯标准库双阶段握手测试 (Initial -> Retry -> Handshake)
无需安装任何第三方依赖，支持指定网卡/源IP、自定义端口、批量 IP 探测与 RTT 时延诊断。
"""

import socket
import time
import struct
import secrets
import argparse
import sys

# --- 终端彩色输出配置 ---
GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[0;33m"
BLUE = "\033[0;34m"
CYAN = "\033[0;36m"
PURPLE = "\033[0;35m"
BOLD = "\033[1m"
RESET = "\033[0m"

DEFAULT_PORTS = [443, 8443, 4500, 8095, 500, 1701, 4443]

def build_varint(val: int) -> bytes:
    """构建 QUIC 可变长整数 (Variable-Length Integer Encoding)"""
    if val < 64:
        return bytes([val])
    elif val < 16384:
        return struct.pack("!H", 0x4000 | val)
    elif val < 1073741824:
        return struct.pack("!I", 0x80000000 | val)
    else:
        return struct.pack("!Q", 0xc000000000000000 | val)

def build_quic_initial(dcid: bytes, scid: bytes, sni: str = "engage.cloudflareclient.com", token: bytes = b"") -> bytes:
    """构造符合 RFC 9000 标准的 QUIC v1 Initial 握手报文 (含 TLS 1.3 ClientHello, 最小填充 1200 字节)"""
    first_byte = 0xc0  # Header Form=1, Fixed=1, Long Packet Type=0 (Initial), Reserved=0, Packet Number Len=1
    version = struct.pack("!I", 0x00000001)  # QUIC v1
    dcid_len = bytes([len(dcid)])
    scid_len = bytes([len(scid)])
    token_len_varint = build_varint(len(token))
    
    # 构造 TLS 1.3 ClientHello 扩展与内容
    sni_bytes = sni.encode("utf-8")
    sni_ext = (
        b"\x00\x00" +
        struct.pack("!H", len(sni_bytes) + 5) +
        struct.pack("!H", len(sni_bytes) + 3) +
        b"\x00" +
        struct.pack("!H", len(sni_bytes)) +
        sni_bytes
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
    ch_body = b"\x03\x03" + client_random + b"\x20" + session_id + cipher_suites + compression + ext_bytes
    client_hello = b"\x01" + struct.pack("!I", len(ch_body))[1:] + ch_body
    
    # Crypto Frame: Type=0x06, Offset=0x00, Length=varint, Data=ClientHello
    crypto_frame = b"\x06\x00" + build_varint(len(client_hello)) + client_hello
    packet_number = b"\x01"
    payload = crypto_frame
    
    header_pre = bytes([first_byte]) + version + dcid_len + dcid + scid_len + scid + token_len_varint + token
    # 填充 Padding (0x00) 确保 Initial 报文总长度 >= 1200 字节 (RFC 9000 规定)
    curr_len = len(header_pre) + 2 + len(packet_number) + len(payload)
    if curr_len < 1200:
        payload += b"\x00" * (1200 - curr_len)
        
    payload_len_varint = build_varint(len(packet_number) + len(payload))
    header = bytes([first_byte]) + version + dcid_len + dcid + scid_len + scid + token_len_varint + token + payload_len_varint
    return header + packet_number + payload

def parse_quic_response(resp: bytes):
    """解析服务端返回的 QUIC 报文头部类型与字段"""
    if len(resp) < 5:
        return {"valid": False, "desc": "报文过短 (<5字节)"}
    
    hdr_byte = resp[0]
    is_long = bool(hdr_byte & 0x80)
    pkt_type = (hdr_byte & 0x30) >> 4
    ver = struct.unpack("!I", resp[1:5])[0]
    
    if not is_long:
        return {"valid": True, "is_long": False, "type": "1-RTT/ShortHeader", "ver": None}
    
    if ver == 0:
        return {"valid": True, "is_long": True, "type": "Version Negotiation", "ver": 0}
        
    type_map = {0: "Initial", 1: "0-RTT", 2: "Handshake", 3: "Retry"}
    pkt_name = type_map.get(pkt_type, f"Unknown(Type={pkt_type})")
    
    result = {"valid": True, "is_long": True, "type": pkt_name, "ver": ver}
    
    if pkt_type == 3:  # Retry
        try:
            dcid_len = resp[5]
            offset = 6 + dcid_len
            scid_len = resp[offset]
            offset += 1
            server_scid = resp[offset:offset+scid_len]
            offset += scid_len
            token = resp[offset:-16]  # 去掉末尾 16 字节 Retry Integrity Tag
            result["server_scid"] = server_scid
            result["token"] = token
        except Exception:
            pass
            
    return result

def test_single_endpoint(target_ip: str, port: int, local_ip: str = "", timeout: float = 2.5, retries: int = 2, sni: str = "engage.cloudflareclient.com"):
    """测试单个 IP:PORT 的 MASQUE 双阶段协商流程"""
    print(f"\n{CYAN}------------------------------------------------------------{RESET}")
    print(f"{BOLD}[*] 探测目标: {YELLOW}{target_ip}:{port}{RESET} | 协议: {PURPLE}MASQUE (QUIC v1){RESET} | 本地源IP: {local_ip or '默认'}")
    print(f"{CYAN}------------------------------------------------------------{RESET}")
    
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if local_ip:
        try:
            sock.bind((local_ip, 0))
        except Exception as e:
            print(f"{RED}[-] 绑定本地源 IP ({local_ip}) 失败: {e}{RESET}")
            sock.close()
            return False
            
    sock.settimeout(timeout)
    
    dcid = secrets.token_bytes(8)
    scid = secrets.token_bytes(8)
    pkt1 = build_quic_initial(dcid, scid, sni=sni)
    
    token = None
    new_dcid = None
    stage1_success = False
    
    print(f"[->] 第一阶段: 发送 Initial 探测包 (长度: {len(pkt1)} 字节)...")
    for attempt in range(1, retries + 1):
        t0 = time.time()
        try:
            sock.sendto(pkt1, (target_ip, port))
            resp, addr = sock.recvfrom(2048)
            rtt = (time.time() - t0) * 1000
            pinfo = parse_quic_response(resp)
            
            print(f"{GREEN}[<-] [第 {attempt} 次] 收到响应! 来自: {addr[0]}:{addr[1]} | 长度: {len(resp)} 字节 | RTT: {BOLD}{rtt:.2f} ms{RESET}")
            print(f"    └─ 报文类型: {BLUE}{pinfo.get('type')}{RESET} (格式: {'Long Header' if pinfo.get('is_long') else 'Short Header'})")
            
            if pinfo.get("type") == "Retry" and "token" in pinfo:
                token = pinfo["token"]
                new_dcid = pinfo["server_scid"]
                print(f"    └─ {GREEN}✅ 成功提取服务端 Retry Token ({len(token)} 字节) & 新 DCID: {new_dcid.hex()}{RESET}")
                stage1_success = True
            elif pinfo.get("type") in ("Initial", "Handshake"):
                print(f"    └─ {GREEN}✅ 服务端直接返回握手报文 (无需 Retry 校验)！{RESET}")
                stage1_success = True
            break
        except socket.timeout:
            print(f"{YELLOW}[-] [尝试 {attempt}/{retries}] 等待响应超时 (丢包/无应答)...{RESET}")
        except Exception as e:
            print(f"{RED}[-] 网络发送异常: {e}{RESET}")
            break
            
    if not stage1_success:
        print(f"{RED}[FAIL] 第一阶段 Initial 探测失败，目标未响应或大包被拦截。{RESET}")
        sock.close()
        return False
        
    if token and new_dcid:
        print(f"\n[->] 第二阶段: 携带 Retry Token 发送第二次 Initial 握手包 (长度: 1200 字节)...")
        pkt2 = build_quic_initial(new_dcid, scid, sni=sni, token=token)
        stage2_success = False
        
        for attempt in range(1, retries + 1):
            t0 = time.time()
            try:
                sock.sendto(pkt2, (target_ip, port))
                resp, addr = sock.recvfrom(2048)
                rtt = (time.time() - t0) * 1000
                pinfo = parse_quic_response(resp)
                
                print(f"{GREEN}[<-] 收到第二阶段握手响应! 长度: {len(resp)} 字节 | RTT: {BOLD}{rtt:.2f} ms{RESET}")
                print(f"    └─ 报文类型: {BLUE}{pinfo.get('type')}{RESET}")
                
                if pinfo.get("type") in ("Handshake", "Initial", "1-RTT/ShortHeader"):
                    print(f"{GREEN}{BOLD}[SUCCESS] 🎉 MASQUE/QUIC 双阶段握手完全成功！该 Endpoint 能够正常建立隧道连接。{RESET}")
                    stage2_success = True
                break
            except socket.timeout:
                print(f"{YELLOW}[-] [第二阶段尝试 {attempt}/{retries}] 等待 Handshake 响应超时 (大包丢包)...{RESET}")
            except Exception as e:
                print(f"{RED}[-] 第二阶段异常: {e}{RESET}")
                break
                
        sock.close()
        return stage2_success
        
    sock.close()
    return stage1_success

def main():
    parser = argparse.ArgumentParser(
        description="Cloudflare WARP MASQUE/QUIC 协议协商与连通性深度测试工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
使用示例:
  1. 测试默认官方 Endpoint (162.159.197.2) 的所有常用 MASQUE 端口:
     python3 test-masque.py -t 162.159.197.2

  2. 指定绑定物理网卡出网 IP (直连测试，绕过宿主机 TUN 代理):
     python3 test-masque.py -t 162.159.197.2 -i 172.19.4.28

  3. 测试指定端口 (例如 4443 和 8443):
     python3 test-masque.py -t 162.159.197.2 -p 4443,8443

  4. 批量测速探测多个优选 IP:
     python3 test-masque.py -t 162.159.192.1,162.159.193.10,162.159.195.1 -p 8443
"""
    )
    parser.add_argument("-t", "--target", default="162.159.197.2", help="目标 IP 地址或逗号分隔的 IP 列表 (默认: 162.159.197.2)")
    parser.add_argument("-p", "--ports", default="443,8443,4500,8095,500,1701,4443", help="待测试端口列表，逗号分隔 (默认: 443,8443,4500,8095,500,1701,4443)")
    parser.add_argument("-i", "--ip", default="", help="本地绑定的源 IP 地址 (用于在 TUN 环境下指定物理网卡 IP 直连)")
    parser.add_argument("-s", "--sni", default="engage.cloudflareclient.com", help="TLS ClientHello 伪装 SNI (默认: engage.cloudflareclient.com)")
    parser.add_argument("--timeout", type=float, default=2.5, help="单次请求超时时间 (秒，默认: 2.5)")
    parser.add_argument("--retries", type=int, default=2, help="单端口重试次数 (默认: 2)")
    
    args = parser.parse_args()
    
    targets = [ip.strip() for ip in args.target.split(",") if ip.strip()]
    try:
        ports = [int(p.strip()) for p in args.ports.split(",") if p.strip()]
    except ValueError:
        print(f"{RED}[ERROR] 端口参数格式不正确，必须为数字 (例如: 443,8443){RESET}")
        sys.exit(1)
        
    print(f"\n{BOLD}================================================================{RESET}")
    print(f"{BOLD}{GREEN}   Cloudflare WARP MASQUE (QUIC) 协议协商与连通性测试工具{RESET}")
    print(f"{BOLD}================================================================{RESET}")
    print(f"目标 IP 列表 : {', '.join(targets)}")
    print(f"测试端口列表 : {', '.join(map(str, ports))}")
    print(f"本地源 IP    : {args.ip or '系统默认路由分配'}")
    print(f"SNI 域名     : {args.sni}")
    print(f"超时 / 重试  : {args.timeout}s / {args.retries}次\n")
    
    summary = []
    
    for ip in targets:
        for p in ports:
            success = test_single_endpoint(
                target_ip=ip,
                port=p,
                local_ip=args.ip,
                timeout=args.timeout,
                retries=args.retries,
                sni=args.sni
            )
            summary.append((ip, p, success))
            
    print(f"\n\n{BOLD}=========================== 测试结果汇总 ==========================={RESET}")
    for ip, p, success in summary:
        status_str = f"{GREEN}✅ 握手成功 (可建立 MASQUE 隧道){RESET}" if success else f"{RED}❌ 握手失败 (超时/丢包){RESET}"
        print(f"  - {ip:<16}:{p:<5} --> {status_str}")
    print(f"{BOLD}===================================================================={RESET}\n")

if __name__ == "__main__":
    main()
