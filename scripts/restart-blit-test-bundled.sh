#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# restart-blit-test-bundled.sh — ISOLATED blit test launcher, REAL .app bundle
# ============================================================================
#
# Phase 9 launcher for the blit-terminal-migration branch. Like
# restart-blit-test.sh it runs THIS worktree's TBDDaemon + TBDApp against a
# completely isolated throwaway home, so it CANNOT touch the user's real
# ~/tbd/state.db, socket, pidfile, port, reposDir, the real running daemon, or
# existing worktrees / live terminal sessions.
#
# WHY A SECOND LAUNCHER (the bare-binary keyboard problem)
# -------------------------------------------------------
# restart-blit-test.sh launches the APP as a BARE BINARY (not a .app bundle)
# because macOS `open` STRIPS environment variables, and the whole isolation
# scheme relies on env (TBD_HOME / TBD_SOCKET_PATH / TBD_WEB_DIST). But a bare
# AppKit/SPM executable has no surrounding Info.plist, so it is a second-class
# GUI citizen: it never becomes a proper "key window". In live blit testing the
# terminal RENDERS but won't take KEYBOARD input — mouse works, keys don't —
# the classic non-bundled "not a key window" symptom. We can't tell whether the
# in-app keyboard bug is a HARNESS artifact (no bundle) or a REAL focus bug
# while testing through the bare-binary harness.
#
# This launcher gives us BOTH: a real .app bundle (proper key window /
# keyboard) AND the isolated env. The trick is an ENV-INJECTING BUNDLE WRAPPER.
#
# THE ENV-INJECTING WRAPPER (how it works)
# ---------------------------------------
# `open Foo.app` strips env, but a bundle's main executable can be a SHELL
# SCRIPT (a script is a valid CFBundleExecutable). So we assemble:
#
#   .build/debug/TBD-blit-test.app/
#     Contents/
#       Info.plist            copy of Resources/TBDApp.Info.plist, but with a
#                             DISTINCT CFBundleIdentifier (so it doesn't fight
#                             the real app's LaunchServices registration) and
#                             CFBundleExecutable = "launch"
#       MacOS/launch          generated #!/bin/bash wrapper: it `export`s the
#                             isolated env (baked in at assembly time, since the
#                             values are known here) then `exec`s the REAL
#                             binary next to it: exec "$DIR/TBDApp" "$@"
#       MacOS/TBDApp          the freshly built .build/debug/TBDApp, copied into
#                             the bundle so the exec'd process's Bundle.main
#                             resolves to THIS .app (Contents/MacOS/TBDApp lives
#                             inside the bundle -> Bundle.main.bundleIdentifier
#                             is non-nil, which the CLAUDE.md bundle guards need)
#       Resources/blit-web/   copy of web/terminal/dist (satisfies
#                             BlitWebTerminalView resolution step 2; the wrapper
#                             also exports TBD_WEB_DIST belt-and-suspenders)
#
# So: `open TBD-blit-test.app` -> LaunchServices spawns Contents/MacOS/launch
# WITHOUT our env -> launch re-injects the isolated env -> execs TBDApp. Because
# the kernel exec target is .../TBD-blit-test.app/Contents/MacOS/TBDApp, the
# process runs as a proper bundled app (key window) AND sees the isolated env.
#
# Bundle.main resolution note: a script-wrapper bundle is fine. `exec` REPLACES
# the launch process image with TBDApp WITHOUT following a symlink (we copy, not
# symlink, the binary in), and CoreFoundation walks up from the running
# executable's real path (.../Contents/MacOS/TBDApp) to find the enclosing
# .app + Info.plist. We verify at runtime that Bundle.main.bundleIdentifier is
# the distinct id we baked in (see the post-launch hint at the end).
#
# The DAEMON needs no window, so it is still launched as the bare binary with
# the env directly (env passes fine to a directly-exec'd child).
#
# Prod restart.sh HARDCODES ~/tbd/ + a /Applications install and re-signs as the
# real com.github.cheapsteak.tbd — never use it for blit testing.
#
# Usage:
#   scripts/restart-blit-test-bundled.sh
#
# Optional environment overrides:
#   TBD_HOME=/some/dir            # isolated home (default /tmp/tbd-blit-test)
#   TBD_SOCKET_PATH=/tmp/x.sock   # isolated socket (default derived from TBD_HOME)
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

