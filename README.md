# VPS Utils - VPS 自动化部署与订阅转换工具箱

`vps-utils` 是一个面向 Linux VPS 运维、代理服务端部署（sing-box）、Cloudflare 边缘网络协同（Zero Trust / Tunnel / 优选 IP）、订阅自适应转换以及安全中转的全套工具箱与实用项目合集。

---

## 🌐 整体系统与双流分离架构

整个系统在架构上清晰地划分为 **订阅管理控制流** 与 **业务数据代理流** 两套独立通道：

---

### 1. 订阅管理与自适应分发流程 (Subscription Workflow)

```text
[ 用户终端 (Clash / sing-box / Surge / 移动端) ]
                       │
                       ▼ (1. 请求自适应订阅: https://sub.yourdomain.com/sub?token=xxx)
[ Cloudflare Tunnel 公共域名: sub.yourdomain.com ]
                       │
                       ▼ (安全反向代理进入 VPS 本地)
┌──────────────────────────────────────────────────────────────┐
│                    singbox-sub-converter                     │
│                   (自适应订阅核心服务, 端口 8000)               │
└──────────────┬───────────────────────────────▲───────────────┘
               │ (调用格式转换)                 │ (拉取实时优选 IP 节点池)
               ▼                               │
┌────────────────────────────┐    ┌────────────┴─────────────┐
│        subconverter        │    │   preferred-ip-manager   │
│ (通用转换后端引擎, 端口 25500)│    │ (Cloudflare Pages/Worker)│
└────────────────────────────┘    └──────────────────────────┘
               │
               ▼ (2. 动态聚合：基础节点 + 优选 IP 节点 + 自动清理空组，分发给客户端)
[ 代理客户端成功加载节点列表 ]
```

---

### 2. 代理数据流量转发路径 (Data Traffic Workflow)

系统支持 **两种独立的客户端出海代理访问路径**：

#### 模式 A：Clash / sing-box 等代理客户端访问路径 (优选 IP + Tunnel 穿透)
```text
[ 代理客户端 (Clash / sing-box / Shadowrocket 等) ]
                       │
                       ▼ (1. 客户端发起代理连接)
[ Cloudflare 优选 IP (Anycast 全球加速节点) ]
                       │
                       ▼ (2. Cloudflare 骨干网络 CDN 高速路由)
[ Cloudflare Tunnel (grpc.yourdomain.com 隧道安全穿透) ]
                       │
                       ▼ (3. 安全长连接送达末端 VPS)
[ 代理末端 VPS: sing-box (vless-grpc 协议, 本地 8088 端口) ]
                       │
                       ▼ (4. VPS 本地出站访问外部网络)
[ 目标国际互联网 (Google / YouTube / GitHub / AI 等) ]
```

#### 模式 B：Cloudflare WARP 客户端 / 本地 SOCKS5 访问路径 (Zero Trust + VPS 出口 NAT)

Cloudflare WARP 客户端出海访问完整拆解为以下 **4 个步骤**：

```text
[ 官方 WARP 客户端 / 本地 Docker SOCKS5 代理 (127.0.0.1:1080) ]
                       │
                       ▼ 1. 客户端通过加密隧道接入 (WireGuard / MASQUE 协议接入 Zero Trust 骨干网)
[ Cloudflare Zero Trust 全球网络 (Gateway / Access) ]
                       │
                       ▼ 2. Cloudflare 通过配置的 Egress 路由策略定向转发至末端 VPS
[ Cloudflare Tunnel / Connector (接收 Zero Trust 进站流量) ]
                       │
                       ▼ 3. VPS 将进入 cloudflared 的流量转发至实际出口网卡
                            (setup-cloudflare-one.sh 自动识别物理网卡如 eth0 并配置 iptables NAT MASQUERADE)
[ VPS 宿主机物理出口网卡 (eth0 / ens3) ]
                       │
                       ▼ 4. 以 VPS 原生公网 IP 访问国际互联网
[ 目标国际互联网 (完美解锁流媒体 / ChatGPT / Claude / 区域原生 IP 验证) ]
```

#### 模式 C：Cloudflare Access TCP 客户端本地安全转发路径 (Zero Trust TCP + 本地端口映射)

适用于在代理客户端/内网机器上安全直连受 Cloudflare Access 保护的私有 TCP 服务（影视服/Emby/Jellyfin/SSH等）：

