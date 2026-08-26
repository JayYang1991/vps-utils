#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Clash and Sing-box Subscription Processor.
1. Extracts proxy inbound nodes from /etc/sing-box/config.json and assigns the specified public IP.
2. Fetches upstream Clash subscription YAML (prioritizing local socks5h proxy with direct fallback).
3. Removes all upstream proxy nodes, replacing them with the extracted sing-box nodes.
4. Adds extracted nodes to proxy groups containing "节点选择" (prioritizing non-socks nodes, putting SOCKS protocol nodes at the end).
5. Removes proxy groups and references containing "自动选择", "XX节点" (or regional node groups).
6. Preserves all other configurations (rules, rule-providers, DNS, routing settings).
"""

import os
import sys
import re
import ssl
import time
import json
import gzip
import zlib
import base64
import subprocess
import urllib.request
from typing import Dict, List, Any, Tuple, Optional, Set
import yaml

_UPSTREAM_SUB_CACHE: Dict[str, Tuple[float, str]] = {}


class ClashParser:
    """Clash subscription processor and Sing-box inbounds extractor."""

    DEFAULT_FALLBACK_TEMPLATE = """
port: 7890
socks-port: 7891
mixed-port: 7892
allow-lan: true
mode: rule
log-level: info
external-controller: 127.0.0.1:9090

proxies: []

proxy-groups:
  - name: 节点选择
    type: select
    proxies:
      - DIRECT

rules:
  - DOMAIN-SUFFIX,local,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,节点选择
