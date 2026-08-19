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


def normalize_push_url(url: str) -> str:
    """
    Normalizes Cloudflare Worker endpoint URL.
    Supports all formats:
    - worker.dev
    - https://worker.dev
    - https://worker.dev/
    - https://worker.dev/upstream
    - https://worker.dev/api/upstream
    - https://worker.dev/proxy
    - https://worker.dev/api/proxy
    """
    if not url:
        return ""
    url = url.strip().rstrip("/")
    if not url.startswith("http://") and not url.startswith("https://"):
        url = "https://" + url

    if url.endswith("/api/upstream") or url.endswith("/api/proxy"):
        return url
    elif url.endswith("/upstream"):
        return url[:-len("/upstream")] + "/api/upstream"
    elif url.endswith("/proxy"):
        return url[:-len("/proxy")] + "/api/upstream"
    else:
        return url + "/api/upstream"


def get_default_config_path(base_dir: str) -> str:
    """Returns default path for cf_push_config.json."""
    return os.path.join(base_dir, "cf_push_config.json")


def load_push_config(config_path: Optional[str] = None, base_dir: str = ".") -> Dict[str, str]:
    """
    Loads push configuration from:
    1. Specified config_path
    2. cf_push_config.json in base_dir or base_dir/results
    3. Environment variables (CF_VLESS_PUSH_URL, CF_VLESS_API_TOKEN)
    """
    config = {
        "push_url": os.environ.get("CF_VLESS_PUSH_URL", os.environ.get("CF_PUSH_URL", "")).strip(),
        "api_token": os.environ.get("CF_VLESS_API_TOKEN", os.environ.get("CF_PUSH_TOKEN", "")).strip(),
        "_source": "env" if (os.environ.get("CF_VLESS_PUSH_URL") or os.environ.get("CF_VLESS_API_TOKEN")) else "none"
    }

    target_paths = []
    if config_path:
        target_paths.append(config_path)
    if base_dir and base_dir != ".":
        target_paths.append(os.path.join(base_dir, "cf_push_config.json"))
        target_paths.append(os.path.join(base_dir, "results", "cf_push_config.json"))
    else:
        target_paths.append("cf_push_config.json")
        target_paths.append(os.path.join("results", "cf_push_config.json"))

    for path in target_paths:
        if os.path.exists(path):
            try:
                with open(path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                if not config["push_url"] and data.get("push_url"):
                    config["push_url"] = normalize_push_url(str(data["push_url"]).strip())
                    config["_source"] = path
                if not config["api_token"] and data.get("api_token"):
                    config["api_token"] = str(data["api_token"]).strip()
                    config["_source"] = path
                if config["push_url"] and config["api_token"]:
                    break
            except Exception as e:
                logger.debug(f"Failed to read push config from {path}: {e}")

    return config


def save_push_config(
    config_data: Dict[str, str],
    config_path: Optional[str] = None,
    base_dir: str = "."
) -> str:
    """
    Saves or updates push_url and api_token into cf_push_config.json.
    Returns the path of the saved configuration file.
    """
    target_path = config_path
    if not target_path:
        # Determine best location to save
        candidates = [
            os.path.join(base_dir, "cf_push_config.json"),
            os.path.join(base_dir, "results", "cf_push_config.json"),
        ]
        for c in candidates:
            if os.path.exists(c):
                target_path = c
                break
        if not target_path:
            if os.path.basename(os.path.abspath(base_dir)) == "results":
                target_path = os.path.join(base_dir, "cf_push_config.json")
            elif os.path.exists(os.path.join(base_dir, "results")):
                target_path = os.path.join(base_dir, "results", "cf_push_config.json")
            else:
                target_path = os.path.join(base_dir, "cf_push_config.json")

    os.makedirs(os.path.dirname(os.path.abspath(target_path)), exist_ok=True)

    existing = {}
    if os.path.exists(target_path):
        try:
            with open(target_path, "r", encoding="utf-8") as f:
                existing = json.load(f)
        except Exception:
            existing = {}

    if "push_url" in config_data and config_data["push_url"]:
        existing["push_url"] = normalize_push_url(config_data["push_url"])
    if "api_token" in config_data and config_data["api_token"]:
        existing["api_token"] = str(config_data["api_token"]).strip()

    existing["updated_at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    with open(target_path, "w", encoding="utf-8") as f:
        json.dump(existing, f, indent=2, ensure_ascii=False)

    logger.info(f"💾 [CF 推送配置已保存] 路径: {target_path}")
    return target_path


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
        timeout: float = 30.0,
        auto_save: bool = True
    ):
        self.state_dir = state_dir
        self.timeout = timeout
        os.makedirs(self.state_dir, exist_ok=True)
        self.state_file = os.path.join(self.state_dir, "cf_push_state.json")

        base_dir = self.state_dir
        loaded = load_push_config(config_path=config_path, base_dir=base_dir)
        self.push_url = normalize_push_url(push_url or loaded.get("push_url", ""))
        self.api_token = (api_token or loaded.get("api_token", "")).strip()

        # If user explicitly passed new url or token via CLI, auto-persist into config file
        if auto_save and (push_url or api_token):
            to_save = {}
            if push_url:
                to_save["push_url"] = self.push_url
            if api_token:
                to_save["api_token"] = self.api_token
            if to_save:
                save_push_config(to_save, config_path=config_path, base_dir=base_dir)

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
        Generates full .ovpn configuration text for the given BenchmarkResult or node dictionary.
        If node contains native OpenVPN config (Base64), decodes it; otherwise constructs standard .ovpn.
        """
        if isinstance(node, dict):
            b64 = node.get("ovpn_b64") or node.get("openvpn_config_b64", "")
            if b64:
                try:
                    decoded = base64.b64decode(b64).decode("utf-8", errors="ignore").strip()
                    if decoded and ("remote " in decoded or "client" in decoded):
                        return decoded
                except Exception:
                    pass

            ip = node.get("ip", "")
            port = node.get("port", 443)
            proto = str(node.get("proto", "tcp")).lower()
        else:
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
        force: bool = False,
        test_on_worker: bool = False
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

        if isinstance(best_node, dict):
            current_ip = best_node.get("ip", "")
            current_port = best_node.get("port", 443)
            current_score = float(best_node.get("composite_score", 0.0))
            current_country = best_node.get("country_short", "UN")
        else:
            server = getattr(best_node, "server", best_node)
            current_ip = getattr(server, "ip", "")
            current_port = getattr(best_node, "tested_port", getattr(server, "port", 443))
            current_score = float(getattr(best_node, "composite_score", 0.0))
            current_country = getattr(server, "country_short", "UN")

        current_node_key = f"{current_ip}:{current_port}"

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
            f"🚀 [CF 代理推送] 准备推送最优节点: "
            f"{current_node_key} ({current_country}, 评分: {current_score:.1f}) 至 {self.push_url} ..."
        )

        try:
            payload = json.dumps({
                "upstreamProxy": ovpn_content,
                "enableDirectFallback": True,
                "test": test_on_worker
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


def find_best_node_from_results(results_dir: str = "results") -> Optional[Dict[str, Any]]:
    """Searches results directories and returns the #1 highest composite score residential node."""
    candidate_dirs = [
        results_dir,
        os.path.abspath(results_dir),
        os.path.join(os.path.dirname(__file__), results_dir),
        "/usr/local/bin/vpngate-residential-selector/results",
        os.path.expanduser("~/.local/bin/vpngate-residential-selector/results"),
        "/root/vps-utils/vpngate-residential-selector/results",
        os.path.expanduser("~/vps-utils/vpngate-residential-selector/results"),
    ]

    all_nodes: List[Dict[str, Any]] = []

    for d in candidate_dirs:
        if not os.path.exists(d):
            continue

        pool_file = os.path.join(d, "residential_pool.json")
        nodes_file = os.path.join(d, "residential_nodes.json")

        if os.path.exists(pool_file):
            try:
                with open(pool_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                pools = data.get("pools", {})
                for c_nodes in pools.values():
                    for n in c_nodes:
                        all_nodes.append(n)
                if all_nodes:
                    break
            except Exception:
                pass

        if os.path.exists(nodes_file):
            try:
                with open(nodes_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                all_nodes = data.get("nodes", [])
                if all_nodes:
                    break
            except Exception:
                pass

    if not all_nodes:
        return None

    # Filter fraud_score < 20 and sort by composite score
    valid = [n for n in all_nodes if n.get("fraud_score", -1) < 20 or n.get("fraud_score", -1) < 0]
    if not valid:
        valid = all_nodes

    valid.sort(key=lambda x: (
        -float(x.get("composite_score", 0.0)),
        x.get("fraud_score", 999) if x.get("fraud_score", -1) >= 0 else 999,
        float(x.get("real_latency_ms", 999.0))
    ))

    return valid[0]


def main() -> int:
    """CLI Entrypoint for manual push and configuration management."""
    import argparse
    parser = argparse.ArgumentParser(
        description="VPNGATE 最优住宅代理手动推送到 Cloudflare VLESS 网关工具",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )

    parser.add_argument("--url", "-u", type=str, default="", help="Cloudflare REST API 推送端点 URL (支持纯域名，自动持久化保存至配置文件)")
    parser.add_argument("--token", "-t", type=str, default="", help="Cloudflare 专属 API Token (自动持久化保存至配置文件)")
    parser.add_argument("--config-only", action="store_true", help="仅保存配置到 cf_push_config.json，不立即发起网络推送")
    parser.add_argument("--show-config", action="store_true", help="查看当前生效的 Cloudflare 推送配置与配置文件路径")
    parser.add_argument("--force", "-f", action="store_true", default=True, help="强制推送 (即使与上次相同也立即推送)")
    parser.add_argument("--status", "-s", action="store_true", help="查看上次推送记录与状态")
    parser.add_argument("--output", "-o", type=str, default="results", help="结果文件目录")
    parser.add_argument("--test", action="store_true", default=False, help="要求 Cloudflare Worker 端在保存前同步进行握手连接测试 (默认关闭以实现秒级更新)")
    parser.add_argument("--verbose", "-v", action="store_true", help="打印详细调试日志")

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S"
    )

    # 1. 仅查看当前配置
    if args.show_config:
        loaded = load_push_config(base_dir=args.output)
        print("\n==================================================")
        print("  ⚙️ Cloudflare VLESS 代理推送当前生效配置")
        print("==================================================")
        print(f"• 推送端点 URL: {loaded.get('push_url') or '(未配置)'}")
        token = loaded.get('api_token') or ''
        masked_token = (token[:8] + '...' + token[-4:]) if len(token) > 12 else (token or '(未配置)')
        print(f"• API 专属 Token: {masked_token}")
        print(f"• 配置来源/路径: {loaded.get('_source', '未知')}")
        print("==================================================\n")
        return 0

    # 2. 如果传入了新 url 或 token，先保存配置
    if args.url or args.token:
        to_save = {}
        if args.url:
            to_save["push_url"] = args.url
        if args.token:
            to_save["api_token"] = args.token
        saved_path = save_push_config(to_save, base_dir=args.output)
        print(f"💾 [配置已持久化] 已成功更新配置并保存至: {saved_path}")
        if args.config_only:
            print("✅ 配置保存完成！\n")
            return 0

    pusher = CloudflareVlessPusher(
        push_url=args.url if args.url else None,
        api_token=args.token if args.token else None,
        state_dir=args.output,
        auto_save=True
    )

    # 3. 查看上次推送记录
    if args.status:
        state = pusher.get_last_pushed_state()
        print("\n==================================================")
        print("  📊 Cloudflare VLESS 代理推送历史状态记录")
        print("==================================================")
        if not state:
            print("ℹ️ 尚未发现任何历史推送记录。")
        else:
            print(f"• 上次推送节点: {state.get('node_key')} ({state.get('country')})")
            print(f"• 综合评分: {state.get('composite_score')}")
            print(f"• 推送时间: {state.get('pushed_at')}")
            print(f"• 目标地址: {state.get('push_url')}")
            print(f"• 网关响应: {json.dumps(state.get('response', {}), ensure_ascii=False)}")
        print("==================================================\n")
        return 0

    # 4. 校验配置是否完整
    if not pusher.is_configured():
        print("\n❌ 错误: 未配置 Cloudflare 推送 URL 或 API Token！")
        print("👉 请通过命令设置 (将自动保存到配置文件，后续无需再次输入):")
        print("   vpngate-push --url \"https://<你的Worker域名>/api/upstream\" --token \"<专属Token>\"")
        print("👉 或设置环境变量:")
        print("   export CF_VLESS_PUSH_URL=\"https://<你的Worker域名>/api/upstream\"")
        print("   export CF_VLESS_API_TOKEN=\"<专属Token>\"\n")
        return 1

    best = find_best_node_from_results(args.output)
    if not best:
        print("\n❌ 未在本地发现任何已保存的住宅节点记录！")
        print("👉 请先运行 'vpngate-selector' 执行一次测速优选后再推送。\n")
        return 1

    print("\n==================================================")
    print("  🚀 正在手动推送最优住宅代理至 Cloudflare 网关...")
    print("==================================================")
    print(f"• 目标节点: {best.get('ip')}:{best.get('port')} ({best.get('country_short', 'UN')})")
    print(f"• 实测延迟: {best.get('real_latency_ms', 0.0):.2f} ms | 综合得分: {best.get('composite_score', 0.0):.1f}")
    print(f"• 推送接口: {pusher.push_url}")
    print("--------------------------------------------------")

    res = pusher.push_best_node_if_changed(best, force=args.force, test_on_worker=args.test)

    if res.get("status") == "success":
        print("\n🎉 ✅ 推送成功！Cloudflare Worker 网关已即时更新并持久化至 KV！")
        print(f"• 响应详情: {json.dumps(res.get('response', {}), indent=2, ensure_ascii=False)}\n")
        return 0
    elif res.get("status") == "skipped":
        print(f"\nℹ️ 节点未发生变化，已跳过推送 (上次推送时间: {res.get('last_pushed_at')})。")
        print("💡 如需强制推送，请添加 -f / --force 参数。\n")
        return 0
    else:
        print(f"\n❌ 推送失败: {res}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())

