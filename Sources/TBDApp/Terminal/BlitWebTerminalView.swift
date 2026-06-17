import AppKit
import Foundation
import SwiftUI
import TBDShared
import WebKit
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "BlitWebTerminal")

// MARK: - Theme bridge

/// The JSON-serializable theme dict the blit web client reads from
/// `window.__BLIT__.theme`. Field shape is fixed by the Phase 5 web bundle:
/// `bg`/`fg`/`cursor` are `"#rrggbb"` strings, `ansi` is 16 `"#rrggbb"`
/// strings, `font` is a CSS family, `fontSize` is px, `dark` is a bool.
/// Omitted fields fall back to the bundle's dark defaults.
struct BlitTheme: Encodable, Equatable {
    let bg: String
    let fg: String
    let cursor: String
    let ansi: [String]
    let font: String
    let fontSize: Double
    let dark: Bool
}

extension BlitTheme {
    /// Build the web-client theme dict from the app's appearance settings.
    /// Reuses `AppearanceSettings.effectiveScheme` (bundled or user theme,
    /// honoring any live draft override) and the resolved font.
    @MainActor
    static func from(appearance: AppearanceSettings) -> BlitTheme {
        let scheme = appearance.effectiveScheme
        return BlitTheme(
            bg: hex(scheme.background),
            fg: hex(scheme.foreground),
            cursor: hex(scheme.cursor),
            ansi: scheme.ansi.map(hex),
            // The web client renders with a CSS font family. The user's chosen
            // `fontName` is a macOS font name; pass it through with a monospace
            // fallback chain so the client still renders if it isn't a web font.
            font: "\"\(appearance.fontName)\", ui-monospace, Menlo, Monaco, monospace",
            fontSize: Double(appearance.fontSize),
            dark: isDark(scheme.background)
        )
    }

    /// `TerminalRGB` → `#rrggbb` for the web client's theme dict.
    static func hex(_ color: TerminalRGB) -> String {
        color.hexString
    }

    /// Approximate luminance test (same coefficients/shortcut as
    /// `AppearanceSettings.colorFgBg`) used to set the `dark` flag.
    static func isDark(_ bg: TerminalRGB) -> Bool {
        bg.approximateLuminance <= 0.5
    }

    /// JSON for the `window.__BLIT__.theme` object, or `{}` on failure.
    var json: String {
        if let data = try? JSONEncoder().encode(self),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{}"
    }
}

// MARK: - Web bundle resolution

enum BlitWebBundle {
    /// Result of locating the self-contained web bundle.
    struct Resolution {
        /// The `index.html` to load.
        let indexURL: URL
        /// The directory `loadFileURL(_:allowingReadAccessTo:)` is granted read
        /// access to. The bundle is self-contained, so this is just the dist dir.
        let distDir: URL
    }

    /// Resolution order (per Phase 6a spec):
    /// 1. `TBD_WEB_DIST` env var — absolute path to the dist dir.
    /// 2. `Bundle.main` resource subdirectory `blit-web` (production app bundle).
    /// 3. Dev fallback computed from the source-worktree path / repo root:
    ///    `<repo>/web/terminal/dist`.
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Resolution? {
        // 1. Explicit env override.
        if let distPath = environment["TBD_WEB_DIST"], !distPath.isEmpty {
            let distDir = URL(fileURLWithPath: distPath, isDirectory: true)
            let index = distDir.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: index.path) {
                logger.debug("web bundle via TBD_WEB_DIST: \(index.path, privacy: .public)")
                return Resolution(indexURL: index, distDir: distDir)
            }
            logger.error("TBD_WEB_DIST set but no index.html at \(index.path, privacy: .public)")
        }

        // 2. Bundled resource (production .app).
        if let bundled = Bundle.main.url(
            forResource: "index", withExtension: "html", subdirectory: "blit-web"
        ) {
            logger.debug("web bundle via Bundle.main/blit-web: \(bundled.path, privacy: .public)")
            return Resolution(indexURL: bundled, distDir: bundled.deletingLastPathComponent())
        }

