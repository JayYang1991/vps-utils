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

### 🌐 Cloudflare Pages 专属测速节点 (`deploy_pages.sh` & `speedtest-pages/`)
- 🚀 **专为 CloudflareSpeedTest (`cfst`) 优化**：提供全球 Anycast 边缘测速能力，支持静态文件与动态流式双模测速。
- 🍃 **极致节约资源 (100% 满足免费版约束)**：
  - **静态资源零配额消耗**：预生成 `5mb.bin`、`10mb.bin`、`20mb.bin` 静态二进制大文件（< 25MB 限制），由 Cloudflare CDN 边缘强缓存分发，**无请求次数上限、零 CPU 额外开销**；
  - **动态流式极致低内存**：基于 `ReadableStream` 流式生成数据，复用 64KB 单一缓冲区，**内存恒定 < 1MB，CPU 微秒级**；
  - **极速 HTTPing 延迟接口 (`/test`)**：毫秒级响应，携带 `CF-Ray` 与机房数据中心代码（Colo），完美兼容 `cfst -httping -cfcolo` 地区筛选。
- 📦 **开箱即用多模部署**：支持 Wrangler CLI 一键上线，也支持一键生成 ZIP 上传包在 Cloudflare 网页控制台直接拖拽部署。

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

`process_ips.py` 支持调度 **CDN 优选** 与 **WARP 优选**，具备**智能两阶段测速与降级容错**、**端口按需过滤**、**敏感凭据脱敏**与**多端自动化同步**能力：

```bash
# 1. CDN 带宽模式测速 (标准模式: TG 下载 + 订阅源现有与历史 IP 合并测速, 默认仅测 443 端口)
python3 process_ips.py --target cdn --mode speed --top 20 --min-speed 5.0

# 2. 【指定本地文件跳过 TG 下载】直接传入已下载的 IP 列表文件继续测速与同步
python3 process_ips.py --target cdn -f ./ALL-2026-08-24.txt --mode speed --top 20

# 3. 【仅从订阅服务器获取】跳过 TG 下载 (适合定期对已有优选池与历史池进行健康复测与提速)
python3 process_ips.py --target cdn --skip-tg --mode speed --top 20

# 4. 指定自建 Cloudflare Pages 测速地址 + 本地文件测速
python3 process_ips.py --target cdn -f ./my_ips.txt --mode speed --url "https://<your-pages-project>.pages.dev/20mb.bin" --top 20

# 5. 指定多个端口测速 (如 443 和 8443，避免轮询全部无用端口)
python3 process_ips.py --target cdn -p 443,8443 --mode speed --top 20

# 6. 结合最大延迟过滤与单点下载时长 (-tl 300ms 延迟上限, -dt 5s 下载测速)
python3 process_ips.py --target cdn --skip-tg -tl 300 -dt 5 --top 10

# 7. CDN 延迟模式测速 (HTTPing 测试延迟，保留延迟最低的前 15 个 IP)
python3 process_ips.py --target cdn --mode latency --url "https://<your-pages-project>.pages.dev/test" --top 15

# 8. WARP Endpoint 优选测速与同步
python3 process_ips.py --target warp --warp-mode fast --top 10

# 9. 自动推送模式 (适用于 Cron 定时任务，跳过所有交互确认)
python3 process_ips.py --target cdn --skip-tg --yes
python3 process_ips.py --target warp --yes
```

