#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
ZIP="$DIST/WeClaw-Send.zip"
VERIFY="$(mktemp -d "${TMPDIR:-/tmp/}weclaw-send-release.XXXXXX")"
PACKAGE="$VERIFY/package"
trap 'rm -rf "$VERIFY"' EXIT

"$ROOT/scripts/build-app.sh"
APP="$(realpath "$ROOT/.build/WeClaw Send.app")"
BINARY="$APP/Contents/MacOS/WeClawSend"

lipo "$BINARY" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" == "14.0" ]]

mkdir -p "$DIST"
rm -f "$ZIP"
mkdir -p "$PACKAGE"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$APP" "$PACKAGE/WeClaw Send.app"
cp "$ROOT/docs/使用说明.html" "$PACKAGE/使用说明.html"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr -c -k "$PACKAGE" "$ZIP"

if zipinfo -1 "$ZIP" | grep -Eq '(^|/)\._'; then
    print -u2 "发布包包含 AppleDouble 元数据"
    exit 1
fi

ditto -x -k "$ZIP" "$VERIFY"
EXTRACTED_APP="$VERIFY/WeClaw Send.app"
EXTRACTED_BINARY="$EXTRACTED_APP/Contents/MacOS/WeClawSend"
EXTRACTED_GUIDE="$VERIFY/使用说明.html"

[[ -d "$EXTRACTED_APP" && ! -L "$EXTRACTED_APP" ]]
[[ -f "$EXTRACTED_GUIDE" ]]
grep -q '系统设置 → 隐私与安全性' "$EXTRACTED_GUIDE"
lipo "$EXTRACTED_BINARY" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$EXTRACTED_APP"
[[ "$(shasum -a 256 "$BINARY" | awk '{print $1}')" == "$(shasum -a 256 "$EXTRACTED_BINARY" | awk '{print $1}')" ]]

print "发布包：$ZIP"
print "架构：$(lipo -archs "$EXTRACTED_BINARY")"
print "系统：macOS 14+"
print "签名：ad-hoc（首次打开需在系统设置中手动批准）"
print "说明：ZIP 内含图解版《使用说明.html》"
