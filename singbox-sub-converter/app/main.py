import os
import re
import time
import threading
import json
import hashlib
import secrets
import asyncio
import logging
from fastapi import FastAPI, Response, Request, HTTPException, Depends, Cookie
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from dotenv import load_dotenv

from app.converter import (
    parse_server_inbounds,
    generate_clash_yaml,
    generate_singbox_json,
    generate_base64_v2ray,
    convert_via_subapi,
    ensure_reality_in_clash_yaml,
    fetch_subconfigs,
    logger,
    DATA_DIR
)

load_dotenv()

# Configuration
SB_CONFIG_PATH = os.getenv("SB_CONFIG_PATH", "/etc/sing-box/config.json")
PORT = int(os.getenv("PORT", 8000))
SUB_TOKEN = os.getenv("SUB_TOKEN", "")
EXTERNAL_URL = os.getenv("EXTERNAL_URL", "").rstrip("/")
SERVER_HOST = os.getenv("SERVER_HOST", "")
SUBAPI_URL = os.getenv("SUBAPI_URL", "https://subapi.19910417.xyz").rstrip("/")

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
USERS_FILE = os.path.join(DATA_DIR, "users.json")
STATIC_DIR = os.path.join(BASE_DIR, "static")

# Ensure data directory exists
os.makedirs(DATA_DIR, exist_ok=True)

# Initialize default user
if not os.path.exists(USERS_FILE):
    default_user = {
        "username": "jayyang",
        "password_hash": hashlib.sha256("admin1234".encode()).hexdigest(),
        "is_first_login": True
    }
    with open(USERS_FILE, "w", encoding="utf-8") as f:
        json.dump(default_user, f)

def get_user():
    with open(USERS_FILE, "r", encoding="utf-8") as f:
        return json.load(f)

def save_user(user):
    with open(USERS_FILE, "w", encoding="utf-8") as f:
        json.dump(user, f)

sessions = {}

app = FastAPI(title="singbox-sub-converter")

cached_clash_config = ""
cached_singbox_config = ""
cached_base64_config = ""
parsed_nodes_cache = []
last_config_mtime = 0

def get_effective_config_path():
    if os.path.exists(SB_CONFIG_PATH):
        return os.path.realpath(SB_CONFIG_PATH)
    fallback = os.path.join(BASE_DIR, "..", "..", "config.json")
    if os.path.exists(fallback):
        return os.path.realpath(fallback)
    return os.path.realpath(SB_CONFIG_PATH)

def refresh_nodes_cache():
    """Instantly parse nodes from config.json and update cached_base64_config (0ms blocking for /v2ray)."""
    global parsed_nodes_cache, cached_base64_config, cached_clash_config, cached_singbox_config, last_config_mtime
    config_path = get_effective_config_path()
    if os.path.exists(config_path):
        try:
            last_config_mtime = os.path.getmtime(config_path)
            parsed_nodes_cache = parse_server_inbounds(config_path, SERVER_HOST)
            cached_base64_config = generate_base64_v2ray(parsed_nodes_cache)
            cached_clash_config = generate_clash_yaml(parsed_nodes_cache)
            cached_singbox_config = generate_singbox_json(parsed_nodes_cache)
            logger.info(f"✅ 本地节点解析完成，生成 {len(parsed_nodes_cache)} 个节点 Base64 订阅")
        except Exception as e:
            logger.error(f"❌ 重新解析本地节点失败: {e}")
            cached_base64_config = ""

def ensure_fresh_nodes():
    """Check if config mtime has changed and update nodes cache if needed."""
    config_path = get_effective_config_path()
    if os.path.exists(config_path):
        current_mtime = os.path.getmtime(config_path)
        if current_mtime != last_config_mtime:
            refresh_nodes_cache()

refresh_nodes_cache()

# Watchdog File Listener
class ConfigHandler(FileSystemEventHandler):
    def process_event(self, event):
        config_path = get_effective_config_path()
        event_src = os.path.realpath(event.src_path) if hasattr(event, "src_path") else ""
        event_dest = os.path.realpath(event.dest_path) if hasattr(event, "dest_path") and event.dest_path else ""
        
        if event_src == config_path or event_dest == config_path:
            refresh_nodes_cache()

    def on_modified(self, event):
        self.process_event(event)

    def on_created(self, event):
        self.process_event(event)

    def on_moved(self, event):
        self.process_event(event)

def start_watcher():
    observer = Observer()
    config_path = get_effective_config_path()
    config_dir = os.path.dirname(config_path)
    if os.path.exists(config_dir):
        observer.schedule(ConfigHandler(), config_dir, recursive=False)
        observer.start()

@app.on_event("startup")
async def startup_event():
    watcher_thread = threading.Thread(target=start_watcher, daemon=True)
    watcher_thread.start()
    # Pre-fetch SUBCONFIG.json in background
    threading.Thread(target=fetch_subconfigs, daemon=True).start()

