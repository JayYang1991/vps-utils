# Preferred IP Manager (edgetunnel 优选 IP 与 WARP Endpoint 聚合管理服务)

`preferred-ip-manager` 是一个集成了 **Cloudflare Worker 无服务器订阅与 WARP 管理**、**Cloudflare CDN 优选测速同步** 以及 **Cloudflare WARP Anycast Endpoint 深度优选** 的全套网络加速与端点优化工具链。

它专为 edgetunnel (VLESS/Trojan) 与 Cloudflare WARP (WireGuard/MASQUE) 协议设计，一方面提供高可用的服务端聚合订阅能力与现代化 Web 管理后台，另一方面通过 Python 脚本实现自动从 Telegram 抓取最新 IP 资源、调起 CloudflareSpeedTest (`cfst`) 测速、利用 RFC 9000 协议探测优选 WARP Anycast Endpoint，并自动将优选结果同步至订阅服务器。

---

## ✨ 核心特性

### ☁️ Cloudflare Worker 服务端 (`sub-worker.js`)
- 🔗 **动态 VLESS 订阅生成 (`/sub`)**：自动合并远程优选源与本地 KV 保存的优选 IP，实时动态拼装生成标准 Base64 编码的 VLESS / Trojan 订阅链接。
- ⚡ **WARP 优选端点获取 (`/warp`)**：对外提供经过测速优选的 Cloudflare WARP Anycast Endpoint 纯文本列表。
- 🖥️ **可视化管理后台 (`/admin`)**：
  - 现代化暗黑玻璃拟物化风格 UI。
  - **CDN 优选 IP 管理**：支持优选 IP 列表 (`ADD.txt`) 在线编辑与历史备份一键恢复（支持覆盖/追加模式）。
  - **WARP Endpoint 优选管理**：支持 WARP 端点列表 (`WARP.txt`) 在线编辑、覆盖/追加与历史记录备份。
  - **客户端配置一键生成**：一键生成并复制适配 **WireGuard**、**Sing-box**、**Clash Meta / Mihomo** 以及 **WARP-CLI** 的客户端配置片段。
  - 内置在线数据格式校验，防止误填无效 IP 或端口。
- 🤖 **自动化 API (`/api/update` & `/api/history`)**：
  - `/api/update?type=ips`：自动推送并更新 CDN 优选 IP。
  - `/api/update?type=warp`：自动推送并更新 WARP 优选 Endpoint。
  - `/api/history?type=ips|warp`：获取历史优选记录列表的 HTTP GET 接口。
  - 支持 Header `Authorization` 或 URL Token 鉴权。

### 🐍 Python 自动化测速与优选工具链
- ⚡ **WARP Endpoint 优选引擎 (`warp_tester.py`)**：
  - **RFC 9000 MASQUE/QUIC 深度探测**：向目标发送 1200 字节标准 QUIC Initial 握手报文，测量端点真实 RTT 延迟、丢包率与 1200B MTU 大包可达性。
  - **全量 Anycast IP 段覆盖**：内置官方全量 IPv4/IPv6 Anycast 网段（`162.159.192.0/24`、`162.159.193.0/24`、`162.159.195.0/24`、`162.159.197.0/24`、`188.114.96.0/24 ~ 188.114.99.0/24` 及域名解析 IP）。
  - **多线程高并发与多轮统计**：支持 `fast`（快速抽样）、`standard`（标准采样）、`full`（全网段扫描），支持自定义并发线程与探测轮数。
  - **多格式导出**：支持输出 WireGuard、Sing-box JSON、Clash Meta YAML、WARP-CLI 切换命令。
- 🌐 **CDN IP 测速与同步工具 (`process_ips.py`)**：
  - 支持一键调度 CDN IP 测速（带宽模式/延迟模式）或 WARP Endpoint 优选（`--target warp`）。
  - 自动从 Telegram 频道下载中转 IP，并在测速前提示断开代理确保无干扰测试。
  - 自动调用 `cfst` 测速并筛选 Top N 个最优 IP 同步推送至 Worker。
- 📥 **Telegram 极速下载器 (`telegram_tool.py`)**：基于 Telethon / MTProto 协议，支持多连接并发加速下载与断点续传。

---

## ⚙️ 环境变量配置说明

### 1. Cloudflare Worker 环境变量

在 Worker 控制台的 **Settings -> Variables** 中配置：

| 变量名 | 类型 | 是否必填 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- | :--- |
| `ADMIN` | Plain Text | **必填** | - | Web 管理后台 (`/admin`) 的登录密码 |
| `TOKEN` | Plain Text | **必填** | - | `/api/update` 自动化接口更新所用的 API Key / Token |
| `SUB_SOURCE` | Plain Text | 可选 | `https://sub.cmliussss.net` | 远程优选 IP 订阅源地址 |

> 🗄️ **KV 绑定要求**：须添加 KV 命名空间绑定，Variable Name 设为 `KV`。Worker 会在 KV 中自动维护 `ADD.txt`、`HISTORY.json`、`WARP.txt`、`WARP_HISTORY.json` 及更新时间戳。

### 2. Python 自动化脚本环境变量

在系统终端或 Shell 配置文件 (`~/.bashrc` / `~/.zshrc`) 中设置：

