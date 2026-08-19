#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VPNGATE Residential IP Benchmark & Selector
Pulls latest VPNGATE server lists, filters residential IPs, benchmarks TCP latency and bandwidth,
and saves the TOP 20 residential proxy endpoints into result files.
"""

import sys
import os
import json
import argparse
import logging
from typing import List, Optional, Dict, Any

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from fetcher import fetch_all_vpngate_servers, VpnGateServer
from filter import filter_servers, filter_by_fraud_score
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
  🌐 VPNGATE 纯净住宅 IP 优选与高并发测速工具 (VPNGATE Selector)
  🛡️ Scamalytics 威胁分纯净筛选 (<20) -> 协议握手测速 -> 优选 TOP 20
==================================================================
"""
    print(banner)


def print_table(results: List[BenchmarkResult]) -> None:
    """Prints a beautiful CLI summary table."""
    if not results:
        print("\n❌ 未找到符合条件的可用节点。\n")
        return

    print("\n" + "=" * 125)
    print(f"  🏆 测速完成！精选最优 TOP {len(results)} Scamalytics纯净验证(<20分)住宅/志愿代理列表:")
    print("=" * 125)
    print(f"{'排名':<4} | {'地区':<6} | {'IP地址:端口':<22} | {'威胁分':<8} | {'协议':<10} | {'实测延迟':<10} | {'官方带宽':<12} | {'综合得分':<10} | {'SOCKS5代理全路径'}")
    print(f"{'-'*4}-+-{'-'*6}-+-{'-'*22}-+-{'-'*8}-+-{'-'*10}-+-{'-'*10}-+-{'-'*12}-+-{'-'*10}-+-{'-'*35}")

    for i, res in enumerate(results, 1):
        flag = get_country_flag(res.server.country_short)
        c_tag = f"{flag} {res.server.country_short}"
        addr = f"{res.server.ip}:{res.tested_port}"
        proto = res.protocol.upper()
        lat = f"{res.real_latency_ms:.2f} ms"
        spd = f"{res.server.speed_mbps:.2f} Mbps"
        score = f"{res.composite_score:.1f}"
        fraud_str = f"{res.fraud_score} / 100" if res.fraud_score >= 0 else "N/A"
        print(f"{i:<4d} | {c_tag:<6} | {addr:<22} | {fraud_str:<8} | {proto:<10} | {lat:<10} | {spd:<12} | {score:<10} | {res.socks5_url}")

    print("=" * 125 + "\n")


