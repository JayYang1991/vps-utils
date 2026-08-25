#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
集成测速与优选管理工具 (Preferred IP & Endpoint Manager)
支持 Cloudflare CDN/中转 IP 测速 与 Cloudflare WARP Anycast Endpoint 优选。
内置深层大带宽挖掘（透传 -sl）、自适应双阶段保底（Auto-Fallback）、丢包率过滤（-tlr）、
端口按需过滤、敏感凭据脱敏以及与 cloudflare-access-tcp 和 Worker 的无缝同步。

GitHub: https://github.com/JayYang1991/vps-utils
"""

import os
import sys
import glob
import csv
import re
import argparse
import ipaddress
import subprocess
import tempfile
import collections
import urllib.parse
from typing import List, Dict, Tuple, Optional, Any
import datetime
import requests

# --- ANSI 终端颜色常量 ---
GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[0;33m"
CYAN = "\033[0;36m"
BOLD = "\033[1m"
RESET = "\033[0m"

def get_time_prefix() -> str:
    """获取当前格式化时间戳 [YYYY-MM-DD HH:MM:SS]"""
    return f"[{datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}]"

def log_info(msg: str):
    print(f"{get_time_prefix()} {GREEN}[INFO]{RESET} {msg}")

def log_warn(msg: str):
    print(f"{get_time_prefix()} {YELLOW}[WARN]{RESET} {msg}")

def log_error(msg: str):
    print(f"{get_time_prefix()} {RED}[ERROR]{RESET} {msg}", file=sys.stderr)

def log_step(msg: str):
    print(f"{get_time_prefix()} ==> {msg}...")

import shutil

# --- 默认全局配置与路径查找 ---
def find_cfst_binary() -> str:
    """动态查找 cfst 二进制可执行文件"""
    if os.getenv("CFST_BIN") and os.path.exists(os.getenv("CFST_BIN")):
        return os.getenv("CFST_BIN")
    which_cfst = shutil.which("cfst")
    if which_cfst:
        return which_cfst
    if os.path.exists("/usr/local/bin/cfst"):
        return "/usr/local/bin/cfst"
    script_dir = os.path.dirname(os.path.abspath(__file__))
    local_cfst = os.path.join(script_dir, "cfst")
    if os.path.exists(local_cfst):
        return local_cfst
    if os.path.exists("./cfst"):
        return "./cfst"
    return "cfst"

def find_telegram_tool() -> str:
    """动态查找 telegram_tool.py"""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    local_tg = os.path.join(script_dir, "telegram_tool.py")
    if os.path.exists(local_tg):
        return f'"{sys.executable}" "{local_tg}"'
    which_tg = shutil.which("telegram_tool.py")
    if which_tg:
        return f'"{sys.executable}" "{which_tg}"'
    if os.path.exists("/usr/local/bin/telegram_tool.py"):
        return f'"{sys.executable}" "/usr/local/bin/telegram_tool.py"'
    return f'"{sys.executable}" ./telegram_tool.py'

TG_TOOL = find_telegram_tool()
DOWNLOAD_DIR = "./origin-iplist"
CFST_BIN = find_cfst_binary()
FINAL_TXT = "ip_result.txt"
SUB_URL = os.getenv("CF_SUB_URL", "https://sub.19910417.xyz").rstrip('/')


# ==============================================================================
# 1. 基础辅助与脱敏函数
# ==============================================================================

def is_valid_ip(ip_str: Any) -> bool:
    """验证是否为有效的 IPv4 或 IPv6 地址/网段（过滤域名及非法字符串）"""
    if not ip_str or not isinstance(ip_str, str):
        return False
    clean_ip = ip_str.strip().strip('[]')
    try:
        ipaddress.ip_network(clean_ip, strict=False)
        return True
    except (ValueError, AttributeError):
        return False

def mask_token(token: str) -> str:
    """脱敏敏感凭据 (保留前4后4)"""
    if not token:
        return "未配置"
    if len(token) <= 8:
        return "******"
    return f"{token[:4]}****{token[-4:]}"

def mask_url(url: str) -> str:
    """脱敏 URL 中的 token 查询参数"""
    return re.sub(r'token=[^&]+', 'token=******', url)

def run_command(cmd: str, description: str):
    """执行 Shell 命令并输出状态"""
    log_step(description)
    try:
        subprocess.run(cmd, shell=True, check=True)
    except subprocess.CalledProcessError:
        log_warn(f"{description} 执行过程中返回非零状态码")


# ==============================================================================
# 2. 本地 cloudflare-access-tcp 提权配置与服务管理
# ==============================================================================

class LocalAccessTCPManager:
    """管理宿主机 cloudflare-access-tcp 项目的 PREFERRED_IP 提权写入与服务重启"""
    ENV_PATH = "/etc/cloudflare-access-tcp/access.env"

    @classmethod
    def check_file_exists(cls) -> bool:
        try:
            if os.path.exists(cls.ENV_PATH):
                return True
        except (PermissionError, OSError):
            pass
        res = subprocess.run(["sudo", "test", "-f", cls.ENV_PATH], capture_output=True)
        return res.returncode == 0

    @classmethod
    def read_config(cls) -> str:
        try:
            with open(cls.ENV_PATH, 'r', encoding='utf-8') as f:
                return f.read()
        except (PermissionError, FileNotFoundError, OSError):
            proc = subprocess.run(["sudo", "cat", cls.ENV_PATH], capture_output=True, text=True, check=True)
            return proc.stdout

    @classmethod
    def write_config(cls, content: str):
        subprocess.run(["sudo", "tee", cls.ENV_PATH], input=content, text=True, capture_output=True, check=True)
        subprocess.run(["sudo", "chmod", "600", cls.ENV_PATH], capture_output=True)

    @classmethod
    def sync_preferred_ip(cls, best_ip: str, auto_yes: bool = False):
        """将 443 端口最优 IP 同步到 cloudflare-access-tcp 并热重载服务"""
        if not cls.check_file_exists():
            log_info(f"未检测到 cloudflare-access-tcp 项目配置 ({cls.ENV_PATH})，跳过本地同步。")
            return

        if not is_valid_ip(best_ip):
            log_warn(f"最优 443 端口 IP 格式无效 ({best_ip})，跳过本地同步。")
            return

        try:
            content = cls.read_config()
            curr_match = re.search(r'^PREFERRED_IP=(.*)$', content, re.MULTILINE)
            old_ip = curr_match.group(1).strip().strip('"').strip("'") if curr_match else ""

            if old_ip == best_ip:
                log_info(f"cloudflare-access-tcp 的 PREFERRED_IP 当前已是最优值 ({best_ip})，无需重复更新。")
                return

            if not auto_yes:
                print("\n" + "=" * 65)
                print(f"📢 检测到 cloudflare-access-tcp 配置，准备将 443 端口最优 IP 同步写入：")
                print(f"   • 新优选 IP:   {GREEN}{BOLD}{best_ip}{RESET}")
                print(f"   • 原配置 IP:   {old_ip or '未配置'}")
                print(f"   • 目标文件:    {cls.ENV_PATH}")
                print("=" * 65)
                try:
                    user_input = input("👉 是否确认更新 cloudflare-access-tcp 优选 IP 并重启服务？ [Y/n] (默认回车更新): ").strip().lower()
                    if user_input not in ('', 'y', 'yes'):
                        log_info(f"已跳过 cloudflare-access-tcp 优选 IP 更新 (保留原值: {old_ip or '未配置'})。")
                        return
                except (KeyboardInterrupt, EOFError):
                    print("\n⏸️ 用户取消操作，跳过更新。")
                    return

            log_step(f"正在通过 sudo 提权将 443 端口最优 IP ({best_ip}) 写入配置")
            if re.search(r'^PREFERRED_IP=', content, re.MULTILINE):
                new_content = re.sub(r'^PREFERRED_IP=.*$', f'PREFERRED_IP={best_ip}', content, flags=re.MULTILINE)
            else:
                new_content = content.rstrip() + f"\nPREFERRED_IP={best_ip}\n"

            cls.write_config(new_content)
            log_info(f"已成功将 cloudflare-access-tcp 的 PREFERRED_IP 更新为: {best_ip}")

            # 检查并重启 Systemd 服务
            check_sudo = subprocess.run(["sudo", "systemctl", "is-active", "--quiet", "cloudflare-access-tcp"], capture_output=True)
            if check_sudo.returncode == 0:
                log_info("检测到 cloudflare-access-tcp 服务正在运行，正在重启服务以生效新优选 IP...")
                subprocess.run(["sudo", "systemctl", "restart", "cloudflare-access-tcp"], check=False)
                log_info("cloudflare-access-tcp 服务已成功重启并完成热重载！")
        except Exception as e:
            log_warn(f"更新 cloudflare-access-tcp PREFERRED_IP 异常: {e}")


# ==============================================================================
# 3. 订阅服务器交互模块 (WorkerSyncManager)
# ==============================================================================

class WorkerSyncManager:
    """负责与 Cloudflare Workers 订阅服务器的数据拉取与更新推送"""

    @staticmethod
    def get_auth_headers(token: Optional[str] = None) -> Dict[str, str]:
        headers = {
            "User-Agent": "Mozilla/5.0 (VPS-Utils; Preferred-IP-Manager)"
        }
        if token:
            headers["Authorization"] = token
        return headers

    @classmethod
    def fetch_sub_ips(cls) -> List[str]:
        """从订阅服务器拉取现有在线 VLESS/Trojan 节点 IP 列表"""
        url = f"{SUB_URL}/sub?host=1&uuid=1"
        log_step(f"正在从订阅服务器获取现有 IP 列表 ({mask_url(url)})")
        try:
            resp = requests.get(url, headers=cls.get_auth_headers(), timeout=15)
            if resp.status_code == 200:
                import base64
                content = base64.b64decode(resp.text).decode('utf-8')
                ips = []
                for line in content.splitlines():
                    line = line.strip()
                    if line.startswith("vless://") or line.startswith("trojan://"):
                        match = re.search(r'@([^?#]+).*#(.+)$', line)
                        if match:
                            addr_port = match.group(1)
                            remark = urllib.parse.unquote(match.group(2))
                            if ':' in addr_port:
                                addr = addr_port.split(':', 1)[0].strip()
                                if is_valid_ip(addr):
                                    ips.append(f"{addr_port}#{remark}")
                    elif ':' in line:
                        addr = line.split(':', 1)[0].strip()
                        if is_valid_ip(addr):
                            ips.append(line)
                log_info(f"从订阅服务器获取到 {len(ips)} 个现有 IP")
                return ips
            else:
                log_warn(f"订阅服务器返回异常状态码: {resp.status_code}")
        except Exception as e:
            log_warn(f"获取订阅 IP 失败: {e}")
        return []

    @classmethod
    def fetch_history_ips(cls) -> List[str]:
        """从订阅服务器拉取历史备份 IP 记录"""
        token = os.environ.get("CF_SUB_TOKEN")
        url = f"{SUB_URL}/api/history"
        log_step(f"正在从订阅服务器获取历史 IP 记录 ({mask_url(url)})")
        try:
            headers = cls.get_auth_headers(token)
            params = {"token": token} if token else {}
            resp = requests.get(url, headers=headers, params=params, timeout=15)
            if resp.status_code == 200:
                data = resp.json()
                if data.get("success") and isinstance(data.get("data"), list):
                    history_ips = []
                    for record in data["data"]:
                        if isinstance(record, dict) and "ips" in record:
                            for line in record.get("ips", []):
                                if line and ":" in line:
                                    addr = line.split(':', 1)[0].strip()
                                    if is_valid_ip(addr):
                                        history_ips.append(line.strip())
                    log_info(f"从订阅服务器获取到 {len(history_ips)} 个历史 IP 记录")
                    return history_ips
            else:
                log_warn(f"获取历史 IP 失败 (HTTP {resp.status_code})")
        except Exception as e:
            log_warn(f"获取历史 IP 出现异常: {e}")
        return []

    @classmethod
    def upload_cdn_results(cls, file_path: str):
        """将 CDN 优选结果上传至订阅服务器"""
        token = os.environ.get("CF_SUB_TOKEN")
        if not token:
            log_warn("未找到环境变量 CF_SUB_TOKEN，跳过推送至订阅服务器。")
            return

        url = f"{SUB_URL}/api/update?type=ips&mode=overwrite"
        log_step(f"正在同步 CDN 优选结果至订阅服务器 ({mask_url(url)})")
        try:
            with open(file_path, 'rb') as f:
                data = f.read()
            headers = cls.get_auth_headers(token)
            headers["Content-Type"] = "text/plain; charset=utf-8"
            resp = requests.put(url, data=data, headers=headers, timeout=15)
            if resp.status_code == 200:
                log_info(f"CDN 优选结果同步成功: {resp.text}")
            else:
                log_error(f"CDN 优选同步失败 (HTTP {resp.status_code}): {resp.text}")
        except Exception as e:
            log_error(f"同步过程中出现异常: {e}")


# ==============================================================================
# 4. 候选 IP 池管理模块 (IPSourceManager)
# ==============================================================================

class IPSourceManager:
    """管理 Telegram 下载源、在线订阅源与历史备份源的汇总与去重"""

    @staticmethod
    def parse_source_file(file_path: str) -> Dict[str, List[Tuple[str, str]]]:
        """解析 IP:Port#Remark 格式文件并按端口分组"""
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
                    match = re.search(r'^(\d+)', full_port_str)
                    if match:
                        port = match.group(1)
                        port_groups[port].append((ip, full_port_str))
        except Exception as e:
            log_error(f"解析原始文件失败: {e}")
        return port_groups

    @classmethod
    def collect_ips(cls, skip_tg: bool, input_file: Optional[str] = None, allowed_ports: Optional[List[str]] = None, auto_yes: bool = False, tg_proxy: str = "") -> Dict[str, List[Tuple[str, str]]]:
        """汇总候选 IP 池并根据端口白名单进行筛选"""
        groups = collections.defaultdict(list)
        file_ip_count = 0

        if input_file:
            if not os.path.exists(input_file):
                log_error(f"指定的本地 IP 列表文件不存在: {input_file}")
                return {}
            log_info(f"已指定本地 IP 列表文件: {input_file} (自动跳过 Telegram 下载流程)")
            groups = cls.parse_source_file(input_file)
            file_ip_count = sum(len(v) for v in groups.values())
            log_info(f"从指定本地文件中成功解析到 {file_ip_count} 个有效 IP 候选")
        elif not skip_tg:
            proxy_flag = f" --proxy '{tg_proxy}'" if tg_proxy else ""
            download_cmd = f"{TG_TOOL} download -n 'CF中转' --limit 1 -o {DOWNLOAD_DIR}{proxy_flag}"
            run_command(download_cmd, "从 Telegram 下载最新的 IP 列表")

            files = glob.glob(os.path.join(DOWNLOAD_DIR, "*.txt"))
            latest_file = max(files, key=os.path.getmtime) if files else None

            if not latest_file:
                log_error("未找到从 Telegram 下载的文件")
                return {}
            log_info(f"识别到 Telegram 原始文件: {latest_file}")

            if not auto_yes:
                print("\n" + "=" * 65)
                print("📢 提示: 从 Telegram 下载 IP 列表已完成！")
                print("⚡ 请【断开/关闭】您的代理服务（如 v2ray / sing-box / Clash 等），以确保后续测速准确。")
                print("=" * 65)
                try:
                    input("👉 断开代理后，请按回车键 (Enter) 继续后续流程: ")
                except (KeyboardInterrupt, EOFError):
                    print("\n⏸️ 用户取消操作，流程终止。")
                    return {}

            groups = cls.parse_source_file(latest_file)
            file_ip_count = sum(len(v) for v in groups.values())

            # 清理下载的临时文件
            for txt_file in glob.glob(os.path.join(DOWNLOAD_DIR, "*.txt")):
                try:
                    os.remove(txt_file)
                except Exception as e:
                    log_warn(f"清理临时文件失败: {txt_file}, {e}")
        else:
            log_info("已启用 --skip-tg 参数: 跳过 Telegram 文件下载，直接从订阅服务器拉取候选 IP 列表...")

        # 合并在线订阅 IP
        sub_ips = WorkerSyncManager.fetch_sub_ips()
        sub_added = 0
        for entry in sub_ips:
            if ':' in entry:
                parts = entry.split(':', 1)
                ip = parts[0].strip()
                full_port = parts[1].strip()
                if not is_valid_ip(ip):
                    continue
                match = re.search(r'^(\d+)', full_port)
                if match:
                    port = match.group(1)
                    if not any(ip == e[0] for e in groups[port]):
                        groups[port].append((ip, full_port))
                        sub_added += 1

        # 合并历史 IP
        history_ips = WorkerSyncManager.fetch_history_ips()
        history_added = 0
        for entry in history_ips:
            if ':' in entry:
                parts = entry.split(':', 1)
                ip = parts[0].strip()
                full_port = parts[1].strip()
                if not is_valid_ip(ip):
                    continue
                match = re.search(r'^(\d+)', full_port)
                if match:
                    port = match.group(1)
                    if not any(ip == e[0] for e in groups[port]):
                        groups[port].append((ip, full_port))
                        history_added += 1

        # 按端口白名单过滤
        filtered_groups = collections.defaultdict(list)
        for port, entries in groups.items():
            if allowed_ports and "all" not in allowed_ports and port not in allowed_ports:
                continue
            valid_entries = [e for e in entries if is_valid_ip(e[0])]
            if valid_entries:
                filtered_groups[port] = valid_entries

        total_ips = sum(len(v) for v in filtered_groups.values())
        if input_file:
            log_info(f"汇总 IP 数据池完成: 指定本地文件 ({file_ip_count} 个) + 现有订阅 IP (新增 {sub_added} 个) + 历史 IP (新增 {history_added} 个)，共计 {total_ips} 个候选 IP 准备测速")
        elif skip_tg:
            log_info(f"汇总 IP 数据池完成: [仅订阅源模式] 现有订阅 IP ({sub_added} 个) + 历史 IP ({history_added} 个)，共计 {total_ips} 个候选 IP 准备测速")
        else:
            log_info(f"汇总 IP 数据池完成: TG 下载源 ({file_ip_count} 个) + 现有订阅 IP (新增 {sub_added} 个) + 历史 IP (新增 {history_added} 个)，共计 {total_ips} 个候选 IP 准备测速")

        return filtered_groups


