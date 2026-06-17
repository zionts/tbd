import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib

@Suite struct MigrationV32Tests {

    @Test func channelMessageTableExistsWithExpectedColumns() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            #expect(try dbConn.tableExists("channel_message"))
            let columns = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(channel_message)")
            let names = Set(columns.compactMap { $0["name"] as String? })
            #expect(names == ["id", "teamID", "senderWorktreeID", "type", "body", "createdAt"])
        }
    }

    @Test func teamCreatedIndexExists() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let exists = try Bool.fetchOne(
                dbConn,
                sql: "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
                arguments: ["idx_channel_message_team_created"]
            ) ?? false
            #expect(exists)
        }
    }
}
