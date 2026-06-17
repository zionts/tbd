import ArgumentParser
import Foundation
import TBDShared

struct ChannelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "channel",
        abstract: "Post to and tail the shared team coordination channel",
        subcommands: [ChannelPost.self, ChannelTail.self]
    )
}

// MARK: - ExpressibleByArgument conformance for CLI

extension ChannelMessageType: ExpressibleByArgument {}

// MARK: - Shared resolution

/// Resolve the caller's worktree id: explicit `--worktree` (UUID or name) wins,
/// otherwise fall back to the `TBD_WORKTREE_ID` env var set in TBD terminals.
private func resolveChannelWorktree(_ explicit: String?, client: SocketClient) throws -> UUID {
    if let explicit {
        if let id = UUID(uuidString: explicit) {
            return id
        }
        let worktrees: [Worktree] = try client.call(
            method: RPCMethod.worktreeList,
            params: WorktreeListParams(),
            resultType: [Worktree].self
        )
        let matches = worktrees.filter { $0.name == explicit || $0.displayName == explicit }
        guard let match = matches.first else {
            throw CLIError.invalidArgument("No worktree found with name or ID: \(explicit)")
        }
        if matches.count > 1 {
            throw CLIError.invalidArgument("Multiple worktrees match '\(explicit)'. Use the full ID instead.")
        }
        return match.id
    }
    if let envID = ProcessInfo.processInfo.environment["TBD_WORKTREE_ID"],
       let id = UUID(uuidString: envID) {
        return id
    }
    throw CLIError.invalidArgument(
        "No worktree specified and TBD_WORKTREE_ID is not set. Pass --worktree <id>."
    )
}

// MARK: - channel post

struct ChannelPost: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "post",
        abstract: "Post a message to the team channel (sender = TBD_WORKTREE_ID)"
    )

    @Option(name: .long, help: "Message type (start, blocker, pr, done, learning, note)")
    var type: ChannelMessageType = .note

    @Option(name: .long, help: "Sender worktree ID/name (defaults to TBD_WORKTREE_ID)")
    var worktree: String?

    @Argument(help: "Message body")
    var body: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let senderWorktreeID = try resolveChannelWorktree(worktree, client: client)

        let message: ChannelMessage = try client.call(
            method: RPCMethod.channelPost,
            params: ChannelPostParams(senderWorktreeID: senderWorktreeID, type: type, body: body),
            resultType: ChannelMessage.self
        )

        if json {
            printJSON(message)
        } else {
            print("[\(message.type.rawValue)] \(message.body)")
        }
    }
}

// MARK: - channel tail

struct ChannelTail: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tail",
        abstract: "Show the team channel in chronological order"
    )

    @Option(name: .long, help: "Worktree ID/name in the team (defaults to TBD_WORKTREE_ID)")
    var worktree: String?

    @Option(name: .long, help: "Only show messages after this message ID")
    var since: String?

    @Option(name: .long, help: "Max number of messages to return")
    var limit: Int?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveChannelWorktree(worktree, client: client)

        let result: ChannelTailResult = try client.call(
            method: RPCMethod.channelTail,
            params: ChannelTailParams(worktreeID: worktreeID, sinceID: since, limit: limit),
            resultType: ChannelTailResult.self
        )

        if json {
            printJSON(result)
        } else {
            let formatter = ISO8601DateFormatter()
            for message in result.messages {
                let ts = formatter.string(from: message.createdAt)
                let sender = message.senderWorktreeID.uuidString.prefix(8)
                print("\(ts)  [\(message.type.rawValue)]  \(sender)  \(message.body)")
            }
        }
    }
}
