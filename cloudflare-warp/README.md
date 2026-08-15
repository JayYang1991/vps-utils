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
| **`generate-singbox-server-config.sh`** | 国内中转 VPS 专用：自动生成 sing-box 服务端配置 (VLESS+Reality 入站 -> WARP SOCKS5 出站) | **中转 VPS 部署**：自动生成多端口 VLESS+Reality 配置并打印客户端链接与配置 |
| **`install.sh`** | 自动配置官方 Apt/Yum 软件源并安装 `cloudflare-warp` 客户端 | **本地 / VPS 部署**：原生 Linux 环境安装官方 WARP 客户端 |
| **`setup-cloudflare-one.sh`** | VPS 出口 NAT 转发与开机双重持久化配置脚本 | **VPS 宿主机部署**：将 VPS 配置为 Cloudflare Zero Trust 出口节点 (NAT Gateway) |

---

## 🚀 一、本地 SOCKS5 代理客户端部署 (推荐 Systemd 服务封装)

使用 `docker-run.sh` 脚本可将 WARP + sing-box 容器打包为 Systemd 系统服务，享受开机自启、日志统一收集、状态持久化与策略路由自动生命周期管理。

---

### 1. 常用命令速查 (Cheat Sheet)

```bash
# ------------------ Systemd 服务管理 (推荐) ------------------
# 一键安装为 Systemd 服务 (Zero Trust Token)
sudo bash docker-run.sh --install-service -t <TEAM> --service-token <ID>:<SECRET> -p 1080

# 重新编译镜像并一键重建服务 (用于代码更新/升级组件)
sudo bash docker-run.sh --install-service --rebuild -t <TEAM> --service-token <ID>:<SECRET> -p 1080

# 查看完整运行状态 (Systemd / 策略路由 / 容器 / WARP 连通性)
sudo bash docker-run.sh --status

# 快速测试 SOCKS5 代理有效性 (自动请求 Cloudflare Trace)
sudo bash docker-run.sh --test

# 查看实时运行日志 (追踪 journalctl)
sudo bash docker-run.sh --logs
# 或直接: journalctl -u cloudflare-warp-socks5 -f

# 平滑重启服务 (保留容器已有状态，秒级启动不重注 WARP)
sudo bash docker-run.sh --restart
# 或直接: sudo systemctl restart cloudflare-warp-socks5

# 停止服务 (保留容器数据，自动清理策略路由)
sudo bash docker-run.sh --stop
# 或直接: sudo systemctl stop cloudflare-warp-socks5

# 卸载 Systemd 服务 (彻底清理配置、删除容器与策略路由)
sudo bash docker-run.sh --uninstall-service

# ------------------ 独立 Docker 容器模式 ------------------
# 启动独立容器 (若已有容器则直接启动保留状态)
sudo bash docker-run.sh -t <TEAM> --service-token <ID>:<SECRET> -p 1080

# 重新编译并重建独立容器
sudo bash docker-run.sh --rebuild -t <TEAM> --service-token <ID>:<SECRET> -p 1080

# 仅重新编译 Docker 镜像 (不运行容器)
bash docker-run.sh --rebuild
bash docker-run.sh --rebuild --no-cache
```

---

### 2. 核心场景与详细用法

#### 场景 A：使用 Zero Trust Service Token 安装为系统服务 (最常用)
```bash
sudo bash docker-run.sh --install-service \
  -t <YOUR_TEAM_NAME> \
  --service-token <CLIENT_ID>:<CLIENT_SECRET> \
  -p 1080
```

#### 场景 B：启用 SOCKS5 用户名与密码鉴权
```bash
sudo bash docker-run.sh --install-service \
  -t <YOUR_TEAM_NAME> \
  --service-token <CLIENT_ID>:<CLIENT_SECRET> \
  -p 1080 \
  -u myusername \
  -w mypassword
```

#### 场景 C：使用 Cloudflare WARP+ 许可证密钥 (License Key)
```bash
sudo bash docker-run.sh --install-service \
  -k <YOUR_WARP_PLUS_LICENSE_KEY> \
  -p 1080
```

#### 场景 D：更新脚本或 entrypoint 后重新编译并重建服务
```bash
# --rebuild 会自动重新构建镜像并重建容器以应用最新代码
sudo bash docker-run.sh --install-service --rebuild \
  -t <YOUR_TEAM_NAME> \
  --service-token <CLIENT_ID>:<CLIENT_SECRET> \
  -p 1080
```

