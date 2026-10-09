import ArgumentParser
import Foundation
import Testing
@testable import TBDCLI
import TBDShared

@Suite("tbd terminal continue-in-claude")
struct TerminalContinueInClaudeCommandTests {
    private let terminalID = "2D5B06CC-4930-445D-B562-7BF7C1706418"

    @Test("requires the named terminal option")
    func requiresTerminalOption() {
        #expect(throws: (any Error).self) {
            _ = try TerminalContinueInClaude.parse([])
        }
        #expect(throws: (any Error).self) {
            _ = try TerminalContinueInClaude.parse([terminalID])
        }
    }

    @Test("accepts a request that names no account")
    func parsesAutomaticRequest() throws {
        let command = try TerminalContinueInClaude.parse([
            "--terminal", terminalID,
        ])

        #expect(command.terminal == terminalID)
        #expect(command.profile == nil)
        #expect(!command.ambient)
        #expect(!command.json)
    }

    @Test("accepts an explicit ambient-login request")
    func parsesAmbientRequest() throws {
        let command = try TerminalContinueInClaude.parse([
            "--terminal", terminalID, "--ambient",
        ])

        #expect(command.ambient)
        #expect(command.profile == nil)
    }

    @Test("refuses a profile and the ambient login together")
    func refusesProfileWithAmbient() {
        #expect(throws: (any Error).self) {
            _ = try TerminalContinueInClaude.parse([
                "--terminal", terminalID, "--profile", "Work", "--ambient",
            ])
        }
    }

    /// Naming no account asks the daemon to choose as it would for a new
    /// session — balancing included — so the CLI no longer lands on the
    /// ambient login unless asked to.
    @Test("no account named routes through the daemon's choice")
    func paramsRouteThroughTheDaemonsChoice() throws {
        let id = try #require(UUID(uuidString: terminalID))
        let profileID = UUID()

        let automatic = TerminalContinueInClaude.params(
            terminalID: id, profileID: nil, ambient: false)
        #expect(automatic.profileID == nil)
        #expect(automatic.automaticProfile == true)

        let ambient = TerminalContinueInClaude.params(
            terminalID: id, profileID: nil, ambient: true)
        #expect(ambient.profileID == nil)
        #expect(ambient.automaticProfile == false)

        let named = TerminalContinueInClaude.params(
            terminalID: id, profileID: profileID, ambient: false)
        #expect(named.profileID == profileID)
        #expect(named.automaticProfile == false)
    }

    @Test("accepts profile selection and JSON output")
    func parsesProfileAndJSON() throws {
        let command = try TerminalContinueInClaude.parse([
            "--terminal", terminalID,
            "--profile", "Work",
            "--json",
        ])

        #expect(command.terminal == terminalID)
        #expect(command.profile == "Work")
        #expect(command.json)
    }

    @Test("accepts a profile UUID for the shared resolver")
    func parsesProfileUUID() throws {
        let profileID = UUID().uuidString
        let command = try TerminalContinueInClaude.parse([
            "--terminal", terminalID,
            "--profile", profileID,
        ])

        #expect(command.profile == profileID)
    }

    @Test("plain output reports the unchanged row and selected account")
    func rendersReplacementOutcome() {
        let id = UUID(uuidString: terminalID)!
        let terminal = Terminal(
            id: id,
            worktreeID: UUID(),
            tmuxWindowID: "@9",
            tmuxPaneID: "%9",
            claudeSessionID: "claude-session",
            profileID: UUID(),
            kind: .claude)

        let output = TerminalContinueInClaude.plainOutput(
            terminal: terminal,
            accountLabel: "Work")

        #expect(output.contains("Terminal: \(id)"))
        #expect(output.contains("Account:  Work"))
    }
}
