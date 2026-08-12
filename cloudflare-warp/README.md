# Cloudflare WARP & Zero Trust 本地代理客户端部署指南 (SOCKS5 Proxy)

本目录提供基于 Docker 容器或本地 Linux 环境的 **Cloudflare WARP 代理客户端** 自动化部署方案。

通过在本地部署运行 `cloudflare-warp`（结合 Cloudflare Zero Trust 团队接入 / Service Token 自动认证），并集成 `sing-box`（直连出站），在本地提供对外监听的 **SOCKS5 代理**。本地应用或局域网设备只需连接该 SOCKS5 代理，流量即可通过 Cloudflare Zero Trust 安全网络加密出站。

> 📌 **架构定位说明**：
> 本项目定位为**本地代理客户端 (Client Side SOCKS5 Proxy)**，运行于本地机器或本地 Docker 容器中。无需在远程 VPS 上部署本客户端。

---

## 🌐 架构与数据流示意图

```text
[ 本地应用 / 局域网设备 ] 
         │
         ▼ (SOCKS5 代理, 默认 127.0.0.1:1080)
[ sing-box (直连出站) ]
         │
         ▼ (系统 TUN 虚拟网卡接口)
[ Cloudflare WARP Daemon (Zero Trust 团队接入) ]
         │
         ▼ (加密隧道)
[ Cloudflare 全球 Zero Trust 网络 ] ──> [ 目标网站 / 互联网 ]
```

---

## 📁 脚本与文件清单

| 脚本 / 文件 | 核心功能 | 应用场景 |
| --- | --- | --- |
| **`docker-run.sh`** | 本地容器一键构建与运行管理脚本 | 提供一键启动、停止、日志查看、状态检测及构建功能 |
| **`Dockerfile`** | 基于 `ubuntu:latest` 镜像构建包含 WARP 与 sing-box 的容器镜像 | 本地 Docker 容器化部署 |
| **`docker-entrypoint.sh`** | 容器入口脚本，自动初始化 `/dev/net/tun`、启动 WARP、配置 Service Token 并运行 sing-box | 容器内部进程与连通自动化管理 |
| **`install.sh`** | 自动配置官方 Apt/Yum 软件源并安装 `cloudflare-warp` 客户端 | 在原生 Linux 本地主机直接安装 WARP 客户端 |
| **`setup-cloudflare-one.sh`** | (可选) VPS 出口 NAT 转发配置脚本 | 仅在需要将特定 VPS 配置为 Zero Trust 出口节点时备用 |

---

## 🚀 快速开始：本地 Docker 容器化部署 (推荐)

使用 Docker 部署是在本地运行 WARP + sing-box SOCKS5 代理最推荐的方式，环境隔离且支持 Zero Trust **Service Token 无人值守自动登录**。

### 1. 一键启动容器

```bash
cd cloudflare-warp

# 使用 Zero Trust 团队名与 Service Token 启动 SOCKS5 代理 (监听本地 1080 端口)
bash docker-run.sh -t <YOUR_TEAM_NAME> -i <CLIENT_ID> -s <CLIENT_SECRET> -p 1080

# 或使用 ID:SECRET 合并字符串格式传入 Service Token:
bash docker-run.sh -t <YOUR_TEAM_NAME> --service-token <CLIENT_ID>:<CLIENT_SECRET> -p 1080

# 可选：配置带用户名和密码身份验证的 SOCKS5 代理
bash docker-run.sh -t <YOUR_TEAM_NAME> --service-token <CLIENT_ID>:<CLIENT_SECRET> -p 1080 -u myuser -w mypass
```

#### 🛠️ `docker-run.sh` 参数说明

- `-t, --team <TEAM>`：Cloudflare Zero Trust 团队名称 (Team Name)
- `-i, --token-id <CLIENT_ID>`：Zero Trust Service Token Client ID
- `-s, --token-secret <SECRET>`：Zero Trust Service Token Client Secret
- `--service-token <ID:SECRET>`：合并格式传入 Service Token
- `-p, --port <PORT>`：宿主机对外映射的 SOCKS5 代理端口 (默认: `1080`)
- `-u, --user <USER>`：SOCKS5 代理用户名 (可选)
- `-w, --pass <PASS>`：SOCKS5 代理密码 (可选)
- `-n, --name <NAME>`：指定容器名称 (默认: `cloudflare-warp-socks5`)
- `--build`：强行重新构建 Docker 镜像
- `--stop`：停止并删除运行中的容器
- `--logs`：查看容器日志
- `--status`：查看容器运行与 WARP 连通状态

---

### 2. 容器管理快捷命令

```bash
# 查看容器运行日志 (含 WARP 建立与 sing-box 启动日志)
bash docker-run.sh --logs

# 查看 WARP 连通状态与 SOCKS5 端口监听状态
bash docker-run.sh --status

# 停止并删除本地容器
bash docker-run.sh --stop

# 重新构建镜像并启动
bash docker-run.sh -t <YOUR_TEAM_NAME> --service-token <CLIENT_ID>:<CLIENT_SECRET> -p 1080 --build
```

---

### 3. 原生 Docker 命令运行示例

如果习惯直接使用 `docker` 命令：

