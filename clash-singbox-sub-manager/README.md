# Clash & Sing-box 订阅同步与注入管理器 (clash-singbox-sub-manager)

基于 Python 3 的轻量级 Clash 订阅转换与 Sing-box 代理入站注入服务。以 Systemd 守护进程运行在后台，提供 Web 前台管理界面、实时订阅分发、动态 UUID 管理、二维码扫码导入以及本地代理加速等功能。

---

## 💡 典型使用场景 (Use Cases)

本项目专门应用于 **Subapi / 在线订阅转换服务无法访问的中转 VPS 节点**：

- **痛点背景**：
  在跨境链路或中转加速网络架构中，中转 VPS 节点（如境内中转机、受限网络 VPS、特定内网中转机等）通常由于网络阻断、DNS 污染或防火墙阻拦，**无法直接连接或访问外部公共/私有的 Subapi / 订阅转换服务**（如外部 subconverter / subapi 接口超时或不可达），导致无法动态生成或实时维护客户端可用的 Clash 完整订阅与分流配置。

- **解决方案与核心价值**：
  1. **本地化独立运行，零外部 Subapi 依赖**：直接在中转 VPS 本地运行纯 Python 订阅解析与注入引擎，完全不需要依赖或调用任何第三方外部订阅转换服务。
  2. **本地 Sing-box 入站自动提取**：自动读取中转 VPS 本机 `/etc/sing-box/config.json` 中的多协议入站（VLESS Reality、Hysteria2、Trojan、Shadowsocks、SOCKS5 等），一键封装为标准 Clash 代理节点。
  3. **双通道上游拉取与模板兜底**：支持优先通过中转 VPS 本地 SOCKS5 代理通道拉取上游 Clash 规则模板，代理不可用时毫秒级自动回落直连，甚至在无上游订阅时直接使用内置标准精简模板。
  4. **独立订阅分发与防盗刷交付**：中转 VPS 本地对外提供基于专属 UUID 的安全订阅分发端点与 Web 可视化管理面板，支持客户端一键导入或扫码导入，彻底打通中转 VPS 节点的订阅交付闭环。

---

## 🌟 核心功能特性

1. **⚡ 自动提取 Sing-box 入站代理节点**
   - 自动解析当前环境 `/etc/sing-box/config.json` 中的 `inbounds` 配置。
   - 支持协议：`mixed` (SOCKS5/HTTP)、`socks`、`http`、`shadowsocks`、`trojan`、`vless` (含 Reality)、`vmess`、`hysteria2`、`hysteria`、`tuic`。
   - 节点的 `server` (IP) 字段支持通过安装参数、Web 界面指定，或自动探测公网 IPv4。

2. **🌐 优先本地代理拉取与直连自动回落**
   - 上游 Clash 订阅拉取优先走本地 SOCKS5 代理（默认 `socks5h://127.0.0.1:2080`，由代理端解析域名避免污染并加速大文件下载）。
   - 若本地代理不可用或超时，系统**毫秒级自动回落到直连**拉取，确保服务 100% 高可用。
   - 支持在 Web 面板与配置文件中自由修改代理地址。

3. **🧹 订阅深度重构与失效节点/分组清理**
   - **清除所有原节点**：清空上游 Clash 订阅中的所有原始代理节点，仅注入本地提取的 Sing-box 节点。
   - **注入「节点选择」分组并优化排序**：将提取出的代理节点自动加入所有包含 `节点选择` 的策略组（如 `节点选择`、`🚀 节点选择`、`PROXIES` 等），并自动进行协议排序优化（原生直连与加密协议如 VLESS、Hysteria2、Trojan、Shadowsocks 等优先排在最前，SOCKS / SOCKS5 协议节点自动排在最后）。
   - **清理失效地域组**：自动识别并删除含有 `自动选择`、`XX节点`（如 `香港节点`、`日本节点`、`美国节点` 等正则匹配组）的分组。
   - **路由与规则重定向**：清理剩余分组中对已删除组的引用；若分流规则（`rules`）指向已被删除的组或节点，自动智能重定向至主「节点选择」组，防止客户端报错。
   - **保留全部高级配置**：完整保留路由规则（`rules`）、规则集（`rule-providers`）、`dns`、`tun`、分流模式、端口配置等。

4. **🖥️ 现代化 Web 可视化管理面板**
   - 密码认证保护（默认账号密码：`admin` / `admin1234`，支持在配置文件或安装时自定义）。
   - 默认监听 `8000` 端口（支持安装时自由指定）。
   - 实时预览 Sing-box 提取节点、分组清理结果、转换后的 Clash YAML 片段。
   - 随时在线修改 Clash 原始订阅链接、拉取代理、节点 IP、目标分组关键词、管理员账号密码等。

