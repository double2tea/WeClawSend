#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp/}weclaw-send-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

python3 -m unittest discover \
    -s "$ROOT/Tests/DaVinciPluginChecks" \
    -p 'test_*.py'

plutil -lint "$ROOT/Resources/Info.plist" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:LSItemContentTypes:0' "$ROOT/Resources/Info.plist")" == "public.movie" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:LSHandlerRank' "$ROOT/Resources/Info.plist")" == "Alternate" ]]

"$ROOT/scripts/build-premiere-plugin.sh"

swiftc \
    -framework AppKit \
    -framework Security \
    -framework ServiceManagement \
    -I "$ROOT/Sources/CCommonCrypto" \
    -Xcc -fmodule-map-file="$ROOT/Sources/CCommonCrypto/module.modulemap" \
    "$ROOT/Sources/WeClawSend/PasteboardURLs.swift" \
    "$ROOT/Sources/WeClawSend/AppSettings.swift" \
    "$ROOT/Sources/WeClawSend/UpdateManager.swift" \
    "$ROOT/Sources/WeClawSend/PopoverAutoClosePolicy.swift" \
    "$ROOT/Sources/WeClawSend/TransferRecord.swift" \
    "$ROOT/Sources/WeClawSend/WeChatCredentials.swift" \
    "$ROOT/Sources/WeClawSend/WeChatCrypto.swift" \
    "$ROOT/Sources/WeClawSend/WeChatService.swift" \
    "$ROOT/Sources/WeClawSend/SendCoordinator.swift" \
    "$ROOT/Tests/ComponentChecks/main.swift" \
    -o "$TEST_DIR/component-checks"
"$TEST_DIR/component-checks"
swift build --package-path "$ROOT" -c release
