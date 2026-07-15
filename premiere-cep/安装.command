#!/bin/zsh
set -euo pipefail

SOURCE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HOME/Library/Application Support/Adobe/CEP/extensions/com.chacha.WeClawSend.Premiere"

mkdir -p "${TARGET:h}"
rm -rf "$TARGET"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$SOURCE" "$TARGET"
defaults write com.adobe.CSXS.12 PlayerDebugMode 1

print "WeClaw Send CEP 12 面板已安装。"
print "请重新打开 Premiere Pro 2025，然后前往：窗口 → 扩展 → WeClaw Send"
