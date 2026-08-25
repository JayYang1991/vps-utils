#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
convert_sub_to_server.py
sing-box 订阅配置转 Server 模式转换脚本

功能：
1. 删除所有客户端路由与 DNS 规则 (route, dns, experimental)
2. outbounds 节点只保留 443 和 8443 端口的 vless+reality 协议节点 (支持自定义端口映射)
3. 8443 端口站点默认修改为 5000 端口，IP 修改为 127.0.0.1
4. 443 端口站点默认修改为 5001 端口，IP 修改为 127.0.0.1
5. 新增 1 个 vless+reality 入站端口（默认 12345）
6. 支持丰富的命令行参数配置与现有配置继承
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
        443: {"host": default_ip, "port": default_443}
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
    inbound_listen="::",
    inbound_domain=None,
    inbound_uuid=None,
    inbound_privkey=None,
    inbound_shortid=None,
    inbound_handshake_server=None,
    inbound_handshake_port=443,
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

    # 1. 删除所有客户端路由与 DNS 规则
    data.pop("route", None)
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

                # 重写 outbound 端口与目标 IP
                target_rule = mappings[server_port]
                ob["server"] = target_rule["host"]
                ob["server_port"] = target_rule["port"]

                # 补全 sing-box 1.8+ utls 规范
                if "utls" not in tls or not isinstance(tls["utls"], dict) or not tls["utls"].get("enabled"):
                    tls["utls"] = {"enabled": True, "fingerprint": "chrome"}

                filtered_outbounds.append(ob)

    if not filtered_outbounds:
        sys.stderr.write(f"[WARN] 警告: 未在订阅配置中检索到匹配端口 ({list(mappings.keys())}) 的 vless+reality 节点！\n")
    
    data["outbounds"] = filtered_outbounds

    # 3. 准备生成 1 个 vless+reality 入站节点 (默认 12345)
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

    inbound_block = {
        "type": "vless",
        "tag": "vless-reality-in",
        "listen": inbound_listen,
        "listen_port": int(inbound_port),
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
    }

    data["inbounds"] = [inbound_block]

    # 输出文件
    target_out = output_path or input_path
    with open(target_out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

    # 打印转换结果摘要
    print("================================================")
    print("✅ 配置文件已成功转换为 Server 转发模式！")
    print("================================================")
    print(f" 入站监听 : {inbound_listen}:{inbound_port} (VLESS + Reality)")
    print(f" 入站 SNI  : {final_domain}")
    print(f" 入站 UUID : {final_uuid}")
    print(f" 入站 ShortID: {final_shortid}")
    print(f" 路由状态 : 已清除所有路由规则 (直连全部出站)")
    print(f" 出站节点 : 保留 {len(filtered_outbounds)} 个 VLESS+Reality 转发节点:")
    for idx, ob in enumerate(filtered_outbounds, 1):
        print(f"   [{idx}] {ob.get('tag', 'vless-reality')} -> {ob.get('server')}:{ob.get('server_port')}")
    print("================================================")

    return target_out

def main():
    parser = argparse.ArgumentParser(description="sing-box 订阅转 Server 模式转换工具")
    parser.add_argument("-i", "--input", required=True, help="输入的 sing-box 订阅配置文件路径")
    parser.add_argument("-o", "--output", help="输出的配置文件路径 (默认直接覆盖输入文件)")
    parser.add_argument("-e", "--existing-config", default="/etc/sing-box/config.json", help="宿主机现有配置文件路径 (默认: /etc/sing-box/config.json)")
    parser.add_argument("--inbound-port", type=int, default=12345, help="VLESS Reality 入站监听端口 (默认: 12345)")
    parser.add_argument("--inbound-listen", default="::", help="入站监听地址 (默认: ::)")
    parser.add_argument("--inbound-domain", "--inbound-sni", dest="inbound_domain", help="入站 Reality 伪装域名/SNI")
    parser.add_argument("--inbound-uuid", help="入站 VLESS 用户 UUID")
    parser.add_argument("--inbound-privkey", "--inbound-private-key", dest="inbound_privkey", help="入站 Reality PrivateKey")
    parser.add_argument("--inbound-shortid", "--inbound-short-id", dest="inbound_shortid", help="入站 Reality Short ID")
    parser.add_argument("--inbound-handshake-server", help="入站 Reality Handshake Server 目标地址")
    parser.add_argument("--inbound-handshake-port", type=int, default=443, help="入站 Reality Handshake 目标端口 (默认: 443)")
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
            inbound_listen=args.inbound_listen,
            inbound_domain=args.inbound_domain,
            inbound_uuid=args.inbound_uuid,
            inbound_privkey=args.inbound_privkey,
            inbound_shortid=args.inbound_shortid,
            inbound_handshake_server=args.inbound_handshake_server,
            inbound_handshake_port=args.inbound_handshake_port,
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