```bash
# Telegram 客户端 API 凭证 (从 https://my.telegram.org 申请，仅 Telegram 下载器需要)
export TG_API_ID="你的_TG_API_ID"
export TG_API_HASH="你的_TG_API_HASH"

# 订阅服务器 API 更新 Token (须与 Worker 的 TOKEN 保持一致)
export CF_SUB_TOKEN="你的_WORKER_UPDATE_TOKEN"
```

---

## 🚀 快速使用指南

### 1. Cloudflare WARP Endpoint 优选测速 (`warp_tester.py`)

```bash
# 1. 快速模式测速 (默认从各 Anycast 网段快速抽样，保留延迟最低、0丢包的前 10 个端点)
python3 warp_tester.py

# 2. 全量模式扫描 (对所有 WARP Anycast IPv4 /24 网段全量扫描)
python3 warp_tester.py --mode full --top 20

# 3. 指定自定义端口与并发线程
python3 warp_tester.py -p 4443,8443,4500,8095 -c 150 --top 15

# 4. 生成不同客户端的配置片段
python3 warp_tester.py --format singbox    # 生成 Sing-box Outbound JSON
python3 warp_tester.py --format clash      # 生成 Clash Meta / Mihomo Proxies YAML
python3 warp_tester.py --format wireguard  # 生成 WireGuard Endpoint 配置
python3 warp_tester.py --format warp-cli   # 生成 WARP 官方客户端切换命令

# 5. 自动测速并无交互推送到 Cloudflare Worker
python3 warp_tester.py --yes
```

#### WARP 测速参数说明
- `--mode`, `-m`：扫描模式。`fast`（快速抽样，默认）、`standard`（标准采样）、`full`（全量扫描）。
- `--top`, `-t`：最终保留的最优 Endpoint 数量（默认：`10`）。
- `--ports`, `-p`：待测试端口列表，逗号分隔（默认：`443,8443,4443,8095,4500,500,1701,2408`）。
- `--concurrency`, `-c`：并发探测线程数（默认：`100`）。
- `--rounds`, `-r`：单端点探测轮数（默认：`3` 轮）。
- `--timeout`：单次探测超时时间（默认：`1.0` 秒）。
- `--format`：输出或导出格式。`txt`、`wireguard`、`singbox`、`clash`、`warp-cli`。
- `--ipv6`：开启 IPv6 Anycast 网段探测。
- `--yes`, `-y`：跳过确认提示，自动推送到 Worker。

---

### 2. 集成自动化测速与同步工具 (`process_ips.py`)

`process_ips.py` 支持调度 **CDN 优选** 与 **WARP 优选**：

```bash
# 1. CDN 带宽模式测速 (测试下载速度，保留速度 >= 10 MB/s 的前 20 个 IP)
python3 process_ips.py --target cdn --mode speed --top 20 --min-speed 10.0

# 2. CDN 延迟模式测速 (HTTPing 测试延迟，保留延迟最低的前 15 个 IP)
python3 process_ips.py --target cdn --mode latency --top 15

# 3. WARP Endpoint 优选测速与同步
python3 process_ips.py --target warp --warp-mode fast --top 10

# 4. 自动推送模式 (适用于 Cron 定时任务)
python3 process_ips.py --target cdn --yes
python3 process_ips.py --target warp --yes
```

---

### 3. Telegram 资源下载与管理助手 (`telegram_tool.py`)

```bash
# 查看最近的对话/频道列表
python telegram_tool.py list

# 按频道名称搜索并下载包含 "CF中转" 关键字的最新 1 个文件
python telegram_tool.py download -n 'CF中转' --limit 1 -o ./origin-iplist
```

---

## ☁️ Cloudflare Worker 接口指南

### 1. 订阅与端点接口
- **VLESS 节点订阅 (`/sub`)**：
  ```http
  GET https://<your-worker-domain>/sub?host=<your-domain>&uuid=<your-uuid>
  ```
  返回 Base64 编码的 VLESS / Trojan 节点列表。
- **WARP 优选端点 (`/warp`)**：
  ```http
  GET https://<your-worker-domain>/warp
  ```
  返回纯文本格式的 WARP 优选端点列表（`IP:Port#备注`）。

### 2. Web 管理后台 (`/admin`)
- 访问 `https://<your-worker-domain>/admin` 并使用 `ADMIN` 密码登录。
- **CDN 优选 IP 面板**：在线查看与编辑本地 CDN 优选 IP，支持历史备份恢复。
- **WARP 优选 Endpoint 面板**：在线查看与编辑本地 WARP 优选端点，支持历史记录恢复。
- **客户端配置生成器**：一键生成并复制 Sing-box、Clash Meta、WireGuard、WARP-CLI 配置。

### 3. 自动化更新 API (`/api/update`)
```bash
# 1. 更新 CDN 优选 IP 列表
curl -X PUT "https://<your-worker-domain>/api/update?token=YOUR_TOKEN&type=ips&mode=overwrite" \
     -H "Content-Type: text/plain" \
     --data-binary @ip_result.txt

# 2. 更新 WARP 优选端点列表
curl -X PUT "https://<your-worker-domain>/api/update?token=YOUR_TOKEN&type=warp&mode=overwrite" \
     -H "Content-Type: text/plain" \
     --data-binary @warp_result.txt
```

---

## 📄 开源许可

本项目遵循 MIT 许可证。
