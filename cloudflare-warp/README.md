# Cloudflare WARP & Cloudflare One VPS 出口自动化部署与配置指南

本目录提供 Cloudflare WARP 官方客户端的自动化安装部署脚本 (`install.sh`)，以及在 VPS 上配置 **Cloudflare One / Zero Trust 自定义流量出口 (NAT 转发)** 的一键脚本 (`setup-cloudflare-one.sh`)。

通过这套方案，你可以将客户端（如手机、电脑上的 Cloudflare WARP 客户端）代理的流量通过 Cloudflare Zero Trust 网络传输后，**指定流量出口为该 VPS 的公网 IP**。

---

## 📁 脚本清单与功能说明

| 脚本 / 文件 | 核心功能 | 常用应用场景 |
| --- | --- | --- |
| **`install.sh`** | 自动配置官方 Apt/Yum 软件源并安装 `cloudflare-warp` 软件包与 `warp-svc` 服务 | 新增或重新安装 Cloudflare WARP 客户端 (用于 VPS 本地接入 WARP 网络) |
| **`setup-cloudflare-one.sh`** | 自动开启 Linux 内核 IP 转发 (`ip_forward`) 并配置 `iptables` NAT MASQUERADE 规则，智能支持 `warp0` 接口隔离或纯 NAT 通用转发模式 | 将 VPS 配置为 Cloudflare One WARP 流量的指定出口节点 (Exit Node / NAT Gateway)，无论 VPS 是否安装 `cloudflare-warp` 均可适用 |
| **`Dockerfile`** | 基于 `ubuntu:latest` 基础镜像，使用 `install.sh` 安装 Cloudflare WARP 与 sing-box | 容器化部署 WARP + sing-box SOCKS5 代理 |
| **`docker-entrypoint.sh`** | 容器入口脚本，自动初始化 `/dev/net/tun`、启动 `warp-svc`、注册 Zero Trust 团队、连接 WARP 并启动 sing-box | 容器自动运维与生命周期管理 |
| **`docker-run.sh`** | 容器化一键构建与运行管理脚本 | 提供命令行构建、启动、日志查看、状态检测与清理功能 |

---

## 🚀 快速开始

### 1. 安装 Cloudflare WARP 客户端 (`install.sh`，可选)

> 💡 **提示**：若 VPS 上仅运行 Cloudflare Tunnel (`cloudflared`) WARP Connector 或纯 NAT 转发，**无需安装此软件包**，直接运行步骤 2 即可。

在 VPS 上以 `root` 权限运行以下命令，自动识别系统发行版并安装官方 `cloudflare-warp`：

```bash
# 远程一键安装
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/cloudflare-warp/install.sh)

# 或本地运行
cd cloudflare-warp
sudo bash install.sh
```

> **重新安装模式**：若环境损坏可传入 `-r` 或 `--reinstall` 参数：
> `sudo bash install.sh -r`

---

### 2. 配置 VPS 上 Cloudflare One 出口 NAT 转发 (`setup-cloudflare-one.sh`)

在 VPS 上开启内核 IP 转发及 `iptables` NAT 转发，使经过 Cloudflare One 的 WARP 流量以本 VPS 公网 IP 作为出口：

```bash
# 开启与应用 NAT 转发配置 (远程一键运行)
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/cloudflare-warp/setup-cloudflare-one.sh) --setup

# 或本地运行
sudo bash setup-cloudflare-one.sh --setup
```

#### 🛠️ `setup-cloudflare-one.sh` 参数说明

```text
Usage: setup-cloudflare-one.sh [MODE] [OPTIONS]

模式 (默认为 --setup):
  -c, --setup, --enable   开启并配置 VPS 上 Cloudflare One NAT 转发规则
  -u, --unset, --disable   清除并还原 VPS 上 Cloudflare One NAT 转发规则
  -s, --status            查看当前内核转发与 iptables NAT 状态
  -h, --help              显示帮助信息

选项:
  -i, --interface <IF>    指定 VPS 外网网卡名称 (默认自动检测，如 eth0, ens3)
  -w, --warp-if <IF>      指定入站隧道网卡名称 (默认: auto。若检测到 warp0 则自动绑定 warp0 隔离转发；若无 warp0 则自动使用 any 通用转发模式)
```

