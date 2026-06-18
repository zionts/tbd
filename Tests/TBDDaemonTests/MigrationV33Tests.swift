import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib

@Suite struct MigrationV33Tests {

    @Test func channelMessageHasSenderKindColumn() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let columns = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(channel_message)")
            let names = Set(columns.compactMap { $0["name"] as String? })
            #expect(names.contains("senderKind"))
        }
    }

    @Test func senderKindColumnDefaultsToAgent() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let columns = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(channel_message)")
            let senderKind = columns.first { ($0["name"] as String?) == "senderKind" }
            // SQLite reports column defaults as a literal string including quotes.
            let dflt = senderKind?["dflt_value"] as String?
            #expect(dflt == "'agent'")
        }
    }

    /// A row inserted without a senderKind value (simulating a pre-v33 row that
    /// the migration backfilled) must read back as 'agent'.
    @Test func rowInsertedWithoutSenderKindDefaultsToAgent() async throws {
        let db = try TBDDatabase(inMemory: true)
        let id = UUID().uuidString
        let team = UUID().uuidString
        let sender = UUID().uuidString
        try await db.writerForTests.write { dbConn in
            try dbConn.execute(
                sql: """
                    INSERT INTO channel_message (id, teamID, senderWorktreeID, type, body, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [id, team, sender, "note", "legacy row", Date()]
            )
        }
        try await db.writerForTests.read { dbConn in
            let value = try String.fetchOne(
                dbConn,
                sql: "SELECT senderKind FROM channel_message WHERE id = ?",
                arguments: [id]
            )
            #expect(value == "agent")
        }
    }
}
