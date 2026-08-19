# 🌐 VPNGATE 住宅 IP 优选与高并发测速工具 (VPNGATE Residential Selector)

自动化从 **VPNGATE (筑波大学学术网络项目)** 动态拉取全球志愿节点与住宅 IP 列表，通过多轮高并发 TCP 握手延迟与带宽质量基准测速，自动计算综合评分并精选出**最优 TOP 20 住宅代理**，全路径格式化输出至多种文件格式，无缝直连中继代理网络。

---

## 🌟 核心特性

1. **⚡ 实时动态数据获取与多镜像容灾**：
   - 自动请求 VPNGATE 官方 API (`http://www.vpngate.net/api/iphone/`)。
   - 内置智能多镜像自动故障切换机制，保障无论在何种网络环境下均能秒级拉取最新数据。

2. **🏡 智能住宅 IP / 宽带运营商识别过滤**：
   - 识别日本 (NTT, KDDI, SoftBank, OCN, So-net)、韩国 (KT, SK Telecom, LG U+)、东南亚、欧美等主流住宅宽带 ISP 签名。
   - 自动过滤内网保留地址、局域网 IP 及离线失活节点。

3. **🚀 高并发多轮网络测速算法 (Multi-Sample TCP RTT)**：
   - 支持 30+ 线程高并发探测，可在 1 秒内完成全网近百个服务器的连通性与多轮平均延迟（RTT）、抖动（Jitter）及丢包率计算。
   - 多端口自适应探测：自动提取并探测 OpenVPN/SSL/SSTP 端口（如 443, 992, 995, 1194 等）。

4. **🏆 多维度加权综合评分排序 (Composite Scoring)**：
   - 综合平衡 **实测握手延迟（低延迟权重最大）**、**官方实测带宽（Mbps）**、**稳定性/丢包惩罚** 及 **VPNGATE 历史活跃质量得分**，精准挑出体验最佳的节点。

5. **📁 全格式全路径自动导出**：
   - `results/proxies.txt`：纯代理全路径 URL 列表（支持 `socks5://vpn:vpn@ip:port`、`http://...` 或 `ip:port` 格式）。
   - `results/upstream_gateway.txt`：精选第一名最优节点，可直接作为 Cloudflare Worker VLESS 的上游中继网关。
   - `results/vpngate_top20.txt`：排版整齐的控制台报表。
   - `results/residential_nodes.json`：包含完整元数据、国旗、运营商、各协议连接串的结构化 JSON。
   - `results/summary.md`：美观的 GitHub Markdown 表格。
   - `results/ovpn/`：一键提取并保存选出节点的 `.ovpn` OpenVPN 客户端配置文件。

6. **🪶 零第三方依赖 (Zero External Dependencies)**：
   - 基于 Python 3.10+ 标准库构建，无需 `pip install` 任何第三方包，开箱即用。

## 🔄 Systemd 后台服务与 7 国智能保活守护 (Daemon Service)

针对生产运维场景，项目内置了 **7国住宅代理智能保活守护进程 (`daemon.py`)** 与 **Systemd 服务管理脚本 (`service.sh`)**：

### 🎯 核心守护逻辑
1. **7大核心国家独立池 (每国维护 TOP 20)**：
   - 包含：**美国 (US)**、**日本 (JP)**、**香港 (HK)**、**新加坡 (SG)**、**韩国 (KR)**、**德国 (DE)**、**澳大利亚 (AU)**。
2. **每隔 5 分钟 (300s) 周期性巡检**：
   - **全量可用跳过拉取**：每次检测开始先快速探活当前池中所有 IP，若全部可用，**立即跳过从 VPNGATE API 刷新**，极大节省带宽并维持长连接稳定。
   - **失效 1 对 1 热替换**：若某个国家的某个代理失活断连，自动拉取 VPNGATE 最新列表，在该国家候选节点中**挑选最优且不与已有 IP 重复的 1 个节点完成热替换**。
3. **分国独立文件输出**：
   - 自动生成 `results/proxies_US.txt`、`results/proxies_JP.txt`、`results/proxies_HK.txt`、`results/proxies_SG.txt`、`results/proxies_KR.txt`、`results/proxies_DE.txt`、`results/proxies_AU.txt` 及全量 `results/proxies.txt`。

---

### 🛠️ Systemd 服务一键管理

使用配套的 [`service.sh`](file:///home/jason/code/vps-utils/vpngate-residential-selector/service.sh) 脚本管理系统后台服务：

```bash
# 1. 一键安装并配置为开机自启系统服务
sudo ./service.sh install

# 2. 查看服务状态与当前 7 国节点统计
./service.sh status

# 3. 实时追踪查看 5 分钟巡检与替换日志
./service.sh logs

# 4. 重启 / 停止 / 卸载
sudo ./service.sh restart
sudo ./service.sh stop
sudo ./service.sh uninstall
```

---

## 🚀 快速上手 (手动运行与单次测试)

### 1. 运行 7 国守护进程 (单次测试模式)
```bash
python3 daemon.py --run-once
```

### 2. 运行常规 CLI 单次测速与优选
```bash
python3 main.py -n 20
```

### 3. 命令行参数详解 (main.py / daemon.py)

```bash
python3 main.py [选项]
```

| 参数 | 简写 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- |
| `--top` | `-n` | `20` | 精选出的最优节点数量 |
| `--output` | `-o` | `results` | 结果输出目录 |
| `--file` | `-f` | *(空)* | 单独指定纯代理列表的输出文件路径 |
| `--proxy-type` | `-p` | `socks5` | 输出代理格式: `socks5` (带认证), `http`, `direct` (ip:port), `noauth`, `all` |
| `--country` | `-c` | *(空)* | 按国家代码过滤，如 `JP,KR,US` (留空代表全球) |
| `--min-speed` | - | `0.0` | 过滤官方带宽低于该值的节点 (单位: Mbps) |
| `--threads` | `-t` | `30` | 并发测速线程数 |
| `--timeout` | - | `2.5` | 单次 TCP 连接超时时间 (秒) |
| `--samples` | - | `3` | 每个节点的采样测试次数 |
| `--sort-by` | - | `composite` | 排序规则: `composite` (综合评分), `latency` (延迟优先), `speed` (带宽优先) |
| `--save-ovpn` | - | `False` | 是否同时导出 OpenVPN `.ovpn` 配置文件 |
| `--strict-residential` | - | `False` | 启用严格住宅 ISP 签名匹配 |

---

## 🔗 与 Cloudflare VLESS 代理联动

本项目生成的住宅 SOCKS5 / HTTP 代理全路径，可直接复制填入 `cloudflare-vless-proxy` 项目的管理后台（`/admin`）中的 **上游中继网关 (`DEFAULT_UPSTREAM_GATEWAY`)**。

这样 Cloudflare Worker 会将所有客户端流量通过选出的日本/韩国等住宅宽带中继落地，实现**真实住宅家庭宽带出口 IP**，彻底规避数据中心机房 IP 限制！

---

## 🧪 单元测试

项目内置完整的单元测试集：

```bash
python3 -m unittest test_selector.py
```
