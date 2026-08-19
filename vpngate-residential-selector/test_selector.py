#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Unit test suite for VPNGATE Residential IP Selector.
"""

import os
import json
import base64
import unittest
from fetcher import safe_int, safe_float, parse_vpngate_csv, extract_openvpn_info, VpnGateServer
from filter import is_valid_public_ip, is_likely_residential, filter_servers
from tester import BenchmarkResult, select_top_servers
from exporter import export_results, get_country_flag


class TestVpnGateSelector(unittest.TestCase):

    def test_safe_converters(self):
        self.assertEqual(safe_int("1,000"), 1000)
        self.assertEqual(safe_int("-"), 0)
        self.assertEqual(safe_int(None, 42), 42)
        self.assertEqual(safe_int("invalid", 10), 10)

        self.assertAlmostEqual(safe_float("123.45"), 123.45)
        self.assertEqual(safe_float("-"), 0.0)
        self.assertEqual(safe_float(None, 3.14), 3.14)

    def test_extract_openvpn_info(self):
        sample_ovpn = (
            "client\n"
            "dev tun\n"
            "proto tcp\n"
            "remote 219.100.37.13 992\n"
            "remote 219.100.37.13 443\n"
        )
        b64 = base64.b64encode(sample_ovpn.encode()).decode()
        info = extract_openvpn_info(b64)
        self.assertEqual(info["proto"], "tcp")
        self.assertEqual(info["port"], 992)
        self.assertIn(443, info["extra_ports"])

    def test_parse_vpngate_csv(self):
        mock_csv = (
            "*vpn_servers\n"
            "#HostName,IP,Score,Ping,Speed,CountryLong,CountryShort,NumVpnSessions,Uptime,TotalUsers,TotalTraffic,LogType,Operator,Message,OpenVPN_ConfigData_Base64\n"
            "public-vpn-01,219.100.37.13,2990000,20,104857600,Japan,JP,50,3600,1000,5000000,2weeks,Volunteer User,Hello,\n"
            "public-vpn-02,125.132.8.21,1500000,15,52428800,Korea,KR,30,7200,800,3000000,2weeks,Korea Telecom,,\n"
            "*\n"
        )
        servers = parse_vpngate_csv(mock_csv)
        self.assertEqual(len(servers), 2)
        self.assertEqual(servers[0].ip, "219.100.37.13")
        self.assertEqual(servers[0].country_short, "JP")
        self.assertEqual(servers[0].speed_mbps, 100.0)
        self.assertEqual(servers[0].socks5_url, "socks5://vpn:vpn@219.100.37.13:443")
        self.assertEqual(servers[1].ip, "125.132.8.21")
        self.assertEqual(servers[1].country_short, "KR")
        self.assertEqual(servers[1].speed_mbps, 50.0)

    def test_ip_and_residential_filter(self):
        self.assertTrue(is_valid_public_ip("219.100.37.13"))
        self.assertTrue(is_valid_public_ip("1.1.1.1"))
        self.assertFalse(is_valid_public_ip("127.0.0.1"))
        self.assertFalse(is_valid_public_ip("192.168.1.1"))
        self.assertFalse(is_valid_public_ip("10.0.0.1"))
        self.assertFalse(is_valid_public_ip("invalid_ip"))

        s1 = VpnGateServer(
            hostname="vg.ntt.jp", ip="219.100.37.13", score=1000, ping=10,
            speed_bps=100, speed_mbps=10.0, country_short="JP", country_long="Japan",
            sessions=5, uptime_seconds=100, total_users=10, total_traffic=100,
            operator="NTT Broadband Volunteer", message=""
        )
        self.assertTrue(is_likely_residential(s1))

        s2 = VpnGateServer(
            hostname="ec2.amazonaws.com", ip="54.239.28.85", score=1000, ping=10,
            speed_bps=100, speed_mbps=10.0, country_short="US", country_long="United States",
            sessions=5, uptime_seconds=100, total_users=10, total_traffic=100,
            operator="AWS Datacenter", message=""
        )
        self.assertFalse(is_likely_residential(s2))

        # Test filter_servers
        filtered = filter_servers([s1, s2], allowed_countries=["JP"])
        self.assertEqual(len(filtered), 1)
        self.assertEqual(filtered[0].country_short, "JP")

    def test_select_top_servers(self):
        s1 = VpnGateServer(
            hostname="s1", ip="1.1.1.1", score=5000, ping=10, speed_bps=10, speed_mbps=100.0,
            country_short="JP", country_long="Japan", sessions=1, uptime_seconds=10,
            total_users=1, total_traffic=1, operator="", message=""
        )
        s2 = VpnGateServer(
            hostname="s2", ip="2.2.2.2", score=2000, ping=50, speed_bps=10, speed_mbps=50.0,
            country_short="KR", country_long="Korea", sessions=1, uptime_seconds=10,
            total_users=1, total_traffic=1, operator="", message=""
        )

        r1 = BenchmarkResult(
            server=s1, reachable=True, protocol="openvpn", real_latency_ms=10.0, min_latency_ms=9.0,
            max_latency_ms=11.0, jitter_ms=2.0, packet_loss_rate=0.0,
            tested_port=443, composite_score=1000.0
        )
        r2 = BenchmarkResult(
            server=s2, reachable=True, protocol="openvpn", real_latency_ms=80.0, min_latency_ms=75.0,
            max_latency_ms=85.0, jitter_ms=10.0, packet_loss_rate=0.0,
            tested_port=443, composite_score=300.0
        )

        top = select_top_servers([r2, r1], top_n=1, sort_by="composite")
        self.assertEqual(len(top), 1)
        self.assertEqual(top[0].server.ip, "1.1.1.1")

    def test_export_results(self):
        s = VpnGateServer(
            hostname="s1", ip="219.100.37.13", score=5000, ping=10, speed_bps=10, speed_mbps=100.0,
            country_short="JP", country_long="Japan", sessions=1, uptime_seconds=10,
            total_users=1, total_traffic=1, operator="", message=""
        )
        r = BenchmarkResult(
            server=s, reachable=True, protocol="openvpn", real_latency_ms=15.5, min_latency_ms=15.0,
            max_latency_ms=16.0, jitter_ms=1.0, packet_loss_rate=0.0,
            tested_port=443, composite_score=850.0
        )

        test_dir = "/home/jason/code/vps-utils/vpngate-residential-selector/results/test_output"
        files = export_results([r], output_dir=test_dir, proxy_type="socks5")

        self.assertTrue(os.path.exists(files["proxies_txt"]))
        self.assertTrue(os.path.exists(files["nodes_json"]))
        self.assertTrue(os.path.exists(files["summary_md"]))
        self.assertTrue(os.path.exists(files["report_txt"]))

        with open(files["proxies_txt"], "r", encoding="utf-8") as f:
            content = f.read().strip()
            self.assertEqual(content, "socks5://vpn:vpn@219.100.37.13:443")

        with open(files["nodes_json"], "r", encoding="utf-8") as f:
            data = json.load(f)
            self.assertEqual(data["total_selected"], 1)
            self.assertEqual(data["nodes"][0]["ip"], "219.100.37.13")

        self.assertEqual(get_country_flag("JP"), "🇯🇵")
        self.assertEqual(get_country_flag("KR"), "🇰🇷")

    def test_pool_manager_state_and_skip_refresh(self):
        import shutil
        from pool_manager import ResidentialPoolManager, TARGET_COUNTRIES
        test_dir = "/home/jason/code/vps-utils/vpngate-residential-selector/results/test_pool"
        if os.path.exists(test_dir):
            shutil.rmtree(test_dir, ignore_errors=True)
        os.makedirs(test_dir, exist_ok=True)

        manager = ResidentialPoolManager(output_dir=test_dir, top_per_country=2)
        self.assertEqual(len(manager.pools), len(TARGET_COUNTRIES))
        self.assertEqual(len(manager.pools["JP"]), 0)

        # Add a dummy node to JP
        s_jp = VpnGateServer(
            hostname="jp1", ip="219.100.37.13", score=5000, ping=10, speed_bps=10, speed_mbps=100.0,
            country_short="JP", country_long="Japan", sessions=1, uptime_seconds=10,
            total_users=1, total_traffic=1, operator="", message=""
        )
        r_jp = BenchmarkResult(
            server=s_jp, reachable=True, protocol="openvpn", real_latency_ms=10.0, min_latency_ms=9.0,
            max_latency_ms=11.0, jitter_ms=2.0, packet_loss_rate=0.0,
            tested_port=443, composite_score=1000.0
        )
        manager.pools["JP"].append(r_jp)
        manager.save_state_and_export()

        # Reload manager from saved state
        manager2 = ResidentialPoolManager(output_dir=test_dir, top_per_country=2)
        self.assertEqual(len(manager2.pools["JP"]), 1)
        self.assertEqual(manager2.pools["JP"][0].server.ip, "219.100.37.13")

        # Verify active IPs set
        active_ips = manager2.get_all_active_ips()
        self.assertIn("219.100.37.13", active_ips)

        if os.path.exists(test_dir):
            shutil.rmtree(test_dir, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
