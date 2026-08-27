# Cloudflare Access TCP 客户端转发服务 (cloudflare-access-tcp)

`cloudflare-access-tcp` 是一个专为 **代理客户端 / 本地网关** 设计的轻量级高可用 TCP 转发与优选 IP 智能运维容器方案。基于官方 `ubuntu:24.04` 镜像与最新版 `cloudflared` 二进制，通过并发拉起多个 `cloudflared access tcp` 进程，将受 Cloudflare Access (Zero Trust) 保护的远程 TCP 服务（如自建影视服、Emby、Jellyfin、Sub 订阅转换、SSH、内网代理端口等）安全转发至客户端本地端口。

在容器内部深度集成了 **CloudflareSpeedTest (cfst) 测速引擎** 与 **网络联通性检测及自动故障转移守护进程 (health_checker.py)**，具备 **每日凌晨自动测速更新待选 IP 池** 与 **TCP 故障毫秒级自动切换优选 IP** 的全自动闭环能力。

日常运维管理命令已从 `install.sh` 完全剥离，独立封装为 **`service.sh`**，并在安装时自动注册至系统全局可执行路径（`/usr/local/bin/cloudflare-access-tcp` / `cf-access-tcp`）。

---

## 🌟 核心特性

- 🐳 **编译走宿主机网络，运行走隔离网络**：
  - **编译阶段**：自动使用宿主机网络 (`--network host`) 构建镜像，自动匹配 CPU 架构（amd64 / arm64 / arm）极速下载最新版 `cloudflared` 与 `cfst` 测速核心；
  - **运行阶段**：采用独立的 Docker Bridge 网桥隔离网络，通过精准端口映射 (`-p [LISTEN_IP:]PORT:PORT`) 暴露服务，配置文件与待选 IP 池持久化挂载至宿主机 (`/etc/cloudflare-access-tcp`)。
- ⚡ **容器内全自动优选 IP 双重调度策略**：
  - 🕒 **策略 1（每日凌晨定时测速）**：每天北京时间凌晨 02:00 ~ 06:00 之间的随机时刻，容器内自动触发 443 端口全量测速，选取 **TOP 20 最优 IP** 更新至待选列表文件 (`candidates.txt`)，并自动将域名解析切换至 TOP 1 节点；
  - 🔄 **策略 2（实时连通性检测与自动故障转移）**：容器内以配置的周期（默认每 15 秒）持续探测本地 TCP 转发端口与当前优选 IP 连通性。当检测到 TCP 不通时（连续失败 2 次），自动读取待选 IP 列表文件，**从前往后依次验证候选 IP 可用性，一旦测试通过即刻将域名切换解析到该优选 IP 并热重载转发进程**。
- ⚡ **多端口并发转发**：容器内采用独立并发进程与优雅信号捕获管理，支持同时映射任意数量的域名与本地 TCP 端口（默认开启 2 个端口：`5000` 与 `5001`）。
- 🔒 **严格参数与格式校验**：内置严格的 RFC 规范域名与端口合法性校验，杜绝无效域名、超出范围端口（1-65535）或端口冲突。
- 🛡️ **敏感凭据安全隔离**：Service Token Client ID 与 Secret 独立存储于权限为 `600` 的配置文件 (`/etc/cloudflare-access-tcp/access.env`) 中，绝不在 Systemd 单元文件或进程列表中泄露明文。
- 🛠️ **专用全局管理 CLI (`cloudflare-access-tcp`)**：安装后提供全局命令行工具，支持 `status`、`candidates`、`speedtest`、`switch-ip`、`test`、`logs`、`start`、`stop`、`restart`、`rebuild`、`uninstall` 全套指令。

---

## 🏗️ 架构与流量转发原理

