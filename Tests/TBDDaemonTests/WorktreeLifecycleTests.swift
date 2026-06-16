import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Test func testCreateWorktree() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let result = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    #expect(result.status == .active)
    #expect(result.name.contains("-"))
    #expect(result.branch.hasPrefix("tbd/"))
    #expect(FileManager.default.fileExists(atPath: result.path))

    // Verify terminals were created
    let terminals = try await db.terminals.list(worktreeID: result.id)
    #expect(terminals.count == 2)
}

@Test func testCreateWorktreeUsesCodexPrimaryAgentPreference() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    try await db.config.setPrimaryAgentPreference(.codex)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let result = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)

    let terminals = try await db.terminals.list(worktreeID: result.id)
    #expect(terminals.count == 2)
    #expect(terminals.contains { $0.kind == .codex && $0.label == "Codex" })
    #expect(!terminals.contains { $0.kind == .claude || $0.label == "Claude Code" })
}

@Test func testCreateWorktreePersistsPrimaryAgentAsFirstAndActiveTab() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    try await db.config.setPrimaryAgentPreference(.codex)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let result = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
    let terminals = try await db.terminals.list(worktreeID: result.id)
    let primary = try #require(terminals.first)

    #expect(primary.kind == .codex)
    #expect(primary.label == "Codex")
    #expect(try await db.worktrees.getTabOrder(worktreeID: result.id) == terminals.map(\.id))
    #expect(try await db.worktrees.getActiveTabID(worktreeID: result.id) == primary.id)
}

@Test func testCreateWorktreeWithCodexPreferenceDoesNotResolveClaudeProfile() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    try await db.config.setPrimaryAgentPreference(.codex)

    let profile = try await db.modelProfiles.create(name: "Test", kind: .apiKey)
    try await db.config.setDefaultProfileID(profile.id)

    let keychainLookups = LockedInt()
    let resolver = ModelProfileResolver(
        profiles: db.modelProfiles,
        repos: db.repos,
        config: db.config,
        keychain: { id in
            keychainLookups.increment()
            if id == profile.id.uuidString {
                return "sk-ant-api03-FAKETOKEN_value"
            }
            return nil
        }
    )

    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver(),
        modelProfileResolver: resolver
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let result = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)

    let terminals = try await db.terminals.list(worktreeID: result.id)
    #expect(terminals.contains { $0.kind == .codex && $0.profileID == nil })
    #expect(keychainLookups.value == 0)
}

@Test func testCreateWorktreeRepoNotFound() async throws {
    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    await #expect(throws: WorktreeLifecycleError.self) {
        try await lifecycle.createWorktree(repoID: UUID(), skipClaude: true)
    }
}

@Test func testCreateWithExplicitFolderAndBranch() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let result = try await lifecycle.createWorktree(
        repoID: repo.id,
        folder: "my-folder",
        branch: "feat/custom-branch",
        skipClaude: true
    )

    #expect(result.status == .active)
    #expect(result.name == "my-folder")
    #expect(result.branch == "feat/custom-branch")
    #expect(result.path.hasSuffix("/my-folder"))
}

@Test func testCreateWithExplicitDisplayName() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let result = try await lifecycle.createWorktree(
        repoID: repo.id,
        displayName: "My Custom Display Name",
        skipClaude: true
    )

    #expect(result.displayName == "My Custom Display Name")
    // name should be auto-generated, not the displayName
    #expect(result.name != "My Custom Display Name")
}

@Test func testCreateCollisionWithUserFolderFails() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Create a worktree that occupies a branch
    _ = try await lifecycle.createWorktree(
        repoID: repo.id,
        folder: "first-folder",
        branch: "feat/collision",
        skipClaude: true
    )

    // Try to create another worktree with a DIFFERENT folder but same branch.
    // With userSpecifiedFolder=true, the retry should NOT be attempted —
    // it should fail immediately after git worktree add fails (branch exists).
    await #expect(throws: WorktreeLifecycleError.self) {
        try await lifecycle.createWorktree(
            repoID: repo.id,
            folder: "second-folder",
            branch: "feat/collision",
            skipClaude: true
        )
    }
}

