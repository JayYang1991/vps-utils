# subconverter 自动化安装指南

本目录提供 `subconverter` 的一键自动化安装与 Systemd 服务部署脚本。

---

## 快速安装

在 Linux 服务器上以 `root` 权限执行以下命令，脚本将自动从 `JayYang1991/vps-utils` 仓库的 Release 中下载最新版安装包，完成安装并配置后台 Systemd 服务：

```bash
# 默认端口安装 (25500)
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/subconverter/install.sh)

# 指定自定义端口安装 (例如: 15051)
sudo bash <(curl -fsSL https://raw.githubusercontent.com/JayYang1991/vps-utils/main/subconverter/install.sh) -p 15051
```

或在克隆本仓库后于本地直接运行：

```bash
cd subconverter

# 默认端口 (25500)
sudo bash install.sh

# 指定自定义端口 (如 15051)
sudo bash install.sh -p 15051
```

---

## 参数与环境变量说明

| 参数 / 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `-p, --port` | `25500` | 指定 subconverter 的监听端口 |
| `SUBCONVERTER_PORT` | `25500` | 环境变量形式指定监听端口（如 `SUBCONVERTER_PORT=15051 bash install.sh`） |

---

## 安装说明

脚本执行后将自动完成以下操作：

1. **自动检测系统架构**（支持 `linux64` / `aarch64` / `armv7` / `linux32`）。
2. **解压部署**：将程序及内置规则集解压安装至 `/usr/local/subconverter/`。
3. **软链接创建**：绑定软链接 `/usr/local/bin/subconverter` 到 `/usr/local/subconverter/subconverter`。
4. **初始配置与端口配置**：若不存在 `pref.ini`，自动从 `pref.example.ini` 生成默认配置文件，并将 `pref.ini` 中的监听端口配置为指定端口。
5. **Systemd 服务注册**：配置 `/etc/systemd/system/subconverter.service` 并设置开机自启。

---

## 服务管理命令

| 操作 | 命令 |
| --- | --- |
| **查看服务状态** | `systemctl status subconverter` |
| **重启服务** | `systemctl restart subconverter` |
| **停止服务** | `systemctl stop subconverter` |
| **启动服务** | `systemctl start subconverter` |
| **查看运行日志** | `journalctl -u subconverter -n 50 --no-pager` |

---

## 配置文件路径

- **配置文件路径**：`/usr/local/subconverter/pref.ini`
