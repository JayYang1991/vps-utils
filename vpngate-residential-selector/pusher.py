#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VPNGATE to Cloudflare VLESS Proxy Automatic Pusher
Generates OpenVPN (.ovpn) configuration for the TOP 1 residential proxy node
and pushes it to the Cloudflare Worker REST API endpoint (/api/upstream)
with dedicated API Token authentication and change-detection logic.
"""

import os
import sys
import json
import base64
import logging
import urllib.request
import urllib.error
from typing import Optional, Dict, Any
from datetime import datetime

logger = logging.getLogger("vpngate.pusher")


def get_default_config_path(base_dir: str) -> str:
    """Returns default path for cf_push_config.json."""
    return os.path.join(base_dir, "cf_push_config.json")


def load_push_config(config_path: Optional[str] = None, base_dir: str = ".") -> Dict[str, str]:
    """
    Loads push configuration from:
    1. Specified config_path
    2. cf_push_config.json in base_dir
    3. Environment variables (CF_VLESS_PUSH_URL, CF_VLESS_API_TOKEN)
    """
    config = {
        "push_url": os.environ.get("CF_VLESS_PUSH_URL", os.environ.get("CF_PUSH_URL", "")).strip(),
        "api_token": os.environ.get("CF_VLESS_API_TOKEN", os.environ.get("CF_PUSH_TOKEN", "")).strip(),
    }

    target_paths = []
    if config_path:
        target_paths.append(config_path)
    target_paths.append(get_default_config_path(base_dir))
    target_paths.append(os.path.join(base_dir, "results", "cf_push_config.json"))

    for path in target_paths:
        if os.path.exists(path):
            try:
                with open(path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                if not config["push_url"] and data.get("push_url"):
                    config["push_url"] = str(data["push_url"]).strip()
                if not config["api_token"] and data.get("api_token"):
                    config["api_token"] = str(data["api_token"]).strip()
                break
            except Exception as e:
                logger.debug(f"Failed to read push config from {path}: {e}")

    return config


class CloudflareVlessPusher:
    """
    Handles automatic pushing of the optimal residential proxy (.ovpn) to Cloudflare VLESS Worker.
    Ensures that pushing only occurs when the optimal node has changed compared to the last push.
    """

    def __init__(
        self,
        push_url: Optional[str] = None,
        api_token: Optional[str] = None,
        state_dir: str = "results",
        config_path: Optional[str] = None,
        timeout: float = 15.0
    ):
        self.state_dir = state_dir
        self.timeout = timeout
        os.makedirs(self.state_dir, exist_ok=True)
        self.state_file = os.path.join(self.state_dir, "cf_push_state.json")

        loaded = load_push_config(config_path=config_path, base_dir=os.path.dirname(self.state_dir) or ".")
        self.push_url = (push_url or loaded["push_url"]).strip()
        self.api_token = (api_token or loaded["api_token"]).strip()

        # Normalize push_url: ensure it points to /api/upstream if root worker domain is given
        if self.push_url and not self.push_url.endswith("/api/upstream") and not self.push_url.endswith("/api/proxy"):
            if self.push_url.endswith("/"):
                self.push_url = self.push_url + "api/upstream"
            else:
                self.push_url = self.push_url + "/api/upstream"

    def is_configured(self) -> bool:
        """Checks if both push_url and api_token are configured."""
        return bool(self.push_url and self.api_token)

    def get_last_pushed_state(self) -> Optional[Dict[str, Any]]:
        """Reads last pushed state from JSON file."""
        if not os.path.exists(self.state_file):
            return None
        try:
            with open(self.state_file, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            logger.debug(f"Failed to read push state from {self.state_file}: {e}")
            return None

    def save_last_pushed_state(self, state: Dict[str, Any]) -> None:
        """Saves last pushed state to JSON file."""
        try:
            with open(self.state_file, "w", encoding="utf-8") as f:
                json.dump(state, f, indent=2, ensure_ascii=False)
        except Exception as e:
            logger.warning(f"Failed to write push state to {self.state_file}: {e}")

    def generate_ovpn_content(self, node: Any) -> str:
        """
        Generates full .ovpn configuration text for the given BenchmarkResult node.
        If node contains native OpenVPN config (Base64), decodes it; otherwise constructs standard .ovpn.
        """
        server = getattr(node, "server", node)
        b64 = getattr(server, "openvpn_config_b64", "")
        if b64:
            try:
                decoded = base64.b64decode(b64).decode("utf-8", errors="ignore").strip()
                if decoded and ("remote " in decoded or "client" in decoded):
                    return decoded
            except Exception:
                pass

        ip = getattr(server, "ip", "")
        port = getattr(node, "tested_port", getattr(server, "port", 443))
        proto = getattr(server, "proto", "tcp").lower()

        ovpn_lines = [
            "client",
            "dev tun",
            f"proto {proto}",
            f"remote {ip} {port}",
            "resolv-retry infinite",
            "nobind",
            "persist-key",
            "persist-tun",
            "auth-user-pass",
            "verb 2",
            "cipher AES-128-CBC",
            "auth SHA1",
        ]
        return "\n".join(ovpn_lines) + "\n"

    def push_best_node_if_changed(
        self,
        best_node: Any,
        force: bool = False
    ) -> Dict[str, Any]:
        """
        Evaluates the optimal node. If changed compared to previous push, generates .ovpn and pushes to Cloudflare.
        
        Constraint:
        - Only pushes when current optimal node (IP:Port) is different from the last pushed node, or if force is True.
        """
        if not self.is_configured():
            logger.debug("Cloudflare VLESS push endpoint or API token not configured. Skipping automatic push.")
            return {"status": "unconfigured", "message": "Push URL or API Token not configured"}

        if not best_node:
            return {"status": "error", "message": "No valid optimal node provided"}

        server = getattr(best_node, "server", best_node)
        current_ip = getattr(server, "ip", "")
        current_port = getattr(best_node, "tested_port", getattr(server, "port", 443))
        current_node_key = f"{current_ip}:{current_port}"
        current_score = getattr(best_node, "composite_score", 0.0)
        current_country = getattr(server, "country_short", "UN")

        # 1. Generate full .ovpn content and save to results/best_upstream.ovpn
        ovpn_content = self.generate_ovpn_content(best_node)
        best_ovpn_path = os.path.join(self.state_dir, "best_upstream.ovpn")
        try:
            with open(best_ovpn_path, "w", encoding="utf-8") as f:
                f.write(ovpn_content)
        except Exception as e:
            logger.debug(f"Failed to save best_upstream.ovpn: {e}")

        # 2. Check if node is unchanged
        last_state = self.get_last_pushed_state()
        if last_state and not force:
            last_key = last_state.get("node_key") or f"{last_state.get('ip')}:{last_state.get('port')}"
            if last_key == current_node_key:
                logger.info(
                    f"ℹ️ [CF 代理推送] 当前最优节点 ({current_node_key} | {current_country}) 与上次推送节点一致，"
                    f"跳过网络推送保持不变。"
                )
                return {
                    "status": "skipped",
                    "reason": "unchanged",
                    "node_key": current_node_key,
                    "last_pushed_at": last_state.get("pushed_at")
                }

        # 3. Node has changed or first push -> Execute HTTP Push
        logger.info(
            f"🚀 [CF 代理推送] 检测到最优节点发生轮换/更新 -> 准备推送新节点: "
            f"{current_node_key} ({current_country}, 评分: {current_score:.1f}) 至 {self.push_url} ..."
        )

        try:
            payload = json.dumps({
                "upstreamProxy": ovpn_content,
                "enableDirectFallback": True,
                "test": True
            }).encode("utf-8")

            req = urllib.request.Request(
                self.push_url,
                data=payload,
                headers={
                    "Authorization": f"Bearer {self.api_token}",
                    "Content-Type": "application/json; charset=utf-8",
                    "User-Agent": "VPNGATE-Residential-Selector-Pusher/1.0",
                },
                method="POST"
            )

            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                resp_code = resp.getcode()
                raw_body = resp.read().decode("utf-8", errors="ignore")
                try:
                    resp_json = json.loads(raw_body)
                except Exception:
                    resp_json = {"raw": raw_body}

                if resp_code in (200, 201):
                    timestamp_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                    new_state = {
                        "node_key": current_node_key,
                        "ip": current_ip,
                        "port": current_port,
                        "country": current_country,
                        "composite_score": current_score,
                        "pushed_at": timestamp_str,
                        "push_url": self.push_url,
                        "response": resp_json,
                    }
                    self.save_last_pushed_state(new_state)
                    logger.info(
                        f"✅ [CF 代理推送成功] 最优节点 {current_node_key} 已成功推送到 Cloudflare VLESS 网关！"
                    )
                    return {
                        "status": "success",
                        "node_key": current_node_key,
                        "pushed_at": timestamp_str,
                        "response": resp_json,
                    }
                else:
                    logger.error(f"❌ [CF 代理推送失败] 状态码: {resp_code}, 返回: {raw_body}")
                    return {"status": "error", "code": resp_code, "response": resp_json}

        except urllib.error.HTTPError as he:
            err_body = he.read().decode("utf-8", errors="ignore")
            logger.error(f"❌ [CF 代理推送 HTTP 错误] 状态码: {he.code}, 错误信息: {err_body}")
            return {"status": "http_error", "code": he.code, "error": err_body}
        except Exception as e:
            logger.error(f"❌ [CF 代理推送网络异常] 错误: {e}")
            return {"status": "network_error", "error": str(e)}
