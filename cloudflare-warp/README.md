# Cloudflare WARP & Cloudflare One VPS 出口自动化部署与配置指南

本目录提供 Cloudflare WARP 官方客户端的自动化安装部署脚本 (`install.sh`)，以及在 VPS 上配置 **Cloudflare One / Zero Trust 自定义流量出口 (NAT 转发)** 的一键脚本 (`setup-cloudflare-one.sh`)。

通过这套方案，你可以将客户端（如手机、电脑上的 Cloudflare WARP 客户端）代理的流量通过 Cloudflare Zero Trust 网络传输后，**指定流量出口为该 VPS 的公网 IP**。

---

## 📁 脚本清单与功能说明

| 脚本名称 | 核心功能 | 常用应用场景 |
| --- | --- | --- |
| **`install.sh`** | 自动配置官方 Apt/Yum 软件源并安装 `cloudflare-warp` 软件包与 `warp-svc` 服务 | 新增或重新安装 Cloudflare WARP 客户端 (用于 VPS 本地接入 WARP 网络) |
| **`setup-cloudflare-one.sh`** | 自动开启 Linux 内核 IP 转发 (`ip_forward`) 并配置 `iptables` NAT MASQUERADE 规则，智能支持 `warp0` 接口隔离或纯 NAT 通用转发模式 | 将 VPS 配置为 Cloudflare One WARP 流量的指定出口节点 (Exit Node / NAT Gateway)，无论 VPS 是否安装 `cloudflare-warp` 均可适用 |

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

## 🌐 Cloudflare One (Zero Trust) 完整配置步骤指南

为了使客户端流量通过 Cloudflare 后成功指定本 VPS 为出口，需完成以下三大部分的配置：

```text
[ 客户端 WARP Client ] ──(加密隧道)──> [ Cloudflare Zero Trust ] ──(网络路由)──> [ VPS (warp0 或 Connector) ] ──(iptables NAT)──> [ 目标网站/Internet ]
```

### 阶段一：在 Cloudflare Zero Trust 控制台初始化配置

1. **登录控制台**：
   访问 [Cloudflare Zero Trust 控制台](https://one.dash.cloudflare.com/)。若未开启，请先绑定组织团队名称（Team Name）。

2. **配置客户端注册规则 (Device Enrollment)**：
   - 导航至 **Settings** -> **WARP Client** -> **Device enrollment** -> **Rules**。
   - 添加规则（例如根据邮箱后缀 `Allow` 允许团队成员加入），以便客户端和 VPS 可以注册到该 Team。

3. **配置 Split Tunnels (流量切分规则)**：
   - 导航至 **Settings** -> **WARP Client** -> **Profile settings** -> 点击对应 Profile 的 **Edit** -> **Split Tunnels**。
   - 将模式切换为 **Include IPs and domains**（推荐，仅将特定流量路由至 Zero Trust），并添加你需要通过该 VPS 出口的目标 IP/CIDR 范围（例如 `0.0.0.0/0` 表示全部 IPv4 流量出口，或指定特定的 IP 段/域名）。
   - 或者在 **Exclude** 模式下，将你需要通过 VPS 出口的 IP 范围从排除列表中移除。

4. **配置网络路由 (Networks Routes)**：
   - 导航至 **Networks** -> **Routes** (或 WARP Connector / Mesh)。
   - 添加目标 CIDR（例如 `0.0.0.0/0` 或私有 IP 段），并将 Destination 绑定为你部署在此 VPS 上的 WARP 节点/Tunnel。

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

3. **系统重启后 NAT 转发规则失效？**
   - 运行 `sudo bash setup-cloudflare-one.sh --setup` 会自动尝试通过 `netfilter-persistent` 或 `/etc/iptables/rules.v4` 保存规则。
   - 在 Debian/Ubuntu 上建议确保已安装 `iptables-persistent`：
     ```bash
     sudo apt-get install -y iptables-persistent
     ```

4. **如何彻底取消并还原 NAT 配置？**
   - 运行 `sudo bash setup-cloudflare-one.sh --unset` 即可自动清理内核转发配置文件与 `iptables` 相关规则。
