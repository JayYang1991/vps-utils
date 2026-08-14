# Cloudflare WARP & Zero Trust 部署指南 (本地代理客户端 & VPS 出口转发)

本目录提供 Cloudflare WARP 相关的两套自动化部署方案：
1. **本地 SOCKS5 代理客户端 (Docker + Systemd 服务封装)**：在本地机器运行 `cloudflare-warp` 容器并结合 `sing-box` (直连出站)，对外提供 **SOCKS5 代理**。支持一键注册为 **Systemd 系统服务**，自动管理 **`172.17.0.0/16` 策略路由**（启动时添加，退出时清理）。
2. **VPS 侧 Zero Trust 出口 NAT 转发 (`setup-cloudflare-one.sh`)**：在远程 VPS 宿主机上开启 IP 转发与 NAT MASQUERADE，将 VPS 配置为 Cloudflare Zero Trust 的指定流量出口节点 (Exit Node)。

---

## 🌐 架构示意图

### 模式一：本地 SOCKS5 代理客户端 (Docker + Systemd + 策略路由隔离)

```text
[ 本地应用 / 局域网设备 ] 
         │
         ▼ (SOCKS5 代理, 默认 127.0.0.1:1080)
[ Docker 容器: sing-box (直连出站) ]
         │
         ▼ (容器内部 TUN 虚拟网卡接口)
[ Cloudflare WARP Daemon (Zero Trust 团队 / Service Token) ]
         │
         ▼ (加密隧道)
[ Cloudflare 全球 Zero Trust 网络 ] ──> [ 目标网站 / 互联网 ]
```

> 🛡️ **策略路由隔离保障**：
> 当包装为 Systemd 服务启动时，系统会自动添加策略路由规则 `from 172.17.0.0/16 priority 8999 lookup main`。
> 从而确保 Docker 容器流量在宿主机被其它全局 TUN 代理（如 Clash TUN）接管时，能够走主路由表直连出口，避免产生路由死循环或握手异常。

---

### 模式二：VPS 侧 Zero Trust 出口 NAT 转发 (VPS 宿主机部署)

```text
[ 客户端设备 (WARP / Connector) ] ──(Zero Trust 隧道)──> [ VPS (warp0 网卡) ] ──(iptables NAT)──> [ 目标网站 / Internet (显示 VPS 公网 IP) ]
```

---

## 📁 脚本与文件清单

| 脚本 / 文件 | 核心功能 | 部署位置与场景 |
| --- | --- | --- |
| **`docker-run.sh`** | 本地容器构建、运行与 **Systemd 系统服务管理** 脚本 | **本地部署**：一键安装 Systemd 服务、管理策略路由、启停容器 |
| **`cloudflare-warp-socks5.service`** | Systemd 服务 Unit 模板，包含开机自启、优雅退出与策略路由钩子 | **本地部署**：宿主机系统服务配置文件 |
| **`Dockerfile`** | 基于 `ubuntu:24.04` 构建包含 WARP、sing-box 与健康检查的镜像 | **本地部署**：Docker 镜像构建 |
| **`docker-entrypoint.sh`** | 容器入口脚本，自动初始化 TUN、启动 WARP、配置 Service Token 并运行 sing-box | **本地部署**：容器自动连通与生命周期管理 |
| **`install.sh`** | 自动配置官方 Apt/Yum 软件源并安装 `cloudflare-warp` 客户端 | **本地 / VPS 部署**：原生 Linux 环境安装官方 WARP 客户端 |
| **`setup-cloudflare-one.sh`** | VPS 出口 NAT 转发与开机双重持久化配置脚本 | **VPS 宿主机部署**：将 VPS 配置为 Cloudflare Zero Trust 出口节点 (NAT Gateway) |

---

## 🚀 一、本地 SOCKS5 代理客户端部署 (推荐 Systemd 服务封装)

使用 `docker-run.sh` 脚本可将 WARP + sing-box 容器打包为 Systemd 系统服务，享受开机自启、日志统一收集与策略路由自动生命周期管理。

### 1. 一键安装并启动为 Systemd 系统服务 (推荐)

```bash
cd cloudflare-warp

# 使用 Zero Trust 团队名与 Service Token 安装为 Systemd 服务 (监听本地 1080 端口)
sudo bash docker-run.sh --install-service -t <YOUR_TEAM_NAME> -i <CLIENT_ID> -s <CLIENT_SECRET> -p 1080

# 或使用 ID:SECRET 合并格式传入 Service Token:
sudo bash docker-run.sh --install-service -t <YOUR_TEAM_NAME> --service-token <CLIENT_ID>:<CLIENT_SECRET> -p 1080

# 可选：设置 SOCKS5 鉴权用户名与密码:
sudo bash docker-run.sh --install-service -t <YOUR_TEAM_NAME> --service-token <CLIENT_ID>:<CLIENT_SECRET> -p 1080 -u myuser -w mypass
```

---

### 2. 🔐 敏感凭据安全隔离机制

* **完全脱离 Systemd 单元文件**：Service Token、Secret、SOCKS5 密码等敏感认证信息**不会**写入 `/etc/systemd/system/*.service` 文件，防止被 `systemctl show` 或非特权服务审查泄漏。
* **独立加密存储**：所有环境变量独立保存在宿主机的 `/etc/cloudflare-warp/warp.env` 文件中，文件权限严格设置为 `0600`（仅 `root` 可读写），并通过 Docker 引擎的 `--env-file` 原生挂载至容器中。

---

### 3. 策略路由（Policy Routing）自动管理说明

