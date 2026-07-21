#!/usr/bin/env python3
import json
import os
import subprocess
import csv
import sys
import copy

# ================= 配置部分 =================
# 默认输入文件路径
BESTCF_DIR = os.path.expanduser("~/user_data/tools/BestCF")
CUCC_IP_FILE = os.getenv("CUCC_IP_FILE", os.path.join(BESTCF_DIR, "cucc-ip.txt"))

# 优先查找当前目录的 config.json，找不到再找 /etc/sing-box/config.json
DEFAULT_CONFIG_PATH = "./config.json" if os.path.exists("./config.json") else "/etc/sing-box/config.json"
CONFIG_JSON_FILE = os.getenv("CONFIG_JSON_FILE", DEFAULT_CONFIG_PATH)

# 默认输出文件路径
MERGED_IP_FILE = "./ip.txt"
RESULT_CSV_FILE = "./result.csv"
NEW_CONFIG_JSON_FILE = "./config.json"

# 目标 outbound 标签前缀
TAG_PREFIX = "cloudflare"
MAX_TAGS = 15
MIN_SPEED = 13.0  # 最低速度阈值 (MB/s)
EXTRA_RESULT_CSV = os.path.expanduser("~/user_data/tools/cfsppedtest/443/result.csv")
# ===========================================

import ipaddress

def is_valid_ip(address):
    """验证是否为有效的 IPv4 地址"""
    try:
        ipaddress.IPv4Address(address)
        return True
    except ValueError:
        return False

