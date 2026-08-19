#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VPNGATE Results Exporter
Exports selected top residential proxies into TXT, JSON, Markdown, and OpenVPN profiles.
"""

import os
import json
import base64
import logging
from typing import List, Dict, Any
from datetime import datetime

from tester import BenchmarkResult

logger = logging.getLogger("vpngate.exporter")

# Country code to Emoji flag mapping
COUNTRY_FLAGS = {
    "JP": "🇯🇵", "KR": "🇰🇷", "US": "🇺🇸", "TW": "🇹🇼", "HK": "🇭🇰", "SG": "🇸🇬",
    "TH": "🇹🇭", "VN": "🇻🇳", "MY": "🇲🇾", "ID": "🇮🇩", "PH": "🇵🇭", "IN": "🇮🇳",
    "GB": "🇬🇧", "DE": "🇩🇪", "FR": "🇫🇷", "NL": "🇳🇱", "RU": "🇷🇺", "UA": "🇺🇦",
    "CA": "🇨🇦", "AU": "🇦🇺", "BR": "🇧🇷", "CO": "🇨🇴", "AR": "🇦🇷", "CL": "🇨🇱",
    "BY": "🇧🇾", "PL": "🇵🇱", "CZ": "🇨🇿", "RO": "🇷🇴", "HR": "🇭🇷", "BG": "🇧🇬",
    "TR": "🇹🇷", "ZA": "🇿🇦", "EG": "🇪🇬", "NZ": "🇳🇿", "MX": "🇲🇽", "UN": "🌐"
}


def get_country_flag(country_code: str) -> str:
    """Returns flag emoji for ISO country code."""
    return COUNTRY_FLAGS.get(country_code.upper(), "🌐")


def export_results(
    selected_results: List[BenchmarkResult],
    output_dir: str = "results",
    proxy_type: str = "socks5",
    save_ovpn: bool = False
) -> Dict[str, str]:
    """
    Exports benchmarked TOP servers into multiple formats.
    Returns a dictionary of generated file paths.
    """
    os.makedirs(output_dir, exist_ok=True)
    generated_files = {}

    timestamp_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # 1. Export pure proxy list: proxies.txt
    proxies_txt_path = os.path.join(output_dir, "proxies.txt")
    with open(proxies_txt_path, "w", encoding="utf-8") as f:
        for res in selected_results:
            if proxy_type == "http":
                f.write(f"{res.http_url}\n")
            elif proxy_type == "direct":
                f.write(f"{res.direct_address}\n")
            elif proxy_type == "noauth":
                f.write(f"{res.socks5_noauth_url}\n")
            elif proxy_type == "all":
                f.write(f"{res.socks5_url}\t{res.http_url}\t{res.direct_address}\n")
            else:  # default socks5
                f.write(f"{res.socks5_url}\n")
    generated_files["proxies_txt"] = proxies_txt_path

    # 2. Export upstream gateway string for cloudflare-vless-proxy: upstream_gateway.txt
    gateway_path = os.path.join(output_dir, "upstream_gateway.txt")
    if selected_results:
        # Best single node for DEFAULT_UPSTREAM_GATEWAY
        top_node = selected_results[0]
        with open(gateway_path, "w", encoding="utf-8") as f:
            f.write(f"{top_node.socks5_url}\n")
        generated_files["upstream_gateway"] = gateway_path

    # 3. Export detailed text report: vpngate_top20.txt
    report_txt_path = os.path.join(output_dir, "vpngate_top20.txt")
    with open(report_txt_path, "w", encoding="utf-8") as f:
        f.write(f"========================================================================================================\n")
        f.write(f"  VPNGATE 最优住宅 IP 代理精选 TOP {len(selected_results)} 列表 (更新时间: {timestamp_str})\n")
        f.write(f"========================================================================================================\n")
        f.write(f"{'排名':<4} | {'国家':<6} | {'IP地址:端口':<22} | {'实测延迟':<10} | {'官方带宽':<12} | {'综合得分':<10} | {'SOCKS5代理全路径'}\n")
        f.write(f"{'-'*4}-+-{'-'*6}-+-{'-'*22}-+-{'-'*10}-+-{'-'*12}-+-{'-'*10}-+-{'-'*40}\n")
        for i, res in enumerate(selected_results, 1):
            flag = get_country_flag(res.server.country_short)
            c_tag = f"{flag} {res.server.country_short}"
            addr = f"{res.server.ip}:{res.tested_port}"
            lat = f"{res.real_latency_ms:.2f} ms"
            spd = f"{res.server.speed_mbps:.2f} Mbps"
            score = f"{res.composite_score:.1f}"
            f.write(f"{i:<4d} | {c_tag:<6} | {addr:<22} | {lat:<10} | {spd:<12} | {score:<10} | {res.socks5_url}\n")
        f.write(f"========================================================================================================\n")
    generated_files["report_txt"] = report_txt_path

    # 4. Export rich JSON data: residential_nodes.json
    json_path = os.path.join(output_dir, "residential_nodes.json")
    json_data: List[Dict[str, Any]] = []
    for i, res in enumerate(selected_results, 1):
        json_data.append({
            "rank": i,
            "ip": res.server.ip,
            "port": res.tested_port,
            "country_short": res.server.country_short,
            "country_long": res.server.country_long,
            "flag": get_country_flag(res.server.country_short),
            "operator": res.server.operator,
            "real_latency_ms": res.real_latency_ms,
            "min_latency_ms": res.min_latency_ms,
            "max_latency_ms": res.max_latency_ms,
            "jitter_ms": res.jitter_ms,
            "packet_loss_rate": res.packet_loss_rate,
            "speed_mbps": res.server.speed_mbps,
            "composite_score": res.composite_score,
            "uptime_hours": round(res.server.uptime_seconds / 3600, 1),
            "sessions": res.server.sessions,
            "proxy_urls": {
                "socks5": res.socks5_url,
                "socks5_noauth": res.socks5_noauth_url,
                "http": res.http_url,
                "direct": res.direct_address
            }
        })

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump({
            "generated_at": timestamp_str,
            "total_selected": len(selected_results),
            "nodes": json_data
        }, f, indent=2, ensure_ascii=False)
    generated_files["nodes_json"] = json_path

    # 5. Export Markdown summary: summary.md
    md_path = os.path.join(output_dir, "summary.md")
    with open(md_path, "w", encoding="utf-8") as f:
        f.write(f"# 🌐 VPNGATE 最优住宅 IP 代理 TOP {len(selected_results)}\n\n")
        f.write(f"> ⏱️ **测速更新时间**：`{timestamp_str}`  \n")
        f.write(f"> 🚀 **精选节点数**：`{len(selected_results)}` 个高可用住宅/志愿网络代理\n\n")
        f.write("| 排名 | 国家/地区 | IP:端口 | 实测 TCP 延迟 | 官方带宽 | 综合评分 | 住宅 SOCKS5 代理全路径 |\n")
        f.write("| :---: | :---: | :--- | :---: | :---: | :---: | :--- |\n")
        for i, res in enumerate(selected_results, 1):
            flag = get_country_flag(res.server.country_short)
            f.write(
                f"| **{i}** | {flag} `{res.server.country_short}` ({res.server.country_long}) | "
                f"`{res.server.ip}:{res.tested_port}` | **{res.real_latency_ms:.2f} ms** | "
                f"{res.server.speed_mbps:.2f} Mbps | {res.composite_score:.1f} | "
                f"`{res.socks5_url}` |\n"
            )
        f.write("\n\n### 💡 使用方法\n")
        f.write("- **在 Cloudflare Worker VLESS 代理中使用**：将选出的 SOCKS5 代理填入控制台的 `DEFAULT_UPSTREAM_GATEWAY` 即可实现全链路住宅 IP 中继落地。\n")
        f.write("- **在 Clash / Sing-box / 客户端中使用**：直接导入 `proxies.txt` 中的 SOCKS5/HTTP 代理节点。\n")
    generated_files["summary_md"] = md_path

    # 6. Optionally export OpenVPN .ovpn files
    if save_ovpn:
        ovpn_dir = os.path.join(output_dir, "ovpn")
        os.makedirs(ovpn_dir, exist_ok=True)
        ovpn_count = 0
        for i, res in enumerate(selected_results, 1):
            if res.server.openvpn_config_b64:
                try:
                    ovpn_content = base64.b64decode(res.server.openvpn_config_b64).decode("utf-8", errors="ignore")
                    fname = f"{i:02d}_{res.server.country_short}_{res.server.ip}_{res.tested_port}.ovpn"
                    fpath = os.path.join(ovpn_dir, fname)
                    with open(fpath, "w", encoding="utf-8") as f:
                        f.write(ovpn_content)
                    ovpn_count += 1
                except Exception as e:
                    logger.debug(f"Failed to write ovpn for {res.server.ip}: {e}")
        logger.info(f"📁 已保存 {ovpn_count} 个 OpenVPN 配置文件至: {ovpn_dir}")
        generated_files["ovpn_dir"] = ovpn_dir

    logger.info(f"💾 结果已成功导出至: {output_dir}/")
    return generated_files
