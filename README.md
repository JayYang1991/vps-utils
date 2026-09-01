# VPS Utils - VPS 自动化部署、住宅 IP 代理与订阅转换工具箱

`vps-utils` 是一个面向 Linux VPS 运维、代理服务端部署（sing-box）、Cloudflare 边缘网络协同（Zero Trust / Tunnel / 优选 IP）、VPNGate 纯净住宅 IP 链式代理池、中转节点订阅自适应转换以及安全中转的全套工具箱与实用项目合集。


---

## ⚡ 一键综合安装与管理 (Quick Start)

`vps-utils` 在根目录提供了统一的交互式与非交互式综合安装部署脚本 [`install.sh`](./install.sh)，支持按照 **目标 VPS**、**中转 VPS**、**Client 端** 三大角色一键完成全套组件的自动化安装、配置与全局生命周期管理：

```bash
# 方式 1：在 VPS 上通过 curl 极速拉取并启动交互式安装菜单
bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/install.sh)

# 方式 2：在克隆好的本地仓库目录下直接运行
sudo bash install.sh
```

### 🚀 按角色一键静默 / 命令行安装命令

| 部署角色 | 核心组件矩阵 | 一键标准安装命令 | 增强/全功能安装命令 |
| **目标 VPS (Target VPS)** | `sing-box` + `cloudflared-tunnel` + `subconverter` + `singbox-sub-converter` + `vpngate-singbox-openvpn` | `sudo ./install.sh -r target` | `sudo ./install.sh -r target` |
| **中转 VPS (Relay VPS)** | `sing-box` + `clash-singbox-sub-manager` + `cloudflare-access-tcp` + `preferred-ip-manager` | `sudo ./install.sh -r relay` | `sudo ./install.sh -r relay` |

### 🔑 预设环境变量参考 (可选 / 自动化静默安装前设置)

在执行 `sudo -E bash install.sh` 或通过 CI/CD / 脚本自动化部署前，可根据部署角色先在终端 `export` 对应环境变量。脚本在执行时会 **优先继承并自动填充** 这些变量，无需反复手动输入：

#### 1. 目标 VPS 模式环境变量 (`--role target`)
```bash
# 【必填】Cloudflare Tunnel 隧道凭据 (在 Cloudflare Zero Trust 控制台 Networks -> Tunnels 获取)
export TUNNEL_TOKEN="eyJhIjoi..."

# 【可选】sing-box Reality 伪装域名与网络参数 (留空则使用内置默认值或自动生成)
export SINGBOX_DOMAIN="dl.google.com"         # Reality SNI 伪装域名 (默认: dl.google.com)
export SINGBOX_SOCKS_PORT="10086"             # SOCKS5 入站监听端口 (默认: 10086)
export SINGBOX_SOCKS_USER="my_user"           # SOCKS5 认证账号 (默认: 自动随机生成)
export SINGBOX_SOCKS_PASS="my_password"       # SOCKS5 认证密码 (默认: 自动随机生成)
export SINGBOX_UUID="auto"                    # VLESS 用户 UUID (默认: 自动生成)

# 【可选】自适应订阅转换服务配置
export SERVER_IP="1.2.3.4"                    # 当前 VPS 公网 IP (用于节点订阅链接生成，默认自动获取)
export SUB_TOKEN="my_custom_token"            # 订阅链接鉴权 Token (默认: 自动生成专属 UUID)

# 【选装: --type full 纯净住宅代理】
export VPNGATE_COUNTRY="JP"                   # 住宅代理国家筛选代码 (默认: JP)
export SINGBOX_SUB_URL="https://..."          # VPNGate 节点上游前置代理订阅链接 (可选)
```

#### 2. 中转 VPS 模式环境变量 (`--role relay`)
```bash
# 【必填】Cloudflare Access Service Token 凭据 (用于穿透鉴权访问目标端/私有影视服务)
export CF_SERVICE_TOKEN_ID="xxx.access"       # Access Service Token Client ID
export CF_SERVICE_TOKEN_SECRET="yyy"          # Access Service Token Client Secret

# 【可选】Access TCP 转发目标域名与端口 (留空则使用内置默认: movies.19910417.xyz -> 5000, movies1.19910417.xyz -> 5001)
export DOMAINS="movies.domain.com,movies1.domain.com" # 自定义转发目标域名列表 (可选，逗号分隔)
export PORTS="5000,5001"                      # 自定义本地映射监听端口列表 (可选，逗号分隔)

# 【可选】中转 Clash 订阅管理器配置
export UPSTREAM_SUB_URL="https://sub.domain.com/sub?token=..." # 上游 Clash 订阅链接
export UPSTREAM_PROXY="socks5h://127.0.0.1:2080"               # 拉取上游订阅的前置代理 (默认: 本地住宅代理)
export ADMIN_USERNAME="admin"                 # 中转 Web 面板登录用户名 (默认: admin)
export ADMIN_PASSWORD="my_password"           # 中转 Web 面板登录密码 (默认: admin1234)
```