# ==============================================================================
# 5. CloudflareSpeedTest 测速与双阶段自适应保底引擎 (CFSTRunner)
# ==============================================================================

class CFSTRunner:
    """调度 cfst 执行深层大带宽探测与两阶段自适应保底降级"""

    @staticmethod
    def parse_csv_row(row: Dict[str, str]) -> Dict[str, Any]:
        """从 CSV 结果行中稳健提取所有关键指标 (IP, 速度, 延迟, 丢包率, 地区码)"""
        ip_addr = (row.get('IP 地址') or row.get('IP Address') or list(row.values())[0] or "").strip()

        speed = 0.0
        latency = 9999.0
        loss_rate = 0.0
        colo = "N/A"

        for key, value in row.items():
            if not key or value is None:
                continue
            k_lower = key.strip().lower()
            v_str = str(value).strip()
            if any(kw in k_lower for kw in ['速度', 'speed', 'mb/s', 'download']):
                try:
                    speed = float(v_str)
                except (ValueError, TypeError):
                    pass
            elif any(kw in k_lower for kw in ['延迟', 'delay', 'latency', 'ms']):
                try:
                    latency = float(v_str)
                except (ValueError, TypeError):
                    pass
            elif any(kw in k_lower for kw in ['丢包', 'loss']):
                try:
                    loss_rate = float(v_str)
                except (ValueError, TypeError):
                    pass
            elif any(kw in k_lower for kw in ['地区', 'colo', 'center', 'datacenter']):
                colo = v_str or "N/A"

        return {
            'ip': ip_addr,
            'speed': speed,
            'latency': latency,
            'loss_rate': loss_rate,
            'colo': colo
        }

    @classmethod
    def execute_cfst(cls, temp_ip_path: str, temp_csv_path: str, port: str, min_speed: float, args: argparse.Namespace) -> List[Dict[str, Any]]:
        """构建命令并执行一次 cfst 测速，返回解析后的各 IP 详细指标字典列表"""
        url_flag = f' -url "{args.speedtest_url}"' if args.speedtest_url else ""
        max_delay_flag = f' -tl {args.max_delay}' if args.max_delay else ""
        max_loss_flag = f' -tlr {args.max_loss}' if (hasattr(args, 'max_loss') and args.max_loss < 1.0) else ""
        download_time_flag = f' -dt {args.download_time}' if args.download_time else ""
        test_count_flag = f' -dn {args.test_count}' if args.test_count else " -dn 20"
        threads_flag = f' -n {args.concurrency}' if (hasattr(args, 'concurrency') and args.concurrency) else " -n 200"

        httping_flag = " -httping" if getattr(args, 'httping', False) else ""

        if args.mode == 'speed':
            cfst_cmd = f"{CFST_BIN} -f \"{temp_ip_path}\" -tp {port}{threads_flag}{test_count_flag}{download_time_flag}{max_delay_flag}{max_loss_flag} -sl {min_speed}{url_flag} -o \"{temp_csv_path}\""
        else:
            # latency 模式: 延迟优先排序，同时对前 -dn 个低延迟候选节点执行下载测速获取真实带宽
            cfst_cmd = f"{CFST_BIN} -f \"{temp_ip_path}\" -tp {port}{threads_flag}{test_count_flag}{download_time_flag}{max_delay_flag}{max_loss_flag}{httping_flag} -sl 0{url_flag} -o \"{temp_csv_path}\""

        # 详细打印调用 cfst 的完整命令行与参数解析明细
        log_info(f"即将调用测速核心 (cfst)，完整命令: {CYAN}{BOLD}{cfst_cmd}{RESET}")
        log_info(f"参数解析明细: [目标端口: {port}] [测速模式: {args.mode}] [并发线程数: {args.concurrency}] [达标队列数: {args.test_count}] [单点时长: {args.download_time}s] [速度下限: {min_speed} MB/s] [延迟上限: {args.max_delay if args.max_delay else '不限制'} ms] [丢包上限: {f'{args.max_loss*100:.0f}%' if args.max_loss < 1.0 else '不限制'}] [测速URL: {args.speedtest_url or '官方默认'}]")

        desc = f"端口 {port} {args.mode} 测试中 (下限: {min_speed:.2f} MB/s)" if (args.mode == 'speed' and min_speed > 0) else f"端口 {port} {args.mode} 测试中"
        run_command(cfst_cmd, desc)

        results = []
        if os.path.exists(temp_csv_path) and os.path.getsize(temp_csv_path) > 0:
            try:
                with open(temp_csv_path, mode='r', encoding='utf-8-sig') as f:
                    reader = csv.DictReader(f)
                    for row in reader:
                        parsed = cls.parse_csv_row(row)
                        if parsed['ip'] and is_valid_ip(parsed['ip']):
                            results.append(parsed)
            except Exception as e:
                log_warn(f"解析端口 {port} CSV 结果失败: {e}")
        return results

    @classmethod
    def test_port(cls, port: str, entries: List[Tuple[str, str]], args: argparse.Namespace) -> List[Dict[str, Any]]:
        """
        对单个端口执行测速：
        【阶段 1: 深层高带宽探测 (Deep Scan)】透传用户指定的 -sl，跨越延迟排序，持续往后测试挖掘深层大带宽低丢包节点；
        【阶段 2: 智能自适应保底 (Auto-Fallback)】若高门槛未凑够达标节点，自动以 -sl 0 保底重测，避免全盘落空。
        """
        print(f"\n--- 正在测试端口 {port} (共 {len(entries)} 个 IP, 模式: {args.mode}) ---")
        ip_to_original = {e[0]: e[1] for e in entries}

        with tempfile.NamedTemporaryFile(mode='w', suffix=f"_{port}.txt", delete=False) as f_ip, \
             tempfile.NamedTemporaryFile(mode='w', suffix=f"_{port}.csv", delete=False) as f_csv:
            temp_ip_path = f_ip.name
            temp_csv_path = f_csv.name
            f_ip.write("\n".join(e[0] for e in entries))

        try:
            # 阶段 1: 真实透传 -sl 进行深层高带宽节点探测
            target_min_speed = args.min_speed if args.mode == 'speed' else 0.0
            raw_results = cls.execute_cfst(temp_ip_path, temp_csv_path, port, target_min_speed, args)

            # 阶段 2: 智能自适应保底
            if not raw_results and args.mode == 'speed' and target_min_speed > 0 and getattr(args, 'fallback', True):
                print("\n" + "-" * 65)
                log_warn(f"⚠️ 在门槛 (>= {target_min_speed:.2f} MB/s) 下未能在端口 {port} 凑够达标节点！")
                log_info(f"🔄 自动触发保底测速 (Pass 2): 以零门槛测试存活节点，获取实测最高速节点...")
                print("-" * 65)
                # 清空 CSV 文件重新测试
                with open(temp_csv_path, 'w') as f:
                    pass
                raw_results = cls.execute_cfst(temp_ip_path, temp_csv_path, port, 0.0, args)

            port_results = []
            for item in raw_results:
                ip_addr = item['ip']
                if ip_addr in ip_to_original:
                    suffix = ip_to_original[ip_addr]
                    if suffix.endswith('自用'):
                        new_suffix = suffix
                    elif '#' in suffix:
                        new_suffix = f"{suffix}自用"
                    else:
                        new_suffix = f"{suffix}#自用"

                    port_results.append({
                        'full_line': f"{ip_addr}:{new_suffix}",
                        'ip': ip_addr,
                        'port': str(port),
                        'speed': item['speed'],
                        'latency': item['latency'],
                        'loss_rate': item['loss_rate'],
                        'colo': item['colo']
                    })

            return port_results
        finally:
            for p in (temp_ip_path, temp_csv_path):
                if os.path.exists(p):
                    try:
                        os.remove(p)
                    except Exception:
                        pass

    @classmethod
    def filter_and_rank(cls, all_results: List[Dict[str, Any]], args: argparse.Namespace) -> List[Dict[str, Any]]:
        """排序并截取 Top N 结果"""
        if not all_results:
            return []

        # 排序：speed 模式主按下载带宽降序、副按延迟升序；latency 模式主按延迟升序、副按下载带宽降序
        if args.mode == 'speed':
            all_results.sort(key=lambda x: (-x['speed'], x['latency']))
        else:
            all_results.sort(key=lambda x: (x['latency'], -x['speed']))

        return all_results[:args.top]


