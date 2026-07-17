#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT/davinci-resolve/Deliver"
VERSION_FILE="$ROOT/davinci-resolve/VERSION"
TARGET_DIR="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Deliver"

[[ -f "$VERSION_FILE" ]]

mkdir -p "$TARGET_DIR"

for name in \
    "自动发送ClawBot_M4V文件.py" \
    "自动发送ClawBot_MP4视频.py"
do
    install -m 0644 "$SOURCE_DIR/$name" "$TARGET_DIR/$name"
done
install -m 0644 "$VERSION_FILE" "$TARGET_DIR/.weclaw-send-version"

print -r -- "已安装 DaVinci Resolve 自动发送脚本：$TARGET_DIR"
print -r -- "请在 WeClaw Send 设置中启用本地接口，并重启 DaVinci Resolve。"