#### 3. Client 端模式环境变量 (`--role client`)
```bash
# 【必填项】Cloudflare Access Service Token 凭据与 Zero Trust Team 组织名称
export CF_SERVICE_TOKEN_ID="xxx.access"       # Access Service Token Client ID (必填)
export CF_SERVICE_TOKEN_SECRET="yyy"          # Access Service Token Client Secret (必填)
export WARP_TEAM_NAME="myteam"                # Cloudflare Zero Trust Team 组织名称 (必填)

# 【可选项】Access TCP 转发目标域名与端口 (留空则使用内置默认: movies.19910417.xyz -> 5000, movies1.19910417.xyz -> 5001)
export DOMAINS="movies.domain.com,movies1.domain.com" # 自定义转发目标域名列表 (可选，逗号分隔)
export PORTS="5000,5001"                      # 自定义本地映射端口列表 (可选，逗号分隔)
export SOCKS_PORT="1080"                      # WARP Docker SOCKS5 本地代理端口 (默认: 1080)

# 【选装: sing-box 客户端模式】
export SUB_URL="http://<目标VPS_IP>:8000/sub?token=..." # 客户端订阅链接
```

#### 4. 优选测速与通知推送环境变量 (`preferred-ip-manager`)
```bash
# Telegram 资源抓取凭据 (在 https://my.telegram.org 获取)
export TG_API_ID="1234567"                    # Telegram API ID
export TG_API_HASH="0123456789abcdef..."      # Telegram API HASH
export TG_SESSION_PATH="/var/lib/preferred-ip-manager/tg_session" # TG 登录 Session 文件路径

# Cloudflare DNS / 优选 IP 自动更新凭证
export CF_API_TOKEN="xxx"                     # Cloudflare API Token (需具备 Zone:DNS:Edit 权限)
export CF_ZONE_ID="yyy"                       # Cloudflare 托管区域 Zone ID
export CF_DOMAIN="proxy.domain.com"           # 自动更新 A/AAAA 解析记录的域名

# 测速前置代理
export PROXY="socks5h://127.0.0.1:2080"       # 抓取 Telegram 消息与测速时走的前置代理
```

#### 💡 配合环境变量一键静默部署示例
```bash
# 目标 VPS 带环境变量一键静默安装 (推荐使用 sudo -E 继承当前用户环境)
export TUNNEL_TOKEN="eyJhIjoi..."
sudo -E bash install.sh --role target -y

# Client 端带环境变量一键静默安装 (必填 Service Token 与 Team 组织名)
export CF_SERVICE_TOKEN_ID="xxx.access"
export CF_SERVICE_TOKEN_SECRET="yyy"
export WARP_TEAM_NAME="myteam"
sudo -E bash install.sh --role client -y
```

### 🛠️ 常用全局运维管理命令

脚本安装完成后会自动注册系统全局命令 `vps-utils`（别名 `vps-manager`）：

```bash
# 查看所有已安装组件的运行状态与端口监听
vps-utils status

# 快捷管理服务 (start / stop / restart / logs)
vps-utils restart all                    # 重启全部已部署组件
vps-utils restart cf-access-tcp          # 重启指定组件
vps-utils logs singbox-sub-converter     # 查看指定组件实时运行日志

# 一键卸载组件或全部清理
vps-utils -u all                         # 彻底卸载全部组件并清理环境
```

---

## 🌐 整体系统与全链路架构

整个系统在架构上划分为 **订阅管理控制流** 与 **业务数据代理流** 两套独立通道：

---

### 1. 订阅管理与自适应分发流程 (Subscription Workflow)

系统支持 **集中式云端分发** 与 **中转 VPS 本地独立分发** 两种工作流：

#### 流程 1：集中式自适应订阅分发 (面向标准 VPS 与公网客户端)

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

#### 流程 2：中转 VPS 本地独立订阅分发 (面向无法访问外部 Subapi 的受限/中转节点)

```text
[ 中转 VPS 本地 /etc/sing-box/config.json (VLESS / Hysteria2 / Trojan / Shadowsocks) ]
                               │
                               ▼ (1. 自动提取本机所有代理入站节点)
┌───────────────────────────────────────────────────────────────────────────┐
│                        clash-singbox-sub-manager                          │
│     (本地 Python 守护进程, 零外部 Subapi 依赖, 端口 8000 + Web 管理面板)     │
└──────────────┬───────────────────────────────────────────▲────────────────┘
               │ (2. 优先经本地代理拉取上游模板, 毫秒级回落直连)│ (动态 UUID 防盗刷 / 扫码)
               ▼                                           │
┌────────────────────────────┐                             │
│   上游 Clash 规则订阅模板    │                             │
└────────────────────────────┘                             │
               │                                           │
               ▼ (3. 订阅深度重构：注入节点选择组、协议排序优化、清理失效地域组)
[ 客户端 (Clash / Flclash / Shadowrocket 等) 扫码或通过专属 UUID 链接直接拉取 ]
```

---

