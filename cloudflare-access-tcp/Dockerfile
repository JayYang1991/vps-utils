FROM ubuntu:24.04

LABEL maintainer="JayYang"
LABEL description="Cloudflare Access TCP Client Forwarder with Auto Preferred IP & Health Check"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# 安装基础运行依赖与 Python 环境
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    procps \
    tini \
    iproute2 \
    net-tools \
    python3 \
    python3-requests \
    tzdata \
    tar \
    netcat-openbsd \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone \
    && rm -rf /var/lib/apt/lists/*

# 自动检测系统架构并下载安装官方最新版 cloudflared 二进制（支持多镜像加速）
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

# 自动检测系统架构并下载安装 CloudflareSpeedTest (cfst) 测速二进制
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in \
         amd64) CFST_ARCH="amd64" ;; \
         arm64|aarch64) CFST_ARCH="arm64" ;; \
         armhf|armv7l) CFST_ARCH="armv7" ;; \
         i386|i686) CFST_ARCH="386" ;; \
         *) CFST_ARCH="amd64" ;; \
       esac \
    && echo "正在为架构 ${CFST_ARCH} 下载 CloudflareSpeedTest (cfst)..." \
    && CFST_TAR="/tmp/cfst.tar.gz" \
    && (curl -fsSL -o "$CFST_TAR" "https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/cfst_linux_${CFST_ARCH}.tar.gz" || \
        curl -fsSL -o "$CFST_TAR" "https://ghfast.top/https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/cfst_linux_${CFST_ARCH}.tar.gz" || \
        curl -fsSL -o "$CFST_TAR" "https://mirror.ghproxy.com/https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/cfst_linux_${CFST_ARCH}.tar.gz") \
    && tar -zxf "$CFST_TAR" -C /tmp \
    && (mv -f /tmp/cfst_linux_${CFST_ARCH}/cfst /usr/local/bin/cfst 2>/dev/null || mv -f /tmp/cfst /usr/local/bin/cfst 2>/dev/null || true) \
    && rm -rf "$CFST_TAR" /tmp/cfst_linux_* \
    && chmod +x /usr/local/bin/cfst \
    && /usr/local/bin/cfst -v || true

WORKDIR /app

# 拷贝测速引擎、健康检测守护脚本
COPY speedtest_runner.py /app/speedtest_runner.py
COPY health_checker.py /app/health_checker.py
COPY docker-entrypoint.sh /docker-entrypoint.sh

RUN chmod +x /docker-entrypoint.sh /app/speedtest_runner.py /app/health_checker.py

ENTRYPOINT ["/usr/bin/tini", "--", "/docker-entrypoint.sh"]
