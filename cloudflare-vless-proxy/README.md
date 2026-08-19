# Cloudflare VLESS 住宅代理网关 (cloudflare-vless-proxy)

基于 **Cloudflare Workers** 原生运行时与 **Cloudflare KV 键值存储** 构建的高可用、防主动探测的 VLESS 协议代理中继服务。支持将客户端流量通过 Cloudflare 全球 Anycast 边缘网络接入，并透明转发至**住宅 IP 代理 (Residential Proxy)** 出口，具备完整的 Web 可视化管理控制台与多客户端配置一键导出能力。

---

## 📑 目录导航

- [1. 🌐 系统架构与工作原理](#1-系统架构与工作原理)
- [2. ✨ 核心特性一览](#2-核心特性一览)
- [3. 🚀 从零开始快速部署指南](#3-从零开始快速部署指南)
  - [步骤 1：安装依赖环境](#步骤-1安装依赖环境)
  - [步骤 2：登录 Cloudflare 账号](#步骤-2登录-cloudflare-账号)
  - [步骤 3：创建 Cloudflare KV 命名空间](#步骤-3创建-cloudflare-kv-命名空间)
  - [步骤 4：配置 wrangler.toml](#步骤-4配置-wranglertoml)
  - [步骤 5：一键部署上线](#步骤-5一键部署上线)
  - [步骤 6：绑定自定义域名（推荐）](#步骤-6绑定自定义域名推荐)
- [4. 🖥️ Web 管理控制台 (`/admin`) 使用指南](#4-web-管理控制台-admin-使用指南)
  - [4.1 登录与权限安全](#41-登录与权限安全)
  - [4.2 核心协议与路径动态配置](#42-核心协议与路径动态配置)
  - [4.3 住宅代理在线连通性与延迟测试](#43-住宅代理在线连通性与延迟测试)
  - [4.4 节点信息导出与多客户端适配](#44-节点信息导出与多客户端适配)
- [5. 🌍 主流住宅代理提供商配置范例](#5-主流住宅代理提供商配置范例)
- [6. 📱 客户端完整配置与接入教程](#6-客户端完整配置与接入教程)
  - [6.1 Sing-box 客户端配置 (JSON)](#61-sing-box-客户端配置-json)
  - [6.2 Clash Meta / Mihomo 客户端配置 (YAML)](#62-clash-meta--mihomo-客户端配置-yaml)
  - [6.3 V2rayN / Shadowrocket / Quantumult X 快速导入](#63-v2rayn--shadowrocket--quantumult-x-快速导入)
- [7. 🧪 本地自动化测试与开发调试](#7-本地自动化测试与开发调试)
- [8. ❓ 常见问题排查与 FAQ](#8-常见问题排查与-faq)

---

## 1. 🌐 系统架构与工作原理

### 业务数据流转与防探测流程

```text
[ 用户客户端 (Sing-box / Clash Meta / Shadowrocket) ]
                       │
                       ▼ 1. 发起 VLESS over WebSocket 连接 (支持 Early Data 0-RTT)
[ Cloudflare 优选 IP (Anycast 全球加速节点 / 自定义域名) ]
                       │
                       ▼ 2. Cloudflare 边缘节点接收请求并校验
┌──────────────────────────────────────────────────────────────┐
│                  Cloudflare Worker 边缘网关                   │
│                                                              │
│  ├─ A. 鉴权校验失败 / 外部探测扫描 / HTTP 探针               │
│  │    └─► 立即返回高保真静态网页《汉武大帝 · 刘彻生平述略》(200 OK) │
│  │                                                           │
│  └─ B. VLESS 鉴权成功 (UUID 匹配)                            │
│       └─► 建立双向流式转发通道 (cloudflare:sockets)          │
└──────────────────────────────┬───────────────────────────────┘
                               │
                               ▼ 3. 透明中继 (TCP SOCKS5 / HTTP CONNECT)
[ 住宅 IP 代理池 (IPRoyal / Bright Data / Oxylabs / Smartproxy) ]
                               │
                               ▼ 4. 住宅原生公网 IP 出口
[ 目标国际互联网 (Google / YouTube / Netflix / ChatGPT / Claude / 原生 IP 验证) ]
```

---

## 2. ✨ 核心特性一览

1. **协议标准与零延迟 (0-RTT)**：
   - 严格遵循 VLESS 协议规范，完整支持 WebSocket 传输与 `Sec-WebSocket-Protocol` Early Data 首包加速。
2. **动态优选 IP 深度集成 (参考 singbox-sub-converter 逻辑)**：
   - 自动且动态从 `https://sub.19910417.xyz` 实时获取最新测速优选的 Cloudflare CDN 节点列表并智能解析命名。
   - 内置 10 分钟内存缓存与故障本地兜底机制，支持在管理后台一键手动即时刷新优选节点。
3. **Subapi 在线订阅转换生成 (`https://subapi.19910417.xyz`)**：
   - Clash Meta / Mihomo 与 Sing-box 客户端完整配置文件直接通过 `subapi.19910417.xyz` 在线 API 智能生成。
   - 内置 ACL4SSR 多地区负载均衡等完整规则模板，并支持在控制台切换 `SUBCONFIG.json` 规则方案或自定义 ini 规则。
   - 具备自适应 User-Agent 识别能力，并提供高可靠的本地配置兜底保证。
4. **住宅 IP 深度整合 (Residential Proxy Relay)**：
   - 流量由 Cloudflare 边缘透明转发至海外住宅网络，获取高纯净度 ISP 住宅 IP，轻松解锁流媒体、各类 AI 大模型并绕过反爬/风控拦截。
   - 兼容多种主流住宅代理认证格式（SOCKS5 与 HTTP 均支持）。
   - 内置智能故障转移（当住宅代理异常时可自动平滑回退至直连模式）。
5. **双重反探测与指纹伪装保护**：
   - **伪装落地页**：根路径 `/` 返回结构完整、具有真实 DOM 结构的《汉武大帝 · 刘彻生平述略》历史文化静态网页。
   - **鉴权失败静默回退**：对任何非合法客户端的嗅探、扫描、路径探测或 UUID 不匹配请求，均直接返回 200 静态网页或安全断开，杜绝协议指纹外泄。
6. **Cloudflare KV 动态配置管理**：
   - UUID、数据传输路径、住宅代理网关、转换规则 URL、优选 IP 列表、管理密码等核心参数均持久化存储于 Cloudflare KV，控制台修改即刻生效，无需重新执行 `wrangler deploy`。
7. **脱敏配置文件 (`wrangler.toml`)**：
   - 配置文件中已全面剔除敏感关键字，使用中性数据流与网关术语，安全隐蔽。
8. **Web 可视化控制台 (`/admin`)**：
   - 包含一键随机 UUID、路径混淆生成器、优选 IP 节点即时刷新、住宅代理实时测速诊断、SUBCONFIG 规则选择与多客户端订阅导出等一站式运维能力。

---

## 3. 🚀 从零开始快速部署指南

### 步骤 1：安装依赖环境

确保本地已安装 [Node.js](https://nodejs.org/) (推荐 Node.js >= 18.0.0)。

克隆项目并进入本目录：
```bash
cd /home/jason/user_data/code/vps-utils/cloudflare-vless-proxy
npm install
```

---

### 步骤 2：登录 Cloudflare 账号

在终端中执行登录命令，浏览器将自动弹出授权页面：
```bash
npx wrangler login
```
*根据命令行提示点击网页中的“Allow”完成授权。*

---

### 步骤 3：创建 Cloudflare KV 命名空间

执行以下命令在你的 Cloudflare 账户中创建一个用于持久化存储配置的 KV 命名空间：

```bash
npx wrangler kv namespace create CONFIG_KV
```

终端将输出类似如下的成功信息：
```text
🌀 Creating namespace with title "han-history-portal-CONFIG_KV"
✨ Success! Add the following to your configuration file in your kv_namespaces array:
[[kv_namespaces]]
binding = "CONFIG_KV"
id = "4a5b6c7d8e9f0123456789abcdef0123"
```

---

### 步骤 4：配置 wrangler.toml

打开 [`wrangler.toml`](file:///home/jason/user_data/code/vps-utils/cloudflare-vless-proxy/wrangler.toml)，将刚刚生成的 `id` 填入第 30 行对应的位置：

```toml
name = "han-history-portal"
main = "dist/index.js"
compatibility_date = "2024-09-23"
compatibility_flags = ["nodejs_compat"]
minify = true

[vars]
DEFAULT_UUID = "d342d11e-d424-4583-b36e-524ab1f0afa4"
DEFAULT_DATA_PATH = "/api-data-sync"
ADMIN_PATH = "/admin"
ADMIN_PASSWORD = "AdminPassword123!"
DEFAULT_UPSTREAM_GATEWAY = ""
DEFAULT_CLEAN_IPS = "cloudflare.com,cf.090227.xyz,visa.cn,icook.hk"
DEFAULT_NODE_TAG = "Edge-Gateway-Node"
ENABLE_DIRECT_FALLBACK = "true"

[[kv_namespaces]]
binding = "CONFIG_KV"
id = "4a5b6c7d8e9f0123456789abcdef0123" # <--- 替换为你实际生成的 KV ID
```

> 💡 **提示**：
> `ADMIN_PASSWORD` 为初始部署时的管理后台密码（部署后亦可在 `/admin` 随时修改）。

---

### 步骤 5：代码自动混淆并一键部署上线

项目已配置好自动化编译与深度代码混淆管线（自动将所有协议逻辑、字符串进行 AST 混淆、十六进制变量重命名与 Base64 编码，生成纯净脱敏的 `dist/index.js` 上传至 Cloudflare 边缘）：

在终端执行部署命令：
```bash
npm run deploy
# 或者分步执行：
# npm run build    # 生成深度混淆产物 dist/index.js
# npx wrangler deploy
```

部署成功后，终端将输出你的 Worker 公网服务地址，例如：
```text
Total Upload: 48.20 KiB / gzip: 13.50 KiB
Uploaded han-history-portal (1.20 sec)
Deployed han-history-portal triggers (0.50 sec)
  https://han-history-portal.<your-subdomain>.workers.dev
Current Deployment ID: a1b2c3d4-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

---

### 步骤 6：绑定自定义域名（推荐）

由于 `*.workers.dev` 域名在部分网络环境下可能受到 DNS 污染或 SNI 阻断，建议绑定已托管在 Cloudflare 上的自定义域名：

1. 登录 [Cloudflare 控制台](https://dash.cloudflare.com/)。
2. 进入 **Workers & Pages** -> 点击刚刚部署的 **han-history-portal**。
3. 点击 **Settings** 选项卡 -> **Domains & Routes** -> 点击 **Add** -> 选择 **Custom Domain**。
4. 输入你的二级域名（例如 `edge.yourdomain.com`），点击 **Add Custom Domain**。
5. Cloudflare 将全自动配置 DNS 解析与 SSL/TLS 证书。

---

## 4. 🖥️ Web 管理控制台 (`/admin`) 使用指南

### 4.1 登录与权限安全

1. 浏览器访问：`https://<你的域名>/admin`。
2. 在登录弹窗中输入管理员密码（初始默认：`AdminPassword123!`）。
3. 登录成功后，Token 将安全加密保存于本地，后续请求自动鉴权。

---

### 4.2 核心协议与路径动态配置

切换至 **⚙️ 代理路径与住宅IP配置** 选项卡：

| 配置项 | 说明与建议 |
| :--- | :--- |
| **VLESS 用户 UUID** | 客户端连接鉴权凭证。支持点击 **🎲 生成随机** 实时生成高强度 UUID。 |
| **WebSocket 代理路径** | 匹配 VLESS 流量的专用 URL 路径（例如 `/api-data-sync`）。支持点击 **🎲 生成混淆路径** 随机生成伪装字符串。 |
| **住宅 IP / 上游代理** | 转发的目标住宅代理地址（留空表示直连）。详见下文格式说明。 |
| **优选 IP / 域名列表** | 每行一个优选 IP 或域名，系统将自动基于这些节点生成对应的优选客户端配置。 |
| **修改管理密码** | 输入新密码后点击保存，全局密码立即更新。 |

> ⚠️ **注意**：每次修改配置后，请务必点击 **💾 保存配置至 KV**，修改将在全球边缘节点即时生效。

---

### 4.3 住宅代理在线连通性与延迟测试

在“住宅 IP / 上游代理”输入框填入代理地址后，点击旁边的 **⚡ 测试连通性** 按钮：
- Worker 将从 Cloudflare 边缘节点向住宅代理发起完整的 SOCKS5 / HTTP CONNECT 握手探测。
- 界面即时返回握手成功状态与**网络往返延迟 (ms)**；若失败则显示具体的错误原因（如认证失败、连接超时、地址拒绝等），方便快速排查。

---

### 4.4 订阅聚合、在线转换与二维码扫码

在 **🔗 订阅与节点导出** 选项卡中：

1. **✨ 智能自适应订阅 (`/sub`)**：
   - 自动识别客户端 User-Agent（Clash / Sing-box / V2Ray / Shadowrocket），无需手动区分格式，一个链接适配所有客户端。

2. **🐱 Clash Meta / Mihomo 订阅 (`/clash`)**：
   - 优先通过 `subapi.19910417.xyz` 在线接口与 ACL4SSR 多地区负载均衡模板生成完整配置。
   - 包含完整的 `proxies`、`proxy-groups` 及智能分流规则；在线服务异常时无缝回退至本地动态配置。
   - 点击 **复制** 可直接导入 Clash Verge / Mihomo Party / Flclash；点击 **📱 二维码** 可使用手机端快速扫码导入。

3. **📦 Sing-box 完整配置订阅 (`/singbox`)**：
   - 优先通过 `subapi.19910417.xyz` 在线接口生成完整 JSON 配置文件（含 `mixed-in` 本地入站、分流规则组与 `urltest` 自动测优）。
   - 点击 **复制** 或 **📱 二维码** 可在 Sing-box 客户端（iOS / Android / Desktop）中直接作为 Profile 订阅链接添加。

4. **🚀 通用 VLESS Base64 订阅 (`/v2ray`)**：
   - 生成标准 Base64 节点列表，适用于 V2rayN、Shadowrocket、Quantumult X 等传统客户端。

5. **📋 动态优选 IP 节点列表**：
   - 自动展示从 `https://sub.19910417.xyz` 实时获取的优选 IP 节点。
   - 支持点击 **🔄 刷新优选 IP** 手动即时同步最新节点。
   - 每个节点均配备独立的 **复制** 与 **📱 二维码** 按钮。

6. **📱 纯原生离线二维码引擎**：
   - 管理后台内置轻量级纯原生 JavaScript SVG 二维码生成引擎，完全不依赖任何外部 CDN 或第三方图片 API，安全隐私，秒级渲染。

---

### 4.5 🔑 REST 代理修改推送接口 (`/api/upstream`)

系统提供了专用于外部程序、保活守护进程（如 `vpngate-residential-selector`）或定时任务自动化推送/修改上游代理的 REST API 接口。

#### 1. 鉴权机制（KV 动态初始化与独立 Token 鉴权）
- **自动初始化存储**：`API_TOKEN` 不在 `wrangler.toml` 中硬编码生成，而是在系统初次运行初始化时自动生成高强度安全随机 Token 并直接持久化存储至 **Cloudflare KV**。
- **界面随时修改与重新生成**：进入 `/admin` 管理后台的“⚙️ 代理路径与住宅IP配置”选项卡，可通过“🎲 生成随机 Token”按钮随时生成新 Token 或手动输入，保存至 KV 即刻生效。
- **多途径鉴权支持**：支持以下三种方式携带 Token 调用 REST 接口：
  - **HTTP Header**：`Authorization: Bearer <API_TOKEN>` 或 `X-API-Token: <API_TOKEN>`
  - **Query Parameter**：`?token=<API_TOKEN>` 或 `?api_token=<API_TOKEN>`

#### 2. 接口端点与调用示例

##### A. 修改/推送新代理 (`POST /api/upstream` 或 `PUT /api/upstream`)

- **方式一：纯文本单行直接推送 (cURL)**：
```bash
# 推送 OpenVPN 住宅代理
curl -X POST https://<你的Worker域名>/api/upstream \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -d "openvpn://vpn:vpn@219.100.37.13:443"

# 推送 SOCKS5 代理
curl -X POST https://<你的Worker域名>/api/upstream \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -d "socks5://vpn:vpn@1.2.3.4:1080"
```

- **方式二：JSON 格式推送（支持同步在线测速与直连回退开关）**：
```bash
curl -X POST https://<你的Worker域名>/api/upstream \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "upstreamProxy": "openvpn://vpn:vpn@219.100.37.13:443",
    "enableDirectFallback": true,
    "test": true
  }'
```

- **方式三：Python 自动化保活守护进程对接代码**：
```python
import requests

API_URL = "https://<你的Worker域名>/api/upstream"
API_TOKEN = "YOUR_API_TOKEN"

def push_upstream_proxy(proxy_url: str):
    resp = requests.post(
        API_URL,
        headers={"Authorization": f"Bearer {API_TOKEN}", "Content-Type": "application/json"},
        json={"upstreamProxy": proxy_url, "test": True},
        timeout=15
    )
    print("Push Result:", resp.json())

# 示例：推送 VPNGATE 优选选出的纯净住宅节点
push_upstream_proxy("openvpn://vpn:vpn@219.100.37.13:443")
```

##### B. 查询当前代理状态 (`GET /api/upstream`)
```bash
curl -X GET https://<你的Worker域名>/api/upstream \
  -H "Authorization: Bearer YOUR_API_TOKEN"
```

---

## 5. 🌍 主流住宅代理提供商配置范例

系统全面支持 **SOCKS5**、**HTTP** 与 **OpenVPN** 三种代理协议及多种格式输入，可直接填入管理控制台或通过 REST 接口推送：

### 1. OpenVPN / VPNGATE 住宅节点 (全新支持 ✨)
- 标准 URL 格式：`openvpn://vpn:vpn@219.100.37.13:443` 或 `ovpn://219.100.37.13:443`（缺省自动使用 `vpn:vpn` 凭据）
- 自定义凭据：`openvpn://username:password@remote.host.com:1194`
- 原始 `.ovpn` 配置文件文本：直接粘贴包含 `remote <host> <port>` 的 ovpn 文本内容
- Base64 编码的 `.ovpn`：直接填入 VPNGATE API 导出的 base64 字符串

### 2. IPRoyal 住宅代理
```text
socks5://your_username:your_password@geo.iproyal.com:12321
```

### 3. Bright Data (Luminati)
```text
http://brd-customer-c_xxxx-zone-residential:your_password@brd.superproxy.io:22225
```

### 4. Oxylabs 动态住宅代理
```text
http://customer-your_user:your_pass@pr.oxylabs.io:7777
```

### 5. Smartproxy 住宅网络
```text
socks5://user-sp12345678:password123@gate.smartproxy.com:7000
```

### 6. 标准无密码 / 简写格式
- `socks5://192.168.1.100:1080`
- `http://192.168.1.100:8080`
- `ip:port:username:password`（自动按 SOCKS5 解析）
- `username:password@ip:port`（自动按 SOCKS5 解析）

---

## 6. 📱 客户端完整配置与接入教程

### 6.1 Sing-box 客户端配置 (JSON)

在 sing-box 的 `outbounds` 列表中添加以下节点：

```json
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "CF-Residential-Node",
      "server": "cloudflare.com",
      "server_port": 443,
      "uuid": "d342d11e-d424-4583-b36e-524ab1f0afa4",
      "tls": {
        "enabled": true,
        "server_name": "edge.yourdomain.com",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        }
      },
      "transport": {
        "type": "ws",
        "path": "/api-data-sync",
        "headers": {
          "Host": "edge.yourdomain.com"
        }
      }
    }
  ]
}
```

> 📌 **参数说明**：
> - `server`：可填写 Cloudflare 优选 IP 或优选域名（如 `cf.090227.xyz` 或 `visa.cn`）；
> - `tls.server_name` 与 `transport.headers.Host`：**必须严格填写你的 Worker 域名或绑定自定义域名**；
> - `transport.path`：填写你在后台配置的 WebSocket 路径。

---

### 6.2 Clash Meta / Mihomo 客户端配置 (YAML)

在 Clash Meta (Mihomo) 配置文件的 `proxies` 区域添加：

```yaml
proxies:
  - name: "CF-Residential-Proxy"
    type: vless
    server: cloudflare.com
    port: 443
    uuid: d342d11e-d424-4583-b36e-524ab1f0afa4
    network: ws
    tls: true
    udp: true
    sni: edge.yourdomain.com
    client-fingerprint: chrome
    ws-opts:
      path: "/api-data-sync"
      headers:
        Host: edge.yourdomain.com
```

---

### 6.3 V2rayN / Shadowrocket / Quantumult X 快速导入

1. 打开管理后台 `https://<你的域名>/admin`。
2. 切换至 **🚀 节点信息导出**。
3. 点击 **复制** 按钮复制对应的 `vless://` 链接。
4. 打开手机端或电脑端客户端，选择 **从剪贴板导入** 即可快速添加完成。

---

## 7. 🧪 本地自动化测试与开发调试

项目内置基于 Node.js 原生 Test Runner 的全套自动化单元测试，覆盖代理字符串解析、VLESS 二进制封包与鉴权、客户端配置生成与静态落地页验证：

```bash
# 运行单元测试
npm test

# 启动本地 Worker 开发预览服务器
npm run dev
```

---

## 8. ❓ 常见问题排查与 FAQ

### Q1: 浏览器访问提示 `Error 1101: Worker threw exception`？
- **原因**：通常是因为 `wrangler.toml` 中的 `CONFIG_KV` 的 `id` 未替换或填错。
- **解决办法**：重新执行 `npx wrangler kv namespace create CONFIG_KV`，确认输出的 ID 完整复制并粘贴到 `wrangler.toml` 中，然后重新运行 `npx wrangler deploy`。

### Q2: 客户端连接后显示超时无法上网？
- **排查步骤**：
  1. 检查客户端的 `Host` / `SNI` 是否正确填写了 Worker 的实际域名；
  2. 检查客户端的 `path` 路径是否与控制台设置的路径完全一致；
  3. 检查客户端的 UUID 是否一致；
  4. 若配置了住宅代理，进入 `/admin` 点击 **⚡ 测试连通性** 确认该住宅代理当前是否存活、账号密码与端口是否正确。

### Q3: 修改了 UUID 或路径后客户端无法连接？
- **原因**：KV 配置具有即时生效性，服务端更新后旧连接会失效。
- **解决办法**：在 `/admin` 后台重新复制最新的节点链接或 Sing-box / Clash 配置并同步至客户端。

### Q4: 如何配合优选 IP 获得更低延迟？
- 可将客户端中的 `server`（服务器地址）替换为经过测速筛选的 Cloudflare Anycast 优选 IP，而保持 `sni` 和 `Host` 依然为你的 Worker 域名即可享受极致低延迟加速。
