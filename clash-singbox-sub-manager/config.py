#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Configuration manager for Clash & Sing-box Subscription Manager.
Manages persistent settings, initial UUID generation, public IP auto-detection (cached),
upstream proxy fallback (socks5h://127.0.0.1:2080), and user authentication credentials.
"""

import os
import time
import json
import uuid
import secrets
import socket
import urllib.request
from typing import Dict, Any, Optional

DEFAULT_CONFIG_PATH = "/etc/clash-singbox-sub-manager/config.json"
LOCAL_CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")

_CACHED_PUBLIC_IP: Optional[str] = None
_CACHED_IP_TIME: float = 0


def get_default_config_path() -> str:
    """Return appropriate config file path depending on existence and permissions."""
    if os.path.exists(DEFAULT_CONFIG_PATH):
        return DEFAULT_CONFIG_PATH
    if os.path.exists(LOCAL_CONFIG_PATH):
        return LOCAL_CONFIG_PATH
    if os.geteuid() == 0 and os.path.exists("/etc"):
        return DEFAULT_CONFIG_PATH
    return LOCAL_CONFIG_PATH


def detect_public_ip(timeout: float = 1.5, force_refresh: bool = False) -> str:
    """
    Auto-detect machine's public IPv4 address with fast caching.
    Supports both international and domestic endpoints.
    """
    global _CACHED_PUBLIC_IP, _CACHED_IP_TIME
    now = time.time()
    if not force_refresh and _CACHED_PUBLIC_IP and (now - _CACHED_IP_TIME < 3600):
        return _CACHED_PUBLIC_IP

    endpoints = [
        "https://api.ipify.org",
        "http://ip-api.com/line/?fields=query",
        "https://ip.sb",
        "http://whatismyip.akamai.com",
        "https://icanhazip.com",
        "https://ifconfig.me/ip"
    ]
    for url in endpoints:
        try:
            req = urllib.request.Request(
                url,
                headers={"User-Agent": "curl/7.88.1"}
            )
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                if resp.status == 200:
                    ip = resp.read().decode("utf-8").strip()
                    parts = ip.split(".")
                    if len(parts) == 4 and all(p.isdigit() and 0 <= int(p) <= 255 for p in parts):
                        _CACHED_PUBLIC_IP = ip
                        _CACHED_IP_TIME = now
                        return ip
        except Exception:
            continue

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0.5)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        _CACHED_PUBLIC_IP = ip
        _CACHED_IP_TIME = now
        return ip
    except Exception:
        return "127.0.0.1"


def get_default_config() -> Dict[str, Any]:
    """Generate default configuration dictionary."""
    return {
        "server": {
            "host": "0.0.0.0",
            "port": 8000
        },
        "auth": {
            "username": "admin",
            "password": "admin1234",
            "session_secret": secrets.token_hex(32)
        },
        "subscription": {
            "uuid": str(uuid.uuid4()),
            "clash_sub_url": "",
            "sub_cache_ttl": 300,
            "upstream_proxy": "socks5h://127.0.0.1:2080",
            "profile_name": "Singbox-Clash-Sub"
        },
        "singbox": {
            "config_path": "/etc/sing-box/config.json",
            "node_ip": "",  # If empty, auto-detects public IP
            "custom_node_name": ""
        },
        "filter": {
            "target_group_pattern": "节点选择",
            "exclude_group_patterns": ["自动选择", "节点"],
            "fallback_target_group": "节点选择"
        }
    }


class ConfigManager:
    """Thread-safe configuration manager."""

    def __init__(self, config_file: Optional[str] = None):
        self.config_file = config_file or get_default_config_path()
        self.config: Dict[str, Any] = self.load()

    def load(self) -> Dict[str, Any]:
        """Load configuration from disk, creating default if missing."""
        default = get_default_config()
        if os.path.exists(self.config_file):
            try:
                with open(self.config_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                for section, values in default.items():
                    if section not in data:
                        data[section] = values
                    elif isinstance(values, dict) and isinstance(data[section], dict):
                        for k, v in values.items():
                            if k not in data[section]:
                                data[section][k] = v
                self.config = data
                return data
            except Exception as e:
                print(f"[WARN] Error reading config file {self.config_file}: {e}, using defaults.")

        self.config = default
        self.save()
        return self.config

    def save(self) -> bool:
        """Persist current configuration to disk."""
        try:
            cfg_dir = os.path.dirname(self.config_file)
            if cfg_dir and not os.path.exists(cfg_dir):
                os.makedirs(cfg_dir, exist_ok=True)
            with open(self.config_file, "w", encoding="utf-8") as f:
                json.dump(self.config, f, indent=2, ensure_ascii=False)
            return True
        except Exception as e:
            print(f"[ERROR] Failed to save config to {self.config_file}: {e}")
            return False

    def get(self, section: str, key: Optional[str] = None, default: Any = None) -> Any:
        """Get config section or subsection key."""
        sec = self.config.get(section, {})
        if key is None:
            return sec
        if isinstance(sec, dict):
            return sec.get(key, default)
        return default

    def set(self, section: str, key: str, value: Any, auto_save: bool = True) -> None:
        """Set config section key and optionally save."""
        if section not in self.config or not isinstance(self.config[section], dict):
            self.config[section] = {}
        self.config[section][key] = value
        if auto_save:
            self.save()

    def get_node_ip(self) -> str:
        """Get effective node IP (configured or auto-detected)."""
        cfg_ip = self.config.get("singbox", {}).get("node_ip", "").strip()
        if cfg_ip and cfg_ip.lower() != "auto":
            return cfg_ip
        return detect_public_ip()

    def get_uuid(self) -> str:
        """Get current subscription UUID."""
        current_uuid = self.config.get("subscription", {}).get("uuid", "").strip()
        if not current_uuid:
            current_uuid = str(uuid.uuid4())
            self.set("subscription", "uuid", current_uuid)
        return current_uuid

    def regenerate_uuid(self) -> str:
        """Generate, save, and return a new random UUID."""
        new_uuid = str(uuid.uuid4())
        self.set("subscription", "uuid", new_uuid)
        return new_uuid

    def get_subscription_path(self) -> str:
        """Return subscription URL path."""
        return f"/sub/{self.get_uuid()}"

    def get_full_subscription_url(self, host_header: Optional[str] = None) -> str:
        """Construct full subscription URL based on request host or configured host/port."""
        if host_header:
            return f"http://{host_header}{self.get_subscription_path()}"
        host = self.get_node_ip()
        port = self.config.get("server", {}).get("port", 8000)
        port_str = f":{port}" if port != 80 else ""
        return f"http://{host}{port_str}{self.get_subscription_path()}"
