import AppKit
import Foundation
import SwiftTerm
import SwiftUI
import WebKit
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "BlitWebTerminal")

// MARK: - Theme bridge

/// The JSON-serializable theme dict the blit web client reads from
/// `window.__BLIT__.theme`. Field shape is fixed by the Phase 5 web bundle:
/// `bg`/`fg`/`cursor` are `"#rrggbb"` strings, `ansi` is 16 `"#rrggbb"`
/// strings, `font` is a CSS family, `fontSize` is px, `dark` is a bool.
/// Omitted fields fall back to the bundle's dark defaults.
struct BlitTheme: Encodable {
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

    /// `SwiftTerm.Color` channels are UInt16 on a 0–65535 scale (8-bit values
    /// are stored as `value * 257`). Convert back to 8-bit and format `#rrggbb`.
    static func hex(_ color: SwiftTerm.Color) -> String {
        let r = Int((Double(color.red) / 65535.0 * 255.0).rounded())
        let g = Int((Double(color.green) / 65535.0 * 255.0).rounded())
        let b = Int((Double(color.blue) / 65535.0 * 255.0).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    /// Approximate luminance test (same coefficients/shortcut as
    /// `AppearanceSettings.colorFgBg`) used to set the `dark` flag.
    static func isDark(_ bg: SwiftTerm.Color) -> Bool {
        let r = Double(bg.red) / 65535.0
        let g = Double(bg.green) / 65535.0
        let b = Double(bg.blue) / 65535.0
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) <= 0.5
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

// MARK: - BlitWebTerminalView (NSViewRepresentable)

/// SwiftUI wrapper around a `WKWebView` that renders a single blit terminal via
/// the Phase 5 self-contained web client. Replaces the SwiftTerm-backed
/// `TerminalPanelRepresentable` as the terminal renderer (Phase 6a).
///
/// Config is injected before first paint via a `.atDocumentStart` user script
/// that sets `window.__BLIT__ = { wsUrl, passphrase, terminalId, theme }`. The
/// bundle renders the terminal whose blit `ptyId == terminalId` and shows
/// "Connecting…" until it appears.
struct BlitWebTerminalView: NSViewRepresentable {
    /// blit's per-server integer terminal ID. nil when the terminal row has no
    /// blit terminal yet (renders an explanatory message instead of connecting).
    let blitTerminalID: Int?
    /// Loopback TCP port of the worktree's blit gateway. nil until provisioned.
    let gatewayPort: Int?
    /// Passphrase for the gateway handshake. nil until provisioned.
    let gatewayPassphrase: String?
    /// Snapshot of the appearance-derived theme, captured at view-creation time.
    let theme: BlitTheme

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
            // TODO(blit 6b/7): consider a spinner + retry instead of static text.
            return Self.errorView("Waiting for terminal to start…")
        }

        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()

        // Inject window.__BLIT__ before any document script runs.
        let bootstrap = Self.bootstrapScript(
            port: port,
            passphrase: gatewayPassphrase ?? "",
            terminalID: blitTerminalID,
            theme: theme
        )
        userContentController.addUserScript(
            WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        config.userContentController = userContentController

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: config
        )
        webView.autoresizingMask = [.width, .height]
        // The web client paints its own background; keep the WKWebView itself
        // non-opaque-free of a white flash by matching the theme bg.
        webView.setValue(false, forKey: "drawsBackground")

        logger.debug(
            "loading blit web client terminalId=\(blitTerminalID, privacy: .public) port=\(port, privacy: .public)"
        )
        webView.loadFileURL(resolution.indexURL, allowingReadAccessTo: resolution.distDir)

        // TODO(blit 6b/7): wire WKScriptMessageHandler/postMessage bridges for
        // Cmd-click file-path routing, snapshot display (initial ANSI), focus
        // guards, and shouldSuppressEvents — none are implemented in 6a. The
        // priority here is a live, compiling rendering path.

        return webView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // TODO(blit 6b/7): push live theme/font changes to the web client via
        // postMessage (replaces the SwiftTerm Combine reapply). For 6a the
        // theme is captured at creation; changing it recreates the panel.
    }

    // MARK: - Helpers

    /// Builds the `window.__BLIT__` bootstrap injected at document start.
    static func bootstrapScript(
        port: Int,
        passphrase: String,
        terminalID: Int,
        theme: BlitTheme
    ) -> String {
        let wsURL = "ws://127.0.0.1:\(port)"
        let themeJSON: String
        if let data = try? JSONEncoder().encode(theme),
           let json = String(data: data, encoding: .utf8) {
            themeJSON = json
        } else {
            themeJSON = "{}"
        }
        // JSON-encode the string fields so quotes/backslashes are escaped safely.
        let wsJSON = jsonString(wsURL)
        let passJSON = jsonString(passphrase)
        return """
        window.__BLIT__ = {
          wsUrl: \(wsJSON),
          passphrase: \(passJSON),
          terminalId: \(terminalID),
          theme: \(themeJSON)
        };
        """
    }

    /// Minimal JSON string encoder for embedding into the bootstrap script.
    private static func jsonString(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "\"\""
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
