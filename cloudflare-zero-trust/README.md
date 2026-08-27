# Cloudflare WARP 客户端与 Zero Trust (Cloudflare One) 本地代理指南

本目录及配套工具提供基于 **Cloudflare Zero Trust (Cloudflare One)** 架构的本地与客户端网络解决方案，涵盖 **本地 Docker + Systemd SOCKS5 代理客户端（策略路由隔离）**、**RFC 9000 MASQUE / QUIC 协议连通性测试诊断工具** 以及 **原生 Linux 官方 WARP 客户端安装脚本**。

> 💡 **目标端 / 末端 VPS 部署提示**：
> 若您需要在目标端 VPS 上部署 Cloudflare Tunnel 内网穿透或配置 VPS 出口 NAT MASQUERADE 转发规则（Exit Node / NAT Gateway），请前往 [`cloudflared-tunnel`](../cloudflared-tunnel/README.md) 目录查看。

---

## 🌐 架构与工作流

```text
[ 本地应用 / 浏览器 / 代理分流客户端 ] 
         │ (SOCKS5 代理, 默认 127.0.0.1:1080)
         ▼
[ Docker 容器: sing-box (直连出站) ]
         │ (容器内部 TUN 虚拟网卡)
         ▼
[ Cloudflare WARP Daemon (Zero Trust 团队 / Service Token) ]
         │ (加密隧道 + 策略路由隔离)
         ▼
[ Cloudflare 全球 Zero Trust 网络 ] ──> [ 目标网站 / 互联网 ]
```

---

## 🧰 工具矩阵与功能详解

---

### 工具 1：本地 SOCKS5 代理客户端 (Docker + Systemd + 策略路由隔离)

使用 [`docker-run.sh`](./docker-run.sh) 脚本，可将 Cloudflare WARP 与 sing-box 容器打包为 Systemd 系统服务，对外暴露标准的 SOCKS5 代理端口（默认 `127.0.0.1:1080`），并自动管理 `172.17.0.0/16` 策略路由，防止与宿主机 Clash/Mihomo TUN 产生路由死循环。

#### 1. 常用管理命令速查
```bash
# 一键安装为开机自启的 Systemd 服务 (使用 Zero Trust Service Token)
sudo bash docker-run.sh --install-service -t <TEAM> --service-token <ID>:<SECRET> -p 1080

# 启用 SOCKS5 账户密码鉴权
sudo bash docker-run.sh --install-service -t <TEAM> --service-token <ID>:<SECRET> -p 1080 -u myuser -w mypass

# 查看服务运行状态、容器状态与策略路由
sudo bash docker-run.sh --status

# 快速测试 SOCKS5 代理连通性 (自动调用 curl 请求 Cloudflare Trace)
sudo bash docker-run.sh --test

# 查看实时运行日志
sudo bash docker-run.sh --logs

# 平滑重启服务 (保留容器已有注册状态，秒级启动)
sudo bash docker-run.sh --restart

# 卸载 Systemd 服务 (清理容器、配置与策略路由)
sudo bash docker-run.sh --uninstall-service
```

#### 2. 常见客户端与开发环境接入配置
* **终端临时代理**：
  ```bash
  export ALL_PROXY="socks5h://127.0.0.1:1080"
  ```
* **Git 代理**：
  ```bash
  git config --global http.proxy "socks5h://127.0.0.1:1080"
  git config --global https.proxy "socks5h://127.0.0.1:1080"
  ```
* **Clash / Mihomo 配置文件片段**：
  ```yaml
  proxies:
    - name: "WARP-SOCKS5-Local"
      type: socks5
      server: 127.0.0.1
      port: 1080
  ```
* **sing-box 客户端出站 (`outbounds`)**：
  ```json
  {
    "type": "socks",
    "tag": "warp-socks5-out",
    "server": "127.0.0.1",
    "server_port": 1080
  }
  ```

---

### 工具 2：MASQUE (QUIC) 协议双阶段握手测试工具 (`test-masque.py`)

用于排查 WARP MASQUE (QUIC v1) 协议在特定 VPS / 物理网卡下的连通性与网络质量诊断工具 [`test-masque.py`](./test-masque.py)：
* **纯 Python 标准库**：零第三方依赖，开箱即用；
* **RFC 9000 QUIC Initial 握手探测**：填充 1200 字节标准握手包，精确测量往返时延（RTT）与丢包情况；
* **支持物理网卡源 IP 绑定 (`-i / --ip`)**：绕过本地全局代理进行直连探测。

```bash
# 探测官方默认 Endpoint (162.159.197.2) 常用 MASQUE 端口 (443, 8443, 4500, 8095, 4443)
python3 test-masque.py -t 162.159.197.2

# 绑定物理网卡 IP 直连测试 (绕过本地 TUN 代理)
python3 test-masque.py -t 162.159.197.2 -i 172.19.4.28

# 批量测试多个 Anycast 优选 IP 与自定义端口
python3 test-masque.py -t 162.159.192.1,162.159.193.10,188.114.96.1 -p 8443,4443
```

---

### 工具 3：原生 Linux 官方 WARP 客户端安装脚本 (`install.sh`)

用于在原生 Linux 系统（Debian/Ubuntu/CentOS/Fedora）中一键配置官方 Apt/Yum 软件源并安装 `cloudflare-warp` 官方二进制：
```bash
sudo bash install.sh
```

---

## 📁 附录：文件与脚本功能对照表

| 脚本 / 文件 | 核心功能 | 适用场景 |
| :--- | :--- | :--- |
| **`docker-run.sh`** | Docker 容器构建、运行与 Systemd 服务封装 | **本地 / 客户端 VPS**：运行 SOCKS5 代理客户端并管理策略路由 |
| **`cloudflare-warp-socks5.service`** | Systemd 服务 Unit 模板 (含策略路由隔离钩子) | **本地 / 客户端 VPS**：Systemd 开机自启服务定义 |
| **`Dockerfile` & `docker-entrypoint.sh`** | 基于 Ubuntu 24.04 构建包含 WARP + sing-box 镜像 | **本地 / 客户端 VPS**：容器化运行环境与自愈守护 |
| **`test-masque.py`** | MASQUE (QUIC v1) 协议双阶段握手与时延测试工具 | **网络诊断**：检测 Endpoint 连通性与 1200 字节 MTU |
| **`install.sh`** | 官方 Apt/Yum 软件源配置与原生 WARP 客户端安装 | **Linux 原生环境**：安装官方 `cloudflare-warp` |
