#!/usr/bin/env bash
#
# install-frp.sh
# 一键部署 FRP 服务端 (frps)

set -e

# --- 默认配置 ---
FRP_PORT=7000
FRP_VHOST_HTTPS_PORT=443
FRP_TOKEN=""
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# --- 帮助信息 ---
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -p, --port PORT           Specify frps bind port (default: 7000)"
    echo "  -t, --token TOKEN         Specify auth token (default: auto-generated)"
    echo "  --vhost-https PORT        Specify vhost HTTPS port (default: 443)"
    echo "  -h, --help                Show this help message"
}

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${RED}[WARN]${NC} $1"
}

# --- 架构检测 ---
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) warn "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# --- 解析参数 ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -p|--port) FRP_PORT="$2"; shift ;;
        -t|--token) FRP_TOKEN="$2"; shift ;;
        --vhost-https) FRP_VHOST_HTTPS_PORT="$2"; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) warn "Unknown argument: $1"; show_help; exit 1 ;;
    esac
    shift
done

# --- 生成随机 Token ---
if [[ -z "$FRP_TOKEN" ]]; then
    FRP_TOKEN=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
    log "Generated random token: ${FRP_TOKEN}"
fi

# --- 获取最新版本 ---
log "Fetching latest FRP version..."
LATEST_VERSION=$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest | grep "tag_name" | cut -d : -f 2,3 | tr -d 'v" ,')
log "Latest version: v${LATEST_VERSION}"

FRP_FILE="frp_${LATEST_VERSION}_linux_${ARCH}"
FRP_URL="https://github.com/fatedier/frp/releases/download/v${LATEST_VERSION}/${FRP_FILE}.tar.gz"

# --- 下载并解压 ---
log "Downloading from ${FRP_URL}..."
curl -L -o "/tmp/${FRP_FILE}.tar.gz" "${FRP_URL}"
tar -zxvf "/tmp/${FRP_FILE}.tar.gz" -C /tmp/

# --- 安装文件 ---
log "Installing frps binary..."
sudo cp "/tmp/${FRP_FILE}/frps" /usr/bin/frps
sudo chmod +x /usr/bin/frps

# --- 配置文件 ---
log "Creating configuration..."
sudo mkdir -p /etc/frp
sudo cat > /tmp/frps.toml << EOF
bindPort = ${FRP_PORT}
vhostHTTPSPort = ${FRP_VHOST_HTTPS_PORT}
auth.method = "token"
auth.token = "${FRP_TOKEN}"
EOF
sudo mv /tmp/frps.toml /etc/frp/frps.toml

# --- Systemd 服务 ---
log "Setting up systemd service..."
sudo cat > /etc/systemd/system/frps.service << EOF
[Unit]
Description=frp server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/frps -c /etc/frp/frps.toml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

log "Reloading systemd and starting frps..."
sudo systemctl daemon-reload
sudo systemctl enable frps
sudo systemctl restart frps

# --- 获取公网 IP (用于引导提示) ---
SERVER_IP=$(curl -s https://ifconfig.me || echo "VPS_IP")

# --- 总结 ---
log "FRP server installed successfully!"
echo "------------------------------------------------"
echo -e "${GREEN}Bind Port   :${NC} ${FRP_PORT}"
echo -e "${GREEN}vhost HTTPS :${NC} ${FRP_VHOST_HTTPS_PORT}"
echo -e "${GREEN}Auth Token  :${NC} ${FRP_TOKEN}"
echo "------------------------------------------------"
log "Configuration: /etc/frp/frps.toml"
log "Service: systemctl status frps"
warn "Please ensure ports ${FRP_PORT} and ${FRP_VHOST_HTTPS_PORT} are open in your firewall."

echo ""
log "Client Configuration Example (frpc.toml):"
echo "------------------------------------------------"
cat << EOF
serverAddr = "${SERVER_IP}"
serverPort = ${FRP_PORT}
auth.method = "token"
auth.token = "${FRP_TOKEN}"

# 场景：内网 Nginx 承载多域名分发
[[proxies]]
name = "https-multi-domain"
type = "https"
customDomains = ["www.yourdomain.com", "api.yourdomain.com"]
[proxies.localSvc]
addr = "127.0.0.1"
port = 443
EOF
echo "------------------------------------------------"
