FROM ubuntu:24.04

LABEL maintainer="vpngate-residential-tools"
LABEL description="Ubuntu 24.04 with Sing-box 1.12.20 and OpenVPN over SOCKS proxy"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    SINGBOX_VERSION=1.12.20 \
    PYTHONUNBUFFERED=1

# Speed up APT downloads using Aliyun mirror
RUN if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
        sed -i -e 's/archive.ubuntu.com/mirrors.aliyun.com/g' \
               -e 's/security.ubuntu.com/mirrors.aliyun.com/g' \
               /etc/apt/sources.list.d/ubuntu.sources; \
    fi

# Install runtime dependencies and OpenVPN
RUN apt-get update && apt-get install -y --no-install-recommends \
    openvpn \
    iproute2 \
    iptables \
    curl \
    wget \
    ca-certificates \
    jq \
    python3 \
    python3-requests \
    python3-urllib3 \
    python3-socks \
    procps \
    net-tools \
    dnsutils \
    tzdata \
    tar \
    gzip \
    && rm -rf /var/lib/apt/lists/*

# Copy local sing-box package if present in bin/ (wildcard prevents build failure if bin/ is missing)
COPY [b]in* /tmp/bin/

# Install Sing-box 1.12.20 (use local cache or download)
RUN set -eux; \
    ARCH=$(dpkg --print-architecture); \
    case "${ARCH}" in \
        amd64) SB_ARCH="linux-amd64" ;; \
        arm64) SB_ARCH="linux-arm64" ;; \
        *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
    esac; \
    TAR_NAME="sing-box-${SINGBOX_VERSION}-${SB_ARCH}.tar.gz"; \
    if [ -f "/tmp/bin/${TAR_NAME}" ]; then \
        echo "Using local package /tmp/bin/${TAR_NAME}..."; \
        tar -xzf "/tmp/bin/${TAR_NAME}" -C /tmp; \
    elif [ -f "/tmp/bin/bin/${TAR_NAME}" ]; then \
        echo "Using local package /tmp/bin/bin/${TAR_NAME}..."; \
        tar -xzf "/tmp/bin/bin/${TAR_NAME}" -C /tmp; \
    else \
        echo "Downloading Sing-box from GitHub..."; \
        (wget -qO /tmp/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${TAR_NAME}" || \
         wget -qO /tmp/sing-box.tar.gz "https://ghproxy.net/https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${TAR_NAME}"); \
        tar -xzf /tmp/sing-box.tar.gz -C /tmp; \
    fi; \
    mv /tmp/sing-box-${SINGBOX_VERSION}-${SB_ARCH}/sing-box /usr/local/bin/sing-box; \
    chmod +x /usr/local/bin/sing-box; \
    rm -rf /tmp/sing-box* /tmp/bin; \
    sing-box version

WORKDIR /app

# Copy application scripts
COPY scripts/ /app/scripts/
COPY entrypoint.sh /app/entrypoint.sh

RUN chmod +x /app/entrypoint.sh /app/scripts/*.py /app/scripts/*.sh 2>/dev/null || true

VOLUME ["/config"]

ENTRYPOINT ["/app/entrypoint.sh"]
