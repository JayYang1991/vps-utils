#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VPNGATE Residential Proxy Daemon Service
Runs periodically (default every 5 minutes / 300s) to perform health checks and 1-for-1 smart replacements
across 7 target countries (US, JP, HK, SG, KR, DE, AU).
"""

import sys
import os
import time
import signal
import argparse
import logging
from datetime import datetime

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from pool_manager import ResidentialPoolManager, TARGET_COUNTRIES

# Global shutdown flag for graceful termination
RUNNING = True


def signal_handler(signum, frame):
    """Handles SIGINT / SIGTERM for graceful exit."""
    global RUNNING
    sig_name = signal.Signals(signum).name
    logging.info(f"🛑 收到系统信号 {sig_name}，正在优雅停止守护进程...")
    RUNNING = False


def setup_logging(verbose: bool = False) -> None:
    """Configures application-wide logging with timestamp."""
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s [%(levelname)s] [%(name)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S"
    )


def parse_arguments() -> argparse.Namespace:
    """Parses CLI arguments."""
    parser = argparse.ArgumentParser(
        description="VPNGATE 7国住宅 IP 守护服务 (每 5 分钟健康检测与失效节点热替换)",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )

    parser.add_argument(
        "--interval", "-i",
        type=int,
        default=300,
        help="巡检与健康检测周期 (秒，默认: 300 即 5 分钟)"
    )

    parser.add_argument(
        "--top-per-country", "-n",
        type=int,
        default=20,
        help="每个国家精选维护的最优节点数 (默认: 20)"
    )

    parser.add_argument(
        "--output", "-o",
        type=str,
        default="results",
        help="结果文件与状态池保存目录"
    )

    parser.add_argument(
        "--proxy-type", "-p",
        choices=["socks5", "http", "direct", "noauth"],
        default="socks5",
        help="输出代理协议格式"
    )

    parser.add_argument(
        "--timeout",
        type=float,
        default=2.5,
        help="单次 TCP 握手超时时间 (秒)"
    )

    parser.add_argument(
        "--samples",
        type=int,
        default=2,
        help="每轮探测采样次数"
    )

    parser.add_argument(
        "--threads", "-t",
        type=int,
        default=30,
        help="并发测速线程数"
    )

    parser.add_argument(
        "--strict-residential",
        action="store_true",
        help="启用严格住宅 ISP 签名匹配"
    )

    parser.add_argument(
        "--run-once",
        action="store_true",
        help="仅执行单次巡检与更新后立即退出"
    )

    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="打印详细调试日志"
    )

    return parser.parse_args()


def main() -> int:
    """Daemon execution loop."""
    global RUNNING
    args = parse_arguments()
    setup_logging(verbose=args.verbose)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    countries_str = ", ".join([f"{zh} ({code})" for code, zh in TARGET_COUNTRIES.items()])
    logging.info("=" * 80)
    logging.info("🚀 VPNGATE 7国住宅 IP 后台守护进程已启动")
    logging.info(f"   • 巡检周期: {args.interval} 秒 ({args.interval / 60:.1f} 分钟)")
    logging.info(f"   • 目标国家: {countries_str}")
    logging.info(f"   • 每国配额: TOP {args.top_per_country}")
    logging.info(f"   • 代理格式: {args.proxy_type.upper()}")
    logging.info(f"   • 输出目录: {args.output}/")
    logging.info("=" * 80)

    manager = ResidentialPoolManager(
        output_dir=args.output,
        top_per_country=args.top_per_country,
        proxy_type=args.proxy_type,
        timeout=args.timeout,
        samples=args.samples,
        threads=args.threads,
        strict_residential=args.strict_residential
    )

    cycle_count = 0

    while RUNNING:
        cycle_count += 1
        logging.info(f"▶️ [第 {cycle_count} 轮巡检] 启动周期检测 ({datetime.now().strftime('%Y-%m-%d %H:%M:%S')})...")

        try:
            summary = manager.run_health_check_and_update()
            logging.info(f"⏹️ [第 {cycle_count} 轮巡检] 状态: {summary.get('status')} | 健康节点: {summary.get('healthy_count')} | 替换: {summary.get('replaced_count')} 个 | 补充: {summary.get('filled_count', 0)} 个")
        except Exception as e:
            logging.error(f"❌ [第 {cycle_count} 轮巡检] 发生异常: {e}", exc_info=args.verbose)

        if args.run_once:
            logging.info("🏁 --run-once 模式执行完毕，正常退出。")
            break

        logging.info(f"💤 正在休眠等待下一次巡检 ({args.interval} 秒)...")

        # Sleep with 1-second intervals for quick responsive shutdown
        for _ in range(args.interval):
            if not RUNNING:
                break
            time.sleep(1)

    logging.info("👋 VPNGATE 守护进程已安全退出。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
