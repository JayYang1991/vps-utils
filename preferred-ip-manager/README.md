# Preferred IP Manager (edgetunnel 优选 IP / 订阅管理服务)

`preferred-ip-manager` 是一个集成了 **Cloudflare Worker 无服务器订阅管理** 与 **Python 本地自动化测速同步工具链** 的完整优选 IP 解决方案。

它专为 edgetunnel / VLESS 协议设计，一方面提供高可用的服务端聚合订阅能力与 Web 管理后台，另一方面通过 Python 脚本实现自动从 Telegram 抓取最新 IP 资源、调起 CloudflareSpeedTest (`cfst`) 测速，并自动将优选结果同步至订阅服务器。

---

## ✨ 核心特性

### ☁️ Cloudflare Worker 服务端 (`sub-worker.js`)
- 🔗 **动态订阅生成 (`/sub`)**：自动合并远程优选源与本地 KV 保存的优选 IP，实时动态拼装生成标准 Base64 编码的 VLESS / Trojan 订阅链接。
- 🖥️ **可视化管理后台 (`/admin`)**：
  - 现代化暗黑玻璃拟物化风格 UI。
  - 支持优选 IP 列表 (`ADD.txt`) 与 自定义节点列表 (`CUSTOM_NODES.txt`) 切页编辑。
  - 支持 **覆盖模式** 与 **追加模式**。
  - 内置在线数据格式校验，防止误填无效 IP、端口或错误协议链接。
- 🤖 **自动化 API (`/api/update`)**：
  - 供测速脚本自动推送最新优选 IP 的 HTTP PUT 接口。
  - 支持 Header `Authorization` 或 URL Token 鉴权。
  - 支持原始文本流 (`--data-binary`) 与 表单上传 (`multipart/form-data`)。

### 🐍 Python 自动化工具链 (`process_ips.py` & `telegram_tool.py`)
- 📥 **Telegram 极速下载器 (`telegram_tool.py`)**：基于 Telethon / MTProto 协议，支持多连接并发加速下载、断点续传及资源列表预览。
- ⚡ **自动化测速与同步全流程 (`process_ips.py`)**：
  - **自动拉取**：自动从指定的 Telegram 频道/群组下载最新的中转 IP 列表。
  - **智能合并**：解析本地 IP:Port 列表，并自动抓取现有订阅服务器中的已有 IP 进行合并去重。
  - **无干扰测速**：测速期间自动挂起本地代理服务（如 `sing-box`），调用 `cfst` 工具进行带宽模式（下载速度）或延迟模式（HTTPing）测试。
  - **自动同步**：挑选测速表现最优的 Top N 个 IP，自动生成结果文件并通过 HTTP PUT 同步更新至订阅 Worker 服务器。
  - **现场恢复**：测速完毕后自动恢复代理服务，并彻底清理所有临时测速文件。

---

## ⚙️ 环境变量配置说明

项目包含服务端和本地脚本两套配置，请按需设置：

### 1. Cloudflare Worker 环境变量

在 Worker 控制台的 **Settings -> Variables** 中配置：

| 变量名 | 类型 | 是否必填 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- | :--- |
| `ADMIN` | Plain Text | **必填** | - | Web 管理后台 (`/admin`) 的登录密码 |
| `TOKEN` | Plain Text | **必填** | - | `/api/update` 自动化接口更新所用的 API Key / Token |
| `SUB_SOURCE` | Plain Text | 可选 | `https://sub.cmliussss.net` | 远程优选 IP 订阅源地址 |

> 🗄️ **KV 绑定要求**：须添加 KV 命名空间绑定，Variable Name 设为 `KV`。 Worker 会在 KV 中维护 `ADD.txt`、`CUSTOM_NODES.txt` 和 `UPDATE_TIME`。

### 2. Python 自动化脚本环境变量

在运行 Python 脚本前，建议在系统终端或 Shell 配置文件 (`~/.bashrc` / `~/.zshrc`) 中设置以下环境变量：

```bash
# Telegram 客户端 API 凭证 (从 https://my.telegram.org 申请)
export TG_API_ID="你的_TG_API_ID"
export TG_API_HASH="你的_TG_API_HASH"

# 订阅服务器 API 更新 Token (须与 Worker 的 TOKEN 保持一致)
export CF_SUB_TOKEN="你的_WORKER_UPDATE_TOKEN"
```

---

## 🐍 Python 自动化运维与优选工具链

### 依赖与准备工作

1. **一键智能检查并安装 Python 依赖库**：
   项目内置了自动依赖检查与安装脚本 [`install_deps.sh`](./install_deps.sh)，会自动检查 `requests` 和 `telethon`，已存在则直接跳过：
   ```bash
   ./install_deps.sh
   ```
   也可以手动使用 pip 安装：
   ```bash
   pip install telethon requests
   ```
2. **硬件/可执行文件准备**：
   - 确保同级目录下存在 CloudflareSpeedTest 二进制文件 `cfst`，并赋予可执行权限 (`chmod +x cfst`)。
   - 确保存在 `origin-iplist` 目录，用于接收从 Telegram 下载的原始 IP 文件。