def load_text_ips(file_path):
    """从文本文件加载 IP 地址，处理 IP#标签 格式"""
    ips = set()
    if not os.path.exists(file_path):
        print(f"Warning: {file_path} 不存在。")
        return ips
    
    with open(file_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            
            # 处理 IP#标签 或 IP 为空的情况
            parts = line.split('#')
            ip = parts[0].strip()
            
            # 去掉 IPv6 的方括号以便验证
            clean_ip = ip.strip('[]')
            
            if is_valid_ip(clean_ip):
                ips.add(clean_ip)
            # 如果需要支持 IPv6，可以添加 elif is_valid_ipv6(clean_ip)
                
    return ips

def extract_ips_from_config(config_path):
    """从 sing-box 配置文件提取 outbound 中 443 端口的 IP"""
    ips = set()
    if not os.path.exists(config_path):
        print(f"Warning: {config_path} 不存在。")
        return ips
    
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            config = json.load(f)
            outbounds = config.get('outbounds', [])
            for ob in outbounds:
                tag = ob.get('tag', '')
                server = ob.get('server')
                port = ob.get('server_port')
                # 只提取标签以 cloudflare 开头且端口为 443 的 IP
                if tag.startswith(TAG_PREFIX) and port == 443 and server and is_valid_ip(server):
                    ips.add(server)
    except Exception as e:
        print(f"Error reading config: {e}")
    
    return ips

def run_cfst(ip_file):
    """执行 cfst 优选工具"""
    print(f"正在执行 cfst 优选测试，使用 IP 文件: {ip_file}...")
    cmd = [
        "cfst",
        "-f", ip_file,
        "-tp", "443",
        "-url", "https://speed.19910417.xyz/__down?bytes=100000000",
        "-httping",
        "-allip",
        "-n", "1000",
        "-sl", str(int(MIN_SPEED)),
        "-dn", "100"
    ]
    try:
        # 直接执行并显示输出
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as e:
        print(f"执行 cfst 出错: {e}")
        return False
    except FileNotFoundError:
        print("错误: 未找到 cfst 命令，请确保已安装并加入 PATH。")
        return False
    return True

def get_top_ips(csv_path, count=15, min_speed=13.0):
    """从 result.csv 提取速度大于 min_speed 的前 N 个 IP"""
    new_ips = []
    if not os.path.exists(csv_path):
        print(f"Error: {csv_path} 未生成。")
        return new_ips

    try:
        with open(csv_path, 'r', encoding='utf-8') as f:
            reader = csv.reader(f)
            header = next(reader) # 跳过表头
            # 标准 CloudflareSpeedTest CSV 格式:
            # IP 地址, 端口, 数据中心, 下载速度 (MB/s), 延迟 (ms), 测速时间
            # 下载速度通常在第 4 列 (index 3)
            for row in reader:
                if row and len(row) > 3:
                    try:
                        speed = float(row[5])
                        if speed >= min_speed:
                            new_ips.append(row[0])
                        else:
                            # 既然 CSV 是按速度降序排列的，如果当前速度小于阈值，后面的肯定也小于
                            break
                    except ValueError:
                        continue
                if len(new_ips) >= count:
                    break
    except Exception as e:
        print(f"解析 CSV 出错: {e}")

    return new_ips


def extract_ips_from_csv(file_path):
    """从 CSV 文件提取第一列的 IP 地址"""
    ips = set()
    if not os.path.exists(file_path):
        return ips
    
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            reader = csv.reader(f)
            try:
                next(reader)  # 跳过表头
                for row in reader:
                    if row:
                        ip = row[0].strip()
                        if is_valid_ip(ip):
                            ips.add(ip)
            except StopIteration:
                pass
    except Exception as e:
        print(f"Error reading CSV {file_path}: {e}")
    
    return ips

def update_singbox_config(original_config_path, new_ips, output_path):
    """更新配置文件中 443 端口且为 IPv4 的 IP，并支持扩展和更新 urltest-selector-tcp"""
    if not os.path.exists(original_config_path):
        print(f"Error: 找不到原始配置文件 {original_config_path}")
        return
    
    try:
        with open(original_config_path, 'r', encoding='utf-8') as f:
            config = json.load(f)
        
        if 'outbounds' not in config:
            config['outbounds'] = []
        outbounds = config['outbounds']
        
        # 1. 识别现有的符合条件的 (443 & IPv4) outbound 并寻找模板
        target_indices = []
        template_outbound = None
        max_tag_num = 0
        selector_index = -1
        
        # 优先寻找 cloudflare1 作为模板
        for ob in outbounds:
            if ob.get('tag') == f"{TAG_PREFIX}1":
                template_outbound = copy.deepcopy(ob)
                break

        for i, ob in enumerate(outbounds):
            tag = ob.get('tag', '')
            if tag == "urltest-selector-tcp":
                selector_index = i
                continue
                
            if tag.startswith(TAG_PREFIX):
                # 提取最大数字编号
                tag_num_str = tag[len(TAG_PREFIX):]
                if tag_num_str.isdigit():
                    max_tag_num = max(max_tag_num, int(tag_num_str))
                
                port = ob.get('server_port')
                server = ob.get('server', '')
                if port == 443 and is_valid_ip(server):
                    target_indices.append(i)
                    if template_outbound is None:
                        template_outbound = copy.deepcopy(ob)
        
        if not template_outbound and new_ips:
            print("Warning: 未找到符合条件的 outbound 或 cloudflare1 作为模板，无法扩展。")
            return

        updated_count = 0
        # 2. 覆盖现有的符合条件的项
        for i in range(min(len(target_indices), len(new_ips))):
            idx = target_indices[i]
            outbounds[idx]['server'] = new_ips[i]
            updated_count += 1
        
        # 3. 如果新 IP 数量超过现有项，进行扩展
        if len(new_ips) > len(target_indices):
            new_outbounds = []
            for i in range(len(target_indices), len(new_ips)):
                new_ob = copy.deepcopy(template_outbound)
                max_tag_num += 1
                new_ob['tag'] = f"{TAG_PREFIX}{max_tag_num}"
                new_ob['server'] = new_ips[i]
                new_outbounds.append(new_ob)
                updated_count += 1
            
            # 插入位置：如果有 selector，插在 selector 前面，否则追加到最后
            if selector_index != -1:
                for i, nob in enumerate(new_outbounds):
                    outbounds.insert(selector_index + i, nob)
            else:
                outbounds.extend(new_outbounds)
        
        # 4. 重新扫描所有 cloudflare 标签并更新 urltest-selector-tcp
        all_cf_tags = [ob.get('tag') for ob in outbounds if ob.get('tag', '').startswith(TAG_PREFIX)]
        all_cf_tags.sort(key=lambda x: int(x[len(TAG_PREFIX):]) if x[len(TAG_PREFIX):].isdigit() else 9999)
        
        for ob in outbounds:
            if ob.get('tag') == "urltest-selector-tcp":
                ob['outbounds'] = all_cf_tags
                break
        
        with open(output_path, 'w', encoding='utf-8') as f:
            json.dump(config, f, indent=2, ensure_ascii=False)
        
        print(f"成功更新/扩展了 {updated_count} 个 443 端口的 IPv4 地址到 {output_path}")
        
    except Exception as e:
        print(f"更新配置文件出错: {e}")
        import traceback
        traceback.print_exc()

def update_bestcf_repo():
    """更新 BestCF 仓库"""
    if not os.path.exists(BESTCF_DIR):
        print(f"Warning: BestCF 目录不存在 ({BESTCF_DIR})，跳过更新。")
        return

    print(f"正在尝试更新 BestCF 仓库: {BESTCF_DIR}...")
    try:
        # 使用 -C 指定目录执行 git pull
        result = subprocess.run(
            ["git", "-C", BESTCF_DIR, "pull"],
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode == 0:
            print("BestCF 仓库更新成功。")
            if "Already up to date" not in result.stdout:
                print(f"Git 输出: {result.stdout.strip()}")
        else:
            print(f"Warning: git pull 失败 (退出码 {result.returncode})。")
            print(f"错误详情: {result.stderr.strip()}")
    except subprocess.TimeoutExpired:
        print("Warning: git pull 超时，跳过。")
    except Exception as e:
        print(f"Warning: 更新仓库时出错: {e}")

def manage_singbox_service(action):
    """使用 sudo systemctl 管理 sing-box 服务"""
    if action not in ["stop", "start"]:
        return
    
    print(f"正在执行: sudo systemctl {action} sing-box...")
    try:
        subprocess.run(["sudo", "systemctl", action, "sing-box"], check=True)
    except subprocess.CalledProcessError as e:
        print(f"管理 sing-box 服务失败 ({action}): {e}")
    except FileNotFoundError:
        print("错误: 未找到 systemctl 命令。")

def main():
    # 0. 更新仓库
    update_bestcf_repo()

    # 1. 加载并合并 IP
    print("正在收集 IP 地址...")
    ips = load_text_ips(CUCC_IP_FILE)
    ips.update(extract_ips_from_config(CONFIG_JSON_FILE))
    
    # 新增：从额外结果文件合并 IP
    extra_ips = extract_ips_from_csv(EXTRA_RESULT_CSV)
    if extra_ips:
        print(f"从额外结果文件提取了 {len(extra_ips)} 个 IP。")
        ips.update(extra_ips)
    
    if not ips:
        print("未找到任何 IP 地址，退出。")
        sys.exit(1)
    
    with open(MERGED_IP_FILE, 'w', encoding='utf-8') as f:
        f.write('\n'.join(sorted(list(ips))))
    print(f"合并后的 IP 已保存至: {MERGED_IP_FILE} (共 {len(ips)} 个)")

    # 2. 运行 cfst
    # 在运行 cfst 之前关闭服务
    manage_singbox_service("stop")
    try:
        if run_cfst(MERGED_IP_FILE):
            # 3. 提取最优 IP (增加速度过滤)
            top_ips = get_top_ips(RESULT_CSV_FILE, MAX_TAGS, MIN_SPEED)
            if not top_ips:
                print(f"未提取到下载速度大于 {MIN_SPEED} MB/s 的优选 IP，未更新配置。")
            else:
                print(f"提取到前 {len(top_ips)} 个速度 > {MIN_SPEED} MB/s 的最优 IP: {', '.join(top_ips[:3])}...")
                
                # 4. 更新配置
                update_singbox_config(CONFIG_JSON_FILE, top_ips, NEW_CONFIG_JSON_FILE)
        else:
            print("优选测试失败，未更新配置。")
    finally:
        # 无论成功与否，最后都重新开启服务
        manage_singbox_service("start")

if __name__ == "__main__":
    # 允许通过命令行参数重写路径（可选）
    if len(sys.argv) > 1:
        CONFIG_JSON_FILE = sys.argv[1]
    if len(sys.argv) > 2:
        NEW_CONFIG_JSON_FILE = sys.argv[2]
        
    main()
