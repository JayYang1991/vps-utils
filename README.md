# VPS Utils - VPS 自动化部署与订阅转换工具箱

`vps-utils` 是一个面向 Linux VPS 运维、代理服务端部署（sing-box）、订阅自适应转换、内网穿透（cloudflared）以及优选 IP 管理的全套工具箱与实用项目合集。

---

## 📦 项目矩阵与组件概览

| 子项目目录 | 核心功能说明 | 推荐入口 / 关键脚本 | 详细文档链接 |
| --- | --- | --- | --- |
| [fhs-install-singbox](./fhs-install-singbox) | sing-box 服务端 FHS 部署与 VPS 远程/Vultr 自动化部署工具 | `setup_vps_server.sh`<br>`install-singbox-server.sh` | [fhs-install-singbox README](./fhs-install-singbox/README.md) |
| [singbox-sub-converter](./singbox-sub-converter) | 基于 Python/FastAPI 的 sing-box 自适应订阅转换服务 | `install.sh`<br>`pack.sh` | [singbox-sub-converter README](./singbox-sub-converter/README.md) |
| [subconverter](./subconverter) | 通用代理订阅格式转换后端服务（带 Systemd 一键安装脚本） | `install.sh` | [subconverter README](./subconverter/README.md) |
| [cloudflared-tunnel](./cloudflared-tunnel) | Cloudflare Official Agent 部署，实现 Cloudflare Tunnel 内网穿透服务 | `install.sh` | [cloudflared-tunnel README](./cloudflared-tunnel/README.md) |
| [cloudflare-warp](./cloudflare-warp) | Cloudflare Official WARP 客户端部署与 Systemd 服务一键配置 | `install.sh` | [cloudflare-warp README](./cloudflare-warp/README.md) |
| [preferred-ip-manager](./preferred-ip-manager) | Cloudflare Worker 订阅管理与 Telegram/CFST 自动化测速同步工具 | `sub-worker.js`<br>`process_ips.py` | [preferred-ip-manager README](./preferred-ip-manager/README.md) |

---

## 🚀 核心子项目简介

### 1. [fhs-install-singbox](./fhs-install-singbox) — sing-box 服务端与 VPS 自动化部署

