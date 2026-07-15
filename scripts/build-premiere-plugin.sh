#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$ROOT/premiere-uxp"

npm --prefix "$PLUGIN" ci
npm --prefix "$PLUGIN" run lint
npm --prefix "$PLUGIN" run type-check
npm --prefix "$PLUGIN" run build

print "$PLUGIN/dist"