5. **🎲 动态 UUID 防盗刷与扫码导入**
   - 首次安装自动生成高强度随机 UUID 作为专属订阅 Token。
   - Web 面板提供「更换随机 UUID」按钮，一键撤销旧链接并生成新订阅地址，无需重启服务即可即刻生效。
   - 提供纯前端/矢量 SVG **二维码扫码** 功能，支持手机客户端（Clash Verge Mobile、Clash for Android、Shadowrocket、Flclash 等）扫码一键导入。
   - 提供「复制订阅链接」与「一键导入 Clash」快捷操作。

6. **🛡️ Systemd 守护进程运行**
   - 系统级开机自启、故障自动重启、无缝日志轮转（支持 `journalctl` 与快捷命令查看）。
   - 项目规范安装于 `/usr/local/bin/clash-singbox-sub-manager` 目录。

---

## 🚀 快速安装与部署

### 1. 一键全自动安装 (推荐)

在项目目录下直接运行一键安装脚本（默认端口 8000，默认账号 admin / admin1234）：

```bash
sudo ./install.sh
```

### 2. 自定义参数安装

安装脚本支持丰富的命令行参数定制：

```bash
sudo ./install.sh \
  --port 8000 \
  --username admin \
  --password your_password \
  --node-ip 8.137.160.254 \
  --proxy socks5h://127.0.0.1:2080 \
  --sub-url "https://your-upstream-clash-sub.com/api/v1/client/subscribe?token=xxx"
```

**参数说明：**
- `-p, --port <PORT>`: Web 服务与订阅监听端口（默认 `8000`）
- `-u, --username <USER>`: Web 管理面板登录用户名（默认 `admin`）
- `-P, --password <PASS>`: Web 管理面板登录密码（默认 `admin1234`）
- `-i, --node-ip <IP>`: 注入节点的 IP 地址（留空则自动探测公网 IPv4）
- `-s, --sub-url <URL>`: 原始 Clash 订阅链接（留空则使用内置精简规则模板）
- `--proxy <PROXY>`: 上游拉取代理地址（默认 `socks5h://127.0.0.1:2080`，不可用时自动回落直连）
- `--singbox-config <PATH>`: Sing-box 配置文件路径（默认 `/etc/sing-box/config.json`）
- `-c, --clean`: 纯净重新安装（清除旧配置文件与历史 UUID）

---

## 🛠️ 服务管理命令

安装完成后，系统全局已注册快捷命令：

```bash
# 查看服务运行状态、公网订阅地址与终端二维码
clash-sub-service status

# 实时查看服务运行日志
clash-sub-service logs

# 重启后台守护服务
clash-sub-service restart

# 重新生成随机订阅 UUID (旧订阅立即失效)
clash-sub-service regen-uuid

# 单次测试 Sing-box 提取与 Clash 配置转换
clash-sub-manager test

# 导出转换后的 Clash YAML 文件
clash-sub-manager export -o /tmp/clash-output.yaml
```

---

## 🌐 访问与使用指南

### 1. 登录 Web 管理面板
打开浏览器访问：`http://<服务器IP>:8000/`
- 默认用户名：`admin`
- 默认密码：`admin1234`（或安装时指定的值）

### 2. 获取并配置订阅
- 在管理面板顶部卡片可直接查看专属订阅地址：`http://<服务器IP>:8000/sub/<UUID>`
- 点击 **「复制」** 按钮复制地址，直接粘贴至 Clash / Clash Verge / Flclash / Clash Meta 等客户端。
- 或点击 **「一键导入 Clash」** 直接唤起本地客户端配置。
- 或使用手机客户端摄像头直接扫描页面右侧呈现的 **二维码**。

### 3. 更换 UUID (防止滥用)
若订阅地址泄漏，点击管理面板顶部的 **「更换随机 UUID」** 按钮，系统会即刻生成新的 UUID 并更新配置，旧订阅地址立即返回 403 禁止访问。

---

## ⚙️ 配置文件说明 (`config.json`)

配置文件位于 `/etc/clash-singbox-sub-manager/config.json` 或项目目录下：

```json
{
  "server": {
    "host": "0.0.0.0",
    "port": 8000
  },
  "auth": {
    "username": "admin",
    "password": "admin1234",
    "session_secret": "..."
  },
  "subscription": {
    "uuid": "550e8400-e29b-41d4-a716-446655440000",
    "clash_sub_url": "https://upstream.example.com/sub",
    "upstream_proxy": "socks5h://127.0.0.1:2080",
    "sub_cache_ttl": 300,
    "profile_name": "Singbox-Clash-Sub"
  },
  "singbox": {
    "config_path": "/etc/sing-box/config.json",
    "node_ip": "8.137.160.254",
    "custom_node_name": ""
  },
  "filter": {
    "target_group_pattern": "节点选择",
    "exclude_group_patterns": [
      "自动选择",
      "节点"
    ],
    "fallback_target_group": "节点选择"
  }
}
```

---

## 🗑️ 卸载与清理

如需完全移除本项目与 systemd 守护进程，可直接运行：

```bash
sudo ./uninstall.sh
```