### 2. 代理数据流量转发路径 (Data Traffic Workflow)

系统支持 **四种独立的客户端代理与出海访问路径**：

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
                            (cloudflared-tunnel/setup-cloudflare-one.sh 自动识别物理网卡如 eth0 并配置 iptables NAT MASQUERADE)
[ VPS 宿主机物理出口网卡 (eth0 / ens3) ]
                       │
                       ▼ 4. 以 VPS 原生公网 IP 访问国际互联网
[ 目标国际互联网 (完美解锁流媒体 / ChatGPT / Claude / 区域原生 IP 验证) ]
```

#### 模式 C：Cloudflare Access TCP 客户端本地安全转发路径 (Zero Trust TCP + 本地端口映射)

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

#### 模式 D：VPNGate + Sing-box + OpenVPN 链式纯净住宅 IP 代理出口路径 (Docker 容器 + 自动轮询容灾 + 每日更新)

```text
[ 宿主机/局域网应用程序 / 爬虫任务 / 分流代理客户端 (连接 SOCKS5 :2080) ]
                       │
                       ▼ (1. 请求发送至宿主机暴露的 2080 端口)
┌───────────────────────────────────────────────────────────────────────────┐
│               Docker 容器: vpngate-singbox-openvpn (Ubuntu 24.04)         │
│                                                                           │
│  外部 Inbound (public-socks-in, 0.0.0.0:2080)                            │
│     │                                                                     │
│     ▼ (2. Sing-box 路由绑定 tun0 网卡 openvpn-out)                         │
│  虚拟网卡 tun0 (OpenVPN 客户端隧道, route-nopull 保障宿主机默认路由安全)        │
│     │                                                                     │
│     ▼ (3. OpenVPN 出站流量走内部 SOCKS 127.0.0.1:1080)                     │
│  内部 Inbound (socks-in, 127.0.0.1:1080) -> Sing-box urltest 优选组       │
│     │                                                                     │
│     ▼ (4. 经由订阅优选节点建立隧道连接 VPNGate 目标节点)                   │
│  健康检测守护进程 (health_checker.py, 30s 探测, 失败自动按序轮询切换节点)   │
└──────────────────────────────────────┬────────────────────────────────────┘
                                       │
                                       ▼ (5. 最终经由纯净住宅 IP 访问互联网)
[ 全球纯净住宅 IP (Scamalytics 威胁分 < 20 / 日本/美国/韩国等) -> 目标互联网 ]

┌───────────────────────────────────────────────────────────────────────────┐
│               宿主机后台守护服务: vpngate-singbox-node-updater             │
│  - 每日北京时间 00:00~06:00 随机时刻自动运行 generate_ovpn.py 刷新节点池  │
│  - 自动并发查询 Scamalytics 过滤威胁分 < 20 的低风控住宅节点 (7天本地缓存) │
│  - 支持按国家代码精准筛选 (-c JP,US) 并自动重启 Docker 容器生效最新节点池   │
└───────────────────────────────────────────────────────────────────────────┘
```

---

## 🚀 第一章：VPS 端到端自动化部署全流程

遵循以下步骤，即可在 VPS 上搭建起一套具备 **高防封锁、多协议支持、Cloudflare Tunnel 内网穿透、Zero Trust 出口 NAT 转发、自适应订阅分发以及纯净住宅 IP 链式代理** 的完整服务闭环。

> 🛡️ **核心安全设计原则**：
> **`singbox-sub-converter`** 与 **`subconverter`** 服务在 VPS 本地仅监听内部回环/本地端口，**绝不直接在 VPS 防火墙暴露公网端口**，而是全部通过 **Cloudflare Tunnel 公共域名 (Public Hostnames)** 提供公网 HTTPS 安全访问，享有免费自动 SSL、全球 CDN 加速与 WAF 防护。

---

### 步骤 1：在代理末端 VPS 上部署 sing-box

使用 [`fhs-install-singbox`](./fhs-install-singbox) 脚本一键安装符合 FHS 规范的 `sing-box` 服务端（默认配置 VLESS+Reality `443` 住宅代理出口、`8443` 原生直连出口、SOCKS5 `10086` 入站认证以及用于 CDN 优选接入的 `vless-grpc` `8088` 端口）：

```bash
# 在 VPS 宿主机以 root 权限运行
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/fhs-install-singbox/install-singbox-server.sh)
```

---

### 步骤 2：安装 cloudflared 并配置 Tunnel (自动配置 VPS 出口 NAT 转发)

使用 [`cloudflared-tunnel`](./cloudflared-tunnel) 建立安全隧道（**`install.sh` 脚本在安装 `cloudflared` 的同时会自动调用 `setup-cloudflare-one.sh` 开启内核 IP 转发与 `iptables` NAT MASQUERADE 双重开机持久化**）：

1. **VPS 宿主机一键安装 Tunnel 服务与配置 NAT 转发**：
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

### 步骤 3 (独立管理/按需配置)：在末端 VPS 上独立管理 NAT 转发与双重开机持久化

> 💡 **提示**：步骤 2 中的 `install.sh` 已默认自动调用配置。如需单独查看状态、修改网卡或清除规则，可直接运行：

```bash
# 查看当前 VPS 内核转发、Systemd 服务及 iptables 规则状态
setup-cloudflare-one.sh --status

