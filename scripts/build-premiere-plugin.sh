#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$ROOT/premiere-uxp"

(
    cd "$PLUGIN"
    npm ci
    npm run lint
    npm run type-check
    npm run build
)

print "$PLUGIN/dist"
