#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$ROOT/premiere-cep"

[[ -f "$PLUGIN/CSXS/manifest.xml" ]]
[[ -f "$PLUGIN/index.html" ]]
[[ -f "$PLUGIN/js/bridge-client.js" ]]
[[ -f "$PLUGIN/js/main.js" ]]
[[ -f "$PLUGIN/js/preset-library.js" ]]
[[ -f "$PLUGIN/jsx/host.jsx" ]]
node --check "$PLUGIN/js/main.js"
node --check "$PLUGIN/js/bridge-client.js"
node --check "$PLUGIN/js/preset-library.js"
node --check "$PLUGIN/js/protocol.js"
node --test "$PLUGIN/tests/"*.test.js

print "$PLUGIN"
