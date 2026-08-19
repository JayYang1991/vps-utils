#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VPNGATE Data Fetcher & Parser
Fetches live server lists from VPNGATE academic API with automatic fallback mirrors.
"""

import csv
import base64
import logging
import urllib.request
import urllib.error
from typing import List, Dict, Any, Optional
from dataclasses import dataclass, field

logger = logging.getLogger("vpngate.fetcher")

# Official and mirror endpoints for VPNGATE API
DEFAULT_VPNGATE_URLS = [
    "http://www.vpngate.net/api/iphone/",
    "https://www.vpngate.net/api/iphone/",
    "http://vpngate.net/api/iphone/",
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


def fetch_vpngate_csv(custom_url: Optional[str] = None, timeout: int = 15, max_retries: int = 3) -> str:
    """
    Fetches raw CSV string from VPNGATE API with fallback URLs.
    """
    urls_to_try = [custom_url] if custom_url else DEFAULT_VPNGATE_URLS

    for url in urls_to_try:
        if not url:
            continue
        for attempt in range(1, max_retries + 1):
            logger.info(f"正在从 VPNGATE 拉取服务器列表: {url} (尝试 {attempt}/{max_retries})...")
            req = urllib.request.Request(
                url,
                headers={
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                    "Accept": "text/csv,text/plain,*/*",
                }
            )
            try:
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    if resp.status == 200:
                        raw_data = resp.read().decode("utf-8", errors="ignore")
                        if "#HostName" in raw_data or "*vpn_servers" in raw_data:
                            logger.info(f"✅ 成功获取 VPNGATE 数据 (大小: {len(raw_data)} 字节)")
                            return raw_data
                        else:
                            logger.warning("⚠️ VPNGATE 返回数据缺少标准表头，准备重试...")
            except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as e:
                logger.warning(f"⚠️ 请求 {url} 失败: {e}")

    raise RuntimeError("无法从 VPNGATE API 或备用镜像获取服务器列表，请检查网络连接。")


def parse_vpngate_csv(raw_csv_text: str) -> List[VpnGateServer]:
    """
    Parses raw VPNGATE CSV string into structured VpnGateServer objects.
    """
    if not raw_csv_text:
        return []

    lines = [l.strip() for l in raw_csv_text.splitlines() if l.strip()]
    
    # Locate the header line starting with #HostName
    header_idx = -1
    for idx, line in enumerate(lines):
        if line.startswith("#HostName") or line.startswith("HostName"):
            header_idx = idx
            break

    if header_idx == -1:
        logger.error("未在 VPNGATE 响应数据中找到 #HostName 表头。")
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

    logger.info(f"成功解析出 {len(servers)} 个 VPNGATE 服务器节点")
    return servers
