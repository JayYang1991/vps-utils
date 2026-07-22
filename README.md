# VPS Utils - VPS 自动化部署与订阅转换工具箱

`vps-utils` 是一个面向 Linux VPS 运维、代理服务端部署（sing-box）、订阅自适应转换以及优选 IP 管理的全套工具箱与实用项目合集。

---

## 📦 项目矩阵与组件概览

| 子项目目录 | 核心功能说明 | 推荐入口 / 关键脚本 | 详细文档链接 |
| --- | --- | --- | --- |
| [fhs-install-singbox](./fhs-install-singbox) | sing-box 服务端 FHS 部署与 VPS 远程/Vultr 自动化部署工具 | `setup_vps_server.sh`<br>`install-singbox-server.sh` | [fhs-install-singbox README](./fhs-install-singbox/README.md) |
| [singbox-sub-converter](./singbox-sub-converter) | 基于 Python/FastAPI 的 sing-box 自适应订阅转换服务 | `install.sh`<br>`pack.sh` | [singbox-sub-converter README](./singbox-sub-converter/README.md) |
| [subconverter](./subconverter) | 通用代理订阅格式转换后端服务（带 Systemd 一键安装脚本） | `install.sh` | [subconverter README](./subconverter/README.md) |
| [preferred-ip-manager](./preferred-ip-manager) | Cloudflare Worker 订阅管理与 Telegram/CFST 自动化测速同步工具 | `sub-worker.js`<br>`process_ips.py` | [preferred-ip-manager README](./preferred-ip-manager/README.md) |

---

## 🚀 核心子项目简介

### 1. [fhs-install-singbox](./fhs-install-singbox) — sing-box 服务端与 VPS 自动化部署

符合 [Filesystem Hierarchy Standard (FHS)](https://en.wikipedia.org/wiki/Filesystem_Hierarchy_Standard) 标准的 `sing-box` (VLESS + Reality + Hysteria2) 服务端部署与 VPS 远程自动化运维工具包。

- **`install-singbox-server.sh`**：单机/本地一键安装、更新与配置 `sing-box` 服务端。
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

### 4. [preferred-ip-manager](./preferred-ip-manager) — 优选 IP 管理与测速同步工具

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
└── preferred-ip-manager/               # 优选 IP 管理与测速工具
    ├── README.md                      # preferred-ip-manager 详细指南
    ├── sub-worker.js                  # Cloudflare Worker 订阅服务
    ├── process_ips.py                 # 自动化测速与推送脚本
    └── telegram_tool.py               # Telegram 资源抓取脚本
```
