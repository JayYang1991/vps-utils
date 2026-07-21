import json
import yaml
import sys
import os
import argparse

# Sing-box 代理类型映射
PROXY_TYPES = {
    "vless", "vmess", "shadowsocks", "trojan", 
    "hysteria2", "tuic", "wireguard", "hysteria"
}

def convert_singbox_to_clash(outbound):
    otype = outbound.get('type')
    tag = outbound.get('tag')
    
    if otype == 'vless':
        proxy = {
            "name": tag,
            "type": "vless",
            "server": outbound.get('server'),
            "port": outbound.get('server_port'),
            "uuid": outbound.get('uuid'),
            "flow": outbound.get('flow', ""),
            "tls": outbound.get('tls', {}).get('enabled', False),
            "servername": outbound.get('tls', {}).get('server_name', ""),
            "client-fingerprint": outbound.get('tls', {}).get('utls', {}).get('fingerprint', 'chrome')
        }
        
        # Reality
        reality = outbound.get('tls', {}).get('reality', {})
        if reality.get('enabled'):
            proxy["reality-opts"] = {
                "public-key": reality.get('public_key'),
                "short-id": reality.get('short_id')
            }
        
        # Transport
        transport = outbound.get('transport', {})
        ttype = transport.get('type')
        if ttype == 'grpc':
            proxy["network"] = "grpc"
            proxy["grpc-opts"] = {
                "grpc-service-name": transport.get('service_name', 'grpc')
            }
        elif ttype == 'ws':
            proxy["network"] = "ws"
            proxy["ws-opts"] = {
                "path": transport.get('path', '/'),
                "headers": transport.get('headers', {})
            }
        return proxy

    elif otype == 'hysteria2':
        proxy = {
            "name": tag,
            "type": "hysteria2",
            "server": outbound.get('server'),
            "port": outbound.get('server_port'),
            "password": outbound.get('password'),
            "sni": outbound.get('tls', {}).get('server_name', ""),
            "skip-cert-verify": outbound.get('tls', {}).get('insecure', False)
        }
        obfs = outbound.get('obfs', {})
        if obfs:
            proxy["obfs"] = obfs.get('type')
            proxy["obfs-password"] = obfs.get('password')
        return proxy

    elif otype == 'shadowsocks':
        return {
            "name": tag,
            "type": "ss",
            "server": outbound.get('server'),
            "port": outbound.get('server_port'),
            "cipher": outbound.get('method'),
            "password": outbound.get('password')
        }

    elif otype == 'trojan':
        return {
            "name": tag,
            "type": "trojan",
            "server": outbound.get('server'),
            "port": outbound.get('server_port'),
            "password": outbound.get('password'),
            "sni": outbound.get('tls', {}).get('server_name', ""),
            "tls": outbound.get('tls', {}).get('enabled', True),
            "skip-cert-verify": outbound.get('tls', {}).get('insecure', False)
        }

    return None

