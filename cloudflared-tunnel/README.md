# cloudflared-tunnel 自动化部署指南

本目录提供 Cloudflare Official Agent (`cloudflared`) 的一键自动化安装与 Systemd 后台服务部署脚本，用于在 VPS 上实现 Cloudflare Tunnel 内网穿透与安全公网服务发布。

---

## 🚀 快速安装

在 VPS 上以 `root` 权限运行以下命令，脚本会自动检测系统架构并下载官方最新版二进制程序，配置后台 Systemd 服务：

### 方式 1：命名 Tunnel 模式（推荐，使用 Zero Trust Token）

在 [Cloudflare Zero Trust 控制台](https://one.dash.cloudflare.com/) 接入新建的 Tunnel 并复制凭证 Token：

```bash
# 远程一键安装 (将 YOUR_TOKEN 替换为您的 Cloudflare Token)
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/cloudflared-tunnel/install.sh) -t <YOUR_CLOUDFLARED_TOKEN>
```

或在克隆本仓库后于本地运行：

```bash
cd cloudflared-tunnel
sudo bash install.sh -t <YOUR_CLOUDFLARED_TOKEN>
```

---

### 方式 2：Quick Tunnel 临时穿透模式（无需 Token）

若未提供 Token，脚本将自动配置为 Quick Tunnel 临时穿透模式，将指定的本地服务对外映射并生成 `.trycloudflare.com` 临时公网访问域名：

```bash
# 穿透本地默认 8000 端口 (singbox-sub-converter)
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/cloudflared-tunnel/install.sh)

# 穿透指定本地服务地址 (如 25500 端口的 subconverter 服务)
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/cloudflared-tunnel/install.sh) -u http://localhost:25500
```

---

## 🛠️ 参数与环境变量说明

| 参数选项 | 环境变量 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `-t, --token` | `CLOUDFLARED_TOKEN` | (空) | Cloudflare Zero Trust 分配的 Tunnel 认证密钥 Token |
| `-u, --url` | `LOCAL_SERVICE_URL` | `http://localhost:8000` | Quick Tunnel 模式下穿透的目标本地服务地址 |
| `-h, --help` | - | - | 显示帮助菜单 |

---

## 📋 服务管理命令

| 操作 | 命令 |
| --- | --- |
| **查看服务状态** | `systemctl status cloudflared` |
| **重启服务** | `systemctl restart cloudflared` |
| **停止服务** | `systemctl stop cloudflared` |
| **启动服务** | `systemctl start cloudflared` |
| **查看运行日志与穿透域名** | `journalctl -u cloudflared -n 50 --no-pager` |

---

## 📁 安装路径与配置文件

- **二进制程序路径**：`/usr/local/bin/cloudflared`
- **配置目录**：`/etc/cloudflared`
- **Systemd 服务路径**：`/etc/systemd/system/cloudflared.service`
