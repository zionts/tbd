import AppKit
import Foundation
import os

private let focusLog = Logger(subsystem: "com.tbd.app", category: "terminal.focus")

/// Weak handle to a terminal's backing NSView for first-responder routing.
///
/// Phase 8: the blit `TBDTerminalWebView` registers itself here on creation
/// (see `BlitWebTerminalView.makeNSView`). Because WebKit nests the actual key
/// view inside the `WKWebView`, `resolvedFocusedTabCloseContext` matches a
/// registered view when the window's first responder is that view OR a
/// descendant of it.
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
        guard let responder = NSApp.keyWindow?.firstResponder as? NSView else {
            return nil
        }
        // WebKit nests the key view inside the WKWebView, so the first responder
        // is usually a descendant of the registered terminal view rather than
        // the view itself. Match on identity OR descendant containment.
        guard let terminalID = terminalFocusTargets.first(where: { entry in
            guard let view = entry.value.view else { return false }
            return responder === view || responder.isDescendant(of: view)
        })?.key else {
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
        guard let terminalID = terminalIDForAutofocus(worktreeID: worktreeID) else {
            focusLog.info("focusTerminalAfterSelectionChange: no autofocus target for worktree \(worktreeID.uuidString.prefix(8), privacy: .public)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let terminalView = self.terminalFocusTargets[terminalID]?.view,
                  terminalView.window != nil
            else {
                // The target terminal's view may not be mounted yet (e.g. a
                // just-created tab). BlitWebTerminalView.makeNSView proactively
                // claims focus on appear, so this miss is benign.
                focusLog.info("focusTerminalAfterSelectionChange: target \(terminalID.uuidString.prefix(8), privacy: .public) not mounted yet")
                return
            }

            // Prefer the blit web view's claimFocus so BOTH AppKit first
            // responder AND blit's hidden-textarea DOM focus are set. Fall back
            // to a plain makeFirstResponder for any non-blit terminal view.
            if let blit = terminalView as? TBDTerminalWebView {
                blit.claimFocus(reason: "selectionChange")
            } else {
                focusLog.info("focusTerminalAfterSelectionChange -> makeFirstResponder \(terminalID.uuidString.prefix(8), privacy: .public)")
                terminalView.window?.makeFirstResponder(terminalView)
            }
            self.focusedTabCloseContext = self.terminalTabCloseContexts[terminalID]
        }
    }
}