# 重新配置或指定特定网卡 (如 eth0 与 warp0)
setup-cloudflare-one.sh --setup -i eth0 -w warp0

# 清除并还原 NAT 转发规则与开机服务
setup-cloudflare-one.sh --unset
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

使用 [`subconverter`](./subconverter) 一键部署高性能 C++ 订阅转换程序，监听本地 `25500` 端口。该服务通过步骤 2 中绑定的 Cloudflare Tunnel 公共域名（如 `https://subapi.yourdomain.com`）对外提供转换能力：

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/subconverter/install.sh) -p 25500
```

---

### 步骤 6：在 Cloudflare Pages / Workers 上部署 preferred-ip-manager

使用 [`preferred-ip-manager`](./preferred-ip-manager) 管理与动态更新 Cloudflare 优选 IP 池：

1. **部署 Worker / Pages 服务**（详细图文步骤请参阅 [附录 C：Cloudflare Workers / Pages 部署与环境变量配置](#附录-c-cloudflare-workers--pages-部署与环境变量配置)）：将 `sub-worker.js` 上传部署至 Cloudflare Workers 或 Pages，提供 `/sub` 优选订阅接口与 `/admin` 可视化后台。
2. **自动化测速与同步**：在本地或控制端运行 `process_ips.py`，从 Telegram 频道自动拉取 IP 并调用 `CloudflareSpeedTest` 测速，将最优 IP 自动推送至 Worker。

---

### 步骤 7：在末端 VPS 上部署 singbox-sub-converter 并通过公共域名获取订阅

使用 [`singbox-sub-converter`](./singbox-sub-converter) 部署自适应订阅转换服务：

1. **一键安装服务**：
   ```bash
   sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/singbox-sub-converter/install.sh)
   ```
2. **通过 Cloudflare Tunnel 公共域名获取订阅并代理上网**：
   - 访问公共域名 `https://sub.yourdomain.com`，配置后端 `subconverter` 地址（可填写本地 `http://127.0.0.1:25500` 或公共 API 域名 `https://subapi.yourdomain.com`）与节点源；
   - 客户端（Clash Meta / sing-box / Shadowrocket / Loon / Surge）直接导入公共域名订阅链接（例如 `https://sub.yourdomain.com/sub?token=your_token`）；
   - 服务端自动识别客户端 User-Agent、注入优选 IP 节点并剔除无效空测速组，客户端一键连接即可畅通出海！

---

### 步骤 8 (选装)：在目标 VPS 上部署 VPNGate 链式住宅 IP 代理服务

使用 [`vpngate-singbox-openvpn`](./vpngate-singbox-openvpn) 在目标 VPS 上集成部署 Docker 容器化链式代理与宿主机自动更新守护进程，对外提供纯净住宅 IP SOCKS5 代理（默认映射 `:2080`）：

```bash
cd vpngate-singbox-openvpn

# 一键安装部署 (支持指定 Sing-box 订阅与国家过滤，例如日本 JP)
sudo ./install.sh -s "https://your-singbox-sub-url..." -p 2080 -c JP

# 安装完成后可通过全局命令管理
vpngate-tunnel status       # 查看当前激活住宅节点与出口 IP
vpngate-tunnel next-node    # 切换至下一个可用节点
vpngate-tunnel list-nodes   # 列出当前优质节点池
```

---

### 步骤 9 (选装)：在中转 VPS 上部署本地 Clash 订阅管理器 (零 Subapi 依赖)

使用 [`clash-singbox-sub-manager`](./clash-singbox-sub-manager) 在无法访问外部 Subapi 的受限中转 VPS 上部署本地轻量级订阅分发与注入服务：

```bash
cd clash-singbox-sub-manager

# 一键安装服务 (默认监听 8000 端口，自动提取本机 sing-box 入站节点)
sudo ./install.sh --port 8000 --proxy socks5h://127.0.0.1:2080

# 查看状态与终端专属订阅二维码
clash-singbox-sub-manager status
```

---

## 🛠️ 第二章：子项目矩阵与各类工具功能详解

