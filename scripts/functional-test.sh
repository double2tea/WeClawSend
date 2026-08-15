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
    sleep 1
    if [[ -d "$INSTALLED_APP" ]]; then
        open -n "$INSTALLED_APP"
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
print "$HEALTH" | grep -q '"scheduled_send_count":' \
    && ok "health scheduled_send_count" || bad "scheduled_send_count missing"
print "$HEALTH" | grep -q '"next_scheduled_at":' \
    && ok "health next_scheduled_at" || bad "next_scheduled_at missing"

print "== 4) negative path checks =="
MISSING_CODE="$(curl --silent --output "$TMP/missing.json" --write-out '%{http_code}' \
    -X POST "$HOST/send" -H 'Content-Type: application/json' \
    -d '{"file_path":"/tmp/weclaw-send-definitely-missing-xyz.m4v","file_name":"x.m4v"}')"
[[ "$MISSING_CODE" == "404" ]] && ok "missing file → 404" || bad "missing file expected 404 got $MISSING_CODE"
INVALID_CODE="$(curl --silent --output "$TMP/invalid.json" --write-out '%{http_code}' \
    -X POST "$HOST/send" -H 'Content-Type: application/json' \
    -d '{')"
[[ "$INVALID_CODE" == "400" ]] && ok "invalid JSON → 400" || bad "invalid JSON expected 400 got $INVALID_CODE"

print "== 5) scheduled send API =="
SCHEDULE_SAMPLE="$TMP/WeClawSend计划测试_$(date +%H%M%S).txt"
print "scheduled send before change" >"$SCHEDULE_SAMPLE"
SCHEDULE_KEY="functional-$(date +%s)-$$"
SCHEDULE_CREATE_BODY="$TMP/schedule-create.json"
SCHEDULE_CREATE_CODE="$(curl --silent --output "$SCHEDULE_CREATE_BODY" --write-out '%{http_code}' \
    -X POST "$HOST/scheduled-sends" -H 'Content-Type: application/json' \
    -d "{\"items\":[{\"file_path\":\"$SCHEDULE_SAMPLE\",\"file_name\":\"$(basename "$SCHEDULE_SAMPLE")\"}],\"delay_seconds\":3600,\"source\":\"functional-test\",\"idempotency_key\":\"$SCHEDULE_KEY\"}")"
if [[ "$SCHEDULE_CREATE_CODE" == "201" ]] && grep -q '"status":"scheduled"' "$SCHEDULE_CREATE_BODY"; then
    ok "create scheduled send → 201"
else
    bad "create scheduled send expected 201 got $SCHEDULE_CREATE_CODE"
fi
SCHEDULE_ID="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["id"])' "$SCHEDULE_CREATE_BODY" 2>/dev/null || true)"
if [[ -n "$SCHEDULE_ID" ]]; then
    ok "scheduled send id returned"
else
    bad "scheduled send id missing"
fi

SCHEDULE_REPEAT_BODY="$TMP/schedule-repeat.json"
SCHEDULE_REPEAT_CODE="$(curl --silent --output "$SCHEDULE_REPEAT_BODY" --write-out '%{http_code}' \
    -X POST "$HOST/scheduled-sends" -H 'Content-Type: application/json' \
    -d "{\"items\":[{\"file_path\":\"$SCHEDULE_SAMPLE\"}],\"delay_seconds\":7200,\"source\":\"functional-test\",\"idempotency_key\":\"$SCHEDULE_KEY\"}")"
SCHEDULE_REPEAT_ID="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["id"])' "$SCHEDULE_REPEAT_BODY" 2>/dev/null || true)"
if [[ "$SCHEDULE_REPEAT_CODE" == "200" && "$SCHEDULE_REPEAT_ID" == "$SCHEDULE_ID" ]]; then
    ok "scheduled send idempotency"
else
    bad "scheduled send idempotency failed"
fi

SCHEDULE_LIST_CODE="$(curl --silent --output "$TMP/schedule-list.json" --write-out '%{http_code}' \
    "$HOST/scheduled-sends")"
