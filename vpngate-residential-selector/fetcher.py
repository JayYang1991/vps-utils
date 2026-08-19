#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VPNGATE Data Fetcher & Full Node Aggregator
Fetches and aggregates full server lists from official VPNGATE APIs, daily mirror sites (sites.aspx),
and real-time community mirrors, providing maximum server discovery.
"""

import os
import re
import csv
import json
import base64
import logging
import concurrent.futures
import urllib.request
import urllib.error
from typing import List, Dict, Any, Optional, Set
from dataclasses import dataclass, field

logger = logging.getLogger("vpngate.fetcher")

# Official base endpoints
DEFAULT_VPNGATE_URLS = [
    "http://www.vpngate.net/api/iphone/",
    "https://www.vpngate.net/api/iphone/",
    "http://vpngate.net/api/iphone/",
]

# Daily mirror index pages
VPNGATE_SITES_INDEX_URLS = [
    "http://www.vpngate.net/en/sites.aspx",
    "http://www.vpngate.net/cn/sites.aspx",
    "http://www.vpngate.net/ja/sites.aspx",
]

# Real-time community synchronization feeds
COMMUNITY_FEEDS = [
    "https://raw.githubusercontent.com/Pawdroid/Free-servers/main/vpngate.csv",
    "https://raw.githubusercontent.com/snakem982/vpngate-csver/main/vpngate.csv",
]


def safe_str(val: Any, default: str = "") -> str:
    """Safely convert value to stripped string."""
    if val is None:
        return default
    return str(val).strip()


def safe_int(val: Any, default: int = 0) -> int:
    """Safely convert string or object to int, stripping commas and handling '-'."""
    if val is None:
        return default
    try:
        cleaned = str(val).replace(",", "").strip()
        if not cleaned or cleaned == "-":
            return default
        return int(float(cleaned))
    except (ValueError, TypeError):
        return default


def safe_float(val: Any, default: float = 0.0) -> float:
    """Safely convert string or object to float."""
    if val is None:
        return default
    try:
        cleaned = str(val).replace(",", "").strip()
        if not cleaned or cleaned == "-":
            return default
        return float(cleaned)
    except (ValueError, TypeError):
        return default


@dataclass
class VpnGateServer:
    """Structured representation of a VPNGATE server."""
    hostname: str
    ip: str
    score: int
    ping: int
    speed_bps: int
    speed_mbps: float
    country_short: str
    country_long: str
    sessions: int
    uptime_seconds: int
    total_users: int
    total_traffic: int
    operator: str
    message: str
    openvpn_config_b64: str = ""
    port: int = 443
    proto: str = "tcp"
    extra_ports: List[int] = field(default_factory=list)
    fraud_score: int = -1

    @property
    def socks5_url(self) -> str:
        """Full SOCKS5 proxy URL with standard VPNGATE credentials."""
        return f"socks5://vpn:vpn@{self.ip}:{self.port}"

    @property
    def socks5_noauth_url(self) -> str:
        """SOCKS5 proxy URL without credentials."""
        return f"socks5://{self.ip}:{self.port}"

    @property
    def http_url(self) -> str:
        """Full HTTP proxy URL with standard credentials."""
        return f"http://vpn:vpn@{self.ip}:{self.port}"

    @property
    def direct_address(self) -> str:
        """Host:Port format (for upstream residential relay)."""
        return f"{self.ip}:{self.port}"


def extract_openvpn_info(ovpn_b64: str) -> Dict[str, Any]:
    """
    Extracts remote port, protocol, and alternative connection ports from base64 OpenVPN config.
    """
    info = {"port": 443, "proto": "tcp", "extra_ports": []}
    if not ovpn_b64:
        return info

    try:
        decoded = base64.b64decode(ovpn_b64).decode("utf-8", errors="ignore")
        for line in decoded.splitlines():
            line = line.strip()
            if line.startswith("proto "):
                parts = line.split()
                if len(parts) >= 2:
                    info["proto"] = parts[1].lower()
            elif line.startswith("remote "):
                parts = line.split()
                if len(parts) >= 3:
                    try:
                        p = int(parts[2])
                        if info["port"] == 443:
                            info["port"] = p
                        if p not in info["extra_ports"]:
                            info["extra_ports"].append(p)
                    except ValueError:
                        pass
    except Exception as e:
        logger.debug(f"Failed to parse OpenVPN config: {e}")

    return info


def discover_daily_mirrors(timeout: int = 4) -> List[str]:
    """Discovers active daily dynamic mirror URLs from sites.aspx pages."""
    discovered: Set[str] = set()
    for sites_url in VPNGATE_SITES_INDEX_URLS:
        try:
            req = urllib.request.Request(
                sites_url,
                headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
            )
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                if resp.status == 200:
                    html = resp.read().decode("utf-8", errors="ignore")
                    mirrors = re.findall(r'http://[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]+/', html)
                    discovered.update(mirrors)
                    if discovered:
                        break
        except Exception:
            continue
    return list(discovered)


def parse_vpngate_csv(raw_csv_text: str) -> List[VpnGateServer]:
    """
    Parses raw VPNGATE CSV string into structured VpnGateServer objects.
    """
    if not raw_csv_text:
        return []

    lines = [l.strip() for l in raw_csv_text.splitlines() if l.strip()]
    
    header_idx = -1
    for idx, line in enumerate(lines):
        if line.startswith("#HostName") or line.startswith("HostName"):
            header_idx = idx
            break

    if header_idx == -1:
        return []

    csv_data = lines[header_idx:]
    if csv_data[0].startswith("#"):
        csv_data[0] = csv_data[0][1:]

    reader = csv.DictReader(csv_data)
    servers: List[VpnGateServer] = []

    for row in reader:
        if not row:
            continue
        ip = safe_str(row.get("IP"))
        if not ip or ip.startswith("*") or ip == "IP":
            continue

        speed_bps = safe_int(row.get("Speed", 0))
        speed_mbps = round(speed_bps / (1024 * 1024), 2)
        ovpn_b64 = safe_str(row.get("OpenVPN_ConfigData_Base64"))
        ovpn_info = extract_openvpn_info(ovpn_b64)

        server = VpnGateServer(
            hostname=safe_str(row.get("HostName", row.get("#HostName", ""))),
            ip=ip,
            score=safe_int(row.get("Score", 0)),
            ping=safe_int(row.get("Ping", 0)),
            speed_bps=speed_bps,
            speed_mbps=speed_mbps,
            country_short=safe_str(row.get("CountryShort", "UN"), "UN").upper(),
            country_long=safe_str(row.get("CountryLong", "Unknown"), "Unknown"),
            sessions=safe_int(row.get("NumVpnSessions", 0)),
            uptime_seconds=safe_int(row.get("Uptime", 0)),
            total_users=safe_int(row.get("TotalUsers", 0)),
            total_traffic=safe_int(row.get("TotalTraffic", 0)),
            operator=safe_str(row.get("Operator", "")),
            message=safe_str(row.get("Message", "")),
            openvpn_config_b64=ovpn_b64,
            port=ovpn_info["port"],
            proto=ovpn_info["proto"],
            extra_ports=ovpn_info["extra_ports"]
        )
        servers.append(server)

    return servers


def _fetch_single_url(url: str, timeout: int = 8) -> List[VpnGateServer]:
    """Fetches and parses a single VPNGATE API or mirror URL."""
    try:
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Accept": "text/csv,text/plain,*/*",
            }
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status == 200:
                raw_data = resp.read().decode("utf-8", errors="ignore")
                if "#HostName" in raw_data or "*vpn_servers" in raw_data:
                    return parse_vpngate_csv(raw_data)
    except Exception:
        pass
    return []


def load_discovered_nodes_cache(cache_file: str) -> Dict[str, VpnGateServer]:
    """Loads previously discovered VPNGATE servers from cache file."""
    cached: Dict[str, VpnGateServer] = {}
    if os.path.exists(cache_file):
        try:
            with open(cache_file, "r", encoding="utf-8") as f:
                data = json.load(f)
                for item in data.get("nodes", []):
                    s = VpnGateServer(
                        hostname=item.get("hostname", ""),
                        ip=item.get("ip", ""),
                        score=item.get("score", 0),
                        ping=item.get("ping", 0),
                        speed_bps=item.get("speed_bps", 0),
                        speed_mbps=item.get("speed_mbps", 0.0),
                        country_short=item.get("country_short", "UN"),
                        country_long=item.get("country_long", "Unknown"),
                        sessions=item.get("sessions", 0),
                        uptime_seconds=item.get("uptime_seconds", 0),
                        total_users=item.get("total_users", 0),
                        total_traffic=item.get("total_traffic", 0),
                        operator=item.get("operator", ""),
                        message=item.get("message", ""),
                        openvpn_config_b64=item.get("openvpn_config_b64", ""),
                        port=item.get("port", 443),
                        proto=item.get("proto", "tcp"),
                        extra_ports=item.get("extra_ports", []),
                        fraud_score=item.get("fraud_score", -1)
                    )
                    if s.ip:
                        cached[s.ip] = s
            logger.info(f"📂 从本地历史沉淀库加载了 {len(cached)} 个已知 VPNGATE 节点")
        except Exception as e:
            logger.debug(f"读取历史沉淀节点库失败: {e}")
    return cached


def save_discovered_nodes_cache(cache_file: str, servers: List[VpnGateServer]) -> None:
    """Saves discovered VPNGATE servers to persistent JSON cache."""
    try:
        os.makedirs(os.path.dirname(os.path.abspath(cache_file)), exist_ok=True)
        data = {
            "updated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            "total_nodes": len(servers),
            "nodes": [
                {
                    "hostname": s.hostname,
                    "ip": s.ip,
                    "score": s.score,
                    "ping": s.ping,
                    "speed_bps": s.speed_bps,
                    "speed_mbps": s.speed_mbps,
                    "country_short": s.country_short,
                    "country_long": s.country_long,
                    "sessions": s.sessions,
                    "uptime_seconds": s.uptime_seconds,
                    "total_users": s.total_users,
                    "total_traffic": s.total_traffic,
                    "operator": s.operator,
                    "message": s.message,
                    "openvpn_config_b64": s.openvpn_config_b64,
                    "port": s.port,
                    "proto": s.proto,
                    "extra_ports": s.extra_ports,
                    "fraud_score": s.fraud_score,
                }
                for s in servers
            ]
        }
        with open(cache_file, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
    except Exception as e:
        logger.debug(f"保存历史沉淀节点库失败: {e}")


def fetch_all_vpngate_servers(
    custom_url: Optional[str] = None,
    timeout: int = 10,
    max_workers: int = 20,
    cache_file: Optional[str] = "results/all_discovered_nodes.json"
) -> List[VpnGateServer]:
    """
    Fetches and aggregates full server lists from official VPNGATE APIs,
    dynamic daily mirrors, and community feeds concurrently, merging with historical discovered pool.
    """
    if custom_url:
        servers = _fetch_single_url(custom_url, timeout=timeout)
        if servers:
            logger.info(f"✅ 从指定源成功获取 {len(servers)} 个 VPNGATE 节点 ({custom_url})")
            return servers

    logger.info("🌐 正在全量并发拉取 VPNGATE 官方接口、每日动态镜像与社区节点池...")

    all_target_urls: List[str] = list(DEFAULT_VPNGATE_URLS)

    # 1. Discover daily mirror endpoints
    daily_mirrors = discover_daily_mirrors(timeout=4)
    for m in daily_mirrors:
        all_target_urls.append(f"{m}api/iphone/")

    # 2. Add community sync feeds
    all_target_urls.extend(COMMUNITY_FEEDS)

    logger.info(f"📡 共发现并汇总了 {len(all_target_urls)} 个高可用数据采集源，正在并发拉取全量节点...")

    # Load historical node pool
    unique_servers: Dict[str, VpnGateServer] = {}
    if cache_file and os.path.exists(cache_file):
        unique_servers = load_discovered_nodes_cache(cache_file)

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_url = {executor.submit(_fetch_single_url, url, timeout): url for url in all_target_urls}
        for future in concurrent.futures.as_completed(future_to_url):
            url = future_to_url[future]
            try:
                s_list = future.result()
                if s_list:
                    logger.debug(f"  • 从源 {url} 成功提取 {len(s_list)} 个节点")
                    for s in s_list:
                        if s.ip not in unique_servers:
                            unique_servers[s.ip] = s
                        else:
                            # Merge extra ports & update with fresher stats
                            existing = unique_servers[s.ip]
                            for ep in s.extra_ports:
                                if ep not in existing.extra_ports:
                                    existing.extra_ports.append(ep)
                            if s.speed_bps > existing.speed_bps:
                                existing.speed_bps = s.speed_bps
                                existing.speed_mbps = s.speed_mbps
                            if s.score > existing.score:
                                existing.score = s.score
                            if not existing.openvpn_config_b64 and s.openvpn_config_b64:
                                existing.openvpn_config_b64 = s.openvpn_config_b64
            except Exception as e:
                logger.debug(f"拉取 {url} 出现异常: {e}")

    result_servers = list(unique_servers.values())
    if not result_servers:
        raise RuntimeError("无法从 VPNGATE API 或任何镜像拉取到服务器列表，请检查 VPS 外网连接。")

    # Save to persistent database
    if cache_file:
        save_discovered_nodes_cache(cache_file, result_servers)

    logger.info(f"🎉 全量聚合与历史沉淀完成！当前已知全球活跃 VPNGATE 节点总数: {len(result_servers)} 个！")
    return result_servers


def fetch_vpngate_csv(custom_url: Optional[str] = None, timeout: int = 15, max_retries: int = 3) -> str:
    """Compatibility wrapper that returns raw CSV from first responding endpoint."""
    urls = [custom_url] if custom_url else DEFAULT_VPNGATE_URLS
    for url in urls:
        if not url:
            continue
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read().decode("utf-8", errors="ignore")
        except Exception:
            continue
    return ""