        // 3. Dev fallback: <repo>/web/terminal/dist. Prefer the source-worktree
        //    path recorded by restart.sh (also used by StatusBarView); fall back
        //    to walking up from this source file's compile-time location.
        for repoRoot in devRepoRootCandidates() {
            let distDir = repoRoot
                .appendingPathComponent("web/terminal/dist", isDirectory: true)
            let index = distDir.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: index.path) {
                logger.debug("web bundle via dev fallback: \(index.path, privacy: .public)")
                return Resolution(indexURL: index, distDir: distDir)
            }
        }

        logger.error("web bundle not found via TBD_WEB_DIST, Bundle.main/blit-web, or dev fallback")
        return nil
    }

    /// Candidate repo roots for the dev fallback, in priority order.
    private static func devRepoRootCandidates() -> [URL] {
        var candidates: [URL] = []

        // a) Sidecar written into the bundle by scripts/restart.sh.
        let sidecar = Bundle.main.bundleURL
            .appendingPathComponent("Contents/SourceWorktreePath.txt")
        if let raw = try? String(contentsOf: sidecar, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                candidates.append(URL(fileURLWithPath: trimmed, isDirectory: true))
            }
        }

        // b) Legacy in-place launch: parse the repo root out of the exec path
        //    (".../<repo>/.build/debug/TBDApp").
        if let execPath = Bundle.main.executablePath,
           let buildRange = execPath.range(of: "/.build/", options: .backwards) {
            candidates.append(URL(fileURLWithPath: String(execPath[..<buildRange.lowerBound]),
                                  isDirectory: true))
        }

        // c) Compile-time source location: this file lives at
        //    <repo>/Sources/TBDApp/Terminal/BlitWebTerminalView.swift, so the
        //    repo root is four directories up. Works when running the binary
        //    directly from the build tree during development.
        let thisFile = URL(fileURLWithPath: #filePath)
        let fromSource = thisFile
            .deletingLastPathComponent()  // Terminal
            .deletingLastPathComponent()  // TBDApp
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repo root
        candidates.append(fromSource)

        return candidates
    }
}

// MARK: - Focusable WKWebView

/// A `WKWebView` that participates in the AppKit responder chain so keyboard
/// routing, tab-close context, and the focus registry track which terminal the
/// user is interacting with (Phase 8, features 4 + 8).
///
/// Focus path (why typing reaches the blit session)
/// ------------------------------------------------
/// Two independent focus layers must both be satisfied:
///  1. AppKit: this WKWebView must be the window's first responder, or AppKit
///     routes key events away from the web content entirely. We promote it on
///     `mouseDown` and on first appear (`makeNSView`), gated by `allowsFocus`
///     (false for suspended/overlaid panels — background event suppression).
///  2. DOM: blit binds its keydown listener to a hidden `<textarea>` inside the
///     surface, NOT to the document — so keys only flow once that element is the
///     focused DOM node. We focus it via `__TBD_BRIDGE__.focus()` after becoming
///     first responder; blit also self-focuses it on its own click handler.
/// A plain browser "just works" because the document already holds key focus and
/// blit's click handler focuses the textarea; inside an unbundled SPM WKWebView
/// with `drawsBackground=false`, neither promotion is reliable, hence both fixes.
final class TBDTerminalWebView: WKWebView {
    /// Set false for non-visible / inactive terminals so they neither accept
    /// first responder nor handle Cmd-W etc. (background event suppression).
    var allowsFocus: Bool = true
    var onBecomeFirstResponder: (() -> Void)?
    var onCloseTab: (() -> Void)?

