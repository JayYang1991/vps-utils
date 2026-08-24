#!/usr/bin/env python3
import os
import subprocess
import glob
import csv
import sys
import collections
import re
import argparse
import ipaddress
import requests

# --- 配置区 ---
TG_TOOL = f'"{sys.executable}" ./telegram_tool.py'
DOWNLOAD_DIR = "./origin-iplist"
CFST_BIN = "./cfst"
FINAL_TXT = "ip_result.txt"

def is_valid_ip(ip_str):
    """验证是否为有效的 IPv4 或 IPv6 地址/网段（过滤域名及非法字符串）"""
    if not ip_str or not isinstance(ip_str, str):
        return False
    clean_ip = ip_str.strip().strip('[]')
    try:
        ipaddress.ip_network(clean_ip, strict=False)
        return True
    except (ValueError, AttributeError):
        return False

def run_command(cmd, description):
    print(f"==> {description}...")
    try:
        subprocess.run(cmd, shell=True, check=True)
    except subprocess.CalledProcessError:
        print(f"警告: {description} 执行任务中出现错误")

def get_latest_file(pattern):
    files = glob.glob(pattern)
    return max(files, key=os.path.getmtime) if files else None

def parse_source_file(file_path):
    """解析 IP:Port 格式文件，提取纯数字端口并保留原始备注"""
    port_groups = collections.defaultdict(list)
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line or ':' not in line:
                    continue
                
                parts = line.split(':', 1)
                ip = parts[0].strip()
                full_port_str = parts[1].strip()
                
                if not is_valid_ip(ip):
                    continue

                numeric_port_match = re.search(r'^(\d+)', full_port_str)
                if numeric_port_match:
                    numeric_port = numeric_port_match.group(1)
                    port_groups[numeric_port].append((ip, full_port_str))
    except Exception as e:
        print(f"解析原始文件失败: {e}")
    return port_groups

def get_val_from_row(row, mode):
    """根据模式从 CSV 行中提取下载速度或延迟"""
    if mode == 'speed':
        # 带宽模式关键词
        keywords = ['速度', 'Speed', 'MB/s']
        default = 0.0
    else:
        # 延迟模式关键词
        keywords = ['延迟', 'Delay', 'ms']
        default = 9999.0
    
    for key, value in row.items():
        if any(kw in key for kw in keywords):
            try:
                return float(value)
            except (ValueError, TypeError):
                continue
    return default

def check_file_exists_sudo(filepath: str) -> bool:
    """使用 sudo 提权检查文件是否存在（避免因父目录 700 权限导致普通用户 stat 失败）"""
    try:
        if os.path.exists(filepath):
            return True
    except (PermissionError, OSError):
        pass
    res = subprocess.run(["sudo", "test", "-f", filepath], capture_output=True)
    return res.returncode == 0

def read_file_sudo(filepath: str) -> str:
    """使用 sudo 提权读取文件内容"""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return f.read()
    except (PermissionError, FileNotFoundError, OSError):
        proc = subprocess.run(["sudo", "cat", filepath], capture_output=True, text=True, check=True)
        return proc.stdout

def write_file_sudo(filepath: str, content: str):
    """使用 sudo 提权写入文件内容并保持原有 600 权限"""
    try:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
            return
    except (PermissionError, FileNotFoundError, OSError):
        pass
    subprocess.run(["sudo", "tee", filepath], input=content, text=True, capture_output=True, check=True)
    subprocess.run(["sudo", "chmod", "600", filepath], capture_output=True)