# ==============================================================================
# 6. 主程序入口与 CLI 参数配置
# ==============================================================================

def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="集成测速与优选管理工具: 支持 Cloudflare CDN 优选与 WARP Endpoint 优选 (带深层大带宽探测与自适应保底)",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument("--target", "-T", choices=['cdn', 'warp'], default='cdn',
                        help="优选目标类型: cdn (Cloudflare CDN/中转 IP 测速), warp (Cloudflare WARP Anycast Endpoint 优选)")

    # CDN 模式参数
    cdn_group = parser.add_argument_group("CDN 优选参数 (--target cdn)")
    cdn_group.add_argument("--mode", "-m", choices=['speed', 'latency'], default='speed',
                           help="测速模式: speed (带宽模式), latency (延迟/httping模式)")
    cdn_group.add_argument("--ports", "-p", default="443",
                           help="待测端口列表，逗号分隔 (例如 443 或 443,8443，设为 all 则测试所有端口)")
    cdn_group.add_argument("--concurrency", "-c", "--threads", "-n", dest="concurrency", type=int, default=200,
                           help="[延迟测速并发] 并发测速/探测线程数 (CDN 模式透传给 cfst -n, 默认 200, 范围 1~1000; WARP 模式控制探测并发数)")
    cdn_group.add_argument("--min-speed", "-s", type=float, default=5.0,
                           help="[带宽模式] 下载速度下限 (MB/s)。驱动 cfst 跨越延迟排序深入挖掘大带宽节点 (未达标将自动触发保底)")
    cdn_group.add_argument("--max-delay", "-tl", type=int, default=300,
                           help="[延迟上限过滤] 仅测试低于指定延迟的 IP (ms, 0 表示不限制)")
    cdn_group.add_argument("--max-loss", "-tlr", type=float, default=1.0,
                           help="[丢包率上限过滤] 仅输出低于或等于指定丢包率的 IP (0.00~1.00，例如 0.25 过滤丢包大于 25%% 的节点)")
    cdn_group.add_argument("--download-time", "-dt", type=int, default=10,
                           help="[带宽模式] 单 IP 下载测速时长 (秒)")
    cdn_group.add_argument("--test-count", "-dn", type=int, default=20,
                           help="[带宽模式] 下载测速达标数量")
    cdn_group.add_argument("--url", "--speedtest-url", dest="speedtest_url", default=os.getenv("CFST_URL", ""),
                           help="自定义测速地址 (如自建 Cloudflare Pages 测速 URL，如 https://xxx.pages.dev/20mb.bin)")
    cdn_group.add_argument("--file", "-f", "--tg-file", dest="input_file", default="",
                           help="指定本地已有的 IP 列表文件路径 (将自动跳过 Telegram 下载流程，直接解析该文件并继续后续测速与同步)")
    cdn_group.add_argument("--skip-tg", "--skip-telegram", "--sub-only", dest="skip_tg", action="store_true",
                           default=os.getenv("SKIP_TG", "").lower() in ("true", "1", "yes"),
                           help="跳过从 Telegram 下载文件，仅从订阅服务器获取现有及历史 IP 列表进行测速")
    cdn_group.add_argument("--tg-proxy", "--proxy", dest="tg_proxy",
                           default=os.getenv("TG_PROXY", ""),
                           help="从 Telegram 下载文件时使用的代理 (例如 socks5://127.0.0.1:1080 或 http://127.0.0.1:7890，支持环境变量 TG_PROXY/ALL_PROXY)")
    cdn_group.add_argument("--httping", action="store_true",
                           help="[延迟模式可选] 使用 HTTPing 代替 TCPing 测量延迟 (默认使用 TCPing)")
    cdn_group.add_argument("--no-fallback", dest="fallback", action="store_false", default=True,
                           help="禁用未凑齐达标节点时的自动保底测速")

    # WARP 模式参数
    warp_group = parser.add_argument_group("WARP 优选参数 (--target warp)")
    warp_group.add_argument("--warp-mode", choices=['fast', 'standard', 'full'], default='fast',
                            help="WARP 扫描模式: fast (快速抽样), standard (标准采样), full (全网段扫描)")
    warp_group.add_argument("--warp-ports", default="443,8443,4443,8095,4500,500,1701,2408",
                            help="WARP 待测端口列表")
    warp_group.add_argument("--rounds", "-r", type=int, default=3, help="WARP 单点探测轮数")
    warp_group.add_argument("--format", choices=['txt', 'wireguard', 'singbox', 'clash', 'warp-cli'], default='txt',
                            help="WARP 结果导出格式")
    warp_group.add_argument("--ipv6", action="store_true", help="启用 IPv6 WARP Anycast 网段探测")
    warp_group.add_argument("--bind-ip", default="", help="本地绑定的出网源 IP 地址")

    # 通用参数
    parser.add_argument("--top", "-t", type=int, default=20, help="最终保留的最优 IP/端点数量")
    parser.add_argument("--yes", "-y", action="store_true", help="跳过所有确认提示，自动推送至订阅服务器")
    parser.add_argument("--no-upload", "--no-push", "--local-only", dest="no_upload", action="store_true",
                        help="仅在本地执行测速与同步 (如更新 cloudflare-access-tcp)，不调用远端 API 更新优选 IP 列表")

    return parser