```bash
# 1. 构建镜像
docker build -t cloudflare-warp-socks5:latest .

# 2. 启动容器 (必须包含 --cap-add=NET_ADMIN 与 --device /dev/net/tun)
docker run -d \
  --name cloudflare-warp-socks5 \
  --cap-add=NET_ADMIN \
  --device /dev/net/tun \
  -p 1080:1080 \
  -e WARP_TEAM="your-zero-trust-team" \
  -e WARP_SERVICE_TOKEN_ID="your-client-id.access" \
  -e WARP_SERVICE_TOKEN_SECRET="your-client-secret" \
  --restart unless-stopped \
  cloudflare-warp-socks5:latest
```

---

## 💻 本地 Linux 主机直接部署 (无 Docker 环境)

若在本地 Linux 主机（如 Ubuntu/Debian）上直接运行，不使用 Docker：

1. **运行安装脚本**：
   ```bash
   sudo bash install.sh
   ```

2. **连接 Zero Trust 团队**：
   ```bash
   # 绑定团队名称
   warp-cli registration organization <YOUR_TEAM_NAME>

   # 切换为全局 WARP 模式并连接
   warp-cli mode warp
   warp-cli connect
   ```

3. **测试连通性**：
   ```bash
   warp-cli status
   curl https://www.cloudflare.com/cdn-cgi/trace
   ```

---

## 🌐 Cloudflare Zero Trust 控制台配置指南

在本地启动客户端前，需在 [Cloudflare Zero Trust 控制台](https://one.dash.cloudflare.com/) 完成团队配置与 Service Token 创建。

### 第一步：获取团队名称 (Team Name)

1. 登录 [Cloudflare Zero Trust 控制台](https://one.dash.cloudflare.com/)。
2. 首次使用时需配置团队域名，格式为 `<your-team-name>.cloudflareaccess.com`。
3. 其中的 **`your-team-name`** 即为参数中的 **`WARP_TEAM` / Team Name**（如 `my-team`）。

---

### 第二步：创建 Service Token (服务令牌)

Service Token 用于本地容器免浏览器人工点击的自动鉴权登录：

1. 在控制台左侧导航栏，点击 **Access** -> **Service Tokens**。
2. 点击右上角 **Create Service Token**。
3. 填入名称（如 `local-warp-socks5`），有效期选择 `Non-expiring` 或 `1 Year`。
4. 点击 **Save** 保存。
5. ⚠️ **保存凭据**：弹窗将一次性展示 `Client ID`（即 `-i` 参数）与 `Client Secret`（即 `-s` 参数），请立即复制保存！

---

### 第三步：配置设备注册策略 (Device Enrollment Rules)

允许使用该 Service Token 进行 WARP 客户端设备注册：

1. 点击 **Settings** -> **WARP Client**。
2. 在 **Device enrollment** 卡片中点击 **Manage** 按钮。
3. 切换至 **Rules** 选项卡，点击 **Add a rule**：
   - **Rule name**：`Allow-Service-Token`
   - **Rule action**：选择 `Service Token`
   - **Selector**：选择 `Service Token`
   - **Value**：选择刚创建的 Service Token 名称
4. 点击 **Save rule** 保存。

---

### 第四步：配置 Split Tunnels (流量切分)

控制哪些流量进入 Zero Trust 隧道：

1. 点击 **Settings** -> **WARP Client** -> **Profile settings** -> 点击编辑目标 Profile (如 `Default`)。
2. 切换至 **Split Tunnels** 选项卡。
3. 模式选择 **Include IPs and domains**，点击 **Manage** -> **Add IP or domain**：
   - **Selector**：`IP Address`
   - **Value**：`0.0.0.0/0`（将全部 IPv4 流量引入 WARP 隧道出站）
4. 点击 **Save destination** 保存。

---

## 🧪 代理效果验证与使用方法

容器启动完成后，即可在本地应用中使用该 SOCKS5 代理：

### 1. 终端 curl 验证 SOCKS5 代理

```bash
# 测试经由 WARP SOCKS5 代理访问 Cloudflare Trace 节点
curl -x socks5://127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace

# 若设置了用户名和密码:
curl -x socks5://myuser:mypass@127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace
```

**预期输出**中应包含：
```text
warp=on
gateway=on (若配置了 Gateway 策略)
```

### 2. 在浏览器或客户端软件中使用

- **代理协议**：`SOCKS5`
- **代理服务器/IP**：`127.0.0.1` (或本地局域网 IP)
- **端口**：`1080` (或自定义 `-p` 端口)
- **认证方式**：根据启动时是否指定 `-u / -w` 配置

---

## 🔍 故障排查

1. **容器日志提示 `Timed out waiting for warp-svc socket`？**
   - 检查宿主机是否已加载 `tun` 模块。可尝试在宿主机运行 `sudo modprobe tun`。

2. **WARP 状态显示 `Registration Missing` 或无法连接？**
   - 检查 Zero Trust 控制台中的 **Device enrollment rules** 是否已正确将 Service Token 加入允许列表中。
   - 确认输入的 `-t` (Team Name)、`-i` (Client ID) 与 `-s` (Client Secret) 拼写无误。

3. **端口冲突报错 `address already in use`？**
   - 说明本地 1080 端口已被其他服务占用。运行时指定新的本地端口即可，如 `bash docker-run.sh ... -p 10800`。
