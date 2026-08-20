# Cloudflare WARP & Zero Trust (Cloudflare One) 综合部署指南

本目录及配套工具提供基于 **Cloudflare Zero Trust (Cloudflare One)** 架构的完整 VPS 边缘网络解决方案，涵盖 **入站内网穿透**、**出站 Exit Node NAT 转发**、**本地 SOCKS5 代理客户端** 以及 **协议连通性测试诊断工具**。

---

## 🌐 整体架构体系

```text
                               ┌────────────────────────────────────────┐
                               │     Cloudflare Zero Trust 全球网络     │
                               └───────┬────────────────────────┬───────┘
                                       │                        │
               ┌───────────────────────┴──────┐          ┌──────┴──────────────────────┐
               │ 1. 入站穿透 (Inbound Tunnel) │          │ 2. 出站转发 (Exit Node NAT) │
               │   cloudflared 建立安全长连接  │          │   VPS 宿主机开启 IP 转发与   │
               │   无公网端口暴露 / 自带 CDN  │          │   iptables NAT MASQUERADE   │
               └───────────────┬──────────────┘          └──────────────┬──────────────┘
                               │                                        │
                               ▼                                        ▼
                   [ VPS 本地运行的应用服务 ]               [ 目标互联网 (显示 VPS 公网 IP) ]
                   (Web / API / SubConverter)             (解锁流媒体 / ChatGPT / 原生 IP)
```

---

## 🚀 第一章：VPS 安装 cloudflared 实现隧道穿透 (Inbound Tunnel)

### 1. 核心原理与优势
* **无需暴露公网端口**：`cloudflared` 作为轻量级守护进程，从 VPS 内部向 Cloudflare 边缘节点发起主动长连接（基于 QUIC / HTTP/2），VPS 本身**无需开放任何公网入站防火墙端口**，亦无需公网固定 IP。
* **原生安全与加速**：自带 Cloudflare CDN 全球加速、自动颁发更新 SSL 证书、DDoS 自动防护与 WAF 防护。
* **支持各类服务协议**：可穿透 HTTP/HTTPS 网站、TCP 服务、SSH、RDP 以及私有内网网段 (Private Network)。

---

### 2. Cloudflare Zero Trust 控制台配置说明

在 VPS 部署前，需在 Cloudflare Zero Trust 控制台创建 Tunnel 并获取连接凭证 Token，同时配置 Public Hostnames 域名路由。