#### 场景 E：自定义策略路由网段与优先级
```bash
sudo bash docker-run.sh --install-service \
  -t <YOUR_TEAM_NAME> \
  --service-token <CLIENT_ID>:<CLIENT_SECRET> \
  --route-src 172.18.0.0/16 \
  --route-prio 8888 \
  -p 1080
```

---

### 3. 🔐 敏感凭据安全隔离机制

* **完全脱离 Systemd 单元文件**：Service Token、Secret、SOCKS5 密码等敏感认证信息**不会**写入 `/etc/systemd/system/*.service` 文件，防止被 `systemctl show` 或非特权服务审查泄漏。
* **独立加密存储**：所有环境变量独立保存在宿主机的 `/etc/cloudflare-warp/warp.env` 文件中，文件权限严格设置为 `0600`（仅 `root` 可读写），并通过 Docker 引擎的 `--env-file` 原生挂载至容器中。

---

### 4. 策略路由（Policy Routing）自动管理说明

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

### 5. 🔄 官方默认接入点连接与健康检查自愈机制

容器默认使用 Cloudflare 官方 Anycast 接入点，并内置了后台健康检查巡检守护进程：

```text
[ 启动阶段 ] ──> 重置并连接官方默认接入点 (warp-cli tunnel endpoint reset && warp-cli connect)
                     │
                     ▼
[ 运行阶段 ] ──> 后台守护进程每 10 秒巡检
                     │
         [ 若检测到 Connecting >= 30s 或断开连接 ]
                     │
                     ▼
        [ 自动重置官方接入点并执行断开重连 (disconnect + connect) ]
```

* **原生官方路由**：使用 Cloudflare 官方 Anycast 节点，保持最稳定原生的 WireGuard/MASQUE 隧道；
* **防死锁自愈**：当遇到网络抖动卡在 `Connecting` 超过 30 秒时，外部守护进程自动触发重连与状态机重置；
* **凭据自动更新**：当检测到团队注册信息失效时，自动触发 `warp-cli mdm refresh` 重新同步。

---

### 6. 🛠️ `docker-run.sh` 完整参数对照表

| 参数选项 | 说明 | 默认值 / 示例 |
| --- | --- | --- |
| `--service`, `--install-service` | 安装并启动为开机自启的 Systemd 服务 | - |
| `--uninstall-service` | 停止并卸载 Systemd 服务，清理环境文件与策略路由 | - |
| `--restart` | 重启 Systemd 服务或 Docker 容器 (保留容器上次状态与数据) | - |
| `--stop` | 停止运行中的容器或 Systemd 服务 (保留容器状态) | - |
| `--status` | 查看服务状态、策略路由、容器与 WARP 连通概览 | - |
| `--test` | 快速测试 SOCKS5 代理连通性 (自动调用 curl 请求 Cloudflare Trace) | - |
| `--logs` | 查看实时运行日志 (优先使用 journalctl 跟踪) | - |
| `-b, --build, --rebuild` | 重新编译 Docker 镜像 (若带启动参数则自动重建容器) | - |
| `--no-cache` | 构建 Docker 镜像时不使用缓存 (全新编译) | - |
| `--recreate` | 强制删除旧容器并重新创建 (清理历史注册状态) | - |
| `-t, --team <TEAM>` | 指定 Cloudflare Zero Trust 团队名称 (Team Name) | `<team-name>` |
| `-i, --token-id <ID>` | 指定 Zero Trust Service Token Client ID | `xxxx.access` |
| `-s, --token-secret <SECRET>` | 指定 Zero Trust Service Token Client Secret | `yyyy` |
| `--service-token <ID:SECRET>` | 使用 `ID:SECRET` 合并格式指定 Service Token | `xxxx.access:yyyy` |
| `-k, --license <KEY>` | 指定 Cloudflare WARP+ 许可证密钥 (License Key) | - |
| `-a, --auth-token <TOKEN>` | 指定 WARP API 注册鉴权 Token | - |
| `-p, --port <PORT>` | 宿主机对外映射的 SOCKS5 代理端口 | `1080` |
| `-u, --user <USER>` | SOCKS5 代理验证用户名 (可选) | - |
| `-w, --pass <PASS>` | SOCKS5 代理验证密码 (可选) | - |
| `-n, --name <NAME>` | 指定容器与 Systemd 服务名称 | `cloudflare-warp-socks5` |
| `--route-src <CIDR>` | 策略路由豁免的源地址网段 | `172.17.0.0/16` |
| `--route-prio <PRIO>` | 策略路由规则优先级 | `8999` |
| `-h, --help` | 显示帮助信息并退出 | - |

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

