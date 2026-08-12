FROM ubuntu:latest

LABEL maintainer="JayYang"
LABEL description="Cloudflare WARP with Zero Trust & Sing-box SOCKS5 Proxy Container"

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies required for cloudflare-warp and sing-box
RUN apt-get update && apt-get install -y \
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

# Install sing-box
RUN curl -fsSL https://sing-box.app/install.sh | sh

# Create configuration directory for sing-box
RUN mkdir -p /etc/sing-box

# Copy entrypoint script
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 1080

ENTRYPOINT ["/docker-entrypoint.sh"]
