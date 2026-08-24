# Cloudflare Access TCP 客户端转发服务 (cloudflare-access-tcp)

`cloudflare-access-tcp` 是一个专为**代理客户端 / 本地网关**设计的轻量级高可用 TCP 转发容器方案。基于官方 `ubuntu:24.04` 镜像与最新版 `cloudflared` 二进制，通过并发拉起多个 `cloudflared access tcp` 进程，将受 Cloudflare Access (Zero Trust) 保护的远程 TCP 服务（如自建影视服、Emby、Jellyfin、Sub 服务、SSH、内网代理端口等）安全转发至客户端本地端口。

提供完善的一键安装脚本，自动构建 Docker 镜像，封装并托管为 **Systemd 系统服务**，支持开机自启、独立凭据加密隔离、状态监控、连通性测试与故障自动恢复。

---

## 🌟 核心特性

- 🐳 **编译走宿主机网络，运行走隔离网络**：
  - **编译阶段**：自动使用宿主机网络 (`--network host`) 构建镜像，自动匹配 CPU 架构（amd64 / arm64 / arm）极速下载最新版 `cloudflared` 二进制与基础依赖；
  - **运行阶段**：采用独立的 Docker Bridge 网桥隔离网络（**不使用宿主机网络**），通过精准端口映射 (`-p [LISTEN_IP:]PORT:PORT`) 暴露服务，具备更高的安全隔离性与网络可控性。
- ⚡ **多端口并发转发**：容器内采用独立并发进程与优雅信号捕获管理，支持同时映射任意数量的域名与本地 TCP 端口（默认开启 2 个端口：`5000` 与 `5001`）。
- 🔒 **严格参数与格式校验**：内置严格的 RFC 规范域名与端口合法性校验，杜绝无效域名、超出范围端口（1-65535）或端口冲突。
- 🛡️ **敏感凭据安全隔离**：Service Token Client ID 与 Secret 独立存储于权限为 `600` 的配置文件 (`/etc/cloudflare-access-tcp/access.env`) 中，绝不在 Systemd 单元文件或进程列表中泄露明文。
- 🔄 **双层高可用自愈体系**：
  - **L1 容器内单进程级热自愈**：主 Entrypoint 实时监控各子进程 PID。任一规则的 `cloudflared` 进程异常退出时，**仅热重启该单一故障进程**，不断开其他健康端口，业务零感知；内置防颠簸重试判定（Anti-Flapping）；
  - **L2 宿主机 Systemd 容器级守护**：若出现整机或不可恢复的致命异常导致容器退出，Systemd 通过 `Restart=always` 与 `RestartSec=5s` 自动拉起重建容器。
- 🛠️ **全生命周期运维管理**：一键安装脚本内置 `--install`、`--status`、`--logs`、`--restart`、`--stop`、`--test`、`--rebuild`、`--uninstall` 全套运维指令。

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
│  │                                                                             │  │
│  │   cloudflared #1: --hostname movies.19910417.xyz  --url 0.0.0.0:5000        │  │
│  │   cloudflared #2: --hostname movies1.19910417.xyz --url 0.0.0.0:5001        │  │
│  │   (附带 Cloudflare Access Service Token 进行安全身份鉴权)                       │  │
│  └──────────────────────────────────────┬──────────────────────────────────────┘  │
└─────────────────────────────────────────┼─────────────────────────────────────────┘
                                          │ (WSS 加密 WebSocket 隧道穿越公网)
                                          ▼
                ┌───────────────────────────────────────────────────┐
                │          Cloudflare Zero Trust 边缘网络           │
                │        (Access TCP 策略鉴权 + 自动化验证)           │
                └─────────────────────────┬─────────────────────────┘
                                          │
                                          ▼
                ┌───────────────────────────────────────────────────┐
                │             远程服务端 (VPS / 私有云)              │
                │                                                   │
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

### 2. 一键安装与启动 (推荐)

在客户端机器上克隆仓库并执行安装脚本：

```bash
# 进入项目目录
cd /path/to/vps-utils/cloudflare-access-tcp

# 默认配置安装 (转发 movies.19910417.xyz -> 5000, movies1.19910417.xyz -> 5001)
sudo bash install.sh -i "your-client-id.access" -s "your-client-secret"
```

或者使用便捷的 `--service-token` 格式：

```bash
sudo bash install.sh --service-token "your-client-id.access:your-client-secret"
```

---

## ⚙️ 参数与选项说明

### 命令行参数