def get_current_user(session_id: str = Cookie(None)):
    if not session_id or session_id not in sessions:
        raise HTTPException(status_code=401, detail="Unauthorized")
    return sessions[session_id]

def get_base_url(request: Request) -> str:
    if EXTERNAL_URL:
        return EXTERNAL_URL
    proto = request.headers.get("x-forwarded-proto", request.url.scheme)
    host = request.headers.get("x-forwarded-host", request.headers.get("host", request.url.netloc))
    return f"{proto}://{host}".rstrip("/")

@app.get("/api/subconfigs")
async def get_subconfigs():
    """Endpoint returning SUBCONFIG.json options for dropdown selector."""
    configs = fetch_subconfigs()
    return JSONResponse(content=configs)

@app.get("/api/logs")
async def get_logs(lines: int = 100, current_user: str = Depends(get_current_user)):
    """Fetch the latest log lines from app.log."""
    log_file = os.path.join(DATA_DIR, "app.log")
    if not os.path.exists(log_file):
        return {"logs": "尚无日志记录"}
    try:
        with open(log_file, "r", encoding="utf-8") as f:
            content = f.readlines()
            last_lines = content[-lines:] if len(content) > lines else content
            return {"logs": "".join(last_lines)}
    except Exception as e:
        return {"logs": f"读取日志出错: {str(e)}"}

@app.post("/api/login")
async def login(request: Request):
    data = await request.json()
    username = data.get("username")
    password = data.get("password")
    
    user = get_user()
    pw_hash = hashlib.sha256(password.encode()).hexdigest()
    
    if username == user["username"] and pw_hash == user["password_hash"]:
        session_id = secrets.token_hex(16)
        sessions[session_id] = username
        response = JSONResponse(content={
            "status": "success",
            "is_first_login": user.get("is_first_login", False)
        })
        response.set_cookie(key="session_id", value=session_id, httponly=True, samesite="lax")
        return response
    
    raise HTTPException(status_code=401, detail="Invalid credentials")

@app.post("/api/change-password")
async def change_password(request: Request, current_user: str = Depends(get_current_user)):
    data = await request.json()
    new_password = data.get("new_password")
    
    if not new_password or len(new_password) < 6:
        raise HTTPException(status_code=400, detail="Password too short")
    
    user = get_user()
    user["password_hash"] = hashlib.sha256(new_password.encode()).hexdigest()
    user["is_first_login"] = False
    save_user(user)
    
    return {"status": "success"}

@app.post("/api/rotate-token")
async def rotate_token(request: Request, current_user: str = Depends(get_current_user)):
    """Rotate the subscription SUB_TOKEN / UUID for enhanced security."""
    global SUB_TOKEN
    new_token = secrets.token_hex(16)
    SUB_TOKEN = new_token
    
    service_file = "/etc/systemd/system/singbox-sub-converter.service"
    if os.path.exists(service_file):
        try:
            with open(service_file, "r", encoding="utf-8") as f:
                content = f.read()
            new_content = re.sub(r'Environment="SUB_TOKEN=[^"]*"', f'Environment="SUB_TOKEN={new_token}"', content)
            with open(service_file, "w", encoding="utf-8") as f:
                f.write(new_content)
            os.system("systemctl daemon-reload >/dev/null 2>&1")
        except Exception as e:
            logger.warning(f"Notice: Could not persist SUB_TOKEN to systemd: {e}")

    base = get_base_url(request)
    refresh_nodes_cache()
    
    return {
        "status": "success",
        "token": new_token,
        "sub_url": f"{base}/sub?token={new_token}",
        "clash_url": f"{base}/clash?token={new_token}",
        "singbox_url": f"{base}/singbox?token={new_token}",
        "v2ray_url": f"{base}/v2ray?token={new_token}"
    }

@app.get("/api/logout")
async def logout(response: Response, session_id: str = Cookie(None)):
    if session_id in sessions:
        del sessions[session_id]
    response.delete_cookie("session_id")
    return {"status": "success"}

@app.post("/api/refresh-ip")
async def refresh_ip(request: Request, current_user: str = Depends(get_current_user)):
    async def generate():
        yield "🔄 正在刷新优选 IP 与订阅缓存...\n"
        try:
            loop = asyncio.get_running_loop()
            await loop.run_in_executor(None, refresh_nodes_cache)
            yield "✅ 优选 IP 刷新成功，订阅缓存已更新！\n"
        except Exception as e:
            yield f"❌ 发生错误: {str(e)}\n"

    return StreamingResponse(generate(), media_type="text/plain")

@app.get("/config/info")
async def get_config_info(request: Request, current_user: str = Depends(get_current_user)):
    base = get_base_url(request)
    ensure_fresh_nodes()
    
    return {
        "token": SUB_TOKEN,
        "external_url": base,
        "sub_url": f"{base}/sub?token={SUB_TOKEN}" if SUB_TOKEN else f"{base}/sub",
        "clash_url": f"{base}/clash?token={SUB_TOKEN}" if SUB_TOKEN else f"{base}/clash",
        "singbox_url": f"{base}/singbox?token={SUB_TOKEN}" if SUB_TOKEN else f"{base}/singbox",
        "v2ray_url": f"{base}/v2ray?token={SUB_TOKEN}" if SUB_TOKEN else f"{base}/v2ray"
    }

