#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Multi-threaded HTTP Server for Clash & Sing-box Subscription Manager.
Provides:
1. Clash subscription endpoint (/sub/<uuid>)
2. Web Management Dashboard & Auth
3. RESTful Management APIs
4. Dynamic QR Code Generator
"""

import os
import sys
import time
import json
import hmac
import hashlib
import urllib.parse
from http.server import HTTPServer, SimpleHTTPRequestHandler
from socketserver import ThreadingMixIn
from typing import Dict, Any, Optional

from config import ConfigManager, detect_public_ip
from clash_parser import ClashParser, _UPSTREAM_SUB_CACHE
from qr_generator import generate_qr_svg
from web_ui import get_login_page_html, get_dashboard_html


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """Multi-threaded HTTP server."""
    daemon_threads = True
    allow_reuse_address = True


class AppRequestHandler(SimpleHTTPRequestHandler):
    """Main request handler for Web UI, APIs, and Subscription endpoints."""

    def __init__(self, *args, config_manager: Optional[ConfigManager] = None, **kwargs):
        self.cm = config_manager or ConfigManager()
        super().__init__(*args, **kwargs)

    # In-memory cache for subscription output
    _cache_time = 0
    _cached_yaml = ""
    _cached_summary = {}

    def log_message(self, format, *args):
        """Custom clean logging."""
        sys.stderr.write(f"[{self.log_date_time_string()}] {self.address_string()} - {format % args}\n")

    def _send_response_headers(self, status_code: int, content_type: str = "text/html; charset=utf-8", extra_headers: Optional[Dict[str, str]] = None):
        self.send_response(status_code)
        self.send_header("Content-Type", content_type)
        self.send_header("Server", "Clash-Singbox-Sub-Manager/1.0")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()

    def _send_json(self, data: Any, status_code: int = 200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self._send_response_headers(status_code, "application/json; charset=utf-8")
        self.wfile.write(body)

    def _get_cookie(self, name: str) -> Optional[str]:
        cookie_header = self.headers.get("Cookie", "")
        for item in cookie_header.split(";"):
            item = item.strip()
            if item.startswith(f"{name}="):
                return item[len(name) + 1:]
        return None

    def _is_authenticated(self) -> bool:
        """Check session cookie or HTTP Basic Auth."""
        secret = self.cm.get("auth", "session_secret", "secret-key")
        expected_user = self.cm.get("auth", "username", "admin")
        expected_pass = self.cm.get("auth", "password", "admin1234")

        cookie = self._get_cookie("auth_session")
        if cookie:
            try:
                parts = cookie.split(":")
                if len(parts) == 3:
                    u, ts, sig = parts
                    if time.time() - float(ts) < 86400 * 7 and u == expected_user:
                        expected_sig = hmac.new(secret.encode(), f"{u}:{ts}".encode(), hashlib.sha256).hexdigest()
                        if hmac.compare_digest(sig, expected_sig):
                            return True
            except Exception:
                pass

        auth_header = self.headers.get("Authorization", "")
        if auth_header.startswith("Basic "):
            try:
                import base64
                decoded = base64.b64decode(auth_header[6:]).decode("utf-8")
                u, p = decoded.split(":", 1)
                if u == expected_user and p == expected_pass:
                    return True
            except Exception:
                pass

        return False

    def _create_session_cookie(self, username: str) -> str:
        secret = self.cm.get("auth", "session_secret", "secret-key")
        ts = str(int(time.time()))
        sig = hmac.new(secret.encode(), f"{username}:{ts}".encode(), hashlib.sha256).hexdigest()
        return f"auth_session={username}:{ts}:{sig}; Path=/; HttpOnly; SameSite=Lax; Max-Age=604800"

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)

        # 1. Subscription Download: /sub/<uuid> or /clash.yaml?uuid=<uuid>
        expected_uuid = self.cm.get_uuid()
        if path.startswith("/sub/") or path in ("/clash.yaml", "/sub.yaml"):
            req_uuid = ""
            if path.startswith("/sub/"):
                req_uuid = path[len("/sub/"):].strip()
            elif "uuid" in query:
                req_uuid = query["uuid"][0]
            elif "token" in query:
                req_uuid = query["token"][0]

            if not req_uuid or req_uuid != expected_uuid:
                self._send_response_headers(403, "text/plain; charset=utf-8")
                self.wfile.write(b"403 Forbidden: Invalid Subscription UUID\n")
                return

            self._serve_clash_subscription()
            return

        # 2. QR Code Generator Endpoint
        if path == "/api/qrcode":
            text = query.get("text", [""])[0]
            if not text:
                text = self.cm.get_full_subscription_url(self.headers.get("Host"))
            svg_content = generate_qr_svg(text)
            self._send_response_headers(200, "image/svg+xml; charset=utf-8")
            self.wfile.write(svg_content.encode("utf-8"))
            return

        # 3. Login Page
        if path == "/login":
            if self._is_authenticated():
                self.send_response(302)
                self.send_header("Location", "/")
                self.end_headers()
                return
            html = get_login_page_html()
            self._send_response_headers(200, "text/html; charset=utf-8")
            self.wfile.write(html.encode("utf-8"))
            return

        # 4. Auth Verification for all remaining routes
        if not self._is_authenticated():
            self.send_response(302)
            self.send_header("Location", "/login")
            self.end_headers()
            return

        # 5. Management Web UI Dashboard (/)
        if path == "/":
            html = get_dashboard_html()
            self._send_response_headers(200, "text/html; charset=utf-8")
            self.wfile.write(html.encode("utf-8"))
            return

        # 6. Status API (/api/status)
        if path == "/api/status":
            safe_cfg = json.loads(json.dumps(self.cm.config))
            if "auth" in safe_cfg:
                safe_cfg["auth"]["password"] = "******"
                safe_cfg["auth"]["session_secret"] = "******"

            node_ip = self.cm.get_node_ip()
            sb_path = self.cm.get("singbox", "config_path", "/etc/sing-box/config.json")
            singbox_nodes = ClashParser.extract_singbox_inbounds(sb_path, node_ip)

            status_data = {
                "success": True,
                "server_port": self.cm.get("server", "port", 8000),
                "uuid": self.cm.get_uuid(),
                "node_ip": node_ip,
                "singbox_status": {
                    "config_path": sb_path,
                    "exists": os.path.exists(sb_path),
                    "nodes_count": len(singbox_nodes),
                    "nodes": singbox_nodes
                },
                "config": safe_cfg
            }
            self._send_json(status_data)
            return

        # 7. Detect Public IP API (/api/detect-ip)
        if path == "/api/detect-ip":
            ip = detect_public_ip(force_refresh=True)
            self._send_json({"ip": ip})
            return

        # 8. Test Sync Preview API (/api/test-sync)
        if path == "/api/test-sync":
            self._handle_test_sync()
            return

        # 404 Fallback
        self._send_response_headers(404, "text/plain; charset=utf-8")
        self.wfile.write(b"404 Not Found\n")

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        # 1. Login Authentication
        if path == "/login":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode("utf-8", errors="replace")
            post_data = urllib.parse.parse_qs(body)

            username = post_data.get("username", [""])[0].strip()
            password = post_data.get("password", [""])[0].strip()

            expected_user = self.cm.get("auth", "username", "admin")
            expected_pass = self.cm.get("auth", "password", "admin1234")

            if username == expected_user and password == expected_pass:
                cookie_str = self._create_session_cookie(username)
                self.send_response(302)
                self.send_header("Set-Cookie", cookie_str)
                self.send_header("Location", "/")
                self.end_headers()
            else:
                html = get_login_page_html("用户名或密码错误，请重试")
                self._send_response_headers(401, "text/html; charset=utf-8")
                self.wfile.write(html.encode("utf-8"))
            return

        # 2. Logout
        if path == "/logout":
            self.send_response(302)
            self.send_header("Set-Cookie", "auth_session=; Path=/; Max-Age=0")
            self.send_header("Location", "/login")
            self.end_headers()
            return

        # Protected POST endpoints require authentication
        if not self._is_authenticated():
            self._send_json({"error": "Unauthorized"}, 401)
            return

        content_length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(content_length).decode("utf-8", errors="replace")
        req_data = {}
        if raw_body:
            try:
                req_data = json.loads(raw_body)
            except Exception:
                req_data = urllib.parse.parse_qs(raw_body)

        # 3. Regenerate UUID API (/api/regenerate-uuid)
        if path == "/api/regenerate-uuid":
            new_uuid = self.cm.regenerate_uuid()
            AppRequestHandler._cache_time = 0
            self._send_json({"success": True, "uuid": new_uuid})
            return

        # 4. Save Config API (/api/config)
        if path == "/api/config":
            if "clash_sub_url" in req_data:
                self.cm.set("subscription", "clash_sub_url", req_data["clash_sub_url"], auto_save=False)
            if "upstream_proxy" in req_data:
                self.cm.set("subscription", "upstream_proxy", req_data["upstream_proxy"], auto_save=False)
            if "node_ip" in req_data:
                self.cm.set("singbox", "node_ip", req_data["node_ip"], auto_save=False)
            if "singbox_config_path" in req_data:
                self.cm.set("singbox", "config_path", req_data["singbox_config_path"], auto_save=False)
            if "target_group_pattern" in req_data:
                self.cm.set("filter", "target_group_pattern", req_data["target_group_pattern"], auto_save=False)
            if "exclude_group_patterns" in req_data:
                patterns = req_data["exclude_group_patterns"]
                if isinstance(patterns, list):
                    self.cm.set("filter", "exclude_group_patterns", patterns, auto_save=False)
            if "username" in req_data and req_data["username"]:
                self.cm.set("auth", "username", req_data["username"], auto_save=False)
            if "password" in req_data and req_data["password"]:
                self.cm.set("auth", "password", req_data["password"], auto_save=False)
            if "port" in req_data and req_data["port"]:
                self.cm.set("server", "port", int(req_data["port"]), auto_save=False)

            self.cm.save()
            AppRequestHandler._cache_time = 0
            _UPSTREAM_SUB_CACHE.clear()
            self._send_json({"success": True})
            return

        # 5. Test Fetch Upstream Subscription (/api/test-fetch)
        if path == "/api/test-fetch":
            url = req_data.get("url", "").strip()
            proxy = req_data.get("proxy", "").strip() or self.cm.get("subscription", "upstream_proxy", "socks5h://127.0.0.1:2080")
            if not url:
                self._send_json({"success": False, "error": "URL 不能为空"})
                return

            ok, fetched = ClashParser.fetch_subscription(url, proxy=proxy, timeout=45.0, force_refresh=True)
            if ok:
                size_bytes = len(fetched)
                if size_bytes >= 1024 * 1024:
                    size_str = f"{size_bytes / (1024 * 1024):.2f} MB"
                elif size_bytes >= 1024:
                    size_str = f"{size_bytes / 1024:.1f} KB"
                else:
                    size_str = f"{size_bytes} B"

                import yaml
                proxies_count = 0
                try:
                    data = yaml.safe_load(fetched)
                    if isinstance(data, dict):
                        proxies_count = len(data.get("proxies", []))
                except Exception:
                    proxies_count = fetched.count("- name:") or fetched.count("vless://") or fetched.count("vmess://")

                self._send_json({
                    "success": True,
                    "size_bytes": size_bytes,
                    "size_str": size_str,
                    "proxies_count": proxies_count,
                    "proxy_used": proxy
                })
            else:
                self._send_json({"success": False, "error": fetched})
            return

        # 404 Fallback
        self._send_response_headers(404, "text/plain; charset=utf-8")
        self.wfile.write(b"404 Not Found\n")

    def _serve_clash_subscription(self):
        """Generate and stream transformed Clash YAML subscription."""
        now = time.time()
        ttl = self.cm.get("subscription", "sub_cache_ttl", 300)

        # Use cache if fresh
        if AppRequestHandler._cached_yaml and (now - AppRequestHandler._cache_time < ttl):
            yaml_content = AppRequestHandler._cached_yaml
        else:
            sub_url = self.cm.get("subscription", "clash_sub_url", "")
            proxy = self.cm.get("subscription", "upstream_proxy", "socks5h://127.0.0.1:2080")
            sb_path = self.cm.get("singbox", "config_path", "/etc/sing-box/config.json")
            node_ip = self.cm.get_node_ip()
            target_pattern = self.cm.get("filter", "target_group_pattern", "节点选择")
            exclude_patterns = self.cm.get("filter", "exclude_group_patterns", ["自动选择", "节点"])
            custom_name = self.cm.get("singbox", "custom_node_name", "")

            yaml_content, summary = ClashParser.generate_full_subscription(
                sub_url=sub_url,
                singbox_path=sb_path,
                node_ip=node_ip,
                proxy=proxy,
                target_group_pattern=target_pattern,
                exclude_patterns=exclude_patterns,
                custom_node_name=custom_name
            )

            AppRequestHandler._cached_yaml = yaml_content
            AppRequestHandler._cached_summary = summary
            AppRequestHandler._cache_time = now

        body = yaml_content.encode("utf-8")
        extra_headers = {
            "Content-Disposition": 'attachment; filename="clash-singbox.yaml"',
            "Subscription-Userinfo": "upload=0; download=0; total=1073741824000; expire=0",
            "Profile-Update-Interval": "24",
            "Profile-Title": self.cm.get("subscription", "profile_name", "Singbox-Clash-Sub")
        }
        self._send_response_headers(200, "text/yaml; charset=utf-8", extra_headers=extra_headers)
        self.wfile.write(body)

    def _handle_test_sync(self):
        """Perform on-demand sync test and return preview JSON."""
        sub_url = self.cm.get("subscription", "clash_sub_url", "")
        proxy = self.cm.get("subscription", "upstream_proxy", "socks5h://127.0.0.1:2080")
        sb_path = self.cm.get("singbox", "config_path", "/etc/sing-box/config.json")
        node_ip = self.cm.get_node_ip()
        target_pattern = self.cm.get("filter", "target_group_pattern", "节点选择")
        exclude_patterns = self.cm.get("filter", "exclude_group_patterns", ["自动选择", "节点"])
        custom_name = self.cm.get("singbox", "custom_node_name", "")

        extracted_nodes = ClashParser.extract_singbox_inbounds(sb_path, node_ip, custom_name=custom_name)
        if not extracted_nodes:
            extracted_nodes = [{
                "name": custom_name or "singbox-node",
                "type": "socks5",
                "server": node_ip,
                "port": 4001
            }]

        yaml_content, summary = ClashParser.generate_full_subscription(
            sub_url=sub_url,
            singbox_path=sb_path,
            node_ip=node_ip,
            proxy=proxy,
            target_group_pattern=target_pattern,
            exclude_patterns=exclude_patterns,
            custom_node_name=custom_name
        )

        self._send_json({
            "success": True,
            "yaml": yaml_content,
            "summary": summary,
            "nodes": extracted_nodes
        })


def make_handler(config_manager: ConfigManager):
    """Factory to pass ConfigManager instance to Handler."""
    def handler(*args, **kwargs):
        return AppRequestHandler(*args, config_manager=config_manager, **kwargs)
    return handler


def start_server(host: str = "0.0.0.0", port: int = 8000, config_file: Optional[str] = None):
    """Start the multi-threaded HTTP server."""
    cm = ConfigManager(config_file)
    actual_host = host or cm.get("server", "host", "0.0.0.0")
    actual_port = port or cm.get("server", "port", 8000)

    handler = make_handler(cm)
    server = ThreadedHTTPServer((actual_host, actual_port), handler)

    effective_ip = cm.get_node_ip()
    sub_url = cm.get_full_subscription_url()

    print("=" * 66)
    print(" 🚀 Clash & Sing-box Subscription Manager Started")
    print("=" * 66)
    print(f" • Web Dashboard:   http://{effective_ip}:{actual_port}/")
    print(f" • Subscription:    {sub_url}")
    print(f" • Node Public IP:  {effective_ip}")
    print(f" • Upstream Proxy:  {cm.get('subscription', 'upstream_proxy', 'socks5h://127.0.0.1:2080')}")
    print(f" • Sing-box Path:   {cm.get('singbox', 'config_path')}")
    print(f" • Auth Account:    {cm.get('auth', 'username')}")
    print("=" * 66)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[INFO] Server shutting down.")
        server.server_close()


if __name__ == "__main__":
    start_server(port=8000)
