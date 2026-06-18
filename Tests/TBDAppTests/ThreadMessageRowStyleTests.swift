import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Coverage for the "human barge-in is first-class" feature (orchestration spine
/// v2). Two branches matter and both are exercised here:
///
///  1. The pure row-presentation decision (`ThreadMessageRowStyle`): a `.human`
///     post renders as "You" with no type badge and the human (offset) treatment;
///     a `.agent` post keeps the worktree name + a type badge. This is the gating
///     conditional in `ThreadMessageRow`, lifted into a testable struct.
///  2. The delta → message mapping (`applyChannelMessageDelta`): `senderKind`
///     must survive the broadcast round-trip, otherwise a human post arriving via
///     the live delta would render as an agent.
@Suite("Thread message row style (human barge-in)")
struct ThreadMessageRowStyleTests {

    // MARK: - Pure rendering decision

    @Test("human post renders as You with no type badge")
    func humanBranch() {
        let style = ThreadMessageRowStyle(senderKind: .human, senderName: "Child — worker")
        #expect(style.isHuman == true)
        #expect(style.authorLabel == "You")
        #expect(style.showsTypeBadge == false)
    }

    @Test("agent post keeps the worktree name and a type badge")
    func agentBranch() {
        let style = ThreadMessageRowStyle(senderKind: .agent, senderName: "Child — worker")
        #expect(style.isHuman == false)
        #expect(style.authorLabel == "Child — worker")
        #expect(style.showsTypeBadge == true)
    }

    @Test("human label ignores the resolved sender name entirely")
    func humanLabelIsAlwaysYou() {
        // Even with a known worktree name, a human post is attributed to "You" —
        // this is the core of the bug fix (human posts were indistinguishable
        // from the worktree's agent).
        let style = ThreadMessageRowStyle(senderKind: .human, senderName: "main")
        #expect(style.authorLabel == "You")
    }

    // MARK: - Delta mapping preserves senderKind

    @MainActor
    @Test("applyChannelMessageDelta preserves a human senderKind")
    func deltaPreservesHumanSenderKind() {
        let suiteName = "TBDAppTests.RowStyle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(userDefaults: defaults)
        let teamID = UUID()
        let delta = ChannelMessageDelta(
            messageID: UUID(),
            teamID: teamID,
            senderWorktreeID: UUID(),
            type: .note,
            senderKind: .human,
            body: "jumping in",
            createdAt: Date()
        )

        state.applyChannelMessageDelta(delta)

        let stored = state.channelMessages[teamID] ?? []
        #expect(stored.count == 1)
        #expect(stored.first?.senderKind == .human)
    }

    @MainActor
    @Test("applyChannelMessageDelta preserves an agent senderKind")
    func deltaPreservesAgentSenderKind() {
        let suiteName = "TBDAppTests.RowStyle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(userDefaults: defaults)
        let teamID = UUID()
        let delta = ChannelMessageDelta(
            messageID: UUID(),
            teamID: teamID,
            senderWorktreeID: UUID(),
            type: .blocker,
            senderKind: .agent,
            body: "blocked on X",
            createdAt: Date()
        )

        state.applyChannelMessageDelta(delta)

        let stored = state.channelMessages[teamID] ?? []
        #expect(stored.count == 1)
        #expect(stored.first?.senderKind == .agent)
    }
}
