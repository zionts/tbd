import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct MigrationV32Tests {

    @Test func blitColumnsExist() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let terminalColumns = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(terminal)")
                .compactMap { $0["name"] as String? }
            #expect(terminalColumns.contains("blitTerminalID"))
            #expect(terminalColumns.contains("blitPidfilePath"))

            let worktreeColumns = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(worktree)")
                .compactMap { $0["name"] as String? }
            #expect(worktreeColumns.contains("blitSocket"))
            #expect(worktreeColumns.contains("gatewayPort"))
            #expect(worktreeColumns.contains("gatewayPassphrase"))
        }
    }

    /// A row written through the normal store API (which doesn't set any blit
    /// fields) must decode with the documented defaults: empty string for the
    /// non-optional `blit*` text columns, nil for the nullable ones.
    @Test func preFieldRowDecodesWithDefaults() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v32-repo-\(UUID().uuidString)",
            displayName: "V32",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "w",
            branch: "b",
            path: "/tmp/v32-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-v32"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1"
        )

        // Defaults on the freshly-created in-memory models.
        #expect(wt.blitSocket == "")
        #expect(wt.gatewayPort == nil)
        #expect(wt.gatewayPassphrase == nil)
        #expect(terminal.blitTerminalID == "")
        #expect(terminal.blitPidfilePath == nil)

        // Round-trip through the DB to prove the GRDB record reads the
        // migrated columns and the model decodes them with defaults.
        let fetchedWt = try await db.worktrees.get(id: wt.id)
        #expect(fetchedWt?.blitSocket == "")
        #expect(fetchedWt?.gatewayPort == nil)
        #expect(fetchedWt?.gatewayPassphrase == nil)

        let fetchedTerminal = try await db.terminals.get(id: terminal.id)
        #expect(fetchedTerminal?.blitTerminalID == "")
        #expect(fetchedTerminal?.blitPidfilePath == nil)
    }
}