def show_current_nodes(results_dir: str = "results", country: Optional[str] = None) -> int:
    """Reads and displays currently selected nodes from residential_pool.json or residential_nodes.json."""
    search_dirs = [
        results_dir,
        os.path.join(SCRIPT_DIR, results_dir),
        "/usr/local/bin/vpngate-residential-selector/results",
        os.path.expanduser("~/.local/bin/vpngate-residential-selector/results")
    ]

    for r_dir in search_dirs:
        if not os.path.exists(r_dir):
            continue

        pool_file = os.path.join(r_dir, "residential_pool.json")
        nodes_file = os.path.join(r_dir, "residential_nodes.json")

        if os.path.exists(pool_file):
            try:
                with open(pool_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                updated_at = data.get("updated_at", "未知")
                pools = data.get("pools", {})
                
                selected_countries = [c.strip().upper() for c in country.split(",") if c.strip()] if country else list(pools.keys())
                
                all_nodes_data = []
                for c_code in selected_countries:
                    if c_code in pools:
                        for item in pools[c_code]:
                            all_nodes_data.append(item)
                
                if all_nodes_data:
                    c_desc = f" ({','.join(selected_countries)})" if country else ""
                    print(f"\n📂 当前 7 国活跃保活住宅节点池{c_desc} (最后更新: {updated_at})")
                    print(f"📊 汇总结算: 共包含 {len(all_nodes_data)} 个已验证节点 (来源: {pool_file})\n")
                    _render_nodes_table(all_nodes_data)
                    return 0
            except Exception as e:
                logging.debug(f"读取 {pool_file} 失败: {e}")

        if os.path.exists(nodes_file):
            try:
                with open(nodes_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                generated_at = data.get("generated_at", "未知")
                nodes = data.get("nodes", [])
                if country:
                    target_c = [c.strip().upper() for c in country.split(",") if c.strip()]
                    nodes = [n for n in nodes if n.get("country_short", "").upper() in target_c]
                if nodes:
                    print(f"\n📂 当前已选出 TOP 节点列表 (生成时间: {generated_at})")
                    print(f"📊 汇总结算: 共包含 {len(nodes)} 个节点 (来源: {nodes_file})\n")
                    _render_nodes_table(nodes)
                    return 0
            except Exception as e:
                logging.debug(f"读取 {nodes_file} 失败: {e}")

    print(f"\n❌ 未找到任何已选出的节点记录文件 (尝试目录: {results_dir})。")
    print("👉 请先运行 'vpngate-selector' 或启动 'vpngate-service start' 进行测速与优选。\n")
    return 1


def _render_nodes_table(nodes: List[Dict[str, Any]]) -> None:
    """Renders formatted CLI table for a list of node dicts."""
    print("=" * 135)
    print(f"{'序号':<4} | {'地区':<10} | {'IP地址:端口':<22} | {'威胁分':<8} | {'协议':<8} | {'实测延迟':<10} | {'官方带宽':<12} | {'综合得分':<10} | {'SOCKS5代理全路径'}")
    print(f"{'-'*4}-+-{'-'*10}-+-{'-'*22}-+-{'-'*8}-+-{'-'*8}-+-{'-'*10}-+-{'-'*12}-+-{'-'*10}-+-{'-'*35}")

    by_country: Dict[str, int] = {}
    for i, n in enumerate(nodes, 1):
        c_short = n.get("country_short", "UN")
        c_zh = n.get("country_zh", "")
        flag = n.get("flag", get_country_flag(c_short))
        c_tag = f"{flag} {c_short}" + (f" {c_zh}" if c_zh else "")
        ip = n.get("ip", "")
        port = n.get("port", 443)
        addr = f"{ip}:{port}"
        proto = n.get("protocol", "openvpn").upper()
        lat = f"{n.get('real_latency_ms', 0.0):.2f} ms"
        spd = f"{n.get('speed_mbps', 0.0):.2f} Mbps"
        score = f"{n.get('composite_score', 0.0):.1f}"
        f_score = n.get("fraud_score", -1)
        f_str = f"{f_score} / 100" if f_score >= 0 else "N/A"
        proxy_url = n.get("proxy_urls", {}).get("socks5", f"socks5://vpn:vpn@{addr}")
        
        by_country[c_short] = by_country.get(c_short, 0) + 1
        print(f"{i:<4d} | {c_tag:<10} | {addr:<22} | {f_str:<8} | {proto:<8} | {lat:<10} | {spd:<12} | {score:<10} | {proxy_url}")

    print("=" * 135)
    print("📈 各地区节点分布统计:")
    for c, cnt in by_country.items():
        print(f"   • {get_country_flag(c)} {c}: {cnt} 个可用节点")
    print("")


def clean_historical_data(results_dir: str = "results") -> int:
    """Cleans all historical node databases, state pools, and fraud score caches."""
    search_dirs = [
        results_dir,
        os.path.join(SCRIPT_DIR, results_dir),
        "/usr/local/bin/vpngate-residential-selector/results",
        os.path.expanduser("~/.local/bin/vpngate-residential-selector/results")
    ]

    cleaned_files = []
    target_filenames = [
        "all_discovered_nodes.json",
        "residential_pool.json",
        "scamalytics_cache.json",
        "residential_nodes.json",
        "proxies.txt",
        "upstream_gateway.txt",
        "vpngate_top20.txt",
        "singbox_outbounds.json",
        "summary.md"
    ]

    for r_dir in set(search_dirs):
        if not os.path.exists(r_dir):
            continue
        for fname in target_filenames:
            fpath = os.path.join(r_dir, fname)
            if os.path.exists(fpath):
                try:
                    os.remove(fpath)
                    cleaned_files.append(fpath)
                except Exception as e:
                    logging.warning(f"删除 {fpath} 失败: {e}")
        try:
            for f in os.listdir(r_dir):
                if f.startswith("proxies_") and f.endswith(".txt"):
                    fpath = os.path.join(r_dir, f)
                    os.remove(fpath)
                    cleaned_files.append(fpath)
        except Exception:
            pass

    if cleaned_files:
        print(f"\n🧹 已成功清理 {len(cleaned_files)} 个历史数据库与缓存文件:")
        for f in sorted(set(cleaned_files)):
            print(f"   • 已删除: {f}")
        print("✅ 历史沉淀库、状态池与威胁分缓存已彻底清空！下次运行将重新全量拉取与测速。\n")
    else:
        print(f"\nℹ️ 未发现任何需要清理的历史数据库或缓存文件。\n")
    return 0


def parse_arguments() -> argparse.Namespace:
    """Parses command-line arguments."""
    parser = argparse.ArgumentParser(
        description="VPNGATE 住宅 IP 优选与多轮高并发测速工具",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )

    parser.add_argument(
        "--list", "-l",
        action="store_true",
        help="查看当前已选出的全部住宅节点列表 (从本地状态文件直接读取展示，不重新测速)"
    )

    parser.add_argument(
        "--clean", "-C",
        action="store_true",
        help="清理本地历史沉淀节点数据库与 Scamalytics 威胁分缓存"
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
        "--max-fraud-score",
        type=int,
        default=20,
        help="Scamalytics 威胁分最大阈值 (低于该分数的 IP 判定为纯净住宅 IP，默认 20)"
    )

    parser.add_argument(
        "--skip-fraud-check",
        action="store_true",
        help="跳过 Scamalytics 威胁分在线查询"
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
    # Check if invoked as vpngate-nodes or with list/clean positional args
    if len(sys.argv) > 1 and sys.argv[1] in ("list", "nodes", "show"):
        sys.argv.pop(1)
        sys.argv.append("--list")
    elif len(sys.argv) > 1 and sys.argv[1] in ("clean", "clear"):
        sys.argv.pop(1)
        sys.argv.append("--clean")
    elif os.path.basename(sys.argv[0]) == "vpngate-nodes":
        if "--list" not in sys.argv and "-l" not in sys.argv:
            sys.argv.append("--list")

    args = parse_arguments()
    setup_logging(verbose=args.verbose, quiet=args.quiet)

    # Fast path: clean historical data
    if args.clean:
        return clean_historical_data(results_dir=args.output)

    # Fast path: display current selected nodes
    if args.list:
        return show_current_nodes(results_dir=args.output, country=args.country)

    if not args.quiet:
        print_banner()

    try:
        # 1. 从 VPNGATE 官方接口与全部镜像全量并发聚合数据
        servers = fetch_all_vpngate_servers(custom_url=args.vpngate_url if args.vpngate_url else None)

        if not servers:
            logging.error("❌ 未从 VPNGATE 解析到任何服务器数据，程序退出。")
            return 1

        # 2. 候选服务器基础过滤 (国家、公网IP、去重)
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
            logging.error("❌ 基础过滤后无符合条件的候选节点，请放宽过滤条件后重试。")
            return 1

        # 3. 通过 Scamalytics 查询威胁分，筛选纯净住宅 IP (< max_fraud_score)
        if not args.skip_fraud_check:
            cache_file = os.path.join(args.output, "scamalytics_cache.json") if not os.path.isabs(args.output) else os.path.join(SCRIPT_DIR, args.output, "scamalytics_cache.json")
            clean_servers = filter_by_fraud_score(
                candidate_servers,
                max_fraud_score=args.max_fraud_score,
                max_workers=min(args.threads, 20),
                cache_path=cache_file
            )
            if clean_servers:
                candidate_servers = clean_servers
            else:
                logging.warning(f"⚠️ 未找到 Scamalytics 威胁分 < {args.max_fraud_score} 的纯净节点，保留全部基础候选节点继续测速。")

        # 4. 对纯净住宅节点执行高并发协议层握手连通性与时延测速
        benchmark_results = benchmark_servers(
            candidate_servers,
            max_workers=args.threads,
            timeout=args.timeout,
            samples=args.samples
        )

        if not benchmark_results:
            logging.error("❌ 所有候选节点连通性测试均失败，请检查当前网络状态。")
            return 1

        # 5. 综合加权排序精选最优 TOP N
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
