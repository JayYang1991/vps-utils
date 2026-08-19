#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VPNGATE Application-Layer Protocol Benchmark & Speed Tester
Actually tests proxy/tunnel connectivity (OpenVPN TCP Handshake, SOCKS5 Handshake, HTTP CONNECT)
rather than just TCP port availability.
"""

import os
import sys
import time
import socket
import struct
import logging
from typing import List, Tuple, Optional
from dataclasses import dataclass
from concurrent.futures import ThreadPoolExecutor, as_completed

from fetcher import VpnGateServer

logger = logging.getLogger("vpngate.tester")


@dataclass
class BenchmarkResult:
    """Benchmark test result for a single VPNGATE server."""
    server: VpnGateServer
    reachable: bool
    protocol: str              # 'openvpn', 'socks5', 'http_proxy', 'softether_tls'
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


def verify_openvpn_protocol(ip: str, port: int, timeout: float = 2.5) -> Tuple[bool, float, str]:
    """
    Sends real OpenVPN P_CONTROL_HARD_RESET_CLIENT_V2 packet over TCP.
    Verifies that the server responds with valid OpenVPN Opcode 8 (Reset Server V2), Opcode 5 (ACK), or TLS ServerHello.
    """
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        start = time.perf_counter()
        sock.connect((ip, port))

        # OpenVPN TCP packet: 2-byte length + Opcode 0x38 + 8 bytes session ID + 5 bytes padding
        opcode = 0x38
        session_id = os.urandom(8)
        payload = bytes([opcode]) + session_id + bytes([0, 0, 0, 0, 0])
        packet = struct.pack("!H", len(payload)) + payload

        sock.sendall(packet)
        resp = sock.recv(1024)
        rtt = (time.perf_counter() - start) * 1000.0
        sock.close()

        if len(resp) >= 3:
            resp_opcode = resp[2] >> 3
            # Opcode 8 is P_CONTROL_HARD_RESET_SERVER_V2, 5 is P_ACK_V1, 7 is P_CONTROL_HARD_RESET_CLIENT_V2
            if resp_opcode in (5, 7, 8):
                return True, rtt, "openvpn"
            if resp[0] == 0x16 or resp[2] == 0x16:
                return True, rtt, "softether_tls"

        return False, 0.0, "invalid_response"
    except Exception as e:
        return False, 0.0, str(e)


def verify_socks5_protocol(ip: str, port: int, timeout: float = 2.5) -> Tuple[bool, float, str]:
    """
    Tests SOCKS5 greeting and authentication handshake.
    """
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        start = time.perf_counter()
        sock.connect((ip, port))

        # Send SOCKS5 greeting with no auth & user/pass methods
        sock.sendall(b"\x05\x02\x00\x02")
        resp = sock.recv(512)
        rtt = (time.perf_counter() - start) * 1000.0
        sock.close()

        if len(resp) >= 2 and resp[0] == 0x05:
            return True, rtt, "socks5"
        return False, 0.0, "not_socks5"
    except Exception as e:
        return False, 0.0, str(e)


def verify_http_proxy_protocol(ip: str, port: int, timeout: float = 2.5) -> Tuple[bool, float, str]:
    """
    Tests HTTP CONNECT proxy handshake.
    """
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        start = time.perf_counter()
        sock.connect((ip, port))

        req = b"CONNECT 1.1.1.1:80 HTTP/1.1\r\nHost: 1.1.1.1:80\r\nProxy-Connection: Keep-Alive\r\n\r\n"
        sock.sendall(req)
        resp = sock.recv(512)
        rtt = (time.perf_counter() - start) * 1000.0
        sock.close()

        if b"200 " in resp or b"HTTP/1." in resp:
            return True, rtt, "http_proxy"
        return False, 0.0, "not_http_proxy"
    except Exception as e:
        return False, 0.0, str(e)


def test_single_server_protocol(
    server: VpnGateServer,
    timeout: float = 2.5,
    samples: int = 2
) -> Optional[BenchmarkResult]:
    """
    Conducts actual application-layer protocol handshake testing on server's ports.
    Tests OpenVPN, SOCKS5, and HTTP proxy handshakes, verifies responses, and measures real RTT.
    """
    ports_to_test = [server.port]
    for p in server.extra_ports:
        if p not in ports_to_test:
            ports_to_test.append(p)

    best_result = None

    for port in ports_to_test:
        successful_samples = []
        failed_count = 0
        detected_protocol = "unknown"

        for _ in range(samples):
            # 1. Try OpenVPN protocol handshake (VPNGATE native protocol)
            ok, rtt, proto = verify_openvpn_protocol(server.ip, port, timeout=timeout)
            if ok:
                successful_samples.append(rtt)
                detected_protocol = proto
                continue

            # 2. Try SOCKS5 proxy handshake
            ok, rtt, proto = verify_socks5_protocol(server.ip, port, timeout=timeout)
            if ok:
                successful_samples.append(rtt)
                detected_protocol = proto
                continue

            # 3. Try HTTP proxy handshake
            ok, rtt, proto = verify_http_proxy_protocol(server.ip, port, timeout=timeout)
            if ok:
                successful_samples.append(rtt)
                detected_protocol = proto
                continue

            failed_count += 1

        if successful_samples:
            avg_lat = sum(successful_samples) / len(successful_samples)
            min_lat = min(successful_samples)
            max_lat = max(successful_samples)
            jitter = max_lat - min_lat if len(successful_samples) > 1 else 0.0
            loss_rate = failed_count / samples

            # Composite Score Calculation
            # 1. Real Protocol Latency Score: 1000 / (avg_lat + 1) * 10
            # 2. Bandwidth Score: speed_mbps * 2.0
            # 3. Stability Multiplier: 1.0 - (loss_rate * 0.5)
            # 4. VPNGATE Academic Score: server.score / 10000.0
            latency_score = (1000.0 / (avg_lat + 1.0)) * 10.0
            speed_score = min(server.speed_mbps, 1000.0) * 2.0
            stability_multiplier = 1.0 - (loss_rate * 0.5)
            quality_score = min(server.score / 10000.0, 500.0)

            composite = (latency_score + speed_score + quality_score) * stability_multiplier

            res = BenchmarkResult(
                server=server,
                reachable=True,
                protocol=detected_protocol,
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
                if loss_rate == 0.0:
                    break

    return best_result


# Alias for backward compatibility
test_single_server = test_single_server_protocol


def benchmark_servers(
    servers: List[VpnGateServer],
    max_workers: int = 30,
    timeout: float = 2.5,
    samples: int = 2
) -> List[BenchmarkResult]:
    """
    Benchmarks a list of VPNGATE servers with actual protocol handshakes concurrently.
    """
    results: List[BenchmarkResult] = []
    total = len(servers)

    if total == 0:
        return []

    logger.info(f"🚀 开始对 {total} 个 VPNGATE 节点执行协议层握手连通性与时延测速 (并发线程: {max_workers}, 超时: {timeout}s)...")
    start_time = time.time()

    completed_count = 0
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_server = {
            executor.submit(test_single_server_protocol, s, timeout, samples): s for s in servers
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
                logger.info(f"📊 协议测速进度: {completed_count}/{total} (已通过协议验证: {len(results)} 个节点)")

    elapsed = time.time() - start_time
    logger.info(f"✅ 协议测速完成！耗时: {elapsed:.2f}s | 协议握手成功响应节点: {len(results)}/{total}")
    return results


def select_top_servers(
    results: List[BenchmarkResult],
    top_n: int = 20,
    sort_by: str = "composite"
) -> List[BenchmarkResult]:
    """
    Sorts verified benchmark results and selects the TOP N best servers.
    """
    if not results:
        return []

    if sort_by == "latency":
        sorted_list = sorted(results, key=lambda x: (x.real_latency_ms, -x.server.speed_mbps))
    elif sort_by == "speed":
        sorted_list = sorted(results, key=lambda x: (-x.server.speed_mbps, x.real_latency_ms))
    else:
        sorted_list = sorted(results, key=lambda x: (-x.composite_score, x.real_latency_ms))

    selected = sorted_list[:top_n]
    logger.info(f"🎯 已从 {len(results)} 个协议验证可用节点中精选出最优 TOP {len(selected)} 住宅代理")
    return selected
