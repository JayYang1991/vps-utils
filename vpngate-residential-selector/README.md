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

---

## 🚀 快速上手

### 1. 直接运行 (默认选出 TOP 20 住宅代理)

```bash
cd vpngate-residential-selector
python3 main.py
```

### 2. 命令行参数详解

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

### 3. 常用示例

#### 示例 A：仅筛选日本 (JP) 和韩国 (KR) 的高带宽住宅节点
```bash
python3 main.py -c JP,KR --min-speed 50 -n 10
```

#### 示例 B：导出 OpenVPN 配置文件并输出 HTTP 代理格式
```bash
python3 main.py -n 20 --save-ovpn -p http -o my_proxies
```

#### 示例 C：生成 Cloudflare Worker 上游直连格式 (`ip:port`)
```bash
python3 main.py -p direct -f ../cloudflare-vless-proxy/residential_upstream.txt
```

---

## 🔗 与 Cloudflare VLESS 代理联动

本项目生成的住宅 SOCKS5 / HTTP 代理全路径，可直接复制填入 `cloudflare-vless-proxy` 项目的管理后台（`/admin`）中的 **上游中继网关 (`DEFAULT_UPSTREAM_GATEWAY`)**。

这样 Cloudflare Worker 会将所有客户端流量通过选出的日本/韩国等住宅宽带中继落地，实现**真实住宅家庭宽带出口 IP**，彻底规避数据中心机房 IP 限制！

---

## ⏰ Linux 定时任务自动更新 (Crontab)

设置每天凌晨或每 6 小时自动运行测速更新住宅代理列表：

```bash
# 编辑 crontab
crontab -e

# 每 6 小时自动执行一次并更新结果
0 */6 * * * cd /home/jason/code/vps-utils/vpngate-residential-selector && python3 main.py -n 20 >> /tmp/vpngate_cron.log 2>&1
```

---

## 🧪 单元测试

项目内置完整的单元测试集：

```bash
python3 -m unittest test_selector.py
```
