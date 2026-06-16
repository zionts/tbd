#!/usr/bin/env bash
set -euo pipefail

# Builds the blit terminal web client bundle that the macOS app's WKWebView
# loads (Phase 5/6 of the tmux->blit migration). Idempotent and reproducible:
#   - installs deps with `npm ci` (falls back to `npm install` if the lockfile
#     and package.json are out of sync, e.g. on first run)
#   - runs `npm run build`, producing web/terminal/dist/{index.html,bundle.js}
#
# Safe to run standalone:  scripts/build-web.sh

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB_DIR="$REPO_ROOT/web/terminal"

if [ ! -f "$WEB_DIR/package.json" ]; then
    echo "build-web: no web/terminal/package.json — nothing to build."
    exit 0
fi

if ! command -v npm >/dev/null 2>&1; then
    echo "build-web: npm not found on PATH — skipping web bundle." >&2
    exit 1
fi

cd "$WEB_DIR"

echo "build-web: installing deps..."
if [ -f package-lock.json ]; then
    npm ci || npm install
else
    npm install
fi

echo "build-web: building bundle..."
npm run build

echo "build-web: done -> web/terminal/dist/index.html"
