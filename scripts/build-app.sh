#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_APP="$ROOT/.build/WeClaw Send.app"
SIGNED_APP="$HOME/Library/Caches/WeClawSend/WeClaw Send.app"
ARM_BUILD="$ROOT/.build/universal/arm64"
X86_BUILD="$ROOT/.build/universal/x86_64"

ACTOOL="$(xcrun --find actool 2>/dev/null || true)"
if [[ -z "$ACTOOL" ]]; then
    print -u2 "缺少 actool。请安装完整 Xcode（不只是 Command Line Tools），以便把 AppIcon.icon 编成 Assets.car。"
    exit 1
fi

compile_app_icon() {
    local app="$1"
    local work
    work="$(mktemp -d "${TMPDIR:-/tmp/}weclaw-icon.XXXXXX")"
    mkdir -p "$work/out"
    "$ACTOOL" \
        "$ROOT/Resources/AppIcon.icon" \
        --compile "$work/out" \
        --app-icon AppIcon \
        --include-all-app-icons \
        --output-format human-readable-text --notices --warnings \
        --output-partial-info-plist "$work/assetcatalog_generated_info.plist" \
        --target-device mac \
        --platform macosx \
        --minimum-deployment-target 26.0 \
        --enable-on-demand-resources NO
    if [[ ! -f "$work/out/Assets.car" ]]; then
        print -u2 "actool 未生成 Assets.car"
        rm -rf "$work"
        exit 1
    fi
    xcrun assetutil --info "$work/out/Assets.car" > "$work/assets.json"
    grep -q AppIcon "$work/assets.json"
    cp "$work/out/Assets.car" "$app/Contents/Resources/Assets.car"
    rm -rf "$work"
}

if [[ ! -f "$ROOT/Resources/AppIcon.icns" || ! -d "$ROOT/Resources/AppIcon.icon" ]]; then
    print -u2 "缺少 AppIcon.icns 或 AppIcon.icon，请先运行: python3 scripts/generate-icons.py"
    exit 1
fi

swift build --package-path "$ROOT" --scratch-path "$ARM_BUILD" -c release --arch arm64
swift build --package-path "$ROOT" --scratch-path "$X86_BUILD" -c release --arch x86_64

ARM_BINARY="$ARM_BUILD/arm64-apple-macosx/release/WeClawSend"
X86_BINARY="$X86_BUILD/x86_64-apple-macosx/release/WeClawSend"

# 在 /tmp 组装 .app，规避 Documents/iCloud 带来的 fileprovider/provenance 导致 codesign 失败。
STAGE="$(mktemp -d "${TMPDIR:-/tmp/}weclaw-send-app.XXXXXX")"
APP="$STAGE/WeClaw Send.app"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$ARM_BINARY" "$X86_BINARY" -output "$APP/Contents/MacOS/WeClawSend"
lipo "$APP/Contents/MacOS/WeClawSend" -verify_arch arm64 x86_64
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -n "${WECLAW_UPDATE_COUNT_ENDPOINT:-}" ]]; then
    [[ "$WECLAW_UPDATE_COUNT_ENDPOINT" == https://* ]]
    /usr/libexec/PlistBuddy -c \
        "Add :WeClawUpdateCountEndpoint string $WECLAW_UPDATE_COUNT_ENDPOINT" \
        "$APP/Contents/Info.plist"
fi
if [[ -n "${WECLAW_ACCOUNT_PRESENCE_ENDPOINT:-}" ]]; then
    [[ "$WECLAW_ACCOUNT_PRESENCE_ENDPOINT" == https://* ]]
    /usr/libexec/PlistBuddy -c \
        "Add :WeClawAccountPresenceEndpoint string $WECLAW_ACCOUNT_PRESENCE_ENDPOINT" \
        "$APP/Contents/Info.plist"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
compile_app_icon "$APP"
cp "$ROOT/Resources/MenuBarIcon.png" "$APP/Contents/Resources/MenuBarIcon.png"
if [[ -f "$ROOT/Resources/MenuBarIcon@2x.png" ]]; then
    cp "$ROOT/Resources/MenuBarIcon@2x.png" "$APP/Contents/Resources/MenuBarIcon@2x.png"
fi
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
if [[ -f "$ROOT/docs/使用说明.md" ]]; then
    cp "$ROOT/docs/使用说明.md" "$APP/Contents/Resources/使用说明.md"
fi
if [[ -f "$ROOT/docs/使用说明.html" ]]; then
    cp "$ROOT/docs/使用说明.html" "$APP/Contents/Resources/使用说明.html"
fi
chmod +x "$APP/Contents/MacOS/WeClawSend"

find "$APP" \( -type f -o -type d \) -exec xattr -c {} \; 2>/dev/null || true

codesign --force --deep --sign - \
    --requirements '=designated => identifier "com.chacha.WeClawSend"' \
    "$APP"
codesign --verify --deep --strict "$APP"

rm -rf "$SIGNED_APP"
mkdir -p "$(dirname "$SIGNED_APP")"
ditto --norsrc --noextattr "$APP" "$SIGNED_APP"
find "$SIGNED_APP" \( -type f -o -type d \) -exec xattr -c {} +

# Documents/FileProvider 会给 .app 重新附加 FinderInfo；签名实体放在用户缓存，
# 工程内保留稳定的标准路径供 open/install 脚本使用。
codesign --force --deep --sign - \
    --requirements '=designated => identifier "com.chacha.WeClawSend"' \
    "$SIGNED_APP"
find "$SIGNED_APP" \( -type f -o -type d \) -exec xattr -c {} +
codesign --verify --deep --strict "$SIGNED_APP"

rm -rf "$OUT_APP"
mkdir -p "$ROOT/.build"
ln -s "$SIGNED_APP" "$OUT_APP"
codesign --verify --deep --strict "$OUT_APP"

print "$OUT_APP"
