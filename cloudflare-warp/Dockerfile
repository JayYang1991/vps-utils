FROM ubuntu:24.04

LABEL maintainer="JayYang"
LABEL description="Cloudflare WARP with Zero Trust & Sing-box SOCKS5 Proxy Container"

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies required for cloudflare-warp and sing-box
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gnupg \
    lsb-release \
    ca-certificates \
    iptables \
    iproute2 \
    procps \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Copy and execute install.sh to install Cloudflare WARP
COPY install.sh /tmp/install.sh
RUN chmod +x /tmp/install.sh && /tmp/install.sh && rm -f /tmp/install.sh

# Download and install sing-box binary with fallback mirrors
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in \
         amd64) SINGBOX_ARCH="amd64" ;; \
         arm64|aarch64) SINGBOX_ARCH="arm64" ;; \
         *) SINGBOX_ARCH="amd64" ;; \
       esac \
    && SINGBOX_VER="1.11.0" \
    && (curl -fsSL -o /tmp/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-${SINGBOX_ARCH}.tar.gz" || \
        curl -fsSL -o /tmp/sing-box.tar.gz "https://ghfast.top/https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-${SINGBOX_ARCH}.tar.gz" || \
        curl -fsSL -o /tmp/sing-box.tar.gz "https://mirror.ghproxy.com/https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-${SINGBOX_ARCH}.tar.gz") \
    && tar -xzf /tmp/sing-box.tar.gz -C /tmp \
    && cp /tmp/sing-box-${SINGBOX_VER}-linux-${SINGBOX_ARCH}/sing-box /usr/bin/sing-box \
    && chmod +x /usr/bin/sing-box \
    && rm -rf /tmp/sing-box*

# Create configuration directory for sing-box
RUN mkdir -p /etc/sing-box

# Copy entrypoint script
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 1080

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD (ss -tlpn 2>/dev/null | grep -q ":1080") || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
