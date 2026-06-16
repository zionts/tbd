import AppKit
import Foundation

/// Weak handle to a terminal's backing NSView for first-responder routing.
///
/// TODO(blit 7): with the SwiftTerm `TBDTerminalView` removed, no NSView is
/// registered here yet — the blit `WKWebView` would need to expose a
/// first-responder hook before keyboard focus tracking can be re-wired. The
/// registry stays in place (callers and tab-close routing depend on it) but is
/// currently always empty, so focus resolution falls back to the last
/// explicitly-set `focusedTabCloseContext`.
@MainActor
final class TerminalFocusTarget {
    weak var view: NSView?

    init(_ view: NSView) {
        self.view = view
    }
}

extension AppState {
    func registerTerminalView(_ view: NSView, for terminalID: UUID) {
        terminalFocusTargets[terminalID] = TerminalFocusTarget(view)
    }

    func registerTerminalCloseContext(_ context: TabCloseContext?, for terminalID: UUID) {
        if let context {
            terminalTabCloseContexts[terminalID] = context
        } else {
            terminalTabCloseContexts.removeValue(forKey: terminalID)
        }
    }

    func unregisterTerminalView(_ view: NSView, for terminalID: UUID) {
        guard terminalFocusTargets[terminalID]?.view === view else { return }
        terminalFocusTargets.removeValue(forKey: terminalID)
        terminalTabCloseContexts.removeValue(forKey: terminalID)
    }

    func resolvedFocusedTabCloseContext() -> TabCloseContext? {
        if terminalFocusTargets.isEmpty {
            return focusedTabCloseContext
        }
        guard let terminalView = NSApp.keyWindow?.firstResponder as? NSView else {
            return nil
        }
        guard let terminalID = terminalFocusTargets.first(where: { $0.value.view === terminalView })?.key else {
            return nil
        }
        return terminalTabCloseContexts[terminalID]
    }

    func terminalIDForAutofocus(worktreeID: UUID) -> UUID? {
        guard !historyActiveWorktrees.contains(worktreeID),
              let worktreeTabs = tabs[worktreeID],
              !worktreeTabs.isEmpty
        else {
            return nil
        }

        let rawIndex = activeTabIndices[worktreeID] ?? 0
        let activeIndex = min(max(rawIndex, 0), worktreeTabs.count - 1)
        let activeTab = worktreeTabs[activeIndex]
        let activeLayout = layouts[activeTab.id] ?? .pane(activeTab.content)

        return activeLayout.allTerminalIDs().first
    }

    func focusTerminalAfterSelectionChange(worktreeID: UUID) {
        guard let terminalID = terminalIDForAutofocus(worktreeID: worktreeID) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let terminalView = self.terminalFocusTargets[terminalID]?.view,
                  terminalView.window != nil
            else {
                return
            }

            terminalView.window?.makeFirstResponder(terminalView)
            self.focusedTabCloseContext = self.terminalTabCloseContexts[terminalID]
        }
    }
}
