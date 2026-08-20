# fhs-install-singbox

> 基于 FHS 标准的 Linux sing-box (VLESS + Reality + Hysteria2) 服务端自动化部署与 VPS 运维工具包。

## 项目介绍

本项目针对基于 `systemd` 的 Linux 发行版，提供了一套高度自动化的 `sing-box` 服务端部署与 VPS 云端部署运维工具。符合 [Filesystem Hierarchy Standard (FHS)](https://en.wikipedia.org/wiki/Filesystem_Hierarchy_Standard) 标准：

- 可执行程序：`/usr/local/bin/sing-box`
- 配置文件：`/etc/sing-box/config.json`
- Hysteria2 证书：`/etc/cert/hy2_cert.pem` 与 `/etc/cert/hy2_key.pem`
- 服务文件：`/etc/systemd/system/sing-box.service`

### 主要特性

1. **组合协议部署**：一键部署 **VLESS + Reality + Vision** (TCP) 与 **Hysteria2** (UDP) 双出站/入站，兼容主流客户端。
2. **自动化密钥与证书处理**：自动生成 Reality 密钥对、Short ID 以及 Hysteria2 自签名 TLS 证书。
3. **防火墙自动配置**：自动识别 `ufw` 或 `firewalld` 并放行相应的 TCP/UDP 端口。
4. **云端自动化运维与免密登录**：自动识别并上传本地 SSH 公钥至 Vultr 账号绑定新实例，并自动同步写入远端 VPS `~/.ssh/authorized_keys` 实现后续免密登录。
5. **本地 fallback 机制**：模板获取优先支持网络下载，在无网或国内网络环境下自动回退使用脚本所在目录的本地模板。

---

## 核心组件说明

| 文件名 | 用途 |
| --- | --- |
| `install-singbox-server.sh` | sing-box 服务端一键安装/更新/重置脚本 |
| `generate-singbox-server-config.sh` | 国内中转 VPS 多端口 Reality 专用配置生成器 (VLESS+Reality ➜ WARP/SOCKS5 落地出站) |
| `update-singbox-keys.sh` | sing-box 服务端各项密钥与凭证安全更新/重置脚本 |
| `update-singbox-sub.sh` | 通过指定订阅链接更新 sing-box 配置并重启服务（支持自动备份与回退） |
| `setup_vps_server.sh` | 通用 VPS 远程部署脚本（支持 IP 直接部署或 Vultr 自动创建） |
| `remove_vultr_instance.sh` | Vultr 实例快速查询与交互式清理工具 |
| `singbox_server_config.json` | sing-box 服务端配置模板（VLESS Reality + Hysteria2） |

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
| `-v`, `--version` | `SINGBOX_VERSION` | `1.12.19` | sing-box 服务端安装版本 |
| `--port` | `SINGBOX_PORT` | `443` | VLESS Reality 监听端口 (TCP) |
| `--domain` | `SINGBOX_DOMAIN` | `www.cloudflare.com` | Reality 目标 SNI 伪装域名 |
| `--uuid` | `SINGBOX_UUID` | `auto` | VLESS 用户 UUID（`auto` 为自动生成） |
| `--short-id` | `SINGBOX_SHORT_ID` | `auto` | Reality Short ID（`auto` 为自动生成） |
| `--log-level` | `SINGBOX_LOG_LEVEL` | `info` | 日志输出级别 (`debug`, `info`, `warn`, `error`) |
| `--hy2-port` | `SINGBOX_HY2_PORT` | `123` | Hysteria2 监听端口 (UDP) |
| `--hy2-domain` | `SINGBOX_HY2_DOMAIN` | `hy2.jayyang.cn` | Hysteria2 TLS 证书域名 |
| `--hy2-password` | `SINGBOX_HY2_PASSWORD` | `auto` | Hysteria2 验证密码（`auto` 为自动生成） |
| `--hy2-up-mbps` | `SINGBOX_HY2_UP_MBPS` | `200` | Hysteria2 服务端上行带宽限制 (Mbps) |
| `--hy2-down-mbps` | `SINGBOX_HY2_DOWN_MBPS` | `200` | Hysteria2 服务端下行带宽限制 (Mbps) |
| `--hy2-masquerade` | `SINGBOX_HY2_MASQUERADE` | `https://www.cloudflare.com` | Hysteria2 伪装响应地址 |
| `-f`, `--force` | - | - | 强制重装（清理已有 sing-box 服务与配置后再安装） |

#### 自定义安装示例

```bash
# 指定安装特定版本与自定义端口
bash install-singbox-server.sh --version 1.12.19 --port 8443 --domain google.com --hy2-port 8444
```

---

### 2. 服务端密钥更新 (`update-singbox-keys.sh`)

专门用于对已安装的 sing-box 服务端进行密钥与凭证更新（支持安全备份与自动语法校验）。

在目标 Linux 服务器上以 `root` 权限直接运行：

```bash
# 一键自动重新生成所有密钥 (UUID, Reality 密钥对, Short ID, Hysteria2 密码)
bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/fhs-install-singbox/update-singbox-keys.sh) -y
```

#### 参数说明

| 参数选项 | 说明 |
| --- | --- |
| `-a`, `--all` | 更新所有密钥（默认操作，包含 UUID、Reality 密钥对、Short ID、Hysteria2 密码） |
| `--uuid [UUID]` | 更新 VLESS UUID（可选自定义 UUID，默认 `auto` 自动生成） |
| `--reality-key` | 重置 Reality 密钥对 (PrivateKey 与 PublicKey) |
| `--short-id [SHORT_ID]` | 更新 Reality Short ID（可选 8 位十六进制，默认 `auto` 自动生成） |
| `--hy2-password [PASSWORD]` | 更新 Hysteria2 密码（可选自定义密码，默认 `auto` 自动生成） |
| `--domain DOMAIN` | 更新 Reality SNI 伪装域名（可选，如 `www.cloudflare.com`） |
| `--hy2-domain DOMAIN` | 更新 Hysteria2 TLS 证书域名并重新生成自签名证书（可选，如 `hy2.example.com`） |
| `-c`, `--config PATH` | 指定配置文件路径 (默认: `/etc/sing-box/config.json`) |
| `-y`, `--yes` | 跳过确认提示直接执行 |

#### 自定义配置与域名更新示例

```bash
# 仅更新 VLESS UUID 与 Reality 密钥对
bash update-singbox-keys.sh --uuid --reality-key -y

# 更新 Reality 伪装域名与 Hysteria2 TLS 域名
bash update-singbox-keys.sh --domain www.google.com --hy2-domain hy2.example.com -y

# 重新生成所有密钥并指定新 Reality 域名
bash update-singbox-keys.sh -a --domain www.apple.com -y
```

---

### 3. 订阅链接配置更新 (`update-singbox-sub.sh`)

专门用于通过订阅链接下载更新 sing-box 服务端/客户端配置文件，并重启服务。内置全流程安全保障：自动备份旧配置至 `/tmp` 目录、语法校验（`sing-box check`）、服务运行状态监控，以及失败自动回退机制。

在目标 Linux 服务器上以 `root` 权限运行：

```bash
# 1. 兼容 singbox-sub-converter 自适应订阅链接 (/sub)
bash update-singbox-sub.sh http://154.12.34.56:8000/sub?token=your_sub_token

# 2. 兼容 singbox-sub-converter 专用 singbox 订阅链接 (/singbox)
bash update-singbox-sub.sh http://154.12.34.56:8000/singbox?token=your_sub_token

# 3. 非交互模式下更新指定订阅链接
bash update-singbox-sub.sh -u "http://154.12.34.56:8000/sub?target=singbox&token=your_sub_token" -y
```

#### 参数说明

| 参数选项 | 说明 |
| --- | --- |
| `-u, --url URL` | 指定订阅链接 URL（必须） |
| `-c, --config PATH` | 指定配置文件路径（默认: `/etc/sing-box/config.json`） |
| `-b, --backup-dir DIR` | 指定备份目录（默认: `/tmp`） |
| `-A, --user-agent AGENT` | 指定 HTTP 请求 User-Agent（默认: `sing-box`） |
| `-t, --timeout SECONDS` | 指定下载超时秒数（默认: `30`） |
| `-y, --yes` | 跳过确认提示直接执行 |
| `-h, --help` | 显示帮助信息 |

---

### 4. 国内中转 VPS 结合 WARP 落地配置生成 (`generate-singbox-server-config.sh`)

当您在**国内云服务器 / 中转 VPS** 上运行 `cloudflare-zero-trust` (WARP SOCKS5 代理) 时，使用配套脚本 [`generate-singbox-server-config.sh`](file:///home/jason/user_data/code/vps-utils/fhs-install-singbox/generate-singbox-server-config.sh) 可一键生成高防封锁的 sing-box 服务端（VLESS + Reality 伪装入站 ➜ SOCKS5 `127.0.0.1:1080` WARP 落地出站）。

#### 架构与流程
```text
[ 用户客户端 (电脑/手机) ] 
          │ (VLESS + Reality 伪装加密协议，防探测防封锁)
          ▼
[ 国内中转 VPS: sing-box (监听 443, 8443, 2053, 2083, 2087, 2096, 8080 等多端口) ]
          │ (本地转发: socks5://127.0.0.1:1080)
          ▼
[ Cloudflare WARP 容器 (Zero Trust / 策略路由隔离) ]
          │ (跨洋高速加密隧道)
          ▼
[ Cloudflare 全球网络 ] ──> [ 目标国际互联网 (Google/GitHub/YouTube等) ]
```

#### 使用方法
```bash
# 1. 零交互一键生成 (自动探测公网 IP、自动生成 UUID 与 Reality 密钥对，开放所有常用端口)
bash generate-singbox-server-config.sh

# 2. 自定义开放端口与 Reality 伪装域名
bash generate-singbox-server-config.sh --ports 443,8443,2053,2083 --sni gateway.icloud.com

# 3. 一键生成并自动应用至 /etc/sing-box/config.json 并重启服务
sudo bash generate-singbox-server-config.sh --apply

# 4. 指定自定义输出路径
bash generate-singbox-server-config.sh -o /etc/sing-box/config.json
```

#### 参数说明
| 参数选项 | 说明 | 默认值 |
| :--- | :--- | :--- |
| `-p, --port <PORT>` | 指定单个开放端口 (例如: `-p 443`) | - |
| `--ports <LIST>` | 指定多个开放端口，逗号分隔 | `443,8443,2053,2083,2087,2096,8080` |
| `-s, --sni <SNI>` | 指定 Reality 伪装域名 | `itunes.apple.com` |
| `-u, --uuid <UUID>` | 指定客户端认证 UUID | 自动随机生成 |
| `--short-id <ID>` | 指定 Reality Short ID | 自动随机生成 |
| `--private-key <KEY>` | 指定 Reality Private Key | 自动生成密钥对 |
| `--public-key <KEY>` | 指定 Reality Public Key | 自动计算衍生 |
| `--socks-port <PORT>` | 指定本地 WARP SOCKS5 代理端口 | `1080` |
| `--socks-host <HOST>` | 指定本地 WARP SOCKS5 代理地址 | `127.0.0.1` |
| `-o, --output <PATH>` | 配置文件输出路径 | `./singbox-server-config.json` |
| `-a, --apply` | 自动写入 `/etc/sing-box/config.json` 并重启服务 | `false` |

---

### 5. 远程 VPS 部署与 Vultr 自动化 (`setup_vps_server.sh`)

`setup_vps_server.sh` 可以在控制端（本地机器）直接对远程 VPS 进行 SSH 一键部署，也可结合 Vultr API 自动创建 VPS 实例并一键完成部署。

#### 模式 A：直接通过 IP 远程部署

在本地执行，通过 SSH 连接远程已有 VPS，**默认将自动部署全套服务**（`sing-box` 服务端 + `subconverter` + `singbox-sub-converter`）：

```bash
# 默认安装全套服务 (sing-box + subconverter + singbox-sub-converter)
bash setup_vps_server.sh --ip 1.2.3.4 --user root

# 如果只需要单独安装 sing-box 服务端
bash setup_vps_server.sh --ip 1.2.3.4 --only-singbox

# 跳过 subconverter，仅部署 sing-box 服务端与 singbox-sub-converter
bash setup_vps_server.sh --ip 1.2.3.4 --no-subconverter

# 结合环境变量传递自定义参数
SINGBOX_PORT=8443 SINGBOX_DOMAIN="microsoft.com" bash setup_vps_server.sh --ip 1.2.3.4 --force
```

#### 远程组件选择与端口参数

| 参数选项 | 默认状态 | 说明 |
| --- | --- | --- |
| `--all` | 默认开启 | 远程一键部署全套服务 (**sing-box 服务端** + **subconverter** + **singbox-sub-converter**) |
| `--no-singbox` | - | 跳过 sing-box 服务端的安装 |
| `--no-subconverter` | - | 跳过 subconverter 服务的安装 |
| `--no-singbox-sub-converter` | - | 跳过 singbox-sub-converter 服务的安装 |
| `--only-singbox` | - | 仅部署 sing-box 服务端 |
| `--only-subconverter` | - | 仅部署 subconverter 服务 |
| `--only-singbox-sub-converter` | - | 仅部署 singbox-sub-converter 服务 |
| `--subconverter-port PORT` | `25500` | 指定 subconverter 端口 (环境变量: `SUBCONVERTER_PORT`) |
| `--singbox-sub-converter-port PORT` | `8000` | 指定 singbox-sub-converter 端口 (环境变量: `SINGBOX_SUB_CONVERTER_PORT`) |

#### 模式 B：Vultr 自动创建并部署

使用 `--vultr` 选项前，需要在本地控制端完成以下准备工作：

##### 步骤 1：安装 `vultr-cli` 客户端

在本地命令行工具中安装 Vultr 官方 CLI 工具：

- **Linux**:
  ```bash
  # 下载最新发布版本解压至系统路径
  curl -sS https://api.github.com/repos/vultr/vultr-cli/releases/latest \
    | grep "browser_download_url.*linux_amd64" \
    | cut -d '"' -f 4 \
    | wget -i - -O vultr-cli.tar.gz
  tar -xvf vultr-cli.tar.gz
  sudo mv vultr-cli /usr/local/bin/
  rm vultr-cli.tar.gz
  ```
- **macOS (Homebrew)**:
  ```bash
  brew install vultr/vultr-cli/vultr-cli
  ```
- **Windows**:
  从 [Vultr CLI Releases](https://github.com/vultr/vultr-cli/releases) 下载 `.zip` 解压并将可执行文件添加至系统 Path 环境变量中。

##### 步骤 2：配置 Vultr API Token

1. 登录 [Vultr 控制台](https://my.vultr.com/)，进入 **Account** -> **API**。
2. 点击 **Enable API** 开启 API 访问权限，并允许您的控制端外网 IP（或设为 `0.0.0.0/0`）。
3. 复制 **Personal Access Token**。
4. 在本地终端中设置环境变量：
   ```bash
   export VULTR_API_KEY="your_personal_access_token_here"
   ```
   *建议将上句写入 `~/.bashrc` 或 `~/.zshrc` 中以便长期生效。*
5. 测试连接：
   ```bash
   vultr-cli account info
   ```

##### 步骤 3：一键自动创建与部署

```bash
# 使用默认配置自动创建实例并完成安装
bash setup_vps_server.sh --vultr
```

##### 可选：Vultr 实例定制环境变量

可通过环境变量自定义开机的实例规格与地域：

| 环境变量 | 默认值 | 描述 |
| --- | --- | --- |
| `VULTR_REGION` | `nrt` | 节点地域代码（`nrt` 为东京 Tokyo, `sgp` 为新加坡, `icn` 为首尔等） |
| `VULTR_PLAN` | `vc2-1c-1gb` | 实例套餐规格（如 `vc2-1c-1gb` 为 1核 1GB 内存） |
| `VULTR_OS` | `2284` | 操作系统 ID (`2284` 为 Ubuntu 24.04 LTS x64) |
| `VULTR_LABEL` | `ubuntu_2404` | 实例 Label 标签名称 |
| `VULTR_HOST` | `jayyang` | 实例的主机名 Hostname |
| `VULTR_TAG` | `v2ray` | 实例 Tag 分组标签 |
| `VULTR_SSH_KEYS` | (空) | 已导入 Vultr 的 SSH Key ID（多个用逗号隔开） |
| `VULTR_SCRIPT_ID` | (空) | 已在 Vultr 注册的 Startup Script ID |

**高级调用示例**：
```bash
# 在东京 (nrt) 创建 1C1G 实例，并指定安装参数
VULTR_REGION="nrt" VULTR_PLAN="vc2-1c-1gb" SINGBOX_PORT=8443 bash setup_vps_server.sh --vultr
```

---

### 6. Vultr 实例删除 (`remove_vultr_instance.sh`)

用于快速查找并交互式删除指定标签的 Vultr 实例：

```bash
# 删除默认标签 (ubuntu_2404) 的实例
bash remove_vultr_instance.sh

# 指定标签删除
bash remove_vultr_instance.sh -l my_vps
```

---

## 服务端配置模板占位符说明

`singbox_server_config.json` 包含了以下参数占位符：

- `{SINGBOX_LOG_LEVEL}`
- `{SINGBOX_PORT}`
- `{SINGBOX_UUID}`
- `{SINGBOX_DOMAIN}`
- `{SINGBOX_PRIVATE_KEY}`
- `{SINGBOX_SHORT_ID}`
- `{SINGBOX_HY2_PORT}`
- `{SINGBOX_HY2_PASSWORD}`
- `{SINGBOX_HY2_UP_MBPS}` / `{SINGBOX_HY2_DOWN_MBPS}`
- `{SINGBOX_HY2_DOMAIN}`
- `{SINGBOX_HY2_CERT_PATH}` / `{SINGBOX_HY2_KEY_PATH}`
- `{SINGBOX_HY2_MASQUERADE}`

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
