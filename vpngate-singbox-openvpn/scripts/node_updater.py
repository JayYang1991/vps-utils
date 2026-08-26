#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
VPNGate Node Daily Auto-Updater Daemon
- Runs continuously in the background on the host machine.
- Schedules a daily execution at a random time between Beijing Time (UTC+8) 00:00 and 06:00.
- Invokes generate_ovpn.py to fetch VPNGate nodes, filter by Scamalytics threat score (< 20),
  and generate fresh .ovpn files & nodes_mapping.json.
- Restarts the docker container (default: vpngate-singbox-openvpn) upon successful refresh to load new nodes.
"""

import os
import sys
import time
import signal
import random
import logging
import argparse
import subprocess
from datetime import datetime, timezone, timedelta
from typing import Optional, Dict, Any, List

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] [NodeUpdater] %(message)s'
)
logger = logging.getLogger("node_updater")

BEIJING_TZ = timezone(timedelta(hours=8))
RUNNING = True


def signal_handler(signum, frame):
    """Handle termination signals gracefully."""
    global RUNNING
    sig_name = signal.Signals(signum).name
    logger.info("🛑 收到信号 %s，正在优雅退出节点更新守护进程...", sig_name)
    RUNNING = False


def get_config_dir() -> str:
    """Determine config directory."""
    if os.environ.get("CONFIG_DIR"):
        return os.environ.get("CONFIG_DIR")
    if os.path.exists("/etc/vpngate-singbox-openvpn"):
        return "/etc/vpngate-singbox-openvpn"
    script_dir = os.path.dirname(os.path.abspath(__file__))
    local_cfg = os.path.join(script_dir, "..", "config")
    if os.path.exists(local_cfg):
        return os.path.abspath(local_cfg)
    return "./config"


def load_env_config(config_dir: str) -> Dict[str, str]:
    """Parse key-value pairs from config.env if present."""
    env_file = os.path.join(config_dir, "config.env")
    config = {}
    if os.path.exists(env_file):
        try:
            with open(env_file, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "=" in line:
                        k, v = line.split("=", 1)
                        k = k.strip()
                        v = v.strip().strip('"').strip("'")
                        config[k] = v
        except Exception as e:
            logger.warning("读取配置文件 %s 失败: %s", env_file, e)
    return config


def find_generate_script() -> str:
    """Locate generate_ovpn.py script path."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(script_dir, "..", "generate_ovpn.py"),
        os.path.join(script_dir, "generate_ovpn.py"),
        "/usr/local/bin/vpngate-singbox-openvpn/generate_ovpn.py",
        "/usr/local/bin/vpngate-generate-ovpn",
        "generate_ovpn.py"
    ]
    for p in candidates:
        if os.path.isfile(p):
            return os.path.abspath(p)
    return "generate_ovpn.py"


def get_next_random_schedule(
    start_hour: int = 0,
    end_hour: int = 6,
    now_dt: Optional[datetime] = None
) -> datetime:
    """
    Calculate the next scheduled run datetime at a random time point
    between start_hour and end_hour in Beijing Time (UTC+8).
    """
    if now_dt is None:
        now_beijing = datetime.now(BEIJING_TZ)
    else:
        now_beijing = now_dt.astimezone(BEIJING_TZ) if now_dt.tzinfo else now_dt.replace(tzinfo=BEIJING_TZ)

    window_seconds = max(1, (end_hour - start_hour) * 3600)
    rand_offset_today = random.randint(0, window_seconds)

    today_start = now_beijing.replace(hour=start_hour, minute=0, second=0, microsecond=0)
    today_target = today_start + timedelta(seconds=rand_offset_today)

    if now_beijing < today_target:
        return today_target

    # Otherwise schedule for tomorrow within [start_hour, end_hour]
    rand_offset_tomorrow = random.randint(0, window_seconds)
    tomorrow_start = today_start + timedelta(days=1)
    return tomorrow_start + timedelta(seconds=rand_offset_tomorrow)