def run_warp_workflow(args: argparse.Namespace):
    """WARP Endpoint 优选流程"""
    import warp_tester
    warp_output = "warp_result.txt"

    try:
        ports = [int(p.strip()) for p in args.warp_ports.split(",") if p.strip()]
    except ValueError:
        log_error("WARP 端口格式不正确，必须为纯数字")
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
        log_warn("未能在任何 WARP 候选端点探测到有效响应。")
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

    # 挑出端口 443 最优 IP 同步到 cloudflare-access-tcp
    best_warp_443_ip = next((r['ip'] for r in top_results if str(r.get('port')) == '443' and is_valid_ip(r.get('ip'))), None)
    if best_warp_443_ip:
        log_info(f"挑选出 WARP 端口 443 最优 IP: {best_warp_443_ip}")
        LocalAccessTCPManager.sync_preferred_ip(best_warp_443_ip, auto_yes=args.yes)

    # 确认并上传
    if getattr(args, 'no_upload', False):
        log_info(f"已指定 --no-upload 参数，跳过推送至远程订阅服务器。优选结果已保存至 {warp_output}")
        return

    token = os.environ.get("CF_SUB_TOKEN")
    if not token:
        log_warn(f"未配置环境变量 CF_SUB_TOKEN，跳过推送操作。优选结果已保存至 {warp_output}")
    else:
        if not args.yes:
            try:
                user_input = input(f"\n👉 是否确认将以上 {len(top_results)} 个 WARP 优选端点推送到 Cloudflare Workers 订阅服务器？ [Y/n]: ").strip().lower()
                if user_input not in ('', 'y', 'yes'):
                    log_info(f"已取消推送操作。优选结果已保留在 {warp_output}")
                    return
            except (KeyboardInterrupt, EOFError):
                print("\n⏸️ 用户取消推送操作。")
                return
        warp_tester.upload_warp_results(warp_output)


