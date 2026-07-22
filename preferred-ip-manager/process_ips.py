#!/usr/bin/env python3
import os
import subprocess
import glob
import csv
import sys
import collections
import re
import argparse
import requests

# --- 配置区 ---
TG_TOOL = f'"{sys.executable}" ./telegram_tool.py'
DOWNLOAD_DIR = "./origin-iplist"
CFST_BIN = "./cfst"
FINAL_TXT = "ip_result.txt"

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
            # 订阅服务器返回的是 Base64 编码的 VLESS 列表
            content = base64.b64decode(resp.text).decode('utf-8')
            lines = content.splitlines()
            ips = []
            for line in lines:
                line = line.strip()
                if line.startswith("vless://"):
                    # 提取 vless://uuid@address:port?...#remark
                    match = re.search(r'@([^?#]+).*#(.+)$', line)
                    if match:
                        addr_port = match.group(1)
                        # 解码 URL 编码的备注
                        remark = urllib.parse.unquote(match.group(2))
                        ips.append(f"{addr_port}#{remark}")
            print(f"✅ 从订阅服务器获取到 {len(ips)} 个 IP")
            return ips
        else:
            print(f"⚠️ 订阅服务器返回异常状态码: {resp.status_code}")
    except Exception as e:
        print(f"⚠️ 获取订阅 IP 失败: {e}")
    return []

def main():
    parser = argparse.ArgumentParser(description="集成测速工具: 支持带宽模式和延迟模式")
    parser.add_argument("--mode", "-m", choices=['speed', 'latency'], default='speed', 
                        help="测速模式: speed (带宽模式, 默认), latency (延迟/httping模式)")
    parser.add_argument("--top", "-t", type=int, default=20, help="最终保留的最优 IP 数量 (默认: 20)")
    parser.add_argument("--min-speed", "-s", type=float, default=10.0, help="[带宽模式] 最小下载速度过滤 (MB/s, 默认: 10.0)")
    args = parser.parse_args()

    # 1. 下载最新文件 (直接调用二进制)
    download_cmd = f"{TG_TOOL} download -n 'CF中转' --limit 1 -o {DOWNLOAD_DIR}"
    run_command(download_cmd, "从 Telegram 下载最新的 IP 列表")

    latest_file = get_latest_file(os.path.join(DOWNLOAD_DIR, "*.txt"))
    if not latest_file:
        print("错误: 未找到下载的文件")
        return
    print(f"识别到原始文件: {latest_file}")

    # 2. 解析文件并合并订阅列表
    groups = parse_source_file(latest_file)
    
    # 解析完成后清理下载目录
    for txt_file in glob.glob(os.path.join(DOWNLOAD_DIR, "*.txt")):
        try:
            os.remove(txt_file)
        except Exception as e:
            print(f"清理下载文件失败: {txt_file}, {e}")

    sub_ips = fetch_sub_ips()
    for entry in sub_ips:
        if ':' in entry:
            parts = entry.split(':', 1)
            ip = parts[0].strip()
            full_port_str = parts[1].strip()
            
            numeric_port_match = re.search(r'^(\d+)', full_port_str)
            if numeric_port_match:
                port = numeric_port_match.group(1)
                # 避免重复添加 (根据 IP 和端口去重)
                if not any(ip == e[0] for e in groups[port]):
                    groups[port].append((ip, full_port_str))

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
                if args.mode == 'speed':
                    # 带宽模式：测试下载速度 (测试前 20 名)，应用最小带宽过滤
                    cfst_cmd = f"{CFST_BIN} -f {temp_ip_file} -tp {port} -dn 20 -sl {args.min_speed} -o {temp_csv}"
                else:
                    # 延迟模式：仅 HTTPing 测速，增加 -dd 确保不进行下载测试
                    cfst_cmd = f"{CFST_BIN} -f {temp_ip_file} -tp {port} -httping -dd -o {temp_csv}"
                
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
                                        'val': val
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

        # 5. 保存并打印结果
        if top_results:
            with open(FINAL_TXT, 'w') as f:
                for item in top_results:
                    f.write(f"{item['full_line']}\n")
            
            unit = "MB/s" if args.mode == 'speed' else "ms"
            print(f"\n✨ {args.mode} 模式测速完成！最优前 {len(top_results)} 个 IP 已保存至 {FINAL_TXT}")
            for i, item in enumerate(top_results):
                print(f"  [{i+1:>2}] {item['full_line']:<30} - {item['val']:.2f} {unit}")
    finally:
        #run_command("sudo systemctl start sing-box.service", "正在恢复 sing-box 代理")
        # 全局兜底清理残留的测速相关文件
        for f in glob.glob("temp_ips_*.txt") + glob.glob("result_*.csv"):
            try:
                os.remove(f)
            except:
                pass

    # 6. 上传结果
    if top_results:
        upload_results(FINAL_TXT)
    else:
        print(f"\n未能在任何端口测得有效结果。")

if __name__ == "__main__":
    main()
