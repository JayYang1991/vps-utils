import os
import re
import json
import yaml
import time
import base64
import logging
from logging.handlers import RotatingFileHandler
import urllib.parse
import urllib.request
import urllib.error
from cryptography.hazmat.primitives.asymmetric import x25519
from cryptography.hazmat.primitives import serialization

EDGETUNNEL_SUB_URL = "https://sub.19910417.xyz/sub?host={host}&uuid={uuid}"
SUBAPI_CONVERT_URL = "https://subapi.19910417.xyz/sub?target={target}&url={url}&filter_local=false"
REMOTE_SUBCONFIG_URL = "https://raw.githubusercontent.com/JayYang1991/edgetunnel/main/SUBCONFIG.json"
DEFAULT_CONFIG_URL = "https://raw.githubusercontent.com/JayYang1991/ACL4SSR/refs/heads/main/Clash/config/ACL4SSR_Online_Full_CF.ini"
DEFAULT_SINGBOX_CONFIG_URL = "https://raw.githubusercontent.com/JayYang1991/ACL4SSR/refs/heads/main/sing-box/singbox-template.ini"
DEFAULT_ENABLED_NODE_TYPES = ["preferred", "vps", "local"]
USER_AGENT = "v2rayN/edgetunnel (https://github.com/cmliu/edgetunnel)"

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "..", "data")
LOG_FILE = os.path.join(DATA_DIR, "app.log")
SETTINGS_FILE = os.path.join(DATA_DIR, "settings.json")

os.makedirs(DATA_DIR, exist_ok=True)

def get_server_settings() -> dict:
    """Get active server settings (config_url and enabled_node_types) from settings.json."""
    default_settings = {
        "config_url": DEFAULT_CONFIG_URL,
        "enabled_node_types": list(DEFAULT_ENABLED_NODE_TYPES)
    }
    if os.path.exists(SETTINGS_FILE):
        try:
            with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                return {
                    "config_url": data.get("config_url") or DEFAULT_CONFIG_URL,
                    "enabled_node_types": data.get("enabled_node_types") if isinstance(data.get("enabled_node_types"), list) else list(DEFAULT_ENABLED_NODE_TYPES)
                }
        except Exception as e:
            logger.error(f"Error reading settings.json: {e}")
    return default_settings

def get_server_config_url() -> str:
    """Get active default Clash config_url from settings."""
    return get_server_settings()["config_url"]

def get_server_enabled_node_types() -> list:
    """Get active enabled node types list (e.g. ['preferred', 'vps', 'local']) from settings."""
    return get_server_settings()["enabled_node_types"]

def set_server_settings(config_url: str = None, enabled_node_types: list = None) -> bool:
    """Save active config_url and/or enabled_node_types to settings.json."""
    try:
        current = get_server_settings()
        if config_url is not None:
            current["config_url"] = config_url
        if enabled_node_types is not None:
            valid_types = [t for t in enabled_node_types if t in ["preferred", "vps", "local"]]
            current["enabled_node_types"] = valid_types
        with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
            json.dump(current, f, indent=2, ensure_ascii=False)
        return True
    except Exception as e:
        logger.error(f"Error writing settings.json: {e}")
        return False

def set_server_config_url(config_url: str) -> bool:
    """Save active Clash config_url to settings.json."""
    return set_server_settings(config_url=config_url)

def set_server_enabled_node_types(enabled_node_types: list) -> bool:
    """Save active enabled node types to settings.json."""
    return set_server_settings(enabled_node_types=enabled_node_types)

# Configure Logger
logger = logging.getLogger("subconverter")
logger.setLevel(logging.INFO)