def update_cloudflare_access_preferred_ip(best_ip: str, auto_yes: bool = False):
    """
    若宿主机上存在 cloudflare-access-tcp 配置 (/etc/cloudflare-access-tcp/access.env)，
    则提示用户确认后通过 sudo 提权将端口为 443 的最优 IP 填入 PREFERRED_IP 配置并重启服务；若不存在则静默跳过。
    """
    env_path = "/etc/cloudflare-access-tcp/access.env"
    if not check_file_exists_sudo(env_path):
        print("ℹ️ 未检测到 cloudflare-access-tcp 项目配置 (/etc/cloudflare-access-tcp/access.env)，跳过更新。")
        return

    if not is_valid_ip(best_ip):
        print(f"⚠️ 最优 443 端口 IP 格式无效 ({best_ip})，跳过 cloudflare-access-tcp 更新。")
        return

    try:
        # 1. sudo 提权读取现有配置文件内容
        content = read_file_sudo(env_path)

        # 2. 检查当前 PREFERRED_IP 是否已经是目标最优 IP
        curr_match = re.search(r'^PREFERRED_IP=(.*)$', content, re.MULTILINE)
        old_ip = curr_match.group(1).strip().strip('"').strip("'") if curr_match else ""
        if old_ip == best_ip:
            print(f"ℹ️ cloudflare-access-tcp 的 PREFERRED_IP 当前已是最优值 ({best_ip})，无需重复更新。")
            return

        # 3. 提示用户确认 (默认回车即确认更新)
        if not auto_yes:
            print("\n" + "=" * 65)
            print(f"📢 检测到 cloudflare-access-tcp 配置，准备将 443 端口最优 IP 同步写入：")
            print(f"   • 新优选 IP:   {best_ip}")
            print(f"   • 原配置 IP:   {old_ip or '未配置'}")
            print(f"   • 目标文件:    {env_path}")
            print("=" * 65)
            try:
                user_input = input("👉 是否确认更新 cloudflare-access-tcp 优选 IP 并重启服务？ [Y/n] (默认回车更新): ").strip().lower()
                if user_input not in ('', 'y', 'yes'):
                    print(f"⏸️ 已跳过 cloudflare-access-tcp 优选 IP 更新 (保留原值: {old_ip or '未配置'})。")
                    return
            except (KeyboardInterrupt, EOFError):
                print("\n⏸️ 用户取消操作，跳过 cloudflare-access-tcp 优选 IP 更新。")
                return

        print(f"\n==> 正在通过 sudo 提权将 443 端口最优 IP ({best_ip}) 写入 cloudflare-access-tcp 项目配置...")

        # 4. 替换或追加 PREFERRED_IP 行
        if re.search(r'^PREFERRED_IP=', content, re.MULTILINE):
            new_content = re.sub(r'^PREFERRED_IP=.*$', f'PREFERRED_IP={best_ip}', content, flags=re.MULTILINE)
        else:
            new_content = content.rstrip() + f"\nPREFERRED_IP={best_ip}\n"

        # 5. sudo 提权写入新配置
        write_file_sudo(env_path, new_content)
        print(f"✅ 已成功将 cloudflare-access-tcp 的 PREFERRED_IP 更新为: {best_ip} (原值: {old_ip or '未配置'})")

        # 6. 若 Systemd 服务处于运行中，自动重启服务使容器内静态映射立即生效
        check_sudo = subprocess.run(["sudo", "systemctl", "is-active", "--quiet", "cloudflare-access-tcp"], capture_output=True)
        if check_sudo.returncode == 0:
            print("🔄 检测到 cloudflare-access-tcp 服务正在运行，正在重启服务以使新优选 IP 立即生效...")
            subprocess.run(["sudo", "systemctl", "restart", "cloudflare-access-tcp"], check=False)
            print("✅ cloudflare-access-tcp 服务已成功重启并完成热重载！")
        else:
            check_svc = subprocess.run(["systemctl", "is-active", "--quiet", "cloudflare-access-tcp"], capture_output=True)
            if check_svc.returncode == 0:
                print("🔄 检测到 cloudflare-access-tcp 服务正在运行，正在重启服务以使新优选 IP 立即生效...")
                subprocess.run(["systemctl", "restart", "cloudflare-access-tcp"], check=False)
                print("✅ cloudflare-access-tcp 服务已成功重启并完成热重载！")
    except Exception as e:
        print(f"⚠️ 更新 cloudflare-access-tcp PREFERRED_IP 异常: {e}")