| 子项目目录 | 核心功能定位 | 推荐入口 / 关键脚本 | 详细文档链接 |
| :--- | :--- | :--- | :--- |
| **[fhs-install-singbox](./fhs-install-singbox)** | sing-box 服务端 FHS 部署与 VPS 远程/Vultr 运维 | `setup_vps_server.sh`<br>`install-singbox-server.sh`<br>`update-singbox-keys.sh`<br>`update-singbox-sub.sh` | [fhs-install-singbox 详细指南](./fhs-install-singbox/README.md) |
| **[cloudflared-tunnel](./cloudflared-tunnel)** | Cloudflare Official Agent 部署与目标端 VPS 出口 NAT 转发配置，实现 Tunnel 内网穿透、公网服务发布与 Exit Node 出口网关 | `install.sh`<br>`setup-cloudflare-one.sh` | [cloudflared-tunnel 详细指南](./cloudflared-tunnel/README.md) |
| **[cloudflare-zero-trust](./cloudflare-zero-trust)** | Cloudflare Zero Trust (WARP) 客户端套件：Docker SOCKS5 代理客户端（策略路由隔离）、官方客户端与 MASQUE 诊断工具 | `docker-run.sh`<br>`test-masque.py`<br>`install.sh` | [cloudflare-zero-trust 详细指南](./cloudflare-zero-trust/README.md) |
| **[subconverter](./subconverter)** | 通用代理订阅格式转换后端服务（带 Systemd 一键安装与端口配置） | `install.sh` | [subconverter 详细指南](./subconverter/README.md) |
| **[preferred-ip-manager](./preferred-ip-manager)** | Cloudflare Worker 订阅管理、CDN 测速与 WARP Endpoint 优选同步工具 | `install.sh`<br>`process_ips.py`<br>`warp_tester.py`<br>`sub-worker.js` | [preferred-ip-manager 详细指南](./preferred-ip-manager/README.md) |
| **[singbox-sub-converter](./singbox-sub-converter)** | 基于 Python/FastAPI 的 sing-box 自适应订阅转换服务与 Web 管理后台 | `install.sh`<br>`uninstall.sh`<br>`pack.sh` | [singbox-sub-converter 详细指南](./singbox-sub-converter/README.md) |
| **[cloudflare-access-tcp](./cloudflare-access-tcp)** | 代理客户端 Cloudflare Access TCP 转发与自动优选 IP 容器 (每日凌晨测速 TOP 20 + 故障自动切换) | `install.sh`<br>`service.sh`<br>`health_checker.py` | [cloudflare-access-tcp 详细指南](./cloudflare-access-tcp/README.md) |

---

### 1. [fhs-install-singbox](./fhs-install-singbox) — 服务端部署与运维

- **`install-singbox-server.sh`**：符合 FHS 标准（`/usr/local/bin/sing-box`, `/etc/sing-box/config.json`）的本地一键安装与升级脚本。
- **`update-singbox-keys.sh`**：一键安全轮换 UUID、Reality 密钥对、Short ID 及 Hysteria2 证书密码。
- **`update-singbox-sub.sh` & `convert_sub_to_server.py`**：支持通过订阅链接更新配置并自动回退，支持 Client 客户端与 Server 转发网关（清除路由、过滤 Reality 节点并重写本地映射端口、生成 Reality 入站）两种模式。
- **`setup_vps_server.sh`**：控制端远程 SSH 一键部署全套服务，支持直接指定 IP 或通过 Vultr API 自动开机。
- **`remove_vultr_instance.sh`**：Vultr 实例交互式查询与快速销毁工具。

### 2. [cloudflared-tunnel](./cloudflared-tunnel) — 内网穿透与目标端 VPS 出口网关

- **`install.sh`**：自动识别 CPU 架构拉取 Cloudflare 官方最新二进制，支持 **命名 Tunnel 模式**（`-t TOKEN`）与 **Quick Tunnel 临时穿透模式**，一键注册 Systemd 服务。
- **`setup-cloudflare-one.sh`**：自动开启目标端 VPS 内核 IP 转发并配置 `iptables` NAT MASQUERADE 规则，支持 Systemd + netfilter 双重开机持久化，配合 Tunnel Private Network 实现 VPS 原生 IP 出海。

### 3. [cloudflare-zero-trust](./cloudflare-zero-trust) — 客户端代理与网络诊断

- **`docker-run.sh`**：本地 Docker + Systemd SOCKS5 客户端管理脚本，内置策略路由自动隔离（防 Clash TUN 环路）与凭据安全存储。
- **`test-masque.py`**：纯 Python 标准库实现的 RFC 9000 QUIC Initial 握手与 MASQUE 连通性/时延诊断工具。
- **`install.sh`**：原生 Linux 环境配置官方软件源并安装 `cloudflare-warp` 客户端。

### 4. [subconverter](./subconverter) — 订阅转换引擎

- **`install.sh`**：一键下载并配置 `subconverter` 二进制，支持自定义端口并注册开机自启服务。

### 5. [preferred-ip-manager](./preferred-ip-manager) — 优选 IP 与 WARP Endpoint 管理

- **`install.sh`**：一键部署测速组件与 Python 依赖至 `/usr/local/bin`，注册每日北京时间 02:00~06:00 随机测速并自动推送至 Cloudflare Workers 订阅端的 Systemd 定时服务。
- **`preferred-ip-manager.sh`**：日常运维全局 CLI 命令（`preferred-ip-manager status/run/logs/restart/config/uninstall`），彻底解耦日常运维与安装脚本。
- **`sub-worker.js`**：Cloudflare Worker 订阅分发与 WARP 端点管理服务端，提供现代化暗黑拟物后台、历史备份及客户端配置生成。
- **`warp_tester.py`**：基于 RFC 9000 MASQUE/QUIC 的 Cloudflare WARP Anycast Endpoint 深度优选与测速引擎。
- **`process_ips.py`**：全流程集成工具，支持一键调度 CDN IP 测速同步或 WARP Endpoint 优选同步。
- **`telegram_tool.py`**：基于 MTProto 协议的 Telegram 文件极速多连接下载助手。

