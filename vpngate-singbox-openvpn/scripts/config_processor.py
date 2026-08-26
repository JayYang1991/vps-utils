#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Sing-box Configuration Processor
- Fetches subscription configuration from URL or local cache
- Injects SOCKS inbound rule
- Routes SOCKS inbound traffic to the urltest outbound group
- Validates and saves the final configuration file
"""

import os
import sys
import json
import base64
import logging
import subprocess
import urllib.parse
import requests

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] [ConfigProcessor] %(message)s'
)
logger = logging.getLogger("config_processor")

CONFIG_DIR = os.environ.get("CONFIG_DIR", "/config")
RAW_CONFIG_CACHE = os.path.join(CONFIG_DIR, "singbox_subscription.raw.json")
RUN_CONFIG_PATH = os.path.join(CONFIG_DIR, "singbox_run.json")

def load_env_file(env_path):
    """Load key=value environment file if exists."""
    if not os.path.exists(env_path):
        return
    with open(env_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, val = line.split("=", 1)
                key = key.strip()
                val = val.strip().strip("'\"")
                if key not in os.environ:
                    os.environ[key] = val

def get_socks_proxy_url() -> str:
    """Get Sing-box local SOCKS inbound proxy URL (socks5h for remote DNS resolution)."""
    socks_listen = os.environ.get("SOCKS_INBOUND_LISTEN", "127.0.0.1")
    socks_port = os.environ.get("SOCKS_INBOUND_PORT", "1080")
    return f"socks5h://{socks_listen}:{socks_port}"

def fetch_remote_url(url: str, headers: dict = None, proxy_url: str = None, timeout: int = 30) -> str:
    """
    Fetch remote URL content with SOCKS proxy support and automatic fallback.
    - If proxy_url is specified (e.g. socks5h://127.0.0.1:1080):
      - Bypasses proxy for localhost/127.0.0.1.
      - Attempts proxy fetch via requests (or curl fallback if PySocks is missing).
      - If proxy connection fails, attempts direct connection fallback.
    """
    if not url:
        raise ValueError("URL cannot be empty")

    headers = headers or {}
    parsed = urllib.parse.urlparse(url)
    is_localhost = parsed.hostname in ("127.0.0.1", "localhost", "::1")

    active_proxy = None if is_localhost else proxy_url

    if active_proxy:
        logger.info("Fetching %s via Sing-box SOCKS proxy (%s)...", url, active_proxy)
        try:
            resp = requests.get(url, headers=headers, proxies={"http": active_proxy, "https": active_proxy}, timeout=timeout)
            resp.raise_for_status()
            return resp.text.strip()
        except Exception as req_err:
            # Check if PySocks missing error occurred
            is_socks_schema_err = "socks" in str(req_err).lower() or "missing dependencies" in str(req_err).lower()
            if is_socks_schema_err:
                logger.debug("Requests missing PySocks, attempting curl fallback for SOCKS proxy fetch...")
                proxy_host_port = active_proxy.replace("socks5h://", "").replace("socks5://", "")
                cmd = ["curl", "-s", "-L", "--max-time", str(timeout), "--socks5-hostname", proxy_host_port]
                for k, v in headers.items():
                    cmd.extend(["-H", f"{k}: {v}"])
                cmd.append(url)
                try:
                    res = subprocess.run(cmd, capture_output=True, text=True, check=True)
                    if res.stdout.strip():
                        return res.stdout.strip()
                except Exception as curl_err:
                    logger.warning("Curl proxy fetch failed: %s", curl_err)

            logger.warning("Failed to fetch %s via SOCKS proxy (%s): %s", url, active_proxy, req_err)
            logger.info("Attempting direct connection fallback to %s ...", url)

    # Direct connection (either no proxy specified, localhost, or fallback)
    try:
        resp = requests.get(url, headers=headers, timeout=timeout)
        resp.raise_for_status()
        return resp.text.strip()
    except Exception as direct_err:
        logger.error("Direct fetch failed for %s: %s", url, direct_err)
        raise

def fetch_subscription(sub_url: str, use_proxy: bool = True) -> dict:
    """Fetch Sing-box subscription configuration from URL via socks-in proxy."""
    if not sub_url:
        logger.warning("SINGBOX_SUBSCRIPTION_URL is not set.")
        if os.path.exists(RAW_CONFIG_CACHE):
            logger.info("Using cached raw configuration from %s", RAW_CONFIG_CACHE)
            with open(RAW_CONFIG_CACHE, "r", encoding="utf-8") as f:
                return json.load(f)
        raise ValueError("No subscription URL provided and no cache file available.")

    headers = {
        "User-Agent": "sing-box/1.12.20 (vpngate-residential-tools)"
    }
    proxy_url = get_socks_proxy_url() if use_proxy else None

    try:
        raw_text = fetch_remote_url(sub_url, headers=headers, proxy_url=proxy_url, timeout=30)
    except Exception as e:
        logger.error("Failed to fetch subscription from remote URL: %s", e)
        if os.path.exists(RAW_CONFIG_CACHE):
            logger.info("Falling back to local cache: %s", RAW_CONFIG_CACHE)
            with open(RAW_CONFIG_CACHE, "r", encoding="utf-8") as f:
                return json.load(f)
        raise

    # Try parsing directly as JSON
    try:
        config_data = json.loads(raw_text)
    except json.JSONDecodeError:
        # Try base64 decoding
        try:
            decoded = base64.b64decode(raw_text).decode("utf-8")
            config_data = json.loads(decoded)
        except Exception as b64_err:
            raise ValueError(f"Subscription content is neither valid JSON nor valid Base64 JSON: {b64_err}")

    # Cache raw config
    try:
        with open(RAW_CONFIG_CACHE, "w", encoding="utf-8") as f:
            json.dump(config_data, f, indent=2, ensure_ascii=False)
        logger.info("Raw subscription cached to %s", RAW_CONFIG_CACHE)
    except Exception as e:
        logger.warning("Could not write cache file: %s", e)

    return config_data

def find_target_outbound_tag(config: dict, custom_target: str = "") -> str:
    """Find the tag of the urltest outbound group or suitable proxy group."""
    outbounds = config.get("outbounds", [])
    if not outbounds:
        logger.warning("No outbounds found in configuration, defaulting to 'direct'")
        return "direct"

    # 1. Custom specified target tag
    if custom_target:
        for ob in outbounds:
            if ob.get("tag") == custom_target:
                logger.info("Found user-specified outbound tag: %s", custom_target)
                return custom_target
        logger.warning("Specified TARGET_URLTEST_TAG '%s' not found in outbounds, auto-detecting...", custom_target)

    # 2. Look for type == "urltest"
    for ob in outbounds:
        if ob.get("type") == "urltest":
            tag = ob.get("tag")
            logger.info("Auto-detected 'urltest' outbound group tag: %s", tag)
            return tag

    # 3. Look for type == "selector"
    for ob in outbounds:
        if ob.get("type") == "selector":
            tag = ob.get("tag")
            logger.info("Auto-detected 'selector' outbound group tag: %s", tag)
            return tag

    # 4. Fallback to first non-direct outbound
    for ob in outbounds:
        if ob.get("type") not in ("direct", "block", "dns"):
            tag = ob.get("tag")
            logger.info("Fallback to first available outbound tag: %s (%s)", tag, ob.get("type"))
            return tag

    first_tag = outbounds[0].get("tag", "direct")
    logger.info("Fallback to first outbound tag: %s", first_tag)
    return first_tag

def save_as_raw_cache(src_path: str = None, dst_path: str = None) -> bool:
    """Save the successfully generated and running singbox_run.json as singbox_subscription.raw.json cache."""
    src = src_path or RUN_CONFIG_PATH
    dst = dst_path or RAW_CONFIG_CACHE
    try:
        if not os.path.exists(src):
            logger.warning("Source configuration does not exist: %s", src)
            return False
        with open(src, "r", encoding="utf-8") as f:
            data = json.load(f)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        logger.info("Saved latest successful configuration from %s to %s", src, dst)
        return True
    except Exception as e:
        logger.warning("Could not save %s as %s: %s", src, dst, e)
        return False

def process_config(raw_config: dict) -> dict:
    """Inject SOCKS inbound and route rules to the target urltest group."""
    config = json.loads(json.dumps(raw_config)) # deep copy

    # 1. 在最开始删除掉所有路由规则和 rule_set 配置
    if "route" not in config or not isinstance(config["route"], dict):
        config["route"] = {}
    config["route"]["rules"] = []
    if "rule_set" in config["route"]:
        del config["route"]["rule_set"]
    if "rule_set" in config:
        del config["rule_set"]

    # 2. 删除 TUN 相关配置 (如 inbounds 中的 tun 网卡、outbounds 中的 tun、以及 route 中的 tun 字段)
    if "inbounds" in config and isinstance(config["inbounds"], list):
        config["inbounds"] = [
            ib for ib in config["inbounds"]
            if isinstance(ib, dict) and ib.get("type") != "tun"
        ]
    if "outbounds" in config and isinstance(config["outbounds"], list):
        config["outbounds"] = [
            ob for ob in config["outbounds"]
            if isinstance(ob, dict) and ob.get("type") != "tun"
        ]
    for key in ("auto_detect_interface", "default_interface", "default_mark", "override_android_vpn"):
        if key in config.get("route", {}):
            del config["route"][key]

    # 3. 删除 Fake-IP 相关配置 (如 dns.servers 中的 fakeip、dns.fakeip、以及引用 fakeip 的 dns 规则)
    if "dns" in config and isinstance(config["dns"], dict):
        if "fakeip" in config["dns"]:
            del config["dns"]["fakeip"]
        if "servers" in config["dns"] and isinstance(config["dns"]["servers"], list):
            config["dns"]["servers"] = [
                s for s in config["dns"]["servers"]
                if isinstance(s, dict) and s.get("type") != "fakeip" and s.get("server") != "fakeip" and "fakeip" not in s.get("tag", "").lower()
            ]
        if "rules" in config["dns"] and isinstance(config["dns"]["rules"], list):
            config["dns"]["rules"] = [
                r for r in config["dns"]["rules"]
                if isinstance(r, dict)
                and "rule_set" not in r
                and "fakeip" not in str(r.get("server", "")).lower()
                and r.get("type") != "fakeip"
            ]

    # 清理 experimental 中 store_fakeip 配置
    if "experimental" in config and isinstance(config["experimental"], dict):
        if "cache_file" in config["experimental"] and isinstance(config["experimental"]["cache_file"], dict):
            if "store_fakeip" in config["experimental"]["cache_file"]:
                del config["experimental"]["cache_file"]["store_fakeip"]

    socks_tag = os.environ.get("SOCKS_INBOUND_TAG", "socks-in")
    socks_listen = os.environ.get("SOCKS_INBOUND_LISTEN", "127.0.0.1")
    socks_port = int(os.environ.get("SOCKS_INBOUND_PORT", "1080"))
    public_socks_port = int(os.environ.get("PUBLIC_SOCKS_PORT", "2080"))
    public_socks_tag = os.environ.get("PUBLIC_SOCKS_TAG", "public-socks-in")
    target_tag_override = os.environ.get("TARGET_URLTEST_TAG", "").strip()
    mixed_port = int(os.environ.get("MIXED_INBOUND_PORT", "0"))

    # Determine urltest / target outbound tag
    target_tag = find_target_outbound_tag(config, target_tag_override)
    logger.info("Target outbound group for OpenVPN SOCKS traffic: %s", target_tag)

    # Ensure inbounds list exists
    if "inbounds" not in config or not isinstance(config["inbounds"], list):
        config["inbounds"] = []

    # Remove previous injected inbound tags if present
    config["inbounds"] = [
        ib for ib in config["inbounds"]
        if ib.get("tag") not in (socks_tag, public_socks_tag, "mixed-in")
    ]

    # 1. 内部专用 SOCKS 入站 (端口 1080，供容器内 OpenVPN 专用出站，监听 127.0.0.1)
    socks_inbound = {
        "type": "socks",
        "tag": socks_tag,
        "listen": socks_listen,
        "listen_port": socks_port,
        "sniff": True
    }
    config["inbounds"].insert(0, socks_inbound)
    logger.info("Injected [1/2] Internal SOCKS inbound: %s:%d (tag: %s) -> for OpenVPN", socks_listen, socks_port, socks_tag)

    # 2. 外部公开 SOCKS 入站 (端口 2080，映射至宿主机供外部/主机使用，监听 0.0.0.0)
    public_inbound = {
        "type": "socks",
        "tag": public_socks_tag,
        "listen": "0.0.0.0",
        "listen_port": public_socks_port,
        "sniff": True
    }
    config["inbounds"].insert(1, public_inbound)
    logger.info("Injected [2/2] Public SOCKS inbound: 0.0.0.0:%d (tag: %s) -> for Host Mapping", public_socks_port, public_socks_tag)

    # Optionally inject mixed inbound if configured
    if mixed_port > 0:
        mixed_inbound = {
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "0.0.0.0",
            "listen_port": mixed_port,
            "sniff": True
        }
        config["inbounds"].append(mixed_inbound)
        logger.info("Injected Mixed HTTP/SOCKS inbound on 0.0.0.0:%d", mixed_port)

    # Ensure outbounds list exists
    if "outbounds" not in config or not isinstance(config["outbounds"], list):
        config["outbounds"] = []

    openvpn_out_tag = os.environ.get("OPENVPN_OUTBOUND_TAG", "openvpn-out")
    tun_interface = os.environ.get("OPENVPN_TUN_INTERFACE", "tun0")

    # Remove existing openvpn-out if present
    config["outbounds"] = [
        ob for ob in config["outbounds"]
        if ob.get("tag") != openvpn_out_tag
    ]

    # Inject openvpn-out direct outbound bound to tun0 with domain_resolver -> dns-remote
    openvpn_outbound = {
        "type": "direct",
        "tag": openvpn_out_tag,
        "bind_interface": tun_interface,
        "domain_resolver": "dns-remote"
    }
    config["outbounds"].append(openvpn_outbound)
    logger.info("Injected OpenVPN TUN direct outbound: tag=%s, bind_interface=%s, domain_resolver=dns-remote", openvpn_out_tag, tun_interface)

    # Ensure DNS configuration routes remote queries through openvpn-out (tun0)
    if "dns" not in config or not isinstance(config["dns"], dict):
        config["dns"] = {}
    if "servers" not in config["dns"] or not isinstance(config["dns"]["servers"], list):
        config["dns"]["servers"] = []

    # 1. 确保存在 dns-direct (用于启动引导与国内域名，走本地 eth0 直连)
    has_direct_dns = any(s.get("tag") == "dns-direct" for s in config["dns"]["servers"])
    if not has_direct_dns:
        config["dns"]["servers"].insert(0, {
            "tag": "dns-direct",
            "type": "udp",
            "server": "223.5.5.5"
        })

    # 2. 将 dns-remote 的 detour 设置为 openvpn-out (经由 tun0 网卡查询无污染 DNS)
    config["dns"]["servers"] = [
        s for s in config["dns"]["servers"]
        if s.get("tag") != "dns-remote"
    ]
    dns_remote_server = {
        "tag": "dns-remote",
        "type": "udp",
        "server": "8.8.8.8",
        "detour": openvpn_out_tag
    }
    config["dns"]["servers"].append(dns_remote_server)
    logger.info("Configured clean DNS server [dns-remote: 8.8.8.8] detour -> %s (tun0)", openvpn_out_tag)

    # 3. 提取所有节点服务器域名，确保启动引导解析直连 dns-direct (防止 chicken-and-egg 死锁)
    bootstrap_domains = set()
    for ob in config.get("outbounds", []):
        if ob.get("server") and not ob.get("server", "").replace(".", "").isdigit():
            bootstrap_domains.add(ob.get("server"))

    if bootstrap_domains:
        config["dns"]["rules"] = [
            r for r in config["dns"].get("rules", [])
            if not any(d in r.get("domain", []) for d in bootstrap_domains)
        ]
        config["dns"]["rules"].insert(0, {
            "domain": sorted(list(bootstrap_domains)),
            "server": "dns-direct"
        })
        logger.info("Whitelisted bootstrap domains to dns-direct: %s", sorted(list(bootstrap_domains)))

    # 4. 配置默认兜底与路由解析器
    config["dns"]["final"] = "dns-remote"
    config["route"]["default_domain_resolver"] = "dns-direct"
    logger.info("Configured default_domain_resolver -> dns-direct, openvpn-out.domain_resolver -> dns-remote (tun0)")

    # 5. 生成纯净路由规则
    # 1. socks-in (1080) -> 路由至 urltest 出站组 (OpenVPN 借此优选节点建立隧道)
    # 2. public-socks-in (2080) -> 路由至 openvpn-out 出站 (经由 OpenVPN tun0 网卡隧道出站)
    rules_to_insert = [
        {"inbound": [socks_tag], "outbound": target_tag},
        {"inbound": [public_socks_tag], "outbound": openvpn_out_tag}
    ]
    if mixed_port > 0:
        rules_to_insert.append({"inbound": ["mixed-in"], "outbound": openvpn_out_tag})

    config["route"]["rules"] = rules_to_insert

    # Ensure log level is reasonable
    if "log" not in config:
        config["log"] = {
            "level": "info",
            "timestamp": True
        }

    return config

def validate_and_save(config: dict, output_file: str = RUN_CONFIG_PATH) -> bool:
    """Save configuration to disk and check syntax using sing-box binary."""
    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    with open(output_file, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)

    logger.info("Saved runtime configuration to %s", output_file)

    # Test configuration with sing-box check
    try:
        res = subprocess.run(
            ["sing-box", "check", "-c", output_file],
            capture_output=True,
            text=True,
            check=True
        )
        logger.info("Sing-box configuration check passed successfully.")
        return True
    except subprocess.CalledProcessError as e:
        logger.error("Sing-box configuration check failed:\nSTDOUT:\n%s\nSTDERR:\n%s", e.stdout, e.stderr)
        return False
    except FileNotFoundError:
        logger.warning("sing-box binary not found in PATH; skipping check.")
        return True

def generate_default_fallback_config() -> dict:
    """Generate a minimal fallback config with dual socks inbounds and tun DNS if subscription is not reachable at first start."""
    socks_port = int(os.environ.get("SOCKS_INBOUND_PORT", "1080"))
    public_port = int(os.environ.get("PUBLIC_SOCKS_PORT", "2080"))
    openvpn_out_tag = os.environ.get("OPENVPN_OUTBOUND_TAG", "openvpn-out")
    tun_interface = os.environ.get("OPENVPN_TUN_INTERFACE", "tun0")
    return {
        "log": {"level": "info", "timestamp": True},
        "dns": {
            "servers": [
                {
                    "tag": "dns-direct",
                    "type": "udp",
                    "server": "223.5.5.5"
                },
                {
                    "tag": "dns-remote",
                    "type": "udp",
                    "server": "8.8.8.8",
                    "detour": openvpn_out_tag
                }
            ],
            "rules": [],
            "final": "dns-remote"
        },
        "inbounds": [
            {
                "type": "socks",
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "listen_port": socks_port,
                "sniff": True
            },
            {
                "type": "socks",
                "tag": "public-socks-in",
                "listen": "0.0.0.0",
                "listen_port": public_port,
                "sniff": True
            }
        ],
        "outbounds": [
            {
                "type": "direct",
                "tag": "direct"
            },
            {
                "type": "direct",
                "tag": openvpn_out_tag,
                "bind_interface": tun_interface
            }
        ],
        "route": {
            "default_domain_resolver": "dns-remote",
            "rules": [
                {
                    "inbound": ["socks-in"],
                    "outbound": "direct"
                },
                {
                    "inbound": ["public-socks-in"],
                    "outbound": openvpn_out_tag
                }
            ]
        }
    }

def main(use_proxy: bool = True):
    env_file = os.path.join(CONFIG_DIR, "config.env")
    load_env_file(env_file)

    sub_url = os.environ.get("SINGBOX_SUBSCRIPTION_URL", "").strip()

    try:
        if sub_url or os.path.exists(RAW_CONFIG_CACHE):
            raw_cfg = fetch_subscription(sub_url, use_proxy=use_proxy)
            processed = process_config(raw_cfg)
        else:
            logger.warning("SINGBOX_SUBSCRIPTION_URL is empty and no cache found. Generating minimal fallback config.")
            processed = generate_default_fallback_config()
            
        success = validate_and_save(processed, RUN_CONFIG_PATH)
        if not success:
            sys.exit(1)
        logger.info("Config processor completed successfully.")
    except Exception as e:
        logger.exception("Error processing Sing-box configuration: %s", e)
        sys.exit(1)

if __name__ == "__main__":
    main()
