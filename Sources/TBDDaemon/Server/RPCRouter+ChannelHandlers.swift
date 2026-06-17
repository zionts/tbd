import Foundation
import TBDShared

extension RPCRouter {

    // MARK: - Channel Handlers (orchestration spine Phase A)

    /// Post a message to the sender's team channel, then broadcast it to all
    /// subscribers via the delta layer (mirrors `handleNotify`'s post→broadcast).
    /// The team is the root of the sender's parent+children subtree.
    func handleChannelPost(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ChannelPostParams.self, from: paramsData)

        guard try await db.worktrees.get(id: params.senderWorktreeID) != nil else {
            return RPCResponse(error: "Worktree not found: \(params.senderWorktreeID)")
        }

        let teamID = try await db.worktrees.rootWorktreeID(of: params.senderWorktreeID)

        let message = try await db.channel.post(
            teamID: teamID,
            senderWorktreeID: params.senderWorktreeID,
            type: params.type,
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
