#!/usr/bin/env bash
set -e

# ============================================================================
# TBD ORCHESTRATION-SPINE ISOLATED TEST LAUNCHER
# ============================================================================
#
# Runs THIS branch's TBD (the orchestration-spine build: native channel,
# role/brief, Thread pane + barge-in, waiting-for-user indicator) against a
# THROWAWAY config home so it never touches your real `~/tbd`.
#
# WHY ISOLATION
#   Every TBD path derives from TBD_HOME (state.db, sock, tbdd.pid, port,
#   repos/). By pointing TBD_HOME at /tmp/tbd-spine-test and the socket at a
#   short /tmp path, this launcher runs a fully independent daemon + app with
#   its own database. Your production `~/tbd` daemon, DB, and tmux server are
#   left completely alone — add throwaway repos here, kick the tires on the
#   spine, then `rm -rf` the temp home when you're done.
#
# WHY A .app BUNDLE (not `swift run TBDApp`)
#   A bare SPM executable has no surrounding Info.plist, so AppKit can't give
#   it a proper key window / keyboard focus, and LaunchServices won't route
#   tbd:// deep links to it. We therefore assemble a real .app bundle so the
#   GUI behaves like the production app.
#
# WHY AN ENV-INJECTING WRAPPER inside the bundle
#   macOS `open` strips the caller's environment, so we can't simply
#   `TBD_HOME=… open TBD.app` — the app would boot against `~/tbd`. Instead the
#   bundle's CFBundleExecutable is a generated `launch` shell wrapper that
#   re-exports the isolated env (baked in at assembly time) and then execs the
#   real TBDApp binary. This is the only reliable way to feed env into a
#   GUI-launched, properly-bundled app.
#
#   A DISTINCT CFBundleIdentifier (com.github.cheapsteak.tbd.spinetest) keeps
#   this test bundle from fighting your production TBD over the shared
#   com.github.cheapsteak.tbd identity in LaunchServices / TCC.
#
# WHAT IT DOES NOT DO
#   - Never a global `pkill`. It kills ONLY this isolated app/daemon, matched
#     narrowly by this worktree's binary path and $TBD_HOME/tbdd.pid.
#   - Never touches the real `~/tbd` daemon or its socket.
#
# USAGE
#   scripts/restart-spine-test.sh
#
# STOP IT
#   pkill -f 'TBD-spine-test.app/Contents/MacOS/TBDApp'   # the GUI app
#   kill "$(cat /tmp/tbd-spine-test/tbdd.pid)"            # the daemon
#   rm -rf /tmp/tbd-spine-test                            # the throwaway home
#   (or just re-run this script — it tears down the prior instance first.)
#
# CUSTOM HOME
#   TBD_HOME=/tmp/my-test scripts/restart-spine-test.sh
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build/debug"

# MARK: - Isolated environment
#
# Everything below TBD_HOME is throwaway. The socket lives at a SHORT /tmp path
# (keyed by a checksum of TBD_HOME) because darwin caps a unix socket's
# sun_path at ~104 bytes — a deep TBD_HOME would overflow `$TBD_HOME/sock`.
# TBD_SOCKET_PATH overrides only the socket; all other paths still follow
# TBD_HOME.
TBD_HOME="${TBD_HOME:-/tmp/tbd-spine-test}"
HOME_CKSUM="$(printf '%s' "$TBD_HOME" | cksum | cut -d' ' -f1)"
TBD_SOCKET_PATH="/tmp/tbd-spine-${HOME_CKSUM}.sock"
export TBD_HOME TBD_SOCKET_PATH

mkdir -p "$TBD_HOME"

echo "Isolated TBD spine test"
echo "  TBD_HOME:        $TBD_HOME"
echo "  TBD_SOCKET_PATH: $TBD_SOCKET_PATH"
echo "  (your real ~/tbd is untouched)"

# MARK: - Build

echo "Building..."
t0=$SECONDS
# shellcheck disable=SC1091
. "$HOME/.swiftly/env.sh"
hash -r
(cd "$REPO_ROOT" && swift build) 2>&1 | tail -3
echo "  Build: $((SECONDS - t0))s"

# MARK: - Assemble isolated env-injecting .app bundle
#
# Modeled on the production bundle assembly in scripts/restart.sh, but:
#   - a DISTINCT CFBundleIdentifier so it doesn't fight prod in LaunchServices,
#   - CFBundleExecutable = an env-injecting `launch` wrapper (see header),
#   - the real TBDApp copied in beside it so Bundle.main resolves to the .app.

BUNDLE_DIR="$BUILD_DIR/TBD-spine-test.app"
BUNDLE_MACOS="$BUNDLE_DIR/Contents/MacOS"
BUNDLE_PLIST="$BUNDLE_DIR/Contents/Info.plist"
SOURCE_PLIST="$REPO_ROOT/Resources/TBDApp.Info.plist"

# Rebuild the bundle from scratch each run so the wrapper + copied binary are
# always current (no stale env or stale executable).
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_MACOS"

APP_EXEC_PATH="$(/usr/bin/readlink -f "$BUILD_DIR/TBDApp")"

