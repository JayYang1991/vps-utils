# 🌐 VPNGATE 纯净住宅 IP 优选与全自动保活系统 (VPNGATE Residential Selector)

自动化从 **VPNGATE (筑波大学学术网络项目)** 全量并发采集全球志愿者节点，通过 **Scamalytics 威胁风控分纯净筛选 (<20分)**，执行多轮高并发**应用层协议握手测速 (OpenVPN / SOCKS5 / HTTP)**，精选最优纯净家庭住宅代理，提供 7 国 Systemd 后台自动愈合保活守护与本地代理网桥服务。

---

## 🌟 核心特性

1. **🌐 全量多源并发采集与历史沉淀**：
   - 自动并发采集 VPNGATE 官方主站、每日动态镜像（`sites.aspx`）与社区同步源，彻底突破单接口 ~100 节点限制，瞬间聚合 **180+ 全球节点**。
   - 内置历史沉淀库（`all_discovered_nodes.json`），随着守护进程周期性运行持续捕获轮换节点，节点库自动滚雪球式累积扩展。

2. **🛡️ Scamalytics 威胁分纯净筛选 (`Fraud Score < 20`)**：
   - 自动批量并发查询 `scamalytics.com` 威胁风控分（0~100）。
   - 严格剔除机房、云服务商及被标记的公开代理网段（70+分），仅保留 **0~19 分的极度纯净家庭宽带住宅 IP**（如 NTT、KDDI、SoftBank 等 0~5 分纯净宽带）。

3. **⚡ 真实应用层协议握手测速 (Protocol Handshake Benchmark)**：
   - 摒弃单纯的 TCP 端口扫描，向节点发送真实 **OpenVPN 握手帧 (`P_CONTROL_HARD_RESET_CLIENT_V2`)** 与 SOCKS5 握手报文，验证服务端真实响应报文（Opcode 8 / Reset Server V2）。
   - 毫秒级计算真实握手时延（RTT）、抖动（Jitter）及丢包率，剔除“端口开放但协议不可用”的假活节点。

4. **🌉 本地 SOCKS5 / HTTP 住宅代理中继网桥 (`vpngate-bridge`)**：
   - 一键启动本地双协议代理网关：`socks5://127.0.0.1:10808` 与 `http://127.0.0.1:10809`。
   - 自动将流量加密中继至最优住宅 OpenVPN 节点，供 Cloudflare Worker VLESS、浏览器、curl 等直接连通出海。

5. **🔄 7 国 Systemd 后台 5 分钟自愈保活守护**：
   - 独立维护 **美国 (US)**、**日本 (JP)**、**香港 (HK)**、**新加坡 (SG)**、**韩国 (KR)**、**德国 (DE)**、**澳大利亚 (AU)** 7 国 TOP 20 节点池。
   - **全量可用跳过刷新**：池内节点健康时跳过网络拉取，保持长连接稳定。
   - **失效 1 对 1 热替换**：若某个 IP 失活，自动从最新候选池挑选最优且不重复的 1 个纯净节点替补。

6. **📁 全格式全客户端配置文件自动导出**：
   - `results/proxies.txt`：标准代理 URL 列表（`socks5://vpn:vpn@ip:port`）。
   - `results/upstream_gateway.txt`：TOP 1 最优节点（直接适配 Cloudflare VLESS 上游中继）。
   - `results/singbox_outbounds.json`：sing-box 客户端原生出站配置。
   - `results/ovpn/*.ovpn`：各节点的独立 OpenVPN 配置文件（内嵌证书）。

## 🎯 节点优选与桥接标准流程 (3 步核心逻辑)

1. 🌐 **第一步：拉取全量节点列表**
   - 多源并发抓取 VPNGATE 官方接口、筑波大学每日镜像（`sites.aspx`）与社区节点源，并结合历史沉淀数据库（`all_discovered_nodes.json`）持续扩充全量节点库。
2. 🛡️ **第二步：按国家选取各自 TOP 5 住宅节点**
   - **严格风控筛选**：只选择 **Scamalytics 威胁分小于 20** 的节点（0~19 判定为纯净住宅 IP，彻底剔除机房与高危代理）。
   - **低威胁分高加权**：威胁分越低加权奖励分越高（0 分节点获得 +500 分最高奖励），结合 OpenVPN 握手延迟、带宽与丢包率综合排序。
   - **分国独立精选**：为每个国家精选 TOP 5 节点，并自动导出各自分国代理文件（如 `proxies_JP.txt`、`proxies_US.txt`）与全局池。
