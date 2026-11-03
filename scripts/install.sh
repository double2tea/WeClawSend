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

mkdir -p "$INSTALL_DIR"
STAGE="$(mktemp -d "$INSTALL_DIR/.weclaw-send-install.XXXXXX")"
STAGED_APP="$STAGE/WeClaw Send.app"
PREVIOUS_APP="$STAGE/previous.app"
cleanup() {
    local result=$?
    if (( result != 0 )) && [[ -e "$PREVIOUS_APP" ]]; then
        rm -rf "$APP"
        mv "$PREVIOUS_APP" "$APP" || return
    fi
    rm -rf "$STAGE"
}
trap cleanup EXIT

COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$SOURCE_APP" "$STAGED_APP"
codesign --force --sign - \
    --requirements '=designated => identifier "com.chacha.WeClawSend"' \
    "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

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

if [[ -e "$APP" ]]; then
    mv "$APP" "$PREVIOUS_APP"
fi
mv "$STAGED_APP" "$APP"
rm -f "$APP_PLIST"

open "$APP"
print "已安装并启动：$APP"
print "打开菜单栏图标 → 设置 → 扫码登录微信。"