def upload_results(file_path):
    token = os.environ.get("CF_SUB_TOKEN")
    if not token:
        print("警告: 未找到环境变量 CF_SUB_TOKEN，跳过上传。")
        return

    url = "https://sub.19910417.xyz/api/update"
    print(f"==> 正在同步结果至订阅服务器 {url}...")
    
    try:
        with open(file_path, 'rb') as f:
            data = f.read()
        
        headers = {
            "Authorization": token,
            "Content-Type": "text/plain; charset=utf-8",
            "User-Agent": "Mozilla/5.0"
        }
        
        response = requests.put(url, data=data, headers=headers, timeout=15)
        if response.status_code == 200:
            print(f"✅ 同步成功: {response.text}")
        else:
            print(f"❌ 同步失败 (HTTP {response.status_code}): {response.text}")
    except Exception as e:
        print(f"❌ 同步过程中出现异常: {e}")

def fetch_sub_ips():
    url = "https://sub.19910417.xyz/sub?host=1&uuid=1"
    print(f"==> 正在从订阅服务器获取现有 IP 列表...")
    try:
        resp = requests.get(url, timeout=15)
        if resp.status_code == 200:
            import base64
            import urllib.parse
            # 订阅服务器返回的是 Base64 编码的 VLESS / Trojan 列表
            content = base64.b64decode(resp.text).decode('utf-8')
            lines = content.splitlines()
            ips = []
            for line in lines:
                line = line.strip()
                if line.startswith("vless://") or line.startswith("trojan://"):
                    # 提取 vless://uuid@address:port?...#remark
                    match = re.search(r'@([^?#]+).*#(.+)$', line)
                    if match:
                        addr_port = match.group(1)
                        # 解码 URL 编码的备注
                        remark = urllib.parse.unquote(match.group(2))
                        if ':' in addr_port:
                            addr = addr_port.split(':', 1)[0].strip()
                            if is_valid_ip(addr):
                                ips.append(f"{addr_port}#{remark}")
                elif ':' in line:
                    addr = line.split(':', 1)[0].strip()
                    if is_valid_ip(addr):
                        ips.append(line)
            print(f"✅ 从订阅服务器获取到 {len(ips)} 个现有 IP")
            return ips
        else:
            print(f"⚠️ 订阅服务器返回异常状态码: {resp.status_code}")
    except Exception as e:
        print(f"⚠️ 获取订阅 IP 失败: {e}")
    return []

def fetch_history_ips():
    token = os.environ.get("CF_SUB_TOKEN")
    url = "https://sub.19910417.xyz/api/history"
    if token:
        url = f"{url}?token={token}"
    print(f"==> 正在从订阅服务器获取历史 IP 记录...")
    try:
        headers = {
            "User-Agent": "Mozilla/5.0"
        }
        if token:
            headers["Authorization"] = token

        resp = requests.get(url, headers=headers, timeout=15)
        if resp.status_code == 200:
            data = resp.json()
            if data.get("success") and isinstance(data.get("data"), list):
                history_records = data["data"]
                history_ips = []
                for record in history_records:
                    if isinstance(record, dict) and "ips" in record:
                        for line in record.get("ips", []):
                            if line and ":" in line:
                                addr = line.split(':', 1)[0].strip()
                                if is_valid_ip(addr):
                                    history_ips.append(line.strip())
                print(f"✅ 从订阅服务器获取到 {len(history_ips)} 个历史 IP 记录")
                return history_ips
        else:
            print(f"⚠️ 获取历史 IP 失败 (HTTP {resp.status_code})")
    except Exception as e:
        print(f"⚠️ 获取历史 IP 出现异常: {e}")
    return []