```text
┌───────────────────────────────────────────────────────────────────────────────────┐
│                              本地代理客户端 / 局域网网关                              │
│                                                                                   │
│  [ 客户端应用 (Emby / Clash / sing-box / 浏览器) ]                                 │
│        │                                                                          │
│        ▼ (连接宿主机端口: 127.0.0.1:5000 / 127.0.0.1:5001)                         │
│  ┌─────────────────────────────────────────────────────────────────────────────┐  │
│  │   Docker 端口映射 (-p 127.0.0.1:5000:5000, -p 127.0.0.1:5001:5001)          │  │
│  │   ▼                                                                         │  │
│  │   cloudflare-access-tcp 容器 (Bridge 隔离网络, Systemd 守护运行)             │  │
│  │   ┌───────────────────────────────────────────────────────────────────────┐ │  │
│  │   │  health_checker.py 守护进程:                                           │ │  │
│  │   │  • 每日 02:00~06:00 随机测速更新 TOP 20 待选 IP 池 (candidates.txt)     │ │  │
│  │   │  • 实时检测 TCP 连通性，异常时从待选列表从前往后测试可用性并自动切换 IP     │ │  │
│  │   │  • 动态更新容器 /etc/hosts 并热重载 cloudflared 转发进程                │ │  │
│  │   └───────────────────────────────────┬───────────────────────────────────┘ │  │
│  │                                       │ (动态优选 IP 路由)                    │  │
│  │   cloudflared #1: --hostname movies.19910417.xyz  --url 0.0.0.0:5000        │  │
│  │   cloudflared #2: --hostname movies1.19910417.xyz --url 0.0.0.0:5001        │  │
│  │   (携带 Cloudflare Access Service Token 安全身份凭证)                        │  │
│  └──────────────────────────────────────┬──────────────────────────────────────┘  │
└─────────────────────────────────────────┼─────────────────────────────────────────┘
                                          │ (WSS 加密 WebSocket 隧道穿越公网)
                                          ▼
                ┌───────────────────────────────────────────────────┐
                │          Cloudflare Zero Trust 边缘网络           │
                │        (Access TCP 策略鉴权 + 优选 Anycast IP)      │
                └─────────────────────────┬─────────────────────────┘
                                          │
                                          ▼
                ┌───────────────────────────────────────────────────┐
                │             远程服务端 (VPS / 私有云)              │
                │          Cloudflare Tunnel (cloudflared)          │
                │                         │                         │
                │                         ▼ (本地转发)               │
                │         目标后端服务 (Emby / TCP Service)          │
                └───────────────────────────────────────────────────┘
```

---

## 📋 快速开始

### 1. 准备 Cloudflare Access Service Token

在 Cloudflare Zero Trust 控制台生成 Service Token：
1. 登录 [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/)。
2. 进入 **Access** -> **Service Credentials** -> 点击 **Add Service Token**。
3. 输入名称（例如 `client-proxy-token`），获取生成的：
   - **Client ID**（形如 `xxxxxx.access`）
   - **Client Secret**（形如 `a1b2c3d4e5...`）
4. 在目标应用程序的 Access Policy 中，添加一条规则：**Action = Service Token**，并将该 Token 加入允许列表。

---

### 2. 一键安装与部署

在客户端机器上克隆仓库并执行安装脚本：

```bash
# 进入项目目录
cd cloudflare-access-tcp

# 默认配置安装 (自动拉取并启动服务，内置每日测速与故障自动转移)
sudo bash install.sh -i "your-client-id.access" -s "your-client-secret"
```

或者使用便捷的 `--service-token` 格式：

```bash
sudo bash install.sh --service-token "your-client-id.access:your-client-secret"
```

安装脚本会自动将专用管理工具安装至系统路径 `/usr/local/bin/cloudflare-access-tcp`（别名：`cf-access-tcp`）。

---

## ⚙️ 参数与选项说明

### 安装脚本选项 (`install.sh`)

