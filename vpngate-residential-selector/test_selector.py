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

        import tempfile
        with tempfile.TemporaryDirectory() as test_dir:
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
        import tempfile
        from pool_manager import ResidentialPoolManager, TARGET_COUNTRIES

        with tempfile.TemporaryDirectory() as test_dir:
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

    def test_select_top_servers_by_country(self):
        from tester import select_top_servers_by_country

        s_jp1 = VpnGateServer(
            hostname="jp1", ip="1.1.1.1", score=5000, ping=10, speed_bps=10, speed_mbps=100.0,
            country_short="JP", country_long="Japan", sessions=1, uptime_seconds=10,
            total_users=1, total_traffic=1, operator="", message="", fraud_score=0
        )
        s_jp2 = VpnGateServer(
            hostname="jp2", ip="1.1.1.2", score=5000, ping=10, speed_bps=10, speed_mbps=100.0,
            country_short="JP", country_long="Japan", sessions=1, uptime_seconds=10,
            total_users=1, total_traffic=1, operator="", message="", fraud_score=15
        )
        s_us1 = VpnGateServer(
            hostname="us1", ip="2.2.2.1", score=5000, ping=10, speed_bps=10, speed_mbps=100.0,
            country_short="US", country_long="United States", sessions=1, uptime_seconds=10,
            total_users=1, total_traffic=1, operator="", message="", fraud_score=2
        )

        r_jp1 = BenchmarkResult(
            server=s_jp1, reachable=True, protocol="openvpn", real_latency_ms=20.0, min_latency_ms=19.0,
            max_latency_ms=21.0, jitter_ms=2.0, packet_loss_rate=0.0,
            tested_port=443, composite_score=1000.0, fraud_score=0
        )
        r_jp2 = BenchmarkResult(
            server=s_jp2, reachable=True, protocol="openvpn", real_latency_ms=20.0, min_latency_ms=19.0,
            max_latency_ms=21.0, jitter_ms=2.0, packet_loss_rate=0.0,
            tested_port=443, composite_score=600.0, fraud_score=15
        )
        r_us1 = BenchmarkResult(
            server=s_us1, reachable=True, protocol="openvpn", real_latency_ms=50.0, min_latency_ms=49.0,
            max_latency_ms=51.0, jitter_ms=2.0, packet_loss_rate=0.0,
            tested_port=443, composite_score=800.0, fraud_score=2
        )

        flattened, pools = select_top_servers_by_country([r_jp2, r_jp1, r_us1], top_per_country=1)
        self.assertIn("JP", pools)
        self.assertIn("US", pools)
        self.assertEqual(len(pools["JP"]), 1)
        # JP1 has fraud_score 0 (higher composite score), should rank 1st
        self.assertEqual(pools["JP"][0].server.ip, "1.1.1.1")
        self.assertEqual(len(pools["US"]), 1)
        self.assertEqual(pools["US"][0].server.ip, "2.2.2.1")
        self.assertEqual(len(flattened), 2)

    def test_resolve_bridge_node(self):
        import tempfile
        from bridge import resolve_bridge_node

        with tempfile.TemporaryDirectory() as test_dir:
            # Write a dummy residential_pool.json
            pool_path = os.path.join(test_dir, "residential_pool.json")
            data = {
                "pools": {
                    "JP": [
                        {"ip": "1.1.1.1", "port": 443, "country_short": "JP", "real_latency_ms": 10.0, "composite_score": 1000.0, "fraud_score": 0, "ovpn_b64": "ZHVtbXk="},
                        {"ip": "1.1.1.2", "port": 992, "country_short": "JP", "real_latency_ms": 15.0, "composite_score": 800.0, "fraud_score": 5, "ovpn_b64": "ZHVtbXk="}
                    ],
                    "US": [
                        {"ip": "2.2.2.1", "port": 443, "country_short": "US", "real_latency_ms": 60.0, "composite_score": 700.0, "fraud_score": 2, "ovpn_b64": "ZHVtbXk="}
                    ]
                }
            }
            with open(pool_path, "w", encoding="utf-8") as f:
                json.dump(data, f)

            # Test 1: Default to optimal node (JP 1.1.1.1)
            best = resolve_bridge_node(results_dir=test_dir)
            self.assertIsNotNone(best)
            self.assertEqual(best["ip"], "1.1.1.1")

            # Test 2: Filter by country US
            best_us = resolve_bridge_node(results_dir=test_dir, country="US")
            self.assertIsNotNone(best_us)
            self.assertEqual(best_us["ip"], "2.2.2.1")

            # Test 3: Specify manual node IP:port
            manual = resolve_bridge_node(results_dir=test_dir, target_node="1.1.1.2:992")
            self.assertIsNotNone(manual)
            self.assertEqual(manual["ip"], "1.1.1.2")
            self.assertEqual(manual["port"], 992)

    def test_pool_manager_dynamic_resort(self):
        import tempfile
        from pool_manager import ResidentialPoolManager

        with tempfile.TemporaryDirectory() as test_dir:
            manager = ResidentialPoolManager(output_dir=test_dir, top_per_country=2)

            s_jp_slow = VpnGateServer(
                hostname="jp_slow", ip="1.1.1.1", score=1000, ping=10, speed_bps=10, speed_mbps=20.0,
                country_short="JP", country_long="Japan", sessions=1, uptime_seconds=10,
                total_users=1, total_traffic=1, operator="", message="", fraud_score=10
            )
            r_jp_slow = BenchmarkResult(
                server=s_jp_slow, reachable=True, protocol="openvpn", real_latency_ms=100.0, min_latency_ms=90.0,
                max_latency_ms=110.0, jitter_ms=5.0, packet_loss_rate=0.0,
                tested_port=443, composite_score=300.0, fraud_score=10
            )

            s_jp_fast = VpnGateServer(
                hostname="jp_fast", ip="1.1.1.2", score=9000, ping=10, speed_bps=10, speed_mbps=100.0,
                country_short="JP", country_long="Japan", sessions=1, uptime_seconds=10,
                total_users=1, total_traffic=1, operator="", message="", fraud_score=0
            )
            r_jp_fast = BenchmarkResult(
                server=s_jp_fast, reachable=True, protocol="openvpn", real_latency_ms=15.0, min_latency_ms=14.0,
                max_latency_ms=16.0, jitter_ms=1.0, packet_loss_rate=0.0,
                tested_port=443, composite_score=1200.0, fraud_score=0
            )

            s_jp_dirty = VpnGateServer(
                hostname="jp_dirty", ip="1.1.1.3", score=9000, ping=10, speed_bps=10, speed_mbps=100.0,
                country_short="JP", country_long="Japan", sessions=1, uptime_seconds=10,
                total_users=1, total_traffic=1, operator="", message="", fraud_score=75
            )
            r_jp_dirty = BenchmarkResult(
                server=s_jp_dirty, reachable=True, protocol="openvpn", real_latency_ms=10.0, min_latency_ms=9.0,
                max_latency_ms=11.0, jitter_ms=1.0, packet_loss_rate=0.0,
                tested_port=443, composite_score=1500.0, fraud_score=75
            )

            # Insert in wrong order (slow first, dirty second, fast last)
            manager.pools["JP"] = [r_jp_slow, r_jp_dirty, r_jp_fast]
            manager.save_state_and_export()

            # Verify:
            # 1. Dirty (fraud_score 75) is filtered out
            # 2. Fast (composite 1200, fraud 0) is ranked #1
            # 3. Slow (composite 300, fraud 10) is ranked #2
            self.assertEqual(len(manager.pools["JP"]), 2)
            self.assertEqual(manager.pools["JP"][0].server.ip, "1.1.1.2")
            self.assertEqual(manager.pools["JP"][1].server.ip, "1.1.1.1")

            # Check exported upstream_gateway.txt points to #1 optimal node
            with open(os.path.join(test_dir, "upstream_gateway.txt"), "r") as f:
                self.assertIn("1.1.1.2", f.read())

    def test_pusher_unconfigured(self):
        import tempfile
        from pusher import CloudflareVlessPusher

        with tempfile.TemporaryDirectory() as test_dir:
            pusher = CloudflareVlessPusher(push_url="", api_token="", state_dir=test_dir)
            self.assertFalse(pusher.is_configured())

            s = VpnGateServer(
                hostname="s1", ip="219.100.37.13", score=5000, ping=10, speed_bps=10, speed_mbps=100.0,
                country_short="JP", country_long="Japan", sessions=1, uptime_seconds=10,
                total_users=1, total_traffic=1, operator="", message=""
            )
            r = BenchmarkResult(
                server=s, reachable=True, protocol="openvpn", real_latency_ms=15.0, min_latency_ms=14.0,
                max_latency_ms=16.0, jitter_ms=1.0, packet_loss_rate=0.0,
                tested_port=443, composite_score=1000.0
            )

            res = pusher.push_best_node_if_changed(r)
            self.assertEqual(res["status"], "unconfigured")

    def test_pusher_ovpn_generation_and_change_detection(self):
        import tempfile
        from unittest.mock import patch, MagicMock
        from pusher import CloudflareVlessPusher

        with tempfile.TemporaryDirectory() as test_dir:
            pusher = CloudflareVlessPusher(
                push_url="https://worker.domain.com/api/upstream",
                api_token="cf-push-secret-token-123",
                state_dir=test_dir
            )
            self.assertTrue(pusher.is_configured())

            # 节点 A
            s_a = VpnGateServer(
                hostname="node_a", ip="219.100.37.13", score=5000, ping=10, speed_bps=10, speed_mbps=100.0,
                country_short="JP", country_long="Japan", sessions=1, uptime_seconds=10,
                total_users=1, total_traffic=1, operator="", message=""
            )
            r_a = BenchmarkResult(
                server=s_a, reachable=True, protocol="openvpn", real_latency_ms=15.0, min_latency_ms=14.0,
                max_latency_ms=16.0, jitter_ms=1.0, packet_loss_rate=0.0,
                tested_port=443, composite_score=1000.0
            )

            # 1. 验证 .ovpn 内容生成
            ovpn = pusher.generate_ovpn_content(r_a)
            self.assertIn("remote 219.100.37.13 443", ovpn)
            self.assertIn("client", ovpn)

            # 2. 模拟第 1 次推送节点 A (Mock urllib.request.urlopen 返回 200)
            mock_resp = MagicMock()
            mock_resp.getcode.return_value = 200
            mock_resp.read.return_value = json.dumps({"success": True, "message": "Updated"}).encode("utf-8")
            mock_resp.__enter__.return_value = mock_resp

            with patch("urllib.request.urlopen", return_value=mock_resp) as mock_urlopen:
                push_res1 = pusher.push_best_node_if_changed(r_a)
                self.assertEqual(push_res1["status"], "success")
                self.assertEqual(push_res1["node_key"], "219.100.37.13:443")
                self.assertEqual(mock_urlopen.call_count, 1)

            # 验证本地状态文件已生成
            state = pusher.get_last_pushed_state()
            self.assertIsNotNone(state)
            self.assertEqual(state["node_key"], "219.100.37.13:443")

            # 3. 第 2 次推送相同的节点 A (约束 1: 相同节点跳过推送)
            with patch("urllib.request.urlopen") as mock_urlopen_2:
                push_res2 = pusher.push_best_node_if_changed(r_a)
                self.assertEqual(push_res2["status"], "skipped")
                self.assertEqual(push_res2["reason"], "unchanged")
                # 确认未发起任何网络请求！
                mock_urlopen_2.assert_not_called()

            # 4. 出现新的更优节点 B -> 触发推送
            s_b = VpnGateServer(
                hostname="node_b", ip="125.132.8.21", score=9000, ping=5, speed_bps=10, speed_mbps=200.0,
                country_short="KR", country_long="Korea", sessions=1, uptime_seconds=10,
                total_users=1, total_traffic=1, operator="", message=""
            )
            r_b = BenchmarkResult(
                server=s_b, reachable=True, protocol="openvpn", real_latency_ms=8.0, min_latency_ms=7.0,
                max_latency_ms=9.0, jitter_ms=0.5, packet_loss_rate=0.0,
                tested_port=995, composite_score=1500.0
            )

            with patch("urllib.request.urlopen", return_value=mock_resp) as mock_urlopen_3:
                push_res3 = pusher.push_best_node_if_changed(r_b)
                self.assertEqual(push_res3["status"], "success")
                self.assertEqual(push_res3["node_key"], "125.132.8.21:995")
                self.assertEqual(mock_urlopen_3.call_count, 1)

            # 验证状态更新为节点 B
            state_updated = pusher.get_last_pushed_state()
            self.assertEqual(state_updated["node_key"], "125.132.8.21:995")


if __name__ == "__main__":
    unittest.main()
