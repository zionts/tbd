import SwiftUI
import AppKit
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "TerminalPanel")

// MARK: - TerminalPanelView

/// SwiftUI view that hosts the blit WebView terminal renderer and, for
/// terminals pinned to a proxy profile (`baseURL != nil`), shows a one-shot
/// proxy-unreachable banner driven by a TCP-connect health probe.
///
/// Phase 6b: the SwiftTerm-backed `TerminalPanelRepresentable` and the tmux
/// app bridge that drove it have been removed. The blit gateway WebView
/// (`BlitWebTerminalView`) is now the only renderer.
struct TerminalPanelView: View {
    let terminalID: UUID
    // MARK: - blit gateway wiring (Phase 6a)
    // The WKWebView renderer connects to the worktree's per-repo blit gateway
    // at ws://127.0.0.1:<gatewayPort> (passphrase auth) and renders the blit
    // terminal whose integer id == `blitTerminalID`. These are populated from
    // the Worktree (gateway info) + Terminal (blit id) at the call site. They
    // default to "unprovisioned" so the panel renders a waiting state until the
    // daemon provisions a gateway/terminal.
    var blitTerminalID: Int? = nil
    var gatewayPort: Int? = nil
    var gatewayPassphrase: String? = nil
    var tabCloseContext: TabCloseContext? = nil
    var worktreePath: String = ""
    var remoteURL: String?
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var appearance: AppearanceSettings

    @State private var proxyWarning: String?
    @State private var didProbe = false

    /// Profile id pinned to this terminal (if any). Used as the `.task` id so
    /// the probe re-fires once AppState populates. `nil` while AppState hasn't
    /// loaded the terminal yet — the probe just returns without consuming its
    /// one-shot gate.
    private var pinnedProfileID: UUID? {
        appState.terminals.values.flatMap({ $0 })
            .first(where: { $0.id == terminalID })?.profileID
    }

    var body: some View {
        VStack(spacing: 0) {
            if let warning = proxyWarning,
               !appState.dismissedProxyWarnings.contains(terminalID) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(warning).font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        appState.dismissedProxyWarnings.insert(terminalID)
                    }
                        .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.yellow.opacity(0.2))
            }
            // Phase 6a/6b: render the terminal via the WKWebView blit web client.
            //
            // TODO(blit 7): snapshot display (initial ANSI for suspended
            // terminals), Cmd-click file-path routing, dead-window recreation,
            // OSC-777 notifications, and SwiftUI-overlay event suppression are
            // not yet bridged into the web client — they were stubbed in 6a and
            // the SwiftTerm code paths that implemented them were removed in 6b.
            BlitWebTerminalView(
                blitTerminalID: blitTerminalID,
                gatewayPort: gatewayPort,
                gatewayPassphrase: gatewayPassphrase,
                theme: BlitTheme.from(appearance: appearance)
            )
        }
        .task(id: pinnedProfileID) {
            await maybeProbeProxy()
        }
    }

    @MainActor
    private func maybeProbeProxy() async {
        if didProbe { return }

        // Look up the pinned profile for this terminal. Only proxy profiles
        // (baseURL != nil) get probed — Claude-direct has nothing to be
        // unreachable. If the lookup fails (AppState hasn't populated yet),
        // return WITHOUT setting `didProbe` so a later `.task` fire — once
        // `pinnedProfileID` settles — gets another chance.
        guard let terminal = appState.terminals.values.flatMap({ $0 })
            .first(where: { $0.id == terminalID }),
              let profileID = terminal.profileID,
              let profile = appState.modelProfiles
                  .first(where: { $0.profile.id == profileID })?.profile,
              let baseURL = profile.baseURL, !baseURL.isEmpty
        else {
            return
        }

        didProbe = true   // gate further attempts only once we actually probe

        try? await Task.sleep(nanoseconds: 500_000_000)
        let result = await appState.healthCheckProfile(baseURL: baseURL)
        if !result.reachable {
            proxyWarning = "Proxy unreachable at \(baseURL). Is your local proxy running?"
            logger.debug("proxy unreachable for terminal \(terminalID, privacy: .public) base=\(baseURL, privacy: .public) detail=\(result.detail ?? "nil", privacy: .public)")
        }
    }
}
