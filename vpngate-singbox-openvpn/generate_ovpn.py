#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
VPNGate OVPN & Mapping Generator
- Parses VPNGate CSV list (from local file or downloaded via API/mirrors)
- Queries scamalytics.com for IP fraud / threat scores (0-100)
- Filters, validates, and retains only nodes with threat score < 20 (pure residential / low-risk)
- Sorts nodes by bandwidth speed in descending order
- Batch generates .ovpn profile files in the designated output directory
- Generates a structured nodes_mapping.json mapping file for container failover rotation
- Optionally updates the primary active client.ovpn with the fastest node
"""

import os
import re
import csv
import json
import time
import base64
import logging
import argparse
import ipaddress
import urllib.request
import urllib.error
import concurrent.futures
from datetime import datetime
from typing import List, Dict, Any, Optional, Tuple, Set

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] [GenerateOvpn] %(message)s'
)
logger = logging.getLogger("generate_ovpn")

# Default official and community endpoints for VPNGate CSV
DEFAULT_VPNGATE_URLS = [
    "http://www.vpngate.net/api/iphone/",
    "https://www.vpngate.net/api/iphone/",
    "https://raw.githubusercontent.com/snakem982/vpngate-csver/main/vpngate.csv",
    "https://raw.githubusercontent.com/Pawdroid/Free-servers/main/vpngate.csv",
]

USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64; rv:123.0) Gecko/20100101 Firefox/123.0",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:123.0) Gecko/20100101 Firefox/123.0",
]

MEMORY_CACHE: Dict[str, Tuple[int, float]] = {}  # ip -> (score, timestamp)


def safe_str(val: Any, default: str = "") -> str:
    """Safely convert value to stripped string."""
    if val is None:
        return default
    return str(val).strip()


def safe_int(val: Any, default: int = 0) -> int:
    """Safely convert string or object to int."""
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


def is_valid_public_ip(ip_str: str) -> bool:
    """Checks whether the given IP is a valid public unicast IP address."""
    if not ip_str or not isinstance(ip_str, str):
        return False
    try:
        ip = ipaddress.ip_address(ip_str.strip())
        return not (ip.is_private or ip.is_loopback or ip.is_multicast or ip.is_unspecified or ip.is_reserved or ip.is_link_local)
    except ValueError:
        return False


def get_default_config_dir() -> str:
    """Determine default config directory based on environment and system layout."""
    if os.environ.get("CONFIG_DIR"):
        return os.environ.get("CONFIG_DIR")
    if os.path.exists("/etc/vpngate-singbox-openvpn"):
        return "/etc/vpngate-singbox-openvpn"
    script_dir = os.path.dirname(os.path.abspath(__file__))
    local_cfg = os.path.join(script_dir, "config")
    if os.path.exists(local_cfg):
        return local_cfg
    return "./config"


def load_fraud_cache(cache_path: Optional[str] = None) -> None:
    """Loads cached fraud scores from JSON file (valid for 7 days)."""
    global MEMORY_CACHE
    if not cache_path or not os.path.exists(cache_path):
        return
    try:
        with open(cache_path, "r", encoding="utf-8") as f:
            data = json.load(f)
            now = time.time()
            for ip, item in data.items():
                if isinstance(item, dict) and (now - item.get("ts", 0) < 7 * 86400):
                    MEMORY_CACHE[ip] = (item.get("score", 100), item.get("ts", now))
    except Exception as e:
        logger.debug("Could not load fraud cache from %s: %s", cache_path, e)


def save_fraud_cache(cache_path: Optional[str] = None) -> None:
    """Saves memory cache to JSON file."""
    if not cache_path:
        return
    try:
        os.makedirs(os.path.dirname(os.path.abspath(cache_path)), exist_ok=True)
        data = {ip: {"score": sc, "ts": ts} for ip, (sc, ts) in MEMORY_CACHE.items()}
        with open(cache_path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
    except Exception as e:
        logger.debug("Could not save fraud cache to %s: %s", cache_path, e)


def query_scamalytics_score(ip: str, timeout: int = 5, retries: int = 2) -> Optional[int]:
    """
    Queries scamalytics.com for the fraud / threat score of a single IP.
    Returns integer 0-100, or None if query fails.
    """
    now = time.time()
    if ip in MEMORY_CACHE:
        score, ts = MEMORY_CACHE[ip]
        if now - ts < 7 * 86400:
            return score

    url = f"https://scamalytics.com/ip/{ip}"
    ua = USER_AGENTS[hash(ip) % len(USER_AGENTS)]
    headers = {
        "User-Agent": ua,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Cache-Control": "no-cache",
    }

    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                if resp.status == 200:
                    html = resp.read().decode("utf-8", errors="ignore")
                    match = re.search(r'Fraud Score:\s*([0-9]+)', html, re.IGNORECASE)
                    if match:
                        score = int(match.group(1))
                        MEMORY_CACHE[ip] = (score, now)
                        return score
                    json_match = re.search(r'\"score\":\s*\"?([0-9]+)\"?', html)
                    if json_match:
                        score = int(json_match.group(1))
                        MEMORY_CACHE[ip] = (score, now)
                        return score
        except Exception:
            if attempt < retries - 1:
                time.sleep(0.5)

    return None


def batch_query_fraud_scores(
    ips: List[str],
    max_workers: int = 15,
    timeout: int = 5,
    cache_path: Optional[str] = None
) -> Dict[str, int]:
    """
    Queries fraud scores for a list of IPs concurrently with caching and rate control.
    """
    if cache_path:
        load_fraud_cache(cache_path)

    results: Dict[str, int] = {}
    missing_ips = [ip for ip in ips if ip not in MEMORY_CACHE or (time.time() - MEMORY_CACHE[ip][1] >= 7 * 86400)]

    for ip in ips:
        if ip in MEMORY_CACHE and (time.time() - MEMORY_CACHE[ip][1] < 7 * 86400):
            results[ip] = MEMORY_CACHE[ip][0]

    if missing_ips:
        cached_count = len(ips) - len(missing_ips)
        logger.info(
            "🛡️ 正在通过 Scamalytics 批量并发查询 %d 个候选节点的 IP 威胁分 (已命中缓存: %d 个)...",
            len(missing_ips), cached_count
        )

        completed = 0
        total = len(missing_ips)

        with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
            future_to_ip = {executor.submit(query_scamalytics_score, ip, timeout): ip for ip in missing_ips}
            for future in concurrent.futures.as_completed(future_to_ip):
                ip = future_to_ip[future]
                completed += 1
                try:
                    score = future.result()
                    results[ip] = score if score is not None else -1
                except Exception:
                    results[ip] = -1

                if completed % 20 == 0 or completed == total:
                    clean_so_far = sum(1 for sc in results.values() if 0 <= sc < 20)
                    logger.info(
                        "📊 威胁分查询进度: %d/%d (已筛选出威胁分 < 20 节点: %d 个)",
                        completed, total, clean_so_far
                    )

        if cache_path:
            save_fraud_cache(cache_path)

    return results


def filter_servers_by_fraud_score(
    servers: List[Dict[str, Any]],
    max_threat_score: int = 20,
    max_workers: int = 15,
    cache_path: Optional[str] = None
) -> List[Dict[str, Any]]:
    """
    Filters candidate server list by Scamalytics threat score.
    Retains ONLY nodes with threat score < max_threat_score (pure residential / low risk).
    """
    if not servers:
        return []

    ips = [s["ip"] for s in servers]
    score_map = batch_query_fraud_scores(ips, max_workers=max_workers, cache_path=cache_path)

    clean_servers: List[Dict[str, Any]] = []
    for s in servers:
        ip = s["ip"]
        score = score_map.get(ip, -1)
        s["fraud_score"] = score
        s["threat_score"] = score
        # Retain if valid and strictly less than threshold (e.g. 0-19)
        if 0 <= score < max_threat_score:
            clean_servers.append(s)

    logger.info(
        "🛡️ Scamalytics 威胁分筛选完成: 候选 %d 个节点 -> 筛选出威胁分 < %d 的低风险节点 %d 个",
        len(servers), max_threat_score, len(clean_servers)
    )
    return clean_servers


def download_vpngate_csv(urls: Optional[List[str]] = None, timeout: int = 15) -> str:
    """Download VPNGate CSV data from available endpoints with automatic fallback."""
    candidate_urls = urls if urls else DEFAULT_VPNGATE_URLS
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "text/csv,text/plain,*/*"
    }

    for url in candidate_urls:
        if not url:
            continue
        logger.info("Attempting to download VPNGate CSV from: %s", url)
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                if resp.status == 200:
                    content = resp.read().decode("utf-8", errors="ignore")
                    if "#HostName" in content or "*vpn_servers" in content:
                        logger.info("Successfully fetched %d bytes from %s", len(content), url)
                        return content
                    else:
                        logger.warning("Downloaded data from %s does not contain valid VPNGate header.", url)
        except Exception as e:
            logger.warning("Failed to download from %s: %s", url, e)

    raise RuntimeError("Failed to download VPNGate CSV from all candidate endpoints.")


def extract_port_and_proto_from_ovpn(ovpn_text: str) -> Tuple[str, str]:
    """Extract port and proto from OpenVPN config text."""
    port = "443"
    proto = "tcp"

    # Match proto directive (on a single line, horizontal whitespace only)
    proto_match = re.search(r'^[ \t]*proto[ \t]+([a-zA-Z0-9_-]+)', ovpn_text, flags=re.MULTILINE | re.IGNORECASE)
    if proto_match:
        p = proto_match.group(1).lower()
        if p.startswith("tcp") or p.startswith("udp"):
            proto = p

    # Match remote directive: remote <host> <port> [proto] (on a single line, horizontal whitespace only)
    port_match = re.search(r'^[ \t]*remote[ \t]+[^ \t\r\n]+[ \t]+(\d+)(?:[ \t]+([a-zA-Z0-9_-]+))?', ovpn_text, flags=re.MULTILINE | re.IGNORECASE)
    if port_match:
        port = port_match.group(1)
        if port_match.group(2):
            p = port_match.group(2).lower()
            if p.startswith("tcp") or p.startswith("udp"):
                proto = p

    return port, proto


def sanitize_name(name: str) -> str:
    """Sanitize string for safe filenames."""
    return re.sub(r'[\s/\\:*?"<>|]+', '_', name).strip('_')


def parse_vpngate_csv_content(
    csv_text: str,
    country_filter: Optional[List[str]] = None,
    min_speed_mbps: float = 0.0,
    limit: int = 0
) -> List[Dict[str, Any]]:
    """Parse raw CSV string and return list of valid server dictionaries sorted by speed descending."""
    lines = [l for l in csv_text.splitlines() if l.strip()]
    if not lines:
        return []

    header_idx = -1
    for idx, line in enumerate(lines):
        if "#HostName" in line or "HostName" in line:
            header_idx = idx
            break

    if header_idx == -1:
        logger.error("Could not find '#HostName' header in CSV content.")
        return []

    header_line = lines[header_idx].lstrip("#").strip()
    headers = [h.strip() for h in header_line.split(",")]

    reader = csv.DictReader(lines[header_idx + 1:], fieldnames=headers)
    servers = []

    normalized_country_filter = (
        [c.strip().upper() for c in country_filter if c.strip()]
        if country_filter else []
    )

    for row in reader:
        if not row:
            continue

        ip = safe_str(row.get("IP"))
        if not ip or ip.startswith("*") or ip == "IP" or not is_valid_public_ip(ip):
            continue

        b64_data = safe_str(row.get("OpenVPN_ConfigData_Base64"))
        if not b64_data:
            continue

        speed_bps = safe_float(row.get("Speed", 0))
        speed_mbps = round(speed_bps / 1_000_000, 2)

        if min_speed_mbps > 0 and speed_mbps < min_speed_mbps:
            continue

        country_short = safe_str(row.get("CountryShort", "UN"), "UN").upper()
        country_long = safe_str(row.get("CountryLong", "Unknown"), "Unknown")

        if normalized_country_filter:
            # 1. Direct match on 2-letter country short code (e.g. JP, US, KR, HK, SG, TW)
            c_short_match = country_short in normalized_country_filter
            # 2. Exact or substring match on country long name ONLY when filter item is long name (>2 chars)
            # To avoid 2-letter code "US" matching "CYPRUS", "BELARUS", "MAURITIUS", "RUSSIAN FEDERATION" etc.
            c_long_match = any(
                (cf == country_long.upper() or (len(cf) > 2 and cf in country_long.upper()))
                for cf in normalized_country_filter
            )
            if not (c_short_match or c_long_match):
                continue

        ping = safe_int(row.get("Ping", 0))
        score = safe_int(row.get("Score", 0))
        hostname = safe_str(row.get("HostName", row.get("#HostName", "")))

        servers.append({
            "hostname": hostname,
            "ip": ip,
            "score": score,
            "ping": ping,
            "speed_bps": speed_bps,
            "speed_mbps": speed_mbps,
            "country_short": country_short,
            "country_long": country_long,
            "b64_data": b64_data
        })

    # Sort servers by speed descending (highest speed first), secondarily by score
    servers.sort(key=lambda s: (s["speed_mbps"], s["score"]), reverse=True)

    if limit > 0:
        servers = servers[:limit]

    return servers


def process_vpngate_csv(
    csv_source: str,
    target_dir: str,
    mapping_output: str,
    country_filter: Optional[List[str]] = None,
    min_speed_mbps: float = 0.0,
    limit: int = 0,
    clean_target_dir: bool = False,
    update_active_client: bool = True,
    max_threat_score: int = 20,
    skip_fraud_check: bool = False,
    fraud_cache_path: Optional[str] = None,
    fraud_workers: int = 15
) -> Dict[str, Any]:
    """
    Process VPNGate CSV data:
    1. Reads from local file or downloads from URL / default endpoints.
    2. Parses candidate nodes matching speed and country criteria.
    3. Checks Scamalytics threat scores and keeps only clean nodes (< max_threat_score).
    4. Sorts clean nodes by speed descending and applies limit.
    5. Writes individual .ovpn files to target_dir.
    6. Writes structured mapping JSON to mapping_output.
    7. Optionally copies top node to client.ovpn in config dir.
    """
    target_dir = os.path.abspath(target_dir)
    mapping_output = os.path.abspath(mapping_output)
    config_dir = os.path.dirname(mapping_output)

    cache_path = os.path.abspath(fraud_cache_path) if fraud_cache_path else os.path.join(config_dir, "scamalytics_cache.json")

    os.makedirs(target_dir, exist_ok=True)
    os.makedirs(config_dir, exist_ok=True)

    csv_text = ""
    if csv_source and os.path.isfile(csv_source):
        logger.info("Reading local CSV file: %s", csv_source)
        with open(csv_source, "r", encoding="utf-8", errors="ignore") as f:
            csv_text = f.read()
    elif csv_source and (csv_source.startswith("http://") or csv_source.startswith("https://")):
        logger.info("Downloading CSV from custom URL: %s", csv_source)
        csv_text = download_vpngate_csv([csv_source])
    else:
        logger.info("No local CSV specified. Fetching latest CSV from VPNGate endpoints...")
        csv_text = download_vpngate_csv()

    if not csv_text.strip():
        raise ValueError("CSV data is empty or could not be loaded.")

    servers = parse_vpngate_csv_content(
        csv_text,
        country_filter=country_filter,
        min_speed_mbps=min_speed_mbps,
        limit=0
    )

    logger.info("Found %d candidate nodes matching country & speed criteria.", len(servers))
    if not servers:
        logger.warning("No valid nodes found in CSV data.")
        return {}

    # Scamalytics threat score filtering (< max_threat_score)
    if not skip_fraud_check:
        servers = filter_servers_by_fraud_score(
            servers,
            max_threat_score=max_threat_score,
            max_workers=fraud_workers,
            cache_path=cache_path
        )
        if not servers:
            logger.warning("No nodes passed the Scamalytics threat score check (< %d).", max_threat_score)

    if limit > 0:
        servers = servers[:limit]

    if clean_target_dir and os.path.exists(target_dir):
        for f in os.listdir(target_dir):
            if f.endswith(".ovpn"):
                try:
                    os.remove(os.path.join(target_dir, f))
                except Exception:
                    pass

    generated_nodes: List[Dict[str, Any]] = []
    nodes_map: Dict[str, Dict[str, Any]] = {}
    used_filenames: Set[str] = set()

    for idx, s in enumerate(servers):
        ip = s["ip"]
        country_clean = sanitize_name(s["country_long"] or s["country_short"])
        b64_data = s["b64_data"]

        try:
            ovpn_bytes = base64.b64decode(b64_data)
            ovpn_text = ovpn_bytes.decode("utf-8", errors="ignore")

            port, proto = extract_port_and_proto_from_ovpn(ovpn_text)
            node_id = f"{country_clean}_{ip}_{port}"

            file_name = f"{node_id}.ovpn"
            counter = 1
            while file_name in used_filenames:
                file_name = f"{country_clean}_{ip}_{port}_{counter}.ovpn"
                counter += 1
            used_filenames.add(file_name)

            full_file_path = os.path.join(target_dir, file_name)
            rel_path = os.path.relpath(full_file_path, config_dir)

            with open(full_file_path, "wb") as f:
                f.write(ovpn_bytes)

            fraud_score = s.get("fraud_score", s.get("threat_score", 0))
            node_item = {
                "id": node_id,
                "filename": file_name,
                "rel_path": rel_path,
                "path": full_file_path,
                "ip": ip,
                "port": port,
                "proto": proto,
                "country": s["country_long"],
                "country_short": s["country_short"],
                "speed_mbps": s["speed_mbps"],
                "ping": s["ping"],
                "score": s["score"],
                "fraud_score": fraud_score,
                "threat_score": fraud_score
            }

            generated_nodes.append(node_item)
            nodes_map[node_id] = node_item

        except Exception as e:
            logger.warning("Failed to decode or save node %s: %s", ip, e)

    mapping_data = {
        "updated_at": datetime.now().isoformat(),
        "total_nodes": len(generated_nodes),
        "nodes": generated_nodes,
        "nodes_map": nodes_map
    }

    with open(mapping_output, "w", encoding="utf-8") as f:
        json.dump(mapping_data, f, indent=2, ensure_ascii=False)

    logger.info("Successfully generated %d .ovpn files to: %s", len(generated_nodes), target_dir)
    logger.info("Mapping manifest saved to: %s", mapping_output)

    if update_active_client and generated_nodes:
        top_node = generated_nodes[0]
        client_ovpn_path = os.path.join(config_dir, "client.ovpn")
        try:
            with open(top_node["path"], "r", encoding="utf-8", errors="ignore") as src_f:
                content = src_f.read()
            with open(client_ovpn_path, "w", encoding="utf-8") as dst_f:
                dst_f.write(content)
            logger.info("Active default client.ovpn updated to Top #1 Node: %s (%s Mbps, Threat Score: %s)",
                        top_node["id"], top_node["speed_mbps"], top_node.get("threat_score", "N/A"))
        except Exception as e:
            logger.warning("Could not update client.ovpn: %s", e)

    return mapping_data


def main():
    default_cfg = get_default_config_dir()
    default_outdir = os.path.join(default_cfg, "ovpn_nodes")
    default_mapping = os.path.join(default_cfg, "nodes_mapping.json")
    default_cache = os.path.join(default_cfg, "scamalytics_cache.json")

    parser = argparse.ArgumentParser(
        description="VPNGate OVPN & Mapping Generator: Parses VPNGate CSV, filters low-risk nodes via Scamalytics (<20), and generates sorted .ovpn nodes and JSON mapping."
    )

    parser.add_argument(
        "-s", "--source", default="",
        help="Source CSV file path, remote URL, or leave empty to auto-download from VPNGate"
    )
    parser.add_argument(
        "-d", "--outdir", default=default_outdir,
        help=f"Target directory for output .ovpn files (default: {default_outdir})"
    )
    parser.add_argument(
        "-m", "--mapping", default=default_mapping,
        help=f"Target path for nodes_mapping.json (default: {default_mapping})"
    )
    parser.add_argument(
        "-c", "--country", "--country-code", default="", dest="country",
        help="Filter nodes by country short code or name (e.g. 'JP' or 'JP,US,KR')"
    )
    parser.add_argument(
        "--min-speed", type=float, default=0.0,
        help="Minimum bandwidth speed threshold in Mbps (default: 0.0)"
    )
    parser.add_argument(
        "-l", "--limit", type=int, default=100,
        help="Maximum number of top-speed nodes to generate (default: 100, 0=unlimited)"
    )
    parser.add_argument(
        "--clean", action="store_true",
        help="Clean destination .ovpn files before generating new ones"
    )
    parser.add_argument(
        "--no-active-update", action="store_true",
        help="Do not overwrite client.ovpn with top-speed node"
    )
    parser.add_argument(
        "--max-threat-score", "--max-fraud-score", type=int, default=20, dest="max_threat_score",
        help="Maximum allowed Scamalytics threat score threshold (default: 20, nodes with score >= threshold are excluded)"
    )
    parser.add_argument(
        "--skip-fraud-check", action="store_true",
        help="Skip Scamalytics IP threat score verification"
    )
    parser.add_argument(
        "--fraud-cache", default=default_cache,
        help=f"Path to Scamalytics cache JSON file (default: {default_cache})"
    )
    parser.add_argument(
        "-w", "--workers", type=int, default=15,
        help="Concurrency workers for Scamalytics batch queries (default: 15)"
    )

    args = parser.parse_args()

    country_filter = [c.strip() for c in args.country.split(",") if c.strip()] if args.country else None

    logger.info("============================================================")
    logger.info(" Starting VPNGate OVPN Node Generator")
    logger.info(" Source:           %s", args.source or "[Auto-Download from VPNGate]")
    logger.info(" Output Dir:       %s", args.outdir)
    logger.info(" Mapping File:     %s", args.mapping)
    logger.info(" Limit:            %s", args.limit if args.limit > 0 else "Unlimited")
    if country_filter:
        logger.info(" Country:          %s", ", ".join(country_filter))
    if args.min_speed > 0:
        logger.info(" Min Speed:        %s Mbps", args.min_speed)
    if not args.skip_fraud_check:
        logger.info(" Scamalytics Max:  Threat Score < %d", args.max_threat_score)
        logger.info(" Fraud Cache:      %s", args.fraud_cache)
        logger.info(" Workers:          %d", args.workers)
    else:
        logger.info(" Scamalytics:      SKIPPED (--skip-fraud-check)")
    logger.info("============================================================")

    try:
        process_vpngate_csv(
            csv_source=args.source,
            target_dir=args.outdir,
            mapping_output=args.mapping,
            country_filter=country_filter,
            min_speed_mbps=args.min_speed,
            limit=args.limit,
            clean_target_dir=args.clean,
            update_active_client=not args.no_active_update,
            max_threat_score=args.max_threat_score,
            skip_fraud_check=args.skip_fraud_check,
            fraud_cache_path=args.fraud_cache,
            fraud_workers=args.workers
        )
        logger.info("Execution finished successfully!")
    except Exception as e:
        logger.exception("Error during execution: %s", e)
        exit(1)


if __name__ == '__main__':
    main()