```text
[ 本地播放器 / 客户端应用 (如 Emby / Infuse / 浏览器, 访问 127.0.0.1:5000) ]
                       │
                       ▼ 1. 连接本地转发端口 (由 cloudflare-access-tcp 容器监听)
[ cloudflare-access-tcp 容器 (cloudflared access tcp, Systemd 自启守护) ]
                       │
                       ▼ 2. 携带 Service Token 建立加密 WSS 隧道直连 Cloudflare
[ Cloudflare Zero Trust 边缘网络 (Access TCP 策略自动鉴权) ]
                       │
                       ▼ 3. 安全穿透隧道长连接到达目标后端
[ 远程服务端 (Cloudflare Tunnel 接入的目标 TCP 影视/私有服务) ]
```

---

## 🚀 第一章：VPS 端到端自动化部署全流程

遵循以下 7 个标准步骤，即可在代理末端 VPS 上搭建起一套具备 **高防封锁、多协议支持、Cloudflare Tunnel 内网穿透、Zero Trust 出口 NAT 转发与自适应订阅分发** 的完整服务闭环。

> 🛡️ **核心安全设计原则**：
> **`singbox-sub-converter`** 与 **`subconverter`** 服务在 VPS 本地仅监听内部回环/本地端口，**绝不直接在 VPS 防火墙暴露公网端口**，而是全部通过 **Cloudflare Tunnel 公共域名 (Public Hostnames)** 提供公网 HTTPS 安全访问，享有免费自动 SSL、全球 CDN 加速与 WAF 防护。

---

### 步骤 1：在代理末端 VPS 上部署 sing-box