#### 💡 实用操作命令示例：

```bash
# 1. 智能自动检测并开启 NAT 出口配置 (若未安装 cloudflare-warp 自动开启通用 NAT 转发)
sudo bash setup-cloudflare-one.sh --setup

# 2. 未安装 cloudflare-warp 时，显式指定使用通用 NAT 转发模式
sudo bash setup-cloudflare-one.sh --setup -w any

# 3. 已安装 cloudflare-warp 时，手动指定外网网卡 eth0 与 WARP 网卡 warp0 隔离转发
sudo bash setup-cloudflare-one.sh --setup -i eth0 -w warp0

# 4. 查看当前内核转发与 iptables NAT 规则状态
sudo bash setup-cloudflare-one.sh --status

# 5. 清除并还原所有 NAT 转发与 sysctl 配置
sudo bash setup-cloudflare-one.sh --unset
```

---

### 3. 容器化一键部署 Cloudflare WARP + Sing-box SOCKS5 代理 (`docker-run.sh` / `Dockerfile`)

如果希望在 Docker 隔离容器中运行 Cloudflare WARP（已配置 Zero Trust 团队）并通过 `sing-box` (直连出站) 对外提供 SOCKS5 代理，可直接使用容器部署方案：

#### 🛠️ 一键构建与运行容器

```bash
# 进入目录
cd cloudflare-warp

# 1. 使用 Zero Trust 团队名及 Service Token 自动认证并启动容器 (推荐无人值守部署)
bash docker-run.sh -t <YOUR_ZERO_TRUST_TEAM> -i <CLIENT_ID> -s <CLIENT_SECRET> -p 1080

# 或使用 ID:SECRET 合并参数传入 Service Token:
bash docker-run.sh -t <YOUR_ZERO_TRUST_TEAM> --service-token <CLIENT_ID>:<CLIENT_SECRET> -p 1080

# 2. 可选：同时设置带用户名和密码验证的 SOCKS5 代理
bash docker-run.sh -t <YOUR_ZERO_TRUST_TEAM> --service-token <CLIENT_ID>:<CLIENT_SECRET> -p 1080 -u myuser -w mypassword
```

#### 📋 容器管理命令参考

```bash
# 查看容器运行日志 (含 WARP 连接与 sing-box 启动日志)
bash docker-run.sh --logs

# 查看容器运行状态与 WARP 连通状态
bash docker-run.sh --status

# 停止并删除容器
bash docker-run.sh --stop

# 强行重新构建 Docker 镜像并运行
bash docker-run.sh -t <YOUR_ZERO_TRUST_TEAM> -i <CLIENT_ID> -s <CLIENT_SECRET> -p 1080 --build
```

#### 🐳 原生 Docker 命令运行示例

如果你习惯直接使用 `docker` 命令行，可以使用环境变量传入 Service Token：

