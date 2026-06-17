import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Coverage for the thread-tab restart-rehydration path (orchestration spine
/// review fix). Thread tabs are not daemon-backed, so their identity is persisted
/// locally in `threadTabPaneIDs` and rebuilt on launch via `reconcileThreadTabs`.
///
/// Uses an injected `UserDefaults(suiteName:)` because `threadTabPaneIDs` persists
/// through a `didSet` — `.standard` is the developer's real plist (unbundled
/// executable), so tests must never write there. See the CLAUDE.md isolation rule.
@MainActor
@Suite("Thread tab rehydration")
struct ThreadTabRehydrationTests {
    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "TBDAppTests.ThreadTabRehydration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    @Test("openThreadTab records the pane id for later rehydration")
    func openThreadTabRecordsPaneID() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            let worktreeID = UUID()

            _ = state.openThreadTab(worktreeID: worktreeID)

            let paneIDs = state.threadTabPaneIDs[worktreeID] ?? []
            #expect(paneIDs.count == 1)
            // The tab's content carries the same pane id we persisted.
            if case .thread(let id, let wt) = state.tabs[worktreeID]?.first?.content {
                #expect(id == paneIDs.first)
                #expect(wt == worktreeID)
            } else {
                Issue.record("expected a .thread tab")
            }
        }
    }

    @Test("openThreadTab reuses an existing thread tab (no duplicate)")
    func openThreadTabIsIdempotent() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            let worktreeID = UUID()

            let first = state.openThreadTab(worktreeID: worktreeID)
            let second = state.openThreadTab(worktreeID: worktreeID)

            #expect(first == second)
            #expect(state.threadTabPaneIDs[worktreeID]?.count == 1)
            #expect(state.tabs[worktreeID]?.count == 1)
        }
    }

    @Test("persisted thread tab is rebuilt on a fresh AppState")
    func reconcileRehydratesPersistedThreadTab() {
        withIsolatedDefaults { defaults in
            // Session 1: open a thread tab, capture its pane id.
            let paneID: UUID
            do {
                let state = AppState(userDefaults: defaults)
                _ = state.openThreadTab(worktreeID: UUID())
                paneID = state.threadTabPaneIDs.values.first!.first!
            }

            // Session 2: a brand-new AppState reads the same suite. Its tabs start
            // empty (no daemon list), but reconcileThreadTabs rebuilds the tab.
            let restored = AppState(userDefaults: defaults)
            let worktreeID = restored.threadTabPaneIDs.keys.first!
            #expect(restored.tabs[worktreeID] == nil)

            restored.reconcileThreadTabs(worktreeID: worktreeID)

            let rebuilt = restored.tabs[worktreeID] ?? []
            #expect(rebuilt.count == 1)
            if case .thread(let id, let wt) = rebuilt.first?.content {
                #expect(id == paneID)
                #expect(wt == worktreeID)
            } else {
                Issue.record("expected a rehydrated .thread tab")
            }
        }
    }

    @Test("reconcileThreadTabs does not duplicate an already-present thread tab")
    func reconcileIsIdempotent() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            let worktreeID = UUID()
            _ = state.openThreadTab(worktreeID: worktreeID)

            // Calling reconcile again must not append a second tab.
            state.reconcileThreadTabs(worktreeID: worktreeID)

            #expect(state.tabs[worktreeID]?.count == 1)
        }
    }

    @Test("closing a thread tab clears its persisted identity (no ghost)")
    func closeTabRemovesPersistedThreadID() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            let worktreeID = UUID()
            _ = state.openThreadTab(worktreeID: worktreeID)
            #expect(state.threadTabPaneIDs[worktreeID]?.count == 1)

            state.closeTab(worktreeID: worktreeID, index: 0)

            // The whole entry is dropped once empty, so nothing lingers to
            // rehydrate on the next launch.
            #expect(state.threadTabPaneIDs[worktreeID] == nil)
            #expect((state.tabs[worktreeID] ?? []).isEmpty)
        }
    }

    // MARK: - Post-failure draft restore

    /// `postChannelMessage` now REPORTS failure (returns false) instead of
    /// swallowing it, which is what lets `ThreadPaneView.send()` restore the
    /// user's typed text instead of silently discarding it. With no daemon running
    /// in tests the RPC throws, so a non-empty body must surface as `false`.
    @Test("postChannelMessage reports failure so the draft can be recovered")
    func postChannelMessageReportsFailure() async {
        let state = AppState()
        let ok = await state.postChannelMessage(
            senderWorktreeID: UUID(), type: .note, body: "important text"
        )
        #expect(ok == false)
    }

    @Test("postChannelMessage rejects an empty body without an RPC")
    func postChannelMessageRejectsEmptyBody() async {
        let state = AppState()
        let ok = await state.postChannelMessage(
            senderWorktreeID: UUID(), type: .note, body: "   "
        )
        #expect(ok == false)
    }
}