@Test func testCreateCollisionWithUserBranchRetries() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Create a worktree that will occupy a branch
    _ = try await lifecycle.createWorktree(
        repoID: repo.id,
        branch: "feat/shared-branch",
        skipClaude: true
    )

    // Create another worktree with the same branch but auto-folder.
    // This should retry with a new folder but keep the user's branch.
    // Since the branch already exists in git, the retry will also fail
    // because git worktree add doesn't allow the same branch in two worktrees.
    // So this should ultimately throw — but importantly it should NOT throw
    // with the "folder" error, it should attempt retry first.
    await #expect(throws: WorktreeLifecycleError.self) {
        try await lifecycle.createWorktree(
            repoID: repo.id,
            branch: "feat/shared-branch",
            skipClaude: true
        )
    }
}

@Test func testArchiveWorktree() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    #expect(FileManager.default.fileExists(atPath: wt.path))

    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let archived = try await db.worktrees.get(id: wt.id)
    #expect(archived?.status == .archived)
    #expect(!FileManager.default.fileExists(atPath: wt.path))

    // Verify terminals were cleaned up
    let terminals = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminals.isEmpty)
}

@Test func testArchiveWorktreeNotFound() async throws {
    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    await #expect(throws: WorktreeLifecycleError.self) {
        try await lifecycle.archiveWorktree(worktreeID: UUID())
    }
}

@Test func testReviveWorktree() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)

    #expect(revived.status == .active)
    #expect(FileManager.default.fileExists(atPath: revived.path))

    // Verify fresh terminals were created
    let terminals = try await db.terminals.list(worktreeID: revived.id)
    #expect(terminals.count == 2)
}

@Test func testReviveActiveWorktreeThrows() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    await #expect(throws: WorktreeLifecycleError.self) {
        try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)
    }
}

@Test func testReviveFailsWhenPathAlreadyExists() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    // Re-create a stray directory where the worktree used to live.
    try FileManager.default.createDirectory(
        atPath: wt.path, withIntermediateDirectories: true
    )
    try "stray".write(
        toFile: (wt.path as NSString).appendingPathComponent("file.txt"),
        atomically: true, encoding: .utf8
    )

    await #expect(throws: WorktreeLifecycleError.self) {
        try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)
    }

    // TODO: add a test for `worktreeAlreadyRegistered` — requires desyncing
    // the on-disk path from git's worktree list, which is awkward to set up.
}

@Test func testArchivePreservesClaudeSessions() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Create worktree with Claude (skipClaude: false creates a session ID)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
    let terminalsBeforeArchive = try await db.terminals.list(worktreeID: wt.id)
    let originalSessionIDs = terminalsBeforeArchive.compactMap { $0.claudeSessionID }
    #expect(!originalSessionIDs.isEmpty, "Should have at least one Claude session")

    // Archive — should save session IDs
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)
    let archived = try await db.worktrees.get(id: wt.id)
    #expect(archived?.archivedClaudeSessions == originalSessionIDs)

    // Terminals should be deleted
    let terminalsAfterArchive = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminalsAfterArchive.isEmpty)

    // Revive — should restore the same Claude session ID
    let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: false)
    let terminalsAfterRevive = try await db.terminals.list(worktreeID: revived.id)
    let revivedSessionIDs = terminalsAfterRevive.compactMap { $0.claudeSessionID }
    #expect(revivedSessionIDs.contains(originalSessionIDs[0]),
            "Revived terminal should reuse the original Claude session ID")

    // archivedClaudeSessions should be cleared after revive
    let revivedWt = try await db.worktrees.get(id: wt.id)
    #expect(revivedWt?.archivedClaudeSessions == nil)
}

