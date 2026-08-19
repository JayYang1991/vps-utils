#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VPNGATE Concurrency Benchmark & Speed Tester
Measures TCP handshake latency, packet loss, and calculates composite scores for ranking.
"""

import time
import socket
import logging
from typing import List, Optional
from dataclasses import dataclass
from concurrent.futures import ThreadPoolExecutor, as_completed

from fetcher import VpnGateServer

logger = logging.getLogger("vpngate.tester")


@dataclass
class BenchmarkResult:
    """Benchmark test result for a single VPNGATE server."""
    server: VpnGateServer
    reachable: bool
    real_latency_ms: float
    min_latency_ms: float
    max_latency_ms: float
    jitter_ms: float
    packet_loss_rate: float
    tested_port: int
    composite_score: float

    @property
    def socks5_url(self) -> str:
        return f"socks5://vpn:vpn@{self.server.ip}:{self.tested_port}"

    @property
    def socks5_noauth_url(self) -> str:
        return f"socks5://{self.server.ip}:{self.tested_port}"

    @property
    def http_url(self) -> str:
        return f"http://vpn:vpn@{self.server.ip}:{self.tested_port}"

    @property
    def direct_address(self) -> str:
        return f"{self.server.ip}:{self.tested_port}"


def test_single_server(server: VpnGateServer, timeout: float = 2.5, samples: int = 3) -> Optional[BenchmarkResult]:
    """
    Performs multi-sample TCP connection testing on a server's primary and alternative ports.
    """
    ports_to_test = [server.port]
    for p in server.extra_ports:
        if p not in ports_to_test:
            ports_to_test.append(p)

    best_result = None

    for port in ports_to_test:
        latencies = []
        failed_count = 0

        for _ in range(samples):
            start = time.perf_counter()
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(timeout)
                sock.connect((server.ip, port))
                latency = (time.perf_counter() - start) * 1000.0
                sock.close()
                latencies.append(latency)
            except (socket.timeout, ConnectionRefusedError, OSError):
                failed_count += 1
            except Exception as e:
                failed_count += 1
                logger.debug(f"Connection error to {server.ip}:{port} - {e}")

        # If at least one sample succeeded
        if latencies:
            avg_lat = sum(latencies) / len(latencies)
            min_lat = min(latencies)
            max_lat = max(latencies)
            jitter = max_lat - min_lat if len(latencies) > 1 else 0.0
            loss_rate = failed_count / samples

            # Composite Score Calculation
            # Formula balances:
            # 1. Latency Score: 1000 / (avg_lat + 1) * 10 (lower latency = much higher score)
            # 2. Speed Score: speed_mbps * 2.0 (higher bandwidth = higher score)
            # 3. Loss Penalty: (1.0 - loss_rate) multiplier
            # 4. VPNGATE Quality Score: server.score / 10000.0
            latency_score = (1000.0 / (avg_lat + 1.0)) * 10.0
            speed_score = min(server.speed_mbps, 1000.0) * 2.0
            stability_multiplier = 1.0 - (loss_rate * 0.5)
            quality_score = min(server.score / 10000.0, 500.0)

            composite = (latency_score + speed_score + quality_score) * stability_multiplier

            res = BenchmarkResult(
                server=server,
                reachable=True,
                real_latency_ms=round(avg_lat, 2),
                min_latency_ms=round(min_lat, 2),
                max_latency_ms=round(max_lat, 2),
                jitter_ms=round(jitter, 2),
                packet_loss_rate=round(loss_rate, 2),
                tested_port=port,
                composite_score=round(composite, 2)
            )

            if best_result is None or res.real_latency_ms < best_result.real_latency_ms:
                best_result = res
                # If primary port works well with 0% loss, no need to probe other ports
                if loss_rate == 0.0:
                    break

    return best_result


def benchmark_servers(
    servers: List[VpnGateServer],
    max_workers: int = 30,
    timeout: float = 2.5,
    samples: int = 3
) -> List[BenchmarkResult]:
    """
    Benchmarks a list of VPNGATE servers concurrently.
    """
    results: List[BenchmarkResult] = []
    total = len(servers)

    if total == 0:
        return []

    logger.info(f"🚀 开始对 {total} 个 VPNGATE 节点执行高并发测速与连通性检测 (并发线程: {max_workers}, 超时: {timeout}s)...")
    start_time = time.time()

    completed_count = 0
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_server = {
            executor.submit(test_single_server, s, timeout, samples): s for s in servers
        }

        for future in as_completed(future_to_server):
            completed_count += 1
            try:
                res = future.result()
                if res and res.reachable:
                    results.append(res)
            except Exception as e:
                logger.debug(f"测速任务异常: {e}")

            if completed_count % 20 == 0 or completed_count == total:
                logger.info(f"📊 测速进度: {completed_count}/{total} (已发现 {len(results)} 个可用节点)")

    elapsed = time.time() - start_time
    logger.info(f"✅ 测速完成！耗时: {elapsed:.2f}s | 成功响应节点: {len(results)}/{total}")
    return results


def select_top_servers(results: List[BenchmarkResult], top_n: int = 20, sort_by: str = "composite") -> List[BenchmarkResult]:
    """
    Sorts benchmark results and selects the TOP N best servers.
    Sort strategies:
    - 'composite' (default): Best balance of real latency, bandwidth, and stability.
    - 'latency': Lowest real TCP latency first.
    - 'speed': Highest reported bandwidth speed first.
    """
    if not results:
        return []

    if sort_by == "latency":
        sorted_list = sorted(results, key=lambda x: (x.real_latency_ms, -x.server.speed_mbps))
    elif sort_by == "speed":
        sorted_list = sorted(results, key=lambda x: (-x.server.speed_mbps, x.real_latency_ms))
    else:
        # composite
        sorted_list = sorted(results, key=lambda x: (-x.composite_score, x.real_latency_ms))

    selected = sorted_list[:top_n]
    logger.info(f"🎯 已从 {len(results)} 个可用节点中精选出最优 TOP {len(selected)} 住宅代理")
    return selected
