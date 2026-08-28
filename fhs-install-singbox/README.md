# fhs-install-singbox

> 基于 FHS 标准的 Linux sing-box (VLESS Reality + SOCKS5 + WS + 住宅 IP 链式路由) 服务端自动化部署与 VPS 运维工具包。

## 项目介绍

本项目针对基于 `systemd` 的 Linux 发行版，提供了一套高度自动化的 `sing-box` 服务端部署与 VPS 云端部署运维工具。符合 [Filesystem Hierarchy Standard (FHS)](https://en.wikipedia.org/wiki/Filesystem_Hierarchy_Standard) 标准：

- 可执行程序：`/usr/local/bin/sing-box`
- 配置文件：`/etc/sing-box/config.json`
- 服务文件：`/etc/systemd/system/sing-box.service`

### 主要特性

1. **多协议多场景入站矩阵**：
   - **`vless-reality-443` (443 端口)**：VLESS + Reality 协议，通过分流路由定向转发至本地 SOCKS 2080（对接 `vpngate-singbox-openvpn` 纯净住宅 IP 代理出口）；
   - **`vless-reality` (8443 端口)**：VLESS + Reality 协议，默认直连出站（使用 VPS 原生公网 IP）；
   - **`socks-in` (10086 端口)**：带账号密码身份认证的通用 SOCKS5 代理入站；
   - **`vless-grpc` (127.0.0.1:8088)**：本地 WS/gRPC 传输入站，专用于配合 Cloudflare Tunnel 与 Anycast 优选 IP 实现 CDN 安全穿透。
2. **闭环分流路由与住宅 IP 出海**：
   - 内置 `direct` 与 `socks-2028` (127.0.0.1:2080) 双出站；
   - 路由规则将 443 端口流量定向转发至住宅代理出口，同时保留 8443 端口原生直连出口。
3. **全自动化密钥与凭据处理**：自动生成 Reality 密钥对 (PrivateKey & PublicKey)、Short ID、UUID 以及 SOCKS 认证用户与强随机密码。
4. **防火墙自动配置**：自动识别 `ufw` 或 `firewalld` 并放行相应的 TCP (443, 8443, 10086, 8088) 端口。
5. **云端自动化运维与免密登录**：自动识别并上传本地 SSH 公钥至 Vultr 账号绑定新实例，并自动同步写入远端 VPS `~/.ssh/authorized_keys` 实现后续免密登录。
6. **本地 fallback 机制**：模板获取优先支持网络下载，在无网或国内网络环境下自动回退使用脚本所在目录的本地模板。

---

## 核心组件说明

| 文件名 | 用途 |
| --- | --- |
| `install-singbox-server.sh` | sing-box 服务端一键安装/更新/重置脚本 |
| `update-singbox-keys.sh` | sing-box 服务端各项密钥、凭证与网络参数安全更新/重置脚本 |
| `update-singbox-sub.sh` | 通过指定订阅链接更新 sing-box 配置（支持 Client 模式与 Server 转发模式，带自动备份与回退） |
| `convert_sub_to_server.py` | sing-box 订阅转 Server 模式转换核心引擎（清除路由、过滤 Reality 节点并重写本地映射端口、生成 Reality 入站） |
| `setup_vps_server.sh` | 通用 VPS 远程部署脚本（支持 IP 直接部署或 Vultr 自动创建） |
| `remove_vultr_instance.sh` | Vultr 实例快速查询与交互式清理工具 |
| `singbox_server_config.json` | sing-box 服务端配置模板（VLESS Reality + SOCKS + WS + 住宅 IP 路由） |

---

## 支持的操作系统

- Ubuntu 18.04+ / Debian 10+
- CentOS 7+ / RHEL / Rocky Linux / AlmaLinux
- Fedora 28+
- Arch Linux

---

## 使用指南

### 1. 本地/单机部署 (`install-singbox-server.sh`)

在目标 Linux 服务器上以 `root` 权限直接运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/fhs-install-singbox/install-singbox-server.sh)
```

#### 参数与环境变量

可以通过命令行参数或环境变量自定义配置：

| 命令行参数 | 环境变量 | 默认值 | 描述 |
| --- | --- | --- | --- |
| `-v`, `--version` | `SINGBOX_VERSION` | `1.12.20` | sing-box 服务端安装版本 |
| `--domain` | `SINGBOX_DOMAIN` | `dl.google.com` | Reality 目标 SNI 伪装域名 |
| `--uuid` | `SINGBOX_UUID` | `auto` | VLESS 用户 UUID（`auto` 为自动生成） |
| `--short-id` | `SINGBOX_SHORT_ID` | `auto` | Reality Short ID（`auto` 为自动生成） |
| `--log-level` | `SINGBOX_LOG_LEVEL` | `warning` | 日志输出级别 (`debug`, `info`, `warning`, `error`) |
| `--socks-port` | `SINGBOX_SOCKS_PORT` | `10086` | SOCKS5 入站监听端口 (TCP/UDP) |
| `--socks-user` | `SINGBOX_SOCKS_USER` | `auto` | SOCKS5 认证用户名（`auto` 为自动生成） |
| `--socks-pass` | `SINGBOX_SOCKS_PASS` | `auto` | SOCKS5 认证密码（`auto` 为自动生成） |
| `--ws-path` | `SINGBOX_WS_PATH` | `/singbox-ws-path` | VLESS WS 传输路径 (8088 端口) |
| `--ws-host` | `SINGBOX_WS_HOST` | `proxy.19910417.xyz` | VLESS WS 头部 Host |
| `--socks-out-server` | `SOCKS_OUT_SERVER` | `127.0.0.1` | SOCKS 出站代理目标 IP (默认本地) |
| `--socks-out-port` | `SOCKS_OUT_PORT` | `2080` | SOCKS 出站代理目标端口 (默认 2080) |
| `-f`, `--force` | - | - | 强制重装（清理已有 sing-box 服务与配置后再安装） |

#### 自定义安装示例

```bash
# 指定安装特定版本与自定义 SNI 域名
bash install-singbox-server.sh --version 1.12.20 --domain dl.google.com --socks-port 10086
```

---

### 2. 服务端密钥与凭据更新 (`update-singbox-keys.sh`)

专门用于对已安装的 sing-box 服务端进行密钥与凭据更新（支持安全备份与自动语法校验）。

在目标 Linux 服务器上以 `root` 权限直接运行：

```bash
# 一键自动重新生成所有密钥与凭据 (UUID, Reality 密钥对, Short ID, SOCKS 凭据)
bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/fhs-install-singbox/update-singbox-keys.sh) -y
```

#### 参数说明

| 参数选项 | 说明 |
| --- | --- |
| `-a`, `--all` | 更新所有密钥（默认操作，包含 UUID、Reality 密钥对、Short ID、SOCKS 凭据） |
| `--uuid [UUID]` | 更新 VLESS UUID（可选自定义 UUID，默认 `auto` 自动生成） |
| `--reality-key` | 重置 Reality 密钥对 (PrivateKey 与 PublicKey) |
| `--short-id [SHORT_ID]` | 更新 Reality Short ID（可选 8 位十六进制，默认 `auto` 自动生成） |
| `--domain DOMAIN` | 更新 Reality SNI 伪装域名（可选，如 `dl.google.com`） |
| `--socks-user USER` | 更新 SOCKS5 入站用户名 |
| `--socks-pass PASS` | 更新 SOCKS5 入站密码 |
| `--socks-port PORT` | 更新 SOCKS5 入站监听端口 |
| `--ws-path PATH` | 更新 VLESS WS 传输路径 |
| `--ws-host HOST` | 更新 VLESS WS 伪装 Host |
| `--socks-out-port PORT` | 更新 SOCKS 出站目标端口 (默认 2080) |
| `-c`, `--config PATH` | 指定配置文件路径 (默认: `/etc/sing-box/config.json`) |
| `-y`, `--yes` | 跳过确认提示直接执行 |

#### 自定义配置与域名更新示例

```bash
# 仅更新 VLESS UUID 与 Reality 密钥对
bash update-singbox-keys.sh --uuid --reality-key -y

