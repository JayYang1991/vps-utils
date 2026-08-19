#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VPNGATE Multi-Country Residential Proxy Pool Manager
Maintains TOP 20 residential proxies for US, JP, HK, SG, KR, DE, and AU with:
1. Periodic health checks.
2. Zero API fetch when all current proxies are alive.
3. Smart incremental hot-replacement (1-for-1 replacement with unique IP) when any proxy fails.
"""

import os
import sys
import json
import base64
import logging
from typing import Dict, List, Set, Any, Optional
from datetime import datetime

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from fetcher import fetch_all_vpngate_servers, VpnGateServer
from filter import filter_servers, filter_by_fraud_score
from tester import test_single_server, benchmark_servers, select_top_servers, BenchmarkResult
from exporter import get_country_flag

logger = logging.getLogger("vpngate.pool")

TARGET_COUNTRIES = {
    "US": "美国",
    "JP": "日本",
    "HK": "香港",
    "SG": "新加坡",
    "KR": "韩国",
    "DE": "德国",
    "AU": "澳大利亚",
}


class ResidentialPoolManager:
    """
    Manages active proxy pools across 7 target countries with health check and incremental replacement.
    """

    def __init__(
        self,
        output_dir: str = "results",
        top_per_country: int = 5,
        proxy_type: str = "socks5",
        timeout: float = 2.5,
        samples: int = 2,
        threads: int = 30,
        strict_residential: bool = False,
    ):
        if not os.path.isabs(output_dir):
            self.output_dir = os.path.join(SCRIPT_DIR, output_dir)
        else:
            self.output_dir = output_dir

        self.top_per_country = top_per_country
        self.proxy_type = proxy_type
        self.timeout = timeout
        self.samples = samples
        self.threads = threads
        self.strict_residential = strict_residential

        self.pool_file = os.path.join(self.output_dir, "residential_pool.json")
        self.pools: Dict[str, List[BenchmarkResult]] = {c: [] for c in TARGET_COUNTRIES}
        os.makedirs(self.output_dir, exist_ok=True)

        self.load_state()

    def get_all_active_ips(self) -> Set[str]:
        """Returns set of all IPs currently active in any country's pool."""
        ips = set()
        for c, results in self.pools.items():
            for res in results:
                ips.add(res.server.ip)
        return ips

    def load_state(self) -> bool:
        """Loads previous pool state from JSON file if available."""
        if not os.path.exists(self.pool_file):
            return False

        try:
            with open(self.pool_file, "r", encoding="utf-8") as f:
                data = json.load(f)

            pools_data = data.get("pools", {})
            for country_code, node_list in pools_data.items():
                if country_code not in self.pools:
                    continue
                parsed_list = []
                for n in node_list:
                    server = VpnGateServer(
                        hostname=n.get("hostname", ""),
                        ip=n.get("ip", ""),
                        score=n.get("score", 0),
                        ping=n.get("ping", 0),
                        speed_bps=int(n.get("speed_mbps", 0) * 1024 * 1024),
                        speed_mbps=n.get("speed_mbps", 0.0),
                        country_short=n.get("country_short", country_code),
                        country_long=n.get("country_long", ""),
                        sessions=n.get("sessions", 0),
                        uptime_seconds=int(n.get("uptime_hours", 0) * 3600),
                        total_users=0,
                        total_traffic=0,
                        operator=n.get("operator", ""),
                        message="",
                        openvpn_config_b64=n.get("ovpn_b64", ""),
                        port=n.get("port", 443),
                        proto=n.get("proto", "tcp"),
                        extra_ports=n.get("extra_ports", []),
                    )
                    res = BenchmarkResult(
                        server=server,
                        reachable=True,
                        protocol=n.get("protocol", "openvpn"),
                        real_latency_ms=n.get("real_latency_ms", 0.0),
                        min_latency_ms=n.get("min_latency_ms", 0.0),
                        max_latency_ms=n.get("max_latency_ms", 0.0),
                        jitter_ms=n.get("jitter_ms", 0.0),
                        packet_loss_rate=n.get("packet_loss_rate", 0.0),
                        tested_port=n.get("port", 443),
                        composite_score=n.get("composite_score", 0.0),
                        fraud_score=n.get("fraud_score", -1),
                    )
                    parsed_list.append(res)
                self.pools[country_code] = parsed_list

            total_loaded = sum(len(v) for v in self.pools.values())
            logger.info(f"📂 从历史状态文件恢复了 {total_loaded} 个节点配置 ({self.pool_file})")
            return True
        except Exception as e:
            logger.warning(f"⚠️ 读取历史状态文件失败: {e}")
            return False

    def resort_and_trim_pools(self) -> None:
        """
        Strictly re-ranks every country's pool according to the standard composite rules:
        1. Only keep nodes with fraud_score < 20 (or -1 if not checked).
        2. Re-sort by: (-composite_score, fraud_score, real_latency_ms) where low threat score gets heavy bonus.
        3. Trim each country's pool to top_per_country (e.g. TOP 5).
        """
        for country_code in list(self.pools.keys()):
            valid_nodes = [
                r for r in self.pools[country_code]
                if r.fraud_score < 20 or r.fraud_score < 0
            ]
            valid_nodes.sort(key=lambda x: (
                -x.composite_score,
                x.fraud_score if x.fraud_score >= 0 else 999,
                x.real_latency_ms
            ))
            self.pools[country_code] = valid_nodes[:self.top_per_country]

    def save_state_and_export(self) -> None:
        """Saves current pool state to JSON and exports all per-country and aggregated proxy files."""
        # Ensure pools are strictly re-sorted and trimmed before exporting
        self.resort_and_trim_pools()

        timestamp_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

        # 1. Prepare JSON state
        json_pools = {}
        all_flattened_nodes: List[BenchmarkResult] = []

        # Export individual OpenVPN profiles
        ovpn_dir = os.path.join(self.output_dir, "ovpn")
        os.makedirs(ovpn_dir, exist_ok=True)

        for country_code, res_list in self.pools.items():
            json_pools[country_code] = []
            for i, res in enumerate(res_list, 1):
                all_flattened_nodes.append(res)
                if res.server.openvpn_config_b64:
                    try:
                        ovpn_content = base64.b64decode(res.server.openvpn_config_b64).decode("utf-8", errors="ignore")
                        fname = f"{country_code}_{i:02d}_{res.server.ip}_{res.tested_port}.ovpn"
                        with open(os.path.join(ovpn_dir, fname), "w", encoding="utf-8") as ovpn_f:
                            ovpn_f.write(ovpn_content)
                    except Exception:
                        pass

                json_pools[country_code].append({
                    "rank": i,
                    "ip": res.server.ip,
                    "port": res.tested_port,
                    "protocol": res.protocol,
                    "fraud_score": res.fraud_score,
                    "proto": res.server.proto,
                    "hostname": res.server.hostname,
                    "country_short": res.server.country_short,
                    "country_long": res.server.country_long,
                    "country_zh": TARGET_COUNTRIES.get(res.server.country_short, res.server.country_short),
                    "flag": get_country_flag(res.server.country_short),
                    "operator": res.server.operator,
                    "real_latency_ms": res.real_latency_ms,
                    "min_latency_ms": res.min_latency_ms,
                    "max_latency_ms": res.max_latency_ms,
                    "jitter_ms": res.jitter_ms,
                    "packet_loss_rate": res.packet_loss_rate,
                    "speed_mbps": res.server.speed_mbps,
                    "score": res.server.score,
                    "composite_score": res.composite_score,
                    "uptime_hours": round(res.server.uptime_seconds / 3600, 1),
                    "sessions": res.server.sessions,
                    "extra_ports": res.server.extra_ports,
                    "ovpn_b64": res.server.openvpn_config_b64,
                    "proxy_urls": {
                        "socks5": res.socks5_url,
                        "socks5_noauth": res.socks5_noauth_url,
                        "http": res.http_url,
                        "direct": res.direct_address,
                    },
                })

        with open(self.pool_file, "w", encoding="utf-8") as f:
            json.dump({
                "updated_at": timestamp_str,
                "target_countries": list(TARGET_COUNTRIES.keys()),
                "total_active_nodes": len(all_flattened_nodes),
                "pools": json_pools,
            }, f, indent=2, ensure_ascii=False)

        # 2. Export per-country pure proxy list: results/proxies_JP.txt, etc.
        for country_code, res_list in self.pools.items():
            country_txt_path = os.path.join(self.output_dir, f"proxies_{country_code}.txt")
            with open(country_txt_path, "w", encoding="utf-8") as f:
                for res in res_list:
                    if self.proxy_type == "http":
                        f.write(f"{res.http_url}\n")
                    elif self.proxy_type == "direct":
                        f.write(f"{res.direct_address}\n")
                    else:
                        f.write(f"{res.socks5_url}\n")

        # 3. Export all aggregated proxy list: results/proxies.txt
        all_proxies_path = os.path.join(self.output_dir, "proxies.txt")
        with open(all_proxies_path, "w", encoding="utf-8") as f:
            for country_code in TARGET_COUNTRIES:
                res_list = self.pools.get(country_code, [])
                for res in res_list:
                    if self.proxy_type == "http":
                        f.write(f"{res.http_url}\n")
                    elif self.proxy_type == "direct":
                        f.write(f"{res.direct_address}\n")
                    else:
                        f.write(f"{res.socks5_url}\n")

        # 4. Export top 1 upstream gateway for cloudflare-vless-proxy: results/upstream_gateway.txt
        if all_flattened_nodes:
            all_flattened_nodes.sort(key=lambda x: (
                -x.composite_score,
                x.fraud_score if x.fraud_score >= 0 else 999,
                x.real_latency_ms
            ))
            best_node = all_flattened_nodes[0]
            gateway_path = os.path.join(self.output_dir, "upstream_gateway.txt")
            with open(gateway_path, "w", encoding="utf-8") as f:
                f.write(f"{best_node.socks5_url}\n")

        # 5. Export Sing-box Outbounds configuration: singbox_outbounds.json
        singbox_path = os.path.join(self.output_dir, "singbox_outbounds.json")
        singbox_outbounds = []
        for i, res in enumerate(all_flattened_nodes, 1):
            flag = get_country_flag(res.server.country_short)
            tag = f"{flag} {res.server.country_short} - {res.server.ip}"
            singbox_outbounds.append({
                "type": "socks",
                "tag": tag,
                "server": res.server.ip,
                "server_port": res.tested_port,
                "version": "5",
                "username": "vpn",
                "password": "vpn"
            })
        with open(singbox_path, "w", encoding="utf-8") as f:
            json.dump({"outbounds": singbox_outbounds}, f, indent=2, ensure_ascii=False)

        # 6. Export Markdown summary: results/summary.md
        md_path = os.path.join(self.output_dir, "summary.md")
        with open(md_path, "w", encoding="utf-8") as f:
            f.write(f"# 🌐 VPNGATE 7国住宅 IP 代理池状态看板\n\n")
            f.write(f"> ⏱️ **最后巡检更新时间**：`{timestamp_str}`  \n")
            f.write(f"> 📊 **当前活跃代理总数**：`{len(all_flattened_nodes)}` 个优质纯净住宅节点 (Scamalytics威胁分<20)\n\n")

            for country_code, country_zh in TARGET_COUNTRIES.items():
                res_list = self.pools.get(country_code, [])
                flag = get_country_flag(country_code)
                f.write(f"### {flag} {country_zh} ({country_code}) — 共 {len(res_list)} / {self.top_per_country} 个节点\n\n")
                if not res_list:
                    f.write("*(暂无在线节点)*\n\n")
                    continue

                f.write("| 排名 | IP:端口 | 威胁分 | 实测握手延迟 | 官方带宽 | 综合评分 | SOCKS5 代理全路径 |\n")
                f.write("| :---: | :--- | :---: | :---: | :---: | :---: | :--- |\n")
                for i, res in enumerate(res_list, 1):
                    fscore_str = f"`{res.fraud_score}/100`" if res.fraud_score >= 0 else "`N/A`"
                    f.write(
                        f"| **{i}** | `{res.server.ip}:{res.tested_port}` | {fscore_str} | "
                        f"**{res.real_latency_ms:.2f} ms** | {res.server.speed_mbps:.2f} Mbps | "
                        f"{res.composite_score:.1f} | `{res.socks5_url}` |\n"
                    )
                f.write("\n")

        # 7. Export text status report
        status_path = os.path.join(self.output_dir, "status_report.txt")
        with open(status_path, "w", encoding="utf-8") as f:
            f.write(f"=========================================================================================\n")
            f.write(f"  VPNGATE 住宅代理池 7国巡检状态报告 (更新时间: {timestamp_str})\n")
            f.write(f"=========================================================================================\n")
            for c_code, c_zh in TARGET_COUNTRIES.items():
                r_list = self.pools.get(c_code, [])
                f.write(f"[{c_code}] {c_zh:<6}: {len(r_list):2d}/{self.top_per_country:2d} 个可用节点\n")
            f.write(f"-----------------------------------------------------------------------------------------\n")
            f.write(f"总活跃节点数: {len(all_flattened_nodes)} 个\n")
            f.write(f"=========================================================================================\n")

        logger.debug(f"💾 代理池数据与各格式文件已更新 ({self.output_dir}/)")

    def run_health_check_and_update(self) -> Dict[str, Any]:
        """
        Executes a complete 5-minute health check cycle:
        1. Tests all existing nodes in the pool.
        2. If all nodes are healthy and pool has targets -> Skip fetching VPNGATE.
        3. If dead nodes or shortages exist -> Fetch latest list, benchmark fresh candidates, and replace/fill.
        """
        cycle_start = datetime.now()
        logger.info(f"🔍 [5m周期巡检] 开始检测当前代理池中所有节点的连通性...")

        dead_nodes_by_country: Dict[str, List[BenchmarkResult]] = {c: [] for c in TARGET_COUNTRIES}
        healthy_nodes_by_country: Dict[str, List[BenchmarkResult]] = {c: [] for c in TARGET_COUNTRIES}
        countries_needing_refill: Set[str] = set()

        # Step 1: Health check every existing node in each country
        for country_code, res_list in self.pools.items():
            for res in res_list:
                # Re-test this specific node
                test_res = test_single_server(res.server, timeout=self.timeout, samples=self.samples)
                if test_res and test_res.reachable:
                    healthy_nodes_by_country[country_code].append(test_res)
                else:
                    dead_nodes_by_country[country_code].append(res)
                    logger.warning(f"❌ [{country_code}] 节点失效: {res.server.ip}:{res.tested_port} (丢包或不可达)")

            # Check if country pool is short of top_per_country
            if len(healthy_nodes_by_country[country_code]) < self.top_per_country:
                countries_needing_refill.add(country_code)

        # Update pools with only healthy nodes initially
        self.pools = healthy_nodes_by_country

        total_dead = sum(len(v) for v in dead_nodes_by_country.values())
        total_healthy = sum(len(v) for v in self.pools.values())

        # Step 2: 如果当前已有节点全部健康可用且没有任何失效节点 -> 直接跳过拉取刷新！
        if total_dead == 0 and total_healthy > 0:
            logger.info(f"✅ [5m周期巡检] 当前所有已持有节点共 {total_healthy} 个全部健康可用，跳过 VPNGATE 刷新！")
            self.save_state_and_export()
            return {
                "status": "all_healthy",
                "healthy_count": total_healthy,
                "replaced_count": 0,
                "filled_count": 0,
                "timestamp": cycle_start.strftime("%Y-%m-%d %H:%M:%S"),
            }

        # Step 3: 当有节点失效 (total_dead > 0) 或首次启动池为空 (total_healthy == 0) 时，从 VPNGATE 拉取
        if total_dead > 0:
            logger.info(f"⚠️ [5m周期巡检] 检测到 {total_dead} 个失效节点，准备从 VPNGATE 拉取候选节点进行 1 对 1 热替换...")
        else:
            logger.info(f"ℹ️ [初始构建] 代理池为空，准备从 VPNGATE 拉取候选节点构建 7 国初始代理池...")

        try:
            all_latest_servers = fetch_all_vpngate_servers()
        except Exception as e:
            logger.error(f"❌ 从 VPNGATE 获取最新列表失败: {e}，保留当前健康节点继续工作。")
            self.save_state_and_export()
            return {
                "status": "fetch_error",
                "healthy_count": total_healthy,
                "replaced_count": 0,
                "error": str(e),
                "timestamp": cycle_start.strftime("%Y-%m-%d %H:%M:%S"),
            }

        total_replaced = 0
        total_filled = 0

        # Step 4: Perform smart 1-for-1 replacement and refill per country
        for country_code in TARGET_COUNTRIES:
            dead_list = dead_nodes_by_country[country_code]
            current_healthy_count = len(self.pools[country_code])
            deficit = self.top_per_country - current_healthy_count

            if not dead_list and deficit <= 0:
                continue

            current_active_ips = self.get_all_active_ips()

            # Filter candidates for this country, excluding all active IPs
            candidates = [
                s for s in all_latest_servers
                if s.country_short == country_code and s.ip not in current_active_ips
            ]

            filtered_candidates = filter_servers(
                candidates,
                allowed_countries=[country_code],
                strict_residential=self.strict_residential,
                deduplicate=True
            )

            if not filtered_candidates:
                logger.info(f"ℹ️ [{country_code}] VPNGATE 暂无新增可用候选节点 (当前保有 {current_healthy_count} 个)")
                continue

            # Filter clean residential IPs (< 20 fraud score) via Scamalytics
            cache_file = os.path.join(self.output_dir, "scamalytics_cache.json")
            clean_candidates = filter_by_fraud_score(
                filtered_candidates,
                max_fraud_score=20,
                cache_path=cache_file
            )
            if not clean_candidates:
                logger.info(f"ℹ️ [{country_code}] VPNGATE 暂无符合 Scamalytics 威胁分 < 20 的纯净住宅节点 (已过滤机房与高危节点)")
                continue

            nodes_to_benchmark = clean_candidates

            # Benchmark candidate nodes
            logger.info(f"🚀 [{country_code}] 正在对 {len(nodes_to_benchmark)} 个纯净候选节点进行协议测速以补充节点...")
            benchmarked = benchmark_servers(
                nodes_to_benchmark,
                max_workers=min(self.threads, len(nodes_to_benchmark)),
                timeout=self.timeout,
                samples=self.samples
            )

            # Sort candidate results by composite score
            best_candidates = select_top_servers(benchmarked, top_n=len(benchmarked), sort_by="composite")

            # 1-for-1 replacement for dead nodes first
            cand_idx = 0
            for dead_node in dead_list:
                if cand_idx < len(best_candidates):
                    replacement = best_candidates[cand_idx]
                    self.pools[country_code].append(replacement)
                    total_replaced += 1
                    logger.info(
                        f"🔄 [{country_code}] 成功替换失效节点 {dead_node.server.ip}:{dead_node.tested_port} -> "
                        f"新节点 {replacement.server.ip}:{replacement.tested_port} "
                        f"(延迟: {replacement.real_latency_ms}ms, 带宽: {replacement.server.speed_mbps}Mbps)"
                    )
                    cand_idx += 1

            # Fill remaining deficit up to top_per_country
            while cand_idx < len(best_candidates) and len(self.pools[country_code]) < self.top_per_country:
                new_node = best_candidates[cand_idx]
                self.pools[country_code].append(new_node)
                total_filled += 1
                logger.info(
                    f"➕ [{country_code}] 补充新节点 {new_node.server.ip}:{new_node.tested_port} "
                    f"(延迟: {new_node.real_latency_ms}ms, 带宽: {new_node.server.speed_mbps}Mbps)"
                )
                cand_idx += 1

            # Re-sort country pool by composite score
            self.pools[country_code].sort(key=lambda x: (-x.composite_score, x.real_latency_ms))

        # Save and export all result files
        self.save_state_and_export()

        new_total_healthy = sum(len(v) for v in self.pools.values())
        logger.info(
            f"🎉 [5m周期巡检完成] 当前总可用节点: {new_total_healthy} 个 "
            f"(替换失效: {total_replaced} 个, 补充新增: {total_filled} 个)"
        )

        return {
            "status": "updated",
            "healthy_count": new_total_healthy,
            "replaced_count": total_replaced,
            "filled_count": total_filled,
            "timestamp": cycle_start.strftime("%Y-%m-%d %H:%M:%S"),
        }
