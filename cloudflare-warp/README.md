# Cloudflare WARP & Zero Trust 部署指南 (本地代理客户端 & VPS 出口转发)

本目录提供 Cloudflare WARP 相关的两套自动化部署方案：
1. **本地 SOCKS5 代理客户端 (Docker / Linux)**：在本地机器运行 `cloudflare-warp` 客户端并结合 `sing-box` (直连出站)，对外提供 **SOCKS5 代理**。
2. **VPS 侧 Zero Trust 出口 NAT 转发 (`setup-cloudflare-one.sh`)**：在远程 VPS 宿主机上开启 IP 转发与 NAT MASQUERADE，将 VPS 配置为 Cloudflare Zero Trust 的指定流量出口节点 (Exit Node)。

---

## 🌐 架构示意图

### 模式一：本地 SOCKS5 代理客户端 (本地机器 / 本地 Docker 部署)

```text
[ 本地应用 / 局域网设备 ] 
         │
         ▼ (SOCKS5 代理, 默认 127.0.0.1:1080)
[ sing-box (直连出站) ]
         │
         ▼ (系统 TUN 虚拟网卡接口)
[ Cloudflare WARP Daemon (Zero Trust 团队 / Service Token) ]
         │
         ▼ (加密隧道)
[ Cloudflare 全球 Zero Trust 网络 ] ──> [ 目标网站 / 互联网 ]
```

---

### 模式二：VPS 侧 Zero Trust 出口 NAT 转发 (VPS 宿主机部署)

```text
[ 客户端设备 (WARP / Connector) ] ──(Zero Trust 隧道)──> [ VPS (warp0 网卡) ] ──(iptables NAT)──> [ 目标网站 / Internet (显示 VPS 公网 IP) ]
```

---

## 📁 脚本与文件清单

| 脚本 / 文件 | 核心功能 | 部署位置与场景 |
| --- | --- | --- |
| **`docker-run.sh`** | 本地容器一键构建与运行管理脚本 | **本地部署**：一键启动/停止本地 WARP + sing-box 容器 |
| **`Dockerfile`** | 基于 `ubuntu:latest` 镜像构建包含 WARP 与 sing-box 的镜像 | **本地部署**：本地 Docker 镜像构建 |
| **`docker-entrypoint.sh`** | 容器入口脚本，自动初始化 `/dev/net/tun`、启动 WARP、配置 Service Token 并运行 sing-box | **本地部署**：容器自动连通与生命周期管理 |
| **`install.sh`** | 自动配置官方 Apt/Yum 软件源并安装 `cloudflare-warp` 客户端 | **本地 / VPS 部署**：原生 Linux 环境安装官方 WARP 客户端 |
| **`setup-cloudflare-one.sh`** | VPS 出口 NAT 转发与开机双重持久化配置脚本 | **VPS 宿主机部署**：将 VPS 配置为 Cloudflare Zero Trust 出口节点 (NAT Gateway) |

---

## 🚀 一、本地 SOCKS5 代理客户端部署 (推荐 Docker)

在本地机器上运行 WARP + sing-box SOCKS5 代理，支持 Zero Trust **Service Token 无人值守自动登录**。

### 1. 一键启动本地容器

```bash
cd cloudflare-warp

# 使用 Zero Trust 团队名与 Service Token 启动 SOCKS5 代理 (监听本地 1080 端口)
sudo bash docker-run.sh -t <YOUR_TEAM_NAME> -i <CLIENT_ID> -s <CLIENT_SECRET> -p 1080

# 或使用 ID:SECRET 合并格式传入 Service Token:
sudo bash docker-run.sh -t <YOUR_TEAM_NAME> --service-token <CLIENT_ID>:<CLIENT_SECRET> -p 1080

# 可选：配置带用户名和密码认证的 SOCKS5 代理
sudo bash docker-run.sh -t <YOUR_TEAM_NAME> --service-token <CLIENT_ID>:<CLIENT_SECRET> -p 1080 -u myuser -w mypass
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

### 2. 本地容器快捷管理指令

```bash
# 查看容器运行日志
sudo bash docker-run.sh --logs

# 查看 WARP 连通状态与 SOCKS5 端口监听状态
sudo bash docker-run.sh --status

# 停止并删除本地容器
sudo bash docker-run.sh --stop
```

---

### 3. 本地 Linux 原生直接部署 (无 Docker)

若在本地 Linux 主机（如 Ubuntu/Debian）上直接运行，不使用 Docker：

1. **运行安装脚本**：
   ```bash
   sudo bash install.sh
   ```

2. **连接 Zero Trust 团队**：
   ```bash
   warp-cli registration organization <YOUR_TEAM_NAME>
   warp-cli mode warp
   warp-cli connect
   ```

---

## 🖥️ 二、VPS 侧 Zero Trust 出口 NAT 转发配置 (`setup-cloudflare-one.sh`)

如果需要将 **VPS 配置为 Cloudflare Zero Trust 的指定出口节点 (Exit Node / NAT Gateway)**，使得客户端经过 Cloudflare 网络的流量由该 VPS 的公网 IP 访问目标网站，请在 **VPS 宿主机** 上运行此脚本。

### 核心功能
- 自动开启 Linux 内核 IP 转发 (`net.ipv4.ip_forward = 1`)。
- 自动配置 `iptables` NAT MASQUERADE 转发规则（智能支持 `warp0` 隧道隔离转发或通用转发）。
- 自动启用 Systemd 开机服务 (`cloudflare-one-nat.service`) 与 netfilter 防火墙规则持久化。

---

### 在 VPS 上的部署与运行命令

在 VPS 宿主机上以 `root` 权限（或 `sudo`）运行：

```bash
# 1. 自动检测外网网卡并一键开启 VPS 出口 NAT 转发 (远程一键运行)
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/cloudflare-warp/setup-cloudflare-one.sh) --setup