# BlitWebTerminalView resolves the web bundle by (1) TBD_WEB_DIST, (2) bundle
# resource blit-web, (3) dev fallback. We bake both (1) into the wrapper and (2)
# into the bundle; set it here so the value is known for the wrapper + daemon.
export TBD_WEB_DIST="$REPO_ROOT/web/terminal/dist"

mkdir -p "$TBD_HOME"

echo "============================================================"
echo " ISOLATED blit test build (REAL .app bundle)"
echo "   TBD_HOME        = $TBD_HOME"
echo "   TBD_SOCKET_PATH = $TBD_SOCKET_PATH"
echo "   TBD_WEB_DIST    = $TBD_WEB_DIST"
echo "   (real ~/tbd is UNTOUCHED)"
echo "============================================================"

# --- Build (web bundle + Swift) --------------------------------------------
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

# --- Bundle layout ----------------------------------------------------------
BUNDLE_DIR="$BUILD_DIR/TBD-blit-test.app"
BUNDLE_CONTENTS="$BUNDLE_DIR/Contents"
BUNDLE_MACOS="$BUNDLE_CONTENTS/MacOS"
BUNDLE_RESOURCES="$BUNDLE_CONTENTS/Resources"
BUNDLE_PLIST="$BUNDLE_CONTENTS/Info.plist"
SOURCE_PLIST="$REPO_ROOT/Resources/TBDApp.Info.plist"
# Distinct id so this isolated test app doesn't fight the real app's
# (com.github.cheapsteak.tbd) LaunchServices / tbd:// registration.
ISO_BUNDLE_ID="com.github.cheapsteak.tbd.blittest"

# --- Stop the PRIOR isolated app AND daemon (never the real ~/tbd) -----------
# restart-blit-test.sh only stopped the daemon, leaving stale isolated app
# windows around — fixed here. We match ONLY this worktree's isolated app:
# either the bundled launcher (Contents/MacOS/launch in OUR bundle) or the bare
# binary at OUR .build/debug/TBDApp. We NEVER do a global `pkill TBDApp`/
# `pkill TBDDaemon`, which would kill the user's real app/daemon or a sibling
# worktree's isolated processes.
echo "Stopping prior isolated app (if any)..."
pkill -f "^${BUNDLE_MACOS}/launch\$" 2>/dev/null && sleep 0.2 || true
pkill -f "^${BUNDLE_MACOS}/TBDApp\$" 2>/dev/null && sleep 0.2 || true
pkill -f "^${BUILD_DIR}/TBDApp\$" 2>/dev/null && sleep 0.2 || true

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

# --- Assemble the isolated .app bundle --------------------------------------
echo "Assembling isolated bundle: $BUNDLE_DIR"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_MACOS" "$BUNDLE_RESOURCES"

# 1. Copy the freshly built binary INTO the bundle (copy, not symlink: `open`/
#    `exec` must keep the kernel exec path inside the .app so Bundle.main
#    resolves to TBD-blit-test.app and Bundle.main.bundleIdentifier is non-nil).
APP_EXEC_PATH="$(/usr/bin/readlink -f "$BUILD_DIR/TBDApp")"
cp "$APP_EXEC_PATH" "$BUNDLE_MACOS/TBDApp"
chmod +x "$BUNDLE_MACOS/TBDApp"

# 2. Generate the env-injecting launch wrapper. macOS `open` strips env, so this
#    script (the bundle's CFBundleExecutable) re-exports the isolated env baked
#    in at assembly time, then execs the real binary next to it. `exec` replaces
#    the process image, so Bundle.main still resolves to this .app.
cat > "$BUNDLE_MACOS/launch" <<WRAPPER
#!/bin/bash
# Auto-generated by scripts/restart-blit-test-bundled.sh — DO NOT EDIT.
# Re-injects the isolated env that macOS \`open\` stripped, then execs the real
# bundled TBDApp binary so the app runs as a proper .app (key window) against
# the isolated home.
DIR="\$(cd "\$(dirname "\$0")" && pwd)"
export TBD_HOME=$(printf '%q' "$TBD_HOME")
export TBD_SOCKET_PATH=$(printf '%q' "$TBD_SOCKET_PATH")
export TBD_WEB_DIST=$(printf '%q' "$TBD_WEB_DIST")
exec "\$DIR/TBDApp" "\$@"
WRAPPER
chmod +x "$BUNDLE_MACOS/launch"