#### CDN 测速参数一览
- `--file`, `-f`, `--tg-file`：指定本地已有的 IP 列表文件路径（将自动跳过 Telegram 下载流程，直接解析该文件并合并订阅库继续测速与同步）。
- `--skip-tg`, `--skip-telegram`：跳过从 Telegram 下载，直接从订阅服务器拉取候选 IP。
- `--mode`, `-m`：测速模式。`speed`（带宽模式，默认，按下载速度降序优先）、`latency`（延迟模式，按平均延迟升序优先）。**无论哪种模式，最终展示均会完整体现每个节点的平均延迟、下载速度、丢包率与地区码**。
- `--httping`：[延迟模式可选] 使用 HTTPing 代替 TCPing 进行延迟测速。
- `--ports`, `-p`：待测试端口列表，逗号分隔（默认：`443`，设为 `all` 测试所有端口）。
- `--concurrency`, `-c`, `-n`：延迟测速并发线程数（透传给 `cfst -n`，默认 `200`，支持 `1~1000`，如路由器等弱性能设备可降至 `50`，高性能 VPS 可提至 `500`）。
- `--min-speed`, `-s`：期望最小下载速度下限（MB/s，默认：`5.0`）。**驱动 cfst 跨越延迟排序深入挖掘大带宽低丢包节点**。内置**自适应保底机制**，若全量测速后未凑够达标节点，自动触发 Pass 2 快速保底测速，绝不产生空结果。
- `--max-delay`, `-tl`：平均延迟上限过滤（ms，默认 `0` 不限制，如 `-tl 350` 过滤死慢节点）。
- `--max-loss`, `-tlr`：丢包率上限过滤（范围 0.00~1.00，默认 `1.0`，例如 `-tlr 0.25` 过滤丢包率 > 25% 的不稳定节点，`-tlr 0` 为零丢包严格模式）。
- `--download-time`, `-dt`：单 IP 下载测速最长时间（秒，默认：`10`）。
- `--test-count`, `-dn`：下载测速达标数量（默认：`20`）。
- `--url`, `--speedtest-url`：指定测速文件地址（支持自建 Cloudflare Pages 静态文件如 `/20mb.bin`）。
- `--no-fallback`：禁用未凑齐达标节点时的自动保底测速（默认启用保底）。
- `--top`, `-t`：最终保留的最优 IP 数量（默认：`20`）。
- `--yes`, `-y`：跳过确认提示，自动推送到 Cloudflare Workers 订阅服务器。

---

### 3. Telegram 资源下载与管理助手 (`telegram_tool.py`)

支持直接连接或通过 **SOCKS5 / SOCKS5h (远程 DNS 解析) / HTTP / SOCKS4** 代理连接 Telegram 下载候选 IP 资源：

```bash
# 1. 查看最近的对话/频道列表 (通过 SOCKS5h 远程 DNS 代理)
python telegram_tool.py list --proxy socks5h://127.0.0.1:1080

# 2. 按频道名称搜索并下载包含 "CF中转" 关键字的最新文件 (通过 HTTP 代理)
python telegram_tool.py download -n 'CF中转' --limit 1 -o ./origin-iplist --proxy http://127.0.0.1:7890

# 3. 通过环境变量设置默认代理 (避免每次手动输入 --proxy)
export TG_PROXY="socks5h://127.0.0.1:1080"
python telegram_tool.py download -n 'CF中转' --limit 1 -o ./origin-iplist
```

在 `process_ips.py` 中也可直接使用 `--tg-proxy` / `--proxy` 参数：
```bash
# 执行 CDN 测速流程，并指定通过本地 1080 端口 SOCKS5 代理下载 Telegram 资源
python3 process_ips.py --target cdn --tg-proxy socks5://127.0.0.1:1080 --mode speed --top 20
```

---

### 4. 自动化 Systemd 服务与定时优选同步 (`install.sh`)

`install.sh` 提供了一键将测速脚本与依赖安装至 `/usr/local/bin` 并注册 Systemd 定时器的能力：

#### 核心自动化机制
1. **安装至系统全局路径**：
   - 自动安装 Python 依赖（`requests`, `telethon`），并部署 `cfst`、`process_ips.py`、`warp_tester.py`、`telegram_tool.py` 至 `/usr/local/bin/`；
   - 创建全局命令行快捷入口：`preferred-ip-tester` 与 `preferred-ip-manager`。
2. **每日定时随机测速**：
   - 配置 Systemd Timer，**每天北京时间凌晨 02:00 ~ 06:00 随机时刻**自动执行（`RandomizedDelaySec=4h`，分散请求避免网络风暴）。
3. **Telegram 自动拉取与订阅合并**：
   - 默认从 Telegram 频道拉取最新候选 IP，并与 Cloudflare Workers 在线订阅/历史数据池合并去重。