@Test func testArchiveWithoutClaudeSessionsDoesNotSaveEmpty() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Create worktree without Claude
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let archived = try await db.worktrees.get(id: wt.id)
    #expect(archived?.archivedClaudeSessions == nil,
            "Should not save empty session list")
}

@Test func testReviveWithArchivedClaudeSessionsPrefersClaudeOverCurrentSetting() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)
    try await db.config.setPrimaryAgentPreference(.codex)

    let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: false)
    let terminals = try await db.terminals.list(worktreeID: revived.id)
    #expect(terminals.contains { $0.kind == .claude && $0.label == "Claude Code" })
}

@Test func testReviveWithoutPriorPrimaryAgentFallsBackToConfiguredPreference() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)
    try await db.config.setPrimaryAgentPreference(.codex)

    let archived = try await db.worktrees.get(id: wt.id)
    #expect(archived?.archivedClaudeSessions == nil)

    let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: false)
    let terminals = try await db.terminals.list(worktreeID: revived.id)
    #expect(terminals.contains { $0.kind == .codex && $0.label == "Codex" })
}

@Test func testArchiveIgnoresCodexSessionMetadata() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    _ = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@codex-1",
        tmuxPaneID: "%codex-1",
        label: "Codex",
        claudeSessionID: "codex-session-id",
        kind: .codex
    )
    _ = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@claude-1",
        tmuxPaneID: "%claude-1",
        label: "Claude Code",
        claudeSessionID: "claude-session-id",
        kind: .claude
    )

    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let archived = try await db.worktrees.get(id: wt.id)
    #expect(archived?.archivedClaudeSessions == ["claude-session-id"])
}

@Test func testReviveWithSkipClaudePreservesSessions() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Create with Claude, archive, then revive with skipClaude
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
    let originalSessions = try await db.terminals.list(worktreeID: wt.id)
        .compactMap { $0.claudeSessionID }
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    _ = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)

    // Sessions should be preserved since Claude wasn't restored
    let revivedWt = try await db.worktrees.get(id: wt.id)
    #expect(revivedWt?.archivedClaudeSessions == originalSessions,
            "skipClaude revive should preserve sessions for later recovery")
}

@Test func testReviveRestoresMultipleClaudeSessions() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Create worktree with Claude
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)

    // Simulate a second Claude terminal added by the user
    let secondSessionID = UUID().uuidString
    let window = try await lifecycle.tmux.createWindow(
        server: wt.tmuxServer, session: "main",
        cwd: wt.path, shellCommand: "echo test"
    )
    _ = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: window.windowID,
        tmuxPaneID: window.paneID,
        label: "claude",
        claudeSessionID: secondSessionID
    )

    let allSessions = try await db.terminals.list(worktreeID: wt.id)
        .compactMap { $0.claudeSessionID }
    #expect(allSessions.count == 2)

    // Archive and revive
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)
    let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: false)

    // Should have 2 setup + 2 claude = but setup only creates once, so:
    // 1 claude (from first session) + 1 setup + 1 extra claude (from second session) = 3
    let terminals = try await db.terminals.list(worktreeID: revived.id)
    let claudeTerminals = terminals.filter { $0.claudeSessionID != nil }
    #expect(claudeTerminals.count == 2,
            "Both Claude sessions should be restored")

    let restoredSessionIDs = Set(claudeTerminals.compactMap { $0.claudeSessionID })
    #expect(restoredSessionIDs.count == 2)
}