> 📖 **控制台详细操作指引**：
> 有关创建 Tunnel、获取 `--token` 凭证、配置 Public Hostnames 域名映射（HTTP / HTTPS / gRPC No TLS Verify）的详细图文操作步骤，请参阅根目录文档 [附录：Cloudflare Zero Trust 控制台完整配置指南](../README.md#附录cloudflare-zero-trust-控制台完整配置指南)。

---

### 3. VPS 端一键自动化安装与部署

在 VPS 宿主机上以 `root` 权限（或 `sudo`）执行以下一键部署命令，脚本会自动适配 CPU 架构（x86_64 / arm64），自动下载官方最新版二进制，并注册为开机自启的 Systemd 服务：

#### 方式 A：命名 Tunnel 生产模式 (推荐，使用 Token)
```bash
# 远程一键安装并启动为系统服务
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/cloudflared-tunnel/install.sh) -t <YOUR_CLOUDFLARED_TOKEN>
```
或在克隆本仓库后于本地执行：
```bash
cd cloudflared-tunnel
sudo bash install.sh -t <YOUR_CLOUDFLARED_TOKEN>
```

#### 方式 B：Quick Tunnel 临时穿透模式 (无需 Token，快速测试)
若未提供 Token，脚本将自动配置为 Quick Tunnel 临时测试模式，直接将本地服务暴露并生成 `*.trycloudflare.com` 临时公网域名：
```bash
# 穿透本地默认 8000 端口 (singbox-sub-converter 服务)
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/cloudflared-tunnel/install.sh)

# 穿透指定本地服务地址 (例如 25500 端口)
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/cloudflared-tunnel/install.sh) -u http://localhost:25500
```

---

### 4. cloudflared 日常管理与运维

| 操作目标 | 执行命令 |
| :--- | :--- |
| **查看服务状态** | `sudo systemctl status cloudflared` |
| **追踪实时运行日志** | `sudo journalctl -u cloudflared -f` |
| **重启隧道服务** | `sudo systemctl restart cloudflared` |
| **停止隧道服务** | `sudo systemctl stop cloudflared` |
| **配置文件位置** | `/etc/cloudflared/config.yml` 与 `/etc/systemd/system/cloudflared.service` |

---

## 🖥️ 第二章：VPS 侧 Zero Trust 出口 NAT 转发配置 (Exit Node / NAT Gateway)

### 1. 核心应用场景与原理
当您需要将 **境外/特定 VPS（如香港、日本、美国 VPS）配置为 Cloudflare Zero Trust 的指定流量出口节点 (Exit Node / NAT Gateway)** 时使用：
* 客户端设备安装 WARP 客户端并加入团队后，所有出海流量或指定分流流量在 Cloudflare 骨干网内部传输，最终由该 VPS 的公网 IP 发出访问互联网；
* 目标网站看到的访问来源 IP 即为该 VPS 的原生公网 IP（可完美用于解锁 ChatGPT、Netflix、Disney+ 或特定区域限制服务）。

---

### 2. VPS 宿主机端一键配置 (`setup-cloudflare-one.sh`)

配套脚本 [`setup-cloudflare-one.sh`](file:///home/jason/user_data/code/vps-utils/cloudflare-zero-trust/setup-cloudflare-one.sh) 会自动开启内核 IPv4/IPv6 转发，注入 `iptables` NAT MASQUERADE 规则，并配置 **Systemd 服务 + netfilter 规则双重开机持久化**，彻底解决 Linux 重启后 NAT 规则失效的问题。

#### VPS 部署命令：

```bash
# 1. 自动检测物理外网网卡，一键配置 VPS 出口 NAT 转发并开启双重开机持久化 (推荐)
sudo bash setup-cloudflare-one.sh --setup

# 2. VPS 已安装官方 cloudflare-warp 客户端时，指定外网网卡 eth0 与 WARP 网卡 warp0 精确隔离转发
sudo bash setup-cloudflare-one.sh --setup -i eth0 -w warp0

# 3. 使用 cloudflared Connector 时，强制使用通用全局转发
sudo bash setup-cloudflare-one.sh --setup -w any

# 4. 查看当前 VPS 内核转发、Systemd 服务及 iptables 规则状态
sudo bash setup-cloudflare-one.sh --status

# 5. 清除并还原 VPS 上的 NAT 转发规则与开机持久化服务
sudo bash setup-cloudflare-one.sh --unset
```

---

### 3. Cloudflare Zero Trust 控制台侧完整联动配置说明

完成 VPS 端的 NAT 转发配置后，需在 Cloudflare Zero Trust 控制台完成 Service Token、设备注册放行规则、Split Tunnels 分流策略以及 Gateway Egress 出口路由策略的配置。

> 📖 **控制台详细操作指引**：
> 有关 Service Token 生成、Device Enrollment 放行规则、Split Tunnels 模式配置与 Egress 出口策略绑定的详细图文操作步骤，请参阅根目录文档 [附录：Cloudflare Zero Trust 控制台完整配置指南](../README.md#附录cloudflare-zero-trust-控制台完整配置指南)。

---

## 🧰 第三章：本地 SOCKS5 代理客户端与生态工具链

除入站穿透与 Exit Node 转发外，本项目还提供了丰富的客户端与辅助工具集：

---

### 工具 1：本地 SOCKS5 代理客户端 (Docker + Systemd + 策略路由隔离)

使用 [`docker-run.sh`](file:///home/jason/user_data/code/vps-utils/cloudflare-zero-trust/docker-run.sh) 脚本，可将 Cloudflare WARP 与 sing-box 容器打包为 Systemd 系统服务，对外暴露标准的 SOCKS5 代理端口（默认 `127.0.0.1:1080`），并自动管理 `172.17.0.0/16` 策略路由，防止与宿主机 Clash/Mihomo TUN 产生路由死循环。

#### 1. 架构流程
```text
[ 本地应用 / 局域网设备 ] 
         │ (SOCKS5 代理, 默认 127.0.0.1:1080)
         ▼
[ Docker 容器: sing-box (直连出站) ]
         │ (容器内部 TUN 虚拟网卡)
         ▼
[ Cloudflare WARP Daemon (Zero Trust 团队 / Service Token) ]
         │ (加密隧道 + 策略路由隔离)
         ▼
[ Cloudflare 全球 Zero Trust 网络 ] ──> [ 目标网站 / 互联网 ]
```

#### 2. 常用管理命令速查
```bash
# 一键安装为开机自启的 Systemd 服务 (使用 Zero Trust Service Token)
sudo bash docker-run.sh --install-service -t <TEAM> --service-token <ID>:<SECRET> -p 1080

# 启用 SOCKS5 账户密码鉴权
sudo bash docker-run.sh --install-service -t <TEAM> --service-token <ID>:<SECRET> -p 1080 -u myuser -w mypass

# 查看服务运行状态、容器状态与策略路由
sudo bash docker-run.sh --status

# 快速测试 SOCKS5 代理连通性 (自动调用 curl 请求 Cloudflare Trace)
sudo bash docker-run.sh --test

# 查看实时运行日志
sudo bash docker-run.sh --logs

# 平滑重启服务 (保留容器已有注册状态，秒级启动)
sudo bash docker-run.sh --restart

# 卸载 Systemd 服务 (清理容器、配置与策略路由)
sudo bash docker-run.sh --uninstall-service
```

#### 3. 常见客户端与开发环境接入配置
* **终端临时代理**：
  ```bash
  export ALL_PROXY="socks5h://127.0.0.1:1080"
  ```
* **Git 代理**：
  ```bash
  git config --global http.proxy "socks5h://127.0.0.1:1080"
  git config --global https.proxy "socks5h://127.0.0.1:1080"
  ```
* **Clash / Mihomo 配置文件片段**：
  ```yaml
  proxies:
    - name: "WARP-SOCKS5-Local"
      type: socks5
      server: 127.0.0.1
      port: 1080
  ```
* **sing-box 客户端出站 (`outbounds`)**：
  ```json
  {
    "type": "socks",
    "tag": "warp-socks5-out",
    "server": "127.0.0.1",
    "server_port": 1080
  }
  ```

---

### 工具 2：MASQUE (QUIC) 协议双阶段握手测试工具 (`test-masque.py`)

用于排查 WARP MASQUE (QUIC v1) 协议在特定 VPS / 物理网卡下的连通性与网络质量诊断工具 [`test-masque.py`](file:///home/jason/user_data/code/vps-utils/cloudflare-zero-trust/test-masque.py)：
* **纯 Python 标准库**：零第三方依赖，开箱即用；
* **RFC 9000 QUIC Initial 握手探测**：填充 1200 字节标准握手包，精确测量往返时延（RTT）与丢包情况；
* **支持物理网卡源 IP 绑定 (`-i / --ip`)**：绕过本地全局代理进行直连探测。

```bash
# 探测官方默认 Endpoint (162.159.197.2) 常用 MASQUE 端口 (443, 8443, 4500, 8095, 4443)
python3 test-masque.py -t 162.159.197.2

# 绑定物理网卡 IP 直连测试 (绕过本地 TUN 代理)
python3 test-masque.py -t 162.159.197.2 -i 172.19.4.28

# 批量测试多个 Anycast 优选 IP 与自定义端口
python3 test-masque.py -t 162.159.192.1,162.159.193.10,188.114.96.1 -p 8443,4443
```

---

### 工具 3：原生 Linux 官方 WARP 客户端安装脚本 (`install.sh`)

用于在原生 Linux 系统（Debian/Ubuntu/CentOS/Fedora）中一键配置官方 Apt/Yum 软件源并安装 `cloudflare-warp` 官方二进制：
```bash
sudo bash install.sh
```

---

## 📁 附录：文件与脚本功能对照表

| 脚本 / 文件 | 核心功能 | 适用场景 |
| :--- | :--- | :--- |
| **`cloudflared-tunnel/install.sh`** | 自动安装 `cloudflared` 二进制与 Systemd 服务 | **VPS 宿主机**：实现入站内网穿透与公网服务发布 |
| **`setup-cloudflare-one.sh`** | 配置内核 IP 转发与 iptables NAT 出口规则 | **VPS 宿主机**：将 VPS 配置为 Zero Trust 出口节点 (Exit Node) |
| **`docker-run.sh`** | Docker 容器构建、运行与 Systemd 服务封装 | **本地 / VPS**：运行 SOCKS5 代理客户端并管理策略路由 |
| **`cloudflare-warp-socks5.service`** | Systemd 服务 Unit 模板 (含策略路由隔离钩子) | **本地 / VPS**：Systemd 开机自启服务定义 |
| **`Dockerfile` & `docker-entrypoint.sh`** | 基于 Ubuntu 24.04 构建包含 WARP + sing-box 镜像 | **本地 / VPS**：容器化运行环境与自愈守护 |
| **`test-masque.py`** | MASQUE (QUIC v1) 协议双阶段握手与时延测试工具 | **网络诊断**：检测 Endpoint 连通性与 1200 字节 MTU |
| **`install.sh`** | 官方 Apt/Yum 软件源配置与原生 WARP 客户端安装 | **Linux 原生环境**：安装官方 `cloudflare-warp` |
