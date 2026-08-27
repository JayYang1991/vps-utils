#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
health_checker.py
Cloudflare Access TCP 容器内网络联通性检测、在线订阅同步与优选 IP 自动故障转移守护进程

功能：
1. 容器启动时从 --sub-url 获取在线订阅更新作为待选列表文件；若获取失败则保持原有文件不变。
2. 启动时从待选列表文件 (candidates.txt) 从前往后依次探测 443 端口并选取可用节点作为优选 IP (--preferred-ip)。
3. 定期检测 TCP 转发端口与当前优选 IP 的网络联通性 (Health Check Loop)。
4. 当 TCP 转发不通时，从待选列表从前往后验证可用性并自动故障转移 (Failover)。
5. 每日北京时间凌晨 02:00 ~ 06:00 随机时刻自动触发测速，更新 TOP 20 待选列表并切换至最优 IP。
6. 实时输出运行状态至 /etc/cloudflare-access-tcp/status.json 供宿主机监控。
"""

import os
import sys
import time
import json
import random
import socket
import signal
import threading
import subprocess
import datetime
from typing import List, Dict, Tuple, Optional, Any

# --- ANSI Colors ---
GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[0;33m"
CYAN = "\033[0;36m"
BOLD = "\033[1m"
RESET = "\033[0m"

# CST 时区 (UTC+8 北京时间)
CST_TZ = datetime.timezone(datetime.timedelta(hours=8))

def get_time_str() -> str:
    now = datetime.datetime.now(CST_TZ)
    return now.strftime('%Y-%m-%d %H:%M:%S CST')

def log_info(msg: str):
    print(f"[{get_time_str()}] {GREEN}[INFO]{RESET} {msg}", flush=True)

def log_warn(msg: str):
    print(f"[{get_time_str()}] {YELLOW}[WARN]{RESET} {msg}", flush=True)

def log_error(msg: str):
    print(f"[{get_time_str()}] {RED}[ERROR]{RESET} {msg}", file=sys.stderr, flush=True)

def log_success(msg: str):
    print(f"[{get_time_str()}] {GREEN}{BOLD}[SUCCESS]{RESET} {msg}", flush=True)


class Config:
    """运行配置加载"""
    DOMAINS_STR = os.getenv("DOMAINS", "movies.19910417.xyz,movies1.19910417.xyz")
    PORTS_STR = os.getenv("PORTS", "5000,5001")
    LISTEN_HOST = os.getenv("LISTEN_HOST", "127.0.0.1")
    INITIAL_PREF_IP = os.getenv("PREFERRED_IP", "").strip()
    CF_SUB_URL = os.getenv("CF_SUB_URL", "https://sub.19910417.xyz").strip()
    
    CANDIDATES_FILE = os.getenv("CANDIDATES_FILE", "/etc/cloudflare-access-tcp/candidates.txt")
    STATUS_FILE = os.getenv("STATUS_FILE", "/etc/cloudflare-access-tcp/status.json")
    CONF_DIR = os.getenv("CONF_DIR", "/etc/cloudflare-access-tcp")
    
    CHECK_INTERVAL = int(os.getenv("CHECK_INTERVAL", "15"))
    FAIL_THRESHOLD = int(os.getenv("FAIL_THRESHOLD", "2"))
    CONNECT_TIMEOUT = float(os.getenv("CONNECT_TIMEOUT", "2.5"))
    AUTO_SPEEDTEST = os.getenv("AUTO_SPEEDTEST", "true").lower() in ("true", "1", "yes")

    @classmethod
    def get_domains(cls) -> List[str]:
        return [d.strip() for d in cls.DOMAINS_STR.split(",") if d.strip()]

    @classmethod
    def get_ports(cls) -> List[int]:
        ports = []
        for p in cls.PORTS_STR.split(","):
            p = p.strip()
            if p.isdigit():
                ports.append(int(p))
        return ports


class HostsManager:
    """管理容器内 /etc/hosts 的优选 IP 静态映射"""
    HOSTS_FILE = "/etc/hosts"

    @classmethod
    def get_current_preferred_ip(cls, domains: List[str]) -> str:
        """从 /etc/hosts 读取当前映射的优选 IP"""
        if not os.path.exists(cls.HOSTS_FILE):
            return ""
        try:
            with open(cls.HOSTS_FILE, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    parts = line.split()
                    if len(parts) >= 2:
                        ip = parts[0]
                        hostnames = parts[1:]
                        for d in domains:
                            if d in hostnames:
                                return ip
        except Exception as e:
            log_warn(f"读取 {cls.HOSTS_FILE} 失败: {e}")
        return ""

    @classmethod
    def update_preferred_ip(cls, new_ip: str, domains: List[str]) -> bool:
        """更新 /etc/hosts 中目标域名的优选 IP 解析"""
        if not new_ip:
            return False
        try:
            lines = []
            if os.path.exists(cls.HOSTS_FILE):
                with open(cls.HOSTS_FILE, 'r', encoding='utf-8') as f:
                    for line in f:
                        line_stripped = line.strip()
                        if not line_stripped or line_stripped.startswith('#'):
                            lines.append(line)
                            continue
                        parts = line_stripped.split()
                        if len(parts) >= 2:
                            hostnames = parts[1:]
                            # 如果包含目标域名，则剔除
                            if any(d in hostnames for d in domains):
                                continue
                        lines.append(line)

            # 追加新的映射记录
            for d in domains:
                lines.append(f"{new_ip} {d}\n")

            with open(cls.HOSTS_FILE, 'w', encoding='utf-8') as f:
                f.writelines(lines)

            log_info(f"⚡ /etc/hosts 已更新域名解析: {', '.join(domains)} ===> {BOLD}{new_ip}{RESET}")
            return True
        except Exception as e:
            log_error(f"更新 {cls.HOSTS_FILE} 失败: {e}")
            return False


class ForwarderController:
    """管理 cloudflared 转发进程的重启与重载"""

    @classmethod
    def restart_forwarders(cls):
        """发送 SIGTERM 通知 entrypoint 进程管理器热重载 cloudflared 进程"""
        log_info("🔄 正在触发 cloudflared access tcp 转发进程重启以加载新 IP 映射...")
        try:
            subprocess.run(["pkill", "-TERM", "cloudflared"], check=False)
            time.sleep(1.5)
            log_info("cloudflared 进程重载指令已发送完成")
        except Exception as e:
            log_warn(f"重启 cloudflared 进程异常: {e}")


class NetworkTester:
    """网络联通性探测工具"""

    @staticmethod
    def test_tcp_port(host: str, port: int, timeout: float = 2.5) -> bool:
        """测试指定 TCP 端口的联通性"""
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            sock.connect((host, port))
            sock.close()
            return True
        except Exception:
            return False

    @staticmethod
    def test_ip_tls_edge(ip: str, port: int = 443, timeout: float = 2.0) -> bool:
        """测试 Cloudflare 边缘 IP 的 443 端口可用性"""
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            sock.connect((ip, port))
            sock.close()
            return True
        except Exception:
            return False


class CandidatePool:
    """待选 IP 列表读取与解析"""

    @staticmethod
    def read_candidates(file_path: str) -> List[Dict[str, Any]]:
        """从 candidates.txt 按顺序（从前往后）读取待选 IP 列表"""
        candidates = []
        if not os.path.exists(file_path):
            return candidates

        try:
            with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    # 格式: IP:Port#Remark
                    remark = ""
                    if '#' in line:
                        addr_part, remark = line.split('#', 1)
                    else:
                        addr_part = line

                    if ':' in addr_part:
                        ip = addr_part.split(':', 1)[0].strip()
                    else:
                        ip = addr_part.strip()

                    if ip:
                        candidates.append({
                            "ip": ip,
                            "raw": line,
                            "remark": remark
                        })
        except Exception as e:
            log_warn(f"读取候选文件 {file_path} 失败: {e}")
        return candidates


def update_candidates_from_sub():
    """从 --sub-url 拉取在线订阅更新待选列表，失败则保持原样"""
    sub_url = Config.CF_SUB_URL
    if not sub_url:
        return
    try:
        from speedtest_runner import update_candidates_from_sub_url
        update_candidates_from_sub_url(
            sub_url=sub_url,
            output_path=Config.CANDIDATES_FILE,
            port="443",
            top_count=20
        )
    except Exception as e:
        log_warn(f"拉取在线订阅更新异常: {e}，保持原有待选列表不变。")


def select_preferred_ip_from_candidates(candidates_file: str, domains: List[str]) -> str:
    """
    --preferred-ip 需要从待选列表文件选取：
    从待选列表文件从前往后依次测试 443 端口可用性，选取首个可用 IP 设置为优选 IP。
    """
    candidates = CandidatePool.read_candidates(candidates_file)
    if not candidates:
        log_warn(f"待选列表文件 ({candidates_file}) 为空！")
        return ""

    log_info(f"🔍 正在从待选列表 ({len(candidates)} 个节点) 从前往后选取首个可用优选 IP...")
    for idx, item in enumerate(candidates):
        cand_ip = item["ip"]
        remark = item.get("remark", "")
        if NetworkTester.test_ip_tls_edge(cand_ip, 443, timeout=2.0):
            log_success(f"✓ 选定优选 IP: {BOLD}{cand_ip}{RESET} [排名 #{idx+1}, {remark}] (443 端口验证通过)")
            HostsManager.update_preferred_ip(cand_ip, domains)
            return cand_ip
        else:
            log_warn(f"  - 候选 IP {cand_ip} ({remark}) 443 端口不可达，测试下一个...")

    # 若均未响应，保底选用列表第一个
    fallback_ip = candidates[0]["ip"]
    log_warn(f"⚠️ 待选列表中所有 IP 测试均未即时响应，保底选取 TOP 1: {fallback_ip}")
    HostsManager.update_preferred_ip(fallback_ip, domains)
    return fallback_ip


class HealthCheckerDaemon:
    """主守护进程：健康检查、故障转移与定时测速"""

    def __init__(self):
        self.domains = Config.get_domains()
        self.ports = Config.get_ports()
        self.candidates_file = Config.CANDIDATES_FILE
        self.status_file = Config.STATUS_FILE
        
        self.current_ip = ""
        self.consecutive_failures = 0
        self.running = True
        
        self.next_speedtest_time: Optional[datetime.datetime] = None
        self.last_speedtest_time: Optional[datetime.datetime] = None

    def save_status(self, is_healthy: bool, details: str = ""):
        """保存当前运行状态至 JSON 文件"""
        try:
            os.makedirs(os.path.dirname(os.path.abspath(self.status_file)), exist_ok=True)
            status_data = {
                "updated_at": get_time_str(),
                "healthy": is_healthy,
                "current_preferred_ip": self.current_ip,
                "domains": self.domains,
                "ports": self.ports,
                "consecutive_failures": self.consecutive_failures,
                "details": details,
                "last_speedtest_at": self.last_speedtest_time.strftime('%Y-%m-%d %H:%M:%S CST') if self.last_speedtest_time else None,
                "next_scheduled_speedtest": self.next_speedtest_time.strftime('%Y-%m-%d %H:%M:%S CST') if self.next_speedtest_time else None,
                "candidates_count": len(CandidatePool.read_candidates(self.candidates_file))
            }
            with open(self.status_file, 'w', encoding='utf-8') as f:
                json.dump(status_data, f, ensure_ascii=False, indent=2)
        except Exception:
            pass

    def run_speedtest_sync(self) -> bool:
        """调用 speedtest_runner.py 执行测速并刷新 candidates.txt"""
        log_info("🚀 开始调用 speedtest_runner.py 执行优选测速...")
        script_path = "/app/speedtest_runner.py"
        if not os.path.exists(script_path):
            script_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "speedtest_runner.py")

        cmd = [
            sys.executable, script_path,
            "--run",
            "--output", self.candidates_file,
            "--top", "20",
            "--port", "443"
        ]

        try:
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode == 0:
                self.last_speedtest_time = datetime.datetime.now(CST_TZ)
                log_success("优选测速执行成功，已更新 TOP 20 待选 IP 列表！")
                return True
            else:
                log_error(f"测速脚本返回非零状态码: {res.returncode}\n{res.stderr}")
                return False
        except Exception as e:
            log_error(f"执行测速异常: {e}")
            return False

    def perform_failover(self) -> bool:
        """
        策略 2: 当 TCP 检测不通时从待选列表文件从前往后测试 IP 可用后设置为优选 IP，
        将域名切换解析到该优选 IP。
        """
        log_warn("⚠️ 开始执行优选 IP 自动故障转移 (Failover 流程)...")
        candidates = CandidatePool.read_candidates(self.candidates_file)

        # 若候选列表为空，则立即尝试触发一次测速获取 TOP 20
        if not candidates:
            log_warn("待选 IP 列表为空，正在尝试立即触发测速以获取可用候选...")
            if self.run_speedtest_sync():
                candidates = CandidatePool.read_candidates(self.candidates_file)

        if not candidates:
            log_error("❌ 无法获取任何候选 IP，故障转移失败！")
            return False

        log_info(f"📋 已加载 {len(candidates)} 个待选优选 IP，开始从前往后依次验证可用性...")

        tested_count = 0
        for item in candidates:
            cand_ip = item["ip"]
            tested_count += 1

            # 跳过当前已损坏的 IP
            if cand_ip == self.current_ip:
                continue

            log_info(f"  [{tested_count}/{len(candidates)}] 正在测试候选 IP: {cand_ip} ({item.get('remark', '')}) ...")
            if NetworkTester.test_ip_tls_edge(cand_ip, 443, timeout=2.0):
                log_success(f"✓ 候选 IP {cand_ip} 443 端口验证通过！正在切换域名解析...")
                
                # 1. 切换 /etc/hosts
                HostsManager.update_preferred_ip(cand_ip, self.domains)
                self.current_ip = cand_ip

                # 2. 重启 cloudflared 转发进程
                ForwarderController.restart_forwarders()

                # 3. 等待并验证本地转发端口联通性
                time.sleep(2.0)
                all_ok = True
                for p in self.ports:
                    if not NetworkTester.test_tcp_port("127.0.0.1", p, timeout=3.0):
                        all_ok = False
                        break

                if all_ok:
                    log_success(f"🎉 优选 IP 已成功切换为: {BOLD}{cand_ip}{RESET}，所有本地 TCP 转发端口已全部恢复！")
                    self.consecutive_failures = 0
                    self.save_status(True, f"已故障转移至 {cand_ip}")
                    return True
                else:
                    log_warn(f"切换至 {cand_ip} 后本地 TCP 转发端口仍未完全恢复，继续尝试下一个候选 IP...")

        log_error("❌ 待选列表中所有 IP 均测试不可用，正在触发全量重新测速重试...")
        if self.run_speedtest_sync():
            # 重新测速后再次尝试
            new_candidates = CandidatePool.read_candidates(self.candidates_file)
            for item in new_candidates:
                cand_ip = item["ip"]
                if cand_ip != self.current_ip and NetworkTester.test_ip_tls_edge(cand_ip, 443, timeout=2.0):
                    HostsManager.update_preferred_ip(cand_ip, self.domains)
                    self.current_ip = cand_ip
                    ForwarderController.restart_forwarders()
                    time.sleep(2.0)
                    log_success(f"🎉 重新测速后成功切换至新优选 IP: {BOLD}{cand_ip}{RESET}")
                    self.consecutive_failures = 0
                    self.save_status(True, f"重新测速后切换至 {cand_ip}")
                    return True
        return False

    def schedule_daily_speedtest(self):
        """
        策略 1: 每天（北京时间凌晨2点-6点随机时间）重新测速选取 TOP 20 的 IP 并更新待选择 IP 列表文件
        """
        while self.running:
            now_cst = datetime.datetime.now(CST_TZ)
            today_date = now_cst.date()

            # 生成当天 02:00 ~ 06:00 之间的随机时间点 (4小时 = 14400秒)
            random_offset = random.randint(0, 14400)
            target_time = datetime.datetime(
                today_date.year, today_date.month, today_date.day, 2, 0, 0, tzinfo=CST_TZ
            ) + datetime.timedelta(seconds=random_offset)

            # 若当天的目标时间已过，则排期至次日
            if target_time <= now_cst:
                tomorrow_date = today_date + datetime.timedelta(days=1)
                random_offset = random.randint(0, 14400)
                target_time = datetime.datetime(
                    tomorrow_date.year, tomorrow_date.month, tomorrow_date.day, 2, 0, 0, tzinfo=CST_TZ
                ) + datetime.timedelta(seconds=random_offset)

            self.next_speedtest_time = target_time
            sleep_secs = (target_time - now_cst).total_seconds()
            hours = int(sleep_secs // 3600)
            mins = int((sleep_secs % 3600) // 60)
            log_info(f"📅 下一次每日定时测速计划排期: {BOLD}{target_time.strftime('%Y-%m-%d %H:%M:%S CST')}{RESET} (距今约 {hours} 小时 {mins} 分钟)")
            self.save_status(True, "定时器等待中")

            # 等待到触发时间
            while self.running and datetime.datetime.now(CST_TZ) < target_time:
                time.sleep(30)

            if not self.running:
                break

            log_info(f"⏰ 触发每日定时测速任务 (北京时间: {get_time_str()}) ...")
            if self.run_speedtest_sync():
                # 测速完成后，自动切换至 TOP 1 最优 IP
                candidates = CandidatePool.read_candidates(self.candidates_file)
                if candidates:
                    top_ip = candidates[0]["ip"]
                    if top_ip != self.current_ip and NetworkTester.test_ip_tls_edge(top_ip, 443, timeout=2.0):
                        log_info(f"⚡ 每日测速完成，自动将域名解析切换至最新 TOP 1 优选 IP: {BOLD}{top_ip}{RESET} ...")
                        HostsManager.update_preferred_ip(top_ip, self.domains)
                        self.current_ip = top_ip
                        ForwarderController.restart_forwarders()
                        log_success(f"✓ 域名已更新至 TOP 1 优选 IP: {top_ip}")
            time.sleep(60)

    def initialize(self):
        """容器启动初始化"""
        log_info("======================================================")
        log_info("  Cloudflare Access TCP 网络连通性与优选守护进程启动  ")
        log_info("======================================================")
        log_info(f"监控域名列表: {', '.join(self.domains)}")
        log_info(f"监听端口列表: {self.ports}")
        log_info(f"健康检查周期: 每 {Config.CHECK_INTERVAL} 秒")
        log_info(f"故障转移阈值: 连续失败 {Config.FAIL_THRESHOLD} 次")

        # 1. 启动时从 --sub-url 获取在线订阅更新作为待选列表文件；若获取失败则保持原有文件不变
        update_candidates_from_sub()

        # 2. 从待选列表文件选取首个可用的优选 IP 并注入 /etc/hosts
        selected_ip = select_preferred_ip_from_candidates(self.candidates_file, self.domains)
        if selected_ip:
            self.current_ip = selected_ip
        else:
            # 兼容已有 /etc/hosts 或默认值
            self.current_ip = HostsManager.get_current_preferred_ip(self.domains)

        self.save_status(True, "初始化完成")

        # 3. 启动每日定时测速线程
        if Config.AUTO_SPEEDTEST:
            t = threading.Thread(target=self.schedule_daily_speedtest, daemon=True, name="DailySpeedtestThread")
            t.start()
        else:
            log_info("已禁用每日自动测速 (AUTO_SPEEDTEST=false)")

    def start_monitoring_loop(self):
        """主健康检测循环"""
        self.initialize()

        while self.running:
            time.sleep(Config.CHECK_INTERVAL)
            if not self.running:
                break

            # 1. 检查各个本地转发端口连通性
            port_statuses = {}
            all_ports_ok = True
            for p in self.ports:
                ok = NetworkTester.test_tcp_port("127.0.0.1", p, timeout=Config.CONNECT_TIMEOUT)
                port_statuses[p] = ok
                if not ok:
                    all_ports_ok = False

            # 2. 检查当前优选 IP 边缘连通性
            edge_ok = True
            if self.current_ip:
                edge_ok = NetworkTester.test_ip_tls_edge(self.current_ip, 443, timeout=Config.CONNECT_TIMEOUT)

            # 判定整体状态
            if all_ports_ok and edge_ok:
                if self.consecutive_failures > 0:
                    log_success(f"✓ 转发链路已恢复正常 (当前优选 IP: {self.current_ip})")
                self.consecutive_failures = 0
                self.save_status(True, "所有本地转发端口与优选 IP 连接正常")
            else:
                self.consecutive_failures += 1
                failed_items = [f"Port {p}: {'OK' if port_statuses[p] else 'DOWN'}" for p in self.ports]
                failed_items.append(f"Edge {self.current_ip}: {'OK' if edge_ok else 'DOWN'}")
                log_warn(f"⚠️ 检测到转发链路异常 ({', '.join(failed_items)}) [连续失败: {self.consecutive_failures}/{Config.FAIL_THRESHOLD}]")
                self.save_status(False, f"连接异常: {', '.join(failed_items)}")

                if self.consecutive_failures >= Config.FAIL_THRESHOLD:
                    self.perform_failover()


def init_ip_cli():
    """CLI 启动前置初始化模式：拉取在线更新并从待选池选取优选 IP 注入 /etc/hosts"""
    domains = Config.get_domains()
    candidates_file = Config.CANDIDATES_FILE
    log_info(f"⚡ 正在执行容器启动前置初始化 (订阅更新与优选 IP 选取)...")
    
    # 1. 在线更新 (失败保持原样)
    update_candidates_from_sub()
    
    # 2. 从待选列表选取优选 IP
    chosen_ip = select_preferred_ip_from_candidates(candidates_file, domains)
    if chosen_ip:
        log_success(f"✓ 容器启动优选 IP 选定并注入完成: {chosen_ip}")
    sys.exit(0)


def handle_signals(signum, frame):
    log_info("收到退出信号，正在停止健康检查守护进程...")
    sys.exit(0)

if __name__ == "__main__":
    signal.signal(signal.SIGTERM, handle_signals)
    signal.signal(signal.SIGINT, handle_signals)

    if "--init-ip" in sys.argv or "--init-only" in sys.argv:
        init_ip_cli()

    daemon = HealthCheckerDaemon()
    daemon.start_monitoring_loop()
