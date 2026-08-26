#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
OpenVPN Configuration Processor
- Ensures OpenVPN does NOT modify the default system routing table (injects route-nopull)
- Optionally directs OpenVPN outbound traffic through Sing-box's SOCKS inbound port when OPENVPN_USE_PROXY is true (default: false / direct)
- Configures authentication credentials (auth.txt) if required
- Prepares sanitized and operational /config/openvpn_run.ovpn
"""

import os
import sys
import re
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] [OvpnProcessor] %(message)s'
)
logger = logging.getLogger("ovpn_processor")

def get_config_dir():
    return os.environ.get("CONFIG_DIR", "/config")

def get_client_ovpn_path():
    return os.path.join(get_config_dir(), os.environ.get("OPENVPN_CONFIG_FILE", "client.ovpn"))

def get_run_ovpn_path():
    return os.path.join(get_config_dir(), "openvpn_run.ovpn")

def get_auth_file_path():
    return os.path.join(get_config_dir(), "auth.txt")

CLIENT_OVPN_PATH = get_client_ovpn_path()
RUN_OVPN_PATH = get_run_ovpn_path()
AUTH_FILE_PATH = get_auth_file_path()

def ensure_auth_file():
    """Create auth.txt if credentials are provided in environment and file missing."""
    auth_path = get_auth_file_path()
    user = os.environ.get("OPENVPN_AUTH_USER", "vpn").strip()
    pwd = os.environ.get("OPENVPN_AUTH_PASS", "vpn").strip()

    if not os.path.exists(auth_path):
        if user or pwd:
            os.makedirs(os.path.dirname(auth_path), exist_ok=True)
            logger.info("Generating auth.txt with provided credentials (%s / ***)", user)
            with open(auth_path, "w", encoding="utf-8") as f:
                f.write(f"{user}\n{pwd}\n")
            os.chmod(auth_path, 0o600)
    else:
        logger.info("Using existing auth.txt file.")

def is_openvpn_proxy_enabled() -> bool:
    """Check if OpenVPN outbound should use SOCKS proxy (default: False)."""
    val = os.environ.get("OPENVPN_USE_PROXY", "false").strip().lower()
    return val in ("true", "1", "yes", "on")

def process_ovpn_content(content: str, use_proxy: bool = None) -> str:
    """Transform .ovpn content to meet requirements: no route modification, optional SOCKS proxy routing."""
    if use_proxy is None:
        use_proxy = is_openvpn_proxy_enabled()

    lines = content.splitlines()
    processed_lines = []

    socks_listen = os.environ.get("SOCKS_INBOUND_LISTEN", "127.0.0.1")
    socks_port = os.environ.get("SOCKS_INBOUND_PORT", "1080")

    has_socks_proxy = False
    has_socks_retry = False
    has_route_nopull = False
    has_dev = False
    has_nobind = False
    has_auth_user_pass = False

    for line in lines:
        stripped = line.strip()

        # Comment out redirect-gateway to strictly prevent overriding default routing
        if stripped.startswith("redirect-gateway"):
            logger.info("Disabling directive: %s (to protect system routing table)", stripped)
            processed_lines.append(f"# [Modified] {line}")
            continue

        # Proxy directives handling (socks-proxy / http-proxy)
        if (
            stripped.startswith("socks-proxy")
            or stripped.startswith("http-proxy")
            or stripped.startswith("http-proxy-")
        ):
            if use_proxy:
                if stripped.startswith("socks-proxy-retry") or stripped.startswith("http-proxy-retry"):
                    has_socks_retry = True
                    processed_lines.append(line)
                elif stripped.startswith("socks-proxy") and not stripped.startswith("socks-proxy-"):
                    has_socks_proxy = True
                    processed_lines.append(f"socks-proxy {socks_listen} {socks_port}")
                else:
                    processed_lines.append(line)
            else:
                logger.info("Removing proxy directive (OPENVPN_USE_PROXY is disabled): %s", stripped)
            continue

        # Check route-nopull
        if stripped.startswith("route-nopull"):
            has_route_nopull = True
            processed_lines.append(line)
            continue

        # Check dev tun
        if stripped.startswith("dev ") or stripped == "dev":
            has_dev = True
            processed_lines.append("dev tun0")
            continue

        if stripped.startswith("nobind"):
            has_nobind = True
            processed_lines.append(line)
            continue

        if stripped.startswith("auth-user-pass"):
            has_auth_user_pass = True
            processed_lines.append(f"auth-user-pass {AUTH_FILE_PATH}")
            continue

        processed_lines.append(line)

    # Append mandatory directives if not present
    injected_header = [
        "",
        "# ===== Injected by vpngate-singbox-openvpn =====",
    ]

    if not has_route_nopull:
        injected_header.append("route-nopull")
        logger.info("Injected: route-nopull (OpenVPN will not modify default routing table)")

    if use_proxy:
        if not has_socks_proxy:
            injected_header.append(f"socks-proxy {socks_listen} {socks_port}")
            logger.info("Injected: socks-proxy %s %s (outbound via Sing-box SOCKS inbound)", socks_listen, socks_port)

        if not has_socks_retry:
            injected_header.append("socks-proxy-retry")
    else:
        logger.info("OpenVPN outbound direct connection mode (OPENVPN_USE_PROXY=false).")

    if not has_dev:
        injected_header.append("dev tun0")

    if not has_nobind:
        injected_header.append("nobind")

    auth_path = get_auth_file_path()
    if os.path.exists(auth_path) and not has_auth_user_pass:
        injected_header.append(f"auth-user-pass {auth_path}")

    injected_header.extend([
        "persist-key",
        "persist-tun",
        "ping 10",
        "ping-restart 60",
        "verb 3",
        "# ===============================================",
        ""
    ])

    return "\n".join(processed_lines + injected_header)

def process_file(input_path: str = None, output_path: str = None, use_proxy: bool = None) -> bool:
    """Read input .ovpn, process directives, and write to output path."""
    input_path = input_path or get_client_ovpn_path()
    output_path = output_path or get_run_ovpn_path()

    if not os.path.exists(input_path):
        logger.error("Input OpenVPN configuration not found: %s", input_path)
        return False

    ensure_auth_file()

    with open(input_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    if not content.strip():
        logger.error("OpenVPN configuration file %s is empty!", input_path)
        return False

    processed_content = process_ovpn_content(content, use_proxy=use_proxy)

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(processed_content)

    logger.info("Successfully generated runtime OpenVPN configuration: %s", output_path)
    return True

def main():
    if not os.path.exists(CLIENT_OVPN_PATH):
        logger.warning("Primary .ovpn config not found at %s. Waiting for downloader/entrypoint...", CLIENT_OVPN_PATH)
        sys.exit(1)

    success = process_file(CLIENT_OVPN_PATH, RUN_OVPN_PATH)
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