def main():
    parser = argparse.ArgumentParser(description="集成测速与优选管理工具: 支持 Cloudflare CDN 优选与 WARP Endpoint 优选")
    parser.add_argument("--target", "-T", choices=['cdn', 'warp'], default='cdn',
                        help="优选目标类型: cdn (Cloudflare CDN/中转 IP 测速, 默认), warp (Cloudflare WARP Anycast Endpoint 优选)")
    
    # CDN 模式参数
    cdn_group = parser.add_argument_group("CDN 优选参数 (--target cdn)")
    cdn_group.add_argument("--mode", "-m", choices=['speed', 'latency'], default='speed', 
                           help="测速模式: speed (带宽模式, 默认), latency (延迟/httping模式)")
    cdn_group.add_argument("--min-speed", "-s", type=float, default=10.0, help="[带宽模式] 最小下载速度过滤 (MB/s, 默认: 10.0)")
    cdn_group.add_argument("--url", "--speedtest-url", dest="speedtest_url", default=os.getenv("CFST_URL", ""),
                           help="自定义测速地址 (如自建 Cloudflare Pages 测速 URL，如 https://xxx.pages.dev/20mb.bin, 默认读取环境变量 CFST_URL)")
    
    # WARP 模式参数
    warp_group = parser.add_argument_group("WARP 优选参数 (--target warp)")
    warp_group.add_argument("--warp-mode", choices=['fast', 'standard', 'full'], default='fast',
                            help="WARP 扫描模式: fast (快速抽样, 默认), standard (标准采样), full (全网段扫描)")
    warp_group.add_argument("--warp-ports", default="443,8443,4443,8095,4500,500,1701,2408",
                            help="WARP 待测端口列表 (默认: 443,8443,4443,8095,4500,500,1701,2408)")
    warp_group.add_argument("--concurrency", "-c", type=int, default=100, help="WARP 并发探测线程数 (默认: 100)")
    warp_group.add_argument("--rounds", "-r", type=int, default=3, help="WARP 单点探测轮数 (默认: 3 轮)")
    warp_group.add_argument("--format", choices=['txt', 'wireguard', 'singbox', 'clash', 'warp-cli'], default='txt',
                            help="WARP 结果导出格式 (默认: txt)")
    warp_group.add_argument("--ipv6", action="store_true", help="启用 IPv6 WARP Anycast 网段探测")
    warp_group.add_argument("--bind-ip", default="", help="本地绑定的出网源 IP 地址")

    # 通用参数
    parser.add_argument("--top", "-t", type=int, default=20, help="最终保留的最优 IP/端点数量 (默认: 20)")
    parser.add_argument("--yes", "-y", action="store_true", help="跳过确认提示，自动推送到 Cloudflare Workers 订阅服务器")
    args = parser.parse_args()

    # --- 若目标为 WARP Endpoint 优选 ---
    if args.target == 'warp':
        import warp_tester
        warp_output = "warp_result.txt"
        
        try:
            ports = [int(p.strip()) for p in args.warp_ports.split(",") if p.strip()]
        except ValueError:
            print("错误: WARP 端口格式不正确，必须为数字")
            return

        candidate_ips = warp_tester.generate_candidate_ips(
            scan_mode=args.warp_mode,
            include_ipv6=args.ipv6
        )

        results = warp_tester.scan_warp_endpoints(
            candidate_ips=candidate_ips,
            ports=ports,
            timeout=1.0,
            rounds=args.rounds,
            concurrency=args.concurrency,
            sni=warp_tester.DEFAULT_SNI,
            bind_ip=args.bind_ip
        )

        if not results:
            print("\n未能在任何 WARP 候选端点探测到有效响应。")
            return

        top_count = min(len(results), args.top)
        top_results = results[:top_count]

        # 保存 TXT
        txt_content = warp_tester.format_export_configs(top_results, "txt")
        with open(warp_output, 'w', encoding='utf-8') as f:
            f.write(txt_content + "\n")

        print(f"\n✨ WARP 优选测速完成！最优前 {len(top_results)} 个 Endpoint 已保存至 {warp_output}：")
        print("=" * 80)
        print(f" {'排名':<4} {'Endpoint (IP:Port)':<26} {'丢包率':<8} {'平均延迟':<12} {'最小延迟':<12} {'抖动':<10} {'协议'}")
        print("-" * 80)
        for i, r in enumerate(top_results):
            ip_port = f"{r['ip']}:{r['port']}"
            print(f" [{i+1:>2}] {ip_port:<26} {r['loss_rate']:>5.1f}%   {r['avg_rtt']:>7.2f} ms   {r['min_rtt']:>7.2f} ms   {r['jitter']:>6.2f} ms   {r['type']}")
        print("=" * 80)

        if args.format != 'txt':
            print(f"\n📋 已生成 [{args.format}] 客户端配置片段：")
            print("-" * 65)
            print(warp_tester.format_export_configs(top_results, args.format))
            print("-" * 65)

        # 挑选 WARP 测速中端口为 443 的最优 IP 并同步更新至 cloudflare-access-tcp (若存在)
        best_warp_443_ip = None
        best_warp_443_item = None
        for r in top_results:
            if str(r.get('port')) == '443' and is_valid_ip(r.get('ip')):
                best_warp_443_ip = r['ip']
                best_warp_443_item = r
                break

        if best_warp_443_ip:
            print(f"\n🎯 挑选出 WARP 端口 443 的最优 IP: {best_warp_443_ip} (平均延迟: {best_warp_443_item['avg_rtt']:.2f} ms)")
            update_cloudflare_access_preferred_ip(best_warp_443_ip, auto_yes=args.yes)

        # 确认并上传
        token = os.environ.get("CF_SUB_TOKEN")
        if not token:
            print(f"\n⚠️ 提示: 未配置环境变量 CF_SUB_TOKEN，跳过推送操作。WARP 优选结果已保存至 {warp_output}")
        else:
            if not args.yes:
                try:
                    user_input = input(f"\n👉 是否确认将以上 {len(top_results)} 个 WARP 优选端点推送到 Cloudflare Workers 订阅服务器？ [Y/n]: ").strip().lower()
                    if user_input not in ('', 'y', 'yes'):
                        print(f"⏸️ 已取消推送操作。优选结果已保留在 {warp_output}")
                        return
                except (KeyboardInterrupt, EOFError):
                    print(f"\n⏸️ 用户取消推送操作。优选结果已保留在 {warp_output}")
                    return

            warp_tester.upload_warp_results(warp_output)
        return

    # --- 以下为目标为 CDN 优选流程 ---
    # 1. 下载最新文件 (直接调用二进制)
    download_cmd = f"{TG_TOOL} download -n 'CF中转' --limit 1 -o {DOWNLOAD_DIR}"
    run_command(download_cmd, "从 Telegram 下载最新的 IP 列表")

    latest_file = get_latest_file(os.path.join(DOWNLOAD_DIR, "*.txt"))
    if not latest_file:
        print("错误: 未找到下载的文件")
        return
    print(f"识别到原始文件: {latest_file}")

    # 从 Telegram 下载完 IP 列表后提示用户断掉代理
    if not args.yes:
        print("\n" + "=" * 65)
        print("📢 提示: 从 Telegram 下载 IP 列表已完成！")
        print("⚡ 请【断开/关闭】您的代理服务（如 v2ray / sing-box / Clash 等），以确保后续测速准确。")
        print("=" * 65)
        try:
            input("👉 断开代理后，请按回车键 (Enter) 继续后续流程: ")
        except (KeyboardInterrupt, EOFError):
            print("\n⏸️ 用户取消操作，流程终止。")
            return

    # 2. 解析文件并合并订阅列表与历史 IP
    groups = parse_source_file(latest_file)
    
    # 解析完成后清理下载目录
    for txt_file in glob.glob(os.path.join(DOWNLOAD_DIR, "*.txt")):
        try:
            os.remove(txt_file)
        except Exception as e:
            print(f"清理下载文件失败: {txt_file}, {e}")

    # 合并订阅服务器现有 IP 列表
    sub_ips = fetch_sub_ips()
    sub_added = 0
    for entry in sub_ips:
        if ':' in entry:
            parts = entry.split(':', 1)
            ip = parts[0].strip()
            full_port_str = parts[1].strip()
            
            if not is_valid_ip(ip):
                continue

            numeric_port_match = re.search(r'^(\d+)', full_port_str)
            if numeric_port_match:
                port = numeric_port_match.group(1)
                # 避免重复添加 (根据 IP 和端口去重)
                if not any(ip == e[0] for e in groups[port]):
                    groups[port].append((ip, full_port_str))
                    sub_added += 1

    # 合并订阅服务器历史 IP 记录
    history_ips = fetch_history_ips()
    history_added = 0
    for entry in history_ips:
        if ':' in entry:
            parts = entry.split(':', 1)
            ip = parts[0].strip()
            full_port_str = parts[1].strip()
            
            if not is_valid_ip(ip):
                continue

            numeric_port_match = re.search(r'^(\d+)', full_port_str)
            if numeric_port_match:
                port = numeric_port_match.group(1)
                # 避免重复添加
                if not any(ip == e[0] for e in groups[port]):
                    groups[port].append((ip, full_port_str))
                    history_added += 1

    # 过滤掉没有有效 IP 的端口
    filtered_groups = collections.defaultdict(list)
    for port, entries in groups.items():
        valid_entries = [e for e in entries if is_valid_ip(e[0])]
        if valid_entries:
            filtered_groups[port] = valid_entries
    groups = filtered_groups

    total_ips = sum(len(v) for v in groups.values())
    print(f"==> 汇总 IP 数据池完成: TG 下载源 + 现有订阅 IP (新增 {sub_added} 个) + 历史 IP (新增 {history_added} 个)，共计 {total_ips} 个候选 IP 准备测速")

    if not any(groups.values()):
        print("错误: 没有有效的 IP:Port 数据进行测试")
        return

    all_results = []
    top_results = []

    # 3. 循环对每个端口进行测试
    print("\n==> 正在准备测速环境...")
    #run_command("sudo systemctl stop sing-box.service", "正在关闭 sing-box 代理")
    
    try:
        for port, entries in groups.items():
            print(f"\n--- 正在测试端口 {port} (共 {len(entries)} 个 IP, 模式: {args.mode}) ---")
            temp_ip_file = f"temp_ips_{port}.txt"
            temp_csv = f"result_{port}.csv"
            
            ip_to_original = {e[0]: e[1] for e in entries}
            
            try:
                # 写入临时 IP 列表
                with open(temp_ip_file, 'w') as f:
                    f.write("\n".join(e[0] for e in entries))
                
                # 构建测速命令
                url_flag = f' -url "{args.speedtest_url}"' if args.speedtest_url else ""
                if args.mode == 'speed':
                    # 带宽模式：测试下载速度 (测试前 20 名)，应用最小带宽过滤
                    cfst_cmd = f"{CFST_BIN} -f {temp_ip_file} -tp {port} -dn 20 -sl {args.min_speed}{url_flag} -o {temp_csv}"
                else:
                    # 延迟模式：仅 HTTPing 测速，增加 -dd 确保不进行下载测试
                    cfst_cmd = f"{CFST_BIN} -f {temp_ip_file} -tp {port} -httping -dd{url_flag} -o {temp_csv}"
                
                run_command(cfst_cmd, f"端口 {port} {args.mode} 测试中")
        
                # 解析测速结果
                if os.path.exists(temp_csv):
                    try:
                        with open(temp_csv, mode='r', encoding='utf-8-sig') as f:
                            reader = csv.DictReader(f)
                            for row in reader:
                                ip_addr = row.get('IP 地址') or row.get('IP Address') or list(row.values())[0]
                                val = get_val_from_row(row, args.mode)
                                
                                if ip_addr in ip_to_original:
                                    suffix = ip_to_original[ip_addr]
                                    # 追加 "自用"，如果不存在 # 则先添加 #
                                    new_suffix = f"{suffix}自用" if '#' in suffix else f"{suffix}#自用"
                                    all_results.append({
                                        'full_line': f"{ip_addr}:{new_suffix}",
                                        'val': val,
                                        'ip': ip_addr,
                                        'port': str(port)
                                    })
                    except Exception as e:
                        print(f"读取端口 {port} 结果失败: {e}")
            finally:
                if os.path.exists(temp_csv):
                    os.remove(temp_csv)
                if os.path.exists(temp_ip_file):
                    os.remove(temp_ip_file)

        # 4. 排序并处理结果
        # 如果是带宽模式，按值降序排序；如果是延迟模式，按值升序排序
        all_results.sort(key=lambda x: x['val'], reverse=(args.mode == 'speed'))
        
        top_count = min(len(all_results), args.top)
        top_results = all_results[:top_count]

        # 挑选端口为 443 的最优 IP
        best_443_ip = None
        best_443_item = None
        for item in all_results:
            if item.get('port') == '443' and is_valid_ip(item.get('ip')):
                best_443_ip = item['ip']
                best_443_item = item
                break

        # 5. 保存并打印结果
        if top_results:
            with open(FINAL_TXT, 'w') as f:
                for item in top_results:
                    f.write(f"{item['full_line']}\n")
            
            unit = "MB/s" if args.mode == 'speed' else "ms"
            print(f"\n✨ {args.mode} 模式测速完成！最优前 {len(top_results)} 个 IP 已保存至 {FINAL_TXT}：")
            print("=" * 65)
            for i, item in enumerate(top_results):
                print(f"  [{i+1:>2}] {item['full_line']:<35} - {item['val']:.2f} {unit}")
            print("=" * 65)

            # 同步更新 cloudflare-access-tcp 的 PREFERRED_IP (若存在配置)
            if best_443_ip:
                print(f"\n🎯 挑选出端口 443 的最优 IP: {best_443_ip} ({best_443_item['val']:.2f} {unit})")
                update_cloudflare_access_preferred_ip(best_443_ip, auto_yes=args.yes)
            else:
                print("\nℹ️ 本次测速未包含或未测出有效的 443 端口 IP，跳过 cloudflare-access-tcp 优选 IP 同步。")
    finally:
        #run_command("sudo systemctl start sing-box.service", "正在恢复 sing-box 代理")
        # 全局兜底清理残留的测速相关文件
        for f in glob.glob("temp_ips_*.txt") + glob.glob("result_*.csv"):
            try:
                os.remove(f)
            except:
                pass

    # 6. 确认并上传结果
    if top_results:
        token = os.environ.get("CF_SUB_TOKEN")
        if not token:
            print(f"\n⚠️ 提示: 未配置环境变量 CF_SUB_TOKEN，跳过推送操作。优选 IP 结果已保存至 {FINAL_TXT}")
        else:
            if not args.yes:
                try:
                    user_input = input(f"\n👉 是否确认将以上 {len(top_results)} 个优选 IP 推送到 Cloudflare Workers 订阅服务器？ [Y/n]: ").strip().lower()
                    if user_input not in ('', 'y', 'yes'):
                        print(f"⏸️ 已取消推送操作。优选 IP 结果已保留在 {FINAL_TXT}")
                        return
                except (KeyboardInterrupt, EOFError):
                    print(f"\n⏸️ 用户取消推送操作。优选 IP 结果已保留在 {FINAL_TXT}")
                    return
            
            upload_results(FINAL_TXT)
    else:
        print(f"\n未能在任何端口测得有效结果。")

if __name__ == "__main__":
    main()