### 6. [singbox-sub-converter](./singbox-sub-converter) — 自适应订阅转换服务

- **自适应识别**：根据客户端 User-Agent 自动分发 Clash YAML、sing-box JSON 或通用 Base64 订阅。
- **动态节点合并**：自动聚合服务端配置与 Cloudflare 优选 IP 节点，自动清理空测速组。
- **`install.sh` & `uninstall.sh` & `pack.sh`**：提供一键自动化部署、一键卸载清理与 GitHub Actions 打包发布脚本。

### 7. [clash-singbox-sub-manager](./clash-singbox-sub-manager) — 中转 VPS 本地订阅同步与注入管理器

专门应用于 **Subapi / 在线订阅转换服务无法访问的中转 VPS 节点**：
- **零外部 Subapi 依赖**：中转 VPS 本地独立运行纯 Python 订阅解析引擎，彻底解决跨境网络中外部 Subapi 访问受阻的痛点。
- **Sing-box 入站自动提取**：自动读取本机 `/etc/sing-box/config.json` 中的多协议入站（VLESS Reality、Hysteria2、Trojan、Shadowsocks 等），一键封装为标准 Clash 代理节点。
- **双通道上游拉取与模板兜底**：优先通过本地 SOCKS5 代理（如 `127.0.0.1:2080`）拉取上游 Clash 规则模板，超时毫秒级自动回落直连拉取，无上游时内置精简规则模板兜底。
- **订阅深度重构与优化**：清空原节点、注入「节点选择」组并优化协议排序（加密直连协议优先，SOCKS 协议置后）、清理失效地域组并智能重定向分流规则。
- **Web 可视化面板与动态 UUID**：内置 Web 管理面板（默认端口 8000）、动态随机 UUID 防盗刷（一键更换 Token 即刻生效）、纯前端 SVG 终端/网页二维码扫码导入。
- **全局管理 CLI**：提供 `clash-singbox-sub-manager status/logs/restart/config/change-uuid/uninstall` 便捷命令体系。

### 8. [vpngate-singbox-openvpn](./vpngate-singbox-openvpn) — 目标 VPS 纯净住宅 IP 链式代理与节点轮询服务

集成部署在目标 VPS 上的 Docker 容器与 OpenVPN 节点自动更新服务，主要对外提供纯净家庭宽带住宅 IP 代理服务：
- **Docker 容器化链式代理架构**：
  - 基于 Ubuntu 24.04 LTS + Sing-box 1.12.20 + OpenVPN 镜像构建；
  - **内部 Inbound (`127.0.0.1:1080`)**：OpenVPN 出站走 Sing-box 订阅的 `urltest` 优选组（或直连）连接 VPNGate 节点；
  - **外部 Inbound (`0.0.0.0:2080`)**：对外映射宿主机 2080 端口，路由绑定 `tun0` 网卡（`openvpn-out`），使宿主机或外部客户端请求全部经由 OpenVPN 隧道最终纯净住宅 IP 出网；
  - **路由安全隔离**：OpenVPN 自动注入 `route-nopull`，禁用 `redirect-gateway`，完全不篡改宿主机与容器默认路由表。
- **Scamalytics 威胁风控过滤与节点批量生成 (`generate_ovpn.py`)**：
  - 自动拉取 VPNGate 官方与镜像节点，并发查询 `scamalytics.com` 威胁风控分（0~100），**严格过滤保留威胁分 < 20 的纯净住宅/低风险节点**；
  - 具备 7 天本地磁盘/内存两级缓存，大幅加速后续查询；
  - 自动按带宽降序排序，批量生成 `.ovpn` 文件与 `nodes_mapping.json` 映射清单，自动设置 Top 1 为默认配置。
- **宿主机每日定时自动更新与重启守护 (`node_updater.py`)**：
  - 宿主机后台常驻服务 `vpngate-singbox-node-updater`；
  - 每天北京时间 (UTC+8) 凌晨 00:00 至 06:00 之间的随机时刻，自动调用 `generate_ovpn.py` 刷新节点池；
  - 支持按国家代码精准筛选（如 `JP`, `US`, `KR` 或 `JP,US`）；
  - 刷新完成后**自动重启 Docker 容器**无缝载入最新节点池；支持 `--run-now` 立即执行。
- **容器内高可用健康检测与自动故障转移 (`health_checker.py`)**：
  - 每 30 秒静默检测 `tun0` 连通性，连续失败 3 次时，自动从 `nodes_mapping.json` 按顺序依次尝试切换节点建链，直至建链成功；
  - 实时将当前状态、出口 IP 与激活节点写入 `vpn_status.json`。