if [[ "$SCHEDULE_LIST_CODE" == "200" ]] && grep -q "$SCHEDULE_ID" "$TMP/schedule-list.json"; then
    ok "list scheduled sends"
else
    bad "scheduled send list missing created plan"
fi

SCHEDULE_DETAIL_CODE="$(curl --silent --output "$TMP/schedule-detail.json" --write-out '%{http_code}' \
    "$HOST/scheduled-sends/$SCHEDULE_ID")"
[[ "$SCHEDULE_DETAIL_CODE" == "200" ]] \
    && ok "get scheduled send" || bad "get scheduled send expected 200 got $SCHEDULE_DETAIL_CODE"

SCHEDULE_PATCH_CODE="$(curl --silent --output "$TMP/schedule-patch.json" --write-out '%{http_code}' \
    -X PATCH "$HOST/scheduled-sends/$SCHEDULE_ID" -H 'Content-Type: application/json' \
    -d '{"delay_seconds":7200}')"
if [[ "$SCHEDULE_PATCH_CODE" == "200" ]] && grep -q '"status":"scheduled"' "$TMP/schedule-patch.json"; then
    ok "reschedule scheduled send"
else
    bad "reschedule expected 200 got $SCHEDULE_PATCH_CODE"
fi

print "scheduled send changed after planning" >>"$SCHEDULE_SAMPLE"
SCHEDULE_NOW_CODE="$(curl --silent --output "$TMP/schedule-now.json" --write-out '%{http_code}' \
    -X POST "$HOST/scheduled-sends/$SCHEDULE_ID/send-now")"
[[ "$SCHEDULE_NOW_CODE" == "202" ]] \
    && ok "send-now accepted" || bad "send-now expected 202 got $SCHEDULE_NOW_CODE"

SCHEDULE_NEEDS_ATTENTION=false
for _ in {1..20}; do
    curl --silent --output "$TMP/schedule-after-now.json" "$HOST/scheduled-sends/$SCHEDULE_ID"
    if grep -q '"status":"needs_attention"' "$TMP/schedule-after-now.json"; then
        SCHEDULE_NEEDS_ATTENTION=true
        break
    fi
    sleep 0.25
done
if [[ "$SCHEDULE_NEEDS_ATTENTION" == true ]]; then
    ok "changed file blocks scheduled send"
else
    bad "changed scheduled file did not enter needs_attention"
fi

SCHEDULE_DELETE_CODE="$(curl --silent --output "$TMP/schedule-delete.json" --write-out '%{http_code}' \
    -X DELETE "$HOST/scheduled-sends/$SCHEDULE_ID")"
if [[ "$SCHEDULE_DELETE_CODE" == "200" ]] && grep -q '"status":"cancelled"' "$TMP/schedule-delete.json"; then
    ok "cancel scheduled send"
else
    bad "cancel scheduled send expected 200 got $SCHEDULE_DELETE_CODE"
fi

SCHEDULE_INVALID_CODE="$(curl --silent --output "$TMP/schedule-invalid.json" --write-out '%{http_code}' \
    -X POST "$HOST/scheduled-sends" -H 'Content-Type: application/json' \
    -d "{\"items\":[{\"file_path\":\"$SCHEDULE_SAMPLE\"}],\"scheduled_at\":\"2099-01-01T00:00:00Z\",\"delay_seconds\":60}")"
[[ "$SCHEDULE_INVALID_CODE" == "400" ]] \
    && ok "scheduled time modes are mutually exclusive" \
    || bad "invalid scheduled request expected 400 got $SCHEDULE_INVALID_CODE"

print "== 6) real send (requires WeChat session) =="
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

print "== 7) UI assets =="
file "$BUNDLE/Contents/Resources/AppIcon.icns" | grep -qi icns && ok "icns type" || bad "icns type"
sips -g all "$BUNDLE/Contents/Resources/MenuBarIcon.png" >/dev/null && ok "menu bar png readable" || bad "menu bar png"

print ""
print "summary: $pass passed, $skip skipped, $fail failed"
[[ "$fail" -eq 0 && "$skip" -eq 0 ]]