# Copy (not hard-link) the freshly built TBDApp into the bundle as a sibling of
# the wrapper. A copy keeps the bundle self-contained for the wrapper's
# `exec "$DIR/TBDApp"`; the bundle is reassembled every run so it never goes
# stale.
cp "$APP_EXEC_PATH" "$BUNDLE_MACOS/TBDApp"

# Info.plist: start from the prod plist, then override the bundle identifier and
# point CFBundleExecutable at the `launch` wrapper.
cp "$SOURCE_PLIST" "$BUNDLE_PLIST"
/usr/libexec/PlistBuddy -c \
    "Set :CFBundleIdentifier com.github.cheapsteak.tbd.spinetest" "$BUNDLE_PLIST"
/usr/libexec/PlistBuddy -c \
    "Set :CFBundleExecutable launch" "$BUNDLE_PLIST"

# Generate the env-injecting wrapper. Values are baked in with `printf %q` so
# the regenerated script is correctly quoted regardless of special chars.
WRAPPER="$BUNDLE_MACOS/launch"
{
    printf '#!/bin/bash\n'
    printf '# Auto-generated by restart-spine-test.sh — env-injecting launcher.\n'
    printf '# macOS `open` strips env, so we re-export the isolated config here\n'
    printf '# and then exec the real bundled TBDApp.\n'
    printf 'export TBD_HOME=%q\n' "$TBD_HOME"
    printf 'export TBD_SOCKET_PATH=%q\n' "$TBD_SOCKET_PATH"
    printf 'DIR="$(cd "$(dirname "$0")" && pwd)"\n'
    printf 'exec "$DIR/TBDApp" "$@"\n'
} > "$WRAPPER"
chmod +x "$WRAPPER"

# Ad-hoc sign so macOS treats the bundle as a stable unit. (No /Applications
# install and no TCC dance — this is a throwaway test bundle.)
codesign --force --deep --identifier com.github.cheapsteak.tbd.spinetest \
    --sign - "$BUNDLE_DIR" >/dev/null 2>&1 || true

# MARK: - Kill the PRIOR isolated instance (narrow — never global, never prod)
#
# Match ONLY this test bundle's running app by its exact exec path, and the
# isolated daemon by THIS TBD_HOME's pid file. The real ~/tbd daemon and any
# sibling worktree are never touched.
BUNDLED_EXEC_PATH="$BUNDLE_MACOS/TBDApp"
APP_EXEC_PATTERN="$(printf '%s' "$BUNDLED_EXEC_PATH" | sed 's/[.+*?()\[\]^$|\\]/\\&/g')"

echo "Stopping any prior isolated app..."
pkill -f "^${APP_EXEC_PATTERN}\$" 2>/dev/null && sleep 0.3 || true

echo "Stopping any prior isolated daemon..."
if [ -f "$TBD_HOME/tbdd.pid" ]; then
    pid="$(cat "$TBD_HOME/tbdd.pid")"
    kill "$pid" 2>/dev/null && sleep 0.5 || true
fi
rm -f "$TBD_HOME/sock" "$TBD_HOME/tbdd.pid" "$TBD_HOME/port" "$TBD_SOCKET_PATH"

# MARK: - Launch the isolated daemon
#
# Bare binary (not the bundle) so we can hand it the isolated env directly. It
# reads TBD_HOME / TBD_SOCKET_PATH from its environment and derives every path
# from them.
DAEMON_LOG="$TBD_HOME/tbdd.log"
echo "Starting isolated daemon... (log: $DAEMON_LOG)"
TBD_HOME="$TBD_HOME" TBD_SOCKET_PATH="$TBD_SOCKET_PATH" \
    "$BUILD_DIR/TBDDaemon" > "$DAEMON_LOG" 2>&1 &

for _ in $(seq 1 50); do
    [ -S "$TBD_SOCKET_PATH" ] && break
    sleep 0.1
done
if [ -S "$TBD_SOCKET_PATH" ]; then
    echo "  Daemon ready (PID $(cat "$TBD_HOME/tbdd.pid" 2>/dev/null))"
else
    echo "  WARNING: Daemon socket not found after 5s. Last log lines:"
    tail -20 "$DAEMON_LOG" 2>/dev/null || true
fi

# MARK: - Launch the isolated app (via the env-injecting bundle)

APP_LOG="$TBD_HOME/tbdapp.log"
echo "Starting isolated app..."
open "$BUNDLE_DIR" --stdout "$APP_LOG" --stderr "$APP_LOG"
sleep 0.5
if pgrep -f "^${APP_EXEC_PATTERN}\$" >/dev/null; then
    echo "  App launched (PID $(pgrep -f "^${APP_EXEC_PATTERN}\$" | head -1)) — log: $APP_LOG"
else
    echo "  ERROR: App failed to launch. Last lines of $APP_LOG:"
    tail -20 "$APP_LOG" 2>/dev/null || true
fi

echo
echo "Done. Isolated TBD spine test is running against $TBD_HOME."
echo "To stop:  pkill -f '${BUNDLED_EXEC_PATH}' ; kill \"\$(cat '$TBD_HOME/tbdd.pid')\" ; rm -rf '$TBD_HOME'"