| 参数 | 简写 | 说明 | 默认值 / 示例 |
| :--- | :--- | :--- | :--- |
| `--token-id` | `-i` | **(必选)** Cloudflare Access Service Token ID | `xxxx.access` |
| `--token-secret` | `-s` | **(必选)** Cloudflare Access Service Token Secret | `xxxxxxxx` |
| `--service-token` | 无 | 以 `ID:SECRET` 格式组合传入 Token | `xxxx.access:yyyy` |
| `--preferred-ip`, `--ip` | 无 | 指定初始 Cloudflare 优选 IP (若未指定将自动从测速池中获取) | `104.16.88.99` |
| `--domains` | `-d` | 目标域名列表 (多个用英文逗号分隔) | `movies.19910417.xyz,movies1.19910417.xyz` |
| `--ports` | `-p` | 本地 TCP 监听端口列表 (与域名列表一一对应) | `5000,5001` |
| `--forward` | `-f` | 快捷规则列表，格式为 `domain:port` (支持多次或逗号分隔) | `movies.19910417.xyz:5000,movies1.19910417.xyz:5001` |
| `--listen` | 无 | 宿主机监听绑定地址 (默认仅限本机访问) | `127.0.0.1` (设为 `0.0.0.0` 开放给局域网) |
| `--sub-url` | 无 | 订阅服务器拉取地址 (用于测速时补充在线候选 IP) | `https://sub.19910417.xyz` |
| `--check-interval` | 无 | TCP 连通性检测周期 (秒) | `15` |
| `--fail-threshold` | 无 | 触发自动切换优选 IP 的连续失败次数 | `2` |
| `--name` | `-n` | 自定义 Systemd 服务与容器名称 | `cloudflare-access-tcp` |
| `--no-cache` | 无 | 构建 Docker 镜像时不使用缓存 (全新编译) | 否 |
| `--help` | `-h` | 显示完整帮助信息 | - |

---

## 🛠️ 日常运维管理命令 (`cloudflare-access-tcp` / `service.sh`)

安装完成后，可以在宿主机任何路径直接使用系统全局命令 `cloudflare-access-tcp` 或 `cf-access-tcp`（亦可直接运行 `./service.sh <command>`）：

```bash
# 别名 cf-access-tcp 等价于 cloudflare-access-tcp
```

### 1. 查看运行状态与优选监控
```bash
cloudflare-access-tcp status
```
输出示例：
```text
=== cloudflare-access-tcp 运行状态与优选监控 ===

Systemd 服务状态:  ● active (running)
Docker 容器状态:   cloudflare-access-tcp (Up 2 hours)

优选与健康检测监控指标 (status.json):
  • 转发健康状态:     ✓ 正常 (Healthy)
  • 当前生效优选 IP:  104.16.88.99
  • 待选池 IP 数量:   20 个 (TOP 20 池)
  • 上次测速时间:     2026-08-27 16:55:00 CST
  • 下次定时测速排期: 2026-08-28 03:42:15 CST (北京时间 02:00~06:00 随机触发)

当前配置的转发规则:
  [1] 127.0.0.1:5000     -> movies.19910417.xyz                 [状态: 监听中 (TCP)]
  [2] 127.0.0.1:5001     -> movies1.19910417.xyz                [状态: 监听中 (TCP)]
```

### 2. 查看当前 TOP 20 待选 IP 池
```bash
cloudflare-access-tcp candidates
```

### 3. 立即触发全量测速刷新待选池
```bash
cloudflare-access-tcp speedtest
```

### 4. 手动切换优选 IP
```bash
sudo cloudflare-access-tcp switch-ip 162.159.192.1
```

### 5. 测试本地转发与待选 IP 连通性
```bash
cloudflare-access-tcp test
```

### 6. 查看实时运行日志
```bash
cloudflare-access-tcp logs -f
```

### 7. 服务启停与配置管理
```bash
# 重启服务
sudo cloudflare-access-tcp restart

# 停止服务
sudo cloudflare-access-tcp stop

# 查看或编辑配置文件
sudo cloudflare-access-tcp config --edit

# 重新编译 Docker 镜像 (使用宿主机网络)
sudo cloudflare-access-tcp rebuild

# 完全卸载清理
sudo cloudflare-access-tcp uninstall
```

---

## 📱 客户端配置与使用

一旦服务启动成功，目标远程服务已被映射在本地回环地址上：

| 远程 Zero Trust 目标 | 本地直连访问地址 | 适用场景 |
| :--- | :--- | :--- |
| `movies.19910417.xyz` | `http://127.0.0.1:5000` | 客户端直接填入 `127.0.0.1:5000` 即可直连远程影视服 |
| `movies1.19910417.xyz` | `http://127.0.0.1:5001` | 客户端填入 `127.0.0.1:5001` 访问备用影视服 |

> 🔒 **无需安装客户端 WARP 软件**：通过 `cloudflare-access-tcp` 服务，任意第三方播放器（如 Infuse、Fileball、VidHub、Kodi、VLC）均可直接像连接局域网一样连接 `127.0.0.1:5000`，由后台自动完成 Zero Trust 鉴权、优选 IP 路由与 WebSocket 隧道传输！
