#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VPNGATE Server Filter & Residential Classifier
Filters out invalid, private, or duplicate IPs and classifies residential broadband nodes.
"""

import ipaddress
import logging
from typing import List, Optional, Set
from fetcher import VpnGateServer

logger = logging.getLogger("vpngate.filter")

# Common residential broadband and telecom ISP keywords
RESIDENTIAL_ISP_KEYWORDS = [
    # Japan
    "ntt", "kddi", "softbank", "ocn", "so-net", "biglobe", "j:com", "eonet", "asahi-net",
    "optage", "ctc", "commufa", "ucom", "nifty", "plala", "dion", "bbtec", "tiki",
    # Korea
    "korea telecom", "kt", "sk broadband", "sk telecom", "lg u+", "lg uplus", "dacom", "hanaro", "tbroad",
    # Taiwan & Hong Kong
    "chunghwa", "hinet", "so-net", "taiwan mobile", "far eastone", "kbro", "hgc", "hkbn", "pccw", "i-cable",
    # Southeast Asia
    "true", "3bb", "ais", "tot", "cat", "vnpt", "viettel", "fpt", "tmnet", "unifi", "maxis", "time dotcom",
    "indihome", "telkom", "biznet", "myrepublic", "singtel", "starhub", "m1",
    # North America
    "comcast", "xfinity", "at&t", "verizon", "spectrum", "charter", "cox", "centurylink", "lumen", "frontier",
    "shaw", "rogers", "bell canada", "telus", "videotron", "optimum", "suddenlink", "windstream",
    # Europe & Others
    "bt", "british telecommunications", "virgin media", "vodafone", "talktalk", "sky broadband",
    "orange", "free sas", "sfr", "bouygues", "deutsche telekom", "telekom", "1&1", "o2", "telefonica",
    "swisscom", "kpn", "telenor", "telia", "tim", "fastweb", "wind tre", "rostelecom", "mts", "beeline",
]

# Datacenter / Cloud hosting keywords to de-prioritize or filter if strict residential is enabled
DATACENTER_KEYWORDS = [
    "amazon", "aws", "google", "microsoft", "azure", "digitalocean", "linode", "vultr",
    "ovh", "hetzner", "choopa", "leaseweb", "oracle", "alibaba", "tencent", "ucloud", "fastly", "cloudflare"
]


def is_valid_public_ip(ip_str: str) -> bool:
    """Checks whether the given IP is a valid public unicast IP address."""
    if not ip_str or not isinstance(ip_str, str):
        return False
    try:
        ip = ipaddress.ip_address(ip_str.strip())
        return not (ip.is_private or ip.is_loopback or ip.is_multicast or ip.is_unspecified or ip.is_reserved or ip.is_link_local)
    except ValueError:
        return False


def is_likely_residential(server: VpnGateServer) -> bool:
    """
    Checks if a VPNGATE server is likely hosted on a residential/volunteer broadband connection.
    Examines Operator, Hostname, and Message fields.
    """
    combined_text = f"{server.operator} {server.hostname} {server.message}".lower()

    # If operator contains academic volunteer note or university (SoftEther/Tsukuba)
    if "academic use only" in combined_text or "volunteer" in combined_text or "student" in combined_text or "home" in combined_text:
        return True

    # Check residential ISP signatures
    for kw in RESIDENTIAL_ISP_KEYWORDS:
        if kw in combined_text:
            return True

    # If it does not match known commercial cloud hosting, assume residential volunteer
    for dc_kw in DATACENTER_KEYWORDS:
        if dc_kw in combined_text:
            return False

    return True


def filter_servers(
    servers: List[VpnGateServer],
    allowed_countries: Optional[List[str]] = None,
    min_speed_mbps: float = 0.0,
    max_ping: int = 9999,
    strict_residential: bool = False,
    deduplicate: bool = True
) -> List[VpnGateServer]:
    """
    Applies filters (country, valid IP, speed, ping, deduplication) to VPNGATE servers.
    """
    filtered: List[VpnGateServer] = []
    seen_ips: Set[str] = set()

    normalized_countries = [c.strip().upper() for c in allowed_countries] if allowed_countries else None

    for server in servers:
        ip = server.ip.strip()

        # 1. Validate public IP
        if not is_valid_public_ip(ip):
            continue

        # 2. Deduplicate
        if deduplicate:
            if ip in seen_ips:
                continue
            seen_ips.add(ip)

        # 3. Country filter
        if normalized_countries and server.country_short not in normalized_countries:
            continue

        # 4. Minimum speed
        if min_speed_mbps > 0 and server.speed_mbps < min_speed_mbps:
            continue

        # 5. Maximum ping
        if server.ping > 0 and server.ping > max_ping:
            continue

        # 6. Strict residential check
        if strict_residential and not is_likely_residential(server):
            continue

        filtered.append(server)

    logger.info(f"过滤完成: 原始 {len(servers)} 个节点 -> 保留 {len(filtered)} 个候选节点")
    return filtered
