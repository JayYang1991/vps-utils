FROM ubuntu:24.04

LABEL maintainer="JayYang"
LABEL description="Cloudflare Access TCP Client Forwarder Container"

ENV DEBIAN_FRONTEND=noninteractive

# 安装基础运行依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    procps \
    tini \
    iproute2 \
    net-tools \
    && rm -rf /var/lib/apt/lists/*

# 自动检测系统架构并下载安装官方最新版 cloudflared 二进制（支持备用镜像源加速）
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in \
         amd64) CF_ARCH="amd64" ;; \
         arm64|aarch64) CF_ARCH="arm64" ;; \
         armhf|armv7l) CF_ARCH="arm" ;; \
         i386|i686) CF_ARCH="386" ;; \
         *) CF_ARCH="amd64" ;; \
       esac \
    && echo "正在为架构 ${CF_ARCH} 下载官方最新版 cloudflared..." \
    && (curl -fsSL -o /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" || \
        curl -fsSL -o /usr/local/bin/cloudflared "https://ghfast.top/https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" || \
        curl -fsSL -o /usr/local/bin/cloudflared "https://mirror.ghproxy.com/https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}") \
    && chmod +x /usr/local/bin/cloudflared \
    && cloudflared --version

# 拷贝并设置容器启动入口脚本
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/docker-entrypoint.sh"]