# 3. Info.plist: copy the real one, then override CFBundleIdentifier (distinct,
#    so we don't fight the real app's LaunchServices registration) and
#    CFBundleExecutable (the wrapper). NSAppTransportSecurity /
#    NSAllowsLocalNetworking are preserved by the copy.
cp "$SOURCE_PLIST" "$BUNDLE_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ISO_BUNDLE_ID" "$BUNDLE_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable launch" "$BUNDLE_PLIST"

# 4. Web client into Contents/Resources/blit-web/ (BlitWebTerminalView
#    resolution step 2). Guarded on the dist existing; the wrapper's TBD_WEB_DIST
#    export (step 1 of resolution) covers the case where dist isn't present here.
BUNDLE_WEB="$BUNDLE_RESOURCES/blit-web"
if [ -f "$TBD_WEB_DIST/index.html" ]; then
    rm -rf "$BUNDLE_WEB"
    mkdir -p "$BUNDLE_WEB"
    cp -R "$TBD_WEB_DIST"/. "$BUNDLE_WEB"/
else
    echo "  WARNING: $TBD_WEB_DIST/index.html missing — bundle has no blit-web; relying on wrapper TBD_WEB_DIST."
fi

# 5. Record the source worktree path so the running app can show it (StatusBar)
#    and the dev fallback can find <repo>/web/terminal/dist if needed.
printf '%s' "$REPO_ROOT" > "$BUNDLE_CONTENTS/SourceWorktreePath.txt"

# 6. Ad-hoc sign so macOS treats it as a coherent bundle. We deliberately do NOT
#    install to /Applications or re-sign as the real identity (that's prod
#    restart.sh's job) — an ad-hoc local signature is enough for key-window
#    behavior in dev.
codesign --force --deep --sign - "$BUNDLE_DIR" >/dev/null 2>&1 || \
    echo "  WARNING: ad-hoc codesign failed — app may still launch."

# --- Launch the isolated daemon (bare binary, env passed directly) ----------
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

# --- Launch the APP via `open` on the bundle --------------------------------
# `open` strips env, but the bundle's launch wrapper re-injects the isolated env,
# so the app gets BOTH a real bundle (key window / keyboard) AND the isolated
# home. The app reads TBD_HOME/TBD_SOCKET_PATH/TBD_WEB_DIST from the wrapper's
# exports and connects to the ISOLATED daemon.
echo "Starting isolated app (real bundle via open)..."
APP_LOG="/tmp/tbdapp-blit-test.log"
[ -f "$APP_LOG" ] && mv "$APP_LOG" "$APP_LOG.1"
# -n: new instance even if an app with this id is registered; --stdout/--stderr
# capture the app's output. `open` does not pass env, by design — the wrapper
# handles it.
open -n "$BUNDLE_DIR" --stdout "$APP_LOG" --stderr "$APP_LOG"
sleep 0.5
if pgrep -f "^${BUNDLE_MACOS}/TBDApp\$" >/dev/null; then
    APP_PID="$(pgrep -f "^${BUNDLE_MACOS}/TBDApp\$" | head -1)"
    echo "  Isolated app launched (PID $APP_PID) — log: $APP_LOG"
    echo "  Bundle.main.bundleIdentifier should be: $ISO_BUNDLE_ID"
else
    echo "  ERROR: isolated app failed to launch. Last log lines:"
    tail -20 "$APP_LOG" || true
fi

echo "Done. This was the ISOLATED blit test build (REAL .app bundle, TBD_HOME=$TBD_HOME)."
echo "To stop it:   kill \$(cat '$ISO_PIDFILE' 2>/dev/null); pkill -f '^${BUNDLE_MACOS}/TBDApp\$'"
echo "Focus log (file mirror): $TBD_HOME/focus.log"
