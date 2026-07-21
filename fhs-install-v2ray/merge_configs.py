import os
import sys
import json
import yaml
import argparse

# 支持的代理类型
PROXY_TYPES = {
    "vless", "vmess", "shadowsocks", "trojan", 
    "hysteria2", "tuic", "wireguard", "hysteria", 
    "shadowsocksr"
}

# Clash Verge 同步节点统一绑定网卡
CLASH_OUTBOUND_BIND_INTERFACE = "wlp4s0"

def convert_clash_to_singbox(proxy):
    name = proxy.get('name')
    ptype = proxy.get('type')
    
    if ptype == 'hysteria2':
        outbound = {
            "type": "hysteria2",
            "tag": name,
            "server": proxy.get('server'),
            "server_port": proxy.get('port'),
            "password": proxy.get('password'),
            "tls": {
                "enabled": True,
                "server_name": proxy.get('sni'),
                "insecure": proxy.get('skip-cert-verify', False)
            }
        }
        if proxy.get('obfs'):
            outbound["obfs"] = {
                "type": proxy.get('obfs'),
                "password": proxy.get('obfs-password')
            }
        if CLASH_OUTBOUND_BIND_INTERFACE:
            outbound["bind_interface"] = CLASH_OUTBOUND_BIND_INTERFACE
        return outbound
        
    elif ptype == 'vless':
        outbound = {
            "type": "vless",
            "tag": name,
            "server": proxy.get('server'),
            "server_port": proxy.get('port'),
            "uuid": proxy.get('uuid'),
            "flow": proxy.get('flow', ""),
            "tls": {
                "enabled": proxy.get('tls', False),
                "server_name": proxy.get('servername'),
                "insecure": proxy.get('skip-cert-verify', False),
                "utls": {
                    "enabled": True,
                    "fingerprint": proxy.get('client-fingerprint', 'chrome')
                }
            }
        }
        if proxy.get('reality-opts'):
            outbound["tls"]["reality"] = {
                "enabled": True,
                "public_key": proxy.get('reality-opts').get('public-key'),
                "short_id": proxy.get('reality-opts').get('short-id')
            }
        
        network = proxy.get('network')
        if network == 'grpc':
            outbound["transport"] = {
                "type": "grpc",
                "service_name": proxy.get('grpc-opts', {}).get('grpc-service-name', 'grpc')
            }
        elif network == 'ws':
             outbound["transport"] = {
                "type": "ws",
                "path": proxy.get('ws-opts', {}).get('path', '/'),
                "headers": proxy.get('ws-opts', {}).get('headers', {})
            }
        if CLASH_OUTBOUND_BIND_INTERFACE:
            outbound["bind_interface"] = CLASH_OUTBOUND_BIND_INTERFACE
        return outbound
    
    elif ptype == 'shadowsocks':
        outbound = {
            "type": "shadowsocks",
            "tag": name,
            "server": proxy.get('server'),
            "server_port": proxy.get('port'),
            "method": proxy.get('cipher'),
            "password": proxy.get('password')
        }
        if CLASH_OUTBOUND_BIND_INTERFACE:
            outbound["bind_interface"] = CLASH_OUTBOUND_BIND_INTERFACE
        return outbound
    
    elif ptype == 'trojan':
        outbound = {
            "type": "trojan",
            "tag": name,
            "server": proxy.get('server'),
            "server_port": proxy.get('port'),
            "password": proxy.get('password'),
            "tls": {
                "enabled": True,
                "server_name": proxy.get('sni') or proxy.get('servername'),
                "insecure": proxy.get('skip-cert-verify', False)
            }
        }
        if CLASH_OUTBOUND_BIND_INTERFACE:
            outbound["bind_interface"] = CLASH_OUTBOUND_BIND_INTERFACE
        return outbound

    return None

