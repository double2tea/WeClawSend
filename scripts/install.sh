#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="$HOME/Applications"
APP="$INSTALL_DIR/WeClaw Send.app"
APP_LABEL="com.chacha.WeClawSend"
APP_PLIST="$HOME/Library/LaunchAgents/$APP_LABEL.plist"
LEGACY_LABELS=(
    "com.chacha.davinci-clawbot-bridge"
    "com.chacha.davinci-weclaw"
)

"$ROOT/scripts/build-app.sh"
SOURCE_APP="$(realpath "$ROOT/.build/WeClaw Send.app")"

# 停掉旧版 LaunchAgent 启动的本应用（现已改用 SMAppService）
if launchctl print "gui/$(id -u)/$APP_LABEL" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$APP_LABEL" || true
    sleep 1
fi

# 可选：停用历史独立 Bridge / WeClaw 后台（不影响新用户）
for label in "${LEGACY_LABELS[@]}"; do
    if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/$label" || true
    fi
    plist="$HOME/Library/LaunchAgents/$label.plist"
    if [[ -f "$plist" ]]; then
        mv "$plist" "$plist.disabled-by-weclaw-send" || true
    fi
done

killall WeClawSend >/dev/null 2>&1 || true

mkdir -p "$INSTALL_DIR"
rm -rf "$APP"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$SOURCE_APP" "$APP"
codesign --force --deep --sign - \
    --requirements '=designated => identifier "com.chacha.WeClawSend"' \
    "$APP" 2>/dev/null || true
codesign --verify --strict "$APP" 2>/dev/null || true
rm -f "$APP_PLIST"

open "$APP"
print "已安装并启动：$APP"
print "打开菜单栏图标 → 设置 → 扫码登录微信。"