使用 [`fhs-install-singbox`](file:///home/jason/user_data/code/vps-utils/fhs-install-singbox) 脚本一键安装符合 FHS 规范的 `sing-box` 服务端（默认开放 VLESS+Reality `443`、Hysteria2 `123` 以及用于 CDN 优选接入的 `vless-grpc` `8088` 端口）：

```bash
# 在 VPS 宿主机以 root 权限运行
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/fhs-install-singbox/install-singbox-server.sh)
```

---

### 步骤 2：安装 cloudflared 并配置 Tunnel (为各服务绑定公网公共域名)

使用 [`cloudflared-tunnel`](file:///home/jason/user_data/code/vps-utils/cloudflared-tunnel) 建立安全隧道，**singbox-sub-converter 与 subconverter 均通过 Cloudflare Tunnel 公共域名对外提供公网访问**：

1. **VPS 宿主机一键安装 Tunnel 服务**：
   ```bash
   sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/cloudflared-tunnel/install.sh) -t <YOUR_CLOUDFLARED_TOKEN>
   ```
2. **在 [Cloudflare Zero Trust 控制台](https://one.dash.cloudflare.com/) 配置 Public Hostnames 公共域名映射**（详细图文步骤请参阅 [附录 A：Cloudflare Tunnel 创建与公共域名配置](#附录-a-cloudflare-tunnel-创建与公共域名配置-public-hostnames)）：

| 服务组件 | VPS 本地监听 | 推荐 Public Hostname 公共域名 | 对外作用与访问场景 |
| :--- | :--- | :--- | :--- |
| **`singbox-sub-converter`** | `HTTP://localhost:8000` | `https://sub.yourdomain.com` | **自适应订阅前端与 API**：供用户访问 Web 管理界面、各类代理客户端拉取订阅链接。 |
| **`subconverter`** | `HTTP://localhost:25500` | `https://subapi.yourdomain.com` | **通用订阅转换后端引擎**：对外提供标准格式转换 API，供前端或外部订阅转换请求调用。 |
| **`sing-box (vless-grpc)`** | `HTTPS://localhost:8088` | `https://grpc.yourdomain.com` | **gRPC 节点入站**：供客户端通过 Cloudflare 优选 IP 经 CDN 转发连接（开启 TLS `No TLS Verify`）。 |

---

### 步骤 3：在末端 VPS 上设置 NAT 转发与双重开机持久化

使用 [`cloudflare-zero-trust`](file:///home/jason/user_data/code/vps-utils/cloudflare-zero-trust) 中的 `setup-cloudflare-one.sh` 脚本，开启 VPS 内核 IP 转发并配置 `iptables` NAT MASQUERADE 规则，支持 Systemd + netfilter 双重开机自启：

```bash
# 自动检测物理外网网卡，一键开启 NAT 转发并配置开机持久化
sudo bash cloudflare-zero-trust/setup-cloudflare-one.sh --setup
```

---

### 步骤 4：在 Cloudflare 控制台配置 Zero Trust CIDR 路由与 Egress 出口策略

为了让加入 Zero Trust 团队的 WARP 客户端流量能够精准路由穿透至该末端 VPS 并以 VPS 原生 IP 出海，需在控制台配置私有网络 CIDR 与出口策略（详细图文步骤请参阅 [附录 A.3 CIDR 路由配置](#3-配置-private-network-私有网络-cidr-路由-让-warp-客户端流量转发至末端-vps) 与 [附录 B：Zero Trust 设备放行、分流与 Egress 出口路由配置](#附录-b-zero-trust-设备放行分流与-egress-出口路由配置)）：

1. **配置 Tunnel Private Network CIDR 路由**：在 Tunnel 管理页面添加 `0.0.0.0/0`（接管 WARP 全量出海流量）或指定目标私有网段（如 `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`）；
2. **配置 Service Token 与设备注册放行规则**：在 `Access -> Service Tokens` 生成令牌，并在 `Settings -> WARP Client -> Device enrollment` 添加放行规则；
3. **配置 Split Tunnels 分流策略**：在 `Settings -> WARP Client -> Device profiles` 中配置 Exclude 或 Include 模式；
4. **配置 Gateway Egress 策略**：在 `Gateway -> Policies -> Egress Policies` 中添加出口规则，将流量定向匹配至该末端 VPS 出口。

---

### 步骤 5：在末端 VPS 上部署 subconverter (后端转换引擎)

使用 [`subconverter`](file:///home/jason/user_data/code/vps-utils/subconverter) 一键部署高性能 C++ 订阅转换程序，监听本地 `25500` 端口。该服务通过步骤 2 中绑定的 Cloudflare Tunnel 公共域名（如 `https://subapi.yourdomain.com`）对外提供转换能力：

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/subconverter/install.sh) -p 25500
```

---

### 步骤 6：在 Cloudflare Pages / Workers 上部署 preferred-ip-manager

使用 [`preferred-ip-manager`](file:///home/jason/user_data/code/vps-utils/preferred-ip-manager) 管理与动态更新 Cloudflare 优选 IP 池：

1. **部署 Worker / Pages 服务**（详细图文步骤请参阅 [附录 C：Cloudflare Workers / Pages 部署与环境变量配置](#附录-c-cloudflare-workers--pages-部署与环境变量配置)）：将 `sub-worker.js` 上传部署至 Cloudflare Workers 或 Pages，提供 `/sub` 优选订阅接口与 `/admin` 可视化后台。
2. **自动化测速与同步**：在本地或控制端运行 `process_ips.py`，从 Telegram 频道自动拉取 IP 并调用 `CloudflareSpeedTest` 测速，将最优 IP 自动推送至 Worker。

---

### 步骤 7：在末端 VPS 上部署 singbox-sub-converter 并通过公共域名获取订阅

使用 [`singbox-sub-converter`](file:///home/jason/user_data/code/vps-utils/singbox-sub-converter) 部署自适应订阅转换服务：

1. **一键安装服务**：
   ```bash
   sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/singbox-sub-converter/install.sh)
   ```
2. **通过 Cloudflare Tunnel 公共域名获取订阅并代理上网**：
   - 访问公共域名 `https://sub.yourdomain.com`，配置后端 `subconverter` 地址（可填写本地 `http://127.0.0.1:25500` 或公共 API 域名 `https://subapi.yourdomain.com`）与节点源；
   - 客户端（Clash Meta / sing-box / Shadowrocket / Loon / Surge）直接导入公共域名订阅链接（例如 `https://sub.yourdomain.com/sub?token=your_token`）；
   - 服务端自动识别客户端 User-Agent、注入优选 IP 节点并剔除无效空测速组，客户端一键连接即可畅通出海！

---

## 🛠️ 第二章：子项目矩阵与各类工具功能详解

| 子项目目录 | 核心功能定位 | 推荐入口 / 关键脚本 | 详细文档链接 |
| :--- | :--- | :--- | :--- |
| **[fhs-install-singbox](./fhs-install-singbox)** | sing-box 服务端 FHS 部署与 VPS 远程/Vultr 运维 | `setup_vps_server.sh`<br>`install-singbox-server.sh`<br>`update-singbox-keys.sh`<br>`update-singbox-sub.sh` | [fhs-install-singbox 详细指南](./fhs-install-singbox/README.md) |
| **[cloudflared-tunnel](./cloudflared-tunnel)** | Cloudflare Official Agent 部署，实现 Tunnel 内网穿透与公网服务发布 | `install.sh` | [cloudflared-tunnel 详细指南](./cloudflared-tunnel/README.md) |
| **[cloudflare-zero-trust](./cloudflare-zero-trust)** | Cloudflare Zero Trust (Cloudflare One) 套件：VPS 出口 NAT 转发、SOCKS5 客户端与诊断工具 | `setup-cloudflare-one.sh`<br>`docker-run.sh`<br>`test-masque.py`<br>`install.sh` | [cloudflare-zero-trust 详细指南](./cloudflare-zero-trust/README.md) |
| **[subconverter](./subconverter)** | 通用代理订阅格式转换后端服务（带 Systemd 一键安装与端口配置） | `install.sh` | [subconverter 详细指南](./subconverter/README.md) |
| **[preferred-ip-manager](./preferred-ip-manager)** | Cloudflare Worker 订阅管理、CDN 测速与 WARP Endpoint 优选同步工具 | `sub-worker.js`<br>`warp_tester.py`<br>`process_ips.py`<br>`telegram_tool.py` | [preferred-ip-manager 详细指南](./preferred-ip-manager/README.md) |
| **[singbox-sub-converter](./singbox-sub-converter)** | 基于 Python/FastAPI 的 sing-box 自适应订阅转换服务与 Web 管理后台 | `install.sh`<br>`uninstall.sh`<br>`pack.sh` | [singbox-sub-converter 详细指南](./singbox-sub-converter/README.md) |
| **[cloudflare-access-tcp](./cloudflare-access-tcp)** | 代理客户端 Cloudflare Access TCP 转发容器 (Ubuntu 24.04 + Systemd 自启) | `install.sh`<br>`docker-entrypoint.sh`<br>`Dockerfile` | [cloudflare-access-tcp 详细指南](./cloudflare-access-tcp/README.md) |

---

### 1. [fhs-install-singbox](./fhs-install-singbox) — 服务端部署与运维

- **`install-singbox-server.sh`**：符合 FHS 标准（`/usr/local/bin/sing-box`, `/etc/sing-box/config.json`）的本地一键安装与升级脚本。
- **`update-singbox-keys.sh`**：一键安全轮换 UUID、Reality 密钥对、Short ID 及 Hysteria2 证书密码。
- **`update-singbox-sub.sh` & `convert_sub_to_server.py`**：支持通过订阅链接更新配置并自动回退，支持 Client 客户端与 Server 转发网关（清除路由、过滤 Reality 节点并重写本地映射端口、生成 Reality 入站）两种模式。
- **`setup_vps_server.sh`**：控制端远程 SSH 一键部署全套服务，支持直接指定 IP 或通过 Vultr API 自动开机。
- **`remove_vultr_instance.sh`**：Vultr 实例交互式查询与快速销毁工具。

### 2. [cloudflared-tunnel](./cloudflared-tunnel) — 内网穿透与安全发布

- **`install.sh`**：自动识别 CPU 架构拉取 Cloudflare 官方最新二进制，支持 **命名 Tunnel 模式**（`-t TOKEN`）与 **Quick Tunnel 临时穿透模式**，一键注册 Systemd 服务。

### 3. [cloudflare-zero-trust](./cloudflare-zero-trust) — 出口转发与本地客户端

- **`setup-cloudflare-one.sh`**：自动开启 VPS 内核 IP 转发并配置 `iptables` NAT MASQUERADE 规则，支持 Systemd + netfilter 双重开机持久化。
- **`docker-run.sh`**：本地 Docker + Systemd SOCKS5 客户端管理脚本，内置策略路由自动隔离（防 Clash TUN 环路）与凭据安全存储。
- **`test-masque.py`**：纯 Python 标准库实现的 RFC 9000 QUIC Initial 握手与 MASQUE 连通性/时延诊断工具。
- **`install.sh`**：原生 Linux 环境配置官方软件源并安装 `cloudflare-warp` 客户端。

### 4. [subconverter](./subconverter) — 订阅转换引擎

- **`install.sh`**：一键下载并配置 `subconverter` 二进制，支持自定义端口并注册开机自启服务。

### 5. [preferred-ip-manager](./preferred-ip-manager) — 优选 IP 与 WARP Endpoint 管理

- **`sub-worker.js`**：Cloudflare Worker 订阅分发与 WARP 端点管理服务端，提供现代化暗黑拟物后台、历史备份及客户端配置生成。
- **`warp_tester.py`**：基于 RFC 9000 MASQUE/QUIC 的 Cloudflare WARP Anycast Endpoint 深度优选与测速引擎。
- **`process_ips.py`**：全流程集成工具，支持一键调度 CDN IP 测速同步或 WARP Endpoint 优选同步。
- **`telegram_tool.py`**：基于 MTProto 协议的 Telegram 文件极速多连接下载助手。

### 6. [singbox-sub-converter](./singbox-sub-converter) — 自适应订阅转换服务

- **自适应识别**：根据客户端 User-Agent 自动分发 Clash YAML、sing-box JSON 或通用 Base64 订阅。
- **动态节点合并**：自动聚合服务端配置与 Cloudflare 优选 IP 节点，自动清理空测速组。
- **`install.sh` & `uninstall.sh` & `pack.sh`**：提供一键自动化部署、一键卸载清理与 GitHub Actions 打包发布脚本。

### 7. [cloudflare-vless-proxy](./cloudflare-vless-proxy) — Cloudflare Worker VLESS 住宅中继代理与管理门户

- **VLESS 边缘中继**：基于 Cloudflare Worker 实现高性能 VLESS over WebSocket 代理，支持 SOCKS5 / HTTP 住宅代理中继出口。
- **动态优选与在线转换**：动态从 `sub.19910417.xyz` 拉取优选 IP，并通过 `subapi.19910417.xyz` 在线生成 Clash Meta 与 Sing-box 订阅。
- **KV 动态管理后台**：内置 `/admin` 控制台，支持可视化热更新 UUID、中继住宅网关、优选 IP 列表与密码。

### 8. [vpngate-residential-selector](./vpngate-residential-selector) — VPNGATE 纯净住宅 IP 优选与全自动保活系统

- **多源全量聚合与历史沉淀**：突破单接口 ~100 限制，并发聚合官方、每日镜像（`sites.aspx`）与社区节点池（180+ 全球节点），并在后台持续沉淀扩展。
- **Scamalytics 威胁分纯净筛选 (<20分)**：自动并发查询 `scamalytics.com` 威胁分，严格剔除机房/被标记 IP，仅保留 0~19 分纯净家庭宽带住宅 IP（威胁分越低加权分越高）。
- **按国家精选 TOP 5 住宅节点**：独立为每个国家筛选 TOP 5 最优纯净节点，并生成各分国代理文件（`proxies_JP.txt`、`proxies_US.txt` 等）与全局保活状态池。
- **真实应用层协议握手测速**：发送 OpenVPN 真实握手帧验证服务端状态，计算真实时延与丢包率，剔除假活节点。
- **7 国 Systemd 5 分钟自愈保活**：独立维护 US、JP、HK、SG、KR、DE、AU 7 国节点池，支持全量可用跳过刷新与失效 1 对 1 热替换。
- **本地住宅代理中继网桥 (`vpngate-bridge`)**：默认自动选用全局最优住宅节点，在本地开启 `socks5://127.0.0.1:10808` 与 `http://127.0.0.1:10809`；全面支持手动指定 IP:端口、国家、排名或自定义 OVPN。
- **全局快捷命令体系**：`vpngate-nodes`、`vpngate-service`、`vpngate-selector`、`vpngate-bridge`、`vpngate-daemon`。

### 9. [cloudflare-access-tcp](./cloudflare-access-tcp) — 代理客户端 Cloudflare Access TCP 转发容器

- **Ubuntu 24.04 编译生成**：基于 `ubuntu:24.04` 与官方 `cloudflared` 二进制，编译全程使用宿主机网络 (`--network host`)。
- **多端口并发转发**：默认开启 2 个 TCP 转发端口（`5000` 与 `5001`）映射远程私有服务（`movies.19910417.xyz` / `movies1.19910417.xyz`），支持任意自定义域名与端口列表。
- **严格校验与凭据隔离**：内置 RFC 域名与 1-65535 端口严格校验，Service Token 凭据独立保存在 `chmod 600` 文件中。
- **Systemd 自启与全生命周期管理**：提供 `install.sh` 脚本，支持 `--install`、`--status`、`--logs`、`--test`、`--restart`、`--stop`、`--rebuild`、`--uninstall`。

---

## 📂 第三章：仓库目录结构与文件索引

```text
vps-utils/
├── README.md                           # 本统一说明文档 (部署流程与工具矩阵)
├── fhs-install-singbox/                # sing-box 服务端与 VPS 自动化运维脚本
│   ├── README.md                      # fhs-install-singbox 详细指南
│   ├── setup_vps_server.sh            # 远程 VPS 自动化部署脚本
│   ├── install-singbox-server.sh      # sing-box 服务端本地安装脚本
│   ├── update-singbox-keys.sh         # 服务端凭证/密钥安全更新工具
│   ├── update-singbox-sub.sh          # 订阅链接更新与回退脚本 (Client/Server 双模式)
│   ├── convert_sub_to_server.py       # 订阅转 Server 模式转换核心引擎
│   ├── remove_vultr_instance.sh       # Vultr 实例查询与清理工具
│   └── singbox_server_config.json     # sing-box 服务端配置模板
├── cloudflared-tunnel/                 # Cloudflare Tunnel 内网穿透服务
│   ├── README.md                      # cloudflared-tunnel 安装指南
│   └── install.sh                     # 自动化安装与 Systemd 服务部署脚本
├── cloudflare-zero-trust/              # Cloudflare Zero Trust 套件与 VPS 出口配置
│   ├── README.md                      # cloudflare-zero-trust 详细指南
│   ├── docker-run.sh                  # 容器与 Systemd 服务管理脚本
│   ├── install.sh                     # 客户端安装与 Systemd 服务部署脚本
│   ├── setup-cloudflare-one.sh        # Cloudflare One VPS NAT 转发配置脚本
│   ├── test-masque.py                 # MASQUE (QUIC) 协议协商与连通性测试工具
│   ├── Dockerfile                     # WARP + sing-box 容器构建文件
│   └── docker-entrypoint.sh           # 容器启动自愈入口脚本
├── subconverter/                       # 订阅转换后端程序
│   ├── README.md                      # subconverter 安装指南
│   └── install.sh                     # 自动化安装与端口配置脚本
├── preferred-ip-manager/               # 优选 IP 管理与测速工具
│   ├── README.md                      # preferred-ip-manager 详细指南
│   ├── sub-worker.js                  # Cloudflare Worker 订阅服务
│   ├── process_ips.py                 # 自动化测速与推送脚本
│   └── telegram_tool.py               # Telegram 资源抓取脚本
├── singbox-sub-converter/              # sing-box 自适应订阅转换服务
│   ├── README.md                      # singbox-sub-converter 详细指南
│   ├── install.sh                     # 自动安装/更新/卸载脚本
│   ├── uninstall.sh                   # 一键卸载与清理脚本
│   ├── pack.sh                        # 自动化打包脚本
│   └── app/                           # FastAPI 后端与前端静态文件
├── cloudflare-vless-proxy/             # Cloudflare Worker VLESS 住宅中继代理与管理门户
│   ├── README.md                      # cloudflare-vless-proxy 部署指南
│   ├── src/                           # Worker 源代码 (VLESS, KV Admin, 优选聚合)
│   ├── wrangler.toml                  # Cloudflare Worker 配置文件
│   └── build.js                       # 自动化打包与 AST 代码混淆管线
├── cloudflare-access-tcp/              # 代理客户端 Cloudflare Access TCP 转发容器
│   ├── README.md                      # cloudflare-access-tcp 详细指南
│   ├── install.sh                     # 一键安装、构建与 Systemd 容器管理脚本
│   ├── Dockerfile                     # Ubuntu 24.04 + cloudflared 容器构建文件
│   └── docker-entrypoint.sh           # 严格参数校验与多进程守护启动脚本
└── vpngate-residential-selector/       # VPNGATE 住宅 IP 优选与高并发测速工具
    ├── README.md                      # vpngate-residential-selector 说明指南
    ├── main.py                        # CLI 调度入口
    ├── fetcher.py                     # VPNGATE API 拉取与 CSV 解析
    ├── filter.py                      # 住宅网络与公网 IP 过滤器
    ├── tester.py                      # 高并发多轮 TCP 延迟与质量测速引擎
    ├── exporter.py                    # 结果文件与代理全路径导出器
    └── test_selector.py               # 自动化单元测试集
```

---

## 📖 附录：Cloudflare Zero Trust 控制台完整配置指南

本附录依据 Cloudflare 官方最新管理后台标准规范编写，涵盖 **Tunnel 穿透**、**Zero Trust 设备鉴权与出口路由** 以及 **Workers / Pages 优选 IP 节点部署** 的全流程控制台操作指引。

---

### 附录 A：Cloudflare Tunnel 创建与公共域名配置 (Public Hostnames)

#### 1. 创建命名 Tunnel 并获取 Token
1. 登录 [Cloudflare Zero Trust 控制台](https://one.dash.cloudflare.com/)。
2. 在左侧导航栏依次展开 **Networks** -> **Tunnels**。
3. 点击右上角 **Add a tunnel**。
4. 选择连接器类型为 **Cloudflare (cloudflared)**，点击 **Next**。
5. 输入 Tunnel 名称（例如 `vps-tunnel-main`），点击 **Save tunnel**。
6. 在安装命令展示区选择系统类型（如 **Debian / Ubuntu / CentOS**），在给出的命令中提取 `--token` 后的长字符串密钥（即 `<YOUR_CLOUDFLARED_TOKEN>`），用于在 VPS 执行一键安装。

#### 2. 配置 Public Hostnames 公共域名路由
进入已创建好的 Tunnel 管理详情页，切换至 **Public Hostname** 标签页，依次点击 **Add a public hostname** 添加各服务路由：

* **路由 1：singbox-sub-converter 订阅前端与 API**
  * **Subdomain**：`sub`（自定义，如 `sub`）
  * **Domain**：选择已托管在 Cloudflare 上的主域名（如 `example.com`）
  * **Service Type**：`HTTP`
  * **URL**：`localhost:8000`
  * 点击 **Save hostname**。

* **路由 2：subconverter 通用订阅转换后端引擎**
  * **Subdomain**：`subapi`
  * **Domain**：`example.com`
  * **Service Type**：`HTTP`
  * **URL**：`localhost:25500`
  * 点击 **Save hostname**。

* **路由 3：sing-box vless-grpc 节点入站 (用于 CDN 优选 IP 转发)**
  * **Subdomain**：`grpc`
  * **Domain**：`example.com`
  * **Service Type**：`HTTPS`
  * **URL**：`localhost:8088`
  * **Additional application settings**：展开 **TLS** -> 勾选 **No TLS Verify**（忽略本地自签名证书校验）。
  * 点击 **Save hostname**。

#### 3. 配置 Private Network 私有网络 CIDR 路由 (让 WARP 客户端流量转发至末端 VPS)
进入已创建好的 Tunnel 管理详情页，切换至 **Private Networks** 标签页，点击 **Add a private network**：
* **CIDR**：
  * **全局接管模式（全量出海）**：输入 `0.0.0.0/0`（接管所有通过该团队 WARP 客户端发起的 IPv4 公网流量）；
  * **定向分流模式（精准网段）**：输入指定的目标 CIDR 网段（例如 VPS 内网段 `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16` 或指定受限目标服务 IP 段）。
* **Description**：（可选）例如 `vps-exit-node-routing`。
* 点击 **Save network** 保存。
* **生效机制**：配置完成后，加入该 Zero Trust 团队的 WARP 客户端在访问该 CIDR 范围内的目标时，流量将由 Cloudflare 骨干网直接通过此 Tunnel 转发至末端 VPS，配合 VPS 本地的 `setup-cloudflare-one.sh` NAT MASQUERADE 规则完成原生 IP 出海。

---

### 附录 B：Zero Trust 设备放行、分流与 Egress 出口路由配置

#### 1. 获取团队名称 (Team Name)
* 登录 [Cloudflare Zero Trust 控制台](https://one.dash.cloudflare.com/)，在控制台首页或设置中查看团队专属域名：`<your-team-name>.cloudflareaccess.com`，其中的 **`your-team-name`** 即为团队标识。

#### 2. 创建 Service Token 机器认证令牌
1. 在控制台左侧导航栏点击 **Access** -> **Service Tokens**。
2. 点击右上角 **Create Service Token**。
3. 填入名称（例如 `vps-warp-client`），点击 **Generate token**。
4. 妥善保存弹出的 **Client ID** 和 **Client Secret**（Secret 仅显示一次）。

#### 3. 配置设备注册放行规则 (Device Enrollment Rules)
1. 在左侧导航栏点击 **Settings** -> **WARP Client**。
2. 找到 **Device enrollment** 卡片，点击 **Manage** 按钮。
3. 切换至 **Rules** 选项卡，点击 **Add a rule**：
   - **Rule name**：`Allow-Service-Token-Enrollment`
   - **Rule action**：选择 `Service Token`
   - **Selector**：选择 `Service Token`
   - **Value**：选择刚刚创建的 Service Token 名称
4. 点击 **Save rule** 保存。

#### 4. 配置 WARP Client 分流策略 (Split Tunnels)
1. 点击 **Settings** -> **WARP Client** -> 在 **Device profiles** 卡片中点击 `Default`（或指定 Profile）的 **Configure**。
2. 找到 **Split Tunnels** 设置项：
   * **Exclude 模式 (排除模式，推荐全局代理)**：
     列表中保留局域网与国内直连 IP（如 `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` 等），其余所有公网互联网流量均走 Zero Trust 隧道；
   * **Include 模式 (包含模式，精准分流)**：
     仅将需要通过 Zero Trust 代理的目标域名或 IP 填写进列表。

#### 5. 配置 Gateway Egress 出口路由策略 (指定 Exit Node)
1. 在左侧导航栏点击 **Gateway** -> **Policies** -> **Egress Policies**（或 **Network Policies**）。
2. 点击 **Add a policy** 添加出口规则：
   - **Policy Name**：`Route-via-VPS-Exit-Node`
   - **Traffic**：配置匹配条件（例如全量匹配 `Traffic == Any`，或指定用户邮箱/IP 网段）；
   - **Action**：选择 `Egress`；
   - **Egress target**：选择该末端 VPS 对应的 Exit Location 或绑定的 Cloudflare Tunnel 连接器。
3. 点击 **Save policy** 保存并确保规则置顶生效。

---

### 附录 C：Cloudflare Workers / Pages 部署与环境变量配置

#### 1. 创建 Worker 应用程序
1. 登录 [Cloudflare Dashboard 仪表盘](https://dash.cloudflare.com/)。
2. 在左侧导航栏点击 **Compute (Workers & Pages)** -> 点击 **Create application** -> 选择 **Create Worker**。
3. 输入 Worker 服务名称（例如 `preferred-ip-manager`），点击 **Deploy** 完成初始创建。

#### 2. 上传与部署脚本代码
1. 进入该 Worker 的管理页面，点击右上角 **Edit code**。
2. 将项目 [`preferred-ip-manager/sub-worker.js`](file:///home/jason/user_data/code/vps-utils/preferred-ip-manager/sub-worker.js) 的完整代码复制并替换编辑器中的原有代码。
3. 点击右上角 **Save and deploy** 完成部署。

#### 3. 创建并绑定 KV 数据库
1. 在左侧导航栏点击 **Storage & Databases** -> **KV** -> 点击 **Create a namespace**。
2. 命名为 `preferred_ip_kv` 并保存。
3. 返回刚创建的 Worker 页面，进入 **Settings** -> **Bindings**（或 **Variables and Secrets**） -> 点击 **Add binding**：
   - **Type**：选择 `KV Namespace`
   - **Variable name**：严格填写为 **`KV`**
   - **KV namespace**：选择刚刚创建的 `preferred_ip_kv`
4. 点击 **Save and deploy**。

#### 4. 配置环境变量与安全密钥
在 Worker 的 **Settings** -> **Variables and Secrets** 中添加以下变量：
* **`ADMIN`**：管理员后台登录密码（用于访问 `/admin`）；
* **`TOKEN`**：数据同步与订阅安全 Token（用于客户端 `/sub?token=...` 与测速工具 `/api/update` 推送）；
* **`SUB_SOURCE`**（可选）：上游节点订阅数据源 URL。

#### 5. 绑定自定义公网域名
1. 在 Worker 的 **Settings** -> **Domains & Routes** 中点击 **Add** -> 选择 **Custom Domain**。
2. 输入已托管在 Cloudflare 上的域名（例如 `cf-ips.yourdomain.com`），点击 **Add Custom Domain**，Cloudflare 会自动完成 DNS 解析与 SSL 证书签发。