"""

    @staticmethod
    def derive_x25519_public_key(private_key_str: str) -> str:
        """Derive x25519 public key from private key base64 URL-safe string."""
        if not private_key_str or not private_key_str.strip():
            return ""
        try:
            import base64
            s = private_key_str.strip()
            pad_len = (4 - len(s) % 4) % 4
            priv_bytes = base64.urlsafe_b64decode(s + "=" * pad_len)
            if len(priv_bytes) == 32:
                from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
                priv_key = X25519PrivateKey.from_private_bytes(priv_bytes)
                pub_bytes = priv_key.public_key().public_bytes_raw()
                return base64.urlsafe_b64encode(pub_bytes).decode().rstrip("=")
        except Exception:
            pass
        return ""

    @staticmethod
    def is_socks_node(node: Dict[str, Any]) -> bool:
        """Check if a node dictionary represents a SOCKS/SOCKS5 protocol proxy."""
        if not isinstance(node, dict):
            return False
        t = str(node.get("type", "")).strip().lower()
        return t in ("socks5", "socks", "socks4", "socks5h", "mixed") or t.startswith("socks")

    @classmethod
    def sort_nodes_socks_last(cls, nodes: Optional[List[Dict[str, Any]]]) -> List[Dict[str, Any]]:
        """
        Sort nodes so that non-socks nodes come first, and socks protocol nodes are placed at the end.
        Preserves relative order within each category.
        """
        if not nodes:
            return []
        non_socks = [n for n in nodes if not cls.is_socks_node(n)]
        socks = [n for n in nodes if cls.is_socks_node(n)]
        return non_socks + socks

    @classmethod
    def extract_singbox_inbounds(cls, singbox_path: str, node_ip: str, custom_name: str = "") -> List[Dict[str, Any]]:
        """
        Read /etc/sing-box/config.json and extract proxy inbound definitions as Clash proxy nodes.
        Supports mixed, socks, http, shadowsocks, trojan, vless, vmess, hysteria2, hysteria, tuic.
        Ignores non-client-proxy inbounds like tun, direct, redirect, tproxy.
        """
        if not os.path.exists(singbox_path):
            return []

        try:
            with open(singbox_path, "r", encoding="utf-8") as f:
                sb_cfg = json.load(f)
        except Exception as e:
            print(f"[WARN] Error reading sing-box config at {singbox_path}: {e}")
            return []

        inbounds = sb_cfg.get("inbounds", [])
        if not isinstance(inbounds, list):
            return []

        extracted_nodes: List[Dict[str, Any]] = []

        for idx, ib in enumerate(inbounds):
            if not isinstance(ib, dict):
                continue

            ib_type = ib.get("type", "").lower()
            tag = ib.get("tag") or (custom_name if custom_name else f"singbox-{ib_type}-{idx + 1}")
            if custom_name and len(inbounds) > 1:
                tag = f"{custom_name}-{idx + 1}"

            listen_port = ib.get("listen_port")
            if listen_port is None:
                continue

            try:
                listen_port = int(listen_port)
            except (ValueError, TypeError):
                continue

            node: Optional[Dict[str, Any]] = None

            if ib_type in ("mixed", "socks"):
                node = {
                    "name": tag,
                    "type": "socks5",
                    "server": node_ip,
                    "port": listen_port
                }
                users = ib.get("users", [])
                if users and isinstance(users, list) and len(users) > 0:
                    u = users[0]
                    if isinstance(u, dict):
                        if u.get("username"):
                            node["username"] = u["username"]
                        if u.get("password"):
                            node["password"] = u["password"]

            elif ib_type == "http":
                node = {
                    "name": tag,
                    "type": "http",
                    "server": node_ip,
                    "port": listen_port
                }
                users = ib.get("users", [])
                if users and isinstance(users, list) and len(users) > 0:
                    u = users[0]
                    if isinstance(u, dict):
                        if u.get("username"):
                            node["username"] = u["username"]
                        if u.get("password"):
                            node["password"] = u["password"]

            elif ib_type in ("shadowsocks", "ss"):
                method = ib.get("method") or "aes-256-gcm"
                password = ib.get("password", "")
                node = {
                    "name": tag,
                    "type": "ss",
                    "server": node_ip,
                    "port": listen_port,
                    "cipher": method,
                    "password": password
                }

            elif ib_type == "trojan":
                users = ib.get("users", [])
                pwd = users[0].get("password", "") if users and isinstance(users[0], dict) else ""
                tls = ib.get("tls", {})
                node = {
                    "name": tag,
                    "type": "trojan",
                    "server": node_ip,
                    "port": listen_port,
                    "password": pwd,
                    "sni": tls.get("server_name", ""),
                    "skip-cert-verify": tls.get("insecure", False)
                }

            elif ib_type == "vless":
                users = ib.get("users", [])
                u = users[0] if users and isinstance(users[0], dict) else {}
                tls = ib.get("tls", {})
                node = {
                    "name": tag,
                    "type": "vless",
                    "server": node_ip,
                    "port": listen_port,
                    "uuid": u.get("uuid", ""),
                    "flow": u.get("flow", ""),
                    "tls": bool(tls.get("enabled", False)),
                    "servername": tls.get("server_name", "")
                }
                reality = tls.get("reality", {})
                if reality.get("enabled"):
                    raw_short_id = reality.get("short_id", reality.get("short_ids", ""))
                    if isinstance(raw_short_id, list):
                        short_id = str(raw_short_id[0]) if raw_short_id else ""
                    else:
                        short_id = str(raw_short_id) if raw_short_id is not None else ""

                    pub_key = reality.get("public_key", reality.get("public-key", ""))
                    if not pub_key:
                        priv_key = reality.get("private_key", reality.get("private-key", ""))
                        if priv_key:
                            pub_key = ClashParser.derive_x25519_public_key(priv_key)

                    node["client-fingerprint"] = reality.get("client_fingerprint", "chrome")
                    node["reality-opts"] = {
                        "public-key": pub_key,
                        "short-id": short_id
                    }

            elif ib_type == "vmess":
                users = ib.get("users", [])
                u = users[0] if users and isinstance(users[0], dict) else {}
                tls = ib.get("tls", {})
                node = {
                    "name": tag,
                    "type": "vmess",
                    "server": node_ip,
                    "port": listen_port,
                    "uuid": u.get("uuid", ""),
                    "alterId": u.get("alter_id", 0),
                    "cipher": "auto",
                    "tls": bool(tls.get("enabled", False))
                }

            elif ib_type in ("hysteria2", "hy2"):
                users = ib.get("users", [])
                pwd = users[0].get("password", "") if users and isinstance(users[0], dict) else ""
                tls = ib.get("tls", {})
                node = {
                    "name": tag,
                    "type": "hysteria2",
                    "server": node_ip,
                    "port": listen_port,
                    "password": pwd,
                    "sni": tls.get("server_name", ""),
                    "skip-cert-verify": tls.get("insecure", False)
                }

            elif ib_type == "hysteria":
                tls = ib.get("tls", {})
                node = {
                    "name": tag,
                    "type": "hysteria",
                    "server": node_ip,
                    "port": listen_port,
                    "auth_str": ib.get("auth_str", ""),
                    "sni": tls.get("server_name", ""),
                    "skip-cert-verify": tls.get("insecure", False)
                }

            elif ib_type == "tuic":
                users = ib.get("users", [])
                u = users[0] if users and isinstance(users[0], dict) else {}
                tls = ib.get("tls", {})
                node = {
                    "name": tag,
                    "type": "tuic",
                    "server": node_ip,
                    "port": listen_port,
                    "uuid": u.get("uuid", ""),
                    "password": u.get("password", ""),
                    "sni": tls.get("server_name", ""),
                    "skip-cert-verify": tls.get("insecure", False)
                }

            if node:
                extracted_nodes.append(node)

        return cls.sort_nodes_socks_last(extracted_nodes)

    @staticmethod
    def fetch_subscription(
        sub_url: str,
        proxy: str = "socks5h://127.0.0.1:2080",
        timeout: float = 30.0,
        force_refresh: bool = False,
        cache_ttl: float = 300.0
    ) -> Tuple[bool, str]:
        """
        Fetch upstream subscription content.
        Strategy:
        1. Prioritize local proxy (e.g. socks5h://127.0.0.1:2080).
        2. If proxy fails or is unavailable, print detailed error reason and automatically fallback to direct connection (直连).
        3. Supports Gzip / Deflate compression and caching.
        """
        if not sub_url or not sub_url.strip():
            return False, "订阅链接为空"

        url = sub_url.strip()
        now = time.time()

        # Check cache
        if not force_refresh and url in _UPSTREAM_SUB_CACHE:
            cached_time, cached_content = _UPSTREAM_SUB_CACHE[url]
            if now - cached_time < cache_ttl and cached_content:
                return True, cached_content

        user_agent = "ClashMeta/v1.18.0 (Clash for Windows; clash-meta)"
        proxy_err_msg = ""
        is_proxy_configured = bool(proxy and proxy.strip() and proxy.strip().lower() not in ("none", "direct", "off", "false"))

        # 1. Attempt 1: Via Proxy (if proxy is configured)
        if is_proxy_configured:
            proxy_url = proxy.strip()
            try:
                cmd = [
                    "curl", "-sS", "--compressed", "-L",
                    "--max-time", "15",
                    "--proxy", proxy_url,
                    "-A", user_agent,
                    url
                ]
                res = subprocess.run(cmd, capture_output=True, timeout=20)
                if res.returncode == 0 and len(res.stdout) > 0:
                    content = res.stdout.decode("utf-8", errors="replace").strip()
                    if content:
                        _UPSTREAM_SUB_CACHE[url] = (now, content)
                        log_msg = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [ClashParser] ✅ 成功通过代理 ({proxy_url}) 拉取上游订阅 (大小: {len(content)} 字节)\n"
                        sys.stderr.write(log_msg)
                        sys.stderr.flush()
                        return True, content
                    else:
                        proxy_err_msg = "代理请求成功但返回内容为空 (0 字节)"
                else:
                    stderr_msg = res.stderr.decode("utf-8", errors="replace").strip()
                    curl_code = res.returncode
                    code_desc = {
                        6: "无法解析主机名 (Couldn't resolve host)",
                        7: "无法连接到代理服务器 (Failed to connect to proxy / Connection refused)",
                        28: "操作超时 (Operation timeout)",
                        35: "SSL/TLS 握手失败 (SSL connect error)",
                        52: "服务器未返回任何数据 (Empty reply from server)",
                        56: "接收网络数据失败 (Failure with receiving network data)",
                        97: "SOCKS 代理握手协商失败 (Proxy handshake failed)"
                    }.get(curl_code, f"curl 退出码 {curl_code}")

                    if stderr_msg:
                        proxy_err_msg = f"{code_desc} - {stderr_msg}"
                    else:
                        proxy_err_msg = code_desc
            except subprocess.TimeoutExpired:
                proxy_err_msg = "代理请求超时 (超过 20 秒未响应)"
            except Exception as e:
                proxy_err_msg = f"代理请求异常: {type(e).__name__}: {str(e)}"

            log_msg = (
                f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [ClashParser] ⚠️ 代理拉取上游订阅失败 "
                f"(代理: {proxy_url}, 目标: {url})\n"
                f"   ↳ 详细失败原因: {proxy_err_msg}\n"
                f"   ↳ 正在自动回落到直连模式重试...\n"
            )
            sys.stderr.write(log_msg)
            sys.stderr.flush()

        # 2. Attempt 2: Direct Connection via curl (直连回落)
        direct_curl_err = ""
        try:
            cmd = [
                "curl", "-sS", "--compressed", "-L",
                "--max-time", str(int(timeout)),
                "-A", user_agent,
                url
            ]
            res = subprocess.run(cmd, capture_output=True, timeout=timeout + 5)
            if res.returncode == 0 and len(res.stdout) > 0:
                content = res.stdout.decode("utf-8", errors="replace").strip()
                if content:
                    _UPSTREAM_SUB_CACHE[url] = (now, content)
                    log_msg = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [ClashParser] ℹ️ 直连回落成功，已拉取上游订阅 (大小: {len(content)} 字节)\n"
                    sys.stderr.write(log_msg)
                    sys.stderr.flush()
                    return True, content
            else:
                stderr_msg = res.stderr.decode("utf-8", errors="replace").strip()
                direct_curl_err = f"curl 错误 (退出码: {res.returncode}): {stderr_msg}" if stderr_msg else f"curl 退出码 {res.returncode}"
        except Exception as e:
            direct_curl_err = f"curl 直连异常: {e}"

        # 3. Attempt 3: Direct Connection via urllib.request (with unverified SSL)
        direct_urllib_err = ""
        headers = {
            "User-Agent": user_agent,
            "Accept": "*/*",
            "Accept-Encoding": "gzip, deflate",
            "Connection": "close"
        }

        try:
            ctx = ssl._create_unverified_context()
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
                raw = resp.read()
                encoding = resp.headers.get("Content-Encoding", "").lower()
                if "gzip" in encoding:
                    try:
                        raw = gzip.decompress(raw)
                    except Exception:
                        pass
                elif "deflate" in encoding:
                    try:
                        raw = zlib.decompress(raw)
                    except Exception:
                        pass
                content = raw.decode("utf-8", errors="replace").strip()
                if content:
                    _UPSTREAM_SUB_CACHE[url] = (now, content)
                    log_msg = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [ClashParser] ℹ️ 直连 (urllib) 成功，已拉取上游订阅 (大小: {len(content)} 字节)\n"
                    sys.stderr.write(log_msg)
                    sys.stderr.flush()
                    return True, content
                return False, "获取到的订阅内容为空"
        except Exception as e:
            direct_urllib_err = f"urllib 直连异常: {e}"

        # Final failure report
        direct_err_summary = direct_urllib_err or direct_curl_err or "直连连接失败"
        log_msg = (
            f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [ClashParser] ❌ 直连拉取上游订阅亦失败 (目标: {url})\n"
            f"   ↳ 详细失败原因: {direct_err_summary}\n"
        )
        sys.stderr.write(log_msg)
        sys.stderr.flush()

        if is_proxy_configured and proxy_err_msg:
            return False, f"获取订阅失败: [代理失败原因] {proxy_err_msg}; [直连失败原因] {direct_err_summary}"
        else:
            return False, f"获取订阅失败 (直连不可用): {direct_err_summary}"

    @classmethod
    def should_delete_group(cls, group_name: str, target_pattern: str = "节点选择",
                            exclude_patterns: Optional[List[str]] = None) -> bool:
        """
        Determine whether a proxy group should be deleted.
        Rule:
        - If group name contains target_pattern ("节点选择"), it MUST BE KEPT.
        - If group name contains "自动选择", it is deleted.
        - If group name contains "XX节点" or matches regional/generic node patterns like `.+节点` (and not 节点选择), it is deleted.
        - Any custom exclude patterns matched.
        """
        if not group_name:
            return False

        if target_pattern in group_name:
            return False

        if "自动选择" in group_name:
            return True

        if re.search(r".+节点$", group_name):
            return True

        if exclude_patterns:
            for pat in exclude_patterns:
                pat = pat.strip()
                if not pat:
                    continue
                if pat in group_name:
                    return True

        return False

    @classmethod
    def transform_config(
        cls,
        raw_clash_yaml: str,
        singbox_nodes: List[Dict[str, Any]],
        target_group_pattern: str = "节点选择",
        exclude_patterns: Optional[List[str]] = None,
        fallback_group: str = "节点选择"
    ) -> Tuple[str, Dict[str, Any]]:
        """
        Transform Clash subscription config:
        1. Clear all original proxies, inject singbox_nodes (sorting SOCKS protocol nodes to the end).
        2. Filter proxy-groups: remove groups with "自动选择" or "XX节点".
        3. Inject extracted node(s) into groups containing "节点选择" (SOCKS nodes placed at the end).
        4. Clean references to deleted groups/nodes in remaining proxy-groups.
        5. Rewrite rule targets pointing to deleted groups/nodes to fallback_group.
        6. Preserve all other settings.
        Returns: (transformed_yaml_str, summary_dict)
        """
        if exclude_patterns is None:
            exclude_patterns = ["自动选择", "节点"]

        clash_data = None
        if raw_clash_yaml and raw_clash_yaml.strip():
            cleaned_input = raw_clash_yaml.strip()
            if not ("proxies:" in cleaned_input or "proxy-groups:" in cleaned_input or "port:" in cleaned_input):
                try:
                    decoded = base64.b64decode(cleaned_input).decode("utf-8", errors="replace")
                    if "proxies:" in decoded or "proxy-groups:" in decoded:
                        cleaned_input = decoded
                except Exception:
                    pass

            try:
                clash_data = yaml.safe_load(cleaned_input)
            except Exception as e:
                print(f"[WARN] Failed to parse input YAML ({e}), using fallback template")

        if not isinstance(clash_data, dict):
            clash_data = yaml.safe_load(cls.DEFAULT_FALLBACK_TEMPLATE)

        if not singbox_nodes:
            singbox_nodes = [{
                "name": "singbox-direct",
                "type": "socks5",
                "server": "127.0.0.1",
                "port": 1080
            }]
        else:
            singbox_nodes = cls.sort_nodes_socks_last(singbox_nodes)

        new_node_names = [n["name"] for n in singbox_nodes]

        # 1. Replace proxies
        original_proxies = clash_data.get("proxies", [])
        original_proxy_names: Set[str] = set()
        if isinstance(original_proxies, list):
            for p in original_proxies:
                if isinstance(p, dict) and "name" in p:
                    original_proxy_names.add(p["name"])

        clash_data["proxies"] = singbox_nodes

        # 2. Filter proxy-groups
        raw_groups = clash_data.get("proxy-groups", [])
        if not isinstance(raw_groups, list):
            raw_groups = []

        deleted_groups: Set[str] = set()
        kept_groups: List[Dict[str, Any]] = []

        for grp in raw_groups:
            if not isinstance(grp, dict):
                continue
            name = grp.get("name", "")
            if cls.should_delete_group(name, target_pattern=target_group_pattern, exclude_patterns=exclude_patterns):
                deleted_groups.add(name)
            else:
                kept_groups.append(grp)

        # 3. Ensure a target group containing target_group_pattern exists
        target_group_names = [g["name"] for g in kept_groups if target_group_pattern in g.get("name", "")]

        if not target_group_names:
            main_target_group = {
                "name": target_group_pattern,
                "type": "select",
                "proxies": list(new_node_names) + ["DIRECT"]
            }
            kept_groups.insert(0, main_target_group)
            target_group_names = [target_group_pattern]
            primary_target = target_group_pattern
        else:
            primary_target = target_group_names[0]

        # 4. Clean and update proxies list in each remaining group
        for grp in kept_groups:
            g_name = grp.get("name", "")
            is_target = target_group_pattern in g_name

            current_proxies = grp.get("proxies", [])
            if not isinstance(current_proxies, list):
                current_proxies = []

            cleaned_proxies: List[str] = []
            for item in current_proxies:
                if item in deleted_groups:
                    continue
                if item in original_proxy_names and item not in new_node_names:
                    continue
                cleaned_proxies.append(item)

            if is_target:
                # Remove any existing occurrences of new_node_names to preserve exact ordering
                remaining_proxies = [p for p in cleaned_proxies if p not in new_node_names]
                cleaned_proxies = list(new_node_names) + remaining_proxies
                if not cleaned_proxies:
                    cleaned_proxies = list(new_node_names)
            else:
                if not cleaned_proxies:
                    if primary_target != g_name:
                        cleaned_proxies.append(primary_target)
                    else:
                        cleaned_proxies.extend(new_node_names)

            grp["proxies"] = cleaned_proxies

        clash_data["proxy-groups"] = kept_groups

        # 5. Fix rules pointing to deleted groups or old proxy nodes
        valid_targets = {g["name"] for g in kept_groups}
        valid_targets.update(new_node_names)
        valid_targets.update({"DIRECT", "REJECT", "GLOBAL", "COMPATIBLE", "no-resolve"})

        original_rules = clash_data.get("rules", [])
        updated_rules: List[str] = []
        rules_rewritten_count = 0

        if isinstance(original_rules, list):
            for rule_entry in original_rules:
                if not isinstance(rule_entry, str):
                    continue

                parts = [p.strip() for p in rule_entry.split(",")]
                if len(parts) >= 2:
                    if parts[0].upper() == "MATCH":
                        target = parts[1]
                        if target in deleted_groups or (target in original_proxy_names and target not in new_node_names) or target not in valid_targets:
                            parts[1] = primary_target
                            rules_rewritten_count += 1
                    elif len(parts) >= 3:
                        target = parts[2]
                        if target in deleted_groups or (target in original_proxy_names and target not in new_node_names) or target not in valid_targets:
                            parts[2] = primary_target
                            rules_rewritten_count += 1

                updated_rules.append(",".join(parts))

        clash_data["rules"] = updated_rules

        output_yaml = yaml.dump(
            clash_data,
            sort_keys=False,
            allow_unicode=True,
            default_flow_style=False
        )

        summary = {
            "injected_nodes_count": len(singbox_nodes),
            "injected_nodes": new_node_names,
            "deleted_groups_count": len(deleted_groups),
            "deleted_groups": list(deleted_groups),
            "kept_groups_count": len(kept_groups),
            "kept_groups": [g["name"] for g in kept_groups],
            "rules_count": len(updated_rules),
            "rules_rewritten_count": rules_rewritten_count,
            "target_groups": target_group_names
        }

        return output_yaml, summary

    @classmethod
    def generate_full_subscription(
        cls,
        sub_url: str,
        singbox_path: str,
        node_ip: str,
        proxy: str = "socks5h://127.0.0.1:2080",
        target_group_pattern: str = "节点选择",
        exclude_patterns: Optional[List[str]] = None,
        custom_node_name: str = "",
        force_refresh: bool = False
    ) -> Tuple[str, Dict[str, Any]]:
        """
        One-stop helper:
        1. Extract singbox inbounds
        2. Fetch upstream subscription (priority via proxy, fallback direct)
        3. Transform and return final Clash YAML + summary
        """
        singbox_nodes = cls.extract_singbox_inbounds(singbox_path, node_ip, custom_name=custom_node_name)
        if not singbox_nodes:
            singbox_nodes = [{
                "name": custom_node_name or "singbox-node",
                "type": "socks5",
                "server": node_ip,
                "port": 4001
            }]

        raw_yaml = ""
        if sub_url and sub_url.strip():
            ok, fetched = cls.fetch_subscription(sub_url, proxy=proxy, force_refresh=force_refresh)
            if ok:
                raw_yaml = fetched
            else:
                raw_yaml = cls.DEFAULT_FALLBACK_TEMPLATE
        else:
            raw_yaml = cls.DEFAULT_FALLBACK_TEMPLATE

        return cls.transform_config(
            raw_clash_yaml=raw_yaml,
            singbox_nodes=singbox_nodes,
            target_group_pattern=target_group_pattern,
            exclude_patterns=exclude_patterns
        )
