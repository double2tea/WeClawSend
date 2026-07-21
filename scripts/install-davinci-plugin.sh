#!/bin/zsh
set -euo pipefail

# 安装 WeClaw Send 的 DaVinci Deliver 后渲染脚本。
#
# 用法：
#   ./scripts/install-davinci-plugin.sh              # 默认 both（推荐）
#   ./scripts/install-davinci-plugin.sh both         # Lua + Python 都装
#   ./scripts/install-davinci-plugin.sh lua          # 仅 Lua（不依赖 Python）
#   ./scripts/install-davinci-plugin.sh python       # 仅 Python
#   ./scripts/install-davinci-plugin.sh auto         # 有 python3 则 both，否则仅 lua
#
# 原因简述：
# - Python 版：Resolve 内直接跑，逻辑完整；需本机 Python 且 Resolve 能枚举 .py
# - Lua 版：用 /usr/bin/curl 调本地接口，不依赖 Python；适合只列 Lua 或未装 Python 的环境
# - 默认 both：下拉里提供两个入口，用户按环境自选；新装自动清旧脚本名

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT/davinci-resolve/Deliver"
VERSION_FILE="$ROOT/davinci-resolve/VERSION"
USER_TARGET_DIR="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Deliver"
SYSTEM_TARGET_DIR="/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Deliver"

MODE="${1:-both}"

LUA_NAME="WeClawSend_Lua.lua"
PYTHON_NAME="WeClawSend_Python.py"

LEGACY_NAMES=(
    "WeClawSend.lua"
    "weclaw_postrender_send.py"
    "自动发送ClawBot_M4V文件.py"
    "自动发送ClawBot_MP4视频.py"
    "自动发送ClawBot_M4V文件.lua"
    "自动发送ClawBot_MP4视频.lua"
)

[[ -f "$VERSION_FILE" ]]
[[ -f "$SOURCE_DIR/$LUA_NAME" ]]
[[ -f "$SOURCE_DIR/$PYTHON_NAME" ]]

has_python3() {
    command -v python3 >/dev/null 2>&1 && python3 - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 6) else 1)
PY
}

case "$MODE" in
    both)
        INSTALL_LUA=1
        INSTALL_PYTHON=1
        REASON="安装 dual：Deliver 下同时提供 Lua / Python 入口，用户按环境自选。"
        ;;
    lua)
        INSTALL_LUA=1
        INSTALL_PYTHON=0
        REASON="仅 Lua：不依赖 Python；通过 curl 调用 WeClaw Send 本地接口。"
        ;;
    python)
        INSTALL_LUA=0
        INSTALL_PYTHON=1
        REASON="仅 Python：在 Resolve 内直接运行；需 Python 3.6+ 且 Resolve 能枚举 .py。"
        ;;
    auto)
        INSTALL_LUA=1
        if has_python3; then
            INSTALL_PYTHON=1
            REASON="自动：检测到 python3>=3.6，安装 Lua + Python。原因：Python 环境可用时提供完整宿主脚本；Lua 作为无 Python / 仅枚举 Lua 时的兜底。"
        else
            INSTALL_PYTHON=0
            REASON="自动：未检测到可用 python3，仅安装 Lua。原因：Lua+curl 不依赖 Python。"
        fi
        ;;
    *)
        print -u2 "未知模式：$MODE（可用 both|lua|python|auto）"
        exit 2
        ;;
esac

install_into() {
    local target_dir="$1"
    mkdir -p "$target_dir"

    # Always remove the other variant when not selected, and all legacy names.
    local name
    for name in "${LEGACY_NAMES[@]}" "$LUA_NAME" "$PYTHON_NAME"; do
        rm -f "$target_dir/$name"
    done

    if [[ "$INSTALL_LUA" == 1 ]]; then
        install -m 0644 "$SOURCE_DIR/$LUA_NAME" "$target_dir/$LUA_NAME"
        [[ -f "$target_dir/$LUA_NAME" ]]
    fi
    if [[ "$INSTALL_PYTHON" == 1 ]]; then
        install -m 0644 "$SOURCE_DIR/$PYTHON_NAME" "$target_dir/$PYTHON_NAME"
        [[ -f "$target_dir/$PYTHON_NAME" ]]
    fi

    install -m 0644 "$VERSION_FILE" "$target_dir/.weclaw-send-version"
    [[ -f "$target_dir/.weclaw-send-version" ]]
}

print -r -- "模式：$MODE"
print -r -- "原因：$REASON"

install_into "$USER_TARGET_DIR"
print -r -- "已安装到用户目录：$USER_TARGET_DIR"

if mkdir -p "$SYSTEM_TARGET_DIR" 2>/dev/null && [[ -w "$SYSTEM_TARGET_DIR" ]]; then
    install_into "$SYSTEM_TARGET_DIR"
    print -r -- "已安装到系统目录：$SYSTEM_TARGET_DIR"
else
    print -r -- "系统目录不可写，已跳过：$SYSTEM_TARGET_DIR"
fi

if [[ "$INSTALL_LUA" == 1 ]]; then
    print -r -- "入口：WeClawSend_Lua  （无需 Python，依赖 /usr/bin/curl）"
fi
if [[ "$INSTALL_PYTHON" == 1 ]]; then
    print -r -- "入口：WeClawSend_Python（需要 Python 3.6+）"
fi
print -r -- "MP4/M4V 显示名由 App 设置「发送时 .mp4 显示为 .m4v」处理。"
print -r -- "请启用 WeClaw Send 本地接口（127.0.0.1:18790），完全退出并重启 DaVinci Resolve。"
print -r -- "Deliver → 高级设置 → 渲染作业结束时触发脚本 中选择对应入口。"
print -r -- "隔离导致接口未启动时：xattr -dr com.apple.quarantine \"/Applications/WeClaw Send.app\""
