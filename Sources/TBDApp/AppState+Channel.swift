import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Channel")

extension AppState {
    // MARK: - Channel (orchestration spine Phase C)

    /// Open a Thread tab for a worktree's team channel and return the index it
    /// occupies so the caller can select it. A single thread tab per worktree is
    /// the intent: if one already exists we reuse it instead of spawning a
    /// duplicate. The daemon resolves the team root from the worktree id, so the
    /// pane needs only the worktree.
    @discardableResult
    func openThreadTab(worktreeID: UUID) -> Int {
        if let idx = tabs[worktreeID]?.firstIndex(where: {
            if case .thread = $0.content { return true }
            return false
        }) {
            return idx
        }
        let paneID = UUID()
        let tab = Tab(
            id: paneID,
            content: .thread(id: paneID, worktreeID: worktreeID),
            label: nil
        )
        tabs[worktreeID, default: []].append(tab)
        // Persist the thread tab's identity so it can be rehydrated after restart
        // (thread tabs are not daemon-backed). See `reconcileThreadTabs`.
        threadTabPaneIDs[worktreeID, default: []].append(paneID)
        return (tabs[worktreeID]?.count ?? 1) - 1
    }

    /// Apply a broadcast `.channelMessage` delta. v1 broadcasts to ALL
    /// subscribers, so we filter/route by the delta's own `teamID`. Append-only,
    /// deduped by id, kept chronological — mirrors how notes/notifications fold
    /// their deltas into the in-memory store.
    func applyChannelMessageDelta(_ delta: ChannelMessageDelta) {
        let message = ChannelMessage(
            id: delta.messageID,
            teamID: delta.teamID,
            senderWorktreeID: delta.senderWorktreeID,
            type: delta.type,
            body: delta.body,
            createdAt: delta.createdAt
        )
        insertChannelMessages([message], teamID: delta.teamID)
    }

    /// Backfill a team's channel from the daemon. Called when a Thread pane
    /// appears so history is present before the first live delta arrives. The
    /// daemon resolves `worktreeID` to its team root and returns that `teamID`,
    /// which we key on (it may differ from the worktree id for nested members).
    /// Returns the resolved teamID so the pane can track which thread it shows.
    @discardableResult
    func backfillChannel(worktreeID: UUID, limit: Int? = nil) async -> UUID? {
        do {
            let result = try await daemonClient.channelTail(worktreeID: worktreeID, limit: limit)
            insertChannelMessages(result.messages, teamID: result.teamID)
            return result.teamID
        } catch {
            logger.error("Failed to backfill channel for worktree \(worktreeID, privacy: .public): \(error, privacy: .public)")
            handleConnectionError(error)
            return nil
        }
    }

    /// Post a human "barge-in" message into a worktree's team channel. The sender
    /// is the pane's own worktree; the daemon resolves the team root. The
    /// resulting message also returns via the `.channelMessage` delta, so the
    /// dedup in `insertChannelMessages` keeps the optimistic insert from
    /// double-appending.
    ///
    /// Returns `true` on success, `false` if the post failed (empty body, or the
    /// daemon RPC threw). The caller relies on this to decide whether to clear or
    /// restore the composer draft — a swallowed failure would silently discard the
    /// user's typed text.
    @discardableResult
    func postChannelMessage(
        senderWorktreeID: UUID, type: ChannelMessageType = .note, body: String
    ) async -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let message = try await daemonClient.channelPost(
                senderWorktreeID: senderWorktreeID, type: type, body: trimmed
            )
            insertChannelMessages([message], teamID: message.teamID)
            return true
        } catch {
            logger.error("Failed to post channel message: \(error, privacy: .public)")
            handleConnectionError(error)
            return false
        }
    }

    /// Merge messages into a team's ordered, deduped log. Sorted by `createdAt`
    /// then `id` so ties (same-millisecond posts) are stable across clients.
    private func insertChannelMessages(_ incoming: [ChannelMessage], teamID: UUID) {
        guard !incoming.isEmpty else { return }
        var existing = channelMessages[teamID] ?? []
        var seen = Set(existing.map(\.id))
        var changed = false
        for message in incoming where seen.insert(message.id).inserted {
            existing.append(message)
            changed = true
        }
        guard changed else { return }
        existing.sort { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        channelMessages[teamID] = existing
    }
}