## 🧪 四、本地代理效果验证与各场景使用方法

### 1. 终端测试与验证

```bash
# 方法 A：使用脚本内置指令一键测试
sudo bash docker-run.sh --test

# 方法 B：手动 curl 验证 (推荐使用 socks5h:// 协议以防止 DNS 污染)
curl -x socks5h://127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace

# 若启用了用户名和密码验证:
curl -x socks5h://myuser:mypass@127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace
```

**预期输出**：
```text
fl=...
h=www.cloudflare.com
ip=2a09:... (或 Cloudflare 节点 IP)
ts=...
visit_scheme=https
uag=curl/...
colo=...
sliver=none
http=http/2
loc=...
tls=TLSv1.3
sni=plaintext
warp=on           <--- 显示 on 表示流量已走 WARP
gateway=on        <--- 若团队启用了 Zero Trust Gateway 策略
```

---

### 2. 常用开发与终端工具配置

#### A. Linux / macOS 终端临时环境变量
```bash
# 当前终端会话所有流量走 SOCKS5
export ALL_PROXY="socks5h://127.0.0.1:1080"
export http_proxy="http://127.0.0.1:1080"
export https_proxy="http://127.0.0.1:1080"

# 取消代理
unset ALL_PROXY http_proxy https_proxy
```

#### B. Git 命令代理配置
```bash
# 全局设置 Git 走 SOCKS5 代理
git config --global http.proxy "socks5h://127.0.0.1:1080"
git config --global https.proxy "socks5h://127.0.0.1:1080"

# 取消 Git 代理设置
git config --global --unset http.proxy
git config --global --unset https.proxy
```

#### C. Clash / Mihomo 配置示例
```yaml
proxies:
  - name: "WARP-SOCKS5-Local"
    type: socks5
    server: 127.0.0.1
    port: 1080
    # username: myuser # 若配置了鉴权
    # password: mypass
```

#### D. sing-box 客户端出站配置 (`outbounds`)
```json
{
  "type": "socks",
  "tag": "warp-socks5-out",
  "server": "127.0.0.1",
  "server_port": 1080
}
```

---

## 🚀 三、国内中转 VPS 结合 Cloudflare WARP 部署 (VLESS + Reality + SOCKS5 出站)

当您在**国内云服务器 / 中转 VPS** 上运行本项目的 Cloudflare WARP SOCKS5 代理时，可以使用配套脚本 [`generate-singbox-server-config.sh`](file:///home/jason/user_data/code/vps-utils/cloudflare-warp/generate-singbox-server-config.sh) 一键生成 sing-box 服务端配置。

### 1. 架构与运作流程
```text
[ 用户客户端 (电脑/手机) ] 
          │
          ▼ (VLESS + Reality 伪装加密协议，防探测防封锁)
[ 国内中转 VPS: sing-box (监听 443, 8443, 2053, 2083, 2087, 2096, 8080 等多端口) ]
          │
          ▼ (本地转发: socks5://127.0.0.1:1080)
[ Cloudflare WARP 容器 (Zero Trust / 策略路由隔离) ]
          │
          ▼ (跨洋高速加密隧道)
[ Cloudflare 全球网络 ] ──> [ 目标国际互联网 (Google/GitHub/YouTube等) ]
```

### 2. 脚本使用方法

```bash
# 1. 零配置一键生成 (自动探测公网 IP、自动生成 UUID 与 Reality 密钥对，开放所有常用端口)
bash generate-singbox-server-config.sh

# 2. 自定义开放端口与 Reality 伪装域名
bash generate-singbox-server-config.sh --ports 443,8443,2053,2083 --sni gateway.icloud.com

# 3. 一键生成并直接应用到系统 /etc/sing-box/config.json 并重启服务
sudo bash generate-singbox-server-config.sh --apply

# 4. 指定自定义输出路径
bash generate-singbox-server-config.sh -o /etc/sing-box/config.json
```

### 3. 生成内容概览
- **服务端**：自动配置 VLESS + Reality (XTLS-Vision)，出站绑定 `socks5://127.0.0.1:1080`；
- **客户端**：终端自动输出彩色可直接复制的各端口 `vless://` 链接、Clash Meta YAML 配置及 sing-box 客户端 JSON。