@Test func testCreateInjectsTokenWhenResolverProvided() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)

    // Seed an api-key profile row and set it as the global default.
    // (oauth profiles no longer inject a token — they use CLAUDE_CONFIG_DIR.)
    let token = try await db.modelProfiles.create(name: "Test", kind: .apiKey)
    try await db.config.setDefaultProfileID(token.id)

    let secret = "sk-ant-api03-FAKETOKEN_value"
    let resolver = ModelProfileResolver(
        profiles: db.modelProfiles,
        repos: db.repos,
        config: db.config,
        keychain: { id in id == token.id.uuidString ? secret : nil }
    )

    // Recorder captures the dryRun blit `terminal start` args from createWindow.
    let recorded = LifecycleRecordedCommands()
    let tmux = TmuxManager(dryRun: true)
    let blit = BlitManager(dryRun: true, dryRunRecorder: { args in
        recorded.append(args)
    })

    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: tmux,
        blit: blit,
        hooks: HookResolver(),
        modelProfileResolver: resolver
    )

    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)

    // (a) The api-key profile's secret (ANTHROPIC_API_KEY) is SENSITIVE env.
    // Under blit it's written to a 0600 env-file the spawn wrapper sources and
    // deletes, so it must NOT appear anywhere in the recorded argv (including
    // the wrapper body). We still prove a claude spawn happened (the command is
    // in the wrapper body) and that neither the secret VALUE nor its env-var
    // assignment leaks into argv.
    let snap = recorded.snapshot()
    let claudeCall = snap.first { call in
        let body = call.last ?? ""
        return body.contains("claude --session-id")
    }
    #expect(claudeCall != nil, "expected a createWindow call spawning claude")
    let joinedCall = claudeCall?.joined(separator: " ") ?? ""
    #expect(!joinedCall.contains(secret),
            "secret leaked into blit terminal start argv: \(joinedCall)")
    #expect(!joinedCall.contains("ANTHROPIC_API_KEY=\(secret)"),
            "secret env assignment leaked into argv: \(joinedCall)")
    let shellBody = claudeCall?.last ?? ""
    #expect(!shellBody.contains(secret),
            "secret leaked into wrapper body: \(shellBody)")
    #expect(!shellBody.contains("ANTHROPIC_API_KEY"),
            "env var name leaked into wrapper body: \(shellBody)")

    // (b) Persisted terminal row has profileID set to the known token UUID.
    let terminals = try await db.terminals.list(worktreeID: wt.id)
    let claudeTerminal = terminals.first { $0.profileID != nil }
    #expect(claudeTerminal?.profileID == token.id,
            "expected the Claude terminal to persist profileID=\(token.id)")
}

@Test func testWorktreePathStructure() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    // Path should be under the canonical layout (tempDir/.tbd/worktrees/<name>)
    // because makeTestRepo overrides worktreeRoot to <tempDir>/.tbd/worktrees.
    #expect(wt.path.hasPrefix(tempDir.path))
    #expect(wt.path.contains(".tbd/worktrees/"))
    #expect(wt.path.contains(wt.name))
}

// MARK: - Reconcile Tests

/// Alive server + alive windows: no terminals are deleted, window IDs unchanged.
/// (dryRun makes serverExists → true and windowExists → true, so this exercises
/// the "server alive, window alive → keep terminal" branch.)
///
/// This also serves as a regression guard for the dead-window deletion path: any
/// bug that incorrectly triggers dead-window deletion would drop terminals here,
/// because the setup is identical to what a "dead window" scenario looks like
/// before the windowExists check. The dead-window path itself (windowExists → false)
/// requires a non-dryRun integration test against a real tmux server with stale IDs.
@Test func testReconcileAliveTerminalUntouched() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    let terminalsBefore = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminalsBefore.count == 2, "Expected 2 terminals after createWorktree")

    let windowIDsBefore = Set(terminalsBefore.map { $0.tmuxWindowID })

    try await lifecycle.reconcile(repoID: repo.id)

    let terminalsAfter = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminalsAfter.count == 2, "Alive terminals must not be deleted during reconcile")

    // In dryRun mode, serverExists → true → windowExists path is taken.
    // windowExists → true → terminals are kept with their original IDs.
    // In the reboot path, windowIDs would be replaced with mock IDs.
    // So if IDs are unchanged OR updated to mock IDs, we know reconcile ran.
    // The important invariant: terminal COUNT must not drop.
    let windowIDsAfter = Set(terminalsAfter.map { $0.tmuxWindowID })
    #expect(!windowIDsAfter.isEmpty, "Terminal window IDs must be present after reconcile")
    // Since serverExists → true and windowExists → true, the alive-window branch
    // is taken and IDs are NOT replaced (no recreateAfterReboot call).
    #expect(windowIDsAfter == windowIDsBefore, "Window IDs must be unchanged when server and windows are alive")
}