# 更新 Reality 伪装域名
bash update-singbox-keys.sh --domain dl.google.com -y

# 重新生成所有密钥并指定新 Reality 域名
bash update-singbox-keys.sh -a --domain dl.google.com -y
```

---

### 3. 订阅链接配置更新 (`update-singbox-sub.sh` 与 `convert_sub_to_server.py`)

专门用于通过订阅链接下载更新 sing-box 服务端/客户端配置文件，并重启服务。内置全流程安全保障：自动备份旧配置至 `/tmp` 目录、语法校验（`sing-box check`）、服务运行状态监控，以及失败自动回退机制。

#### 支持的两种更新模式

1. **Client 客户端模式（默认）**：
   - 直接下载订阅节点与客户端分流路由规则，适用于将 VPS 作为中转或出海客户端。
2. **Server 服务端转发模式（`--mode server` 或 `--server`）**：
   - **清除默认分流并配置精准分流路由**：自动移除客户端原有复杂分流，配置精准的域名与出入站映射路由；
   - **AI 相关域名定向分流**：OpenAI 与 Google AI/Gemini 相关域名自动优先路由至 5001 出站；
   - **精确过滤出站节点**：`outbounds` 中仅保留 **443** 与 **8443** 端口的 `vless+reality` 协议节点；
   - **自动重写目标与本地端口映射**：
     - 原 **8443** 端口节点默认重写为 `127.0.0.1:5000` (tag: `vless-out-5000`)；
     - 原 **443** 端口节点默认重写为 `127.0.0.1:5001` (tag: `vless-out-5001`)；
   - **自动创建入站监听**：
     - **SOCKS5 入站**（默认端口 `1080`，本地监听 `127.0.0.1`）；
     - **VLESS + Reality 入站 1**（默认端口 `12345`，默认路由至 5000）；
     - **VLESS + Reality 入站 2**（默认端口 `12346`，路由至 5001）；
   - **核心转换引擎**：由配套 Python 脚本 [`convert_sub_to_server.py`](./convert_sub_to_server.py) 实现。

在目标 Linux 服务器上以 `root` 权限运行：

```bash
# 1. 默认 Client 客户端模式更新:
bash update-singbox-sub.sh http://154.12.34.56:8000/sub?token=your_sub_token

