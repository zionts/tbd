#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# restart-blit-test.sh — ISOLATED blit-terminal test launcher
# ============================================================================
#
# This is the Phase 7 safe launcher for the blit-terminal-migration branch.
# It builds and runs THIS worktree's TBDDaemon + TBDApp against a completely
# isolated, throwaway home directory so it CANNOT touch:
#   - the user's real ~/tbd/state.db, socket, pidfile, port, or reposDir
#   - the real running TBD daemon
#   - existing worktrees / live terminal sessions
#
# How isolation works:
#   - TBD_HOME points at a throwaway dir (default /tmp/tbd-blit-test). Every
#     derived path in TBDConstants (state.db, socket, tbdd.pid, port, reposDir,
#     and BlitManager's blit server/gateway sockets) follows TBD_HOME.
#   - TBD_SOCKET_PATH overrides ONLY the unix socket and is kept short (under
#     /tmp) to stay within darwin's ~104-char sun_path limit even if TBD_HOME
#     is a deep path.
#   - The daemon and app BINARIES are launched DIRECTLY with this env. macOS
#     `open` STRIPS environment variables before launching a .app bundle, so we
#     must NOT use `open` here — otherwise the GUI app would fall back to the
#     real ~/tbd. The trade-off: launching the bare binary means there is no
#     surrounding .app/Info.plist, so deep links (tbd://) and a few bundle-only
#     APIs (UNUserNotificationCenter banners, LaunchServices URL routing) are
#     DEGRADED. That is acceptable for a terminal RENDER test — the goal here is
#     to confirm blit terminals render in the WKWebView, not to test deep links.
#
# Prod restart.sh HARDCODES ~/tbd/ and a /Applications install — never use it
# for blit testing. This script is its isolated counterpart.
#
# Usage:
#   scripts/restart-blit-test.sh
#
# Optional environment overrides:
#   TBD_HOME=/some/dir            # isolated home (default /tmp/tbd-blit-test)
#   TBD_TEST_REPO=/path/to/repo   # a scratch git repo to point TBD at (see below)
#
# Pointing it at a throwaway repo:
#   The isolated daemon starts with an empty state.db and no repos. To exercise
#   terminals you need a repo + worktree. Create a scratch git repo once, e.g.:
#       mkdir -p /tmp/tbd-scratch-repo && cd /tmp/tbd-scratch-repo \
#         && git init -q && git commit -q --allow-empty -m init
#   then add it via the running app's UI ("Add Repo") or the CLI against the
#   isolated socket:
#       TBD_HOME="$TBD_HOME" TBD_SOCKET_PATH="$TBD_SOCKET_PATH" \
#         .build/debug/tbd repo add "$TBD_TEST_REPO"
#   (Set TBD_TEST_REPO above only as documentation of which repo you intend to
#   use; this script does not auto-add it, to keep the launcher simple.)
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build/debug"

# --- Isolated home + short socket ------------------------------------------
export TBD_HOME="${TBD_HOME:-/tmp/tbd-blit-test}"
# Keep the socket short and OUTSIDE a potentially-deep TBD_HOME to respect
# darwin's ~104-char sun_path limit. Derive a stable, collision-resistant name
# from TBD_HOME so concurrent isolated runs with different homes don't clash.
TBD_HOME_HASH="$(printf '%s' "$TBD_HOME" | cksum | cut -d' ' -f1)"
export TBD_SOCKET_PATH="${TBD_SOCKET_PATH:-/tmp/tbd-blit-${TBD_HOME_HASH}.sock}"

mkdir -p "$TBD_HOME"

# --- Web bundle path so the app's WKWebView finds the blit client ----------
# BlitWebTerminalView resolves the bundle by (1) TBD_WEB_DIST, (2) bundle
# resource, (3) dev fallback. We are launching the bare binary (no bundle), so
# set TBD_WEB_DIST explicitly to this worktree's freshly built dist.
export TBD_WEB_DIST="$REPO_ROOT/web/terminal/dist"

echo "============================================================"
echo " ISOLATED blit test build"
echo "   TBD_HOME        = $TBD_HOME"
echo "   TBD_SOCKET_PATH = $TBD_SOCKET_PATH"
echo "   TBD_WEB_DIST    = $TBD_WEB_DIST"
echo "   (real ~/tbd is UNTOUCHED)"
echo "============================================================"

