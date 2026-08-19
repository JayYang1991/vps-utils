#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Scamalytics Fraud / Threat Score Checker
Queries scamalytics.com for IP threat score (0-100) and filters for pure residential IPs (< 20).
Includes high-concurrency batch query, memory & disk caching.
"""

import os
import re
import json
import time
import logging
import urllib.request
import urllib.error
import concurrent.futures
from typing import Dict, List, Optional, Tuple

logger = logging.getLogger("vpngate.fraud")

USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64; rv:123.0) Gecko/20100101 Firefox/123.0",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:123.0) Gecko/20100101 Firefox/123.0",
]

CACHE_FILE = "results/scamalytics_cache.json"
MEMORY_CACHE: Dict[str, Tuple[int, float]] = {}  # ip -> (score, timestamp)


def load_cache(cache_path: str = CACHE_FILE) -> None:
    """Loads cached fraud scores from JSON file."""
    global MEMORY_CACHE
    if os.path.exists(cache_path):
        try:
            with open(cache_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                now = time.time()
                for ip, item in data.items():
                    # 7-day cache validity
                    if isinstance(item, dict) and (now - item.get("ts", 0) < 7 * 86400):
                        MEMORY_CACHE[ip] = (item.get("score", 100), item.get("ts", now))
        except Exception:
            pass


def save_cache(cache_path: str = CACHE_FILE) -> None:
    """Saves memory cache to JSON file."""
    try:
        os.makedirs(os.path.dirname(os.path.abspath(cache_path)), exist_ok=True)
        data = {ip: {"score": sc, "ts": ts} for ip, (sc, ts) in MEMORY_CACHE.items()}
        with open(cache_path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
    except Exception:
        pass


def query_scamalytics_score(ip: str, timeout: int = 5, retries: int = 2) -> Optional[int]:
    """
    Queries scamalytics.com for the fraud score of a single IP.
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
    cache_path: Optional[str] = CACHE_FILE
) -> Dict[str, int]:
    """
    Queries fraud scores for a list of IPs concurrently with rate control and caching.
    """
    if cache_path:
        load_cache(cache_path)

    results: Dict[str, int] = {}
    missing_ips = [ip for ip in ips if ip not in MEMORY_CACHE]

    for ip in ips:
        if ip in MEMORY_CACHE:
            results[ip] = MEMORY_CACHE[ip][0]

    if missing_ips:
        logger.info(f"🛡️ 正在通过 Scamalytics 批量查询 {len(missing_ips)} 个候选节点的 IP 威胁分 (已命中缓存: {len(ips) - len(missing_ips)} 个)...")

        completed = 0
        total = len(missing_ips)

        with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
            future_to_ip = {executor.submit(query_scamalytics_score, ip, timeout): ip for ip in missing_ips}
            for future in concurrent.futures.as_completed(future_to_ip):
                ip = future_to_ip[future]
                completed += 1
                try:
                    score = future.result()
                    if score is not None:
                        results[ip] = score
                    else:
                        results[ip] = -1
                except Exception:
                    results[ip] = -1

                if completed % 20 == 0 or completed == total:
                    clean_so_far = sum(1 for sc in results.values() if 0 <= sc < 20)
                    logger.info(f"📊 威胁分查询进度: {completed}/{total} (已筛选出纯净住宅 IP: {clean_so_far} 个)")

        if cache_path:
            save_cache(cache_path)

    return results
