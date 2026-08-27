# Cloudflare Tunnel & VPS 出口 NAT 转发自动化部署指南

本目录提供面向 **目标端 / 末端 VPS** 的 Cloudflare 边缘网络连接与出口转发全套解决方案，包含 **Cloudflare Official Agent (`cloudflared`)** 自动化安装部署以及 **Zero Trust 出口 NAT MASQUERADE 转发配置 (`setup-cloudflare-one.sh`)**。

---

## 🌐 核心功能与架构定位

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

1. **入站隧道穿透 (Inbound Tunnel)**：在末端 VPS 上部署 `cloudflared`，将本地服务（如 `singbox-sub-converter`、`subconverter`、`sing-box` gRPC 节点）安全发布至公网公共域名，无需开放 VPS 防火墙入站端口。
2. **出站出口网关 (Exit Node / NAT Gateway)**：通过 `setup-cloudflare-one.sh` 开启内核 IP 转发与 `iptables` NAT MASQUERADE，配合 Zero Trust Private Network CIDR（如 `0.0.0.0/0`），使团队 WARP 流量穿透至该 VPS 并以 VPS 原生公网 IP 访问互联网。

---

## 🚀 第一章：安装 cloudflared 实现隧道穿透 (Inbound Tunnel)

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

### 3. VPS 端一键自动化安装与部署 (`install.sh`)

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

### 4. `install.sh` 参数与环境变量说明

| 参数选项 | 环境变量 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- |
| `-t, --token` | `CLOUDFLARED_TOKEN` | (空) | Cloudflare Zero Trust 分配的 Tunnel 认证密钥 Token |
| `-u, --url` | `LOCAL_SERVICE_URL` | `http://localhost:8000` | Quick Tunnel 模式下穿透的目标本地服务地址 |
| `-h, --help` | - | - | 显示帮助菜单 |

---

### 5. cloudflared 日常管理与运维

| 操作目标 | 执行命令 |
| :--- | :--- |
| **查看服务状态** | `sudo systemctl status cloudflared` |
| **追踪实时运行日志** | `sudo journalctl -u cloudflared -f` |
| **重启隧道服务** | `sudo systemctl restart cloudflared` |
| **停止隧道服务** | `sudo systemctl stop cloudflared` |
| **配置文件位置** | `/etc/cloudflared/config.yml` 与 `/etc/systemd/system/cloudflared.service` |

---

## 🖥️ 第二章：目标端 VPS 出口 NAT 转发配置 (Exit Node / NAT Gateway)

### 1. 核心应用场景与原理
当您需要将 **境外/特定 VPS（如香港、日本、美国 VPS）配置为 Cloudflare Zero Trust 的指定流量出口节点 (Exit Node / NAT Gateway)** 时使用：
* 客户端设备安装 WARP 客户端并加入团队后，所有出海流量或指定分流流量在 Cloudflare 骨干网内部传输，最终由该 VPS 的公网 IP 发出访问互联网；
* 目标网站看到的访问来源 IP 即为该 VPS 的原生公网 IP（可完美用于解锁 ChatGPT、Netflix、Disney+ 或特定区域限制服务）。

---

### 2. VPS 宿主机端一键配置 (`setup-cloudflare-one.sh`)

配套脚本 [`setup-cloudflare-one.sh`](./setup-cloudflare-one.sh) 会自动开启内核 IPv4/IPv6 转发，注入 `iptables` NAT MASQUERADE 规则，并配置 **Systemd 服务 + netfilter 规则双重开机持久化**，彻底解决 Linux 重启后 NAT 规则失效的问题。

#### 远程一键执行：
```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/cloudflared-tunnel/setup-cloudflare-one.sh) --setup
```

#### 本地执行命令速查：

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

### 3. `setup-cloudflare-one.sh` 参数选项说明

| 参数选项 | 说明 |
| :--- | :--- |
| `-c, --setup, --enable` | 开启并配置 VPS 上 Cloudflare One NAT 转发规则 (含开机持久化服务) |
| `-u, --unset, --disable` | 清除并还原 VPS 上 Cloudflare One NAT 转发规则 (并清理开机服务) |
| `-s, --status` | 查看当前内核转发、iptables NAT 与 Systemd 持久化服务状态 |
| `-i, --interface <IF>` | 指定 VPS 的外网物理网卡名称 (默认自动检测，如 `eth0`, `ens3`) |
| `-w, --warp-if <IF>` | 指定入站隧道网卡名称 (默认: `auto`。若存在 `warp0` 则绑定 `warp0`，否则使用 `any` 通用转发) |
| `-h, --help` | 显示帮助信息 |

---

### 4. Cloudflare Zero Trust 控制台侧完整联动配置说明

完成 VPS 端的 NAT 转发配置后，需在 Cloudflare Zero Trust 控制台完成 Tunnel Private Network CIDR 路由、Service Token、设备注册放行规则、Split Tunnels 分流策略以及 Gateway Egress 出口路由策略的配置。

> 📖 **控制台详细操作指引**：
> 有关 Private Network CIDR 添加（`0.0.0.0/0`）、Service Token 生成、Device Enrollment 放行规则、Split Tunnels 模式配置与 Egress 出口策略绑定的详细图文操作步骤，请参阅根目录文档 [附录：Cloudflare Zero Trust 控制台完整配置指南](../README.md#附录cloudflare-zero-trust-控制台完整配置指南)。

---

## 📁 附录：文件与脚本功能对照表

| 脚本 / 文件 | 核心功能 | 适用场景 |
| :--- | :--- | :--- |
| **`install.sh`** | 自动安装 `cloudflared` 二进制与 Systemd 服务 | **目标端 VPS**：实现入站内网穿透与公网服务发布 |
| **`setup-cloudflare-one.sh`** | 配置内核 IP 转发与 iptables NAT 出口规则 | **目标端 VPS**：将 VPS 配置为 Zero Trust 出口节点 (Exit Node / NAT Gateway) |
