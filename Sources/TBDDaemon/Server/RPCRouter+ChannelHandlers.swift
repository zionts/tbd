import Foundation
import TBDShared

extension RPCRouter {

    // MARK: - Channel Handlers (orchestration spine Phase A)

    /// Max byte length of a channel message body. The channel is append-only
    /// (no delete/edit) and every body is broadcast to all team subscribers, so
    /// an unbounded body is both a permanent storage leak and a broadcast-amp
    /// vector. 16 KiB comfortably fits a long status update or a PR summary.
    static let maxChannelBodyBytes = 16 * 1024

    /// Post a message to the sender's team channel, then broadcast it to all
    /// subscribers via the delta layer (mirrors `handleNotify`'s post→broadcast).
    /// The team is the root of the sender's parent+children subtree.
    ///
    /// Authorship/team scoping are local-trust only — see `ChannelStore`'s
    /// type-level doc comment for the v1 trust model.
    func handleChannelPost(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ChannelPostParams.self, from: paramsData)

        guard try await db.worktrees.get(id: params.senderWorktreeID) != nil else {
            return RPCResponse(error: "Worktree not found: \(params.senderWorktreeID)")
        }

        // Reject (don't truncate) an over-cap body: silent truncation on an
        // append-only, broadcast log would corrupt the sender's intent.
        let bodyByteCount = params.body.utf8.count
        guard bodyByteCount <= Self.maxChannelBodyBytes else {
            return RPCResponse(
                error: "Channel message body too large: \(bodyByteCount) bytes "
                    + "(max \(Self.maxChannelBodyBytes))")
        }

        let teamID = try await db.worktrees.rootWorktreeID(of: params.senderWorktreeID)

        let message = try await db.channel.post(
            teamID: teamID,
            senderWorktreeID: params.senderWorktreeID,
            type: params.type,
            senderKind: params.senderKind,
            body: params.body
        )

        subscriptions.broadcast(delta: .channelMessage(ChannelMessageDelta(from: message)))

        return try RPCResponse(result: message)
    }

    /// Return a team's channel messages in chronological order. `worktreeID` is
    /// resolved to the team root so any member can tail the shared thread.
    func handleChannelTail(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ChannelTailParams.self, from: paramsData)

        guard try await db.worktrees.get(id: params.worktreeID) != nil else {
            return RPCResponse(error: "Worktree not found: \(params.worktreeID)")
        }

        let teamID = try await db.worktrees.rootWorktreeID(of: params.worktreeID)
        let messages = try await db.channel.tail(
            teamID: teamID,
            sinceID: params.sinceID,
            limit: params.limit
        )

        return try RPCResponse(result: ChannelTailResult(teamID: teamID, messages: messages))
    }
}
