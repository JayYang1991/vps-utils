# cloudflare-warp 自动化部署指南

本目录提供 Cloudflare WARP 官方客户端 (`cloudflare-warp` / `warp-cli`) 的一键自动化安装与 Systemd 服务配置脚本。脚本负责自动配置官方 Apt/Yum 软件源并安装 `cloudflare-warp` 软件包，同时启动后台 `warp-svc` 开机自启服务。

---

## 🚀 快速安装与重新安装

在 VPS 上以 `root` 权限运行以下命令，脚本会自动识别 Linux 发行版与系统架构，配置官方仓库并完成软件安装：

### 1. 标准安装

```bash
# 远程一键安装
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/cloudflare-warp/install.sh)

# 或本地运行
cd cloudflare-warp
sudo bash install.sh
```

### 2. 强制重新安装

若遇到环境损坏或需要重置软件环境，可传入 `-r` 或 `--reinstall` 参数开启重新安装模式（自动停止已有服务并重新重装软件包）：

```bash
# 远程一键重新安装
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/cloudflare-warp/install.sh) -r

# 或本地运行
sudo bash install.sh -r
```

---

## 🛠️ 参数与环境变量说明

| 参数选项 | 环境变量 | 说明 |
| --- | --- | --- |
| `-r, --reinstall` | `REINSTALL=true` | 强制重新安装 Cloudflare WARP（停止服务并重装软件包） |
| `-h, --help` | - | 显示帮助信息 |

---

## 📋 常用 CLI 配置指南

安装完成后，可以使用官方 `warp-cli` 工具按需完成后续初始化与配置：

| 操作 | 命令 |
| --- | --- |
| **初始化注册账户** | `warp-cli registration new` |
| **切换为 SOCKS5 代理模式** (推荐) | `warp-cli mode proxy` |
| **设置 SOCKS5 代理端口** (默认 40000) | `warp-cli proxy port 40000` |
| **切换为全局 WARP VPN 模式** | `warp-cli mode warp` |
| **建立 WARP 连接** | `warp-cli connect` |
| **断开 WARP 连接** | `warp-cli disconnect` |
| **查看 WARP 连接状态** | `warp-cli status` |
| **查看账户与流量信息** | `warp-cli registration show` (或 `warp-cli account`) |
| **应用 WARP+ 密钥** | `warp-cli registration license <YOUR_KEY>` |

---

## 🧪 SOCKS5 代理测试示例

若配置为 **SOCKS5 代理模式**（端口 40000），可通过以下 `curl` 命令测试出站代理状态：

```bash
curl -x socks5://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace
```

连通时输出的 trace 信息中将显示 `warp=on` 或 `warp=plus`。