# Subscription Endpoints with non-blocking async execution and reality merge
@app.get("/sub")
async def get_adaptive_sub(request: Request, token: str = "", target: str = "", flag: str = "", config: str = ""):
    if SUB_TOKEN and token != SUB_TOKEN:
        logger.warning("拒绝非法 Token 订阅请求: /sub")
        return Response(content="# Error: Invalid Token", media_type="text/plain", status_code=403)
        
    base_url = get_base_url(request)
    ensure_fresh_nodes()
    
    v2ray_url = f"{base_url}/v2ray?token={SUB_TOKEN}" if SUB_TOKEN else f"{base_url}/v2ray"
    
    ua = request.headers.get("user-agent", "").lower()
    tgt = (target or flag).lower()
    
    is_clash = "clash" in tgt or "mihomo" in tgt or "stash" in tgt or any(k in ua for k in ["clash", "stash", "mihomo", "shadowrocket", "verge"])
    is_singbox = "singbox" in tgt or "sing-box" in tgt or any(k in ua for k in ["sing-box", "singbox", "box"])
    
    if is_clash:
        content = await asyncio.to_thread(convert_via_subapi, v2ray_url, "clash", config_url=config)
        if content:
            content = ensure_reality_in_clash_yaml(content, parsed_nodes_cache)
        else:
            content = cached_clash_config
        clash_headers = {
            "profile-update-interval": "24",
            "subscription-userinfo": "upload=0; download=0; total=1073741824000; expire=0",
            "content-disposition": 'attachment; filename="config.yaml"',
            "connection": "close"
        }
        return Response(content=content, media_type="text/yaml; charset=utf-8", headers=clash_headers)
    elif is_singbox:
        content = await asyncio.to_thread(convert_via_subapi, v2ray_url, "singbox", config_url=config) or cached_singbox_config
        return Response(content=content, media_type="application/json; charset=utf-8")
    else:
        return Response(content=cached_base64_config, media_type="text/plain; charset=utf-8")

@app.get("/clash")
async def get_clash_sub(request: Request, token: str = "", config: str = ""):
    if SUB_TOKEN and token != SUB_TOKEN:
        logger.warning("拒绝非法 Token 订阅请求: /clash")
        return Response(content="# Error: Invalid Token", media_type="text/plain", status_code=403)
    base_url = get_base_url(request)
    ensure_fresh_nodes()
    
    v2ray_url = f"{base_url}/v2ray?token={SUB_TOKEN}" if SUB_TOKEN else f"{base_url}/v2ray"
    content = await asyncio.to_thread(convert_via_subapi, v2ray_url, "clash", config_url=config)
    if content:
        content = ensure_reality_in_clash_yaml(content, parsed_nodes_cache)
    else:
        content = cached_clash_config
    clash_headers = {
        "profile-update-interval": "24",
        "subscription-userinfo": "upload=0; download=0; total=1073741824000; expire=0",
        "content-disposition": 'attachment; filename="config.yaml"',
        "connection": "close"
    }
    return Response(content=content, media_type="text/yaml; charset=utf-8", headers=clash_headers)

@app.get("/singbox")
async def get_singbox_sub(request: Request, token: str = "", config: str = ""):
    if SUB_TOKEN and token != SUB_TOKEN:
        logger.warning("拒绝非法 Token 订阅请求: /singbox")
        return Response(content="# Error: Invalid Token", media_type="application/json", status_code=403)
    base_url = get_base_url(request)
    ensure_fresh_nodes()
    
    v2ray_url = f"{base_url}/v2ray?token={SUB_TOKEN}" if SUB_TOKEN else f"{base_url}/v2ray"
    content = await asyncio.to_thread(convert_via_subapi, v2ray_url, "singbox", config_url=config) or cached_singbox_config
    return Response(content=content, media_type="application/json; charset=utf-8")

@app.get("/v2ray")
@app.get("/base64")
async def get_v2ray_sub(request: Request, token: str = ""):
    """Instant 0ms response for /v2ray: returns pre-computed cached_base64_config without blocking event loop."""
    if SUB_TOKEN and token != SUB_TOKEN:
        logger.warning("拒绝非法 Token 订阅请求: /v2ray")
        return Response(content="# Error: Invalid Token", media_type="text/plain", status_code=403)
    ensure_fresh_nodes()
    return Response(content=cached_base64_config, media_type="text/plain; charset=utf-8")

@app.get("/", response_class=HTMLResponse)
async def index():
    index_path = os.path.join(STATIC_DIR, "index.html")
    if os.path.exists(index_path):
        with open(index_path, "r", encoding="utf-8") as f:
            return f.read()
    return "index.html not found"

if os.path.exists(STATIC_DIR):
    app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=PORT)
