#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
speedtest_runner.py
Cloudflare Access TCP 优选 IP 测速与候选池管理引擎

功能：
1. 容器启动或定时任务时从 --sub-url 在线订阅源与历史记录拉取最新候选节点；
   若获取失败则保持原有待选列表文件不变。
2. 调度 cfst (CloudflareSpeedTest) 在 443 端口执行延迟与大带宽下载测速。
3. 内置深层大带宽挖掘与零门槛自适应保底机制 (Pass 2 Auto-Fallback)。
4. 筛选并导出 TOP 20 最优 IP 至待选列表文件 (candidates.txt)。
"""

import os
import sys
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
    print(f"{get_time_prefix()} {GREEN}[INFO]{RESET} {msg}", flush=True)

def log_warn(msg: str):
    print(f"{get_time_prefix()} {YELLOW}[WARN]{RESET} {msg}", flush=True)

def log_error(msg: str):
    print(f"{get_time_prefix()} {RED}[ERROR]{RESET} {msg}", file=sys.stderr, flush=True)

def is_valid_ip(ip_str: Any) -> bool:
    """验证是否为有效的 IPv4 或 IPv6 地址"""
    if not ip_str or not isinstance(ip_str, str):
        return False
    clean_ip = ip_str.strip().strip('[]')
    try:
        ipaddress.ip_network(clean_ip, strict=False)
        return True
    except (ValueError, AttributeError):
        return False

def find_cfst_binary() -> str:
    """查找 cfst 可执行文件路径"""
    if os.getenv("CFST_BIN") and os.path.exists(os.getenv("CFST_BIN")):
        return os.getenv("CFST_BIN")
    for p in ["/usr/local/bin/cfst", "/app/cfst", "./cfst"]:
        if os.path.exists(p) and os.access(p, os.X_OK):
            return p
    return "cfst"


class CandidateSourceManager:
    """候选 IP 收集与去重管理"""

    @staticmethod
    def parse_file(file_path: str, target_port: str = "443") -> List[Tuple[str, str]]:
        """从待选 IP 列表中提取匹配目标端口的 IP"""
        results = []
        if not os.path.exists(file_path):
            return results
        try:
            with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    # 处理 IP:Port#Remark 格式
                    if ':' in line:
                        parts = line.split(':', 1)
                        ip = parts[0].strip().strip('[]')
                        rest = parts[1].strip()
                        port_match = re.search(r'^(\d+)', rest)
                        port = port_match.group(1) if port_match else "443"
                        remark = rest[len(port):].lstrip('#').strip() if port_match else ""
                        if is_valid_ip(ip) and (target_port == "all" or port == target_port):
                            results.append((ip, remark or "Candidate"))
                    else:
                        # 纯 IP
                        ip = line.split('#')[0].strip()
                        if is_valid_ip(ip):
                            results.append((ip, "Candidate"))
        except Exception as e:
            log_warn(f"解析文件 {file_path} 异常: {e}")
        return results

    @classmethod
    def fetch_online_ips(cls, sub_url: str, target_port: str = "443") -> List[Tuple[str, str]]:
        """从订阅服务器拉取在线与历史节点 IP"""
        if not sub_url:
            return []
        sub_url = sub_url.rstrip('/')
        results = []
        headers = {"User-Agent": "Mozilla/5.0 (VPS-Utils; Cloudflare-Access-TCP)"}

        # 1. 获取在线节点 (/sub?host=1&uuid=1)
        try:
            url = f"{sub_url}/sub?host=1&uuid=1"
            resp = requests.get(url, headers=headers, timeout=6)
            if resp.status_code == 200 and resp.text.strip():
                import base64
                try:
                    content = base64.b64decode(resp.text).decode('utf-8')
                except Exception:
                    content = resp.text
                for line in content.splitlines():
                    line = line.strip()
                    if line.startswith(("vless://", "trojan://", "ss://")):
                        match = re.search(r'@([^?#]+).*#(.+)$', line)
                        if match:
                            addr_port = match.group(1)
                            remark = urllib.parse.unquote(match.group(2))
                            if ':' in addr_port:
                                addr, p = addr_port.split(':', 1)
                                if is_valid_ip(addr) and (target_port == "all" or p == target_port):
                                    results.append((addr, remark))
                    elif ':' in line:
                        addr = line.split(':', 1)[0].strip()
                        if is_valid_ip(addr):
                            results.append((addr, "Sub"))
                log_info(f"从在线订阅源 ({sub_url}) 获取到 {len(results)} 个候选 IP")
        except Exception as e:
            log_warn(f"拉取在线订阅 IP 失败: {e}")

        # 2. 获取历史记录 (/api/history)
        try:
            url = f"{sub_url}/api/history"
            resp = requests.get(url, headers=headers, timeout=6)
            if resp.status_code == 200:
                data = resp.json()
                if data.get("success") and isinstance(data.get("data"), list):
                    h_count = 0
                    for record in data["data"]:
                        if isinstance(record, dict) and "ips" in record:
                            for line in record.get("ips", []):
                                if line and ":" in line:
                                    addr, rest = line.split(':', 1)
                                    port_match = re.search(r'^(\d+)', rest)
                                    p = port_match.group(1) if port_match else "443"
                                    if is_valid_ip(addr) and (target_port == "all" or p == target_port):
                                        results.append((addr, "History"))
                                        h_count += 1
                    log_info(f"从历史记录获取到 {h_count} 个候选 IP")
        except Exception as e:
            log_warn(f"拉取历史 IP 失败: {e}")

        return results

    @classmethod
    def collect_all_candidates(cls, sub_url: str, existing_candidates_file: str, target_port: str = "443") -> List[Tuple[str, str]]:
        """聚合去重候选 IP 来源 (在线订阅源 + 本地现有待选列表)"""
        seen_ips = set()
        candidates = []

        # 1. 现有候选列表
        if existing_candidates_file and os.path.exists(existing_candidates_file):
            for ip, remark in cls.parse_file(existing_candidates_file, target_port):
                if ip not in seen_ips:
                    seen_ips.add(ip)
                    candidates.append((ip, remark))

        # 2. 在线订阅与历史源
        if sub_url:
            for ip, remark in cls.fetch_online_ips(sub_url, target_port):
                if ip not in seen_ips:
                    seen_ips.add(ip)
                    candidates.append((ip, remark))

        log_info(f"候选 IP 汇聚完成，去重后共计 {len(candidates)} 个 IP 待测速")
        return candidates


class SpeedTestEngine:
    """调用 cfst 执行测速与保底排序"""

    @staticmethod
    def parse_csv_row(row: Dict[str, str]) -> Dict[str, Any]:
        """解析 CSV 结果行关键字段"""
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
    def execute_cfst(cls, cfst_bin: str, ip_file: str, csv_file: str, port: str,
                     concurrency: int, test_count: int, download_time: int,
                     min_speed: float, max_delay: int, max_loss: float,
                     speedtest_url: str = "") -> List[Dict[str, Any]]:
        """执行一次 cfst 测速"""
        url_flag = f' -url "{speedtest_url}"' if speedtest_url else ""
        max_delay_flag = f' -tl {max_delay}' if max_delay else ""
        max_loss_flag = f' -tlr {max_loss}' if max_loss < 1.0 else ""
        download_time_flag = f' -dt {download_time}' if download_time else ""
        test_count_flag = f' -dn {test_count}' if test_count else " -dn 20"
        threads_flag = f' -n {concurrency}' if concurrency else " -n 200"

        cfst_cmd = (f"{cfst_bin} -f \"{ip_file}\" -tp {port}{threads_flag}{test_count_flag}"
                    f"{download_time_flag}{max_delay_flag}{max_loss_flag} -sl {min_speed}{url_flag} -o \"{csv_file}\"")

        log_info(f"调用测速核心: {CYAN}{cfst_cmd}{RESET}")
        try:
            subprocess.run(cfst_cmd, shell=True, check=True)
        except subprocess.CalledProcessError as e:
            log_warn(f"cfst 执行返回状态码: {e.returncode}")

        results = []
        if os.path.exists(csv_file) and os.path.getsize(csv_file) > 0:
            try:
                with open(csv_file, mode='r', encoding='utf-8-sig') as f:
                    reader = csv.DictReader(f)
                    for row in reader:
                        parsed = cls.parse_csv_row(row)
                        if parsed['ip'] and is_valid_ip(parsed['ip']):
                            results.append(parsed)
            except Exception as e:
                log_warn(f"解析 CSV 结果失败: {e}")
        return results

    @classmethod
    def run_speedtest(cls, candidates: List[Tuple[str, str]], top_count: int = 20,
                      port: str = "443", concurrency: int = 200, min_speed: float = 5.0,
                      max_delay: int = 300, max_loss: float = 1.0, download_time: int = 10,
                      speedtest_url: str = "") -> List[Dict[str, Any]]:
        """执行完整测速流程 (含 Pass 1 深度测速与 Pass 2 自动保底)"""
        cfst_bin = find_cfst_binary()
        if not os.path.exists(cfst_bin) and not shutil.which(cfst_bin):
            log_error(f"未找到 cfst 测速工具 ({cfst_bin})")
            return []

        if not candidates:
            log_error("无候选 IP 数据，无法执行测速")
            return []

        with tempfile.NamedTemporaryFile(mode='w', suffix="_ip.txt", delete=False) as f_ip, \
             tempfile.NamedTemporaryFile(mode='w', suffix="_result.csv", delete=False) as f_csv:
            ip_file = f_ip.name
            csv_file = f_csv.name
            f_ip.write("\n".join(c[0] for c in candidates))

        try:
            # 阶段 1: 指定速度下限测速
            log_info(f"🚀 开始阶段 1 测速 (门槛: >= {min_speed:.1f} MB/s, 端口: {port}, 并发: {concurrency})...")
            results = cls.execute_cfst(
                cfst_bin, ip_file, csv_file, port, concurrency, top_count,
                download_time, min_speed, max_delay, max_loss, speedtest_url
            )

            # 阶段 2: 自适应保底
            if len(results) < 5 and min_speed > 0:
                log_warn(f"⚠️ 阶段 1 仅获取到 {len(results)} 个达标节点，触发阶段 2 保底测速 (门槛: 0 MB/s)...")
                with open(csv_file, 'w') as f:
                    pass
                fallback_results = cls.execute_cfst(
                    cfst_bin, ip_file, csv_file, port, concurrency, top_count,
                    download_time, 0.0, max_delay, max_loss, speedtest_url
                )
                if fallback_results:
                    seen = {r['ip'] for r in results}
                    for fr in fallback_results:
                        if fr['ip'] not in seen:
                            results.append(fr)
                            seen.add(fr['ip'])

            # 排序：优先按下载带宽降序，次优按延迟升序
            results.sort(key=lambda x: (-x['speed'], x['latency']))
            top_results = results[:top_count]
            return top_results
        finally:
            for p in (ip_file, csv_file):
                if os.path.exists(p):
                    try:
                        os.remove(p)
                    except Exception:
                        pass


def save_candidates_file(results: List[Dict[str, Any]], output_path: str, port: str = "443") -> bool:
    """将 TOP N 测速结果保存为待选 IP 列表文件"""
    if not results:
        return False
    try:
        os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
        with open(output_path, 'w', encoding='utf-8') as f:
            for item in results:
                ip = item['ip']
                speed = item['speed']
                latency = item['latency']
                loss = item['loss_rate']
                colo = item.get('colo', 'N/A')
                loss_str = f"{loss*100:.0f}%" if loss <= 1.0 else f"{loss:.0f}%"
                f.write(f"{ip}:{port}#{colo}_{speed:.2f}MBs_{latency:.1f}ms_loss{loss_str}\n")
        log_info(f"✨ 成功将 TOP {len(results)} 优选 IP 保存至待选文件: {output_path}")
        return True
    except Exception as e:
        log_error(f"写入待选文件失败: {e}")
        return False


def test_ip_reachability(ip: str, port: int = 443, timeout: float = 2.0) -> bool:
    """轻量级探测指定 IP 的 TCP 443 端口连通性"""
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((ip, port))
        s.close()
        return True
    except Exception:
        return False


def update_candidates_from_sub_url(sub_url: str, output_path: str, port: str = "443", top_count: int = 20) -> bool:
    """
    容器启动时从 --sub-url 获取在线订阅更新作为待选列表文件；
    如果获取失败，则保持原有待选列表文件不变。
    """
    log_info(f"🔄 正在尝试从在线订阅源 ({sub_url}) 拉取最新优选候选 IP...")
    online_ips = CandidateSourceManager.fetch_online_ips(sub_url, target_port=port)

    if online_ips:
        log_info(f"✓ 成功从在线订阅源获取到 {len(online_ips)} 个最新 IP，正在执行优选测速以更新待选列表...")
        top_results = SpeedTestEngine.run_speedtest(
            candidates=online_ips,
            top_count=top_count,
            port=port,
            concurrency=int(os.getenv("CONCURRENCY", "200")),
            min_speed=float(os.getenv("MIN_SPEED", "5.0")),
            max_delay=int(os.getenv("MAX_DELAY", "300")),
            download_time=10
        )
        if top_results:
            save_candidates_file(top_results, output_path, port)
            return True
        else:
            log_warn("在线 IP 测速未产生有效结果，保持原有待选列表不变。")
            return False
    else:
        log_warn(f"⚠️ 从在线订阅源 ({sub_url}) 获取更新失败或未返回有效节点，保持原有待选列表文件 ({output_path}) 不变。")
        return False


def main():
    import shutil
    parser = argparse.ArgumentParser(description="Cloudflare Access TCP 优选 IP 测速与候选池管理引擎")
    parser.add_argument("--run", action="store_true", help="立即执行一次全流程测速并输出 TOP 20 待选列表")
    parser.add_argument("--update-from-sub", action="store_true", help="从 --sub-url 拉取在线订阅并更新待选列表 (失败则保持原样)")
    parser.add_argument("--output", "-o", default=os.getenv("CANDIDATES_FILE", "/etc/cloudflare-access-tcp/candidates.txt"),
                        help="待选 IP 列表输出文件路径 (默认: /etc/cloudflare-access-tcp/candidates.txt)")
    parser.add_argument("--top", "-t", type=int, default=int(os.getenv("TOP_COUNT", "20")),
                        help="选取最优 IP 的数量 (默认: 20)")
    parser.add_argument("--port", "-p", default=os.getenv("SPEEDTEST_PORT", "443"),
                        help="测速目标端口 (默认: 443)")
    parser.add_argument("--concurrency", "-n", type=int, default=int(os.getenv("CONCURRENCY", "200")),
                        help="测速并发线程数 (默认: 200)")
    parser.add_argument("--min-speed", "-s", type=float, default=float(os.getenv("MIN_SPEED", "5.0")),
                        help="下载带宽下限 MB/s (默认: 5.0)")
    parser.add_argument("--max-delay", "-tl", type=int, default=int(os.getenv("MAX_DELAY", "300")),
                        help="最大允许延迟 ms (默认: 300)")
    parser.add_argument("--sub-url", default=os.getenv("CF_SUB_URL", "https://sub.19910417.xyz"),
                        help="Cloudflare Workers 订阅拉取 URL")
    parser.add_argument("--test-ip", default="", help="测试单个 IP 的 443 端口连通性")

    args = parser.parse_args()

    if args.test_ip:
        ok = test_ip_reachability(args.test_ip, int(args.port))
        if ok:
            print(f"IP {args.test_ip}:{args.port} 连通正常 (TCP 连接成功)")
            sys.exit(0)
        else:
            print(f"IP {args.test_ip}:{args.port} 连接失败或超时")
            sys.exit(1)

    if args.update_from_sub:
        success = update_candidates_from_sub_url(
            sub_url=args.sub_url,
            output_path=args.output,
            port=args.port,
            top_count=args.top
        )
        sys.exit(0 if success else 0)

    if not args.run:
        parser.print_help()
        sys.exit(0)

    log_info("=== 开始执行 Cloudflare Access TCP 优选 IP 测速流程 ===")
    candidates = CandidateSourceManager.collect_all_candidates(
        sub_url=args.sub_url,
        existing_candidates_file=args.output,
        target_port=args.port
    )

    if not candidates:
        log_error("未能收集到任何候选 IP，测速终止。")
        sys.exit(1)

    top_results = SpeedTestEngine.run_speedtest(
        candidates=candidates,
        top_count=args.top,
        port=args.port,
        concurrency=args.concurrency,
        min_speed=args.min_speed,
        max_delay=args.max_delay,
        download_time=10,
        speedtest_url=os.getenv("CFST_URL", "")
    )

    if not top_results:
        log_error("测速未获得有效结果。")
        sys.exit(1)

    print("\n" + "=" * 90)
    print(f" {'排名':<4} {'优选 IP':<18} {'平均延迟':<12} {'下载速度':<14} {'丢包率':<10} {'地区码'}")
    print("-" * 90)
    for i, r in enumerate(top_results):
        loss_str = f"{r['loss_rate']*100:.1f}%" if r['loss_rate'] <= 1.0 else f"{r['loss_rate']:.1f}%"
        print(f" [{i+1:>2}] {r['ip']:<18} {r['latency']:>6.1f} ms    {r['speed']:>6.2f} MB/s    {loss_str:<10} {r['colo']}")
    print("=" * 90 + "\n")

    saved = save_candidates_file(top_results, args.output, args.port)
    if saved:
        log_info(f"🎉 优选测速完成！TOP 1 最优 IP: {BOLD}{top_results[0]['ip']}{RESET} ({top_results[0]['speed']:.2f} MB/s, {top_results[0]['latency']:.1f} ms)")
        sys.exit(0)
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