if not logger.handlers:
    # Console Handler
    ch = logging.StreamHandler()
    ch.setLevel(logging.INFO)
    formatter = logging.Formatter('[%(asctime)s] [%(levelname)s] %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
    ch.setFormatter(formatter)
    logger.addHandler(ch)

    # File Handler (5MB per log file, max 5 backup files)
    fh = RotatingFileHandler(LOG_FILE, maxBytes=5*1024*1024, backupCount=5, encoding="utf-8")
    fh.setLevel(logging.INFO)
    fh.setFormatter(formatter)
    logger.addHandler(fh)

cached_subconfigs_data = []

def derive_public_key(priv_b64: str) -> str:
    """Derive X25519 public key in RawURLEncoding (URL-safe base64 without padding for Mihomo/Clash Meta)."""
    if not priv_b64:
        return ""
    try:
        padded_b64 = priv_b64 + '=' * (-len(priv_b64) % 4)
        try:
            priv_bytes = base64.urlsafe_b64decode(padded_b64)
        except Exception:
            priv_bytes = base64.b64decode(padded_b64)
            
        if len(priv_bytes) != 32:
            return ""
            
        priv_key = x25519.X25519PrivateKey.from_private_bytes(priv_bytes)
        pub_key = priv_key.public_key()
        pub_bytes = pub_key.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        return base64.urlsafe_b64encode(pub_bytes).decode('utf-8').rstrip('=')
    except Exception as e:
        logger.error(f"Error deriving public key: {e}")
        return ""

_preferred_nodes_cache = []
_preferred_nodes_last_fetch = 0
PREFERRED_CACHE_TTL = 600  # 10 minutes cache

def fetch_preferred_nodes(vless_grpc_inbound: dict) -> list:
    """Rule 1: Fetch preferred IP list with 10-min in-memory cache and 4s timeout to prevent hanging."""
    global _preferred_nodes_cache, _preferred_nodes_last_fetch
    
    now = time.time()
    if _preferred_nodes_cache and (now - _preferred_nodes_last_fetch < PREFERRED_CACHE_TTL):
        return _preferred_nodes_cache

    if not vless_grpc_inbound:
        return []
        
    users = vless_grpc_inbound.get("users", [{}])
    uuid = users[0].get("uuid", "") if users else ""
    
    transport = vless_grpc_inbound.get("transport", {})
    host = transport.get("headers", {}).get("Host", "")
    if not host:
        host = vless_grpc_inbound.get("tls", {}).get("server_name", "")
    path = transport.get("path", "/singbox-ws-path")
    
    if not host or not uuid:
        return []
        
    url = EDGETUNNEL_SUB_URL.format(host=host, uuid=uuid)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    
    nodes = []
    try:
        with urllib.request.urlopen(req, timeout=4) as resp:
            data = resp.read().decode("utf-8")
            try:
                decoded = base64.b64decode(data).decode("utf-8")
            except Exception:
                decoded = data
                
            idx = 1
            for line in decoded.splitlines():
                line = line.strip()
                if not line.startswith("vless://"):
                    continue
                parsed = urllib.parse.urlparse(line)
                user_host = parsed.netloc
                if "@" not in user_host:
                    continue
                    
                _, ip_port = user_host.split("@", 1)
                if ":" in ip_port:
                    ip, port = ip_port.split(":", 1)
                else:
                    ip, port = ip_port, "443"
                    
                if ip in ["example.com", "127.0.0.1", "localhost"]:
                    continue
                    
                tag = urllib.parse.unquote(parsed.fragment) if parsed.fragment else f"CF-{ip}"
                if "不再支持旧版" in tag or "更新至最新版本" in tag:
                    continue
                    
                clean_tag = tag.strip("#").strip()
                name = f"CF-{clean_tag}-{idx:02d}"
                
                nodes.append({
                    "type": "vless-ws",
                    "name": name,
                    "server": ip,
                    "port": int(port),
                    "uuid": uuid,
                    "path": path,
                    "host": host,
                    "sni": host,
                    "tls": True,
                    "category": "preferred"
                })
                idx += 1
        if nodes:
            _preferred_nodes_cache = nodes
            _preferred_nodes_last_fetch = now
    except Exception as e:
        logger.error(f"Error fetching preferred nodes: {e}")
        if _preferred_nodes_cache:
            return _preferred_nodes_cache
        
    return nodes

def parse_server_inbounds(sb_config_path: str, default_server_host: str = "") -> list:
    """Parse sing-box server config into nodes ordered by: Preferred IP nodes -> VPS nodes -> Local Socks5 node."""
    local_socks_node = {
        "type": "socks5",
        "name": "本地Socks5节点",
        "server": "127.0.0.1",
        "port": 1080,
        "category": "local"
    }
    
    if not os.path.exists(sb_config_path):
        return [local_socks_node]
        
    with open(sb_config_path, "r", encoding="utf-8") as f:
        config = json.load(f)
        
    inbounds = config.get("inbounds", [])
    
    vless_grpc_ib = None
    other_ibs = []
    
    for ib in inbounds:
        ib_type = ib.get("type")
        tag = ib.get("tag", "")
        if ib_type == "socks":
            continue
        if tag == "vless-grpc":
            vless_grpc_ib = ib
        else:
            other_ibs.append(ib)
            
    preferred_nodes = fetch_preferred_nodes(vless_grpc_ib)
    for n in preferred_nodes:
        n["category"] = "preferred"

    vps_nodes = []
    server_host = default_server_host or "127.0.0.1"
    
    for ib in other_ibs:
        ib_type = ib.get("type")
        tag = ib.get("tag", "node")
        if tag.startswith("VPS自用"):
            node_name = tag
        elif tag.startswith("自用"):
            node_name = f"VPS{tag}"
        else:
            node_name = f"VPS自用-{tag}"
        port = ib.get("listen_port")
        
        if ib_type == "vless" and ib.get("tls", {}).get("reality", {}).get("enabled"):
            user = ib.get("users", [{}])[0]
            uuid = user.get("uuid", "")
            flow = user.get("flow", "")
            tls = ib.get("tls", {})
            reality = tls.get("reality", {})
            sni = tls.get("server_name", "") or server_host
            priv_key = reality.get("private_key", "")
            raw_pub = reality.get("public_key") or derive_public_key(priv_key)
            pub_key = raw_pub.replace('+', '-').replace('/', '_').rstrip('=')
            short_id = reality.get("short_id", [""])[0] if reality.get("short_id") else ""
            
            vps_nodes.append({
                "type": "vless-reality",
                "name": node_name,
                "server": server_host,
                "port": int(port),
                "uuid": uuid,
                "flow": flow,
                "sni": sni,
                "public_key": pub_key,
                "short_id": short_id,
                "tls": True,
                "category": "vps"
            })
        elif ib_type == "hysteria2":
            user = ib.get("users", [{}])[0]
            password = user.get("password", "")
            tls = ib.get("tls", {})
            sni = tls.get("server_name", "") or server_host
            
            vps_nodes.append({
                "type": "hysteria2",
                "name": node_name,
                "server": server_host,
                "port": int(port),
                "password": password,
                "sni": sni,
                "tls": True,
                "category": "vps"
            })
        else:
            tls = ib.get("tls", {})
            sni = tls.get("server_name", "") or server_host
            user = ib.get("users", [{}])[0] if ib.get("users") else {}
            uuid = user.get("uuid", "") or user.get("password", "")
            if port and uuid:
                vps_nodes.append({
                    "type": ib_type,
                    "name": node_name,
                    "server": server_host,
                    "port": int(port),
                    "uuid": uuid,
                    "sni": sni,
                    "tls": bool(tls.get("enabled", True)),
                    "category": "vps"
                })
            
    nodes = preferred_nodes + vps_nodes + [local_socks_node]
    return nodes

def get_node_category(node: dict) -> str:
    """Determine category ('preferred', 'vps', 'local') of a node dict."""
    cat = node.get("category")
    if cat in ["preferred", "vps", "local"]:
        return cat
    
    name = str(node.get("name", ""))
    server = str(node.get("server", ""))
    n_type = str(node.get("type", ""))
    
    if n_type == "socks5" or "本地" in name or server == "127.0.0.1":
        return "local"
    elif "CF-" in name or n_type == "vless-ws":
        return "preferred"
    else:
        return "vps"

def parse_type_string(t_str: str) -> list:
    """Parse a comma/pipe-separated string or single type string into a list of canonical categories ('preferred', 'vps', 'local')."""
    if not t_str:
        return []
    result = []
    for part in re.split(r'[,|+ \-_]+', str(t_str).strip().lower()):
        part = part.strip()
        if not part:
            continue
        if part in ["preferred", "preferred_ip", "cf", "cdn", "优选", "优选ip", "1"]:
            if "preferred" not in result:
                result.append("preferred")
        elif part in ["vps", "vps自用", "自用", "server", "2"]:
            if "vps" not in result:
                result.append("vps")
        elif part in ["local", "socks", "socks5", "本地", "3"]:
            if "local" not in result:
                result.append("local")
        elif part in ["all", "full", "全部", "所有", "0"]:
            return list(DEFAULT_ENABLED_NODE_TYPES)
    return result

def filter_nodes_by_type(nodes: list, node_type = None) -> list:
    """
    Filter nodes by category ('preferred', 'vps', 'local').
    - If node_type is None: defaults to server-side configured get_server_enabled_node_types().
    - If node_type is provided as list or str: filters by specified categories.
    - If node_type is 'all' / '全部' / '0': returns all categories.
    """
    if not nodes:
        return []
        
    if node_type is None:
        allowed_categories = get_server_enabled_node_types()
    elif isinstance(node_type, list):
        allowed_categories = [t for t in node_type if t in ["preferred", "vps", "local"]]
    elif isinstance(node_type, str):
        s = node_type.strip().lower()
        if not s:
            allowed_categories = get_server_enabled_node_types()
        elif s in ["all", "full", "全部", "所有", "0"]:
            allowed_categories = list(DEFAULT_ENABLED_NODE_TYPES)
        else:
            allowed_categories = parse_type_string(s)
    else:
        allowed_categories = get_server_enabled_node_types()

    if not allowed_categories:
        return []

    return [n for n in nodes if get_node_category(n) in allowed_categories]

def fetch_subconfigs() -> list:
    """Fetch rule configuration list from REMOTE_SUBCONFIG_URL."""
    global cached_subconfigs_data
    req = urllib.request.Request(REMOTE_SUBCONFIG_URL, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            if resp.status == 200:
                data = json.loads(resp.read().decode("utf-8"))
                cached_subconfigs_data = data
                return data
    except Exception as e:
        logger.error(f"Error fetching remote SUBCONFIG.json: {e}")
        
    return cached_subconfigs_data

def convert_via_subapi(sub_url: str, target: str, config_url: str = "", max_retries: int = 5) -> str:
    """Use https://subapi.19910417.xyz/ online conversion API with 5 retries and progressive timeout (+10s per attempt)."""
    if not sub_url:
        logger.warning(f"⚠️ Subapi 转换跳过: 传入的 sub_url 为空 (target={target})")
        return ""
    subapi_target = "clash" if "clash" in target.lower() else "singbox"
    encoded_url = urllib.parse.quote(sub_url, safe="")
    
    if not config_url:
        if subapi_target == "singbox":
            cfg = DEFAULT_SINGBOX_CONFIG_URL
        else:
            cfg = get_server_config_url()
    else:
        cfg = config_url

    api_url = f"{SUBAPI_CONVERT_URL.format(target=subapi_target, url=encoded_url)}&config={urllib.parse.quote(cfg, safe='')}"
    curl_cmd = f"curl -s -L -A \"Mozilla/5.0\" \"{api_url}\""
    
    for attempt in range(1, max_retries + 1):
        current_timeout = attempt * 10  # 10s, 20s, 30s, 40s, 50s
        req = urllib.request.Request(api_url, headers={"User-Agent": "Mozilla/5.0"})
        try:
            with urllib.request.urlopen(req, timeout=current_timeout) as resp:
                status_code = resp.status
                content = resp.read().decode("utf-8")
                is_valid_content = any(k in content for k in ["proxies", "outbounds", "outbound", "port", "inbounds"])
                if status_code == 200 and len(content) > 100 and is_valid_content:
                    logger.info(f"✅ Subapi 订阅转换成功! [目标: {target}, 策略规则: {cfg}, 响应大小: {len(content)} 字节, 第 {attempt} 次尝试]")
                    return content
                else:
                    logger.error(f"❌ Subapi 转换响应异常 [HTTP {status_code}] [目标: {target}, 订阅源: {sub_url}, 规则: {cfg}]: 返回内容缺少节点定义!\n测试 curl 命令: {curl_cmd}")
                    break
        except urllib.error.HTTPError as e:
            err_body = ""
            try:
                err_body = e.read().decode("utf-8")[:250]
            except Exception:
                pass
            logger.error(f"❌ Subapi 转换 HTTP 错误 [HTTP {e.code} {e.reason}] [目标: {target}, 订阅源: {sub_url}] - 详细返回: {err_body}\n测试 curl 命令: {curl_cmd}")
            break
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            err_msg = str(e.reason if hasattr(e, "reason") else e)
            if attempt < max_retries:
                next_timeout = (attempt + 1) * 10
                logger.warning(f"⚠️ Subapi 在线转换超时/网络抖动 (第 {attempt}/{max_retries} 次请求超时 {current_timeout}s: {err_msg})，增加超时时间至 {next_timeout}s 并进行第 {attempt+1} 次重试...\n测试 curl 命令: {curl_cmd}")
                time.sleep(1)
            else:
                logger.error(f"❌ Subapi 在线转换连续超时 [已重试 {max_retries} 次, 最终超时 {current_timeout}s] [目标: {target}, 订阅源: {sub_url}] - 错误信息: {err_msg}\n测试 curl 命令: {curl_cmd}")
        except Exception as e:
            logger.error(f"❌ Subapi 转换未捕获异常 [目标: {target}, 订阅源: {sub_url}] - 错误信息: {str(e)}\n测试 curl 命令: {curl_cmd}")
            break
            
    return ""

def clean_clash_proxies(yaml_content: str) -> str:
    """Clean up non-standard or redundant fields in Clash Meta proxies (remove 'auth' from hysteria2, remove 'network' from vless-reality)."""
    if not yaml_content:
        return yaml_content
    try:
        data = yaml.safe_load(yaml_content)
        if not isinstance(data, dict):
            return yaml_content
            
        proxies = data.get("proxies", [])
        if isinstance(proxies, list):
            for p in proxies:
                if not isinstance(p, dict):
                    continue
                p_type = str(p.get("type", "")).lower()
                p_name = str(p.get("name", ""))
                
                # Only set skip-cert-verify: true for non-preferred Hysteria2 nodes; leave other nodes untouched
                is_non_preferred_hy2 = (p_type == "hysteria2") and ("VPS" in p_name or "自用" in p_name or "hy2" in p_name)
                if is_non_preferred_hy2:
                    p["skip-cert-verify"] = True
                
                # 1. For hysteria2: remove non-standard 'auth' field (Mihomo uses 'password')
                if p_type == "hysteria2":
                    if "auth" in p:
                        if not p.get("password"):
                            p["password"] = p["auth"]
                        del p["auth"]
                # 2. For vless reality: remove non-standard 'network' field
                elif p_type == "vless" and "reality-opts" in p:
                    if "network" in p:
                        del p["network"]
                        
            data["proxies"] = proxies
            return yaml.dump(data, allow_unicode=True, sort_keys=False)
    except Exception as e:
        logger.error(f"Error cleaning Clash proxies: {e}")
    return yaml_content

def patch_clash_sniffer(yaml_content: str) -> str:
    """Patch Clash YAML config to insert/update sniffer configuration for FakeIP domain mapping and pure IP direct routing."""
    if not yaml_content:
        return yaml_content
    try:
        data = yaml.safe_load(yaml_content)
        if not isinstance(data, dict):
            return yaml_content

        default_sniff = {
            "HTTP": {
                "ports": [80, "8080-8880"],
                "override-destination": True
            },
            "TLS": {
                "ports": [443, 8443]
            },
            "QUIC": {
                "ports": [443, 8443]
            }
        }

        default_skip_domains = [
            "MJP.Mihomo.DEV",
            "+.push.apple.com"
        ]

        sniffer = data.get("sniffer")
        if not isinstance(sniffer, dict):
            data["sniffer"] = {
                "enable": True,
                "force-dns-mapping": True,
                "parse-pure-ip": True,
                "override-destination": True,
                "sniff": default_sniff,
                "skip-domain": default_skip_domains
            }
        else:
            sniffer["enable"] = True
            sniffer["force-dns-mapping"] = True
            sniffer["parse-pure-ip"] = True
            sniffer["override-destination"] = True

            sniff = sniffer.get("sniff")
            if not isinstance(sniff, dict):
                sniffer["sniff"] = default_sniff
            else:
                if "HTTP" not in sniff or not isinstance(sniff["HTTP"], dict):
                    sniff["HTTP"] = default_sniff["HTTP"]
                else:
                    sniff["HTTP"]["override-destination"] = True
                    if "ports" not in sniff["HTTP"]:
                        sniff["HTTP"]["ports"] = [80, "8080-8880"]

                if "TLS" not in sniff or not isinstance(sniff["TLS"], dict):
                    sniff["TLS"] = default_sniff["TLS"]
                else:
                    if "ports" not in sniff["TLS"]:
                        sniff["TLS"]["ports"] = [443, 8443]

                if "QUIC" not in sniff or not isinstance(sniff["QUIC"], dict):
                    sniff["QUIC"] = default_sniff["QUIC"]
                else:
                    if "ports" not in sniff["QUIC"]:
                        sniff["QUIC"]["ports"] = [443, 8443]

            skip_domain = sniffer.get("skip-domain")
            if not isinstance(skip_domain, list):
                sniffer["skip-domain"] = default_skip_domains
            else:
                for domain in default_skip_domains:
                    if domain not in skip_domain:
                        skip_domain.append(domain)

        return yaml.dump(data, allow_unicode=True, sort_keys=False)
    except Exception as e:
        logger.error(f"Error patching Clash sniffer: {e}")
        return yaml_content

def ensure_reality_in_clash_yaml(yaml_content: str, nodes: list = None) -> str:
    """Clean up non-standard fields and patch sniffer config in Clash YAML."""
    if not yaml_content:
        return yaml_content
    cleaned_yaml = clean_clash_proxies(yaml_content)
    return patch_clash_sniffer(cleaned_yaml)

def ensure_reality_utls_in_singbox_dict(data: dict) -> bool:
    """Ensure all vless reality outbounds in sing-box config have utls enabled."""
    modified = False
    outbounds = data.get("outbounds", [])
    if isinstance(outbounds, list):
        for ob in outbounds:
            if isinstance(ob, dict) and ob.get("type") == "vless":
                tls = ob.get("tls")
                if isinstance(tls, dict) and tls.get("enabled"):
                    reality = tls.get("reality")
                    if isinstance(reality, dict) and reality.get("enabled"):
                        utls = tls.get("utls")
                        if not isinstance(utls, dict) or not utls.get("enabled"):
                            tls["utls"] = {"enabled": True, "fingerprint": "chrome"}
                            modified = True
    return modified

def patch_singbox_direct_tag(data: dict) -> bool:
    """Patch sing-box JSON dict: if outbounds contains a node with tag 'DIRECT', change its tag to 'direct'.
    Also update any references in selector/urltest outbounds list, route rules, or dns servers from 'DIRECT' to 'direct'.
    """
    modified = False
    outbounds = data.get("outbounds", [])
    if isinstance(outbounds, list):
        for ob in outbounds:
            if isinstance(ob, dict):
                if ob.get("tag") == "DIRECT":
                    ob["tag"] = "direct"
                    modified = True
                
                ob_list = ob.get("outbounds")
                if isinstance(ob_list, list):
                    for idx, item in enumerate(ob_list):
                        if item == "DIRECT":
                            ob_list[idx] = "direct"
                            modified = True

    route = data.get("route", {})
    if isinstance(route, dict):
        if route.get("final") == "DIRECT":
            route["final"] = "direct"
            modified = True
        rules = route.get("rules", [])
        if isinstance(rules, list):
            for rule in rules:
                if isinstance(rule, dict) and rule.get("outbound") == "DIRECT":
                    rule["outbound"] = "direct"
                    modified = True

    dns = data.get("dns", {})
    if isinstance(dns, dict):
        servers = dns.get("servers", [])
        if isinstance(servers, list):
            for srv in servers:
                if isinstance(srv, dict) and srv.get("detour") in ["direct", "DIRECT"]:
                    del srv["detour"]
                    modified = True

    return modified

def ensure_extra_nodes_in_singbox_json(json_content: str, nodes: list = None) -> str:
    """Ensure reality utls and patch DIRECT tags in sing-box JSON configuration."""
    if not json_content:
        return json_content
    try:
        data = json.loads(json_content)
        if not isinstance(data, dict):
            return json_content
            
        modified_utls = ensure_reality_utls_in_singbox_dict(data)
        modified_direct = patch_singbox_direct_tag(data)
        if modified_utls or modified_direct:
            return json.dumps(data, indent=2, ensure_ascii=False)
    except Exception as e:
        logger.error(f"Error processing sing-box JSON: {e}")
        
    return json_content

def generate_base64_v2ray(nodes: list) -> str:
    """Generate Base64 encoded V2Ray / URI subscription links."""
    links = []
    for n in nodes:
        name = n["name"]
        encoded_name = urllib.parse.quote(name)
        
        if n["type"] == "vless-ws":
            path_enc = urllib.parse.quote(n["path"])
            link = f"vless://{n['uuid']}@{n['server']}:{n['port']}?encryption=none&security=tls&sni={n['sni']}&fp=chrome&type=ws&host={n['host']}&path={path_enc}#{encoded_name}"
            links.append(link)
        elif n["type"] == "vless-reality":
            flow = n.get("flow", "")
            pbk = n["public_key"].replace('+', '-').replace('/', '_').rstrip('=')
            link = f"vless://{n['uuid']}@{n['server']}:{n['port']}?encryption=none&security=reality&sni={n['sni']}&fp=chrome&pbk={pbk}&sid={n['short_id']}&type=tcp&flow={flow}#{encoded_name}"
            links.append(link)
        elif n["type"] == "hysteria2":
            link = f"hysteria2://{n['password']}@{n['server']}:{n['port']}?sni={n['sni']}&insecure=0#{encoded_name}"
            links.append(link)
        elif n["type"] in ["socks", "socks5"]:
            user = n.get("user") or ""
            pwd = n.get("pass") or n.get("password") or ""
            if user and pwd:
                payload = f"{user}:{pwd}@{n['server']}:{n['port']}"
            else:
                payload = f"{n['server']}:{n['port']}"
            b64_payload = base64.urlsafe_b64encode(payload.encode("utf-8")).decode("utf-8")
            link = f"socks://{b64_payload}#{encoded_name}"
            links.append(link)
            
    raw_text = "\n".join(links)
    return base64.b64encode(raw_text.encode("utf-8")).decode("utf-8")

def generate_subscription(sb_config_path: str, target: str = "clash", server_host: str = "", sub_url: str = "", config_url: str = "", node_type: str = ""):
    """Adaptive subscription generator via https://subapi.19910417.xyz/, custom config_url, and node_type filter."""
    nodes = parse_server_inbounds(sb_config_path, server_host)
    nodes = filter_nodes_by_type(nodes, node_type)
    target = target.lower()
    
    if "base64" in target or "v2ray" in target or "shadowrocket" in target:
        return generate_base64_v2ray(nodes)
        
    if sub_url:
        default_cfg = DEFAULT_SINGBOX_CONFIG_URL if ("singbox" in target or "sing-box" in target) else get_server_config_url()
        converted = convert_via_subapi(sub_url, target, config_url or default_cfg)
        if converted:
            if "clash" in target:
                converted = ensure_reality_in_clash_yaml(converted, nodes)
            elif "singbox" in target or "sing-box" in target:
                converted = ensure_extra_nodes_in_singbox_json(converted, nodes)
            return converted
        else:
            logger.error(f"❌ 订阅生成失败: subapi 转换失败 (target={target})，拒绝本地配置兜底")
            return ""
            
    return ""