- **全局管理 CLI 与平滑升级 (`vpngate-tunnel`)**：
  - 提供 `vpngate-tunnel status/list-nodes/next-node/update-nodes/upgrade/restart/logs/test` 全生命周期命令；
  - 支持一键平滑升级（`--upgrade`），预构建镜像并保留配置，秒级无缝重启。

### 9. [cloudflare-access-tcp](./cloudflare-access-tcp) — 代理客户端 Cloudflare Access TCP 转发与自动优选 IP 容器

- **Ubuntu 24.04 编译生成**：基于 `ubuntu:24.04`、官方 `cloudflared` 与 `cfst` 测速核心，编译全程使用宿主机网络 (`--network host`)。
- **多端口并发转发**：默认开启 2 个 TCP 转发端口（`5000` 与 `5001`）映射远程私有服务（`movies.19910417.xyz` / `movies1.19910417.xyz`），支持任意自定义域名与端口列表。
- **全自动优选 IP 双重调度策略**：
  - **策略 1（每日凌晨定时测速）**：每天北京时间凌晨 02:00 ~ 06:00 随机时刻自动测速，选取 **TOP 20 优选 IP** 存入待选列表 (`candidates.txt`)，并自动切换至 TOP 1 优选 IP；
  - **策略 2（实时连通性检测与自动故障转移）**：容器内定时检测 TCP 转发连通性，当检测不通时从待选列表从前往后验证 IP 可用性，自动切换域名解析到可用优选 IP 并热重载转发。
- **日常运维管理 CLI 独立剥离**：管理命令独立封装为 `service.sh`，安装时自动注册为系统全局命令 `cloudflare-access-tcp`（别名 `cf-access-tcp`），支持 `status`、`candidates`、`speedtest`、`switch-ip`、`test`、`logs`、`restart`、`rebuild`、`uninstall`。

---

## 📂 第三章：仓库目录结构与文件索引