```bash
# 1. 构建镜像
docker build -t cloudflare-warp-socks5:latest .

# 2. 运行容器 (必须包含 --cap-add=NET_ADMIN 和 --device /dev/net/tun)
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

## 🌐 Cloudflare Zero Trust 控制台完整配置指南

在部署 VPS 脚本或容器前，需在 [Cloudflare Zero Trust 控制台](https://one.dash.cloudflare.com/) 完成团队初始化、Service Token 创建、设备注册规则与 Split Tunnels 路由配置。以下为详细控制台操作步骤：

```text
[ 客户端 / SOCKS5 代理 ] ──(加密隧道)──> [ Cloudflare Zero Trust ] ──(网络路由)──> [ VPS 出口 / Internet ]
```

---

### 第一步：获取 Zero Trust 团队名称 (Team Name)

1. 打开浏览器登录 [Cloudflare Zero Trust 控制台](https://one.dash.cloudflare.com/)。
2. 若属于首次设置，根据页面引导配置团队域名（Team Domain），格式为 `<your-team-name>.cloudflareaccess.com`。
3. 其中的 **`your-team-name`** 即为容器与脚本参数中的 **`WARP_TEAM` / Team Name**（例如 `my-company`）。
4. **验证方式**：在控制台左侧导航栏选择 **Settings** -> **Account**，或者查看控制台左上角展示的组织团队名称。

---

### 第二步：创建 Service Token (服务令牌)

Service Token 用于 Docker 容器或 headless 服务器免浏览器交互的无人值守设备注册：

1. 在左侧导航栏，点击 **Access** -> **Service Tokens**。
2. 点击右上角 **Create Service Token** 按钮。
3. 填写令牌参数：
   - **Service Token Name**：输入令牌标识名称（例如 `vps-warp-socks5`）
   - **Service Token Duration**：选择凭据有效期（建议选择 `Non-expiring` 永久有效或 `1 Year`）
4. 点击右下角 **Save** 保存。
5. **保存重要凭据**：页面将弹窗一次性展示该 Service Token 的钥匙信息：
   - **Client ID**：对应脚本中的 `-i / --token-id` 参数（格式如 `xxxxxx.access`）
   - **Client Secret**：对应脚本中的 `-s / --token-secret` 参数（格式如 64 位随机字符）
   - ⚠️ **请务必复制并妥善保存 Client Secret**，该密钥离开当前弹窗后将无法再次提取！

---

### 第三步：配置设备注册策略 (Device Enrollment Rules)

配置许可该 Service Token 进行 WARP 设备的自动注册与接入：

1. 在左侧导航栏，点击 **Settings** -> **WARP Client**。
2. 在 **Device enrollment**（设备注册）卡片中，点击 **Manage** 按钮。
3. 切换至 **Rules** 选项卡，点击 **Add a rule** 按钮：
   - **Rule name**：填入规则名称（如 `Allow-Service-Token-Enroll`）
   - **Rule action**：选择 `Service Token`
   - **Selector**：在下拉列表中选择 `Service Token`
   - **Value**：选择第二步中创建的 Service Token 名称（如 `vps-warp-socks5`）
4. 点击 **Save rule** 保存规则。

---

### 第四步：配置 Split Tunnels (流量切分与包含路由)

指定哪些网络流量需要被接管并送入 Zero Trust 隧道：

1. 在左侧导航栏，点击 **Settings** -> **WARP Client**。
2. 在 **Profile settings** 卡片中，选择目标 Profile（默认即为 `Default`），点击右侧的 **Edit** 按钮。
3. 切换至 **Split Tunnels** 选项卡：
   - **模式选择**：推荐切换为 **Include IPs and domains**（仅包含模式，仅指定的 IP/域名进入 WARP 隧道），或保留 **Exclude IPs and domains**（排除模式）。
4. 若选择 **Include** 模式，点击 **Manage** -> **Add IP or domain**：
   - **Selector**：选择 `IP Address`
   - **Value**：填入 `0.0.0.0/0`（接管所有 IPv4 流量），或填入特定 CIDR 网段（如 `1.1.1.1/32`）
5. 点击 **Save destination** 保存规则。

---

### 第五步：配置网络路由 (Networks Routes / Exit Nodes, 可选)

若需将经过 Zero Trust 网络的客户端流量指定由该 VPS 公网 IP 出口（Exit Node / Gateway）：

1. 在左侧导航栏，点击 **Networks** -> **Routes**。
2. 点击 **Create Route** 按钮：
   - **CIDR**：填入目标 IP 网段（例如 `0.0.0.0/0` 表示全部出口流量）
   - **Tunnel / Destination**：选择本 VPS 上注册的 WARP 节点设备或 WARP Connector 实例
3. 点击 **Save** 保存使路由生效。

---

### 阶段二：在 VPS 上完成网络接入与 NAT 脚本配置

根据你的 VPS 部署架构选择以下**两种模式之一**：

#### 方案 A：使用 `cloudflare-warp` 客户端模式 (有 `warp0` 网卡)
1. **安装并配置注册**：
   ```bash
   sudo bash install.sh
   warp-cli registration organization <YOUR_TEAM_NAME>
   warp-cli mode warp
   warp-cli connect
   ```
2. **运行 NAT 脚本**（脚本会自动检测到 `warp0` 并绑定该网卡）：
   ```bash
   sudo bash setup-cloudflare-one.sh --setup
   ```

#### 方案 B：使用 `cloudflared` WARP Connector / 纯 NAT 模式 (无 `warp0` 网卡)
1. **无需安装 `cloudflare-warp` 客户端**，通过 `cloudflared` 创建 Connector 并在 Cloudflare 控制台绑定 Route。
2. **直接运行 NAT 脚本**（脚本会自动启用通用 NAT 转发，或指定 `-w any`）：
   ```bash
   sudo bash setup-cloudflare-one.sh --setup
   ```

---

### 阶段三：客户端接入与出口 IP 效果验证

1. **客户端连接**：
   - 在个人电脑或手机上下载 Cloudflare WARP 客户端。
   - 在客户端设置中选择 **Account** -> **Login with Cloudflare Zero Trust**，输入你的 Team Name 并完成认证。
   - 开启 WARP 连接。

2. **出口 IP 验证**：
   - 在客户端设备上打开终端或浏览器访问以下验证链接：
     ```bash
     curl https://www.cloudflare.com/cdn-cgi/trace
     ```
   - 或者访问 `https://ipinfo.io` / `https://ifconfig.me`。
   - **预期结果**：输出的公网 IP 应显示为你 **VPS 的公网 IP**，且 `warp=on`。

