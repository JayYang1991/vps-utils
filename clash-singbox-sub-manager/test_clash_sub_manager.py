#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Comprehensive Unit & Integration Test Suite for Clash & Sing-box Subscription Manager.
Covers:
1. Pure Python QR Code Generator (SVG, ASCII, Matrix)
2. Configuration Manager (Defaults, UUID generation, IP detection, Save/Load)
3. Clash Parser & Sing-box Inbounds Extractor (All inbound types, YAML cleanup, Group filtering, Rule rewrites)
4. HTTP Server, Authentication, REST APIs, and Subscription Endpoint (/sub/<uuid>)
"""

import os
import sys
import json
import uuid
import time
import tempfile
import unittest
import threading
import urllib.request
import urllib.parse
import yaml

from qr_generator import QRGenerator, generate_qr_svg, generate_qr_ascii
from config import ConfigManager, get_default_config, detect_public_ip
from clash_parser import ClashParser
from server import ThreadedHTTPServer, make_handler


class TestQRGenerator(unittest.TestCase):
    """Test pure Python QR code generation."""

    def test_qr_generation_versions(self):
        qr = QRGenerator("http://127.0.0.1:8000/sub/test-uuid")
        matrix = qr.to_matrix()
        self.assertIsInstance(matrix, list)
        self.assertGreater(len(matrix), 20)
        self.assertEqual(len(matrix), len(matrix[0]))

    def test_qr_svg(self):
        svg = generate_qr_svg("http://127.0.0.1:8000/sub/test-uuid")
        self.assertTrue(svg.startswith("<svg"))
        self.assertTrue(svg.endswith("</svg>"))
        self.assertIn("viewBox", svg)
        self.assertIn("<path", svg)

    def test_qr_ascii(self):
        ascii_art = generate_qr_ascii("http://127.0.0.1:8000/sub/test-uuid")
        self.assertIsInstance(ascii_art, str)
        self.assertIn("█", ascii_art)


class TestConfigManager(unittest.TestCase):
    """Test Configuration Manager."""

    def setUp(self):
        self.temp_file = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        self.temp_file.close()

    def tearDown(self):
        if os.path.exists(self.temp_file.name):
            os.remove(self.temp_file.name)

    def test_defaults(self):
        cm = ConfigManager(self.temp_file.name)
        self.assertEqual(cm.get("server", "port"), 8000)
        self.assertEqual(cm.get("auth", "username"), "admin")
        self.assertEqual(cm.get("auth", "password"), "admin1234")
        self.assertEqual(cm.get("filter", "target_group_pattern"), "节点选择")
        self.assertIn("自动选择", cm.get("filter", "exclude_group_patterns"))
        self.assertTrue(bool(cm.get_uuid()))

    def test_regenerate_uuid(self):
        cm = ConfigManager(self.temp_file.name)
        old_uuid = cm.get_uuid()
        new_uuid = cm.regenerate_uuid()
        self.assertNotEqual(old_uuid, new_uuid)
        self.assertEqual(cm.get_uuid(), new_uuid)

        # Reload from disk
        cm2 = ConfigManager(self.temp_file.name)
        self.assertEqual(cm2.get_uuid(), new_uuid)

    def test_node_ip(self):
        cm = ConfigManager(self.temp_file.name)
        cm.set("singbox", "node_ip", "192.168.1.100")
        self.assertEqual(cm.get_node_ip(), "192.168.1.100")

        cm.set("singbox", "node_ip", "")
        detected_ip = cm.get_node_ip()
        self.assertIsInstance(detected_ip, str)
        self.assertGreater(len(detected_ip.split(".")), 1)


class TestClashParser(unittest.TestCase):
    """Test Sing-box inbounds extraction and Clash YAML transformation."""

    def test_extract_various_singbox_inbounds(self):
        mock_sb_config = {
            "inbounds": [
                {
                    "type": "mixed",
                    "tag": "my-mixed",
                    "listen": "0.0.0.0",
                    "listen_port": 4001,
                    "users": [{"username": "user1", "password": "pass1"}]
                },
                {
                    "type": "shadowsocks",
                    "tag": "my-ss",
                    "listen_port": 8388,
                    "method": "aes-256-gcm",
                    "password": "secretpassword"
                },
                {
                    "type": "trojan",
                    "tag": "my-trojan",
                    "listen_port": 443,
                    "users": [{"password": "trojanpass"}],
                    "tls": {"enabled": True, "server_name": "example.com"}
                },
                {
                    "type": "vless",
                    "tag": "my-vless",
                    "listen_port": 8443,
                    "users": [{"uuid": "e9365518-8d4e-4b25-9610-18fdf973b069", "flow": "xtls-rprx-vision"}],
                    "tls": {"enabled": True, "server_name": "vless.example.com"}
                },
                {
                    "type": "tun",
                    "tag": "tun-in",
                    "interface_name": "sing-tun0"
                }
            ]
        }

        with tempfile.NamedTemporaryFile(mode="w+", suffix=".json", delete=False) as tf:
            json.dump(mock_sb_config, tf)
            tf_path = tf.name

        try:
            nodes = ClashParser.extract_singbox_inbounds(tf_path, "1.2.3.4")
            self.assertEqual(len(nodes), 4)  # tun is skipped

            # Verify mixed
            mixed = next(n for n in nodes if n["name"] == "my-mixed")
            self.assertEqual(mixed["type"], "socks5")
            self.assertEqual(mixed["server"], "1.2.3.4")
            self.assertEqual(mixed["port"], 4001)
            self.assertEqual(mixed["username"], "user1")

            # Verify ss
            ss = next(n for n in nodes if n["name"] == "my-ss")
            self.assertEqual(ss["type"], "ss")
            self.assertEqual(ss["cipher"], "aes-256-gcm")

            # Verify trojan
            trojan = next(n for n in nodes if n["name"] == "my-trojan")
            self.assertEqual(trojan["type"], "trojan")
            self.assertEqual(trojan["sni"], "example.com")

            # Verify vless
            vless = next(n for n in nodes if n["name"] == "my-vless")
            self.assertEqual(vless["type"], "vless")
            self.assertEqual(vless["uuid"], "e9365518-8d4e-4b25-9610-18fdf973b069")
        finally:
            if os.path.exists(tf_path):
                os.remove(tf_path)

    def test_extract_vless_reality_inbounds(self):
        mock_sb_config = {
            "inbounds": [
                {
                    "type": "vless",
                    "tag": "vless-reality-in",
                    "listen_port": 12345,
                    "users": [{"uuid": "d4f89d1d-62da-4bb6-941e-2a1a4749a5b0", "flow": "xtls-rprx-vision"}],
                    "tls": {
                        "enabled": True,
                        "server_name": "dl.google.com",
                        "reality": {
                            "enabled": True,
                            "private_key": "qINUYR2leSEY7wAblZgN7AYrvK0bS9CIx735pZ7dXEk",
                            "short_id": ["d1a46e64"]
                        }
                    }
                }
            ]
        }

        with tempfile.NamedTemporaryFile(mode="w+", suffix=".json", delete=False) as tf:
            json.dump(mock_sb_config, tf)
            tf_path = tf.name

        try:
            nodes = ClashParser.extract_singbox_inbounds(tf_path, "8.137.160.254")
            self.assertEqual(len(nodes), 1)
            node = nodes[0]
            self.assertEqual(node["type"], "vless")
            self.assertEqual(node["server"], "8.137.160.254")
            self.assertEqual(node["port"], 12345)
            self.assertEqual(node["flow"], "xtls-rprx-vision")
            self.assertEqual(node["servername"], "dl.google.com")
            self.assertEqual(node["client-fingerprint"], "chrome")
            self.assertIn("reality-opts", node)
            # short-id MUST be a string, not a list!
            self.assertEqual(node["reality-opts"]["short-id"], "d1a46e64")
            self.assertIsInstance(node["reality-opts"]["short-id"], str)
            # public-key MUST be derived from private-key with x25519
            self.assertEqual(node["reality-opts"]["public-key"], "bg0uqwL4Lj0gwXPnHk8L9U4DU5M4jAko19WwYAbSYWI")
        finally:
            if os.path.exists(tf_path):
                os.remove(tf_path)

    def test_transform_config_groups_and_rules(self):
        mock_raw_yaml = """