def main():
    parser = argparse.ArgumentParser(description='Merge Clash proxies into Sing-box configuration.')
    parser.add_argument('-s', '--singbox', help='Path to Sing-box client config', default='/etc/sing-box/config.json')
    parser.add_argument('-c', '--clash', help='Path to Clash config (YAML)')
    parser.add_argument('-o', '--output', help='Path for the merged output file', default='merged_config.json')
    args = parser.parse_args()

    sb_path = args.singbox
    clash_path = args.clash
    output_path = args.output
    
    # 自动定位默认路径逻辑 (保持原样)
    if not os.path.exists(sb_path) and os.path.exists("./singbox_client_config.json") and "etc" in sb_path:
        sb_path = "./singbox_client_config.json"
    
    if not clash_path:
        # 寻找 Clash Verge 默认配置文件路径
        possible_clash_paths = [
            os.path.expanduser("~/.config/clash/config.yaml"),
            os.path.expanduser("~/.local/share/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml"),
            os.path.expanduser("~/.config/clash-verge/clash-verge.yaml"),
            "./clash-verge.yaml"
        ]
        for p in possible_clash_paths:
            if os.path.exists(p):
                clash_path = p
                break
    
    if not clash_path:
        print("Error: Clash config path not specified and not found in common locations.")
        sys.exit(1)

    if not os.path.exists(sb_path):
        print(f"Error: Sing-box config not found at {sb_path}")
        sys.exit(1)
    if not os.path.exists(clash_path):
        print(f"Error: Clash config not found at {clash_path}")
        sys.exit(1)

    print(f"[*] Reading Sing-box config: {sb_path}")
    print(f"[*] Reading Clash config: {clash_path}")

    with open(sb_path, 'r') as f:
        sb_config = json.load(f)
    
    with open(clash_path, 'r') as f:
        clash_config = yaml.safe_load(f)
    
    # 分类 Sing-box 原有的 outbounds
    old_outbounds = sb_config.get('outbounds', [])
    non_proxy_outbounds = [] # direct, dns 等
    original_proxies = {}   # tag -> config
    
    # 按照在原配置中的出现顺序记录
    for o in old_outbounds:
        tag = o.get('tag')
        if o.get('type') in PROXY_TYPES:
            original_proxies[tag] = o
        elif tag not in ["Clash-Auto", "Auto-Select-All"]:
            non_proxy_outbounds.append(o)
    
    # 转换 Clash 代理节点
    clash_proxies = clash_config.get('proxies', [])
    new_clash_outbounds = []
    new_clash_tags = []
    
    for p in clash_proxies:
        sb_out = convert_clash_to_singbox(p)
        if sb_out:
            tag = sb_out['tag']
            # 如果存在同名节点，则从原有代理池中移除（标记为已由 Clash 替换）
            if tag in original_proxies:
                print(f"[*] Overwriting existing proxy: {tag}")
                del original_proxies[tag]
            
            new_clash_outbounds.append(sb_out)
            new_clash_tags.append(tag)
    
    # 剩余的 original_proxies 就是没被 Clash 替换的 SB 节点
    remaining_sb_proxies = list(original_proxies.values())
    remaining_sb_tags = [o.get('tag') for o in remaining_sb_proxies]
    
    # 构建最终的 outbounds 列表
    # 顺序：基础出站 (direct等) -> Clash 节点 -> Sing-box 剩余节点 -> 策略组
    final_outbounds = non_proxy_outbounds + new_clash_outbounds + remaining_sb_proxies
    
    all_proxy_tags = new_clash_tags + remaining_sb_tags
    all_proxy_tags_set = set(all_proxy_tags)
    
    if not all_proxy_tags:
        print("Warning: No proxy nodes found.")
    else:
        # 创建自动选择组
        group_tag = "Auto-Select-All"
        urltest_group = {
            "type": "urltest",
            "tag": group_tag,
            "outbounds": all_proxy_tags + ["direct"],
            "url": "http://www.gstatic.com/generate_204",
            "interval": "3m",
            "tolerance": 50
        }
        final_outbounds.append(urltest_group)
        
        # 优化：全局替换单节点引用为代理组
        print(f"[*] Optimizing proxy references (detour/outbound) to use group: {group_tag}")
        
        # 1. 替换 DNS detour
        dns_config = sb_config.get('dns', {})
        for server in dns_config.get('servers', []):
            if server.get('detour') in all_proxy_tags_set:
                server['detour'] = group_tag
        
        # 2. 替换 Route rules
        route_config = sb_config.get('route', {})
        for rule in route_config.get('rules', []):
            if rule.get('outbound') in all_proxy_tags_set:
                rule['outbound'] = group_tag
        
        # 3. 强制 final 路由指向这个组
        if "route" in sb_config:
            sb_config["route"]["final"] = group_tag

    sb_config["outbounds"] = final_outbounds

    with open(output_path, 'w') as f:
        json.dump(sb_config, f, indent=2, ensure_ascii=False)
    
    print(f"[+] Successfully merged/replaced proxies.")
    print(f"[+] Target group '{group_tag}' contains {len(all_proxy_tags)} nodes.")
    print(f"[+] Saved to: {output_path}")

if __name__ == "__main__":
    main()