```text
vps-utils/
├── README.md                           # 本统一说明文档 (系统架构、部署流程与工具矩阵)
├── install.sh                          # 统一综合一键安装与运维管理入口 (支持目标VPS/中转VPS/Client端)
├── fhs-install-singbox/                # sing-box 服务端与 VPS 自动化运维脚本
│   ├── README.md                      # fhs-install-singbox 详细指南
│   ├── setup_vps_server.sh            # 远程 VPS 自动化部署脚本
│   ├── install-singbox-server.sh      # sing-box 服务端本地安装脚本
│   ├── update-singbox-keys.sh         # 服务端凭证/密钥安全更新工具
│   ├── update-singbox-sub.sh          # 订阅链接更新与回退脚本 (Client/Server 双模式)
│   ├── convert_sub_to_server.py       # 订阅转 Server 模式转换核心引擎
│   ├── remove_vultr_instance.sh       # Vultr 实例查询与清理工具
│   └── singbox_server_config.json     # sing-box 服务端配置模板
├── cloudflared-tunnel/                 # Cloudflare Tunnel 内网穿透与目标端 VPS 出口配置
│   ├── README.md                      # cloudflared-tunnel 详细指南
│   ├── install.sh                     # 自动化安装与 Systemd 服务部署脚本
│   └── setup-cloudflare-one.sh        # Cloudflare One VPS NAT 转发配置脚本
├── cloudflare-zero-trust/              # Cloudflare Zero Trust 客户端与代理套件
│   ├── README.md                      # cloudflare-zero-trust 详细指南
│   ├── docker-run.sh                  # 容器与 Systemd 服务管理脚本
│   ├── install.sh                     # 客户端安装与 Systemd 服务部署脚本
│   ├── test-masque.py                 # MASQUE (QUIC) 协议协商与连通性测试工具
│   ├── Dockerfile                     # WARP + sing-box 容器构建文件
│   ├── docker-entrypoint.sh           # 容器启动自愈入口脚本
│   └── cloudflare-warp-socks5.service # Systemd 服务 Unit 模板
├── subconverter/                       # 订阅转换后端程序
│   ├── README.md                      # subconverter 安装指南
│   ├── install.sh                     # 自动化安装与端口配置脚本
│   └── pack.sh                        # subconverter 项目离线打包脚本
├── preferred-ip-manager/               # 优选 IP 管理与测速工具
│   ├── README.md                      # preferred-ip-manager 详细指南
│   ├── install.sh                     # 自动安装与 Systemd 每日定时测速服务脚本
│   ├── preferred-ip-manager.sh        # 日常运维与服务管理 CLI 工具
│   ├── sub-worker.js                  # Cloudflare Worker 订阅服务
│   ├── process_ips.py                 # 自动化测速与推送脚本
│   ├── warp_tester.py                 # WARP MASQUE/QUIC 端点优选引擎
│   └── telegram_tool.py               # Telegram 资源抓取脚本
├── singbox-sub-converter/              # sing-box 自适应订阅转换服务
│   ├── README.md                      # singbox-sub-converter 详细指南
│   ├── install.sh                     # 自动安装/更新/卸载脚本
│   ├── uninstall.sh                   # 一键卸载与清理脚本
│   ├── pack.sh                        # 自动化打包脚本
│   └── app/                           # FastAPI 后端与前端静态文件
├── clash-singbox-sub-manager/          # 中转 VPS 本地订阅同步与注入管理器 (零外部 Subapi 依赖)
│   ├── README.md                      # clash-singbox-sub-manager 详细指南
│   ├── install.sh                     # 一键安装部署脚本 (支持自定义端口、上游订阅与代理)
│   ├── uninstall.sh                   # 一键卸载清理脚本
│   ├── service.sh                     # 日常运维管理 CLI 脚本 (注册为系统全局命令)
│   ├── main.py                        # 服务启动入口
│   ├── server.py                      # 轻量级 HTTP API 服务
│   ├── web_ui.py                      # Web 管理面板前端 HTML/JS 渲染器
│   ├── clash_parser.py                # Clash 订阅解析、节点提取、协议排序与规则重定向引擎
│   ├── qr_generator.py                # 纯 Python 矢量 SVG 二维码生成模块
│   ├── config.py                      # 配置管理与动态 UUID 生成模块
│   └── clash-singbox-sub-manager.service # Systemd 守护进程单元模板
├── vpngate-singbox-openvpn/            # VPNGate 链式住宅 IP 代理与自动轮询保活服务
│   ├── README.md                      # vpngate-singbox-openvpn 详细指南
│   ├── Dockerfile                     # Ubuntu 24.04 + Sing-box 1.12.20 + OpenVPN 镜像构建
│   ├── docker-compose.yml             # Docker Compose 编排文件
│   ├── entrypoint.sh                  # 容器启动入口脚本
│   ├── generate_ovpn.py               # VPNGate 节点拉取、Scamalytics 风控过滤与 .ovpn 批量生成
│   ├── install.sh                     # 宿主机一键安装与平滑升级脚本
│   ├── uninstall.sh                   # 一键卸载与数据清理脚本
│   ├── vpngate-singbox-openvpn.service # 主容器服务 Systemd 模板
│   ├── vpngate-singbox-node-updater.service # 宿主机每日定时自动更新与重启守护 Systemd 模板
│   ├── scripts/                       # 核心业务模块
│   │   ├── config_processor.py        # Sing-box 订阅解析与 SOCKS 规则注入
│   │   ├── ovpn_processor.py          # OpenVPN 规则注入 (route-nopull, socks-proxy)
│   │   ├── health_checker.py          # 容器内网络探测与按顺序自动轮询故障切换
│   │   ├── node_updater.py            # 宿主机每日定时节点更新与容器自动重启守护
│   │   └── service.sh                 # 常用维护管理 CLI 工具 (vpngate-tunnel)
│   └── config/                        # 宿主机映射配置目录 (/etc/vpngate-singbox-openvpn)
│       ├── config.env.example         # 环境变量配置模板
│       ├── client.ovpn.example        # OpenVPN 节点配置模板
│       ├── auth.txt.example           # OpenVPN 认证模板
│       ├── singbox_subscription.raw.json # 基础 Sing-box 配置
│       ├── nodes_mapping.json         # VPNGate 节点池映射清单
│       ├── ovpn_nodes/                # 批量生成的 .ovpn 节点文件目录
│       ├── scamalytics_cache.json     # Scamalytics 威胁分 7 天本地缓存
│       └── vpn_status.json            # 实时运行状态与当前激活节点输出
└── cloudflare-access-tcp/              # 代理客户端 Cloudflare Access TCP 转发与自动优选 IP 容器
    ├── README.md                      # cloudflare-access-tcp 详细指南
    ├── install.sh                     # 一键安装、构建与 Systemd 容器部署脚本
    ├── service.sh                     # 宿主机日常运维管理 CLI 脚本 (安装为 cloudflare-access-tcp)
    ├── Dockerfile                     # Ubuntu 24.04 + cloudflared + cfst 容器构建文件
    ├── docker-entrypoint.sh           # 多进程守护与初始化启动入口脚本
    ├── speedtest_runner.py            # 优选 IP 测速与 TOP 20 待选池管理引擎
    └── health_checker.py              # TCP 联通性检测、故障转移与每日定时测速守护进程
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
* **生效机制**：配置完成后，加入该 Zero Trust 团队的 WARP 客户端在访问该 CIDR 范围内的目标时，流量将由 Cloudflare 骨干网直接通过此 Tunnel 转发至末端 VPS，配合 VPS 本地的 `setup-cloudflare-one.sh`（位于 [`cloudflared-tunnel`](./cloudflared-tunnel)）NAT MASQUERADE 规则完成原生 IP 出海。

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
2. 将项目 [`preferred-ip-manager/sub-worker.js`](./preferred-ip-manager/sub-worker.js) 的完整代码复制并替换编辑器中的原有代码。
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