def main():
    parser = argparse.ArgumentParser(description='Convert Sing-box configuration to Clash Verge format.')
    parser.add_argument('-i', '--input', help='Path to Sing-box client config', default='/etc/sing-box/config.json')
    parser.add_argument('-o', '--output', help='Path for the converted Clash YAML file', default='clash_config.yaml')
    args = parser.parse_args()

    sb_path = args.input
    output_path = args.output
    
    # 自动重定向测试路径 (保持原样)
    if not os.path.exists(sb_path) and os.path.exists("./singbox_client_config.json") and "etc" in sb_path:
        sb_path = "./singbox_client_config.json"
    elif not os.path.exists(sb_path) and os.path.exists("./config.json") and "etc" in sb_path:
        sb_path = "./config.json"

    if not os.path.exists(sb_path):
        print(f"Error: Sing-box config not found at {sb_path}")
        sys.exit(1)

    print(f"[*] Reading Sing-box config: {sb_path}")
    with open(sb_path, 'r') as f:
        sb_config = json.load(f)

    proxies = []
    proxy_names = []
    
    outbounds = sb_config.get('outbounds', [])
    for o in outbounds:
        if o.get('type') in PROXY_TYPES:
            clash_p = convert_singbox_to_clash(o)
            if clash_p:
                proxies.append(clash_p)
                proxy_names.append(clash_p['name'])

    if not proxies:
        print("Warning: No proxy outbounds found in Sing-box config.")
        sys.exit(1)

    # 自动提取 FakeIP 过滤域名 (扫描指向非 FakeIP 服务的 DNS 规则)
    fake_ip_filter = ["*.lan", "*.local", "*.arpa"]
    dns_rules = sb_config.get('dns', {}).get('rules', [])
    for rule in dns_rules:
        # 寻找指向 dns-direct 或非 dns-fakeip 的规则
        if rule.get('server') != 'dns-fakeip' and rule.get('action') == 'route':
            domains = rule.get('domain', [])
            if isinstance(domains, str): domains = [domains]
            fake_ip_filter.extend(domains)

            suffixes = rule.get('domain_suffix', [])
            if isinstance(suffixes, str): suffixes = [suffixes]
            for s in suffixes:
                if not s.startswith('.') and not s.startswith('*'):
                    fake_ip_filter.append(f"+.{s}")
                else:
                    fake_ip_filter.append(f"*{s}" if s.startswith('.') else s)
            
            # 处理正则转换 (简单处理通配符)
            regexes = rule.get('domain_regex', [])
            if isinstance(regexes, str): regexes = [regexes]
            for r in regexes:
                if r.startswith('^') and r.endswith('$'):
                    clean_r = r[1:-1].replace('\\.', '.').replace('.*', '*')
                    fake_ip_filter.append(clean_r)

    # 去重并保持顺序
    fake_ip_filter = list(dict.fromkeys(fake_ip_filter))

    # Clash 基础配置模板
    clash_template = {
        "port": 7890,
        "socks-port": 7891,
        "allow-lan": False,
        "mode": "rule",
        "log-level": "info",
        "dns": {
            "enabled": True,
            "ipv6": False,
            "default-nameserver": ["223.5.5.5", "119.29.29.29"],
            "enhanced-mode": "fake-ip",
            "fake-ip-range": "198.18.0.1/16",
            "fake-ip-filter": fake_ip_filter,
            "nameserver": ["https://dns.alidns.com/dns-query", "https://doh.pub/dns-query"],
            "fallback": ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]
        },
        "tun": {
            "enable": True,
            "stack": "system",
            "auto-route": True,
            "auto-detect-interface": True,
            "dns-hijack": ["any:53", "tcp://any:53"]
        },
        "proxies": proxies,
        "proxy-groups": [
            {
                "name": "🚀 节点选择",
                "type": "select",
                "proxies": ["⚡ 自动优选", "DIRECT"] + proxy_names
            },
            {
                "name": "⚡ 自动优选",
                "type": "url-test",
                "proxies": proxy_names,
                "url": "http://www.gstatic.com/generate_204",
                "interval": 300
            },
            {
                "name": "🐟 漏网之鱼",
                "type": "select",
                "proxies": ["🚀 节点选择", "DIRECT"]
            }
        ],
        "rules": [
            "DOMAIN,ntp.aliyun.com,DIRECT",
            "GEOSITE,cn,DIRECT",
            "GEOIP,cn,DIRECT",
            "GEOIP,private,DIRECT",
            "MATCH,🐟 漏网之鱼"
        ]
    }

    with open(output_path, 'w') as f:
        yaml.dump(clash_template, f, allow_unicode=True, sort_keys=False)

    print(f"[+] Successfully converted {len(proxies)} proxies.")
    print(f"[+] Clash config saved to: {output_path}")

if __name__ == "__main__":
    main()
