#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
ZIP="$DIST/WeClaw-Send.zip"
DMG="$DIST/WeClaw-Send.dmg"
PREMIERE_ZIP="$DIST/WeClaw-Send-Premiere-CEP12.zip"
DAVINCI_ZIP="$DIST/WeClaw-Send-DaVinci-Resolve.zip"
COMPONENTS="$DIST/WeClaw-Send-Components.json"
CHECKSUMS="$DIST/SHA256SUMS.txt"
TUTORIAL_LINK="$ROOT/docs/视频教程.webloc"
TUTORIAL_URL="https://xhslink.cn/o/njUmexGUhg"
VERIFY="$(mktemp -d "${TMPDIR:-/tmp/}weclaw-send-release.XXXXXX")"
PACKAGE="$VERIFY/package"
DMG_PACKAGE="$VERIFY/dmg"
PREMIERE_PACKAGE="$VERIFY/premiere"
DAVINCI_PACKAGE="$VERIFY/davinci"
MOUNT="$VERIFY/mount"
MOUNTED=false
MOUNT_DEVICE=""

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")"
APP_CHANNEL="$(/usr/libexec/PlistBuddy -c 'Print :WeClawReleaseChannel' "$ROOT/Resources/Info.plist")"
VERSIONED_DMG="$DIST/WeClaw-Send-$APP_VERSION-build$APP_BUILD.dmg"
PREMIERE_VERSION="$(sed -n 's/.*ExtensionBundleVersion="\([^"]*\)".*/\1/p' "$ROOT/premiere-cep/CSXS/manifest.xml")"
DAVINCI_VERSION="$(tr -d '[:space:]' < "$ROOT/davinci-resolve/VERSION")"
VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'
BUILD_PATTERN='^[0-9]+$'
[[ "$APP_VERSION" =~ $VERSION_PATTERN ]]
[[ "$APP_BUILD" =~ $BUILD_PATTERN ]]
[[ "$APP_CHANNEL" == "stable" || "$APP_CHANNEL" == "beta" ]]
[[ "$PREMIERE_VERSION" =~ $VERSION_PATTERN ]]
[[ "$DAVINCI_VERSION" =~ $VERSION_PATTERN ]]
[[ -f "$TUTORIAL_LINK" ]]
grep -Fq "$TUTORIAL_URL" "$TUTORIAL_LINK"

detach_mounted_image() {
    [[ "$MOUNTED" == true ]] || return 0
    local target="${MOUNT_DEVICE:-$MOUNT}"
    local attempt
    for attempt in {1..5}; do
        if hdiutil detach "$target" >/dev/null 2>&1; then
            MOUNTED=false
            MOUNT_DEVICE=""
            return 0
        fi
        sleep 1
    done
    hdiutil detach "$target" -force >/dev/null
    MOUNTED=false
    MOUNT_DEVICE=""
}

cleanup() {
    detach_mounted_image || true
    rm -rf "$VERIFY"
}
trap cleanup EXIT

"$ROOT/scripts/build-app.sh"
"$ROOT/scripts/build-premiere-plugin.sh"
APP="$(realpath "$ROOT/.build/WeClaw Send.app")"
BINARY="$APP/Contents/MacOS/WeClawSend"

lipo "$BINARY" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" == "14.0" ]]
[[ -f "$APP/Contents/Resources/RELEASE_NOTES.md" ]]

mkdir -p "$DIST"
rm -f \
    "$ZIP" \
    "$DMG" \
    "$VERSIONED_DMG" \
    "$PREMIERE_ZIP" \
    "$DAVINCI_ZIP" \
    "$COMPONENTS" \
    "$CHECKSUMS" \
    "$DIST/WeClaw-Send-Premiere-UXP.zip"
mkdir -p "$PACKAGE"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$APP" "$PACKAGE/WeClaw Send.app"
cp "$ROOT/docs/使用说明.html" "$PACKAGE/使用说明.html"
cp "$TUTORIAL_LINK" "$PACKAGE/视频教程.webloc"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr -c -k "$PACKAGE" "$ZIP"

mkdir -p "$DMG_PACKAGE"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$APP" "$DMG_PACKAGE/WeClaw Send.app"
cp "$ROOT/docs/使用说明.html" "$DMG_PACKAGE/使用说明.html"
cp "$TUTORIAL_LINK" "$DMG_PACKAGE/视频教程.webloc"
ln -s /Applications "$DMG_PACKAGE/Applications"
hdiutil create -volname "WeClaw Send" -srcfolder "$DMG_PACKAGE" -format UDZO -ov "$DMG" >/dev/null
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$DMG" "$VERSIONED_DMG"

mkdir -p "$PREMIERE_PACKAGE"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$ROOT/premiere-cep" "$PREMIERE_PACKAGE"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr -c -k "$PREMIERE_PACKAGE" "$PREMIERE_ZIP"

mkdir -p "$DAVINCI_PACKAGE/davinci-resolve/Deliver" "$DAVINCI_PACKAGE/scripts"
for name in \
    "WeClawSend_Lua.lua" \
    "WeClawSend_Python.py"
do
    cp "$ROOT/davinci-resolve/Deliver/$name" "$DAVINCI_PACKAGE/davinci-resolve/Deliver/$name"
done
cp "$ROOT/davinci-resolve/README.md" "$DAVINCI_PACKAGE/davinci-resolve/README.md"
cp "$ROOT/davinci-resolve/VERSION" "$DAVINCI_PACKAGE/davinci-resolve/VERSION"
cp "$ROOT/scripts/install-davinci-plugin.sh" "$DAVINCI_PACKAGE/scripts/install-davinci-plugin.sh"
chmod +x "$DAVINCI_PACKAGE/scripts/install-davinci-plugin.sh"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr -c -k "$DAVINCI_PACKAGE" "$DAVINCI_ZIP"

for archive in "$ZIP" "$PREMIERE_ZIP" "$DAVINCI_ZIP"; do
    if zipinfo -1 "$archive" | grep -Eq '(^|/)\._'; then
        print -u2 "发布包包含 AppleDouble 元数据：$archive"
        exit 1
    fi
done

PREMIERE_CONTENTS="$(LC_ALL=C zipinfo -1 "$PREMIERE_ZIP")"
if ! grep -qx 'CSXS/manifest.xml' <<<"$PREMIERE_CONTENTS" \
    || ! grep -qx 'js/bridge-client.js' <<<"$PREMIERE_CONTENTS" \
    || ! grep -Eq '\.command$' <<<"$PREMIERE_CONTENTS"; then
    print -u2 "Premiere 发布包缺少构建产物"
    exit 1
fi

DAVINCI_CONTENTS="$(LC_ALL=C zipinfo -1 "$DAVINCI_ZIP")"
if ! grep -qx 'davinci-resolve/Deliver/WeClawSend_Lua.lua' <<<"$DAVINCI_CONTENTS" \
    || ! grep -qx 'davinci-resolve/Deliver/WeClawSend_Python.py' <<<"$DAVINCI_CONTENTS" \
    || ! grep -qx 'davinci-resolve/VERSION' <<<"$DAVINCI_CONTENTS" \
    || ! grep -qx 'scripts/install-davinci-plugin.sh' <<<"$DAVINCI_CONTENTS"; then
    print -u2 "DaVinci 发布包缺少脚本"
    exit 1
fi

printf '{\n  "app": "%s",\n  "app_build": %s,\n  "premiere": "%s",\n  "davinci": "%s"\n}\n' \
    "$APP_VERSION" \
    "$APP_BUILD" \
    "$PREMIERE_VERSION" \
    "$DAVINCI_VERSION" > "$COMPONENTS"
python3 -m json.tool "$COMPONENTS" >/dev/null

if grep -q '__pycache__' <<<"$DAVINCI_CONTENTS"; then
    print -u2 "DaVinci 发布包包含 Python 缓存"
    exit 1
fi

ditto -x -k "$ZIP" "$VERIFY"
EXTRACTED_APP="$VERIFY/WeClaw Send.app"
EXTRACTED_BINARY="$EXTRACTED_APP/Contents/MacOS/WeClawSend"
EXTRACTED_GUIDE="$VERIFY/使用说明.html"
EXTRACTED_TUTORIAL_LINK="$VERIFY/视频教程.webloc"

[[ -d "$EXTRACTED_APP" && ! -L "$EXTRACTED_APP" ]]
[[ -f "$EXTRACTED_APP/Contents/Resources/RELEASE_NOTES.md" ]]
[[ -f "$EXTRACTED_GUIDE" ]]
[[ -f "$EXTRACTED_TUTORIAL_LINK" ]]
grep -q '系统设置 → 隐私与安全性' "$EXTRACTED_GUIDE"
grep -Fq "$TUTORIAL_URL" "$EXTRACTED_GUIDE"
grep -Fq "$TUTORIAL_URL" "$EXTRACTED_TUTORIAL_LINK"
lipo "$EXTRACTED_BINARY" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$EXTRACTED_APP"
[[ "$(shasum -a 256 "$BINARY" | awk '{print $1}')" == "$(shasum -a 256 "$EXTRACTED_BINARY" | awk '{print $1}')" ]]

mkdir -p "$MOUNT"
ATTACH_OUTPUT="$(hdiutil attach "$VERSIONED_DMG" -readonly -nobrowse -mountpoint "$MOUNT")"
MOUNTED=true
MOUNT_DEVICE="$(print -r -- "$ATTACH_OUTPUT" | awk '$1 ~ "^/dev/" { print $1; exit }')"
[[ "$MOUNT_DEVICE" == /dev/disk* ]]
[[ -d "$MOUNT/WeClaw Send.app" ]]
[[ -f "$MOUNT/WeClaw Send.app/Contents/Resources/RELEASE_NOTES.md" ]]
[[ -f "$MOUNT/使用说明.html" ]]
[[ -f "$MOUNT/视频教程.webloc" ]]
grep -Fq "$TUTORIAL_URL" "$MOUNT/视频教程.webloc"
[[ "$(readlink "$MOUNT/Applications")" == "/Applications" ]]
lipo "$MOUNT/WeClaw Send.app/Contents/MacOS/WeClawSend" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$MOUNT/WeClaw Send.app"
detach_mounted_image

(
    cd "$DIST"
    shasum -a 256 \
        "${ZIP:t}" \
        "${DMG:t}" \
        "${VERSIONED_DMG:t}" \
        "${PREMIERE_ZIP:t}" \
        "${DAVINCI_ZIP:t}" \
        "${COMPONENTS:t}" >"${CHECKSUMS:t}"
)

print "ZIP：$ZIP"
print "DMG（版本化）：$VERSIONED_DMG"
print "DMG（固定链接）：$DMG"
print "Premiere：$PREMIERE_ZIP"
print "DaVinci：$DAVINCI_ZIP"
print "组件版本：$COMPONENTS"
print "校验：$CHECKSUMS"
print "架构：$(lipo -archs "$EXTRACTED_BINARY")"
print "系统：macOS 14+"
print "签名：ad-hoc（首次打开需在系统设置中手动批准）"
print "说明：ZIP 与 DMG 均内含《使用说明.html》和可双击的《视频教程.webloc》"
