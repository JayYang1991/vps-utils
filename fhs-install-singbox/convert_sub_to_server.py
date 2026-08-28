#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
convert_sub_to_server.py
sing-box 订阅配置转 Server 模式转换脚本

功能：
1. 清除原有客户端 DNS/Experimental 与默认路由，并配置精准入站分流路由规则
2. outbounds 节点只保留 443 和 8443 端口的 vless+reality 协议节点 (支持自定义端口映射)
3. 8443 端口站点默认修改为 5000 端口，IP 修改为 127.0.0.1 (tag: vless-out-5000)
4. 443 端口站点默认修改为 5001 端口，IP 修改为 127.0.0.1 (tag: vless-out-5001)
5. 新增 2 个 vless+reality 入站（默认 12345 和 12346 端口）与 1 个 SOCKS5 本地入站（默认 127.0.0.1:1080）
6. 自动配置分流路由规则：
   - OpenAI 与 Google AI 相关域名优先路由至 5001 出站 (vless-out-5001)
   - socks-in (1080) 与 vless-in-12345 其它流量路由至 5000 出站 (vless-out-5000)
   - vless-in-12346 请求路由至 5001 出站 (vless-out-5001)
7. 支持丰富的命令行参数配置与现有配置继承
"""

import sys
import os
import json
import argparse
import subprocess
import secrets
import uuid
import base64

def generate_reality_keypair():
    """生成 Reality X25519 密钥对 (优先使用 sing-box 命令，次选 Python cryptography)"""
    # 1. 优先调用 sing-box 命令
    try:
        res = subprocess.run(["sing-box", "generate", "reality-keypair"], capture_output=True, text=True)
        if res.returncode == 0:
            priv, pub = None, None
            for line in res.stdout.splitlines():
                if "PrivateKey:" in line:
                    priv = line.split(":", 1)[1].strip()
                elif "PublicKey:" in line:
                    pub = line.split(":", 1)[1].strip()
            if priv:
                return priv, pub
    except Exception:
        pass

    # 2. 调用 cryptography 库
    try:
        from cryptography.hazmat.primitives.asymmetric import x25519
        from cryptography.hazmat.primitives import serialization
        priv_key = x25519.X25519PrivateKey.generate()
        priv_bytes = priv_key.private_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PrivateFormat.Raw,
            encryption_algorithm=serialization.NoEncryption()
        )
        pub_key = priv_key.public_key()
        pub_bytes = pub_key.public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw
        )
        priv_b64 = base64.urlsafe_b64encode(priv_bytes).decode('utf-8').rstrip('=')
        pub_b64 = base64.urlsafe_b64encode(pub_bytes).decode('utf-8').rstrip('=')
        return priv_b64, pub_b64
    except Exception:
        pass

    # 3. 兜底随机 32 字节
    rand_bytes = secrets.token_bytes(32)
    return base64.urlsafe_b64encode(rand_bytes).decode('utf-8').rstrip('='), None

def extract_from_existing_config(config_path):
    """从宿主机现有配置文件中提取 Reality 入站参数与密钥"""
    info = {
        "uuid": None,
        "private_key": None,
        "short_id": None,
        "server_name": None
    }
    if not config_path or not os.path.exists(config_path):
        return info

    try:
        with open(config_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        
        inbounds = cfg.get("inbounds", [])
        for ib in inbounds:
            if isinstance(ib, dict) and ib.get("type") == "vless":
                tls = ib.get("tls", {})
                reality = tls.get("reality", {}) if isinstance(tls, dict) else {}
                if isinstance(reality, dict) and reality.get("enabled") and reality.get("private_key"):
                    info["private_key"] = reality.get("private_key")
                    s_id = reality.get("short_id")
                    if isinstance(s_id, list) and len(s_id) > 0:
                        info["short_id"] = s_id[0]
                    elif isinstance(s_id, str):
                        info["short_id"] = s_id
                    info["server_name"] = tls.get("server_name")
                    
                    users = ib.get("users", [])
                    if isinstance(users, list) and len(users) > 0 and isinstance(users[0], dict):
                        info["uuid"] = users[0].get("uuid")
                    break
    except Exception as e:
        sys.stderr.write(f"[WARN] 读取现有配置文件提取参数失败: {e}\n")

    return info

def parse_port_mappings(mapping_str, default_8443, default_443, default_ip):
    """
    解析端口映射规则。
    默认: 8443 -> default_ip:default_8443 (5000), 443 -> default_ip:default_443 (5001)
    支持格式:
      '8443:5000,443:5001'
      '8443:127.0.0.1:5000,443:127.0.0.1:5001'
    """
    mappings = {
        8443: {"host": default_ip, "port": default_8443},
        443: {"host": default_ip, "port": default_443},
        default_8443: {"host": default_ip, "port": default_8443},
        default_443: {"host": default_ip, "port": default_443}
    }

    if not mapping_str:
        return mappings

    rules = [r.strip() for r in mapping_str.split(",") if r.strip()]
    for r in rules:
        parts = r.split(":")
        if len(parts) == 2:
            try:
                src = int(parts[0])
                dst = int(parts[1])
                mappings[src] = {"host": default_ip, "port": dst}
            except ValueError:
                sys.stderr.write(f"[WARN] 忽略非法映射规则: {r}\n")
        elif len(parts) == 3:
            try:
                src = int(parts[0])
                host = parts[1]
                dst = int(parts[2])
                mappings[src] = {"host": host, "port": dst}
            except ValueError:
                sys.stderr.write(f"[WARN] 忽略非法映射规则: {r}\n")
    return mappings

def is_vless_reality(ob):
    """判断一个 outbound 节点是否为 VLESS + Reality 节点"""
    if not isinstance(ob, dict):
        return False
    if ob.get("type") != "vless":
        return False
    tls = ob.get("tls")
    if not isinstance(tls, dict) or not tls.get("enabled"):
        return False
    reality = tls.get("reality")
    if not isinstance(reality, dict):
        return False
    if reality.get("enabled") is True or reality.get("public_key"):
        return True
    return False

def convert_to_server_config(
    input_path,
    output_path=None,
    existing_config_path="/etc/sing-box/config.json",
    inbound_port=12345,
    inbound_port_2=12346,
    inbound_listen="::",
    inbound_domain=None,
    inbound_uuid=None,
    inbound_privkey=None,
    inbound_shortid=None,
    inbound_handshake_server=None,
    inbound_handshake_port=443,
    socks_port=1080,
    socks_listen="127.0.0.1",
    port_8443=5000,
    port_443=5001,
    target_ip="127.0.0.1",
    port_map_str=None
):
    if not os.path.exists(input_path):
        raise FileNotFoundError(f"未找到输入配置文件: {input_path}")

    with open(input_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    if not isinstance(data, dict):
        raise ValueError("配置文件内容不是合法的 JSON 对象")

    # 1. 删除旧客户端路由与 DNS 规则
    data.pop("dns", None)
    data.pop("experimental", None)

    # 确保 log 存在
    if "log" not in data or not isinstance(data["log"], dict):
        data["log"] = {"level": "info", "timestamp": True}
    else:
        data["log"]["timestamp"] = True

    # 解析端口映射
    mappings = parse_port_mappings(port_map_str, port_8443, port_443, target_ip)

    # 2. 筛选并重写 outbounds 节点
    original_outbounds = data.get("outbounds", [])
    filtered_outbounds = []
    port_to_outbound_tag = {}

    extracted_outbound_uuid = None
    extracted_outbound_domain = None
    extracted_outbound_shortid = None

    for ob in original_outbounds:
        if is_vless_reality(ob):
            try:
                server_port = int(ob.get("server_port", 0))
            except (ValueError, TypeError):
                continue

            if server_port in mappings:
                # 记录以备提取入站参数
                if not extracted_outbound_uuid and ob.get("uuid"):
                    extracted_outbound_uuid = ob.get("uuid")
                
                tls = ob.get("tls", {})
                if not extracted_outbound_domain and tls.get("server_name"):
                    extracted_outbound_domain = tls.get("server_name")
                
                reality = tls.get("reality", {})
                if not extracted_outbound_shortid:
                    s_id = reality.get("short_id")
                    if isinstance(s_id, list) and len(s_id) > 0:
                        extracted_outbound_shortid = s_id[0]
                    elif isinstance(s_id, str):
                        extracted_outbound_shortid = s_id

                # 重写 outbound 端口与目标 IP 并规范 tag
                target_rule = mappings[server_port]
                target_port = target_rule["port"]
                outbound_tag = f"vless-out-{target_port}"

                ob["tag"] = outbound_tag
                ob["server"] = target_rule["host"]
                ob["server_port"] = target_port
                port_to_outbound_tag[target_port] = outbound_tag

                # 补全 sing-box 1.8+ utls 规范
                if "utls" not in tls or not isinstance(tls["utls"], dict) or not tls["utls"].get("enabled"):
                    tls["utls"] = {"enabled": True, "fingerprint": "chrome"}

                filtered_outbounds.append(ob)

    # 严格校验：确保 5000 和 5001 端口对应的 VLESS 出站站点都存在
    missing_ports = []
    if port_8443 not in port_to_outbound_tag:
        missing_ports.append(f"{port_8443} 端口 (原 8443/{port_8443})")
    if port_443 not in port_to_outbound_tag:
        missing_ports.append(f"{port_443} 端口 (原 443/{port_443})")

    if missing_ports:
        raise ValueError(
            f"校验失败: 下载的配置文件中缺少必需的 VLESS 协议站点！\n"
            f"  缺失目标站点: {', '.join(missing_ports)}\n"
            f"  已检索到匹配站点: {[f'{port} (tag: {tag})' for port, tag in port_to_outbound_tag.items()]}\n"
            f"  Server 模式要求订阅源必须同时包含映射到 {port_8443} (原 8443) 和 {port_443} (原 443) 端口的 VLESS Reality 节点。"
        )

    data["outbounds"] = filtered_outbounds

    # 3. 准备生成入站节点 (SOCKS 1080 + VLESS 12345 + VLESS 12346)
    existing_info = extract_from_existing_config(existing_config_path)

    # 决策 UUID
    final_uuid = inbound_uuid or existing_info["uuid"] or extracted_outbound_uuid or str(uuid.uuid4())

    # 决策 Domain / SNI
    final_domain = inbound_domain or existing_info["server_name"] or extracted_outbound_domain or "www.cloudflare.com"

    # 决策 PrivateKey
    final_privkey = inbound_privkey or existing_info["private_key"]
    if not final_privkey:
        final_privkey, _ = generate_reality_keypair()

    # 决策 Short ID
    final_shortid = inbound_shortid or existing_info["short_id"] or extracted_outbound_shortid or secrets.token_hex(4)

    # 决策 Handshake Server & Port
    final_handshake_server = inbound_handshake_server or final_domain
    final_handshake_port = int(inbound_handshake_port or 443)

    inbound_blocks = []
    vless_1_tag = f"vless-in-{inbound_port}"
    vless_2_tag = f"vless-in-{inbound_port_2}" if inbound_port_2 and int(inbound_port_2) > 0 else None

    # (1) SOCKS5 入站 (默认 1080 本地监听)
    if socks_port and int(socks_port) > 0:
        actual_socks_listen = socks_listen if socks_listen else "127.0.0.1"
        inbound_blocks.append({
            "type": "socks",
            "tag": "socks-in",
            "listen": actual_socks_listen,
            "listen_port": int(socks_port),
            "sniff": True
        })

    # (2) VLESS + Reality 入站 1 (默认 12345 端口 -> 路由至 5000)
    inbound_blocks.append({
        "type": "vless",
        "tag": vless_1_tag,
        "listen": inbound_listen,
        "listen_port": int(inbound_port),
        "sniff": True,
        "users": [
            {
                "uuid": final_uuid,
                "flow": "xtls-rprx-vision"
            }
        ],
        "tls": {
            "enabled": True,
            "server_name": final_domain,
            "reality": {
                "enabled": True,
                "handshake": {
                    "server": final_handshake_server,
                    "server_port": final_handshake_port
                },
                "private_key": final_privkey,
                "short_id": [
                    final_shortid
                ]
            }
        }
    })

    # (3) VLESS + Reality 入站 2 (默认 12346 端口 -> 路由至 5001)
    if vless_2_tag:
        inbound_blocks.append({
            "type": "vless",
            "tag": vless_2_tag,
            "listen": inbound_listen,
            "listen_port": int(inbound_port_2),
            "sniff": True,
            "users": [
                {
                    "uuid": final_uuid,
                    "flow": "xtls-rprx-vision"
                }
            ],
            "tls": {
                "enabled": True,
                "server_name": final_domain,
                "reality": {
                    "enabled": True,
                    "handshake": {
                        "server": final_handshake_server,
                        "server_port": final_handshake_port
                    },
                    "private_key": final_privkey,
                    "short_id": [
                        final_shortid
                    ]
                }
            }
        })

    data["inbounds"] = inbound_blocks

    # 4. 配置分流路由规则
    # 出站目标 tag (安全回退)
    available_tags = [ob.get("tag") for ob in filtered_outbounds if ob.get("tag")]
    target_out_5000 = port_to_outbound_tag.get(port_8443, f"vless-out-{port_8443}")
    target_out_5001 = port_to_outbound_tag.get(port_443, f"vless-out-{port_443}")

    if target_out_5000 not in available_tags and available_tags:
        target_out_5000 = available_tags[0]
    if target_out_5001 not in available_tags and available_tags:
        target_out_5001 = available_tags[-1]

    route_rules = []

    # 规则 1: OpenAI 与 Google AI 相关域名 -> 路由至 5001 端口出站
    ai_domain_suffixes = [
        # OpenAI 域名
        "openai.com",
        "chatgpt.com",
        "oaistatic.com",
        "oaiusercontent.com",
        "oaistatsig.com",
        "chat.com",
        "sora.com",
        "crixet.com",
        "chatgpt.site",
        "openai.com.cdn.cloudflare.net",
        "openaiapi-site.azureedge.net",
        "openaiassets.blob.core.windows.net",
        "openaicom-api-bdcpf8c6d2e9atf6.z01.azurefd.net",
        "openaicom.imgix.net",
        # Google AI / Gemini / DeepMind / Antigravity 域名
        "gemini.google.com",
        "bard.google.com",
        "ai.google.dev",
        "generativeai.google",
        "makersuite.google.com",
        "aistudio.google.com",
        "aistudio.google",
        "deepmind.com",
        "deepmind.google",
        "ai.studio",
        "generativelanguage.googleapis.com",
        "geller-pa.googleapis.com",
        "proactivebackend-pa.googleapis.com",
        "robinfrontend-pa.googleapis.com",
        "alkalicore-pa.clients6.google.com",
        "alkalimakersuite-pa.clients6.google.com",
        "webchannel-alkalimakersuite-pa.clients6.google.com",
        "alkalicore-pa.googleapis.com",
        "alkalimakersuite-pa.googleapis.com",
        "antigravity.google",
        "antigravity-unleash.goog",
        "antigravity.googleapis.com",
        "antigravity-pa.googleapis.com",
        "aiplatform.googleapis.com",
        "aisandbox-pa.googleapis.com",
        "bard-pa.googleapis.com",
        "aida.googleapis.com",
        "cloudaicompanion.googleapis.com",
        "cloudcode-pa.googleapis.com",
        "firebasevertexai.googleapis.com",
        "gemini.gstatic.com"
    ]
    ai_domain_keywords = [
        "openai",
        "chatgpt",
        "antigravity"
    ]

    route_rules.append({
        "domain_suffix": ai_domain_suffixes,
        "domain_keyword": ai_domain_keywords,
        "outbound": target_out_5001
    })

    # 规则 2: socks-in (1080) 与 vless-in-12345 -> 路由至 5000 端口出站
    inbounds_5000 = []
    if socks_port and int(socks_port) > 0:
        inbounds_5000.append("socks-in")
    inbounds_5000.append(vless_1_tag)

    route_rules.append({
        "inbound": inbounds_5000,
        "outbound": target_out_5000
    })

    # 规则 3: vless-in-12346 -> 路由至 5001 端口出站
    if vless_2_tag:
        route_rules.append({
            "inbound": [vless_2_tag],
            "outbound": target_out_5001
        })

    data["route"] = {
        "rules": route_rules,
        "final": target_out_5000
    }

    # 输出文件
    target_out = output_path or input_path
    with open(target_out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

    # 打印转换结果摘要
    print("================================================")
    print("✅ 配置文件已成功转换为 Server 转发模式！")
    print("================================================")
    actual_socks_listen = socks_listen if socks_listen else "127.0.0.1"
    if socks_port and int(socks_port) > 0:
        print(f" 入站监听 [1] : {actual_socks_listen}:{socks_port} (SOCKS5 本地) -> 路由至 {target_out_5000}")
    print(f" 入站监听 [2] : {inbound_listen}:{inbound_port} (VLESS+Reality) -> 路由至 {target_out_5000}")
    if vless_2_tag:
        print(f" 入站监听 [3] : {inbound_listen}:{inbound_port_2} (VLESS+Reality) -> 路由至 {target_out_5001}")
    print(f" 入站 SNI    : {final_domain}")
    print(f" 入站 UUID   : {final_uuid}")
    print(f" 入站 ShortID: {final_shortid}")
    print(f" 路由分流规则:")
    print(f"   - 域名 [OpenAI & Google AI 相关域名] -> {target_out_5001}")
    print(f"   - 入站 [{', '.join(inbounds_5000)}] -> {target_out_5000}")
    if vless_2_tag:
        print(f"   - 入站 [{vless_2_tag}] -> {target_out_5001}")
    print(f" 出站节点 : 保留 {len(filtered_outbounds)} 个 VLESS+Reality 转发节点:")
    for idx, ob in enumerate(filtered_outbounds, 1):
        print(f"   [{idx}] {ob.get('tag')} -> {ob.get('server')}:{ob.get('server_port')}")
    print("================================================")

    return target_out

def main():
    parser = argparse.ArgumentParser(description="sing-box 订阅转 Server 模式转换工具")
    parser.add_argument("-i", "--input", required=True, help="输入的 sing-box 订阅配置文件路径")
    parser.add_argument("-o", "--output", help="输出的配置文件路径 (默认直接覆盖输入文件)")
    parser.add_argument("-e", "--existing-config", default="/etc/sing-box/config.json", help="宿主机现有配置文件路径 (默认: /etc/sing-box/config.json)")
    parser.add_argument("--inbound-port", "--inbound-port-1", type=int, default=12345, dest="inbound_port", help="VLESS Reality 入站 1 监听端口 (默认: 12345, 路由至 5000)")
    parser.add_argument("--inbound-port-2", type=int, default=12346, help="VLESS Reality 入站 2 监听端口 (默认: 12346, 路由至 5001)")
    parser.add_argument("--inbound-listen", default="::", help="入站监听地址 (默认: ::)")
    parser.add_argument("--inbound-domain", "--inbound-sni", dest="inbound_domain", help="入站 Reality 伪装域名/SNI")
    parser.add_argument("--inbound-uuid", help="入站 VLESS 用户 UUID")
    parser.add_argument("--inbound-privkey", "--inbound-private-key", dest="inbound_privkey", help="入站 Reality PrivateKey")
    parser.add_argument("--inbound-shortid", "--inbound-short-id", dest="inbound_shortid", help="入站 Reality Short ID")
    parser.add_argument("--inbound-handshake-server", help="入站 Reality Handshake Server 目标地址")
    parser.add_argument("--inbound-handshake-port", type=int, default=443, help="入站 Reality Handshake 目标端口 (默认: 443)")
    parser.add_argument("--socks-port", type=int, default=1080, help="SOCKS5 入站监听端口 (默认: 1080)")
    parser.add_argument("--socks-listen", default="127.0.0.1", help="SOCKS5 入站监听地址 (默认: 127.0.0.1)")
    parser.add_argument("--port-8443", type=int, default=5000, help="原 8443 节点映射的目标本地端口 (默认: 5000)")
    parser.add_argument("--port-443", type=int, default=5001, help="原 443 节点映射的目标本地端口 (默认: 5001)")
    parser.add_argument("--target-ip", default="127.0.0.1", help="节点重写的目标 IP 地址 (默认: 127.0.0.1)")
    parser.add_argument("--port-map", help="自定义端口映射规则，格式: '8443:5000,443:5001' 或 '8443:127.0.0.1:5000'")

    args = parser.parse_args()

    try:
        convert_to_server_config(
            input_path=args.input,
            output_path=args.output,
            existing_config_path=args.existing_config,
            inbound_port=args.inbound_port,
            inbound_port_2=args.inbound_port_2,
            inbound_listen=args.inbound_listen,
            inbound_domain=args.inbound_domain,
            inbound_uuid=args.inbound_uuid,
            inbound_privkey=args.inbound_privkey,
            inbound_shortid=args.inbound_shortid,
            inbound_handshake_server=args.inbound_handshake_server,
            inbound_handshake_port=args.inbound_handshake_port,
            socks_port=args.socks_port,
            socks_listen=args.socks_listen,
            port_8443=args.port_8443,
            port_443=args.port_443,
            target_ip=args.target_ip,
            port_map_str=args.port_map
        )
    except Exception as e:
        sys.stderr.write(f"[ERROR] 转换失败: {e}\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
