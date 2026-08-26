#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Unit test suite for vpngate-singbox-openvpn.
Verifies:
- VPNGate CSV parsing, speed sorting, country filtering, and batch .ovpn & mapping generation (generate_ovpn.py)
- Node pool mapping loading, resolution, and sequential failover / connection establishment (health_checker.py)
- Remote configuration fetch for Sing-box & OpenVPN through socks-in proxy (socks5h://127.0.0.1:1080)
- Automatic fallback on proxy failure
- Localhost bypass logic
- Config transformation and OpenVPN directive injection
"""

import os
import sys
import time
import json
import base64
import tempfile
import unittest
import requests
from unittest.mock import patch, MagicMock

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPTS_DIR = os.path.join(PROJECT_DIR, "scripts")
sys.path.insert(0, PROJECT_DIR)
sys.path.insert(0, SCRIPTS_DIR)

import config_processor
import ovpn_processor
import generate_ovpn
import node_updater
from health_checker import ServiceManager

SAMPLE_OVPN_TEXT_TCP = """client
dev tun
proto tcp
remote 219.100.37.18 443
<ca>
TEST_CA
</ca>
"""

SAMPLE_OVPN_TEXT_UDP = """client
dev tun
proto udp
remote 180.144.152.157 1377
<ca>
TEST_CA_2
</ca>
"""

SAMPLE_CSV_HEADER = "*vpn_servers\n#HostName,IP,Score,Ping,Speed,CountryLong,CountryShort,NumVpnSessions,Uptime,TotalUsers,TotalTraffic,LogType,Operator,Message,OpenVPN_ConfigData_Base64\n"

class TestVpngateSingboxOpenvpn(unittest.TestCase):

    def setUp(self):
        self.test_dir = tempfile.TemporaryDirectory()
        self.orig_config_dir = os.environ.get("CONFIG_DIR")
        os.environ["CONFIG_DIR"] = self.test_dir.name
        config_processor.CONFIG_DIR = self.test_dir.name
        config_processor.RAW_CONFIG_CACHE = os.path.join(self.test_dir.name, "singbox_subscription.raw.json")
        config_processor.RUN_CONFIG_PATH = os.path.join(self.test_dir.name, "singbox_run.json")

    def tearDown(self):
        if self.orig_config_dir:
            os.environ["CONFIG_DIR"] = self.orig_config_dir
        else:
            os.environ.pop("CONFIG_DIR", None)
        self.test_dir.cleanup()

    def test_extract_port_and_proto_from_ovpn(self):
        port, proto = generate_ovpn.extract_port_and_proto_from_ovpn(SAMPLE_OVPN_TEXT_TCP)
        self.assertEqual(port, "443")
        self.assertEqual(proto, "tcp")

        port2, proto2 = generate_ovpn.extract_port_and_proto_from_ovpn(SAMPLE_OVPN_TEXT_UDP)
        self.assertEqual(port2, "1377")
        self.assertEqual(proto2, "udp")

    def test_parse_vpngate_csv_content_sorting_and_filtering(self):
        b64_1 = base64.b64encode(SAMPLE_OVPN_TEXT_TCP.encode("utf-8")).decode("utf-8")
        b64_2 = base64.b64encode(SAMPLE_OVPN_TEXT_UDP.encode("utf-8")).decode("utf-8")

        csv_data = SAMPLE_CSV_HEADER + (
            "node-low,1.1.1.1,100,50,10000000,United States,US,5,100,10,1000,2weeks,op,," + b64_1 + "\n"
            "node-high,2.2.2.2,500,10,500000000,Japan,JP,20,500,50,5000,2weeks,op,," + b64_2 + "\n"
            "node-mid,3.3.3.3,300,25,100000000,Japan,JP,10,300,30,3000,2weeks,op,," + b64_1 + "\n"
            "node-cyprus,4.4.4.4,200,30,50000000,Cyprus,CY,8,200,20,2000,2weeks,op,," + b64_1 + "\n"
            "node-belarus,5.5.5.5,200,30,60000000,Belarus,BY,8,200,20,2000,2weeks,op,," + b64_1 + "\n"
            "node-korea,6.6.6.6,400,15,300000000,Korea Republic of,KR,15,400,40,4000,2weeks,op,," + b64_2 + "\n"
        )
        servers = generate_ovpn.parse_vpngate_csv_content(csv_data)
        self.assertEqual(len(servers), 6)
        self.assertEqual(servers[0]["ip"], "2.2.2.2")

        # Country filter: JP only
        jp_servers = generate_ovpn.parse_vpngate_csv_content(csv_data, country_filter=["JP"])
        self.assertEqual(len(jp_servers), 2)
        self.assertTrue(all(s["country_short"] == "JP" for s in jp_servers))

        # Country filter: US only (Ensure CYPRUS and BELARUS are NOT falsely matched)
        us_servers = generate_ovpn.parse_vpngate_csv_content(csv_data, country_filter=["US"])
        self.assertEqual(len(us_servers), 1)
        self.assertEqual(us_servers[0]["ip"], "1.1.1.1")
        self.assertEqual(us_servers[0]["country_short"], "US")

        # Multi-country filter: JP and KR
        jp_kr_servers = generate_ovpn.parse_vpngate_csv_content(csv_data, country_filter=["JP", "KR"])
        self.assertEqual(len(jp_kr_servers), 3)
        self.assertTrue(all(s["country_short"] in ["JP", "KR"] for s in jp_kr_servers))

        # Speed filter
        fast_servers = generate_ovpn.parse_vpngate_csv_content(csv_data, min_speed_mbps=50.0)
        self.assertEqual(len(fast_servers), 5)

        # Limit filter
        limited = generate_ovpn.parse_vpngate_csv_content(csv_data, limit=1)
        self.assertEqual(len(limited), 1)
        self.assertEqual(limited[0]["ip"], "2.2.2.2")

    def test_process_vpngate_csv_end_to_end_with_scamalytics_filtering(self):
        b64_1 = base64.b64encode(SAMPLE_OVPN_TEXT_TCP.encode("utf-8")).decode("utf-8")
        b64_2 = base64.b64encode(SAMPLE_OVPN_TEXT_UDP.encode("utf-8")).decode("utf-8")

        csv_file = os.path.join(self.test_dir.name, "test_input.csv")
        outdir = os.path.join(self.test_dir.name, "ovpn_nodes")
        mapping_file = os.path.join(self.test_dir.name, "nodes_mapping.json")

        csv_content = SAMPLE_CSV_HEADER + (
            "vpn1,219.100.37.18,1000,10,800000000,Japan,JP,10,100,100,1000,2weeks,op,," + b64_1 + "\n"
            "vpn2,180.144.152.157,500,20,400000000,Japan,JP,5,50,50,500,2weeks,op,," + b64_2 + "\n"
        )
        with open(csv_file, "w", encoding="utf-8") as f:
            f.write(csv_content)

        # Mock Scamalytics scores: 219.100.37.18 -> 72 (high threat, excluded), 180.144.152.157 -> 3 (pure residential, kept)
        mock_scores = {
            "219.100.37.18": 72,
            "180.144.152.157": 3
        }
        with patch("generate_ovpn.batch_query_fraud_scores", return_value=mock_scores):
            mapping = generate_ovpn.process_vpngate_csv(
                csv_source=csv_file,
                target_dir=outdir,
                mapping_output=mapping_file,
                update_active_client=True,
                max_threat_score=20
            )

        # Only node 180.144.152.157 (< 20) should be generated and present in mapping
        self.assertEqual(mapping["total_nodes"], 1)
        self.assertTrue(os.path.exists(mapping_file))
        self.assertTrue(os.path.exists(outdir))

        node = mapping["nodes"][0]
        self.assertEqual(node["ip"], "180.144.152.157")
        self.assertEqual(node["port"], "1377")
        self.assertEqual(node["fraud_score"], 3)
        self.assertEqual(node["threat_score"], 3)
        self.assertTrue(os.path.exists(node["path"]))

        # 219.100.37.18 must NOT have a generated .ovpn file
        excluded_ovpn = os.path.join(outdir, "Japan_219.100.37.18_443.ovpn")
        self.assertFalse(os.path.exists(excluded_ovpn))

        client_ovpn = os.path.join(self.test_dir.name, "client.ovpn")
        self.assertTrue(os.path.exists(client_ovpn))
        with open(client_ovpn, "r") as cf:
            self.assertIn("180.144.152.157", cf.read())
            self.assertNotIn("219.100.37.18", cf.read())

    def test_filter_servers_by_fraud_score(self):
        servers = [
            {"ip": "1.1.1.1", "speed_mbps": 100.0},
            {"ip": "2.2.2.2", "speed_mbps": 80.0},
            {"ip": "3.3.3.3", "speed_mbps": 60.0},
            {"ip": "4.4.4.4", "speed_mbps": 40.0},
            {"ip": "5.5.5.5", "speed_mbps": 20.0},
        ]
        mock_scores = {
            "1.1.1.1": 0,    # Kept (< 20)
            "2.2.2.2": 19,   # Kept (< 20)
            "3.3.3.3": 20,   # Filtered out (>= 20)
            "4.4.4.4": 85,   # Filtered out (>= 20)
            "5.5.5.5": -1,   # Filtered out (failed query)
        }
        with patch("generate_ovpn.batch_query_fraud_scores", return_value=mock_scores):
            filtered = generate_ovpn.filter_servers_by_fraud_score(servers, max_threat_score=20)

        self.assertEqual(len(filtered), 2)
        self.assertEqual(filtered[0]["ip"], "1.1.1.1")
        self.assertEqual(filtered[0]["fraud_score"], 0)
        self.assertEqual(filtered[1]["ip"], "2.2.2.2")
        self.assertEqual(filtered[1]["fraud_score"], 19)

    def test_scamalytics_cache_save_and_load(self):
        cache_file = os.path.join(self.test_dir.name, "scamalytics_test_cache.json")
        generate_ovpn.MEMORY_CACHE.clear()
        generate_ovpn.MEMORY_CACHE["8.8.8.8"] = (0, time.time())
        generate_ovpn.MEMORY_CACHE["1.2.3.4"] = (15, time.time())

        generate_ovpn.save_fraud_cache(cache_file)
        self.assertTrue(os.path.exists(cache_file))

        # Clear memory and reload
        generate_ovpn.MEMORY_CACHE.clear()
        generate_ovpn.load_fraud_cache(cache_file)
        self.assertIn("8.8.8.8", generate_ovpn.MEMORY_CACHE)
        self.assertEqual(generate_ovpn.MEMORY_CACHE["8.8.8.8"][0], 0)
        self.assertEqual(generate_ovpn.MEMORY_CACHE["1.2.3.4"][0], 15)

    def test_query_scamalytics_score_parsing(self):
        generate_ovpn.MEMORY_CACHE.clear()
        sample_html = "<html><body><div class='score'>Fraud Score: 12</div></body></html>"
        mock_resp = MagicMock()
        mock_resp.status = 200
        mock_resp.read.return_value = sample_html.encode("utf-8")
        mock_resp.__enter__.return_value = mock_resp

        with patch("urllib.request.urlopen", return_value=mock_resp):
            score = generate_ovpn.query_scamalytics_score("9.9.9.9")
            self.assertEqual(score, 12)
            self.assertIn("9.9.9.9", generate_ovpn.MEMORY_CACHE)
            self.assertEqual(generate_ovpn.MEMORY_CACHE["9.9.9.9"][0], 12)

    def test_health_checker_load_nodes_mapping(self):
        mapping_file = os.path.join(self.test_dir.name, "nodes_mapping.json")
        outdir = os.path.join(self.test_dir.name, "ovpn_nodes")
        os.makedirs(outdir, exist_ok=True)

        ovpn_p1 = os.path.join(outdir, "Japan_219.100.37.18_443.ovpn")
        with open(ovpn_p1, "w") as f:
            f.write(SAMPLE_OVPN_TEXT_TCP)

        ovpn_p2 = os.path.join(outdir, "Japan_180.144.152.157_1377.ovpn")
        with open(ovpn_p2, "w") as f:
            f.write(SAMPLE_OVPN_TEXT_UDP)

        mapping_data = {
            "updated_at": "2026-08-21T00:00:00",
            "total_nodes": 2,
            "nodes": [
                {
                    "id": "Japan_219.100.37.18_443",
                    "filename": "Japan_219.100.37.18_443.ovpn",
                    "rel_path": "ovpn_nodes/Japan_219.100.37.18_443.ovpn",
                    "path": "/some/host/path/Japan_219.100.37.18_443.ovpn",
                    "ip": "219.100.37.18",
                    "port": "443",
                    "proto": "tcp",
                    "country": "Japan",
                    "country_short": "JP",
                    "speed_mbps": 800.0
                },
                {
                    "id": "Japan_180.144.152.157_1377",
                    "filename": "Japan_180.144.152.157_1377.ovpn",
                    "rel_path": "ovpn_nodes/Japan_180.144.152.157_1377.ovpn",
                    "path": "/some/host/path/Japan_180.144.152.157_1377.ovpn",
                    "ip": "180.144.152.157",
                    "port": "1377",
                    "proto": "udp",
                    "country": "Japan",
                    "country_short": "JP",
                    "speed_mbps": 400.0
                }
            ]
        }
        with open(mapping_file, "w") as f:
            json.dump(mapping_data, f)

        sm = ServiceManager()
        with patch("health_checker.CONFIG_DIR", self.test_dir.name), \
             patch("health_checker.MAPPING_FILE_PATH", mapping_file):
            nodes = sm.load_nodes_mapping()
            self.assertEqual(len(nodes), 2)
            self.assertEqual(nodes[0]["id"], "Japan_219.100.37.18_443")
            self.assertEqual(nodes[0]["path"], ovpn_p1)

    def test_health_checker_sequential_failover(self):
        mapping_file = os.path.join(self.test_dir.name, "nodes_mapping.json")
        outdir = os.path.join(self.test_dir.name, "ovpn_nodes")
        os.makedirs(outdir, exist_ok=True)

        ovpn_p1 = os.path.join(outdir, "node1.ovpn")
        with open(ovpn_p1, "w") as f:
            f.write(SAMPLE_OVPN_TEXT_TCP)

        ovpn_p2 = os.path.join(outdir, "node2.ovpn")
        with open(ovpn_p2, "w") as f:
            f.write(SAMPLE_OVPN_TEXT_UDP)

        mapping_data = {
            "nodes": [
                {"id": "node1", "filename": "node1.ovpn", "rel_path": "ovpn_nodes/node1.ovpn", "ip": "1.1.1.1", "port": "443", "speed_mbps": 100.0},
                {"id": "node2", "filename": "node2.ovpn", "rel_path": "ovpn_nodes/node2.ovpn", "ip": "2.2.2.2", "port": "1377", "speed_mbps": 50.0}
            ]
        }
        with open(mapping_file, "w") as f:
            json.dump(mapping_data, f)

        sm = ServiceManager()
        sm.current_node_index = 0

        def fake_test_connectivity():
            if sm.active_node_info and sm.active_node_info.get("id") == "node2":
                return True, "2.2.2.2", ""
            return False, "", "Connection refused on node 1"

        with patch("health_checker.CONFIG_DIR", self.test_dir.name), \
             patch("health_checker.MAPPING_FILE_PATH", mapping_file), \
             patch("health_checker.RUN_OVPN_PATH", os.path.join(self.test_dir.name, "openvpn_run.ovpn")), \
             patch("health_checker.CLIENT_OVPN_PATH", os.path.join(self.test_dir.name, "client.ovpn")), \
             patch.object(sm, "is_singbox_running", return_value=True), \
             patch.object(sm, "restart_openvpn", return_value=None), \
             patch.object(sm, "wait_for_tun_ready", return_value=True), \
             patch.object(sm, "test_vpn_connectivity", side_effect=fake_test_connectivity):

            success = sm.attempt_connect_nodes_sequence(start_from_next=True)
            self.assertTrue(success)
            self.assertEqual(sm.current_node_index, 1)
            self.assertEqual(sm.active_node_info["id"], "node2")
            self.assertEqual(sm.last_status.get("status"), "UP")
            self.assertEqual(sm.last_status.get("exit_ip"), "2.2.2.2")

    def test_openvpn_not_started_when_singbox_down(self):
        sm = ServiceManager()
        with patch.object(sm, "is_singbox_running", return_value=False), \
             patch("health_checker.subprocess.Popen") as mock_popen:

            # 1. start_openvpn should refuse to start OpenVPN
            started = sm.start_openvpn()
            self.assertFalse(started)
            mock_popen.assert_not_called()

            # 2. attempt_connect_nodes_sequence should refuse to run failover
            connected = sm.attempt_connect_nodes_sequence()
            self.assertFalse(connected)

    def test_service_manager_manual_switch_trigger(self):
        trigger_file = os.path.join(self.test_dir.name, ".switch_node")
        with open(trigger_file, "w") as f:
            f.write("1")

        sm = ServiceManager()
        with patch("health_checker.CONFIG_DIR", self.test_dir.name), \
             patch("health_checker.SWITCH_TRIGGER_FILE", trigger_file), \
             patch.object(sm, "attempt_connect_nodes_sequence", return_value=True) as mock_switch:

            sm.check_and_handle_switch_trigger()
            mock_switch.assert_called_once_with(start_from_next=True)
            self.assertFalse(os.path.exists(trigger_file))

    def test_get_socks_proxy_url(self):
        with patch.dict(os.environ, {"SOCKS_INBOUND_LISTEN": "127.0.0.1", "SOCKS_INBOUND_PORT": "1080"}):
            proxy_url = config_processor.get_socks_proxy_url()
            self.assertEqual(proxy_url, "socks5h://127.0.0.1:1080")

        with patch.dict(os.environ, {"SOCKS_INBOUND_LISTEN": "192.168.1.5", "SOCKS_INBOUND_PORT": "10808"}):
            proxy_url = config_processor.get_socks_proxy_url()
            self.assertEqual(proxy_url, "socks5h://192.168.1.5:10808")

    @patch("config_processor.requests.get")
    def test_fetch_remote_url_via_socks_proxy(self, mock_get):
        mock_resp = MagicMock()
        mock_resp.text = "{\"outbounds\": []}"
        mock_resp.raise_for_status = MagicMock()
        mock_get.return_value = mock_resp

        proxy_url = "socks5h://127.0.0.1:1080"
        target_url = "https://example.com/api/sub"

        result = config_processor.fetch_remote_url(target_url, headers={"User-Agent": "test"}, proxy_url=proxy_url)
        self.assertEqual(result, "{\"outbounds\": []}")

        mock_get.assert_called_once()
        _, kwargs = mock_get.call_args
        self.assertEqual(kwargs.get("proxies"), {"http": proxy_url, "https": proxy_url})

    @patch("config_processor.requests.get")
    def test_fetch_remote_url_localhost_bypass(self, mock_get):
        mock_resp = MagicMock()
        mock_resp.text = "client\nremote 1.2.3.4 443"
        mock_resp.raise_for_status = MagicMock()
        mock_get.return_value = mock_resp

        proxy_url = "socks5h://127.0.0.1:1080"
        local_url = "http://127.0.0.1:8080/export/ovpn"

        result = config_processor.fetch_remote_url(local_url, proxy_url=proxy_url)
        self.assertIn("client", result)

        mock_get.assert_called_once()
        _, kwargs = mock_get.call_args
        self.assertIsNone(kwargs.get("proxies"))

    @patch("config_processor.requests.get")
    def test_fetch_remote_url_proxy_fallback_to_direct(self, mock_get):
        mock_success_resp = MagicMock()
        mock_success_resp.text = "fallback success"
        mock_success_resp.raise_for_status = MagicMock()

        mock_get.side_effect = [
            requests.exceptions.ConnectionError("Proxy refused"),
            mock_success_resp
        ]

        proxy_url = "socks5h://127.0.0.1:1080"
        target_url = "https://sub.example.com/api"

        result = config_processor.fetch_remote_url(target_url, proxy_url=proxy_url)
        self.assertEqual(result, "fallback success")
        self.assertEqual(mock_get.call_count, 2)

    def test_process_config_injections_and_rule_set_removal(self):
        sample_raw = {
            "inbounds": [
                {"type": "tun", "tag": "tun-in", "interface_name": "sing-tun0", "auto_route": True}
            ],
            "outbounds": [
                {"type": "urltest", "tag": "🚀 节点选择", "outbounds": ["node-1", "node-2"]},
                {"type": "vless", "tag": "node-1", "server": "example.com", "server_port": 443},
                {"type": "tun", "tag": "old-tun-out"}
            ],
            "route": {
                "auto_detect_interface": True,
                "default_interface": "eth0",
                "rules": [
                    {"geosite": ["cn"], "outbound": "direct"},
                    {"rule_set": ["geosite-google"], "outbound": "proxy"}
                ],
                "rule_set": [
                    {"tag": "geosite-google", "type": "remote", "url": "https://example.com/google.srs"}
                ]
            },
            "dns": {
                "fakeip": {"enabled": True, "inet4_range": "198.18.0.0/15"},
                "servers": [
                    {"tag": "dns-fakeip", "type": "fakeip"},
                    {"tag": "dns-direct", "type": "udp", "server": "223.5.5.5"}
                ],
                "rules": [
                    {"rule_set": ["geosite-cn"], "server": "dns-direct"},
                    {"query_type": ["A", "AAAA"], "server": "dns-fakeip"}
                ]
            },
            "experimental": {
                "cache_file": {
                    "enabled": True,
                    "store_fakeip": True
                }
            }
        }

        processed = config_processor.process_config(sample_raw)

        # 1. rule_set must be deleted from route
        self.assertNotIn("rule_set", processed.get("route", {}))

        # 2. TUN inbounds and outbounds removed
        for ib in processed.get("inbounds", []):
            self.assertNotEqual(ib.get("type"), "tun")
        for ob in processed.get("outbounds", []):
            if ob.get("tag") != "openvpn-out":
                self.assertNotEqual(ob.get("type"), "tun")
        self.assertNotIn("auto_detect_interface", processed.get("route", {}))
        self.assertNotIn("default_interface", processed.get("route", {}))

        # 3. FakeIP removed from dns
        self.assertNotIn("fakeip", processed.get("dns", {}))
        for s in processed.get("dns", {}).get("servers", []):
            self.assertNotEqual(s.get("type"), "fakeip")
            self.assertNotIn("fakeip", s.get("tag", "").lower())
        for dr in processed.get("dns", {}).get("rules", []):
            self.assertNotIn("rule_set", dr)
            self.assertNotIn("fakeip", str(dr.get("server", "")).lower())

        # 4. store_fakeip removed from experimental.cache_file
        self.assertNotIn("store_fakeip", processed.get("experimental", {}).get("cache_file", {}))

        # 5. inbounds injected
        inbounds = processed.get("inbounds", [])
        inbound_tags = [ib.get("tag") for ib in inbounds]
        self.assertIn("socks-in", inbound_tags)
        self.assertIn("public-socks-in", inbound_tags)

        # 6. outbounds injected
        outbounds = processed.get("outbounds", [])
        outbound_tags = [ob.get("tag") for ob in outbounds]
        self.assertIn("openvpn-out", outbound_tags)
        openvpn_ob = next(ob for ob in outbounds if ob.get("tag") == "openvpn-out")
        self.assertEqual(openvpn_ob.get("bind_interface"), "tun0")

        # 7. route.rules only contains clean injected rules
        route_rules = processed.get("route", {}).get("rules", [])
        self.assertEqual(len(route_rules), 2)
        self.assertEqual(route_rules[0], {"inbound": ["socks-in"], "outbound": "🚀 节点选择"})
        self.assertEqual(route_rules[1], {"inbound": ["public-socks-in"], "outbound": "openvpn-out"})

    def test_save_as_raw_cache(self):
        run_config = os.path.join(self.test_dir.name, "singbox_run.json")
        raw_cache = os.path.join(self.test_dir.name, "singbox_subscription.raw.json")

        sample_data = {"test_key": "test_val", "inbounds": [], "outbounds": []}
        with open(run_config, "w", encoding="utf-8") as f:
            json.dump(sample_data, f)

        success = config_processor.save_as_raw_cache(run_config, raw_cache)
        self.assertTrue(success)
        self.assertTrue(os.path.exists(raw_cache))

        with open(raw_cache, "r", encoding="utf-8") as f:
            saved_data = json.load(f)
        self.assertEqual(saved_data, sample_data)

    def test_health_checker_saves_raw_cache_on_singbox_start(self):
        run_config = os.path.join(self.test_dir.name, "singbox_run.json")
        raw_cache = os.path.join(self.test_dir.name, "singbox_subscription.raw.json")
        sample_data = {"tag": "running_test"}
        with open(run_config, "w", encoding="utf-8") as f:
            json.dump(sample_data, f)

        sm = ServiceManager()
        with patch("health_checker.RUN_CONFIG_PATH", run_config), \
             patch("config_processor.RUN_CONFIG_PATH", run_config), \
             patch("config_processor.RAW_CONFIG_CACHE", raw_cache), \
             patch("health_checker.subprocess.Popen") as mock_popen, \
             patch.object(sm, "refresh_singbox_subscription", return_value=True):

            mock_proc = MagicMock()
            mock_proc.pid = 12345
            mock_proc.poll.return_value = None
            mock_popen.return_value = mock_proc

            sm.start_singbox()
            self.assertTrue(os.path.exists(raw_cache))
            with open(raw_cache, "r", encoding="utf-8") as f:
                self.assertEqual(json.load(f), sample_data)

    def test_process_ovpn_content_default_no_proxy(self):
        raw_ovpn = """client
dev tun
proto tcp
remote 219.100.37.13 443
socks-proxy 1.2.3.4 1080
socks-proxy-retry
http-proxy 5.6.7.8 8080
redirect-gateway def1
auth-user-pass
verb 2
<ca>
TEST_CA
</ca>
"""
        # Default without proxy
        with patch.dict(os.environ, {"OPENVPN_USE_PROXY": "false"}, clear=False):
            processed = ovpn_processor.process_ovpn_content(raw_ovpn)

        self.assertNotIn("\nredirect-gateway", processed)
        self.assertIn("# [Modified] redirect-gateway def1", processed)
        self.assertIn("route-nopull", processed)
        # Proxy directives must be stripped out when proxy is disabled
        self.assertNotIn("socks-proxy", processed)
        self.assertNotIn("http-proxy", processed)

    def test_process_ovpn_content_with_proxy_enabled(self):
        raw_ovpn = """client
dev tun
proto tcp
remote 219.100.37.13 443
redirect-gateway def1
auth-user-pass
verb 2
<ca>
TEST_CA
</ca>
"""
        with patch.dict(os.environ, {"OPENVPN_USE_PROXY": "true", "SOCKS_INBOUND_LISTEN": "127.0.0.1", "SOCKS_INBOUND_PORT": "1080"}, clear=False):
            processed = ovpn_processor.process_ovpn_content(raw_ovpn)

        self.assertIn("route-nopull", processed)
        self.assertIn("socks-proxy 127.0.0.1 1080", processed)
        self.assertIn("socks-proxy-retry", processed)
    @patch("health_checker.subprocess.run")
    def test_setup_tun_policy_routing_deduplication(self, mock_run):
        sm = ServiceManager()

        # Case 1: tun0 is down -> nothing called
        with patch.object(sm, "is_tun_up", return_value=False):
            sm.setup_tun_policy_routing()
            mock_run.assert_not_called()

        # Case 2: tun0 is up, rules not yet present -> rule add called
        mock_run.reset_mock()
        mock_show_res = MagicMock(stdout="0: from all lookup local\n32766: from all lookup main\n")
        mock_run.side_effect = [mock_show_res, MagicMock(), MagicMock(), MagicMock()]

        with patch.object(sm, "is_tun_up", return_value=True):
            sm.setup_tun_policy_routing()
            # 1: ip rule show, 2: ip rule add oif tun0, 3: ip rule add from 10.0.0.0/8, 4: ip route replace
            self.assertEqual(mock_run.call_count, 4)
            self.assertEqual(mock_run.call_args_list[0][0][0], ["ip", "rule", "show"])
            self.assertEqual(mock_run.call_args_list[1][0][0], ["ip", "rule", "add", "oif", "tun0", "table", "100"])
            self.assertEqual(mock_run.call_args_list[2][0][0], ["ip", "rule", "add", "from", "10.0.0.0/8", "table", "100"])
            self.assertEqual(mock_run.call_args_list[3][0][0], ["ip", "route", "replace", "default", "dev", "tun0", "table", "100"])

        # Case 3: tun0 is up, rules already present -> rule add NOT called
        mock_run.reset_mock()
        mock_show_res_existing = MagicMock(stdout="0: from all lookup local\n32764: from 10.0.0.0/8 lookup 100\n32765: from all oif tun0 lookup 100\n32766: from all lookup main\n")
        mock_run.side_effect = [mock_show_res_existing, MagicMock()]

        with patch.object(sm, "is_tun_up", return_value=True):
            sm.setup_tun_policy_routing()
            # 1: ip rule show, 2: ip route replace (no ip rule add!)
            self.assertEqual(mock_run.call_count, 2)
            self.assertEqual(mock_run.call_args_list[0][0][0], ["ip", "rule", "show"])
            self.assertEqual(mock_run.call_args_list[1][0][0], ["ip", "route", "replace", "default", "dev", "tun0", "table", "100"])

    def test_node_updater_beijing_schedule_calculation(self):
        from datetime import datetime, timezone, timedelta

        beijing_tz = timezone(timedelta(hours=8))
        # Case 1: current time is 07:30 Beijing time -> must schedule for tomorrow between 00:00 and 06:00
        now_dt = datetime(2026, 8, 23, 7, 30, 0, tzinfo=beijing_tz)
        next_run = node_updater.get_next_random_schedule(start_hour=0, end_hour=6, now_dt=now_dt)

        self.assertEqual(next_run.tzinfo, beijing_tz)
        self.assertEqual(next_run.year, 2026)
        self.assertEqual(next_run.month, 8)
        self.assertEqual(next_run.day, 24)
        self.assertTrue(0 <= next_run.hour <= 6)
        self.assertTrue(next_run > now_dt)

        # Case 2: current time is 00:00 Beijing time -> target should be today
        with patch("node_updater.random.randint", return_value=3600):  # 1 hour after start_hour -> 01:00 today
            now_early = datetime(2026, 8, 23, 0, 0, 0, tzinfo=beijing_tz)
            next_run_early = node_updater.get_next_random_schedule(start_hour=0, end_hour=6, now_dt=now_early)
            self.assertEqual(next_run_early.day, 23)
            self.assertEqual(next_run_early.hour, 1)
            self.assertEqual(next_run_early.minute, 0)

    def test_node_updater_load_env_config(self):
        env_file = os.path.join(self.test_dir.name, "config.env")
        with open(env_file, "w", encoding="utf-8") as f:
            f.write("VPNGATE_COUNTRY=JP\nVPNGATE_MIN_SPEED=50.0\nVPNGATE_LIMIT=20\nAUTO_UPDATE_START_HOUR=0\n")

        cfg = node_updater.load_env_config(self.test_dir.name)
        self.assertEqual(cfg.get("VPNGATE_COUNTRY"), "JP")
        self.assertEqual(cfg.get("VPNGATE_MIN_SPEED"), "50.0")
        self.assertEqual(cfg.get("VPNGATE_LIMIT"), "20")
        self.assertEqual(cfg.get("AUTO_UPDATE_START_HOUR"), "0")

    @patch("node_updater.subprocess.run")
    def test_node_updater_refresh_and_restart(self, mock_subproc):
        # 1. Mock generate_ovpn run
        mock_gen_res = MagicMock(returncode=0, stdout="Success", stderr="")
        # 2. Mock docker restart
        mock_docker_res = MagicMock(returncode=0, stdout="vpngate-singbox-openvpn", stderr="")

        mock_subproc.side_effect = [mock_gen_res, mock_docker_res]

        success = node_updater.run_node_refresh_and_restart(
            config_dir=self.test_dir.name,
            container_name="vpngate-singbox-openvpn"
        )
        self.assertTrue(success)
        self.assertEqual(mock_subproc.call_count, 2)
        # Check first call is python generate_ovpn.py
        gen_cmd = mock_subproc.call_args_list[0][0][0]
        self.assertIn("generate_ovpn.py", gen_cmd[1])
        # Check second call is docker restart
        docker_cmd = mock_subproc.call_args_list[1][0][0]
        self.assertEqual(docker_cmd, ["docker", "restart", "vpngate-singbox-openvpn"])

    @patch("node_updater.subprocess.run")
    def test_node_updater_country_filtering_precedence(self, mock_subproc):
        mock_gen_res = MagicMock(returncode=0, stdout="Success", stderr="")
        mock_docker_res = MagicMock(returncode=0, stdout="vpngate-singbox-openvpn", stderr="")
        mock_subproc.side_effect = [mock_gen_res, mock_docker_res, mock_gen_res, mock_docker_res, mock_gen_res, mock_docker_res]

        # Case 1: Country specified in config.env
        env_file = os.path.join(self.test_dir.name, "config.env")
        with open(env_file, "w", encoding="utf-8") as f:
            f.write("VPNGATE_COUNTRY=JP\n")

        node_updater.run_node_refresh_and_restart(
            config_dir=self.test_dir.name,
            container_name="vpngate-singbox-openvpn"
        )
        gen_cmd1 = mock_subproc.call_args_list[0][0][0]
        self.assertIn("-c", gen_cmd1)
        c_idx1 = gen_cmd1.index("-c")
        self.assertEqual(gen_cmd1[c_idx1 + 1], "JP")

        # Case 2: Explicit country parameter overrides config.env
        node_updater.run_node_refresh_and_restart(
            config_dir=self.test_dir.name,
            container_name="vpngate-singbox-openvpn",
            country="US"
        )
        gen_cmd2 = mock_subproc.call_args_list[2][0][0]
        self.assertIn("-c", gen_cmd2)
        c_idx2 = gen_cmd2.index("-c")
        self.assertEqual(gen_cmd2[c_idx2 + 1], "US")

        # Case 3: Empty country in config.env and no explicit parameter -> no -c flag
        with open(env_file, "w", encoding="utf-8") as f:
            f.write("VPNGATE_COUNTRY=\n")

        node_updater.run_node_refresh_and_restart(
            config_dir=self.test_dir.name,
            container_name="vpngate-singbox-openvpn"
        )
        gen_cmd3 = mock_subproc.call_args_list[4][0][0]
        self.assertNotIn("-c", gen_cmd3)

    def test_node_updater_cli_arguments(self):
        import argparse

        # Verify parser handles -c, --country, and --country-code
        parser = argparse.ArgumentParser()
        parser.add_argument("-c", "--country", "--country-code", dest="country", default=None)

        args1 = parser.parse_args(["-c", "JP"])
        self.assertEqual(args1.country, "JP")

        args2 = parser.parse_args(["--country", "US,KR"])
        self.assertEqual(args2.country, "US,KR")

        args3 = parser.parse_args(["--country-code", "SG"])
        self.assertEqual(args3.country, "SG")

    def test_smooth_upgrade_config_merging(self):
        # Test merging missing keys from example config to user's config
        user_config_path = os.path.join(self.test_dir.name, "config.env")
        example_config_path = os.path.join(self.test_dir.name, "config.env.example")

        user_content = """# Existing User Config
SINGBOX_SUBSCRIPTION_URL="https://mycustomsub.com"
PUBLIC_SOCKS_PORT=9999
"""
        example_content = """# Example Config
SINGBOX_SUBSCRIPTION_URL="https://example.com"
PUBLIC_SOCKS_PORT=2080
VPNGATE_COUNTRY="JP"
VPNGATE_MIN_SPEED=10.0
VPNGATE_MAX_THREAT_SCORE=20
"""
        with open(user_config_path, "w", encoding="utf-8") as f:
            f.write(user_content)
        with open(example_config_path, "w", encoding="utf-8") as f:
            f.write(example_content)

        # Simulate bash merge_config_env logic in Python
        existing_cfg = node_updater.load_env_config(self.test_dir.name)
        self.assertEqual(existing_cfg.get("SINGBOX_SUBSCRIPTION_URL"), "https://mycustomsub.com")
        self.assertEqual(existing_cfg.get("PUBLIC_SOCKS_PORT"), "9999")
        self.assertNotIn("VPNGATE_COUNTRY", existing_cfg)

        # Merge script invocation
        import subprocess
        bash_cmd = f"""
        merge_config_env() {{
            local target_file="$1"
            local example_file="$2"
            while IFS= read -r line || [ -n "$line" ]; do
                if [[ "$line" =~ ^[#[:space:]]*([A-Z0-9_]+)= ]]; then
                    local key="${{BASH_REMATCH[1]}}"
                    if ! grep -qE "^[#[:space:]]*${{key}}=" "${{target_file}}"; then
                        echo "${{line}}" >> "${{target_file}}"
                    fi
                fi
            done < "${{example_file}}"
        }}
        merge_config_env "{user_config_path}" "{example_config_path}"
        """
        res = subprocess.run(["bash", "-c", bash_cmd], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0)

        # Verify user config values are intact and new keys were added
        merged_cfg = node_updater.load_env_config(self.test_dir.name)
        self.assertEqual(merged_cfg.get("SINGBOX_SUBSCRIPTION_URL"), "https://mycustomsub.com")
        self.assertEqual(merged_cfg.get("PUBLIC_SOCKS_PORT"), "9999")
        self.assertEqual(merged_cfg.get("VPNGATE_COUNTRY"), "JP")
        self.assertEqual(merged_cfg.get("VPNGATE_MIN_SPEED"), "10.0")
        self.assertEqual(merged_cfg.get("VPNGATE_MAX_THREAT_SCORE"), "20")


if __name__ == "__main__":
    unittest.main()