当使用 `--install-service` 安装为 Systemd 服务后：
1. **服务启动时（`ExecStartPost`）**：
   自动检测并注入内核策略路由：
   ```bash
   /sbin/ip rule add from 172.17.0.0/16 priority 8999 lookup main
   ```
   **作用**：将 Docker 网桥产生的源流量（`172.17.0.0/16`）直接重定向至系统 `main` 路由表，彻底避免宿主机其它 TUN 网卡（如 Clash/Mihomo 等）产生路由冲突与死循环。
2. **服务停止时（`ExecStopPost`）**：
   自动清理策略路由规则，还原宿主机网络干净状态：
   ```bash
   /sbin/ip rule del from 172.17.0.0/16 priority 8999 lookup main
   ```

---

### 4. 服务状态、测试与运维指令

```bash
# 1. 查看服务运行状态、策略路由规则与 WARP 连通状态
sudo bash docker-run.sh --status

# 2. 快速测试 SOCKS5 代理连通性 (自动调用 curl 请求 Cloudflare Trace)
sudo bash docker-run.sh --test

# 3. 查看实时运行日志 (优先使用 journalctl)
sudo bash docker-run.sh --logs
# 或直接使用:
journalctl -u cloudflare-warp-socks5 -f

# 4. 重启 / 停止服务
sudo systemctl restart cloudflare-warp-socks5
sudo bash docker-run.sh --stop

# 5. 卸载 Systemd 服务与规则
sudo bash docker-run.sh --uninstall-service
```

---

### 4. 也可以直接以 Docker 独立容器模式运行

如果不想注册 Systemd 服务，也可以直接前台/后台运行容器：

```bash
# 启动独立容器 (脚本同样会自动配置策略路由)
sudo bash docker-run.sh -t <YOUR_TEAM_NAME> --service-token <CLIENT_ID>:<CLIENT_SECRET> -p 1080

# 停止并清理独立容器
sudo bash docker-run.sh --stop
```

#### 🛠️ `docker-run.sh` 常用参数说明

- `-t, --team <TEAM>`：Cloudflare Zero Trust 团队名称 (Team Name)
- `-i, --token-id <CLIENT_ID>`：Zero Trust Service Token Client ID
- `-s, --token-secret <SECRET>`：Zero Trust Service Token Client Secret
- `--service-token <ID:SECRET>`：合并格式传入 Service Token
- `-p, --port <PORT>`：宿主机对外映射的 SOCKS5 代理端口 (默认: `1080`)
- `-u, --user <USER>`：SOCKS5 代理用户名 (可选)
- `-w, --pass <PASS>`：SOCKS5 代理密码 (可选)
- `-n, --name <NAME>`：指定容器/服务名称 (默认: `cloudflare-warp-socks5`)
- `--route-src <CIDR>`：策略路由豁免的源地址网段 (默认: `172.17.0.0/16`)
- `--route-prio <PRIO>`：策略路由规则优先级 (默认: `8999`)
- `--install-service`：注册并启动 Systemd 服务
- `--uninstall-service`：卸载 Systemd 服务并清理规则
- `--build, --rebuild, -b`：重新编译 Docker 镜像 (仅构建镜像，不启动容器)
- `--no-cache`：构建 Docker 镜像时不使用缓存 (全新编译)
- `--status`：查看完整运行状态与连通性
- `--test`：测试代理有效性
- `--logs`：查看日志
- `--stop`：停止服务与容器

---

## 🖥️ 二、VPS 侧 Zero Trust 出口 NAT 转发配置 (`setup-cloudflare-one.sh`)

如果需要将 **VPS 配置为 Cloudflare Zero Trust 的指定出口节点 (Exit Node / NAT Gateway)**，使得客户端经过 Cloudflare 网络的流量由该 VPS 的公网 IP 访问目标网站，请在 **VPS 宿主机** 上运行此脚本。

### 在 VPS 上的部署与运行命令

在 VPS 宿主机上以 `root` 权限（或 `sudo`）运行：

```bash
# 1. 自动检测外网网卡并一键开启 VPS 出口 NAT 转发
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

---

## 🌐 三、Cloudflare Zero Trust 控制台配置指南

无论是在本地运行客户端还是在 VPS 上配置出口，均需在 [Cloudflare Zero Trust 控制台](https://one.dash.cloudflare.com/) 完成对应配置。

### 第一步：获取团队名称 (Team Name)
1. 登录 [Cloudflare Zero Trust 控制台](https://one.dash.cloudflare.com/)。
2. 团队域名格式为 `<your-team-name>.cloudflareaccess.com`，其中的 **`your-team-name`** 即为参数中的 **`WARP_TEAM`**。

### 第二步：创建 Service Token (服务令牌)
1. 在控制台左侧导航栏，点击 **Access** -> **Service Tokens**。
2. 点击右上角 **Create Service Token**。
3. 填入名称（如 `local-warp-socks5`），保存后复制记录 `Client ID`（即 `-i` 参数）与 `Client Secret`（即 `-s` 参数）。

### 第三步：配置设备注册策略 (Device Enrollment Rules)
1. 点击 **Settings** -> **WARP Client**。
2. 在 **Device enrollment** 卡片中点击 **Manage** 按钮。
3. 切换至 **Rules** 选项卡，点击 **Add a rule**：
   - **Rule name**：`Allow-Service-Token`
   - **Rule action**：选择 `Service Token`
   - **Selector**：选择 `Service Token`
   - **Value**：选择刚创建的 Service Token 名称
4. 点击 **Save rule** 保存。

---

## 🧪 四、本地代理效果验证与使用方法

```bash
# 1. 使用内置指令测试:
sudo bash docker-run.sh --test

# 2. 手动 curl 验证 SOCKS5 代理 (推荐 socks5h:// 防 DNS 污染)
curl -x socks5h://127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace
```

**预期输出**中应包含：
```text
warp=on
gateway=on (若配置了 Gateway 策略)
```
