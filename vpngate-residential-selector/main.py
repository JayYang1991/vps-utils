#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VPNGATE Residential IP Benchmark & Selector
Pulls latest VPNGATE server lists, filters residential IPs, benchmarks TCP latency and bandwidth,
and saves the TOP 20 residential proxy endpoints into result files.
"""

import sys
import os
import argparse
import logging
from typing import List

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from fetcher import fetch_all_vpngate_servers, VpnGateServer
from filter import filter_servers
from tester import benchmark_servers, select_top_servers, BenchmarkResult
from exporter import export_results, get_country_flag


def setup_logging(verbose: bool = False, quiet: bool = False) -> None:
    """Configures application-wide logging."""
    if quiet:
        level = logging.ERROR
    elif verbose:
        level = logging.DEBUG
    else:
        level = logging.INFO

    logging.basicConfig(
        level=level,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S"
    )


def print_banner() -> None:
    """Prints tool banner."""
    banner = """
==================================================================
  🌐 VPNGATE 住宅 IP 优选与高并发测速工具 (VPNGATE Selector)
  ⚡ 自动拉取 -> 住宅网络识别 -> 高并发多轮测速 -> 优选 TOP 20
==================================================================
"""
    print(banner)


def print_table(results: List[BenchmarkResult]) -> None:
    """Prints a beautiful CLI summary table."""
    if not results:
        print("\n❌ 未找到符合条件的可用节点。\n")
        return

    print("\n" + "=" * 115)
    print(f"  🏆 测速完成！精选最优 TOP {len(results)} 协议验证可用住宅/志愿代理列表:")
    print("=" * 115)
    print(f"{'排名':<4} | {'地区':<6} | {'IP地址:端口':<22} | {'协议':<10} | {'实测延迟':<10} | {'官方带宽':<12} | {'综合得分':<10} | {'SOCKS5代理全路径'}")
    print(f"{'-'*4}-+-{'-'*6}-+-{'-'*22}-+-{'-'*10}-+-{'-'*10}-+-{'-'*12}-+-{'-'*10}-+-{'-'*35}")

    for i, res in enumerate(results, 1):
        flag = get_country_flag(res.server.country_short)
        c_tag = f"{flag} {res.server.country_short}"
        addr = f"{res.server.ip}:{res.tested_port}"
        proto = res.protocol.upper()
        lat = f"{res.real_latency_ms:.2f} ms"
        spd = f"{res.server.speed_mbps:.2f} Mbps"
        score = f"{res.composite_score:.1f}"
        print(f"{i:<4d} | {c_tag:<6} | {addr:<22} | {proto:<10} | {lat:<10} | {spd:<12} | {score:<10} | {res.socks5_url}")

    print("=" * 115 + "\n")


def parse_arguments() -> argparse.Namespace:
    """Parses command-line arguments."""
    parser = argparse.ArgumentParser(
        description="VPNGATE 住宅 IP 优选与多轮高并发测速工具",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )

    parser.add_argument(
        "--top", "-n",
        type=int,
        default=20,
        help="精选出的最优节点数量 (默认: 20)"
    )

    parser.add_argument(
        "--output", "-o",
        type=str,
        default="results",
        help="结果文件输出目录"
    )

    parser.add_argument(
        "--file", "-f",
        type=str,
        default="",
        help="单独指定纯代理列表的输出文件路径 (若指定则覆盖默认的 proxies.txt)"
    )

    parser.add_argument(
        "--proxy-type", "-p",
        choices=["socks5", "http", "direct", "noauth", "all"],
        default="socks5",
        help="输出代理的协议格式: socks5 (带认证), http, direct (ip:port), noauth, all"
    )

    parser.add_argument(
        "--country", "-c",
        type=str,
        default="",
        help="按国家/地区代码过滤 (如: JP,KR,US，留空代表不限国家)"
    )

    parser.add_argument(
        "--min-speed",
        type=float,
        default=0.0,
        help="过滤官方带宽小于该值的节点 (单位: Mbps)"
    )

    parser.add_argument(
        "--max-ping",
        type=int,
        default=9999,
        help="过滤官方 Ping 大于该值的节点 (单位: ms)"
    )

    parser.add_argument(
        "--sort-by",
        choices=["composite", "latency", "speed"],
        default="composite",
        help="排序策略: composite (综合评分), latency (实测低延迟优先), speed (带宽优先)"
    )

    parser.add_argument(
        "--threads", "-t",
        type=int,
        default=30,
        help="并发测速线程数"
    )

    parser.add_argument(
        "--timeout",
        type=float,
        default=2.5,
        help="单次 TCP 连接探测超时时间 (单位: 秒)"
    )

    parser.add_argument(
        "--samples",
        type=int,
        default=3,
        help="每个节点的探测采样次数 (用于计算平均延迟与丢包率)"
    )

    parser.add_argument(
        "--strict-residential",
        action="store_true",
        help="启用严格住宅 ISP 签名匹配"
    )

    parser.add_argument(
        "--save-ovpn",
        action="store_true",
        help="是否同时将选出节点的 OpenVPN (.ovpn) 配置文件保存至 ovpn/ 目录"
    )

    parser.add_argument(
        "--vpngate-url",
        type=str,
        default="",
        help="自定义 VPNGATE API 地址或本地镜像 URL"
    )

    parser.add_argument(
        "--quiet", "-q",
        action="store_true",
        help="静默模式 (仅输出最终简要信息)"
    )

    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="打印详细调试日志"
    )

    return parser.parse_args()


def main() -> int:
    """Main CLI execution flow."""
    args = parse_arguments()
    setup_logging(verbose=args.verbose, quiet=args.quiet)

    if not args.quiet:
        print_banner()

    try:
        # 1. 从 VPNGATE 官方接口与全部镜像全量并发聚合数据
        servers = fetch_all_vpngate_servers(custom_url=args.vpngate_url if args.vpngate_url else None)

        if not servers:
            logging.error("❌ 未从 VPNGATE 解析到任何服务器数据，程序退出。")
            return 1

        # 2. 候选服务器过滤与分类
        countries = [c.strip() for c in args.country.split(",") if c.strip()] if args.country else None
        candidate_servers = filter_servers(
            servers,
            allowed_countries=countries,
            min_speed_mbps=args.min_speed,
            max_ping=args.max_ping,
            strict_residential=args.strict_residential,
            deduplicate=True
        )

        if not candidate_servers:
            logging.error("❌ 过滤后无符合条件的候选节点，请放宽过滤条件后重试。")
            return 1

        # 3. 多轮高并发网络测速与连通性检测
        benchmark_results = benchmark_servers(
            candidate_servers,
            max_workers=args.threads,
            timeout=args.timeout,
            samples=args.samples
        )

        if not benchmark_results:
            logging.error("❌ 所有候选节点连通性测试均失败，请检查当前网络状态。")
            return 1

        # 4. 排序并精选出 TOP N
        top_servers = select_top_servers(
            benchmark_results,
            top_n=args.top,
            sort_by=args.sort_by
        )

        # 5. 打印终端预览
        if not args.quiet:
            print_table(top_servers)

        # 6. 导出结果文件
        exported = export_results(
            top_servers,
            output_dir=args.output,
            proxy_type=args.proxy_type,
            save_ovpn=args.save_ovpn
        )

        # 若指定了自定义单个输出文件
        if args.file:
            with open(args.file, "w", encoding="utf-8") as f:
                for res in top_servers:
                    f.write(f"{res.socks5_url}\n")
            logging.info(f"📄 代理全路径已单独保存至指定文件: {args.file}")

        print("✨ 任务全部完成！生成文件列表:")
        for key, path in exported.items():
            print(f"   • {key}: {path}")

        if top_servers:
            print(f"\n🚀 最优节点推荐 (可直接用于 Cloudflare VLESS 住宅中继网关):")
            print(f"   👉 {top_servers[0].socks5_url}\n")

        return 0

    except Exception as e:
        logging.error(f"❌ 运行过程中发生未捕获异常: {e}", exc_info=args.verbose)
        return 1


if __name__ == "__main__":
    sys.exit(main())
