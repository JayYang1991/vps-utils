# fhs-install-v2ray

> Bash scripts for installing V2Ray and sing-box on systemd-based Linux distributions

该脚本安装的文件符合 [Filesystem Hierarchy Standard (FHS)](https://en.wikipedia.org/wiki/Filesystem_Hierarchy_Standard)：

```
installed: /usr/local/bin/v2ray
installed: /usr/local/bin/v2ctl
installed: /usr/local/share/v2ray/geoip.dat
installed: /usr/local/share/v2ray/geosite.dat
installed: /usr/local/etc/v2ray/config.json
installed: /var/log/v2ray/
installed: /var/log/v2ray/access.log
installed: /var/log/v2ray/error.log
installed: /etc/systemd/system/v2ray.service
installed: /etc/systemd/system/v2ray@.service
```

## 项目介绍

本项目基于 [V2Fly 官方 fhs-install-v2ray](https://github.com/v2fly/fhs-install-v2ray) 项目，在标准安装功能的基础上，扩展了以下功能：

- **统一安装脚本** - 一个脚本支持多种安装模式，通过 `--mode` 参数选择
- **代理服务端安装** - 快速部署 V2Ray 代理服务器
- **代理客户端安装** - 配置客户端通过代理服务器访问网络
- **反向代理服务端安装** - 实现内网服务穿透，从外网访问局域网服务
- **Vultr 自动化部署** - 一键创建云服务器并自动安装配置 sing-box
- **预置配置模板** - 提供常用场景的配置文件模板（V2Ray 与 sing-box）

## 配置模板说明

本仓库包含多套可直接修改使用的配置模板（均含占位符）：

- `proxy_server_config.json` / `proxy_client_config.json`：V2Ray 代理模板（gRPC 传输）。
- `reverse_server_config.json`：V2Ray 反向代理服务端模板。
- `singbox_server_config.json`：sing-box 服务端模板（VLESS + Reality + Hysteria2）。
- `singbox_client_config.json`：sing-box 客户端模板（VLESS + Hysteria2 双出站，TUN 模式，局域网与中国地址直连，其余走代理）。

sing-box 模板占位符以 `SINGBOX_*` 命名，例如 `{SINGBOX_SERVER_IP}`、`{SINGBOX_UUID}`。

## 重要提示

**不推荐在 docker 中使用本项目安装 v2ray，请直接使用 [官方镜像](https://github.com/v2fly/docker)。**  
如果官方镜像不能满足您自定义安装的需要，请以**复刻并修改上游 dockerfile 的方式来实现**。

V2Ray 安装**不会自动生成配置文件**；sing-box 安装脚本会基于模板生成配置。  
请在安装完成后参阅 [文档](https://www.v2fly.org/) 了解配置文件语法，并自己完成适合自己的配置文件。过程中可参阅社区贡献的 [配置文件模板](https://github.com/v2fly/v2ray-examples)  
（**提请您注意这些模板复制下来以后是需要您自己修改调整的，不能直接使用**）

## 支持的操作系统

- Debian 8+ / Ubuntu 16.04+
- CentOS 7+ / Rocky Linux / AlmaLinux
- Fedora 28+
- openSUSE 15+
- Arch Linux

## 使用说明

* 该脚本在运行时会提供 `info` 和 `error` 等信息，请仔细阅读。

### install-singbox-server.sh - sing-box Reality 服务器安装脚本

`install-singbox-server.sh` 用于在 Linux 服务器上快速部署基于 VLESS + Reality + Vision + Hysteria2 协议的 sing-box 服务器。

#### 基本用法

```bash
# 一键安装（使用默认参数）
bash <(curl -L https://raw.githubusercontent.com/JayYang1991/fhs-install-v2ray/master/install-singbox-server.sh)
```

安装完成后会在服务端生成：
- `/etc/sing-box/config.json`
- 客户端配置临时文件（位于 `/tmp/singbox_client_config.*.json`，脚本会输出该路径）

#### 参数说明

可以通过环境变量或命令行参数自定义配置：

| 参数 | 环境变量 | 描述 | 默认值 |
|------|----------|------|--------|
| `--port` | `SINGBOX_PORT` | 监听端口 | 443 |
| `--domain` | `SINGBOX_DOMAIN` | SNI 域名 (Reality 目标) | www.cloudflare.com |
| `-f`, `--force` | | 强制安装（安装前自动执行卸载逻辑，清理旧版本） | |
| `--uuid` | `SINGBOX_UUID` | 用户 UUID | 自动生成 |
| `--short-id` | `SINGBOX_SHORT_ID` | Reality Short ID | 自动生成 |
| `--log-level` | `SINGBOX_LOG_LEVEL` | 日志级别 | info |
| `--hy2-port` | `SINGBOX_HY2_PORT` | Hysteria2 监听端口（UDP） | 123 |
| `--hy2-domain` | `SINGBOX_HY2_DOMAIN` | Hysteria2 TLS 域名 | hy2.jayyang.cn |
| `--hy2-password` | `SINGBOX_HY2_PASSWORD` | Hysteria2 用户密码 | 自动生成 |
| `--hy2-up-mbps` | `SINGBOX_HY2_UP_MBPS` | Hysteria2 上行带宽（Mbps） | 200 |
| `--hy2-down-mbps` | `SINGBOX_HY2_DOWN_MBPS` | Hysteria2 下行带宽（Mbps） | 200 |
| `--hy2-masquerade` | `SINGBOX_HY2_MASQUERADE` | Hysteria2 伪装地址 | https://www.cloudflare.com |

#### 示例

```bash
# 自定义端口和域名
bash <(curl -L https://raw.githubusercontent.com/JayYang1991/fhs-install-v2ray/master/install-singbox-server.sh) --port 8443 --domain google.com
```

#### 特性

1. **全自动部署**：自动安装架构匹配的 sing-box 与依赖。
2. **Reality 安全保障**：自动生成密钥对并配置 Reality 隧道。
3. **防火墙自动配置**：支持 `ufw` 和 `firewalld` 自动放行 `TCP/$SINGBOX_PORT` 与 `UDP/$SINGBOX_HY2_PORT`。
4. **配置生成**：在线下载模板并生成 `/etc/sing-box/config.json`，同时输出客户端配置路径。
5. **证书自动处理**：Hysteria2 证书固定使用 `/etc/cert/hy2_cert.pem` 与 `/etc/cert/hy2_key.pem`，不存在时自动生成自签名证书。

### sing-box 节点切换脚本 (`switch-singbox-proxy.sh`)

仓库提供了 `switch-singbox-proxy.sh` 脚本，用于通过 sing-box 的 Clash API 动态切换代理节点。支持自动优选（延迟最低）、切换至下一个节点或设置特定节点。

#### 基本用法

```bash
# 自动选择并切换至延迟最低的节点（默认动作）
bash switch-singbox-proxy.sh --api http://127.0.0.1:9090

# 切换至组内下一个节点
bash switch-singbox-proxy.sh --next

# 切换至特定节点
bash switch-singbox-proxy.sh --group "PROXY" --set "MyNodeName"

# 查询当前组和节点信息
bash switch-singbox-proxy.sh --list-groups
bash switch-singbox-proxy.sh --group "PROXY" --list-nodes
```

#### 参数说明

- `--api`: sing-box external controller 地址（默认：`http://127.0.0.1:9090`）。
- `--group`: 代理组名称（可选，为空时自动发现，优先使用 `PROXY` 组）。
- `--best`: 自动测试延迟并切换至最优节点（默认行为）。
- `--next`: 切换至组内的下一个节点。
- `--set`: 手动切换至指定名称的节点。
- `--test-url`: 延迟测试地址（默认：`https://www.gstatic.com/generate_204`）。
- `--timeout-ms`: 测试超时时间（毫秒，默认：5000）。


### 统一安装脚本

V2Ray 相关安装统一由 `install-v2ray.sh` 处理，通过 `--mode` 参数选择不同的安装模式（`proxy-server` / `proxy-client` / `reverse-server` / `update-dat` / `--remove`）。

#### 常用选项

| 选项 | 描述 |
|------|------|
| `--mode` | 安装模式（详见下方各模式说明） |
| `--remove` | 卸载 V2Ray（所有模式均适用） |
| `--version` | 安装特定版本的 V2Ray（例如 `--version v4.45.2`） |
| `-c`, `--check` | 检查是否有新版本可更新 |
| `-f`, `--force` | 强制重新安装最新版本（即使已经是最新） |
| `-l`, `--local` | 从本地文件安装（例如 `-l /tmp/v2ray.zip`） |
| `-p`, `--proxy` | 通过代理服务器下载（例如 `-p http://127.0.0.1:8118`） |

#### 安装 V2Ray 代理服务端

**环境变量设置**（必须）：
- `V2RAY_PROXY_ID`: VMess 用户 ID

```bash
# 设置环境变量
export V2RAY_PROXY_ID="your-vmess-id"

# 安装代理服务端
# bash <(curl -L https://raw.githubusercontent.com/JayYang1991/fhs-install-v2ray/master/install-v2ray.sh) --mode proxy-server
```

**特性**：
- 使用 VMess 协议与 gRPC 传输
- 内置流量统计功能（通过 API）
- 支持域名路由规则，可自定义分流策略
- 预置常用域名黑名单

### 更新 geoip.dat 和 geosite.dat

可以使用统一脚本仅更新数据文件：

```bash
# 更新 .dat 数据文件
bash <(curl -L https://raw.githubusercontent.com/JayYang1991/fhs-install-v2ray/master/install-v2ray.sh) --mode update-dat
```

### 移除 V2Ray

```bash
# 移除 V2Ray（所有模式）
# bash <(curl -L https://raw.githubusercontent.com/JayYang1991/fhs-install-v2ray/master/install-v2ray.sh) --remove
```

#### 安装 V2Ray Proxy 客户端

在本地机器上安装客户端，通过代理服务器访问网络。

**环境变量设置**（必须）：
- `V2RAY_PROXY_SERVER_IP`: 代理服务器 IP 地址
- `V2RAY_PROXY_ID`: VMess 用户 ID
- `V2RAY_REVERSE_SERVER_IP`: 反向代理服务器 IP 地址（可选）
- `V2RAY_REVERSE_ID`: 反向代理用户 ID（可选）

```bash
# 设置环境变量
export V2RAY_PROXY_SERVER_IP="your-server-ip"
export V2RAY_PROXY_ID="your-vmess-id"
export V2RAY_REVERSE_SERVER_IP="your-reverse-server-ip"
export V2RAY_REVERSE_ID="your-reverse-id"

# 安装客户端
# bash <(curl -L https://raw.githubusercontent.com/JayYang1991/fhs-install-v2ray/master/install-v2ray.sh) --mode proxy-client
```

**特性**：
- 支持 SOCKS5 和 HTTP 代理协议
- 内置流量健康检测和自动故障切换
- 支持多出口负载均衡
- 预置国内直连规则（geosite:cn）

#### 安装 V2Ray 反向代理服务端

实现内网穿透，从外网访问局域网内的服务。

**环境变量设置**（必须）：
- `V2RAY_REVERSE_ID`: 反向代理用户 ID

```bash
# 设置环境变量
export V2RAY_REVERSE_ID="your-reverse-id"

# 安装反向代理服务端
# bash <(curl -L https://raw.githubusercontent.com/JayYang1991/fhs-install-v2ray/master/install-v2ray.sh) --mode reverse-server
```

**特性**：
- 支持多域名反向代理
- 使用 VMess 协议建立隧道
- 基于 SNI 路由，支持 HTTPS 流量转发

### 流量统计命令

```bash
# v2ray api stats --server="127.0.0.1:10085"
```

### 4. Cloudflare Workers 测速后端 (`speedtest-worker.js`)

本项目包含一个精简的 Cloudflare Workers 脚本，专门为 [CloudflareSpeedTest (cfst)](https://github.com/XIU2/CloudflareSpeedTest) 等 CLI 工具优化的测速后端。

#### 部署步骤

1. **登录 Cloudflare**：进入 [Cloudflare Dashboard](https://dash.cloudflare.com/)。
2. **创建 Worker**：在侧边栏选择 "Workers & Pages" -> "Create application" -> "Create Worker"。
3. **命名并部署**：给你的 Worker 起个名字（如 `my-speedtest`），点击 "Deploy"。
4. **编辑代码**：点击 "Edit code"，将编辑器中的所有代码替换为本项目中的 `speedtest-worker.js` 内容。
5. **保存并部署**：点击右上角的 "Save and deploy"。

#### CLI 工具使用教程

你可以使用部署好的 Worker URL 作为测速地址进行 IP 优选：

```bash
# 使用 CloudflareSpeedTest 进行下载测速
./CloudflareST -url https://your-worker-name.workers.dev/__down?bytes=100000000
```

#### sing-box 配合用法

**1. 作为延迟测试 (urltest) 地址**

在 sing-box 配置文件的 `outbounds` 中，你可以将该 Worker 用于 `urltest` 类型的出站节点，以实现自动选路：

```json
{
  "type": "urltest",
  "tag": "auto-select",
  "outbounds": ["proxy1", "proxy2"],
  "url": "https://your-worker-name.workers.dev/generate_204",
  "interval": "1m0s",
  "tolerance": 50
}
```

**2. 手动通过代理进行下载测速**

如果你想测试某个代理节点通过该 Worker 的实际下载带宽，可以使用 `curl` 配合代理：

```bash
# 假设你的 sing-box 开启了 7890 端口的混合代理
curl -x http://127.0.0.1:7890 -L "https://your-worker-name.workers.dev/__down?bytes=50000000" -o /dev/null
```

**功能特性：**
- **高性能流传输**：采用 `ReadableStream` 技术，支持大规模数据下载测试而不占用 Worker 内存。
- **参数兼容**：完全支持 `?bytes=` 参数，适配各种测速工具。
- **多端点支持**：
    - `/generate_204`: 返回 204 No Content，非常适合 sing-box 的 `urltest`。
    - `/cdn-cgi/trace` 或 `/`: 返回详细的节点信息，可验证代理 IP 是否生效。
    - `/__down`: 流式下载，用于带宽压力测试。
- **节点识别**：根目录 `/` 和 `/cdn-cgi/trace` 均返回标准节点信息（Colo, IP, Location）。
- **极简设计**：移除了所有前端 UI，仅保留核心测速 API，响应更迅速。

## 高级部署与辅助工具

### 1. 自动化 VPS 远程部署 (`setup_vps_server.sh`)

该脚本是一个通用的 VPS 远程安装工具。它支持通过 SSH 在远程 VPS 上一键安装 sing-box，并具备 Vultr 自动化创建功能。

#### 使用方法

```bash
# 模式 A：通过 IP 直接远程安装 (适用于已有 VPS)
bash setup_vps_server.sh --ip 8.137.160.254

# 模式 B：Vultr 自动创建并安装
# 需要本地已安装并配置好 vultr-cli
bash setup_vps_server.sh --vultr

# 可选参数示例：
# --user 指定 SSH 用户名 (默认 root)
# --force 强制重新安装 (先卸载旧版本)
bash setup_vps_server.sh --ip 1.2.3.4 --user myuser --force
```

### 2. FRP 服务端一键安装 (`install-frp.sh`)

用于在 Linux 服务器上部署 FRP 服务端 (frps)，支持 HTTPS 穿透。

```bash
# 默认安装
bash <(curl -L https://raw.githubusercontent.com/JayYang1991/fhs-install-v2ray/master/install-frp.sh)
```

### 3. 离线安装包构建脚本

用于在有网环境下下载所有依赖并打包成离线安装包，以便在无网服务器上安装。

- `build-offline-singbox.sh`: 构建 sing-box 离线安装包。
- `build-offline-v2ray.sh`: 构建 V2Ray 离线安装包。

### 4. 其它辅助脚本

- `download-singbox-rules.sh`: 下载最新的 sing-box 规则集 (`.srs`)。
- `generate-singbox-hysteria2-config.sh`: 生成 Hysteria2 服务端与客户端配置文件及自签名证书。
- `remove_vultr_instance.sh`: 快速删除 Vultr 实例。

## 配置工具

本仓库提供了两个强大的配置处理工具：

#### 1. `merge_configs.py` (Clash -> Sing-box)
该工具用于将外部 Clash 节点的代理信息合并到现有的 Sing-box 配置文件中。

`merge_configs.py` 是一个 Python 脚本，支持将 Clash Verge (Mihomo) 导出的 YAML 配置文件中的节点转换为 sing-box 格式，并与现有的 sing-box 节点合并。

#### 主要功能
- **全节点合并**：自动提取并在 sing-box 中保留原有节点，同时加入 Clash 节点。
- **智能策略组**：自动创建一个名为 `Auto-Select-All` 的 `urltest` 组，包含所有合并的节点，实现毫秒级自动优选。
- **协议支持**：支持 VLESS (Reality/gRPC/WS)、Hysteria2、Shadowsocks、Trojan 等主流协议转换。
- **智能合并与去重**：如果 Clash 配置文件中的节点名称与 Sing-box 现有节点冲突，脚本将强制使用 Clash 的配置覆盖原有节点，避免重复。
- **灵活排序**：默认将所有代理节点合并至 `Auto-Select-All` 组，Clash 节点排在前面，Sing-box 原始节点排在最后。
- **自定义输出**：支持指定输出文件路径。

#### 使用方法
```bash
# 基本用法
python3 merge_configs.py -s /etc/sing-box/config.json -c ~/.config/clash/config.yaml -o final_merged.json

# 如果不指定参数，脚本会尝试寻找默认路径并在当前目录生成 merged_config.json
python3 merge_configs.py
```

#### 2. `sb_to_clash.py` (Sing-box -> Clash)
该工具用于将现有的 Sing-box 配置文件转换为 Clash Verge (Mihomo) 格式。

**特性：**
- **协议转换**：支持将 VLESS (Reality/gRPC/WS)、Hysteria2、Shadowsocks、Trojan 从 Sing-box 格式转换为 Clash 格式。
- **自动模板**：自动生成完整的 Clash 配置文件，包含优化的 DNS 设置、策略组（手动选择、自动优选）以及常用路由规则。
- **自定义路径**：支持指定输入 Sing-box 路径和输出 YAML 路径。

**使用方法：**
```bash
# 默认转换 (输入 /etc/sing-box/config.json, 输出当前目录 clash_config.yaml)
python3 sb_to_clash.py

# 使用具体命名参数
python3 sb_to_clash.py -i /path/to/singbox.json -o /path/to/output.yaml
```

#### 3. `update_cloudflare_ips.py` (Cloudflare 优选 IP 自动化)
该工具集成 [CloudflareSpeedTest (cfst)](https://github.com/XIU2/CloudflareSpeedTest) 功能，实现对 Cloudflare IP 的自动测速与配置更新。

**特性：**
- **智能合并**：从本地 `cucc-ip.txt` 和现有 Sing-box 配置文件中自动提取并合并 IPv4 地址。
- **自动优选**：调用 `cfst` 工具执行 HTTPing 测速，精准筛选低延迟 IP。
- **自动更新**：自动提取最优的前 15 个 IP，并按顺序更新到 Sing-box 配置文件中标签为 `cloudflare1` 到 `cloudflare15` 的条目。

**使用方法：**
```bash
# 默认模式 (读取 /etc/singbox/config.json, 在当前目录生成新配置)
python3 update_cloudflare_ips.py

# 自定义路径
python3 update_cloudflare_ips.py /path/to/origin.json /path/to/output.json
```

#### 示例
```bash
python3 merge_configs.py /etc/sing-box/config.json ~/.local/share/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml final_config.json
```

## 配置文件模板

项目提供了多种配置文件模板，位于项目根目录：

| 文件名 | 用途 |
|--------|------|
| `proxy_server_config.json` | V2Ray 代理服务端配置 |
| `proxy_client_config.json` | V2Ray 代理客户端配置 |
| `reverse_server_config.json` | V2Ray 反向代理服务端配置 |
| `singbox_server_config.json` | sing-box 服务端模板（VLESS + Reality + Hysteria2） |
| `singbox_client_config.json` | sing-box 客户端模板（VLESS + Hysteria2） |

**使用方法（V2Ray）**：
1. 下载对应的配置文件模板
2. 替换占位符（如 `{V2RAY_PROXY_ID}`、`{V2RAY_PROXY_SERVER_IP}` 等）
3. 复制到 `/usr/local/etc/v2ray/config.json`
4. 重启 V2Ray 服务：`systemctl restart v2ray.service`

**使用方法（sing-box）**：
1. 直接运行 `install-singbox-server.sh`，脚本会在线下载模板并生成 `/etc/sing-box/config.json`
2. 客户端模板会生成到 `/tmp/singbox_client_config.*.json` 并在安装结束时输出路径

## 常用命令

```bash
# 启动 V2Ray 服务
# systemctl start v2ray.service

# 停止 V2Ray 服务
# systemctl stop v2ray.service

# 重启 V2Ray 服务
# systemctl restart v2ray.service

# 查看 V2Ray 服务状态
# systemctl status v2ray.service

# 查看 V2Ray 日志
# journalctl -u v2ray.service -f

# 查看配置文件
# cat /usr/local/etc/v2ray/config.json

# 测试配置文件
# v2ray -test -config /usr/local/etc/v2ray/config.json
```

## 环境变量

### 通用路径变量

```bash
# 设置数据文件路径（默认：/usr/local/share/v2ray）
export DAT_PATH='/usr/local/share/v2ray'

# 设置配置文件路径（默认：/usr/local/etc/v2ray）
export JSON_PATH='/usr/local/etc/v2ray'

# 设置多配置文件路径（可选）
export JSONS_PATH='/usr/local/etc/v2ray'

# 检查所有服务文件（可选，默认：no）
export check_all_service_files='yes'
```

### 代理服务端变量

```bash
# 代理服务器 IP（客户端配置时使用）
export V2RAY_PROXY_SERVER_IP="your-server-ip"

# VMess 用户 ID
export V2RAY_PROXY_ID="your-vmess-id"
```

### 反向代理变量

```bash
# 反向代理服务器 IP
export V2RAY_REVERSE_SERVER_IP="your-reverse-server-ip"

# 反向代理用户 ID
export V2RAY_REVERSE_ID="your-reverse-id"
```

## 解决问题

* 「[不安装或更新 geoip.dat 和 geosite.dat](https://github.com/v2fly/fhs-install-v2ray/wiki/Do-not-install-or-update-geoip.dat-and-geosite-dat-zh-Hans-CN)」。
* 「[使用证书时权限不足](https://github.com/v2fly/fhs-install-v2ray/wiki/Insufficient-permissions-when-using-certificates-zh-Hans-CN)」。
* 「[从旧脚本迁移至此](https://github.com/v2fly/fhs-install-v2ray/wiki/Migrate-from-the-old-script-to-this-zh-Hans-CN)」。
* 「[将 .dat 文档由 lib 目录移动到 share 目录](https://github.com/v2fly/fhs-install-v2ray/wiki/Move-.dat-files-from-lib-directory-to-share-directory-zh-Hans-CN)」。
* 「[使用 VLESS 协议](https://github.com/v2fly/fhs-install-v2ray/wiki/To-use-the-VLESS-protocol-zh-Hans-CN)」。

> 若您的问题没有在上方列出，欢迎在 Issue 区提出。

**提问前请先阅读 [Issue #63](https://github.com/v2fly/fhs-install-v2ray/issues/63)，否则可能无法得到解答并被锁定。**

## 开发与测试

### Linting

```bash
# 使用 shellcheck 检查脚本
shellcheck install-*.sh

# 使用 shfmt 格式化脚本
shfmt -i 2 -ci -sr -w install-*.sh
```

### 测试

可以直接运行脚本进行测试。CI 通过 `.github/workflows/sh-checker.yml` 在 Ubuntu、Rocky Linux 和 Arch Linux 上自动运行测试。

## 贡献

请于 [develop](https://github.com/JayYang1991/fhs-install-v2ray/tree/develop) 分支进行，以避免对主分支造成破坏。

待确定无误后，两分支将进行合并。

## 代码风格

- Shebang: `#!/usr/bin/env bash`
- 缩进：2 个空格
- 使用双引号包裹所有变量引用：`"$VARIABLE"`
- 使用 `[[ ]]` 而非 `[ ]` 进行测试
- 函数命名：snake_case
- 常量命名：UPPER_CASE

详见 [AGENTS.md](AGENTS.md)。

## 许可证

本项目基于 [V2Fly 官方项目](https://github.com/v2fly/fhs-install-v2ray) fork，遵循相同的许可证（GPL-3.0 或更高版本）。

## 相关链接

- [V2Fly 官方文档](https://www.v2fly.org/)
- [V2Ray 配置示例](https://github.com/v2fly/v2ray-examples)
- [V2Fly 官方 Docker 镜像](https://github.com/v2fly/docker)
- [V2Fly fhs-install-v2ray](https://github.com/v2fly/fhs-install-v2ray)
