#!/usr/bin/env bash
# preferred-ip-manager Python 依赖自动检查与安装脚本
# 兼容 sh / dash / bash / zsh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"

echo "🔍 正在检测 Python 运行环境..."

# 校验并解决 Ubuntu PEP 668 环境限制的函数
resolve_python_env() {
    base_python="$1"
    
    # 检查是否为被系统保护不可直接 pip 的环境
    if $base_python -m pip install --help 2>&1 | grep -q "break-system-packages"; then
        echo "⚠️ 检测到 Ubuntu/Debian 系统保护的 Python 环境 (PEP 668: externally-managed-environment)。" 1>&2
        if [ ! -d "$VENV_DIR" ]; then
            echo "📦 正在自动创建 Python 虚拟环境 ($VENV_DIR)..." 1>&2
            if ! $base_python -m venv "$VENV_DIR" 2>/dev/null; then
                echo "❌ 错误: 创建虚拟环境失败。若缺少 venv 模块，请执行: sudo apt update && sudo apt install -y python3-venv" 1>&2
                exit 1
            fi
            echo "✅ 虚拟环境创建成功: $VENV_DIR" 1>&2
        fi
        echo "$VENV_DIR/bin/python"
    else
        echo "$base_python"
    fi
}

RAW_PYTHON=""
PYTHON_EXEC=""

# 1. 按照优先级寻找可用 Python
if [ -n "$PYTHON_BIN" ]; then
    RAW_PYTHON="$PYTHON_BIN"
elif [ -n "$VIRTUAL_ENV" ]; then
    PYTHON_EXEC="$VIRTUAL_ENV/bin/python"
elif [ -f "$VENV_DIR/bin/python" ]; then
    PYTHON_EXEC="$VENV_DIR/bin/python"
elif [ -f "$HOME/miniconda3/bin/python3" ]; then
    PYTHON_EXEC="$HOME/miniconda3/bin/python3"
elif [ -f "/home/jason/miniconda3/bin/python3" ]; then
    PYTHON_EXEC="/home/jason/miniconda3/bin/python3"
elif command -v python3 >/dev/null 2>&1; then
    RAW_PYTHON="$(command -v python3)"
else
    echo "❌ 错误: 未找到 python3 解释器，请先安装 Python 3。"
    exit 1
fi

# 如果选中的是系统 Python，进行 PEP 668 校验并切换为 venv 环境
if [ -z "$PYTHON_EXEC" ] && [ -n "$RAW_PYTHON" ]; then
    PYTHON_EXEC="$(resolve_python_env "$RAW_PYTHON")"
fi

PY_VER="$($PYTHON_EXEC --version 2>&1)"
echo "🔍 最终选定的 Python 解释器: $PY_VER ($PYTHON_EXEC)"

# 2. 需要检查与安装的第三方依赖包 (空格分隔字符串，完美兼容 dash/sh)
DEPENDENCIES="requests telethon"
missing_deps=""

echo "⚙️ 正在检查 Python 依赖包..."

for dep in $DEPENDENCIES; do
    if $PYTHON_EXEC -c "import $dep" >/dev/null 2>&1; then
        echo "✅ [已存在] 依赖包 '$dep' 已安装，跳过。"
    else
        echo "⚠️ [缺失] 依赖包 '$dep' 未安装。"
        missing_deps="$missing_deps $dep"
    fi
done

# 3. 如果无缺失依赖包则退出
if [ -z "$missing_deps" ]; then
    echo "🎉 所有 Python 依赖均已就绪，无需重复安装！"
    if [ -d "$VENV_DIR" ]; then
        echo "💡 提示: 项目虚拟环境已部署，运行脚本方法:"
        echo "   方法 1: $PYTHON_EXEC process_ips.py"
        echo "   方法 2: source .venv/bin/activate && python process_ips.py"
    fi
    exit 0
fi

# 4. 安装缺失依赖包
echo "📦 正在安装缺失的依赖包:$missing_deps ..."
# shellcheck disable=SC2086
$PYTHON_EXEC -m pip install $missing_deps

echo "✅ 所有 Python 依赖安装完成！"

if [ -d "$VENV_DIR" ]; then
    echo "💡 提示: 项目虚拟环境位于 $VENV_DIR"
    echo "   运行脚本方法 1: $PYTHON_EXEC process_ips.py"
    echo "   运行脚本方法 2: source .venv/bin/activate && python process_ips.py"
fi