符合 [Filesystem Hierarchy Standard (FHS)](https://en.wikipedia.org/wiki/Filesystem_Hierarchy_Standard) 标准的 `sing-box` (VLESS + Reality + Hysteria2) 服务端部署与 VPS 远程自动化运维工具包。

- **`install-singbox-server.sh`**：单机/本地一键安装、更新与配置 `sing-box` 服务端。
- **`update-singbox-keys.sh`**：服务端各项密钥与凭证（UUID, Reality 密钥对, Short ID, Hysteria2 密码）安全更新/重置工具。
- **`setup_vps_server.sh`**：远程 SSH 一键部署工具，支持直连 IP 部署或结合 Vultr API 自动创建 VPS 实例，自动注入公钥实现免密登录，默认一键安装全套组件。
- **`remove_vultr_instance.sh`**：Vultr 实例交互式查询与快速清理工具。

> 📖 **详细说明与完整选项**：参阅 [fhs-install-singbox/README.md](./fhs-install-singbox/README.md)

---

### 2. [singbox-sub-converter](./singbox-sub-converter) — sing-box 自适应订阅转换服务

基于 Python / FastAPI 开发的轻量级自适应订阅转换服务与 Web 管理界面：

- **自适应客户端识别**：根据 HTTP `User-Agent` 自动转换并输出 Clash YAML、sing-box JSON 或 Base64 编码订阅。
- **优选 IP 节点合并**：自动读取服务端 VLESS-gRPC 配置并动态拉取 Cloudflare 优选 IP 进行组合。
- **一键平滑部署**：内置 `install.sh` 自动化脚本，自动从仓库 Release 拉取打包产物（`singbox-sub-converter.tar.gz`）并配置后台 Systemd 服务。

> 📖 **详细说明与完整选项**：参阅 [singbox-sub-converter/README.md](./singbox-sub-converter/README.md)

---

### 3. [subconverter](./subconverter) — 订阅转换后端服务

基于 C++ 开发的高性能通用代理订阅格式转换后端，支持 Clash、Surge、Quantumult X、Loon、sing-box 等多种协议格式互转。

- **一键安装与端口配置**：提供 `install.sh` 部署脚本，支持 `-p / --port` 自定义端口，自动生成 `pref.ini` 配置文件并注册开机自启 Systemd 服务。

> 📖 **详细说明与完整选项**：参阅 [subconverter/README.md](./subconverter/README.md)

---

### 4. [cloudflared-tunnel](./cloudflared-tunnel) — Cloudflare Tunnel 内网穿透服务

官方 Cloudflare Agent (`cloudflared`) 的自动化安装与后台 Systemd 服务配置项目：

- **自动化多架构安装**：自动检测 `amd64` / `arm64` / `arm` / `386` 架构并拉取 Cloudflare 官方最新二进制文件。
- **双模式运行支持**：
  - **命名 Tunnel 模式**（`-t TOKEN`）：连接 Cloudflare Zero Trust，稳定发布公网 HTTPS 服务。
  - **Quick Tunnel 模式**（无 Token）：临时将本地服务（如 8000 或 25500 端口）映射为 `.trycloudflare.com` 公网域名。

> 📖 **详细说明与完整选项**：参阅 [cloudflared-tunnel/README.md](./cloudflared-tunnel/README.md)

---

### 5. [cloudflare-warp](./cloudflare-warp) — Cloudflare WARP 客户端部署

官方 Cloudflare WARP 客户端 (`cloudflare-warp` / `warp-cli`) 的自动化下载安装与 Systemd 服务配置：

- **自动配置官方 Apt / Yum 源**：自动检测 Debian/Ubuntu 或 RHEL/CentOS/Fedora 系统及其版本架构并安装官方软件包。
- **开机自启服务**：自动配置并启动后台 `warp-svc` Systemd 服务。
- **纯净安装**：仅负责软件环境的部署与服务启动，不擅自修改任何网络模式与账户注册，由用户根据需求通过 `warp-cli` 手动配置。

> 📖 **详细说明与完整选项**：参阅 [cloudflare-warp/README.md](./cloudflare-warp/README.md)

---

### 6. [preferred-ip-manager](./preferred-ip-manager) — 优选 IP 管理与测速同步工具

结合 Cloudflare Worker 无服务器架构与 Python 本地自动化测速同步全流程解决方案：

- **Cloudflare Worker 订阅服务 (`sub-worker.js`)**：提供实时优选 IP 订阅生成 (`/sub`)、暗黑拟物风格可视化管理后台 (`/admin`) 以及历史记录备份与 API 同步接口 (`/api/update`)。
- **Python 自动化工具链 (`process_ips.py` & `telegram_tool.py`)**：自动从 Telegram 抓取最新中转 IP，无干扰调起 `CloudflareSpeedTest` 测速，并将优选结果自动推送更新至 Worker 订阅节点。

> 📖 **详细说明与完整选项**：参阅 [preferred-ip-manager/README.md](./preferred-ip-manager/README.md)

---

## ⚡ 远程全套一键部署快速开始

只需在本地机器运行 `setup_vps_server.sh`，即可对远程 VPS（或自动创建的 Vultr 实例）完成包含 `sing-box` 服务端、`subconverter` 以及 `singbox-sub-converter` 的**全套组件自动部署**：

```bash
# 模式 A：直接通过 IP 部署远程 VPS
bash fhs-install-singbox/setup_vps_server.sh --ip <VPS_IP>

# 模式 B：使用 Vultr API 自动开机并部署
export VULTR_API_KEY="your_vultr_api_key"
bash fhs-install-singbox/setup_vps_server.sh --vultr
```

---

## 🌐 Cloudflare Tunnel 域名映射与网络公网发布指南

为了确保全套服务正常对外提供访问，以及客户端（如 Clash、sing-box）能够通过 **Cloudflare 优选 IP** 顺畅连接节点，**需要将 VPS 上的以下 3 个核心服务端口通过 Cloudflare (Tunnel) 映射至公网域名**：

### 端口与映射域名对照表

| 服务名称 | VPS 本地端口 | 推荐公网映射域名示例 | 说明与用途 |
| --- | --- | --- | --- |
| **`singbox-sub-converter`** | `8000` (HTTP) | `https://sub.yourdomain.com` | 自适应订阅转换 Frontend/API 界面，提供客户端订阅拉取与 Token 重置。 |
| **`subconverter`** | `25500` (HTTP) | `https://subapi.yourdomain.com` | 后端高级订阅转换引擎 API，处理通用协议模板转换。 |
| **`sing-box (vless-grpc)`** | `8088` (gRPC/HTTPS) | `https://grpc.yourdomain.com` | `vless-grpc` 协议入站端口。映射后供 Clash/sing-box 客户端通过 Cloudflare 优选 IP 直接连接中转。 |

---

### 1. 使用 Cloudflare Zero Trust 控制台配置 (GUI 推荐)

在 [Cloudflare Zero Trust 控制台](https://one.dash.cloudflare.com/) -> **Networks** -> **Tunnels** 中，点击对应的 Tunnel 并添加 **Public Hostnames**：

1. **自适应订阅转换服务 (`singbox-sub-converter`)**：
   - Subdomain: `sub` | Domain: `yourdomain.com`
   - Service: `HTTP` -> `localhost:8000`
2. **订阅转换后端服务 (`subconverter`)**：
   - Subdomain: `subapi` | Domain: `yourdomain.com`
   - Service: `HTTP` -> `localhost:25500`
3. **sing-box gRPC 节点入站 (`vless-grpc`)**：
   - Subdomain: `grpc` | Domain: `yourdomain.com`
   - Service: `HTTPS` -> `localhost:8088`
   - **Additional application settings**: 开启 **TLS** -> **No TLS Verify** (忽略本地自签证书校验)

---

### 2. 使用 Cloudflare Tunnel 本地配置文件配置 (`config.yml`)

若在 VPS 上使用本地 `/etc/cloudflared/config.yml` 运行，示例如下：

```yaml
tunnel: <YOUR-TUNNEL-UUID>
credentials-file: /etc/cloudflared/<YOUR-TUNNEL-UUID>.json

ingress:
  # 1. singbox-sub-converter 自适应订阅前端与 API (端口 8000)
  - hostname: sub.yourdomain.com
    service: http://localhost:8000

  # 2. subconverter 转换后端 API (端口 25500)
  - hostname: subapi.yourdomain.com
    service: http://localhost:25500

  # 3. sing-box vless-grpc 节点入站 (端口 8088，用于优选 IP 节点转发)
  - hostname: grpc.yourdomain.com
    service: https://localhost:8088
    originRequest:
      noTLSVerify: true

  # 默认 404 响应
  - service: http_status:404
```

> 💡 **提示**：公网域名映射完成后，只需将域名配置填入 `singbox-sub-converter` 后端，客户端获取订阅时即可自动获得带有 Cloudflare 优选 IP 且经 CDN 加速的 `vless-grpc` 节点。

---

## 📂 仓库目录结构

```text
vps-utils/
├── README.md                           # 本统一说明文档
├── fhs-install-singbox/                # sing-box 服务端与 VPS 自动化运维脚本
│   ├── README.md                      # fhs-install-singbox 详细指南
│   ├── setup_vps_server.sh            # 远程 VPS 自动化部署脚本
│   ├── install-singbox-server.sh      # sing-box 服务端本地安装脚本
│   └── singbox_server_config.json     # sing-box 服务端配置模板
├── singbox-sub-converter/              # sing-box 自适应订阅转换服务
│   ├── README.md                      # singbox-sub-converter 详细指南
│   ├── install.sh                     # 自动安装/更新脚本
│   ├── pack.sh                        # 自动化打包脚本
│   └── app/                           # FastAPI 后端与前端静态文件
├── subconverter/                       # 订阅转换后端程序
│   ├── README.md                      # subconverter 安装指南
│   └── install.sh                     # 自动化安装与端口配置脚本
├── cloudflared-tunnel/                 # Cloudflare Tunnel 内网穿透服务
│   ├── README.md                      # cloudflared-tunnel 安装指南
│   └── install.sh                     # 自动化安装与 Systemd 服务部署脚本
└── preferred-ip-manager/               # 优选 IP 管理与测速工具
    ├── README.md                      # preferred-ip-manager 详细指南
    ├── sub-worker.js                  # Cloudflare Worker 订阅服务
    ├── process_ips.py                 # 自动化测速与推送脚本
    └── telegram_tool.py               # Telegram 资源抓取脚本
```
