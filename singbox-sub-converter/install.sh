#!/bin/bash
#
# install.sh
# singbox-sub-converter 一键安装与更新脚本
# 自动从 JayYang1991/vps-utils 最新 Release 下载打包好的压缩包安装与升级。

# 开启错误即停止模式
set -e

# 错误处理函数
error_handler() {
  echo "------------------------------------------------"
  echo "错误: 执行过程中出现问题，请检查上方日志。"
  echo "步骤: $1 失败"
  echo "------------------------------------------------"
  exit 1
}

# 检查权限
if [ "$(id -u)" -ne 0 ]; then
  echo "错误: 请以 root 权限运行此脚本: sudo bash install.sh <SERVER_IP> [端口号]"
  exit 1
fi

GITHUB_REPO="JayYang1991/vps-utils"
PACKAGE_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/singbox-sub-converter.tar.gz"
TARGET_DIR="/usr/local/singbox-sub-converter"
VENV_DIR="${TARGET_DIR}/venv"
SERVICE_NAME="singbox-sub-converter"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"

ACTION="install"
SERVER_IP=""
PORT=""
IS_EXPLICIT_PORT=false

# 如果服务文件已存在，先读取现有的 SERVER_HOST、PORT 与 SUB_TOKEN
EXISTING_IP=""
EXISTING_PORT=""
EXISTING_TOKEN=""
if [ -f "$SERVICE_FILE" ]; then
    EXISTING_IP=$(grep "SERVER_HOST=" "$SERVICE_FILE" | sed -n 's/.*SERVER_HOST=\([^"]*\).*/\1/p')
    EXISTING_PORT=$(grep "PORT=" "$SERVICE_FILE" | sed -n 's/.*PORT=\([^"]*\).*/\1/p')
    EXISTING_TOKEN=$(grep "SUB_TOKEN=" "$SERVICE_FILE" | sed -n 's/.*SUB_TOKEN=\([^"]*\).*/\1/p')
fi

# 参数遍历解析
while [ $# -gt 0 ]; do
  case "$1" in
    update|-u|--update)
      ACTION="update"
      shift 1
      ;;
    -i|--ip|--server-ip)
      SERVER_IP="$2"
      shift 2
      ;;
    -p|--port)
      PORT="$2"
      IS_EXPLICIT_PORT=true
      shift 2
      ;;
    *)
      if [ -z "$SERVER_IP" ]; then
        SERVER_IP="$1"
      elif [ -z "$PORT" ]; then
        PORT="$1"
        IS_EXPLICIT_PORT=true
      fi
      shift 1
      ;;
  esac
done

# 如果更新操作未显式传入新 IP，继承已保存的 SERVER_HOST
if [ -z "$SERVER_IP" ] && [ -n "$EXISTING_IP" ]; then
    SERVER_IP="$EXISTING_IP"
fi

# 必选参数校验: SERVER_IP 必须指定
if [ -z "$SERVER_IP" ]; then
    echo "================================================"
    echo "❌ 错误: 缺少必选参数 [SERVER_IP] (非优选 IP 节点所使用的服务器 IP 地址)。"
    echo "================================================"
    echo ""
    echo "使用说明:"
    echo "  1. 全新安装: sudo ./install.sh <SERVER_IP> [端口号]"
    echo "     示例:     sudo ./install.sh 154.12.34.56 8000"
    echo ""
    echo "  2. 在线更新: sudo ./install.sh update <SERVER_IP> [端口号]"
    echo "     示例:     sudo ./install.sh update 154.12.34.56"
    echo "================================================"
    exit 1
fi

# 确认端口号 (显式指定 > 现有端口 > 默认 8000)
if [ "$IS_EXPLICIT_PORT" = false ] && [ -n "$EXISTING_PORT" ]; then
    PORT="$EXISTING_PORT"
elif [ -z "$PORT" ]; then
    PORT="8000"
fi

# 确认 SUB_TOKEN
if [ -n "$EXISTING_TOKEN" ]; then
    SUB_TOKEN="$EXISTING_TOKEN"
else
    SUB_TOKEN=$(cat /proc/sys/kernel/random/uuid | tr -d '-')
fi

download_and_extract_package() {
  echo "正在从 GitHub Release 下载最新的 singbox-sub-converter.tar.gz ..."
  echo "下载地址: ${PACKAGE_URL}"

  TMP_ARCHIVE=$(mktemp /tmp/singbox-sub-converter.XXXXXX.tar.gz)
  if ! curl -4 -L -q --retry 5 --retry-delay 5 -o "${TMP_ARCHIVE}" "${PACKAGE_URL}"; then
    rm -f "${TMP_ARCHIVE}"
    error_handler "下载最新 singbox-sub-converter.tar.gz 压缩包"
  fi

  echo "正在解压安装包至 ${TARGET_DIR} ..."
  mkdir -p "${TARGET_DIR}/data"
  tar -xzf "${TMP_ARCHIVE}" -C "${TARGET_DIR}"
  rm -f "${TMP_ARCHIVE}"
}