| 参数 | 简写 | 说明 | 默认值 / 示例 |
| :--- | :--- | :--- | :--- |
| `--token-id` | `-i` | **(必选)** Cloudflare Access Service Token ID | `xxxx.access` |
| `--token-secret` | `-s` | **(必选)** Cloudflare Access Service Token Secret | `xxxxxxxx` |
| `--service-token` | 无 | 以 `ID:SECRET` 格式组合传入 Token | `xxxx.access:yyyy` |
| `--preferred-ip`, `--ip` | 无 | 指定 Cloudflare 优选 IP (容器内所有域名共用解析至此 IP 加速) | `104.16.88.99` / `162.159.192.1` |
| `--domains` | `-d` | 目标域名列表 (多个用英文逗号分隔) | `movies.19910417.xyz,movies1.19910417.xyz` |
| `--ports` | `-p` | 本地 TCP 监听端口列表 (与域名列表一一对应) | `5000,5001` |
| `--forward` | `-f` | 快捷规则列表，格式为 `domain:port` (支持多次或逗号分隔) | `movies.19910417.xyz:5000,movies1.19910417.xyz:5001` |
| `--listen` | 无 | 宿主机监听绑定地址 (默认仅限本机访问) | `127.0.0.1` (设为 `0.0.0.0` 开放给局域网) |
| `--network-mode` | 无 | 容器网络模式 (`bridge` 容器隔离网络) | `bridge` |
| `--name` | `-n` | 自定义 Systemd 服务与容器名称 | `cloudflare-access-tcp` |
| `--no-cache` | 无 | 构建 Docker 镜像时不使用缓存 (全新编译) | 否 |
| `--rebuild` | `-b` | 仅重新编译 Docker 镜像 (使用宿主机网络构建)，不重新安装服务 | - |
| `--status` | 无 | 查看 Systemd 服务、Docker 容器、优选 IP 与监听端口状态 | - |
| `--logs` | `-l` | 实时追踪查看运行日志 | - |
| `--test` | 无 | 测试各个本地 TCP 转发端口与优选 IP 的连通性 | - |
| `--restart` | 无 | 重启 Systemd 服务 | - |
| `--stop` | 无 | 停止 Systemd 服务 | - |
| `--uninstall` | 无 | 卸载 Systemd 服务、删除容器与配置文件 | - |
| `--help` | `-h` | 显示完整帮助信息 | - |

---

## 💡 高级自定义示例

### 1. 配置优选 IP 静态映射加速 (多域名共用)

```bash
sudo bash install.sh \
  -i "xxxx.access" \
  -s "yyyy" \
  --preferred-ip "104.16.88.99"
```

### 2. 自定义 3 个域名与对应端口转发并指定优选 IP

```bash
sudo bash install.sh \
  -i "xxxx.access" \
  -s "yyyy" \
  -d "emby.example.com,jellyfin.example.com,sub.example.com" \
  -p "8096,8097,8000" \
  --ip "162.159.192.1"
```

### 3. 允许局域网其他设备访问 (`--listen 0.0.0.0`)

```bash
sudo bash install.sh \
  -i "xxxx.access" \
  -s "yyyy" \
  --listen "0.0.0.0"
```

---

## 🛠️ 常用运维管理

### 1. 查看运行状态
```bash
sudo bash install.sh --status
# 或
sudo systemctl status cloudflare-access-tcp
```

### 2. 查看实时日志
```bash
sudo bash install.sh --logs
# 或
sudo journalctl -u cloudflare-access-tcp -f
```

### 3. 测试端口连通性
```bash
sudo bash install.sh --test
```

### 4. 重启与停止服务
```bash
# 重启
sudo bash install.sh --restart
# 停止
sudo bash install.sh --stop
```

### 5. 卸载与清理
```bash
sudo bash install.sh --uninstall
```

---

## 📱 客户端配置与使用

一旦服务启动成功，目标远程服务已被映射在本地回环地址上：

| 远程 Zero Trust 目标 | 本地直连访问地址 | 适用场景 |
| :--- | :--- | :--- |
| `movies.19910417.xyz` | `http://127.0.0.1:5000` | 客户端直接填入 `127.0.0.1:5000` 即可直连远程影视服 |
| `movies1.19910417.xyz` | `http://127.0.0.1:5001` | 客户端填入 `127.0.0.1:5001` 访问备用影视服 |

> 🔒 **无需安装客户端 WARP 软件**：通过 `cloudflare-access-tcp` 服务，任意第三方播放器（如 Infuse、Fileball、VidHub、Kodi、VLC）均可直接像连接局域网一样连接 `127.0.0.1:5000`，由后台自动完成 Zero Trust 鉴权与 WebSocket 隧道传输！