---

### 1. 自动化 IP 测速与同步工具 (`process_ips.py`)

`process_ips.py` 是全流程集成脚本，一键完成“下载 IP 列表 -> 合并已有订阅 IP -> 暂停代理 -> cfst 测速 -> 筛选最优 IP -> 上传至订阅服务器 -> 恢复代理”。

```bash
# 1. 默认带宽模式测速 (测试下载速度，保留速度 >= 10 MB/s 的前 20 个 IP 并上传)
python process_ips.py --mode speed --top 20 --min-speed 10.0

# 2. 延迟模式测速 (HTTPing 测试延迟，保留延迟最低的前 15 个 IP 并上传)
python process_ips.py --mode latency --top 15
```

#### 参数说明
- `--mode`, `-m`：测速模式。`speed`（带宽模式，默认）或 `latency`（延迟模式）。
- `--top`, `-t`：最终保留并同步的最优 IP 数量（默认：`20`）。
- `--min-speed`, `-s`：[仅带宽模式] 最小下载速度过滤阈值（MB/s，默认：`10.0`）。

---

### 2. Telegram 资源下载与管理助手 (`telegram_tool.py`)

`telegram_tool.py` 是一个通用的 Telegram 命令行助手，基于 MTProto 协议实现大文件极速并发下载与会话管理。

#### 常见命令用法

**查看最近的对话/频道列表**：
```bash
python telegram_tool.py list
```

**展示指定聊天的消息与文件列表**：
```bash
python telegram_tool.py show --id <CHAT_ID> --limit 20
```

**从 Telegram 频道极速下载文件**：
```bash
# 按频道名称搜索并下载包含 "CF中转" 关键字的最新 1 个文件到指定目录
python telegram_tool.py download -n 'CF中转' --limit 1 -o ./origin-iplist

# 使用并发通道模式极速下载大文件
python telegram_tool.py download --id <CHAT_ID> --mode parallel --concurrency 4 --output ./downloads
```

---

## 🚀 Cloudflare Worker 部署指南

### 方法一：通过 Cloudflare 控制台网页部署

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)。
2. 进入 **Workers & Pages** -> **Create Application** -> **Create Worker**。
3. 输入 Worker 名称，点击 **Deploy**。
4. 点击 **Edit code**，将 [`sub-worker.js`](./sub-worker.js) 的代码粘贴覆盖并保存部署。
5. 在 Worker 的 **Settings -> Variables** 中配置环境变量 `ADMIN`、`TOKEN`，并绑定 KV 命名空间（变量名为 `KV`）。

### 方法二：通过 Wrangler CLI 部署

创建 `wrangler.toml` 文件：

```toml
name = "preferred-ip-manager"
main = "sub-worker.js"
compatibility_date = "2024-01-01"

[vars]
SUB_SOURCE = "https://sub.cmliussss.net"

kv_namespaces = [
  { binding = "KV", id = "你的_KV_NAMESPACE_ID" }
]
```

命令行设置密钥并部署：

```bash
npx wrangler secret put ADMIN
npx wrangler secret put TOKEN
npx wrangler deploy
```

---

## 📖 Worker 接口指南

### 1. 订阅接口 (`/sub`)

客户端请求格式：
```http
GET https://<your-worker-domain>/sub?host=<your-domain>&uuid=<your-uuid>
```
返回经过 Base64 编码的 VLESS 节点列表。

---

### 2. Web 管理后台 (`/admin`)

访问 `https://<your-worker-domain>/admin`：
- 支持使用 `ADMIN` 密码登录。
- **优选 IP 配置**：按 `地址:端口#备注` 格式在线编辑或追加。
- **自定义节点配置**：支持追加或覆盖全量节点链接（如 `vless://...`）。

---

### 3. 自动化更新 API (`/api/update`)

HTTP `PUT` 请求样例：

```bash
# 通过 PUT 直接更新/覆盖优选 IP 列表
curl -X PUT "https://<your-worker-domain>/api/update?token=YOUR_TOKEN&type=ips&mode=overwrite" \
     -H "Content-Type: text/plain" \
     --data-binary @ip_result.txt
```

---

## 📝 数据格式说明

| 数据类型 | 格式要求 | 校验规则示例 |
| :--- | :--- | :--- |
| **优选 IP (`ADD.txt`)** | `IP:端口#备注` 或 `域名:端口#备注` | 必须包含端口，端口范围在 `1-65535` |
| **自定义节点 (`CUSTOM_NODES.txt`)** | 节点协议链接 | 必须为 `vless://`、`trojan://` 等 URI 格式 |

---

## 🔐 安全规范与注意事项

1. **凭证安全**：妥善保管 `ADMIN` 密码、`TOKEN` 以及 `TG_API_ID` / `TG_API_HASH`，切勿泄露或提交至公开仓库。
2. **权限说明**：`process_ips.py` 脚本在测速前后会执行 `sudo systemctl stop/start sing-box.service` 操作，以确保测速不受本地代理干扰。运行用户需具备相应的 `sudo` 权限。

---

## 📄 开源许可

本项目遵循 MIT 许可证。