def run_cdn_workflow(args: argparse.Namespace):
    """CDN IP 测速与优选流程 (深层大带宽探测 + 智能保底)"""
    allowed_ports = [p.strip() for p in args.ports.split(",") if p.strip()] if args.ports else ["443"]

    # 1. 收集与汇总候选 IP 池 (支持 --file 直接指定本地文件)
    groups = IPSourceManager.collect_ips(
        skip_tg=args.skip_tg or bool(args.input_file),
        input_file=args.input_file,
        allowed_ports=allowed_ports,
        auto_yes=args.yes,
        tg_proxy=args.tg_proxy
    )

    if not any(groups.values()):
        log_error("未能获取到任何有效的候选 IP:Port 数据，流程终止。")
        return

    # 2. 依次测试各目标端口 (内部已包含深层探测与 Pass 2 保底)
    all_results = []
    for port, entries in groups.items():
        port_results = CFSTRunner.test_port(port, entries, args)
        all_results.extend(port_results)

    if not all_results:
        log_warn("未能在任何端口测得有效结果。")
        return

    # 3. 排序并取 Top N
    top_results = CFSTRunner.filter_and_rank(all_results, args)

    # 4. 输出并保存最终结果
    if top_results:
        with open(FINAL_TXT, 'w', encoding='utf-8') as f:
            for item in top_results:
                f.write(f"{item['full_line']}\n")

        unit = "MB/s" if args.mode == 'speed' else "ms"
        print(f"\n✨ {args.mode} 模式测速完成！最优前 {len(top_results)} 个 IP 已保存至 {FINAL_TXT}：")
        print("=" * 96)
        print(f" {'排名':<4} {'优选节点 (IP:Port#备注)':<38} {'平均延迟':<14} {'下载速度':<14} {'丢包率':<10} {'地区码'}")
        print("-" * 96)
        for i, item in enumerate(top_results):
            loss_str = f"{item['loss_rate']*100:.1f}%" if item['loss_rate'] <= 1.0 else f"{item['loss_rate']:.1f}%"
            latency_str = f"{item['latency']:.2f} ms"
            speed_str = f"{item['speed']:.2f} MB/s"
            print(f" [{i+1:>2}] {item['full_line']:<38} {latency_str:<14} {speed_str:<14} {loss_str:<10} {item['colo']}")
        print("=" * 96)

        # 挑出端口 443 最优 IP 同步到 cloudflare-access-tcp
        best_443_item = next((item for item in top_results if item.get('port') == '443' and is_valid_ip(item.get('ip'))), None)
        if best_443_item:
            log_info(f"挑选出端口 443 最优 IP: {best_443_item['ip']} (平均延迟: {best_443_item['latency']:.2f} ms, 下载速度: {best_443_item['speed']:.2f} MB/s, 地区: {best_443_item['colo']})")
            LocalAccessTCPManager.sync_preferred_ip(best_443_item['ip'], auto_yes=args.yes)
        else:
            log_info("本次优选未包含有效的 443 端口 IP，跳过 cloudflare-access-tcp 同步。")

        # 5. 确认并上传至订阅服务器
        if getattr(args, 'no_upload', False):
            log_info(f"已指定 --no-upload 参数，跳过推送至远程订阅服务器。优选结果已保存至 {FINAL_TXT}")
            return

        token = os.environ.get("CF_SUB_TOKEN")
        if not token:
            log_warn(f"未配置环境变量 CF_SUB_TOKEN，跳过推送操作。优选结果已保存至 {FINAL_TXT}")
        else:
            if not args.yes:
                try:
                    user_input = input(f"\n👉 是否确认将以上 {len(top_results)} 个优选 IP 推送到 Cloudflare Workers 订阅服务器？ [Y/n]: ").strip().lower()
                    if user_input not in ('', 'y', 'yes'):
                        log_info(f"已取消推送操作。优选 IP 结果已保留在 {FINAL_TXT}")
                        return
                except (KeyboardInterrupt, EOFError):
                    print("\n⏸️ 用户取消推送操作。")
                    return
            WorkerSyncManager.upload_cdn_results(FINAL_TXT)


def main():
    import shlex
    normalized_argv = []
    for arg in sys.argv[1:]:
        if arg.startswith('-') and ' ' in arg:
            normalized_argv.extend(shlex.split(arg))
        else:
            normalized_argv.append(arg)

    parser = build_arg_parser()
    args = parser.parse_args(normalized_argv)

    if args.target == 'warp':
        run_warp_workflow(args)
    else:
        run_cdn_workflow(args)


if __name__ == "__main__":
    main()
