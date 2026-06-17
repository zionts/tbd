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
public struct ChannelStore: Sendable {
    let writer: any DatabaseWriter

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
    /// When `sinceID` is supplied, only messages strictly *after* that message
    /// (by the same createdAt/rowid ordering) are returned — the cursor for a
    /// tail/poll loop. An unknown `sinceID` is treated as "from the beginning".
    public func tail(
        teamID: UUID,
        sinceID: String? = nil,
        limit: Int? = nil
    ) async throws -> [ChannelMessage] {
        try await writer.read { db in
            var sql = """
                SELECT * FROM channel_message
                WHERE teamID = ?
                """
            var arguments: [any DatabaseValueConvertible] = [teamID.uuidString]

            if let sinceID,
               let cursor = try Row.fetchOne(
                   db,
                   sql: "SELECT createdAt, rowid FROM channel_message WHERE id = ?",
                   arguments: [sinceID]
               ) {
                let cursorCreatedAt = cursor["createdAt"] as Date
                let cursorRowID = cursor["rowid"] as Int64
                sql += " AND (createdAt > ? OR (createdAt = ? AND rowid > ?))"
                arguments.append(cursorCreatedAt)
                arguments.append(cursorCreatedAt)
                arguments.append(cursorRowID)
            }

            sql += " ORDER BY createdAt ASC, rowid ASC"
            if let limit {
                sql += " LIMIT ?"
                arguments.append(limit)
            }

            return try ChannelMessageRecord
                .fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .map { $0.toModel() }
        }
    }
}
