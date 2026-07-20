#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="http://127.0.0.1:18790"
TMP="$(mktemp -d "${TMPDIR:-/tmp/}weclaw-send-func.XXXXXX")"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/WeClaw Send.app"
PREF_DOMAIN="com.chacha.WeClawSend"
PREF_KEY="LocalAPIEnabled"
HAD_LOCAL_API_SETTING=false
PREVIOUS_LOCAL_API_SETTING=""

if PREVIOUS_LOCAL_API_SETTING="$(defaults read "$PREF_DOMAIN" "$PREF_KEY" 2>/dev/null)"; then
    HAD_LOCAL_API_SETTING=true
fi

cleanup() {
    rm -rf "$TMP"
    if [[ "$HAD_LOCAL_API_SETTING" == true ]]; then
        if [[ "$PREVIOUS_LOCAL_API_SETTING" == "1" ]]; then
            defaults write "$PREF_DOMAIN" "$PREF_KEY" -bool true
        else
            defaults write "$PREF_DOMAIN" "$PREF_KEY" -bool false
        fi
    else
        defaults delete "$PREF_DOMAIN" "$PREF_KEY" 2>/dev/null || true
    fi
    killall WeClawSend >/dev/null 2>&1 || true
    if [[ -d "$INSTALLED_APP" ]]; then
        open "$INSTALLED_APP"
    fi
}
trap cleanup EXIT

defaults write "$PREF_DOMAIN" "$PREF_KEY" -bool true

pass=0
skip=0
fail=0

ok() {
    print "PASS  $1"
    pass=$((pass + 1))
}

bad() {
    print -u2 "FAIL  $1"
    fail=$((fail + 1))
}

skipped() {
    print "SKIP  $1"
    skip=$((skip + 1))
}

print "== 1) component + release build =="
"$ROOT/scripts/test.sh"
ok "component checks + release build"

print "== 2) package app with branding =="
"$ROOT/scripts/build-app.sh"
BUNDLE="$(realpath "$ROOT/.build/WeClaw Send.app")"
[[ -f "$BUNDLE/Contents/Resources/AppIcon.icns" ]] || bad "AppIcon.icns missing in bundle"
[[ -f "$BUNDLE/Contents/Resources/MenuBarIcon.png" ]] || bad "MenuBarIcon.png missing in bundle"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$BUNDLE/Contents/Info.plist" | grep -q AppIcon \
    && ok "bundle icon metadata" || bad "CFBundleIconFile not AppIcon"
/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:LSItemContentTypes:0' "$BUNDLE/Contents/Info.plist" | grep -qx public.movie \
    && ok "Final Cut video handoff metadata" || bad "public.movie document type missing"

print "== 3) reinstall & launch =="
killall WeClawSend >/dev/null 2>&1 || true
sleep 1
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$BUNDLE" "$INSTALLED_APP"
# Documents 路径拷贝后可能附带 xattr；安装目录再签一次保证可运行。
codesign --force --deep --sign - \
    --requirements '=designated => identifier "com.chacha.WeClawSend"' \
    "$INSTALLED_APP" 2>/dev/null || true
open "$INSTALLED_APP"

READY=false
HEALTH=""
for _ in {1..30}; do
    HEALTH="$(curl --silent --max-time 1 "$HOST/health" || true)"
    if print "$HEALTH" | grep -q '"ok":true'; then
        READY=true
        break
    fi
    sleep 0.5
done
if [[ "$READY" == true ]]; then
    ok "local API health ok"
else
    bad "local API did not become ready"
    print "summary: $pass passed, $skip skipped, $fail failed"
    exit 1
fi

LISTENERS="$(lsof -nP -iTCP:18790 -sTCP:LISTEN -F n 2>/dev/null || true)"
if print "$LISTENERS" | grep -q '^n127\.0\.0\.1:18790$' \
    && ! print "$LISTENERS" | grep -q '^n\*:18790$'; then
    ok "local API bound to IPv4 loopback"
else
    bad "local API is not restricted to 127.0.0.1:18790"
fi

# 等待凭据校验（Application Support / legacy migration + getconfig）
for _ in {1..20}; do
    HEALTH="$(curl --silent --max-time 2 "$HOST/health" || true)"
    if print "$HEALTH" | grep -q '"wechat_connected":true'; then
        break
    fi
    sleep 0.5
done
print "health: $HEALTH"
print "$HEALTH" | grep -q '"service":"weclaw-send"' && ok "service id" || bad "unexpected service id"
print "$HEALTH" | grep -q '"backend":"wechat-ilink"' && ok "backend id" || bad "unexpected backend"

print "== 4) negative path checks =="
MISSING_CODE="$(curl --silent --output "$TMP/missing.json" --write-out '%{http_code}' \
    -X POST "$HOST/send" -H 'Content-Type: application/json' \
    -d '{"file_path":"/tmp/weclaw-send-definitely-missing-xyz.m4v","file_name":"x.m4v"}')"
[[ "$MISSING_CODE" == "404" ]] && ok "missing file → 404" || bad "missing file expected 404 got $MISSING_CODE"
INVALID_CODE="$(curl --silent --output "$TMP/invalid.json" --write-out '%{http_code}' \
    -X POST "$HOST/send" -H 'Content-Type: application/json' \
    -d '{')"
[[ "$INVALID_CODE" == "400" ]] && ok "invalid JSON → 400" || bad "invalid JSON expected 400 got $INVALID_CODE"

print "== 5) real send (requires WeChat session) =="
SAMPLE="$TMP/WeClawSend功能测试_$(date +%H%M%S).txt"
print "WeClaw Send functional test payload $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$SAMPLE"
SEND_BODY="$TMP/send.json"
set +e
SEND_CODE="$(curl --silent --output "$SEND_BODY" --write-out '%{http_code}' \
    --max-time 200 \
    -X POST "$HOST/send" -H 'Content-Type: application/json' \
    -d "{\"file_path\":\"$SAMPLE\",\"file_name\":\"$(basename "$SAMPLE")\"}")"
SEND_CURL=$?
set -e
print "send curl_exit=$SEND_CURL http=$SEND_CODE body=$(cat "$SEND_BODY" 2>/dev/null || true)"
if [[ "$SEND_CURL" -eq 0 && "$SEND_CODE" == "200" ]] && grep -q '"ok":true' "$SEND_BODY"; then
    ok "real file send"
    AFTER="$(curl --silent --max-time 2 "$HOST/health")"
    print "health after send: $AFTER"
    print "$AFTER" | grep -q 'last_send_at' && ok "last_send_at present" || bad "last_send_at missing"
elif [[ "$SEND_CODE" == "503" ]] && grep -q '尚未登录' "$SEND_BODY" 2>/dev/null; then
    skipped "real send (未登录；扫码登录后重跑)"
elif [[ "$SEND_CURL" -ne 0 ]]; then
    skipped "real send (请求超时/中断，可能处于 60s 冷却或网络慢)"
else
    bad "real file send failed (http $SEND_CODE)"
fi

print "== 6) UI assets =="
file "$BUNDLE/Contents/Resources/AppIcon.icns" | grep -qi icns && ok "icns type" || bad "icns type"
sips -g all "$BUNDLE/Contents/Resources/MenuBarIcon.png" >/dev/null && ok "menu bar png readable" || bad "menu bar png"

print ""
print "summary: $pass passed, $skip skipped, $fail failed"
[[ "$fail" -eq 0 && "$skip" -eq 0 ]]