# 2. Server 服务端转发模式更新:
bash update-singbox-sub.sh http://154.12.34.56:8000/sub?token=your_sub_token --server
```

---

### 4. 远程 VPS 部署与 Vultr 自动化 (`setup_vps_server.sh`)

`setup_vps_server.sh` 可以在控制端（本地机器）直接对远程 VPS 进行 SSH 一键部署，也可结合 Vultr API 自动创建 VPS 实例并一键完成部署。

#### 模式 A：直接通过 IP 远程部署

在本地执行，通过 SSH 连接远程已有 VPS，**默认将自动部署全套服务**（`sing-box` 服务端 + `subconverter` + `singbox-sub-converter`）：

```bash
# 默认安装全套服务 (sing-box + subconverter + singbox-sub-converter)
bash setup_vps_server.sh --ip 1.2.3.4 --user root

# 如果只需要单独安装 sing-box 服务端
bash setup_vps_server.sh --ip 1.2.3.4 --only-singbox

# 结合环境变量传递自定义参数
SINGBOX_DOMAIN="dl.google.com" bash setup_vps_server.sh --ip 1.2.3.4 --force
```

#### 模式 B：Vultr 自动创建并部署

```bash
# 使用默认配置自动创建实例并完成安装
bash setup_vps_server.sh --vultr
```

---

## 服务端配置模板占位符说明

`singbox_server_config.json` 包含了以下参数占位符：

- `{SINGBOX_LOG_LEVEL}`：日志输出等级 (默认 `warning`)
- `{SINGBOX_SOCKS_PORT}`：SOCKS5 入站端口 (默认 `10086`)
- `{SINGBOX_SOCKS_USER}`：SOCKS5 认证用户名
- `{SINGBOX_SOCKS_PASS}`：SOCKS5 认证密码
- `{SINGBOX_UUID}`：VLESS 用户 UUID
- `{SINGBOX_DOMAIN}`：Reality SNI 伪装域名 (默认 `dl.google.com`)
- `{SINGBOX_PRIVATE_KEY}`：Reality PrivateKey 私钥
- `{SINGBOX_SHORT_ID}`：Reality Short ID
- `{SINGBOX_WS_PATH}`：VLESS WS 传输路径 (默认 `/singbox-ws-path`)
- `{SINGBOX_WS_HOST}`：VLESS WS Host 头
- `{SOCKS_OUT_SERVER}`：SOCKS 出站目标 IP (默认 `127.0.0.1`)
- `{SOCKS_OUT_PORT}`：SOCKS 出站目标端口 (默认 `2080`)

---

## 常用服务管理命令

安装完成后，可通过以下命令管理 sing-box 服务：

```bash
# 查看服务运行状态
systemctl status sing-box

# 启动 / 停止 / 重启服务
systemctl start sing-box
systemctl stop sing-box
systemctl restart sing-box

# 查看实时日志
journalctl -u sing-box -f -n 50

# 手动校验配置文件格式
sing-box check -c /etc/sing-box/config.json
```

---

## 代码规范与贡献

- ShellShebang: `#!/usr/bin/env bash`
- 缩进规范：2 个空格
- 变量引用：所有变量统一使用 `"$VARIABLE"` 双引号包裹
- 条件分支：统一使用 `[[ ]]` 代替 `[ ]`
- 代码格式校验：可通过 `bash -n *.sh` 检查语法错误

## 许可证

本项目遵循 [GPL-3.0 License](https://www.gnu.org/licenses/gpl-3.0.html)。