3. **在 VPS 上观察流量转发**：
   - 在 VPS 上运行以下命令查看流量包计数：
     ```bash
     sudo bash setup-cloudflare-one.sh --status
     ```
   - 或使用 `iptables -t nat -L POSTROUTING -v -n`，可看到 `MASQUERADE` 规则下的 `pkts` (数据包数) 和 `bytes` 随客户端访问持续递增。

---

## 🔍 故障排查与常见问题

1. **VPS 没有安装 `cloudflare-warp` 客户端，运行脚本会报错吗？**
   - 不会。脚本中的 `-w` 参数默认为 `auto`，会自动检测系统是否存在 `warp0` 网卡。若没有 `warp0`，将自动开启通用 NAT 转发模式（`* -> eth0`），完美适配 Cloudflare Tunnel Connector 或纯 NAT 组网场景。

2. **客户端连通但出口 IP 仍为 Cloudflare 节点 IP 而不是 VPS IP？**
   - 检查 Cloudflare Dashboard 的 **Networks Routes** 是否正确将目标 CIDR 指向了该 VPS 的节点。
   - 检查 Cloudflare Dashboard 的 **Split Tunnels** 设置，确认客户端访问的目标 IP 在路由包含范围内。
   - 在 VPS 上运行 `sudo bash setup-cloudflare-one.sh --status`，确认内核参数 `net.ipv4.ip_forward = 1` 以及 POSTROUTING MASQUERADE 规则生效。

3. **系统重启后 NAT 转发规则是否会失效？**
   - 不会。运行 `sudo bash setup-cloudflare-one.sh --setup` 具备**多重双重开机持久化保障**：
     - **Systemd 自启服务保障**：脚本会自动注册并启用 `cloudflare-one-nat.service` 服务，系统重启开机后会自动重新加载 IP 转发与 `iptables` 规则。
     - **防火墙规则持久化**：自动保存规则文件（Debian/Ubuntu 自动配置 `netfilter-persistent` / `/etc/iptables/rules.v4`，RHEL/CentOS 自动配置 `iptables-services`）。
     - **内核参数持久化**：内核转发参数自动写入 `/etc/sysctl.d/99-cloudflare-one-nat.conf`，重启自动生效。

4. **如何彻底取消并还原 NAT 配置？**
   - 运行 `sudo bash setup-cloudflare-one.sh --unset` 即可自动清理内核转发配置文件与 `iptables` 相关规则。
