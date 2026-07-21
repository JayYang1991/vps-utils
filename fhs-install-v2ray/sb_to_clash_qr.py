import json
import yaml
import sys
import os
import argparse
import socket
import threading
import subprocess
from http.server import HTTPServer, SimpleHTTPRequestHandler

# Sing-box 代理类型映射
PROXY_TYPES = {
    "vless", "vmess", "shadowsocks", "trojan", 
    "hysteria2", "tuic", "wireguard", "hysteria"
}

def get_local_ip():
    """获取本机局域网 IP"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # 尝试连接公网 DNS 以获取出站接口 IP
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = '127.0.0.1'
    finally:
        s.close()
    return ip

def convert_singbox_to_clash(outbound):
    """将单个 Sing-box 出站转换为 Clash 代理格式"""
    otype = outbound.get('type')
    tag = outbound.get('tag')
    
    # 基础配置
    proxy = {
        "name": tag,
        "server": outbound.get('server'),
        "port": outbound.get('server_port'),
    }

    if otype == 'vless':
        proxy.update({
            "type": "vless",
            "uuid": outbound.get('uuid'),
            "flow": outbound.get('flow', ""),
            "tls": outbound.get('tls', {}).get('enabled', False),
            "servername": outbound.get('tls', {}).get('server_name', ""),
            "client-fingerprint": outbound.get('tls', {}).get('utls', {}).get('fingerprint', 'chrome')
        })
        
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
            proxy["grpc-opts"] = {"grpc-service-name": transport.get('service_name', 'grpc')}
        elif ttype == 'ws':
            proxy["network"] = "ws"
            proxy["ws-opts"] = {
                "path": transport.get('path', '/'),
                "headers": transport.get('headers', {})
            }
        
        # XUDP (Mihomo/Meta specific)
        if outbound.get('packet_encoding') == 'xudp':
            proxy['packet-encoding'] = 'xudp'

        return proxy

    elif otype == 'vmess':
        proxy.update({
            "type": "vmess",
            "uuid": outbound.get('uuid'),
            "alterId": outbound.get('alterId', 0),
            "cipher": outbound.get('security', 'auto'),
            "tls": outbound.get('tls', {}).get('enabled', False),
            "servername": outbound.get('tls', {}).get('server_name', "")
        })
        transport = outbound.get('transport', {})
        if transport.get('type') == 'ws':
            proxy["network"] = "ws"
            proxy["ws-opts"] = {"path": transport.get('path', '/'), "headers": transport.get('headers', {})}
        return proxy

    elif otype == 'hysteria2':
        proxy.update({
            "type": "hysteria2",
            "password": outbound.get('password'),
            "sni": outbound.get('tls', {}).get('server_name', ""),
            "skip-cert-verify": outbound.get('tls', {}).get('insecure', False)
        })
        obfs = outbound.get('obfs', {})
        if obfs:
            proxy["obfs"] = obfs.get('type')
            proxy["obfs-password"] = obfs.get('password')
        return proxy

    elif otype == 'shadowsocks':
        proxy.update({
            "type": "ss",
            "cipher": outbound.get('method'),
            "password": outbound.get('password')
        })
        return proxy

    elif otype == 'trojan':
        proxy.update({
            "type": "trojan",
            "password": outbound.get('password'),
            "sni": outbound.get('tls', {}).get('server_name', ""),
            "tls": outbound.get('tls', {}).get('enabled', True),
            "skip-cert-verify": outbound.get('tls', {}).get('insecure', False)
        })
        return proxy

    elif otype == 'tuic':
        proxy.update({
            "type": "tuic",
            "uuid": outbound.get('uuid'),
            "password": outbound.get('password'),
            "sni": outbound.get('tls', {}).get('server_name', ""),
            "alpn": outbound.get('tls', {}).get('alpn', ["h3"]),
            "congestion-controller": outbound.get('congestion_control', 'cubic'),
            "udp-relay-mode": "native"
        })
        return proxy

    return None

def start_share_server(file_path, port=8080):
    """启动一个简单的 HTTP 服务器共享文件"""
    class SingleFileHandler(SimpleHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/' + os.path.basename(file_path):
                return super().do_GET()
            else:
                self.send_response(404)
                self.end_headers()

    server = HTTPServer(('0.0.0.0', port), SingleFileHandler)
    thread = threading.Thread(target=server.serve_forever)
    thread.daemon = True
    thread.start()
    return server

def show_qr(url):
    """使用 npx qrcode-terminal 展示二维码"""
    print(f"[*] Generating QR code for: {url}")
    try:
        subprocess.run(["npx", "-y", "qrcode-terminal", url], check=True)
    except Exception as e:
        print(f"[!] Failed to show QR code via npx: {e}")
        print(f"[!] Please manually access the URL: {url}")

def main():
    parser = argparse.ArgumentParser(description='Convert Sing-box configuration to Clash Verge format and share.')
    parser.get_default('-v')
    parser.add_argument('-i', '--input', help='Path to Sing-box client config', default='/etc/sing-box/config.json')
    parser.add_argument('-o', '--output', help='Path for the converted Clash YAML file', default='clash_config.yaml')
    parser.add_argument('--share', action='store_true', help='Share the config via HTTP and show QR code')
    parser.add_argument('--port', type=int, default=10086, help='Port for the share server (default: 10086)')
    args = parser.parse_args()

    sb_path = args.input
    output_path = args.output
    
    # 自动重定向测试路径
    if not os.path.exists(sb_path):
        search_paths = ["./singbox_client_config.json", "./config.json", "/etc/sing-box/config.json"]
        for p in search_paths:
            if os.path.exists(p):
                sb_path = p
                break

    if not os.path.exists(sb_path):
        print(f"Error: Sing-box config not found.")
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
        print("Warning: No supported proxy outbounds found.")
        sys.exit(1)

    # Clash 基础配置模板 (Mihomo/Meta Style)
    clash_template = {
        "port": 7890,
        "socks-port": 7891,
        "allow-lan": True,
        "mode": "rule",
        "log-level": "info",
        "ipv6": False,
        "dns": {
            "enabled": True,
            "enhanced-mode": "fake-ip",
            "fake-ip-range": "198.18.0.1/16",
            "nameserver": ["https://dns.alidns.com/dns-query", "https://doh.pub/dns-query"],
            "fallback": ["https://1.1.1.1/dns-query", "8.8.8.8"]
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
            }
        ],
        "rules": [
            "DOMAIN,ntp.aliyun.com,DIRECT",
            "GEOIP,cn,DIRECT",
            "GEOIP,private,DIRECT",
            "MATCH,🚀 节点选择"
        ]
    }

    with open(output_path, 'w') as f:
        yaml.dump(clash_template, f, allow_unicode=True, sort_keys=False)

    print(f"[+] Successfully converted {len(proxies)} proxies.")
    print(f"[+] Clash config saved to: {output_path}")

    if args.share:
        local_ip = get_local_ip()
        share_url = f"http://{local_ip}:{args.port}/{os.path.basename(output_path)}"
        
        print(f"\n[!] Starting share server at {share_url}")
        server = start_share_server(output_path, args.port)
        
        show_qr(share_url)
        
        print("\n" + "="*50)
        print(f"Share URL: {share_url}")
        print("Keep this script running while importing to your phone.")
        print("Press Ctrl+C to stop the server.")
        print("="*50 + "\n")
        
        try:
            while True:
                import time
                time.sleep(1)
        except KeyboardInterrupt:
            print("\n[*] Stopping share server...")
            server.shutdown()

if __name__ == "__main__":
    main()