# --- Build (Swift + web bundle) --------------------------------------------
[ -f "$HOME/.swiftly/env.sh" ] && . "$HOME/.swiftly/env.sh"
hash -r

echo "Building web bundle..."
if [ -f "$REPO_ROOT/web/terminal/package.json" ] && command -v npm >/dev/null 2>&1; then
    if "$REPO_ROOT/scripts/build-web.sh" 2>&1 | tail -3; then
        :
    else
        echo "  WARNING: web bundle build failed — continuing with existing dist (if any)."
    fi
else
    echo "  Skipping web build (no package.json or npm not found); using existing dist."
fi

echo "Building Swift..."
(cd "$REPO_ROOT" && swift build) 2>&1 | tail -3

# --- Stop ONLY the isolated daemon -----------------------------------------
# NEVER touch ~/tbd/tbdd.pid and NEVER `pkill TBDDaemon` globally — that would
# kill the user's real daemon and any sibling worktree's isolated daemon.
ISO_PIDFILE="$TBD_HOME/tbdd.pid"
if [ -f "$ISO_PIDFILE" ]; then
    iso_pid="$(cat "$ISO_PIDFILE" 2>/dev/null || true)"
    if [ -n "$iso_pid" ]; then
        echo "Stopping isolated daemon (PID $iso_pid)..."
        kill "$iso_pid" 2>/dev/null && sleep 0.5 || true
    fi
fi
# Clean only the isolated runtime files (under TBD_HOME / our socket path).
rm -f "$TBD_SOCKET_PATH" "$ISO_PIDFILE" "$TBD_HOME/port"

# --- Launch the isolated daemon (binary directly, with env) -----------------
echo "Starting isolated daemon..."
ISO_LOG="/tmp/tbdd-blit-test.log"
[ -f "$ISO_LOG" ] && mv "$ISO_LOG" "$ISO_LOG.1"
TBD_HOME="$TBD_HOME" TBD_SOCKET_PATH="$TBD_SOCKET_PATH" TBD_WEB_DIST="$TBD_WEB_DIST" \
    "$BUILD_DIR/TBDDaemon" > "$ISO_LOG" 2>&1 &

# Wait for the isolated socket to appear.
for _ in $(seq 1 30); do
    [ -S "$TBD_SOCKET_PATH" ] && break
    sleep 0.1
done
if [ -S "$TBD_SOCKET_PATH" ]; then
    echo "  Isolated daemon ready (PID $(cat "$ISO_PIDFILE" 2>/dev/null || echo '?')) — log: $ISO_LOG"
else
    echo "  WARNING: isolated daemon socket not found after 3s. Last log lines:"
    tail -20 "$ISO_LOG" || true
fi

# --- Launch the app BINARY directly (NOT via `open`, which strips env) -------
# Launching the bare binary means no .app bundle is present, so deep links and
# some bundle-only APIs are degraded (see header). That is fine for a render
# test: the app will read TBD_HOME/TBD_SOCKET_PATH/TBD_WEB_DIST from this env
# and connect to the ISOLATED daemon + render the blit web client.
echo "Starting isolated app (direct binary launch)..."
APP_LOG="/tmp/tbdapp-blit-test.log"
[ -f "$APP_LOG" ] && mv "$APP_LOG" "$APP_LOG.1"
TBD_HOME="$TBD_HOME" TBD_SOCKET_PATH="$TBD_SOCKET_PATH" TBD_WEB_DIST="$TBD_WEB_DIST" \
    "$BUILD_DIR/TBDApp" > "$APP_LOG" 2>&1 &
APP_PID=$!
sleep 0.5
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "  Isolated app launched (PID $APP_PID) — log: $APP_LOG"
else
    echo "  ERROR: isolated app failed to launch. Last log lines:"
    tail -20 "$APP_LOG" || true
fi

echo "Done. This was the ISOLATED blit test build (TBD_HOME=$TBD_HOME)."
echo "To stop it:   kill \$(cat '$ISO_PIDFILE' 2>/dev/null); pkill -f '$BUILD_DIR/TBDApp'"