port: 7890
socks-port: 7891
mode: rule
dns:
  enable: true
  nameserver:
    - 8.8.8.8
proxies:
  - { name: "HK-Old", type: ss, server: 9.9.9.9, port: 8888, cipher: aes-256-gcm, password: p }
  - { name: "US-Old", type: vmess, server: 8.8.8.8, port: 443, uuid: 12345 }
proxy-groups:
  - name: 节点选择
    type: select
    proxies:
      - 自动选择
      - 香港节点
      - 日本节点
      - 美国节点
      - HK-Old
      - US-Old
      - DIRECT
  - name: 自动选择
    type: url-test
    proxies: [HK-Old, US-Old]
  - name: 香港节点
    type: select
    proxies: [HK-Old]
  - name: 日本节点
    type: select
    proxies: [HK-Old]
  - name: 美国节点
    type: select
    proxies: [US-Old]
  - name: 媒体流媒体
    type: select
    proxies:
      - 节点选择
      - 香港节点
      - 自动选择
rules:
  - DOMAIN-SUFFIX,google.com,节点选择
  - DOMAIN-SUFFIX,netflix.com,香港节点
  - DOMAIN-SUFFIX,disney.com,美国节点
  - MATCH,自动选择
"""
        singbox_nodes = [
            {"name": "singbox-node", "type": "socks5", "server": "1.2.3.4", "port": 4001}
        ]

        yaml_out, summary = ClashParser.transform_config(
            raw_clash_yaml=mock_raw_yaml,
            singbox_nodes=singbox_nodes,
            target_group_pattern="节点选择",
            exclude_patterns=["自动选择", "节点"]
        )

        parsed = yaml.safe_load(yaml_out)

        # 1. Proxies check
        self.assertEqual(len(parsed["proxies"]), 1)
        self.assertEqual(parsed["proxies"][0]["name"], "singbox-node")
        self.assertEqual(parsed["proxies"][0]["server"], "1.2.3.4")

        # 2. Proxy groups check
        group_names = [g["name"] for g in parsed["proxy-groups"]]
        self.assertIn("节点选择", group_names)
        self.assertIn("媒体流媒体", group_names)
        self.assertNotIn("自动选择", group_names)
        self.assertNotIn("香港节点", group_names)
        self.assertNotIn("日本节点", group_names)
        self.assertNotIn("美国节点", group_names)

        # 3. 节点选择 group proxies check
        target_grp = next(g for g in parsed["proxy-groups"] if g["name"] == "节点选择")
        self.assertIn("singbox-node", target_grp["proxies"])
        self.assertNotIn("HK-Old", target_grp["proxies"])
        self.assertNotIn("自动选择", target_grp["proxies"])
        self.assertNotIn("香港节点", target_grp["proxies"])

        # 4. Rules check
        rules = parsed["rules"]
        self.assertIn("DOMAIN-SUFFIX,google.com,节点选择", rules)
        self.assertIn("DOMAIN-SUFFIX,netflix.com,节点选择", rules)
        self.assertIn("DOMAIN-SUFFIX,disney.com,节点选择", rules)
        self.assertIn("MATCH,节点选择", rules)

        # 5. Retained configs check
        self.assertEqual(parsed["port"], 7890)
        self.assertEqual(parsed["mode"], "rule")
        self.assertTrue(parsed["dns"]["enable"])

    def test_is_socks_node(self):
        self.assertTrue(ClashParser.is_socks_node({"type": "socks5"}))
        self.assertTrue(ClashParser.is_socks_node({"type": "socks"}))
        self.assertTrue(ClashParser.is_socks_node({"type": "socks4"}))
        self.assertTrue(ClashParser.is_socks_node({"type": "socks5h"}))
        self.assertTrue(ClashParser.is_socks_node({"type": "mixed"}))
        self.assertTrue(ClashParser.is_socks_node({"type": "SOCKS5"}))

        self.assertFalse(ClashParser.is_socks_node({"type": "vless"}))
        self.assertFalse(ClashParser.is_socks_node({"type": "ss"}))
        self.assertFalse(ClashParser.is_socks_node({"type": "shadowsocks"}))
        self.assertFalse(ClashParser.is_socks_node({"type": "trojan"}))
        self.assertFalse(ClashParser.is_socks_node({"type": "hysteria2"}))
        self.assertFalse(ClashParser.is_socks_node({"type": "vmess"}))
        self.assertFalse(ClashParser.is_socks_node({"type": "http"}))
        self.assertFalse(ClashParser.is_socks_node({}))
        self.assertFalse(ClashParser.is_socks_node(None))

    def test_sort_nodes_socks_last(self):
        nodes = [
            {"name": "socks-1", "type": "socks5"},
            {"name": "vless-1", "type": "vless"},
            {"name": "hy2-1", "type": "hysteria2"},
            {"name": "socks-2", "type": "socks"},
            {"name": "trojan-1", "type": "trojan"},
            {"name": "mixed-1", "type": "mixed"}
        ]
        sorted_nodes = ClashParser.sort_nodes_socks_last(nodes)
        names = [n["name"] for n in sorted_nodes]
        self.assertEqual(names, ["vless-1", "hy2-1", "trojan-1", "socks-1", "socks-2", "mixed-1"])

    def test_transform_config_socks_ordering_in_target_group(self):
        mock_raw_yaml = """