/// Suspended terminals must not be touched during reconcile, regardless of server/window state.
/// dryRun mode exercises the serverAlive=true branch; suspended terminals are skipped
/// before the windowExists check, so this works with dryRun=true.
@Test func testReconcileSuspendedTerminalSkippedOnReboot() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    var terminals = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminals.count == 2)

    // Suspend one terminal — simulate a terminal that was suspended before reboot.
    let suspended = terminals[0]
    let fakeSessionID = UUID().uuidString
    try await db.terminals.setSuspended(id: suspended.id, sessionID: fakeSessionID)

    // Verify suspension was recorded.
    let suspendedBefore = try await db.terminals.get(id: suspended.id)
    #expect(suspendedBefore?.suspendedAt != nil, "Terminal should have suspendedAt set")

    try await lifecycle.reconcile(repoID: repo.id)

    // All terminals must still exist after reconcile.
    terminals = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminals.count == 2, "Suspended terminal must not be deleted during reconcile")

    // The suspended terminal's state must be untouched.
    let suspendedAfter = try await db.terminals.get(id: suspended.id)
    #expect(suspendedAfter?.suspendedAt != nil, "suspendedAt must still be set after reconcile")
    #expect(suspendedAfter?.claudeSessionID == fakeSessionID, "claudeSessionID must be preserved for suspended terminal")
}

/// Server gone path (reboot): in dryRun mode serverExists → true, so this path
/// cannot be directly triggered. Instead, this test seeds a stale windowID and
/// verifies that when the server IS alive (dryRun), the stale window is treated
/// as alive (windowExists → true in dryRun) and NOT deleted.
/// This is the inverse regression guard: ensures dryRun never triggers reboot recreation.
@Test func testReconcileDryRunDoesNotTriggerRebootRecreation() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: BlitManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    // Seed a stale window ID to simulate what happens after a reboot
    // (the DB still has the old window ID, but the tmux server is gone).
    let terminals = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminals.count == 2)
    let terminal = terminals[0]
    let staleWindowID = "@stale-99"
    try await db.terminals.updateTmuxIDs(id: terminal.id, windowID: staleWindowID, paneID: "%stale-99")

    // In dryRun mode, serverExists → true (not the reboot path).
    // windowExists → true for any ID, so the stale window is treated as alive.
    // Result: the terminal record must NOT be deleted (no dead-window deletion).
    try await lifecycle.reconcile(repoID: repo.id)

    let terminalsAfter = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminalsAfter.count == 2, "Terminal with stale window ID must survive when server is alive (dryRun)")

    // The stale window ID should be unchanged (no recreation happened).
    let terminalAfter = terminalsAfter.first { $0.id == terminal.id }
    #expect(terminalAfter?.tmuxWindowID == staleWindowID,
            "dryRun: stale window ID must not be replaced when server reports alive")

    // NOTE: The actual reboot recovery path (serverExists → false → recreateAfterReboot)
    // cannot be tested with dryRun=true. A non-dryRun integration test with a real
    // tmux server would be needed to verify that stale IDs ARE replaced with fresh
    // mock IDs when the server is gone.
}