    override var acceptsFirstResponder: Bool { allowsFocus }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            onBecomeFirstResponder?()
            // Push DOM focus onto blit's hidden input textarea. AppKit
            // first-responder status alone routes key events into the web
            // content, but the *blit* keyboard listener is bound to that
            // textarea, not the document — so it only sees keys once the
            // textarea is the focused DOM element. (See focus path note below.)
            focusWebContent()
        }
        return ok
    }

    /// A click anywhere in the terminal must (a) make this WKWebView the
    /// window's first responder so AppKit routes keystrokes into the web
    /// content, and (b) focus blit's hidden input textarea so blit's keydown
    /// listener actually fires. WKWebView usually self-promotes on click, but
    /// in this unbundled SPM app with `drawsBackground=false` that promotion is
    /// unreliable; do it explicitly. blit's own click handler also focuses the
    /// textarea, but we call it too so focus lands even on the very first click
    /// (before blit's listeners are guaranteed wired) and on non-canvas hits.
    override func mouseDown(with event: NSEvent) {
        if allowsFocus, window?.firstResponder !== self, !isDescendantFirstResponder() {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
        if allowsFocus { focusWebContent() }
    }

    /// Ask the web client to focus its terminal input element. No-op until the
    /// bridge is installed (the React app calls `installBridge` on mount).
    func focusWebContent() {
        evaluateJavaScript(
            "window.__TBD_BRIDGE__ && window.__TBD_BRIDGE__.focus && window.__TBD_BRIDGE__.focus();",
            completionHandler: nil
        )
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd-W closes the owning tab — but only when this terminal is the
        // first responder, so the leftmost terminal can't steal it from the
        // one the user actually clicked (mirrors the old SwiftTerm guard).
        if window?.firstResponder === self || isDescendantFirstResponder() {
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.type == .keyDown, flags == .command,
               event.charactersIgnoringModifiers?.lowercased() == "w" {
                onCloseTab?()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The actual key view is the WebKit content view nested inside the
    /// WKWebView, so `firstResponder === self` is rarely true; treat a
    /// descendant first responder as "this terminal is focused".
    private func isDescendantFirstResponder() -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }
}

// MARK: - BlitWebTerminalView (NSViewRepresentable)

/// SwiftUI wrapper around a `WKWebView` that renders a single blit terminal via
/// the Phase 5 self-contained web client. Replaces the SwiftTerm-backed
/// `TerminalPanelRepresentable` as the terminal renderer.
///
/// Config is injected before first paint via a `.atDocumentStart` user script
/// that sets `window.__BLIT__ = { wsUrl, passphrase, terminalId, theme,
/// snapshot, isSuspended }`. Live updates (theme/font, active-state) are pushed
/// over the JS bridge (`window.__TBD_BRIDGE__`) without a reload. Inbound web
/// messages (`window.webkit.messageHandlers.tbd`) drive Cmd-click file opens,
/// dead-window recreation, terminal notifications, and focus tracking.
struct BlitWebTerminalView: NSViewRepresentable {
    /// SwiftUI identity for this terminal panel.
    let terminalID: UUID
    /// blit's per-server integer terminal ID. nil when the terminal row has no
    /// blit terminal yet (renders an explanatory message instead of connecting).
    let blitTerminalID: Int?
    /// Loopback TCP port of the worktree's blit gateway. nil until provisioned.
    let gatewayPort: Int?
    /// Passphrase for the gateway handshake. nil until provisioned.
    let gatewayPassphrase: String?
    /// Snapshot of the appearance-derived theme; pushed live on change.
    let theme: BlitTheme
    /// Worktree path used to resolve relative file paths on Cmd-click.
    let worktreePath: String
    /// Captured ANSI scrollback to show while suspended (feature 1).
    let snapshot: String?
    /// True when this terminal is suspended (no live PTY behind it).
    let isSuspended: Bool
    /// Tab-close context registered for focus-aware Cmd-W routing.
    let tabCloseContext: TabCloseContext?
    /// Cmd-click handler: resolves + opens a file path.
    var onFilePathClicked: ((String) -> Void)?
    /// Dead-window handler: recreate the terminal's blit window.
    var onDeadWindow: (() -> Void)?
    /// Terminal notification handler (OSC-777 / bell / title).
    var onTerminalNotification: ((String, String) -> Void)?
    /// Returns true while a SwiftUI overlay covers the terminal — input is then
    /// suppressed so the overlay receives events (mirrors the old behavior).
    var shouldSuppressEvents: @MainActor () -> Bool = { false }

    @EnvironmentObject var appState: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeNSView(context: Context) -> NSView {
        // Resolve the web bundle up front so a missing bundle renders a clear
        // in-view error rather than a blank WebView (or a crash).
        guard let resolution = BlitWebBundle.resolve() else {
            return Self.errorView(
                "Terminal web bundle not found.\n" +
                "Set TBD_WEB_DIST or build web/terminal/dist."
            )
        }

        guard let port = gatewayPort, let blitTerminalID else {
            // The daemon hasn't provisioned a gateway/terminal yet. Show a
            // lightweight placeholder; the panel is recreated (new SwiftUI .id)
            // once these populate.
            return Self.errorView("Waiting for terminal to start…")
        }

        let coordinator = context.coordinator
        coordinator.terminalID = terminalID
        coordinator.worktreePath = worktreePath
        coordinator.onFilePathClicked = onFilePathClicked
        coordinator.onDeadWindow = onDeadWindow
        coordinator.onTerminalNotification = onTerminalNotification
        coordinator.tabCloseContext = tabCloseContext
        coordinator.lastTheme = theme

        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()

        // Inject window.__BLIT__ before any document script runs.
        let bootstrap = Self.bootstrapScript(
            port: port,
            passphrase: gatewayPassphrase ?? "",
            terminalID: blitTerminalID,
            theme: theme,
            snapshot: snapshot,
            isSuspended: isSuspended
        )
        userContentController.addUserScript(
            WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        // The web client posts to window.webkit.messageHandlers.tbd.
        userContentController.add(coordinator, name: "tbd")
        config.userContentController = userContentController

        let webView = TBDTerminalWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: config
        )
        webView.autoresizingMask = [.width, .height]
        // The web client paints its own background; keep the WKWebView itself
        // free of a white flash by matching the theme bg.
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsFocus = !isSuspended
        webView.onCloseTab = { [weak coordinator] in
            coordinator?.handleCloseTab()
        }
        webView.onBecomeFirstResponder = { [weak coordinator] in
            coordinator?.handleBecameFirstResponder()
        }
        coordinator.webView = webView

        logger.debug(
            "loading blit web client terminalId=\(blitTerminalID, privacy: .public) port=\(port, privacy: .public)"
        )
        webView.loadFileURL(resolution.indexURL, allowingReadAccessTo: resolution.distDir)

        // Robust default: a freshly-shown, non-suspended foreground terminal
        // should be interactive without the user having to click first. Once the
        // view is in a window, grab first responder (if nothing else in this
        // window already owns it) and focus the web input. This runs after the
        // current runloop turn so the view is attached to its window.
        if !isSuspended {
            DispatchQueue.main.async { [weak webView] in
                guard let webView, webView.allowsFocus, let window = webView.window else { return }
                let current = window.firstResponder as? NSView
                let alreadyFocused = current === webView || (current?.isDescendant(of: webView) ?? false)
                if !alreadyFocused {
                    window.makeFirstResponder(webView)
                }
            }
        }

        // Register focus + screenshot providers (features 4 + 5).
        appState.registerTerminalView(webView, for: terminalID)
        appState.registerTerminalCloseContext(tabCloseContext, for: terminalID)
        appState.snapshotProviders[terminalID] = { [weak webView] in
            Self.synchronousSnapshot(of: webView)
        }

        return webView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let webView = nsView as? TBDTerminalWebView else { return }
        let coordinator = context.coordinator

        // Keep handler closures current (SwiftUI may recreate the struct).
        coordinator.onFilePathClicked = onFilePathClicked
        coordinator.onDeadWindow = onDeadWindow
        coordinator.onTerminalNotification = onTerminalNotification
        coordinator.tabCloseContext = tabCloseContext
        coordinator.worktreePath = worktreePath

        // Feature 6: push live theme/font changes without a reload.
        if coordinator.lastTheme != theme {
            coordinator.lastTheme = theme
            let js = "window.__TBD_BRIDGE__ && window.__TBD_BRIDGE__.applyTheme(\(Self.jsonString(theme.json)));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // Feature 8: background / overlaid terminals neither focus nor handle
        // input. A suspended terminal has no live PTY; an overlay (transcript,
        // file preview) covering the terminal must receive events itself.
        let suppressed = shouldSuppressEvents()
        let active = !isSuspended && !suppressed
        if webView.allowsFocus != active {
            webView.allowsFocus = active
            // If we just lost the right to focus while holding it, hand first
            // responder back so the covering overlay / sibling can take it.
            if !active, let window = webView.window,
               (window.firstResponder as? NSView)?.isDescendant(of: webView) == true {
                window.makeFirstResponder(nil)
            }
        }
        if coordinator.lastActive != active {
            coordinator.lastActive = active
            let activeJS = "window.__TBD_BRIDGE__ && window.__TBD_BRIDGE__.setActive(\(active ? "true" : "false"));"
            webView.evaluateJavaScript(activeJS, completionHandler: nil)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let appState: AppState
        weak var webView: TBDTerminalWebView?
        var terminalID: UUID?
        var worktreePath: String = ""
        var onFilePathClicked: ((String) -> Void)?
        var onDeadWindow: (() -> Void)?
        var onTerminalNotification: ((String, String) -> Void)?
        var tabCloseContext: TabCloseContext?
        var lastTheme: BlitTheme?
        /// Last active-state pushed to the web client; nil until first push so
        /// the initial state is always sent once.
        var lastActive: Bool?

        init(appState: AppState) {
            self.appState = appState
        }

        /// Tear down registrations and the WK message handler to avoid a
        /// retain cycle / leaked handler when the panel goes away.
        func detach() {
            if let webView, let terminalID {
                appState.unregisterTerminalView(webView, for: terminalID)
                appState.snapshotProviders.removeValue(forKey: terminalID)
            }
            webView?.configuration.userContentController
                .removeScriptMessageHandler(forName: "tbd")
        }

        func handleBecameFirstResponder() {
            guard let context = tabCloseContext else { return }
            appState.focusedTabCloseContext = context
        }

        func handleCloseTab() {
            guard let context = tabCloseContext else { return }
            appState.closeTab(worktreeID: context.worktreeID, tabID: context.tabID)
        }

        // MARK: WKScriptMessageHandler

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // WKScriptMessage and its `body` are main-actor isolated; the
            // delegate callback always arrives on the main thread, so hop onto
            // the main actor before reading the payload.
            MainActor.assumeIsolated {
                guard let body = message.body as? [String: Any],
                      let type = body["type"] as? String else { return }
                self.dispatch(type: type, body: body)
            }
        }

        private func dispatch(type: String, body: [String: Any]) {
            switch type {
            case "ready":
                logger.debug("blit web client ready for terminal \(self.terminalID?.uuidString ?? "nil", privacy: .public)")
            case "openPath":
                if let text = body["text"] as? String,
                   let resolved = resolveFilePath(text) {
                    onFilePathClicked?(resolved)
                }
            case "sessionExited":
                logger.debug("blit session exited for terminal \(self.terminalID?.uuidString ?? "nil", privacy: .public)")
                onDeadWindow?()
            case "notification":
                let title = (body["title"] as? String) ?? ""
                let bodyText = (body["body"] as? String) ?? ""
                onTerminalNotification?(title, bodyText)
            case "focus":
                handleBecameFirstResponder()
            default:
                break
            }
        }

        /// Resolve a clicked token to an existing regular file path. Mirrors the
        /// old SwiftTerm `resolveAsFilePath`: absolute, file://, ~-relative, and
        /// worktree-relative forms, stripping any trailing `:line:col` suffix.
        private func resolveFilePath(_ link: String) -> String? {
            let candidate: String
            if link.hasPrefix("file://~") {
                candidate = NSString(string: String(link.dropFirst("file://".count))).expandingTildeInPath
            } else if link.hasPrefix("file://") {
                guard let path = URL(string: link)?.path, !path.isEmpty else { return nil }
                candidate = path
            } else if link.hasPrefix("~") {
                candidate = NSString(string: link).expandingTildeInPath
            } else if link.hasPrefix("/") {
                candidate = link
            } else if !link.contains("://"), !worktreePath.isEmpty {
                candidate = URL(fileURLWithPath: worktreePath).appendingPathComponent(link).path
            } else {
                return nil
            }
            let pathOnly: String
            if let range = candidate.range(of: ":\\d+(:\\d+)?$", options: .regularExpression) {
                pathOnly = String(candidate[..<range.lowerBound])
            } else {
                pathOnly = candidate
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: pathOnly, isDirectory: &isDir),
                  !isDir.boolValue else { return nil }
            return pathOnly
        }
    }

    // MARK: - Helpers

    /// Builds the `window.__BLIT__` bootstrap injected at document start.
    static func bootstrapScript(
        port: Int,
        passphrase: String,
        terminalID: Int,
        theme: BlitTheme,
        snapshot: String?,
        isSuspended: Bool
    ) -> String {
        // The gateway routes by URL path: `/d/<name>` selects the destination
        // the daemon registered in the gateway's `blit.remotes` file. Connecting
        // to the bare root `/` yields `error:no destination specified` and the
        // client loops forever (verified against blit 0.35.0). See
        // `TBDConstants.blitGatewayDestinationName` / `BlitManager.ensureGateway`.
        let wsURL = "ws://127.0.0.1:\(port)/d/\(TBDConstants.blitGatewayDestinationName)"
        let wsJSON = jsonString(wsURL)
        let passJSON = jsonString(passphrase)
        let snapshotJSON = snapshot.map(jsonString) ?? "null"
        return """
        window.__BLIT__ = {
          wsUrl: \(wsJSON),
          passphrase: \(passJSON),
          terminalId: \(terminalID),
          theme: \(theme.json),
          snapshot: \(snapshotJSON),
          isSuspended: \(isSuspended ? "true" : "false")
        };
        """
    }

    /// Minimal JSON string encoder for embedding into the bootstrap script.
    static func jsonString(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "\"\""
    }

    /// Synchronously capture a thumbnail of the rendered terminal for the
    /// sidebar suspend flow (feature 5). `WKWebView.takeSnapshot` is async, so
    /// we drive it with a short run-loop wait — the call site
    /// (`SidebarContextMenu`) needs the image before it mutates state.
    @MainActor
    static func synchronousSnapshot(of webView: TBDTerminalWebView?) -> NSImage? {
        guard let webView, webView.window != nil, webView.bounds.width > 0 else {
            return nil
        }
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.afterScreenUpdates = false

        var result: NSImage?
        let group = DispatchGroup()
        group.enter()
        webView.takeSnapshot(with: config) { image, error in
            if let error {
                logger.debug("takeSnapshot failed: \(error.localizedDescription, privacy: .public)")
            }
            result = image
            group.leave()
        }
        // Pump the main run loop briefly so the async snapshot completes without
        // deadlocking the main thread (takeSnapshot's completion runs on main).
        let deadline = Date().addingTimeInterval(0.5)
        while result == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return result
    }

    /// A simple text NSView used for error / waiting states.
    private static func errorView(_ message: String) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = NSColor.secondaryLabelColor
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])
        return container
    }
}
