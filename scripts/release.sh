#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
ZIP="$DIST/WeClaw-Send.zip"
DMG="$DIST/WeClaw-Send.dmg"
CHECKSUMS="$DIST/SHA256SUMS.txt"
VERIFY="$(mktemp -d "${TMPDIR:-/tmp/}weclaw-send-release.XXXXXX")"
PACKAGE="$VERIFY/package"
DMG_PACKAGE="$VERIFY/dmg"
MOUNT="$VERIFY/mount"
MOUNTED=false

cleanup() {
    if [[ "$MOUNTED" == true ]]; then
        hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    fi
    rm -rf "$VERIFY"
}
trap cleanup EXIT

"$ROOT/scripts/build-app.sh"
APP="$(realpath "$ROOT/.build/WeClaw Send.app")"
BINARY="$APP/Contents/MacOS/WeClawSend"

lipo "$BINARY" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" == "14.0" ]]

mkdir -p "$DIST"
rm -f "$ZIP" "$DMG" "$CHECKSUMS"
mkdir -p "$PACKAGE"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$APP" "$PACKAGE/WeClaw Send.app"
cp "$ROOT/docs/使用说明.html" "$PACKAGE/使用说明.html"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr -c -k "$PACKAGE" "$ZIP"

mkdir -p "$DMG_PACKAGE"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$APP" "$DMG_PACKAGE/WeClaw Send.app"
cp "$ROOT/docs/使用说明.html" "$DMG_PACKAGE/使用说明.html"
ln -s /Applications "$DMG_PACKAGE/Applications"
hdiutil create -volname "WeClaw Send" -srcfolder "$DMG_PACKAGE" -format UDZO -ov "$DMG" >/dev/null

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

mkdir -p "$MOUNT"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT" >/dev/null
MOUNTED=true
[[ -d "$MOUNT/WeClaw Send.app" ]]
[[ -f "$MOUNT/使用说明.html" ]]
[[ "$(readlink "$MOUNT/Applications")" == "/Applications" ]]
lipo "$MOUNT/WeClaw Send.app/Contents/MacOS/WeClawSend" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$MOUNT/WeClaw Send.app"
hdiutil detach "$MOUNT" >/dev/null
MOUNTED=false

(
    cd "$DIST"
    shasum -a 256 "${ZIP:t}" "${DMG:t}" >"${CHECKSUMS:t}"
)

print "ZIP：$ZIP"
print "DMG：$DMG"
print "校验：$CHECKSUMS"
print "架构：$(lipo -archs "$EXTRACTED_BINARY")"
print "系统：macOS 14+"
print "签名：ad-hoc（首次打开需在系统设置中手动批准）"
print "说明：ZIP 与 DMG 均内含图解版《使用说明.html》"