/// Blit-model replacement for the old tmux "bootstrap kill ordering" regression.
/// The tmux-specific bug (killing the only window destroyed the session) is gone
/// under blit, which has no session concept. The surviving invariant is:
/// `recreateAfterReboot` provisions the (dry-run) blit server and respawns the
/// terminal, updating the row's `blitTerminalID` to the freshly-allocated ID
/// (dry-run createWindow returns incrementing integer IDs as strings). No real
/// server is contacted.
@Test func testRecreateAfterRebootBootstrapKillOrdering() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let recorded = LifecycleRecordedCommands()
    let blit = BlitManager(dryRun: true, dryRunRecorder: { args in recorded.append(args) })
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        blit: blit,
        hooks: HookResolver()
    )

    // Simulate a freshly-rebooted state: DB rows exist but the terminal's
    // in-memory blit state is gone (stale blitTerminalID).
    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id,
        name: "wt",
        branch: "main",
        path: repoDir.path,
        tmuxServer: "tbd-unused"
    )
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "",
        tmuxPaneID: "",
        blitTerminalID: "stale-999"
    )

    // Drive the recovery path. Must not throw.
    try await lifecycle.recreateAfterReboot(terminal: terminal, worktree: wt)

    // The terminal's blit ID must have been replaced with the freshly-allocated
    // dry-run mock ID (an integer-as-string), not the stale value.
    let updated = try await db.terminals.get(id: terminal.id)
    #expect(updated != nil)
    #expect(updated?.blitTerminalID != "stale-999",
            "blitTerminalID must be replaced with a freshly-allocated blit terminal ID")
    #expect(Int(updated?.blitTerminalID ?? "") != nil,
            "dry-run blit createWindow returns an integer ID as a string; got: \(updated?.blitTerminalID ?? "nil")")

    // A blit `terminal start` was recorded (the respawn actually happened).
    let started = recorded.snapshot().contains { $0.contains("terminal") && $0.contains("start") }
    #expect(started, "recreateAfterReboot must issue a blit terminal start")
}

/// Blit-model reconcile: after a restart the server's terminals are rebuilt from
/// the DB. A Claude terminal WITH a `claudeSessionID` whose blit terminal is no
/// longer live (not in `dryRunListWindows`) must be RESPAWNED via
/// `claude --resume <sessionID>` (not deleted), and its row updated with the new
/// blit terminal ID. Covers the "WITH sessionID" branch of the test-both rule.
@Test func testReconcileDeadWindowClaudeTerminalSuspended() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let recorded = LifecycleRecordedCommands()
    // Report NO live terminals so every tracked terminal is treated as gone and
    // rebuilt from the DB (the post-restart path). serverExists is true in
    // dry-run, so we exercise the serverAlive=true, terminal-not-live branch.
    let blit = BlitManager(
        dryRun: true,
        dryRunRecorder: { args in recorded.append(args) },
        dryRunListWindows: { _ in [] }
    )
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), blit: blit, hooks: HookResolver()
    )

    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    // A worktree whose path == the repo path is reported by `git worktree
    // list`, so reconcile will not archive it as missing.
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "wt", branch: "main",
        path: repoDir.path, tmuxServer: "tbd-unused"
    )
    let sessionID = UUID().uuidString
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "", tmuxPaneID: "",
        label: "claude", claudeSessionID: sessionID, kind: .claude,
        blitTerminalID: "stale-claude"
    )

    try await lifecycle.reconcile(repoID: repo.id)

    let after = try await db.terminals.get(id: terminal.id)
    #expect(after != nil, "claude terminal must NOT be deleted — it is rebuilt from the DB")
    #expect(after?.claudeSessionID == sessionID, "session ID must be preserved across rebuild")
    #expect(after?.blitTerminalID != "stale-claude",
            "rebuilt claude terminal must get a fresh blit terminal ID")
    // The rebuild resumes the existing session.
    let bodies = recorded.snapshot()
        .filter { $0.contains("terminal") && $0.contains("start") }
        .compactMap { $0.last }
    #expect(bodies.contains { $0.contains("--resume \(sessionID)") },
            "claude terminal with a session ID must be rebuilt via --resume <sessionID>; got: \(bodies)")
}

