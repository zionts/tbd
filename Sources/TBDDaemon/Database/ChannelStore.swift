import Foundation
import GRDB
import TBDShared

/// GRDB Record type for the `channel_message` table.
struct ChannelMessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "channel_message"

    var id: String
    var teamID: String
    var senderWorktreeID: String
    var type: String
    var body: String
    var createdAt: Date

    init(from message: ChannelMessage) {
        self.id = message.id.uuidString
        self.teamID = message.teamID.uuidString
        self.senderWorktreeID = message.senderWorktreeID.uuidString
        self.type = message.type.rawValue
        self.body = message.body
        self.createdAt = message.createdAt
    }

    func toModel() -> ChannelMessage {
        ChannelMessage(
            id: UUID(uuidString: id)!,
            teamID: UUID(uuidString: teamID)!,
            senderWorktreeID: UUID(uuidString: senderWorktreeID)!,
            type: ChannelMessageType(rawValue: type) ?? .note,
            body: body,
            createdAt: createdAt
        )
    }
}

/// Append-only store for the team coordination channel (orchestration spine
/// Phase A). Intentionally has NO update or delete methods — the channel is an
/// immutable, ordered log.
///
/// ## Trust model (v1)
///
/// Channel authorship (`senderWorktreeID`) and team scoping are **not**
/// authenticated beyond verifying that the sender worktree exists. The trust
/// boundary is the local user: the daemon's control socket is `0o700` and HTTP
/// is loopback-only, so any local process the user runs can post as — or tail —
/// any worktree's team. Provenance tags (`senderWorktreeID`, `type`) are
/// therefore advisory hints within that boundary, not security claims. This is
/// an accepted v1 stance; if the daemon ever accepts non-local clients this must
/// be revisited.
public struct ChannelStore: Sendable {
    let writer: any DatabaseWriter

    /// Default cap on a `tail` read when the caller passes no `limit` — bounds
    /// the catch-up/backfill read so a long-lived thread can't return unbounded.
    static let defaultTailLimit = 200
    /// Hard server-side ceiling on any `tail` `limit`, even an explicit one, so a
    /// hostile or buggy caller can't request an unbounded scan.
    static let maxTailLimit = 1000

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Append a new message to a team's channel and return it.
    public func post(
        teamID: UUID,
        senderWorktreeID: UUID,
        type: ChannelMessageType,
        body: String
    ) async throws -> ChannelMessage {
        try await writer.write { db in
            let message = ChannelMessage(
                teamID: teamID,
                senderWorktreeID: senderWorktreeID,
                type: type,
                body: body
            )
            let record = ChannelMessageRecord(from: message)
            try record.insert(db)
            return message
        }
    }

    /// Return a team's messages in chronological order (createdAt, then rowid
    /// to break ties for messages posted within the same clock tick).
    ///
    /// Two modes, both returning rows oldest-to-newest for display:
    ///
    /// - **Newest-N cap (no `sinceID`):** the thread pane wants the most recent
    ///   `limit` messages, not the oldest. We select the newest N (`ORDER BY …
    ///   DESC LIMIT n`) then reverse to chronological order. When more than N
    ///   messages exist this drops the *oldest*, never the newest.
    /// - **Incremental tail (`sinceID` supplied):** only messages strictly
    ///   *after* that cursor are returned, ascending — the catch-up path for a
    ///   poll loop. This is a forward scan from the cursor, so the limit caps how
    ///   far forward we read (not a newest-N window). An unknown `sinceID` is
    ///   treated as "from the beginning".
    ///
    /// `limit` is clamped server-side to `1...maxTailLimit`; a `nil` limit uses
    /// `defaultTailLimit`. A negative or zero limit (which SQLite would otherwise
    /// treat as unbounded / empty) becomes a bounded read of at least one row.
    public func tail(
        teamID: UUID,
        sinceID: String? = nil,
        limit: Int? = nil
    ) async throws -> [ChannelMessage] {
        let effectiveLimit = min(max(1, limit ?? Self.defaultTailLimit), Self.maxTailLimit)

        return try await writer.read { db in
            var sql = """
                SELECT * FROM channel_message
                WHERE teamID = ?
                """
            var arguments: [any DatabaseValueConvertible] = [teamID.uuidString]

            var cursorMatched = false
            if let sinceID,
               let cursor = try Row.fetchOne(
                   db,
                   sql: "SELECT createdAt, rowid FROM channel_message WHERE id = ?",
                   arguments: [sinceID]
               ) {
                cursorMatched = true
                let cursorCreatedAt = cursor["createdAt"] as Date
                let cursorRowID = cursor["rowid"] as Int64
                sql += " AND (createdAt > ? OR (createdAt = ? AND rowid > ?))"
                arguments.append(cursorCreatedAt)
                arguments.append(cursorCreatedAt)
                arguments.append(cursorRowID)
            }

            arguments.append(effectiveLimit)

            if cursorMatched {
                // Incremental catch-up: forward scan from the cursor, ascending.
                sql += " ORDER BY createdAt ASC, rowid ASC LIMIT ?"
                return try ChannelMessageRecord
                    .fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                    .map { $0.toModel() }
            }

            // Newest-N window: take the most recent `limit` rows, then reverse to
            // chronological (oldest-first) order for display.
            sql += " ORDER BY createdAt DESC, rowid DESC LIMIT ?"
            return try ChannelMessageRecord
                .fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .reversed()
                .map { $0.toModel() }
        }
    }
}