if [ "$ACTION" = "update" ]; then
    echo "================================================"
    echo "正在更新 sing-box 订阅转换服务..."
    echo "服务器 IP : $SERVER_IP (非优选节点地址)"
    echo "服务端口  : $PORT"
    echo "================================================"

    download_and_extract_package

    echo "1. 正在升级 Python 依赖..."
    if [ ! -d "$VENV_DIR" ]; then
        python3 -m venv "$VENV_DIR" || error_handler "创建虚拟环境"
    fi
    set +e
    . "$VENV_DIR/bin/activate" || error_handler "激活虚拟环境"
    set -e
    "$VENV_DIR/bin/pip" install --upgrade pip || error_handler "更新 pip"
    "$VENV_DIR/bin/pip" install --upgrade -r "$TARGET_DIR/requirements.txt" || error_handler "升级依赖包"

    echo "2. 正在更新 systemd 服务配置..."
    cat <<EOF > $SERVICE_FILE
[Unit]
Description=sing-box Adaptive Subscription Converter Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$TARGET_DIR
ExecStart=$VENV_DIR/bin/python3 -m app.main
Restart=always
TimeoutStartSec=15s
TimeoutStopSec=3s
KillMode=mixed
Environment="PYTHONPATH=$TARGET_DIR"
Environment="SB_CONFIG_PATH=/etc/sing-box/config.json"
Environment="PORT=$PORT"
Environment="SUB_TOKEN=$SUB_TOKEN"
Environment="SERVER_HOST=$SERVER_IP"

[Install]
WantedBy=multi-user.target
EOF

    echo "3. 正在快速平滑重启服务..."
    systemctl daemon-reload || error_handler "重载 systemd 配置"
    systemctl stop $SERVICE_NAME || true
    pkill -9 -f "app.main" || true
    sleep 0.5
    systemctl start $SERVICE_NAME || error_handler "启动服务"

    sleep 2
    if ! systemctl is-active --quiet $SERVICE_NAME; then
        error_handler "更新后服务启动失败"
    fi

    echo "------------------------------------------------"
    echo "✅ sing-box 订阅转换服务更新完成！"
    echo "服务名称  : $SERVICE_NAME"
    echo "服务器 IP : $SERVER_IP (非优选节点地址)"
    echo "服务端口  : $PORT"
    echo "安全 Token: $SUB_TOKEN"
    echo "访问地址  : http://$(hostname -I | awk '{print $1}'):$PORT"
    echo "自适应订阅: http://$(hostname -I | awk '{print $1}'):$PORT/sub?token=$SUB_TOKEN"
    echo "------------------------------------------------"
    exit 0
fi

# 全新安装流程
echo "================================================"
echo "正在安装 sing-box 订阅转换服务..."
echo "服务器 IP : $SERVER_IP (非优选节点地址)"
echo "服务端口  : $PORT"
echo "================================================"

echo "1. 正在更新系统并安装基础依赖 (python3-venv python3-pip curl tar)..."
apt update || error_handler "更新软件包列表"
apt install -y python3-venv python3-pip curl tar || error_handler "安装依赖包"

download_and_extract_package

echo "2. 初始化数据目录与权限..."
mkdir -p "$TARGET_DIR/data"
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR" || error_handler "创建虚拟环境"
fi
chown -R root:root "$TARGET_DIR"
chmod -R 755 "$TARGET_DIR"

set +e
. "$VENV_DIR/bin/activate" || error_handler "激活虚拟环境"
set -e

echo "3. 正在安装项目依赖..."
"$VENV_DIR/bin/pip" install --upgrade pip || error_handler "更新 pip"
"$VENV_DIR/bin/pip" install -r "$TARGET_DIR/requirements.txt" || error_handler "安装 requirements.txt 依赖"

echo "4. 正在配置 systemd 服务..."
cat <<EOF > $SERVICE_FILE
[Unit]
Description=sing-box Adaptive Subscription Converter Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$TARGET_DIR
ExecStart=$VENV_DIR/bin/python3 -m app.main
Restart=always
TimeoutStartSec=15s
TimeoutStopSec=3s
KillMode=mixed
Environment="PYTHONPATH=$TARGET_DIR"
Environment="SB_CONFIG_PATH=/etc/sing-box/config.json"
Environment="PORT=$PORT"
Environment="SUB_TOKEN=$SUB_TOKEN"
Environment="SERVER_HOST=$SERVER_IP"

[Install]
WantedBy=multi-user.target
EOF

echo "5. 正在启动服务..."
systemctl daemon-reload || error_handler "重载 systemd 配置"
systemctl enable $SERVICE_NAME || error_handler "设置服务自启动"
systemctl restart $SERVICE_NAME || error_handler "启动服务"

sleep 2
if ! systemctl is-active --quiet $SERVICE_NAME; then
    error_handler "服务启动失败 (服务已停止)"
fi

echo "------------------------------------------------"
echo "✅ sing-box 订阅转换服务安装成功！"
echo "服务名称  : $SERVICE_NAME"
echo "服务器 IP : $SERVER_IP (非优选节点地址)"
echo "服务端口  : $PORT"
echo "默认用户名: jayyang"
echo "默认密码  : admin1234"
echo "访问地址  : http://$(hostname -I | awk '{print $1}'):$PORT"
echo "自适应订阅: http://$(hostname -I | awk '{print $1}'):$PORT/sub?token=$SUB_TOKEN"
echo "首次登录 Web 界面后请及时修改密码。"
echo "------------------------------------------------"