4. **默认自动推送至订阅端**：
   - 测速完成后自动将 TOP 20 最优 IP 推送更新至 Cloudflare Workers 订阅服务器。
5. **默认大带宽测速地址**：
   - 默认测速下载地址为 `https://movies.jackyang.cc.cd/download?size=200`。

#### 1. 一键安装与配置

```bash
# 默认一键安装组件并启动每日定时服务 (需 root 权限)
sudo bash install.sh --install

# 或安装时指定 Telegram 下载代理 (SOCKS5 / SOCKS5h / HTTP)
sudo bash install.sh --install --proxy socks5h://127.0.0.1:1080
```

#### 2. 全局日常运维命令 (`preferred-ip-manager` / `preferred-ip`)

安装后系统内自动注册全局运维命令，**不再依赖 `install.sh` 脚本**，可在任意终端路径直接调用：

```bash
# 1. 查看定时器计划、下次触发时间与服务状态
preferred-ip-manager status

# 2. 立即手动触发一次测速与订阅端推送 (并实时跟踪日志)
sudo preferred-ip-manager run

# 3. 查看最近测速服务日志 (-f 实时跟踪)
preferred-ip-manager logs -f

# 4. 查看或编辑配置文件
preferred-ip-manager config
sudo preferred-ip-manager config --edit

# 5. 重启 / 启动 / 暂停定时任务
sudo preferred-ip-manager restart
sudo preferred-ip-manager stop
sudo preferred-ip-manager start

# 6. 一键卸载定时服务与所有组件
sudo preferred-ip-manager uninstall -y
```

#### 定时任务配置文件 (`/etc/preferred-ip-manager/config.env`)
可通过修改该配置文件调整定时任务参数：
```bash
TARGET="cdn"               # 优选目标: cdn 或 warp
MODE="speed"               # 测速模式: speed 或 latency
PORTS="443"                # 待测端口
CONCURRENCY="200"          # 并发数
MIN_SPEED="5.0"            # 最低达标速度 (MB/s)
MAX_DELAY="300"            # 最大允许延迟 (ms)
EXTRA_ARGS="-y"            # 默认非交互自动推送参数
CFST_URL="https://movies.jackyang.cc.cd/download?size=200" # 默认测速地址
TG_PROXY="socks5://127.0.0.1:1080"     # Telegram 下载代理 (可选)
CF_SUB_URL="https://sub.19910417.xyz"  # Workers 订阅端地址
CF_SUB_TOKEN=""            # Workers 订阅端更新 Token (若设置将自动推送)
```

---

## 🌐 Cloudflare Pages 专属测速网站部署指南

本项目内置了专为 `CloudflareSpeedTest` (`cfst`) 设计的 Cloudflare Pages 测速站点，**100% 契合 Cloudflare 免费版限制**。

### 1. 为什么选择 Cloudflare Pages 作为测速节点？
- **零配额消耗（静态文件）**：`5mb.bin`、`10mb.bin`、`20mb.bin` 等静态文件直接由全球 CDN 边缘节点分发，**不消耗任何 Worker / Function 请求次数（Pages 静态请求无上限）**，零额外 CPU 开销。
- **流式低内存（动态流）**：`/download?size=50` 接口采用 `ReadableStream` 流式生成，内存恒定 `< 1MB`，单次 CPU 消耗微秒级。
- **精准机房匹配**：`/test` 接口毫秒级返回，自动包含 `CF-Ray`，完美支持 `cfst -httping -cfcolo` 地区筛选。

---

### 2. 一键构建与部署 (`deploy_pages.sh`)

#### 方式 A: 自动通过 Wrangler 部署上线 (推荐)
```bash
# 1. 赋予执行权限并执行一键部署 (默认项目名: cf-speedtest)
bash deploy_pages.sh --deploy

# 2. 或指定自定义项目名称
bash deploy_pages.sh -n my-cf-speedtest --deploy
```