3. 🌉 **第三步：本地网桥智能中继 (`vpngate-bridge`)**
   - **默认模式**：自动选择当前综合评分最高（威胁分最低 + 握手延迟最低）的住宅代理节点。
   - **手动指定**：支持指定具体 IP:端口（如 `vpngate-bridge 219.100.37.13:443`）、指定国家（如 `vpngate-bridge -c JP`）、指定排名（`--rank 2`）或自定义 OVPN 文件（`--ovpn`）。

---

## 📦 一键安装 (Install)

在 VPS 终端执行一键安装脚本（自动跨发行版安装 `openvpn` 依赖并配置全局命令）：

```bash
cd ~/vps-utils/vpngate-residential-selector
git pull
sudo ./install.sh
```

> **说明**：
> - **以 root 身份运行**：自动安装到系统全局 `/usr/local/bin`，并注册系统级 `systemd` 服务。
> - **以普通用户运行**：自动安装到 `~/.local/bin`，无需 `sudo`。

---

## 💻 服务安装后的全局命令用法 (Command Usage)

安装完成后，系统已注册以下 **5 个全局快捷命令**，可在任意目录下直接调用：

```
• vpngate-nodes     -> 🚀 查看当前已选出的全部 7 国住宅代理节点列表 (支持 -c JP)
• vpngate-service   -> ⚙️ 管理后台 Systemd 自动保活服务 (支持 list/status/logs/启停)
• vpngate-selector  -> 🔍 手动单次运行全量测速与纯净住宅节点提取 (支持 -l 查看)
• vpngate-bridge    -> 🌉 启动本地 SOCKS5 (10808) / HTTP (10809) 住宅中继网桥
• vpngate-daemon    -> 🛡️ 前台直接运行 7 国保活守护进程
```

---

### 1️⃣ `vpngate-nodes` & `vpngate-service list` — 查看当前已选出的所有节点

直接打印当前 7 国已通过 Scamalytics 纯净风控与协议验证的可用节点列表，包含国旗、IP:端口、威胁分、实测延迟与代理全路径：

```bash
# 1. 查看当前全部 7 国已选出的节点
vpngate-nodes

# 2. 仅查看指定国家的节点 (如日本 JP、美国 US、韩国 KR)
vpngate-nodes -c JP
vpngate-nodes -c US,KR

# 3. 通过 vpngate-service 或 vpngate-selector 同样可快捷查看
vpngate-service list
vpngate-service list -c JP
vpngate-selector -l
```

---

### 2️⃣ `vpngate-service` — 管理后台 Systemd 保活服务

用于管理守护进程、监控 5 分钟健康检查与节点热替换日志：

```bash
# 查看全部已选出节点列表
vpngate-service list

# 清理历史节点沉淀库、7国保活状态池与 Scamalytics 威胁分缓存并重置
vpngate-service clean

# 查看服务运行状态及当前 7 国保活节点统计看板
vpngate-service status

# 实时追踪守护进程日志 (5 分钟自动巡检与 1 对 1 热替换过程)
vpngate-service logs

# 重启守护服务
vpngate-service restart

# 停止守护服务
vpngate-service stop

# 启动守护服务
vpngate-service start

# 卸载守护服务
vpngate-service uninstall
```

---

### 3️⃣ `vpngate-selector` — 手动执行全量测速与提取

用于手动触发全网节点抓取、Scamalytics 威胁分过滤与深度协议测速：

```bash
# 1. 默认精选全球 TOP 20 纯净住宅节点 (威胁分 < 20)
vpngate-selector

# 2. 清理全部历史沉淀库与 Scamalytics 威胁分缓存
vpngate-selector --clean

# 3. 指定提取数量 (如精选最优 TOP 10)
vpngate-selector -n 10

# 4. 指定筛选特定国家 (如仅筛选日本、韩国、美国)
vpngate-selector -c JP,KR,US -n 10

# 4. 自定义 Scamalytics 威胁分阈值 (如严格筛选低于 5 分的极致纯净节点)
vpngate-selector --max-fraud-score 5 -n 10

# 5. 指定输出格式 (socks5 / http / direct / noauth)
vpngate-selector -p socks5 -o /tmp/my_results

# 6. 同时导出所有选出节点的独立 .ovpn 配置文件
vpngate-selector --save-ovpn
```

#### 常用参数速查表 (`vpngate-selector`)：

