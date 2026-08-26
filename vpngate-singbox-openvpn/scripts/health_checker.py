#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Service Daemon & Health Monitor for vpngate-singbox-openvpn
- Supervises Sing-box and OpenVPN processes
- Periodically checks OpenVPN connectivity through the tun0 interface
- Rotates and connects through nodes in nodes_mapping.json sequentially upon health check failure until success
- Supports fallback to remote OVPN_REMOTE_URL if configured
- Emits comprehensive real-time status to /config/vpn_status.json
- Listens for manual switch trigger (/config/.switch_node)
"""

import os
import sys
import time
import json
import signal
import logging
import subprocess
import requests
from datetime import datetime
from typing import List, Dict, Any, Optional, Tuple

import config_processor
import ovpn_processor

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] [HealthChecker] %(message)s'
)
logger = logging.getLogger("health_checker")

CONFIG_DIR = os.environ.get("CONFIG_DIR", "/config")
STATUS_FILE = os.path.join(CONFIG_DIR, "vpn_status.json")
RUN_CONFIG_PATH = os.path.join(CONFIG_DIR, "singbox_run.json")
CLIENT_OVPN_PATH = os.path.join(CONFIG_DIR, os.environ.get("OPENVPN_CONFIG_FILE", "client.ovpn"))
RUN_OVPN_PATH = os.path.join(CONFIG_DIR, "openvpn_run.ovpn")
MAPPING_FILE_PATH = os.path.join(CONFIG_DIR, "nodes_mapping.json")
SWITCH_TRIGGER_FILE = os.path.join(CONFIG_DIR, ".switch_node")

class ServiceManager:
    def __init__(self):
        self.singbox_proc = None
        self.openvpn_proc = None
        self.running = True
        self.fail_count = 0
        self.last_status = {}
        self.last_sub_update = time.time()
        self.last_switch_time = ""

        # Node mapping tracking
        self.nodes_list: List[Dict[str, Any]] = []
        self.current_node_index = -1
        self.active_node_info: Optional[Dict[str, Any]] = None

        # Load environment variables
        self.check_interval = int(os.environ.get("CHECK_INTERVAL", "30"))
        self.fail_threshold = int(os.environ.get("CHECK_FAIL_THRESHOLD", "3"))
        self.check_timeout = int(os.environ.get("CHECK_TIMEOUT", "10"))
        self.check_target_url = os.environ.get("CHECK_TARGET_URL", "https://api.ipify.org")
        self.ovpn_remote_url = os.environ.get("OVPN_REMOTE_URL", "").strip()
        self.sub_update_interval = int(os.environ.get("SINGBOX_UPDATE_INTERVAL_HOURS", "0")) * 3600

        # Hardcoded real IP test targets to bypass host DNS Fake-IP hijacking
        self.hardcoded_targets = [
            {"url": "https://1.1.1.1/cdn-cgi/trace", "resolve": []},
            {"url": "https://1.0.0.1/cdn-cgi/trace", "resolve": []},
            {"url": "https://api.ipify.org", "resolve": [
                "api.ipify.org:443:104.26.12.205",
                "api.ipify.org:443:104.26.13.205",
                "api.ipify.org:443:172.67.74.152"
            ]},
            {"url": "http://ip-api.com/line?fields=query", "resolve": ["ip-api.com:80:208.95.112.1"]},
            {"url": "https://cloudflare.com/cdn-cgi/trace", "resolve": ["cloudflare.com:443:104.16.132.229"]}
        ]

    def load_nodes_mapping(self) -> List[Dict[str, Any]]:
        """
        Load and parse nodes_mapping.json from config directory.
        Returns a list of valid node dicts whose .ovpn files exist.
        """
        mapping_path = MAPPING_FILE_PATH
        if not os.path.exists(mapping_path):
            alt_path = os.path.join(CONFIG_DIR, "nodes.json")
            if os.path.exists(alt_path):
                mapping_path = alt_path
            else:
                self.nodes_list = []
                return []

        try:
            with open(mapping_path, "r", encoding="utf-8") as f:
                data = json.load(f)

            raw_nodes = []
            if isinstance(data, list):
                raw_nodes = data
            elif isinstance(data, dict):
                if "nodes" in data and isinstance(data["nodes"], list):
                    raw_nodes = data["nodes"]
                elif "nodes_map" in data and isinstance(data["nodes_map"], dict):
                    raw_nodes = list(data["nodes_map"].values())
                else:
                    for nid, nval in data.items():
                        if isinstance(nval, dict):
                            item = dict(nval)
                            item.setdefault("id", nid)
                            raw_nodes.append(item)

            valid_nodes = []
            for item in raw_nodes:
                if not isinstance(item, dict):
                    continue
                node_id = item.get("id", "")
                rel_path = item.get("rel_path", "")
                filename = item.get("filename", "") or (f"{node_id}.ovpn" if node_id else "")
                abs_path = item.get("path", "")

                candidate_paths = [
                    os.path.join(CONFIG_DIR, rel_path) if rel_path else None,
                    os.path.join(CONFIG_DIR, "ovpn_nodes", filename) if filename else None,
                    os.path.join(CONFIG_DIR, filename) if filename else None,
                    abs_path if abs_path and os.path.exists(abs_path) else None,
                ]

                resolved_path = None
                for p in candidate_paths:
                    if p and os.path.isfile(p):
                        resolved_path = os.path.abspath(p)
                        break

                if resolved_path:
                    node_entry = {
                        "id": node_id or os.path.splitext(filename)[0],
                        "filename": filename or os.path.basename(resolved_path),
                        "rel_path": os.path.relpath(resolved_path, CONFIG_DIR),
                        "path": resolved_path,
                        "ip": item.get("ip", ""),
                        "port": str(item.get("port", "443")),
                        "proto": item.get("proto", "tcp"),
                        "country": item.get("country", item.get("country_long", "Unknown")),
                        "country_short": item.get("country_short", "UN"),
                        "speed_mbps": float(item.get("speed_mbps", 0.0)),
                        "ping": int(item.get("ping", 0)),
                        "score": int(item.get("score", 0))
                    }
                    valid_nodes.append(node_entry)

            self.nodes_list = valid_nodes
            logger.info("Loaded %d usable nodes from mapping file (%s).", len(self.nodes_list), mapping_path)
            return self.nodes_list
        except Exception as e:
            logger.warning("Could not load nodes mapping from %s: %s", mapping_path, e)
            self.nodes_list = []
            return []

    def activate_node(self, node: Dict[str, Any]) -> bool:
        """
        Activate a specific node by generating openvpn_run.ovpn from its profile.
        Also copies the profile to client.ovpn.
        """
        src_path = node.get("path")
        if not src_path or not os.path.exists(src_path):
            logger.error("Node file does not exist: %s", src_path)
            return False

        try:
            success = ovpn_processor.process_file(src_path, RUN_OVPN_PATH)
            if not success:
                logger.error("Failed to process OpenVPN file for node %s", node.get("id"))
                return False

            try:
                with open(src_path, "r", encoding="utf-8", errors="ignore") as sf:
                    content = sf.read()
                with open(CLIENT_OVPN_PATH, "w", encoding="utf-8") as df:
                    df.write(content)
            except Exception as copy_err:
                logger.debug("Could not copy to client.ovpn: %s", copy_err)

            self.active_node_info = node
            return True
        except Exception as e:
            logger.error("Error activating node %s: %s", node.get("id"), e)
            return False

    def activate_node_by_index(self, index: int) -> bool:
        """Activate node by its index in the nodes_list."""
        if not self.nodes_list:
            self.load_nodes_mapping()
        if not self.nodes_list or index < 0 or index >= len(self.nodes_list):
            return False
        node = self.nodes_list[index]
        success = self.activate_node(node)
        if success:
            self.current_node_index = index
        return success

    def wait_for_tun_ready(self, max_wait_sec: int = 16) -> bool:
        """
        Actively poll until tun0 interface is created and assigned a valid IPv4 address.
        Returns immediately if OpenVPN process exits prematurely.
        """
        start = time.time()
        while time.time() - start < max_wait_sec:
            if not self.is_openvpn_running():
                return False
            if self.is_tun_up():
                tun_ip = self.get_tun_ip()
                if tun_ip:
                    self.setup_tun_policy_routing()
                    return True
            time.sleep(0.5)
        return False

    def attempt_connect_nodes_sequence(self, start_from_next: bool = True) -> bool:
        """
        Iterate through nodes in nodes_mapping.json sequentially until connection succeeds.
        Returns True if a node was successfully connected and verified healthy.
        """
        if not self.is_singbox_running():
            logger.error("[Failover] Sing-box is not running! Cannot attempt OpenVPN node connections.")
            return False

        self.load_nodes_mapping()
        if not self.nodes_list:
            logger.warning("[Failover] No mapped nodes found. Cannot perform node rotation.")
            return False

        total_nodes = len(self.nodes_list)
        if start_from_next:
            start_index = (self.current_node_index + 1) % total_nodes
        else:
            start_index = 0 if self.current_node_index < 0 else self.current_node_index

        logger.info("⚡ [Failover] Starting sequential node connection attempt through %d nodes (starting at #%d)...",
                    total_nodes, start_index + 1)

        for step in range(total_nodes):
            candidate_idx = (start_index + step) % total_nodes
            candidate_node = self.nodes_list[candidate_idx]
            node_id = candidate_node.get("id", f"node-{candidate_idx}")
            speed = candidate_node.get("speed_mbps", 0.0)
            country = candidate_node.get("country", "")

            logger.info("👉 [Failover %d/%d] Attempting node #%d: %s (%s, %s Mbps)...",
                        step + 1, total_nodes, candidate_idx + 1, node_id, country, speed)

            self.update_status(
                state="SWITCHING",
                active_node={**candidate_node, "index": candidate_idx, "total_nodes": total_nodes},
                error_msg=f"Attempting node {node_id} ({step + 1}/{total_nodes})"
            )

            if not self.activate_node(candidate_node):
                logger.warning("Could not activate node %s, trying next...", node_id)
                continue

            self.restart_openvpn()

            tun_ready = self.wait_for_tun_ready(max_wait_sec=16)
            if not tun_ready:
                logger.warning("❌ [Failover] Handshake timeout (tun0 did not appear within 16s) for node %s", node_id)
                continue

            healthy, exit_ip, err_msg = self.test_vpn_connectivity()

            if healthy:
                self.current_node_index = candidate_idx
                self.active_node_info = candidate_node
                self.fail_count = 0
                self.last_switch_time = datetime.now().isoformat()
                logger.info("🎉 [Failover SUCCESS] Connected successfully to node #%d: %s! Exit IP: %s",
                            candidate_idx + 1, node_id, exit_ip)
                self.update_status(
                    state="UP",
                    exit_ip=exit_ip,
                    active_node={**candidate_node, "index": candidate_idx, "total_nodes": total_nodes},
                    error_msg=""
                )
                return True
            else:
                logger.warning("❌ [Failover] Connection failed for node %s: %s", node_id, err_msg)

        logger.error("🚫 [Failover] All %d nodes in mapping failed connection test!", total_nodes)
        return False

    def update_status(self, state: str, exit_ip: str = "", active_node: Optional[Dict[str, Any]] = None, error_msg: str = ""):
        """Write current status to vpn_status.json."""
        node_data = active_node or self.active_node_info or {}
        if isinstance(node_data, dict):
            node_summary = {
                "id": node_data.get("id", ""),
                "ip": node_data.get("ip", ""),
                "port": node_data.get("port", ""),
                "proto": node_data.get("proto", ""),
                "country": node_data.get("country", ""),
                "country_short": node_data.get("country_short", ""),
                "speed_mbps": node_data.get("speed_mbps", 0.0),
                "index": node_data.get("index", self.current_node_index),
                "total_nodes": node_data.get("total_nodes", len(self.nodes_list))
            }
        else:
            node_summary = {}

        self.last_status = {
            "status": state,
            "exit_ip": exit_ip,
            "fail_count": self.fail_count,
            "active_node": node_summary,
            "last_check": datetime.now().isoformat(),
            "last_switch": self.last_switch_time,
            "last_error": error_msg,
            "singbox_running": self.is_singbox_running(),
            "openvpn_running": self.is_openvpn_running(),
            "tun_interface_up": self.is_tun_up()
        }
        try:
            with open(STATUS_FILE, "w", encoding="utf-8") as f:
                json.dump(self.last_status, f, indent=2, ensure_ascii=False)
        except Exception as e:
            logger.warning("Could not write status file: %s", e)

    def is_singbox_running(self) -> bool:
        return self.singbox_proc is not None and self.singbox_proc.poll() is None

    def is_openvpn_running(self) -> bool:
        return self.openvpn_proc is not None and self.openvpn_proc.poll() is None

    def is_tun_up(self) -> bool:
        """Check if tun0 interface exists in network namespace."""
        return os.path.exists("/sys/class/net/tun0")

    def get_tun_ip(self) -> Optional[str]:
        """Extract the assigned IPv4 address on tun0."""
        if not self.is_tun_up():
            return None
        try:
            res = subprocess.run(
                ["ip", "-4", "-o", "addr", "show", "dev", "tun0"],
                capture_output=True,
                text=True,
                timeout=2
            )
            if res.returncode == 0 and res.stdout.strip():
                parts = res.stdout.strip().split()
                for idx, p in enumerate(parts):
                    if p == "inet" and idx + 1 < len(parts):
                        return parts[idx + 1].split("/")[0]
        except Exception:
            pass
        return None

    def start_singbox(self) -> bool:
        """Start sing-box subprocess."""
        if self.is_singbox_running():
            logger.info("Sing-box is already running (PID %d).", self.singbox_proc.pid)
            return True

        if not os.path.exists(RUN_CONFIG_PATH):
            logger.info("No runtime sing-box config found. Generating initial bootstrap configuration...")
            try:
                config_processor.main(use_proxy=False)
            except Exception as e:
                logger.error("Error generating initial Sing-box configuration: %s", e)

        if not os.path.exists(RUN_CONFIG_PATH):
            logger.error("No valid Sing-box configuration found. Cannot start sing-box.")
            return False

        cmd = ["sing-box", "run", "-c", RUN_CONFIG_PATH]
        logger.info("Starting Sing-box: %s", " ".join(cmd))
        self.singbox_proc = subprocess.Popen(cmd)
        time.sleep(2)
        if self.singbox_proc.poll() is not None:
            logger.error("Sing-box exited immediately with code %s!", self.singbox_proc.returncode)
            return False

        socks_port = os.environ.get("SOCKS_INBOUND_PORT", "1080")
        logger.info("Sing-box started successfully with PID %d (socks-in proxy ready on 127.0.0.1:%s).",
                    self.singbox_proc.pid, socks_port)

        config_processor.save_as_raw_cache(RUN_CONFIG_PATH, config_processor.RAW_CONFIG_CACHE)

        sub_url = os.environ.get("SINGBOX_SUBSCRIPTION_URL", "").strip()
        if sub_url:
            self.refresh_singbox_subscription()
        return True

    def restart_singbox_process(self) -> bool:
        """Restart Sing-box process cleanly."""
        logger.info("Restarting Sing-box process...")
        self.stop_singbox()
        time.sleep(1)
        cmd = ["sing-box", "run", "-c", RUN_CONFIG_PATH]
        self.singbox_proc = subprocess.Popen(cmd)
        time.sleep(2)
        if self.is_singbox_running():
            logger.info("Sing-box restarted successfully with PID %d.", self.singbox_proc.pid)
            config_processor.save_as_raw_cache(RUN_CONFIG_PATH, config_processor.RAW_CONFIG_CACHE)
            return True
        else:
            logger.error("Sing-box failed to restart!")
            return False

    def refresh_singbox_subscription(self) -> bool:
        """Fetch latest Sing-box subscription via active socks-in proxy and reload if changed."""
        sub_url = os.environ.get("SINGBOX_SUBSCRIPTION_URL", "").strip()
        if not sub_url:
            return False

        logger.info("Refreshing Sing-box subscription via active socks-in proxy (%s)...",
                    config_processor.get_socks_proxy_url())
        try:
            raw_cfg = config_processor.fetch_subscription(sub_url, use_proxy=True)
            processed = config_processor.process_config(raw_cfg)

            if os.path.exists(RUN_CONFIG_PATH):
                try:
                    with open(RUN_CONFIG_PATH, "r", encoding="utf-8") as f:
                        old_cfg = json.load(f)
                    if old_cfg == processed:
                        logger.info("Sing-box configuration is already up-to-date.")
                        return True
                except Exception:
                    pass

            success = config_processor.validate_and_save(processed, RUN_CONFIG_PATH)
            if success:
                logger.info("Sing-box subscription updated from remote. Reloading Sing-box...")
                self.restart_singbox_process()
                return True
        except Exception as e:
            logger.warning("Could not refresh Sing-box subscription via proxy: %s", e)
        return False

    def stop_singbox(self):
        """Stop sing-box gracefully."""
        if self.is_singbox_running():
            logger.info("Stopping Sing-box (PID %d)...", self.singbox_proc.pid)
            self.singbox_proc.terminate()
            try:
                self.singbox_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.singbox_proc.kill()
            self.singbox_proc = None

    def start_openvpn(self) -> bool:
        """Start OpenVPN subprocess with current runtime configuration. Requires Sing-box running."""
        if not self.is_singbox_running():
            logger.error("Sing-box is not running! OpenVPN relies on Sing-box proxy and cannot be started.")
            return False

        if self.is_openvpn_running():
            logger.info("OpenVPN is already running (PID %d).", self.openvpn_proc.pid)
            return True

        if not os.path.exists(RUN_OVPN_PATH):
            self.load_nodes_mapping()
            if self.nodes_list:
                start_idx = 0 if self.current_node_index < 0 else self.current_node_index
                logger.info("Activating initial node #%d from nodes_mapping.json...", start_idx + 1)
                self.activate_node_by_index(start_idx)

        if not os.path.exists(RUN_OVPN_PATH):
            if os.path.exists(CLIENT_OVPN_PATH):
                ovpn_processor.process_file(CLIENT_OVPN_PATH, RUN_OVPN_PATH)
            elif self.ovpn_remote_url:
                logger.info("No local config found. Fetching initial .ovpn via socks-in proxy from %s ...", self.ovpn_remote_url)
                if not self.fetch_remote_ovpn(use_proxy=True):
                    logger.error("Initial .ovpn download failed.")
                    return False
            else:
                logger.error("No OpenVPN configuration found (no nodes_mapping.json, client.ovpn, or OVPN_REMOTE_URL).")
                return False

        if not os.path.exists(RUN_OVPN_PATH):
            logger.error("Failed to generate runtime OpenVPN configuration file: %s", RUN_OVPN_PATH)
            return False

        cmd = [
            "openvpn",
            "--config", RUN_OVPN_PATH,
            "--script-security", "2"
        ]
        logger.info("Starting OpenVPN: %s", " ".join(cmd))
        self.openvpn_proc = subprocess.Popen(cmd)
        time.sleep(2)
        if self.openvpn_proc.poll() is not None:
            logger.error("OpenVPN exited immediately with code %s!", self.openvpn_proc.returncode)
            return False
        else:
            logger.info("OpenVPN started successfully with PID %d.", self.openvpn_proc.pid)
            return True

    def stop_openvpn(self):
        """Stop OpenVPN gracefully."""
        if self.is_openvpn_running():
            logger.info("Stopping OpenVPN (PID %d)...", self.openvpn_proc.pid)
            self.openvpn_proc.terminate()
            try:
                self.openvpn_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.openvpn_proc.kill()
            self.openvpn_proc = None
        subprocess.run(["pkill", "-f", "openvpn --config"], capture_output=True)

    def restart_openvpn(self):
        """Restart OpenVPN with refreshed configuration."""
        logger.info("Restarting OpenVPN process...")
        self.stop_openvpn()
        time.sleep(1)
        self.start_openvpn()

    def fetch_remote_ovpn(self, use_proxy: bool = True) -> bool:
        """Download remote .ovpn configuration via Sing-box's socks-in proxy and update local file."""
        if not self.ovpn_remote_url:
            logger.warning("OVPN_REMOTE_URL is not configured; cannot fetch remote .ovpn.")
            return False

        proxy_url = config_processor.get_socks_proxy_url() if use_proxy else None

        try:
            content = config_processor.fetch_remote_url(
                self.ovpn_remote_url,
                proxy_url=proxy_url,
                timeout=20
            )

            if ("client" not in content and "remote" not in content and "dev" not in content):
                logger.error("Remote URL did not return a valid .ovpn configuration! Content snippet: %s", content[:150])
                return False

            if os.path.exists(CLIENT_OVPN_PATH):
                backup_file = f"{CLIENT_OVPN_PATH}.bak"
                try:
                    with open(CLIENT_OVPN_PATH, "r", encoding="utf-8", errors="ignore") as old_f:
                        with open(backup_file, "w", encoding="utf-8") as bak_f:
                            bak_f.write(old_f.read())
                except Exception as e:
                    logger.warning("Could not create backup of client.ovpn: %s", e)

            with open(CLIENT_OVPN_PATH, "w", encoding="utf-8") as f:
                f.write(content)
            logger.info("Saved new .ovpn configuration to %s (%d bytes)", CLIENT_OVPN_PATH, len(content))

            success = ovpn_processor.process_file(CLIENT_OVPN_PATH, RUN_OVPN_PATH)
            return success
        except Exception as e:
            logger.error("Failed to fetch remote .ovpn: %s", e)
            return False

    def setup_tun_policy_routing(self):
        """Ensure tun0 interface policy routing rules and default route in table 100 exist."""
        if self.is_tun_up():
            res = subprocess.run(["ip", "rule", "show"], capture_output=True, text=True)
            if "oif tun0" not in res.stdout:
                subprocess.run(["ip", "rule", "add", "oif", "tun0", "table", "100"], capture_output=True)
            if "from 10.0.0.0/8" not in res.stdout:
                subprocess.run(["ip", "rule", "add", "from", "10.0.0.0/8", "table", "100"], capture_output=True)
            subprocess.run(["ip", "route", "replace", "default", "dev", "tun0", "table", "100"], capture_output=True)

    def test_vpn_connectivity(self) -> Tuple[bool, str, str]:
        """
        Test network connectivity through tun0 interface.
        Bypasses host Sing-box Fake-IP DNS hijacking by:
        1. Binding directly to tun0's IPv4 address instead of interface string name.
        2. Using direct IP endpoints (e.g. 1.1.1.1) and hardcoded --resolve IP mappings.
        Returns (is_healthy, exit_ip, error_message).
        """
        if not self.is_tun_up():
            return False, "", "tun0 interface does not exist"

        tun_ip = self.get_tun_ip()
        if not tun_ip:
            return False, "", "tun0 interface has no IPv4 address assigned"

        self.setup_tun_policy_routing()

        test_items = list(self.hardcoded_targets)
        if self.check_target_url and not any(t["url"] == self.check_target_url for t in test_items):
            test_items.insert(0, {"url": self.check_target_url, "resolve": []})

        for item in test_items:
            url = item["url"]
            resolves = item.get("resolve", [])
            try:
                cmd = [
                    "curl",
                    "--interface", tun_ip,
                    "-s",
                    "--max-time", str(self.check_timeout)
                ]
                for r in resolves:
                    cmd.extend(["--resolve", r])
                cmd.append(url)

                res = subprocess.run(cmd, capture_output=True, text=True, timeout=self.check_timeout + 2)
                if res.returncode == 0 and res.stdout.strip():
                    raw_out = res.stdout.strip()
                    ip_candidate = ""
                    if "ip=" in raw_out:
                        for line in raw_out.splitlines():
                            if line.startswith("ip="):
                                ip_candidate = line.split("=", 1)[1].strip()
                    elif "\n" not in raw_out and len(raw_out) <= 45:
                        ip_candidate = raw_out
                    else:
                        ip_candidate = raw_out[:45].strip()

                    parts = ip_candidate.split(".")
                    if len(parts) == 4 and all(p.isdigit() for p in parts):
                        return True, ip_candidate, ""
                    elif ":" in ip_candidate:
                        return True, ip_candidate, ""
                    elif ip_candidate:
                        return True, ip_candidate, ""
            except Exception as e:
                logger.debug("Test failed against %s: %s", url, e)

        return False, "", "All test targets timed out or failed on tun0"

    def check_and_handle_switch_trigger(self):
        """Check for external manual switch signal file (.switch_node)."""
        if os.path.exists(SWITCH_TRIGGER_FILE):
            try:
                os.remove(SWITCH_TRIGGER_FILE)
            except Exception:
                pass
            logger.info("Manual switch trigger detected! Switching to next node in sequence...")
            self.attempt_connect_nodes_sequence(start_from_next=True)

    def handle_periodic_subscription_update(self):
        """Periodically refresh Sing-box subscription via active socks-in proxy if configured."""
        if self.sub_update_interval > 0:
            if time.time() - self.last_sub_update > self.sub_update_interval:
                logger.info("Periodic Sing-box subscription update triggered.")
                self.refresh_singbox_subscription()
                self.last_sub_update = time.time()

    def loop(self):
        """Main supervision and health checking loop."""
        singbox_ok = self.start_singbox()

        if singbox_ok and self.is_singbox_running():
            self.load_nodes_mapping()
            if self.nodes_list and self.current_node_index < 0:
                self.activate_node_by_index(0)

            self.start_openvpn()

            logger.info("Waiting for OpenVPN initial handshake (up to 16 seconds)...")
            tun_ready = self.wait_for_tun_ready(max_wait_sec=16)
            if tun_ready:
                healthy, exit_ip, err_msg = self.test_vpn_connectivity()
                if healthy:
                    logger.info("Initial connection verified! Exit IP: %s", exit_ip)
                    self.update_status("UP", exit_ip=exit_ip)
                else:
                    logger.warning("Initial node connection failed (%s). Triggering sequential failover...", err_msg)
                    self.attempt_connect_nodes_sequence(start_from_next=True)
            else:
                logger.warning("Initial OpenVPN handshake timed out. Triggering sequential failover...")
                self.attempt_connect_nodes_sequence(start_from_next=True)
        else:
            logger.error("Sing-box failed to start during initial boot. OpenVPN startup skipped.")
            self.update_status("ERROR", error_msg="Sing-box failed to start")

        while self.running:
            try:
                if not self.is_singbox_running():
                    logger.warning("Sing-box is not running! Restarting sing-box...")
                    self.start_singbox()

                if not self.is_singbox_running():
                    if self.is_openvpn_running():
                        logger.warning("Sing-box is down! Stopping OpenVPN as it depends on Sing-box proxy...")
                        self.stop_openvpn()
                    self.update_status("ERROR", error_msg="Sing-box is down")
                    for _ in range(self.check_interval):
                        if not self.running:
                            break
                        time.sleep(1)
                    continue

                self.check_and_handle_switch_trigger()

                if not self.is_openvpn_running():
                    logger.warning("OpenVPN process is not running! Restarting openvpn...")
                    self.start_openvpn()
                    self.wait_for_tun_ready(max_wait_sec=16)

                self.handle_periodic_subscription_update()

                healthy, exit_ip, err_msg = self.test_vpn_connectivity()

                if healthy:
                    if self.fail_count > 0:
                        logger.info("OpenVPN recovered to healthy state! Exit IP: %s", exit_ip)
                    logger.debug("HealthCheck PASS: OpenVPN is UP (tun0 exit IP: %s)", exit_ip)
                    self.fail_count = 0
                    self.update_status("UP", exit_ip=exit_ip)
                else:
                    self.fail_count += 1
                    logger.warning(
                        "HealthCheck FAIL (%d/%d): %s",
                        self.fail_count, self.fail_threshold, err_msg
                    )
                    self.update_status("FAILING", error_msg=err_msg)

                    if self.fail_count >= self.fail_threshold:
                        logger.warning(
                            "OpenVPN node failure threshold reached (%d consecutive failures). Initiating failover...",
                            self.fail_count
                        )
                        self.update_status("FAILOVER", error_msg="Threshold reached, rotating node...")

                        connected = self.attempt_connect_nodes_sequence(start_from_next=True)
                        if not connected:
                            if self.ovpn_remote_url:
                                logger.info("Mapped nodes exhausted. Attempting fallback to OVPN_REMOTE_URL...")
                                fetched = self.fetch_remote_ovpn(use_proxy=True)
                                if fetched:
                                    self.restart_openvpn()
                                    self.wait_for_tun_ready(max_wait_sec=16)
                            else:
                                logger.warning("Failover attempt completed without active connection. Will retry on next cycle.")

                        self.fail_count = 0

            except Exception as e:
                logger.exception("Unexpected error in main loop: %s", e)

            for _ in range(self.check_interval):
                if not self.running:
                    break
                if os.path.exists(SWITCH_TRIGGER_FILE):
                    break
                time.sleep(1)

        self.shutdown()

    def shutdown(self):
        logger.info("Received termination signal. Shutting down services...")
        self.stop_openvpn()
        self.stop_singbox()
        self.update_status("STOPPED")
        logger.info("Shutdown complete.")

def main():
    manager = ServiceManager()

    def sig_handler(signum, frame):
        logger.info("Signal %s received.", signum)
        manager.running = False

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    manager.loop()

if __name__ == "__main__":
    main()