#### 方式 B: 本地生成构建包并网页拖拽部署 (无需安装任何 CLI)
```bash
# 1. 仅在本地生成静态测速文件与 ZIP 包
bash deploy_pages.sh --build-only
```
执行后将生成 `speedtest-pages.zip` 与 `dist/` 目录：
1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)。
2. 进入 **Workers & Pages** -> 点击 **Create application** -> 选择 **Pages** 页签。
3. 点击 **Upload assets**（直接上传资产），输入项目名称（如 `cf-speedtest`）。
4. 上传生成的 `speedtest-pages.zip` 文件并点击 **Deploy site**，5 秒内全球上线！

---

## 🧪 手动测试功能与常用命令说明

部署完成后，你将获得一个形如 `https://<your-project>.pages.dev` 的专属测速站点。以下是完整的手动测试命令参考：

### 1. 使用 `curl` 验证测速端点与响应头
```bash
# 1. 测试静态 20MB 测速文件响应头与缓存策略 (确认 Cache-Control: public 与 Content-Length: 20971520)
curl -I https://<your-project>.pages.dev/20mb.bin

# 2. 测试 HTTPing 延迟接口与识别当前接入的数据中心 (查看 cf-ray 与 x-cf-colo)
curl -s https://<your-project>.pages.dev/test | jq .

# 3. 测试 50MB 动态流式下载响应头
curl -I "https://<your-project>.pages.dev/download?size=50"
```

---

### 2. 使用 CloudflareSpeedTest (`cfst`) 进行测速

#### ⚡ 场景 1: 静态大文件下载测速 (零配额消耗·最推荐)
```bash
# 测试各个 IP 的下载速度 (测试延迟最低的前 10 个 IP，每个 IP 测速 10 秒)
./cfst -url "https://<your-project>.pages.dev/20mb.bin" -dn 10 -dt 10

# 仅保留下载速度 >= 10 MB/s 的最优 IP
./cfst -url "https://<your-project>.pages.dev/20mb.bin" -sl 10 -dn 10
```

#### 🌊 场景 2: 动态流式超大文件下载测速
```bash
# 请求 50MB 动态数据流进行极限带宽压测
./cfst -url "https://<your-project>.pages.dev/download?size=50" -dn 10 -dt 15
```

#### ⏱️ 场景 3: HTTPing 延迟测速与指定机房地区筛选 (`-cfcolo`)
```bash
# 1. 纯延迟测速 (禁用下载测速，按 HTTP 延迟排序)
./cfst -url "https://<your-project>.pages.dev/test" -httping -dd

# 2. 筛选亚洲与美西优质数据中心 (香港 HKG、东京 NRT、圣何塞 SJC、洛杉矶 LAX、新加坡 SIN)
./cfst -url "https://<your-project>.pages.dev/test" -httping -cfcolo HKG,NRT,SJC,LAX,SIN -dd
```

#### 🎯 场景 4: 综合过滤测速 (丢包率 <= 10%、延迟 <= 180ms、速度 >= 15 MB/s)
```bash
./cfst -url "https://<your-project>.pages.dev/20mb.bin" -tl 180 -tlr 0.1 -sl 15 -dn 5
```

---

### 3. 在 Python 自动化脚本中全局使用自建测速节点
```bash
# 方式 A: 命令行参数显式指定
python3 process_ips.py --target cdn --mode speed --url "https://<your-project>.pages.dev/20mb.bin" --min-speed 12.0

# 方式 B: 设置全局环境变量 (适合持久化或定时任务)
export CFST_URL="https://<your-project>.pages.dev/20mb.bin"
python3 process_ips.py --target cdn --mode speed
```

---

### 4. 浏览器可视化在线测速
直接在浏览器中打开 `https://<your-project>.pages.dev`：
- **实时探测**：自动识别并显示当前客户端接入的 Cloudflare Anycast 数据中心代码（如 `HKG` / `NRT` / `SJC`）；
- **一键测速**：点击页面“浏览器快速测速”按钮，实时测量 RTT 往返延迟与下行带宽；
- **命令生成**：页面自动生成适配当前域名的所有 `cfst` 复制指令。

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