| 参数 | 简写 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- |
| `--top` | `-n` | `20` | 精选出的最优节点数量 |
| `--country` | `-c` | *(空)* | 按国家代码过滤，如 `JP,KR,US` (留空代表全球) |
| `--max-fraud-score` | - | `20` | Scamalytics 威胁分上限 (低于该值判定为纯净住宅) |
| `--skip-fraud-check` | - | `False`| 跳过 Scamalytics 在线查询 (直接测试全部节点) |
| `--output` | `-o` | `results` | 结果与配置文件输出目录 |
| `--proxy-type` | `-p` | `socks5` | 输出代理格式: `socks5`, `http`, `direct`, `noauth`, `all` |
| `--threads` | `-t` | `30` | 并发协议测速线程数 |
| `--timeout` | - | `2.5` | 单次协议握手超时时间 (秒) |
| `--save-ovpn` | - | `False`| 是否将各节点的 OpenVPN `.ovpn` 配置文件导出至 `ovpn/` |

---

---

### 3️⃣ `vpngate-bridge` — 启动本地 SOCKS5 / HTTP 代理中继网桥

默认选择评分最优的纯净住宅节点，并在本地开启 SOCKS5 / HTTP 双协议代理网关；同时**全面支持手动指定节点、指定国家、指定排名或自定义 OVPN**：

```bash
# 1. 默认模式：自动选用全局综合评分最优 (威胁分最低+握手延迟最低) 的住宅节点
vpngate-bridge

# 2. 手动指定国家最优节点 (如日本 JP、美国 US、韩国 KR)
vpngate-bridge -c JP
vpngate-bridge US

# 3. 手动指定具体的 IP 或 IP:端口 节点
vpngate-bridge 219.100.37.13:443
vpngate-bridge --node 219.100.37.13:443

# 4. 指定该国家或全局排名第几的最优节点 (如日本第 2 名)
vpngate-bridge -c JP --rank 2

# 5. 直接指定本地自定义 OpenVPN 配置文件 (.ovpn)
vpngate-bridge --ovpn /path/to/my_server.ovpn

# 6. 自定义本地监听端口
vpngate-bridge --socks-port 10808 --http-port 10809
```

#### 启动后测试本地网桥连通性：

```bash
# 测试本地 HTTP 代理通道
curl -x http://127.0.0.1:10809 https://api.ip.sb/ip

# 测试本地 SOCKS5 代理通道
curl -x socks5h://127.0.0.1:10808 https://api.ip.sb/ip
```

---

### 4️⃣ `vpngate-daemon` — 前台运行 7 国保活守护进程

可在终端前台调试或测试 7 国轮询保活逻辑：

```bash
# 单次运行 7 国全量巡检与池构建后退出
vpngate-daemon --run-once

# 自定义巡检周期 (如每 600 秒巡检一次，每国维持 TOP 10)
vpngate-daemon --interval 600 --top-per-country 10
```

---

## 📁 生成文件位置与说明

所有生成的文件保存在安装目录的 `results/` 下（默认 `/usr/local/bin/vpngate-residential-selector/results/` 或 `~/.local/bin/vpngate-residential-selector/results/`）：

| 文件路径 | 说明 |
| :--- | :--- |
| `results/proxies.txt` | 全量通过协议验证与纯净筛选的代理全路径列表 |
| `results/proxies_US.txt` 等 | 各国独立代理列表 (`_JP.txt`, `_KR.txt`, `_HK.txt`, `_SG.txt`, `_DE.txt`, `_AU.txt`) |
| `results/upstream_gateway.txt` | 当前最优 TOP 1 节点，用于 Cloudflare VLESS 上游中继 |
| `results/residential_pool.json`| 7 国保活节点状态数据库 (含延迟、威胁分、端口等) |
| `results/singbox_outbounds.json` | 适配 sing-box 客户端的原生 Outbound 配置 |
| `results/ovpn/*.ovpn` | 选出节点的独立 OpenVPN 配置文件 |
| `results/summary.md` | 7 国保活看板与实时评分明细 |

---

## 🔗 与 Cloudflare VLESS 代理联动

本项目生成的纯净住宅代理全路径，可直接填入 `cloudflare-vless-proxy` 项目的管理后台（`/admin`）的 **上游中继网关 (`DEFAULT_UPSTREAM_GATEWAY`)** 或本地网桥 `socks5://127.0.0.1:10808`。

Cloudflare Worker 会自动通过选出的纯净家庭住宅宽带中继落地，实现**真实住宅宽带出口 IP**，彻底解除数据中心机房 IP 限制！

---

## 🧪 单元测试

项目内置完整的单元测试集（覆盖多源聚合、Scamalytics威胁分筛选、协议握手及保活逻辑）：

```bash
python3 -m unittest test_selector.py
```