proxies: []
proxy-groups:
  - name: 节点选择
    type: select
    proxies:
      - 自动选择
      - 香港节点
      - DIRECT
  - name: 自动选择
    type: url-test
    proxies: []
  - name: 香港节点
    type: select
    proxies: []
  - name: 🚀 节点选择
    type: select
    proxies:
      - DIRECT
rules:
  - MATCH,节点选择
"""
        singbox_nodes = [
            {"name": "residential-socks", "type": "socks5", "server": "1.2.3.4", "port": 1080},
            {"name": "vless-reality", "type": "vless", "server": "1.2.3.4", "port": 443},
            {"name": "hy2-fast", "type": "hysteria2", "server": "1.2.3.4", "port": 8443},
            {"name": "aux-socks", "type": "socks", "server": "1.2.3.4", "port": 2080}
        ]

        yaml_out, summary = ClashParser.transform_config(
            raw_clash_yaml=mock_raw_yaml,
            singbox_nodes=singbox_nodes,
            target_group_pattern="节点选择",
            exclude_patterns=["自动选择", "节点"]
        )

        parsed = yaml.safe_load(yaml_out)

        # Check proxies order
        proxy_names = [p["name"] for p in parsed["proxies"]]
        self.assertEqual(proxy_names, ["vless-reality", "hy2-fast", "residential-socks", "aux-socks"])

        # Check target group "节点选择"
        target_grp = next(g for g in parsed["proxy-groups"] if g["name"] == "节点选择")
        self.assertEqual(
            target_grp["proxies"],
            ["vless-reality", "hy2-fast", "residential-socks", "aux-socks", "DIRECT"]
        )

        # Check target group "🚀 节点选择"
        rocket_grp = next(g for g in parsed["proxy-groups"] if g["name"] == "🚀 节点选择")
        self.assertEqual(
            rocket_grp["proxies"],
            ["vless-reality", "hy2-fast", "residential-socks", "aux-socks", "DIRECT"]
        )

    def test_extract_singbox_inbounds_sorted_order(self):
        mock_sb_config = {
            "inbounds": [
                {
                    "type": "socks",
                    "tag": "my-socks",
                    "listen_port": 1080
                },
                {
                    "type": "vless",
                    "tag": "my-vless",
                    "listen_port": 443
                },
                {
                    "type": "mixed",
                    "tag": "my-mixed",
                    "listen_port": 2080
                },
                {
                    "type": "hysteria2",
                    "tag": "my-hy2",
                    "listen_port": 8443
                }
            ]
        }

        with tempfile.NamedTemporaryFile(mode="w+", suffix=".json", delete=False) as tf:
            json.dump(mock_sb_config, tf)
            tf_path = tf.name

        try:
            nodes = ClashParser.extract_singbox_inbounds(tf_path, "1.2.3.4")
            names = [n["name"] for n in nodes]
            self.assertEqual(names, ["my-vless", "my-hy2", "my-socks", "my-mixed"])
        finally:
            if os.path.exists(tf_path):
                os.remove(tf_path)

    def test_fetch_subscription_proxy_success(self):
        from unittest.mock import patch, MagicMock
        with patch("subprocess.run") as mock_run:
            mock_res = MagicMock()
            mock_res.returncode = 0
            mock_res.stdout = b"port: 7890\nproxies: []\n"
            mock_res.stderr = b""
            mock_run.return_value = mock_res

            ok, content = ClashParser.fetch_subscription("https://example.com/sub", proxy="socks5h://127.0.0.1:2080", force_refresh=True)
            self.assertTrue(ok)
            self.assertIn("port: 7890", content)

    def test_fetch_subscription_proxy_fail_fallback_direct(self):
        from unittest.mock import patch, MagicMock
        with patch("subprocess.run") as mock_run:
            # 1st call (proxy): fail with exit code 7
            mock_proxy_res = MagicMock()
            mock_proxy_res.returncode = 7
            mock_proxy_res.stdout = b""
            mock_proxy_res.stderr = b"curl: (7) Failed to connect to 127.0.0.1 port 2080: Connection refused"

            # 2nd call (direct): success
            mock_direct_res = MagicMock()
            mock_direct_res.returncode = 0
            mock_direct_res.stdout = b"port: 7890\nmode: rule\n"
            mock_direct_res.stderr = b""

            mock_run.side_effect = [mock_proxy_res, mock_direct_res]

            ok, content = ClashParser.fetch_subscription("https://example.com/sub", proxy="socks5h://127.0.0.1:2080", force_refresh=True)
            self.assertTrue(ok)
            self.assertIn("mode: rule", content)

    def test_fetch_subscription_all_fail_detailed_error(self):
        from unittest.mock import patch, MagicMock
        with patch("subprocess.run") as mock_run, patch("urllib.request.urlopen") as mock_urlopen:
            mock_proxy_res = MagicMock()
            mock_proxy_res.returncode = 7
            mock_proxy_res.stdout = b""
            mock_proxy_res.stderr = b"Failed to connect to 127.0.0.1 port 2080"

            mock_direct_res = MagicMock()
            mock_direct_res.returncode = 28
            mock_direct_res.stdout = b""
            mock_direct_res.stderr = b"Operation timed out after 30000ms"

            mock_run.side_effect = [mock_proxy_res, mock_direct_res]
            mock_urlopen.side_effect = Exception("Connection refused by remote host")

            ok, error_msg = ClashParser.fetch_subscription("https://example.com/sub", proxy="socks5h://127.0.0.1:2080", force_refresh=True)
            self.assertFalse(ok)
            self.assertIn("代理失败原因", error_msg)
            self.assertIn("直连失败原因", error_msg)
            self.assertIn("无法连接到代理服务器", error_msg)


class TestServerAndAPI(unittest.TestCase):
    """Test HTTP Server, Authentication, REST APIs, and Subscription Endpoint."""

    @classmethod
    def setUpClass(cls):
        cls.temp_cfg = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        cls.temp_cfg.close()

        cls.cm = ConfigManager(cls.temp_cfg.name)
        cls.cm.set("server", "port", 18080)
        cls.cm.set("auth", "username", "admin")
        cls.cm.set("auth", "password", "admin1234")
        cls.cm.set("singbox", "node_ip", "127.0.0.1")

        cls.handler = make_handler(cls.cm)
        cls.server = ThreadedHTTPServer(("127.0.0.1", 18080), cls.handler)
        cls.server_thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.server_thread.start()
        time.sleep(0.3)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        if os.path.exists(cls.temp_cfg.name):
            os.remove(cls.temp_cfg.name)

    def test_unauthenticated_redirect(self):
        req = urllib.request.Request("http://127.0.0.1:18080/", headers={"User-Agent": "Test"})
        # Should redirect to /login
        try:
            with urllib.request.urlopen(req) as resp:
                self.assertEqual(resp.status, 200)
                self.assertIn("/login", resp.geturl())
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 302)

    def test_login_and_auth_session(self):
        # 1. POST /login with correct credentials
        data = urllib.parse.urlencode({"username": "admin", "password": "admin1234"}).encode("utf-8")
        req = urllib.request.Request("http://127.0.0.1:18080/login", data=data, method="POST")

        class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
            def http_error_302(self, req, fp, code, msg, headers):
                return fp

        opener = urllib.request.build_opener(NoRedirectHandler)
        resp = opener.open(req)
        set_cookie = resp.headers.get("Set-Cookie", "")
        self.assertIn("auth_session=", set_cookie)

        cookie_val = set_cookie.split(";")[0]

        # 2. Access dashboard / with cookie
        req_dash = urllib.request.Request("http://127.0.0.1:18080/", headers={"Cookie": cookie_val})
        with urllib.request.urlopen(req_dash) as dash_resp:
            self.assertEqual(dash_resp.status, 200)
            body = dash_resp.read().decode("utf-8")
            self.assertIn("Clash & Sing-box", body)

        # 3. Access API /api/status with cookie
        req_api = urllib.request.Request("http://127.0.0.1:18080/api/status", headers={"Cookie": cookie_val})
        with urllib.request.urlopen(req_api) as api_resp:
            self.assertEqual(api_resp.status, 200)
            data = json.loads(api_resp.read().decode("utf-8"))
            self.assertTrue(data["success"])
            self.assertEqual(data["uuid"], self.cm.get_uuid())

    def test_subscription_endpoint(self):
        current_uuid = self.cm.get_uuid()

        # 1. Valid UUID
        url = f"http://127.0.0.1:18080/sub/{current_uuid}"
        with urllib.request.urlopen(url) as resp:
            self.assertEqual(resp.status, 200)
            self.assertEqual(resp.headers.get("Content-Type"), "text/yaml; charset=utf-8")
            content = resp.read().decode("utf-8")
            parsed = yaml.safe_load(content)
            self.assertIsInstance(parsed, dict)
            self.assertIn("proxies", parsed)
            self.assertIn("proxy-groups", parsed)

        # 2. Invalid UUID -> 403
        invalid_url = f"http://127.0.0.1:18080/sub/wrong-uuid"
        try:
            urllib.request.urlopen(invalid_url)
            self.fail("Should raise 403")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 403)

    def test_regenerate_uuid_api(self):
        # Authenticate via Basic Auth
        import base64
        creds = base64.b64encode(b"admin:admin1234").decode()
        headers = {"Authorization": f"Basic {creds}"}

        old_uuid = self.cm.get_uuid()
        req = urllib.request.Request("http://127.0.0.1:18080/api/regenerate-uuid", data=b"{}", headers=headers, method="POST")
        with urllib.request.urlopen(req) as resp:
            self.assertEqual(resp.status, 200)
            data = json.loads(resp.read().decode("utf-8"))
            self.assertTrue(data["success"])
            self.assertNotEqual(data["uuid"], old_uuid)

        # Old UUID should now 403
        try:
            urllib.request.urlopen(f"http://127.0.0.1:18080/sub/{old_uuid}")
            self.fail("Old UUID should return 403")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 403)

        # New UUID should 200
        with urllib.request.urlopen(f"http://127.0.0.1:18080/sub/{data['uuid']}") as resp:
            self.assertEqual(resp.status, 200)


if __name__ == "__main__":
    unittest.main(verbosity=2)