/// Blit-model reconcile: a terminal with NO `claudeSessionID` (plain shell)
/// whose blit terminal is gone is also REBUILT from the DB (respawned fresh),
/// NOT deleted — every non-suspended terminal is rebuilt after a restart so the
/// user always sees a live pane. Covers the "WITHOUT sessionID" branch
/// (rebuilt fresh, no `--resume`).
@Test func testReconcileDeadWindowShellTerminalDeleted() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let recorded = LifecycleRecordedCommands()
    let blit = BlitManager(
        dryRun: true,
        dryRunRecorder: { args in recorded.append(args) },
        dryRunListWindows: { _ in [] }
    )
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), blit: blit, hooks: HookResolver()
    )

    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "wt", branch: "main",
        path: repoDir.path, tmuxServer: "tbd-unused"
    )
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "", tmuxPaneID: "",
        blitTerminalID: "stale-shell"
    )

    try await lifecycle.reconcile(repoID: repo.id)

    let after = try await db.terminals.get(id: terminal.id)
    #expect(after != nil, "shell terminal is rebuilt from the DB after restart, not deleted")
    #expect(after?.blitTerminalID != "stale-shell",
            "rebuilt shell terminal must get a fresh blit terminal ID")
    // A fresh shell rebuild carries no claude session, so it must NOT --resume.
    let bodies = recorded.snapshot()
        .filter { $0.contains("terminal") && $0.contains("start") }
        .compactMap { $0.last }
    #expect(!bodies.contains { $0.contains("--resume") },
            "shell terminal (no session) must be rebuilt fresh, never via --resume; got: \(bodies)")
}

/// Blit-model reconcile: a Codex terminal whose blit terminal is gone is rebuilt
/// from the DB (respawned as codex), NOT deleted, and NOT misclassified as a
/// Claude `--resume` even though Codex records its session into the shared
/// claudeSessionID field.
@Test func testReconcileDeadWindowCodexTerminalWithSessionMetadataDeleted() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // recreateAfterReboot's codex branch resolves the global Codex home; isolate
    // it so the test never touches the developer's real ~/.codex.
    let codexHome = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-codex-home-\(UUID().uuidString)")
    setenv("TBD_TEST_CODEX_HOME", codexHome.path, 1)
    defer {
        unsetenv("TBD_TEST_CODEX_HOME")
        try? FileManager.default.removeItem(at: codexHome)
    }

    let db = try TBDDatabase(inMemory: true)
    let recorded = LifecycleRecordedCommands()
    let blit = BlitManager(
        dryRun: true,
        dryRunRecorder: { args in recorded.append(args) },
        dryRunListWindows: { _ in [] }
    )
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), blit: blit, hooks: HookResolver()
    )

    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "wt", branch: "main",
        path: repoDir.path, tmuxServer: "tbd-unused"
    )
    let codexSession = UUID().uuidString
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "", tmuxPaneID: "",
        label: "Codex", claudeSessionID: codexSession, kind: .codex,
        blitTerminalID: "stale-codex"
    )

    try await lifecycle.reconcile(repoID: repo.id)

    let after = try await db.terminals.get(id: terminal.id)
    #expect(after != nil, "codex terminal is rebuilt from the DB after restart, not deleted")
    #expect(after?.blitTerminalID != "stale-codex",
            "rebuilt codex terminal must get a fresh blit terminal ID")
    let bodies = recorded.snapshot()
        .filter { $0.contains("terminal") && $0.contains("start") }
        .compactMap { $0.last }
    #expect(bodies.contains { $0.contains("codex ") },
            "codex terminal must be rebuilt as codex; got: \(bodies)")
    #expect(!bodies.contains { $0.contains("--resume \(codexSession)") },
            "codex terminal must NOT be misclassified as a Claude --resume; got: \(bodies)")
}

// MARK: - Helpers

/// Thread-safe collector for TmuxManager dryRun recorded args.
private final class LifecycleRecordedCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String]] = []

    func append(_ args: [String]) {
        lock.lock(); defer { lock.unlock() }
        commands.append(args)
    }

    func snapshot() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return commands
    }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        storage += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
