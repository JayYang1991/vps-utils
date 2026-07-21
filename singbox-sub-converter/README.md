# singbox-sub-converter

基于 Python / FastAPI 的 sing-box 服务端自适应订阅转换服务。

## 核心功能与转换规则

1. **优选 IP 节点转换**:
   - 自动读取 `sing-box` 服务端配置中 `tag` 为 `vless-grpc` 的 inbound 参数（`host` 与 `uuid`）。
   - 使用请求接口 `https://sub.19910417.xyz/sub?host={host}&uuid={uuid}` 并带有 `User-Agent: v2rayN/edgetunnel (https://github.com/cmliu/edgetunnel)` 动态拉取 Cloudflare 优选 IP 节点。
   - 解析优选 IP 节点，并将节点中的 `host`、`uuid`、`path` 与 `sni` 替换为服务端配置中的实际参数。

2. **原始协议节点追加与指定服务器 IP**:
   - 自动解析服务端配置中的其他协议 inbound（如 `vless-reality`、`hysteria2` 等）。
   - 针对 Reality 节点自动根据 Private Key 计算衍生 Public Key。
   - 所有非优选节点自动在连接目标（`server`）中使用通过 `install.sh` 传入的必选 **`SERVER_IP`** 参数，并自动加上 `VPS自用-` 名称前缀（例如 `VPS自用-vless-reality`）。

3. **自适应客户端订阅**:
   - `/sub`: 根据客户端 HTTP `User-Agent` 标头（或 `?target=` / `?flag=` 参数）自动识别客户端并输出对应格式：
     - **Clash / Mihomo**: 输出 Clash YAML 格式
     - **sing-box**: 输出 sing-box JSON 客户端配置
     - **V2Ray / Base64 / Shadowrocket**: 输出标准 Base64 编码 URI 列表
   - 独立订阅路径：
     - `/clash`: 强制输出 Clash 格式
     - `/singbox`: 强制输出 sing-box 格式
     - `/v2ray` / `/base64`: 强制输出 Base64 格式

4. **远程规则配置与在线 API 转换**:
   - 支持读取 `SUBCONFIG.json` 规则列表，前端下拉选单提供多组预设，默认启用 `ACL4SSR_Online_Full_CF.ini`。
   - 通过 `https://subapi.19910417.xyz/` 进行高级订阅转换，本地离线引擎自动兜底保障高可用。

5. **订阅 Token / UUID 动态安全重置**:
   - 前端管理界面提供 **「🔑 更换订阅 Token / UUID」** 功能，一键生成新 Token 并更新服务与订阅链接，使旧链接立即失效。

## 快速安装与更新 (Systemd)

在 VPS 上运行以下命令进行自动安装或平滑在线更新（**`SERVER_IP` 为必选参数**）：

```bash
cd singbox-sub-converter
chmod +x install.sh

# 1. 全新安装 (必填 SERVER_IP，默认端口 8000)
sudo ./install.sh 154.12.34.56

# 2. 指定自定义服务端口安装 (例如 SERVER_IP 154.12.34.56 端口 9000)
sudo ./install.sh 154.12.34.56 9000

# 3. 在线一键更新服务 (保留已有 SERVER_IP 与端口)
sudo ./install.sh update

# 4. 在线更新时更新 SERVER_IP 或修改端口
sudo ./install.sh update 154.12.34.56 9500
```

## 日志查看与问题排查

系统已对 `subapi` 在线转换以及配置文件解析添加了完整的结构化日志记录。您可以采用以下 3 种方式实时查看日志：

### 方式 1: 使用 systemd journal 实时日志命令（推荐）
```bash
sudo journalctl -u singbox-sub-converter -f
```

### 方式 2: 查看应用日志文件 (`data/app.log`)
日志文件存储在项目根目录的 `data/app.log`，支持按 5MB 轮转分割：
```bash
# 查看最新 100 行日志
tail -n 100 -f data/app.log
```

### 方式 3: Web API 接口查询
登录 Web 控制台后，可以直接访问 `/api/logs` 查看最新日志：
```bash
# 在服务端通过 curl 查询
curl -s http://127.0.0.1:8000/api/logs
```

## 服务管理命令

```bash
# 查看服务状态
sudo systemctl status singbox-sub-converter

# 重启服务
sudo systemctl restart singbox-sub-converter

# 查看服务日志
sudo journalctl -u singbox-sub-converter -f
```

## 默认凭据

- 默认端口: `8000` (或安装时指定的自定义端口)
- 默认用户名: `jayyang`
- 默认密码: `admin1234` (首次登录后强制要求修改)