def run_node_refresh_and_restart(
    config_dir: str,
    container_name: str = "vpngate-singbox-openvpn",
    custom_generate_args: Optional[List[str]] = None,
    country: Optional[str] = None
) -> bool:
    """
    Execute generate_ovpn.py to refresh nodes and restart docker container.
    Supports filtering nodes by country code (e.g. 'JP' or 'JP,US').
    """
    logger.info("🔄 [开始执行节点刷新任务] 读取配置与 VPNGate 节点数据...")

    env_cfg = load_env_config(config_dir)
    generate_py = find_generate_script()

    outdir = os.path.join(config_dir, "ovpn_nodes")
    mapping_file = os.path.join(config_dir, "nodes_mapping.json")

    cmd = [
        sys.executable,
        generate_py,
        "-d", outdir,
        "-m", mapping_file,
        "--clean"
    ]

    # Priority for country: explicit argument > config.env > os.environ
    target_country = (country if country is not None else env_cfg.get("VPNGATE_COUNTRY", os.environ.get("VPNGATE_COUNTRY", ""))).strip()
    min_speed = env_cfg.get("VPNGATE_MIN_SPEED", os.environ.get("VPNGATE_MIN_SPEED", "")).strip()
    limit = env_cfg.get("VPNGATE_LIMIT", os.environ.get("VPNGATE_LIMIT", "100")).strip()
    csv_source = env_cfg.get("VPNGATE_CSV_SOURCE", os.environ.get("VPNGATE_CSV_SOURCE", "")).strip()
    max_threat = env_cfg.get("VPNGATE_MAX_THREAT_SCORE", os.environ.get("VPNGATE_MAX_THREAT_SCORE", "20")).strip()

    if target_country:
        logger.info("📍 [国家过滤] 仅选取国家代码为 [%s] 的节点", target_country)
        cmd.extend(["-c", target_country])
    else:
        logger.info("🌐 [国家过滤] 未指定国家代码，拉取全部国家节点")

    if min_speed:
        try:
            if float(min_speed) > 0:
                cmd.extend(["--min-speed", str(min_speed)])
        except ValueError:
            pass
    if limit:
        try:
            if int(limit) > 0:
                cmd.extend(["-l", str(limit)])
        except ValueError:
            pass
    if csv_source:
        cmd.extend(["-s", csv_source])
    if max_threat:
        try:
            if int(max_threat) > 0:
                cmd.extend(["--max-threat-score", str(max_threat)])
        except ValueError:
            pass

    if custom_generate_args:
        cmd.extend(custom_generate_args)

    logger.info("执行节点生成命令: %s", " ".join(cmd))
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        if res.stdout:
            for line in res.stdout.strip().splitlines():
                logger.info("[generate_ovpn] %s", line)
        if res.stderr:
            for line in res.stderr.strip().splitlines():
                logger.warning("[generate_ovpn ERR] %s", line)

        if res.returncode != 0:
            logger.error("❌ generate_ovpn.py 执行失败，返回码: %d", res.returncode)
            return False

        logger.info("✅ 节点池与映射文件刷新成功！")
    except Exception as e:
        logger.exception("❌ 调用 generate_ovpn.py 异常: %s", e)
        return False

    # Restart Docker Container
    logger.info("🔄 正在重启 Docker 容器 %s 以加载并应用新节点...", container_name)
    try:
        res_docker = subprocess.run(
            ["docker", "restart", container_name],
            capture_output=True,
            text=True,
            timeout=60
        )
        if res_docker.returncode == 0:
            logger.info("🎉 [SUCCESS] 容器 %s 已成功重启，新节点生效！", container_name)
            return True
        else:
            logger.warning("⚠️ 重启容器 %s 失败 (可能容器未运行或无权限): %s", container_name, res_docker.stderr.strip())
            return False
    except Exception as e:
        logger.exception("❌ 调用 docker restart %s 异常: %s", container_name, e)
        return False


def main():
    global RUNNING
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    default_cfg = get_config_dir()

    parser = argparse.ArgumentParser(
        description="VPNGate Node Daily Auto-Updater Daemon: Periodically refreshes nodes (Beijing Time 00:00-06:00 random) and restarts container."
    )
    parser.add_argument(
        "--config-dir", default=default_cfg,
        help=f"Path to configuration directory (default: {default_cfg})"
    )
    parser.add_argument(
        "--container", default=os.environ.get("CONTAINER_NAME", "vpngate-singbox-openvpn"),
        help="Target Docker container name to restart (default: vpngate-singbox-openvpn)"
    )
    parser.add_argument(
        "-c", "--country", "--country-code", dest="country", default=None,
        help="Filter VPNGate nodes by country code (e.g. 'JP' or 'JP,US,KR'). Overrides config.env."
    )
    parser.add_argument(
        "--start-hour", type=int, default=0,
        help="Schedule window start hour in Beijing Time (0-23, default: 0)"
    )
    parser.add_argument(
        "--end-hour", type=int, default=6,
        help="Schedule window end hour in Beijing Time (0-23, default: 6)"
    )
    parser.add_argument(
        "--run-now", action="store_true",
        help="Immediately perform a node refresh and container restart, then exit"
    )

    args = parser.parse_args()

    if args.run_now:
        logger.info("⚡ [--run-now] 立即执行单次节点刷新与容器重启任务...")
        success = run_node_refresh_and_restart(args.config_dir, container_name=args.container, country=args.country)
        sys.exit(0 if success else 1)

    configured_country = args.country or load_env_config(args.config_dir).get("VPNGATE_COUNTRY", "") or os.environ.get("VPNGATE_COUNTRY", "")
    country_display = configured_country if configured_country else "全部国家 (不过滤)"

    logger.info("============================================================")
    logger.info("🚀 VPNGate 宿主机定时刷新与重启守护进程已启动")
    logger.info(" • 配置目录:       %s", args.config_dir)
    logger.info(" • 目标容器:       %s", args.container)
    logger.info(" • 目标国家代码:   %s", country_display)
    logger.info(" • 定时时间窗口:   每天北京时间 %02d:00 - %02d:00 之间的随机时刻", args.start_hour, args.end_hour)
    logger.info("============================================================")

    while RUNNING:
        next_run = get_next_random_schedule(start_hour=args.start_hour, end_hour=args.end_hour)
        now_beijing = datetime.now(BEIJING_TZ)
        wait_seconds = max(0, (next_run - now_beijing).total_seconds())

        next_str = next_run.strftime("%Y-%m-%d %H:%M:%S")
        hours_left = wait_seconds / 3600
        logger.info("⏰ 下一次自动刷新预定时间 (北京时间): %s (约 %.2f 小时后)", next_str, hours_left)

        # Sleep responsive loop
        sleep_end = time.time() + wait_seconds
        while RUNNING and time.time() < sleep_end:
            time.sleep(min(1.0, max(0.1, sleep_end - time.time())))

        if not RUNNING:
            break

        logger.info("⏰ 达到预定刷新时间点 (%s)，开始执行每日节点更新...", datetime.now(BEIJING_TZ).strftime("%Y-%m-%d %H:%M:%S"))
        try:
            run_node_refresh_and_restart(args.config_dir, container_name=args.container, country=args.country)
        except Exception as e:
            logger.exception("❌ 执行每日更新任务异常: %s", e)

        # Brief pause to ensure we don't trigger again within the same second
        time.sleep(5)

    logger.info("👋 VPNGate 节点刷新守护进程已安全退出。")
    return 0


if __name__ == '__main__':
    main()