# 或在 VPS 本地运行
sudo bash setup-cloudflare-one.sh --setup

# 2. VPS 已安装 cloudflare-warp 时，指定外网网卡 eth0 与 WARP 网卡 warp0 隔离转发
sudo bash setup-cloudflare-one.sh --setup -i eth0 -w warp0

# 3. 未安装 cloudflare-warp 客户端时 (如使用 cloudflared Connector)，强制使用通用转发
sudo bash setup-cloudflare-one.sh --setup -w any

# 4. 查看当前 VPS 内核转发、Systemd 服务及 iptables 规则状态
sudo bash setup-cloudflare-one.sh --status

# 5. 清除并还原 VPS 上的 NAT 转发规则与开机持久化服务
sudo bash setup-cloudflare-one.sh --unset
```

#### 🛠️ `setup-cloudflare-one.sh` 参数说明

```text
Usage: setup-cloudflare-one.sh [MODE] [OPTIONS]

模式 (默认为 --setup):
  -c, --setup, --enable   开启并配置 VPS 上 Cloudflare One NAT 转发规则 (含开机双重持久化)
  -u, --unset, --disable   清除并还原 VPS 上 Cloudflare One NAT 转发规则 (并清理开机服务)
  -s, --status            查看当前内核转发、iptables NAT 与 Systemd 持久化服务状态
  -h, --help              显示帮助信息

选项:
  -i, --interface <IF>    指定 VPS 外网网卡名称 (默认自动检测，如 eth0, ens3)
  -w, --warp-if <IF>      指定入站隧道网卡名称 (默认: auto。若存在 warp0 则自动绑定 warp0，否则使用 any 通用转发)
```

---

## 🌐 三、Cloudflare Zero Trust 控制台配置指南

无论是在本地运行客户端还是在 VPS 上配置出口，均需在 [Cloudflare Zero Trust 控制台](https://one.dash.cloudflare.com/) 完成对应配置。

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

### 第五步：配置网络路由与出口节点 (Networks Routes / Exit Nodes)

若需指定特定流量由在 VPS 上运行了 `setup-cloudflare-one.sh` 的节点出口：

1. 点击 **Networks** -> **Routes**。
2. 点击 **Create Route** 按钮：
   - **CIDR**：填入目标 IP 网段（例如 `0.0.0.0/0`）
   - **Tunnel / Destination**：选择绑定的 VPS WARP 节点设备或 WARP Connector 实例
3. 点击 **Save** 保存使路由生效。

---

## 🧪 四、本地代理效果验证与使用方法

本地 SOCKS5 容器启动完成后，即可在本地应用中使用该代理：

### 终端 curl 验证 SOCKS5 代理

> 💡 **提示**：建议使用 `socks5h://`（带 `h` 表示 DNS 域名解析在代理服务端 / WARP 内部完成，可有效防止本地 DNS 污染导致连接重置）。

```bash
# 1. 测试经由 WARP SOCKS5 代理访问 Cloudflare Trace 节点
curl -x socks5h://127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace

# 2. 测试访问外网
curl -x socks5h://127.0.0.1:1080 https://www.google.com

# 3. 若设置了代理用户名和密码:
curl -x socks5h://myuser:mypass@127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace
```

**预期输出**中应包含：
```text
warp=on
gateway=on (若配置了 Gateway 策略)
```

---

## 🔍 五、常见问题与故障排查

1. **`setup-cloudflare-one.sh` 应该部署在本地还是 VPS？**
   - `setup-cloudflare-one.sh` 只能部署在**远程 VPS 宿主机**上，作用是开启 Linux 内核 IP 转发与 NAT 转发，使 VPS 能够充当出口网关。本地机器仅需运行 `docker-run.sh` / `install.sh` 即可。

2. **本地容器日志提示 `Timed out waiting for warp-svc socket`？**
   - 检查宿主机是否已加载 `tun` 模块。可尝试在宿主机运行 `sudo modprobe tun`。

3. **WARP 状态显示 `Registration Missing` 或无法连接？**
   - 检查 Zero Trust 控制台中的 **Device enrollment rules** 是否已正确将 Service Token 加入允许列表中。
   - 确认输入的 `-t` (Team Name)、`-i` (Client ID) 与 `-s` (Client Secret) 拼写无误。
