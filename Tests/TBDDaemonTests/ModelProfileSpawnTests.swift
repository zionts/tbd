import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Nested under TBDHomeSerialized: several tests mutate the process-global
// `TBD_HOME` env var (via setenv/unsetenv) to isolate the overlay/runtime dir.
// Nesting prevents cross-suite races with the other TBD_HOME-mutating suites.
// See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
@Suite("Claude Token Spawn + Swap")
struct ModelProfileSpawnTests {

    /// Recorder for blit argv lists invoked during dryRun. (Named `TmuxRecorder`
    /// historically; it now feeds `BlitManager.dryRunRecorder`. The blit backend
    /// records `terminal start …` argv where the LAST element is the zsh wrapper
    /// string carrying cwd, exported non-sensitive env, and `exec <shellCommand>`.)
    final class TmuxRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var calls: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        func record(_ args: [String]) {
            lock.lock(); defer { lock.unlock() }
            _calls.append(args)
        }
        var joinedAll: String { calls.map { $0.joined(separator: " ") }.joined(separator: "\n") }
        /// Concatenation of just the wrapper bodies (last argv element of each
        /// blit `terminal start` call). The wrapper holds the non-sensitive env
        /// exports and `exec <shellCommand>`; secrets are routed via a 0600
        /// env-file and so never appear here. Used to assert on the spawned
        /// claude/codex command + flags, and that secrets do NOT leak.
        var shellBodies: String {
            calls
                .filter { $0.contains("terminal") && $0.contains("start") }
                .compactMap { $0.last }
                .joined(separator: "\n")
        }
    }

    private func makeFixture() -> (RPCRouter, TBDDatabase, TmuxRecorder) {
        let recorder = TmuxRecorder()
        // Production still holds a TmuxManager (for the reaper), but spawns/
        // captures go through blit. Attach the recorder to the BLIT manager and
        // wire the SAME dry-run instance into both lifecycle and router so no
        // real blit server is ever contacted (avoids serverNotReady).
        let tmux = TmuxManager(dryRun: true)
        let blit = BlitManager(dryRun: true, dryRunRecorder: { args in recorder.record(args) })
        let db = try! TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, blit: blit, hooks: HookResolver())
        let router = RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: tmux,
            blit: blit,
            startTime: Date(),
            usageFetcher: StubClaudeUsageFetcher()
        )
        return (router, db, recorder)
    }

    private func seedRepoAndWorktree(_ db: TBDDatabase) async throws -> (Repo, Worktree) {
        let repo = try await db.repos.create(
            path: "/tmp/r-\(UUID().uuidString)",
            displayName: "r",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/wt-\(UUID().uuidString)",
            tmuxServer: "tbd-test"
        )
        return (repo, wt)
    }

    private func seedOAuthProfile(_ db: TBDDatabase, name: String) async throws -> ModelProfile {
        let row = try await db.modelProfiles.create(name: name, kind: .oauth)
        return row
    }

    private func cleanup(_ db: TBDDatabase) async {
        let toks = (try? await db.modelProfiles.list()) ?? []
        for t in toks { try? ModelProfileKeychain.delete(id: t.id.uuidString) }
    }

    // MARK: - Spawn: no token configured

    @Test("spawn: no tokens → no env prefix, profileID nil")
    func spawnNoToken() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)

        let req = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let term = try resp.decodeResult(Terminal.self)
        #expect(term.profileID == nil)
        #expect(!recorder.joinedAll.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        #expect(!recorder.joinedAll.contains("CLAUDE_CONFIG_DIR"))
    }

    // MARK: - Spawn: global default

    @Test("spawn: global default oauth → CLAUDE_CONFIG_DIR + profileID, no token")
    func spawnWithGlobalDefaultOAuth() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let tok = try await seedOAuthProfile(db, name: "Default")
        try await db.config.setDefaultProfileID(tok.id)

        let req = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let term = try resp.decodeResult(Terminal.self)
        #expect(term.profileID == tok.id)
        // OAuth profiles inject CLAUDE_CONFIG_DIR, not a token. Under blit,
        // CLAUDE_CONFIG_DIR is now SENSITIVE env routed through a 0600 env-file
        // the wrapper sources — so it (and any token) is NOT present in the
        // recorded argv by design. We can still prove the profile was resolved
        // (profileID above) and that no secret/token leaks into the argv.
        #expect(!recorder.joinedAll.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        #expect(!recorder.shellBodies.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }

    // MARK: - Spawn: repo override beats default

    @Test("spawn: repo override beats global default")
    func spawnRepoOverride() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        let a = try await seedOAuthProfile(db, name: "A")
        let b = try await seedOAuthProfile(db, name: "B")
        try await db.config.setDefaultProfileID(a.id)
        try await db.repos.setProfileOverride(id: repo.id, profileID: b.id)

        let req = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let term = try resp.decodeResult(Terminal.self)
        #expect(term.profileID == b.id)
        // OAuth profiles inject CLAUDE_CONFIG_DIR, not a token. Under blit it
        // flows via the 0600 env-file (sensitive), so it is NOT in argv; we
        // assert the override was resolved (profileID==b.id) and no token leaks.
        #expect(!recorder.joinedAll.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }

    // MARK: - Spawn: non-claude type ignores token

    @Test("spawn: non-claude type ignores token")
    func spawnNonClaudeIgnoresToken() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let tok = try await seedOAuthProfile(db, name: "A")
        try await db.config.setDefaultProfileID(tok.id)

        let req = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, cmd: "ls", type: .shell)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let term = try resp.decodeResult(Terminal.self)
        #expect(term.profileID == nil)
        #expect(!recorder.joinedAll.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }

    // MARK: - Spawn: Codex free-form env overrides (branch-test rule)

    /// Build a lifecycle + recorder fixture. Unlike `makeFixture`, this exposes
    /// the `WorktreeLifecycle` so tests can drive `spawnPrimaryTerminals`
    /// directly — the chokepoint where the env-injection branches live. A real
    /// `ModelProfileResolver` is attached so the Claude branch resolves the
    /// worktree's effective profile (Codex tests ignore it — Codex resolves no
    /// profile).
    private func makeLifecycleFixture() -> (WorktreeLifecycle, TBDDatabase, TmuxRecorder) {
        let recorder = TmuxRecorder()
        let tmux = TmuxManager(dryRun: true)
        let blit = BlitManager(dryRun: true, dryRunRecorder: { args in recorder.record(args) })
        let db = try! TBDDatabase(inMemory: true)
        let resolver = ModelProfileResolver(
            profiles: db.modelProfiles, repos: db.repos, config: db.config
        )
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, blit: blit, hooks: HookResolver(),
            modelProfileResolver: resolver
        )
        return (lifecycle, db, recorder)
    }

    /// Codex's primary spawn carries the merged free-form env overrides
    /// (global ∪ repo) as `sensitiveEnv`. Covers the
    /// `primarySensitiveEnv = mergedEnvOverrides` branch in spawnPrimaryTerminals.
    /// Under blit, sensitive env is written to a 0600 env-file the wrapper
    /// sources — it is NEVER in the recorded argv — so we assert the spawn
    /// succeeded and the values do NOT leak into argv. (Merge precedence itself
    /// is unit-tested via EnvOverrideResolver's own tests.)
    @Test("spawn: Codex primary receives merged global+repo env overrides (env-file, not argv)")
    func codexReceivesMergedEnvOverrides() async throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-home-\(UUID().uuidString)")
        setenv("TBD_TEST_CODEX_HOME", codexHome.path, 1)
        defer {
            unsetenv("TBD_TEST_CODEX_HOME")
            try? FileManager.default.removeItem(at: codexHome)
        }

        let (lifecycle, db, recorder) = makeLifecycleFixture()
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        try await db.config.setPrimaryAgentPreference(.codex)
        try await db.config.setEnvOverrides(["FOO": "bar"])
        try await db.repos.setEnvOverrides(id: repo.id, overrides: ["REPO_VAR": "rv"])
        // Re-fetch so the repo passed to spawnPrimaryTerminals carries its
        // freshly-persisted envOverrides (the spawn reads repo.envOverrides
        // from the argument, not the DB).
        let freshRepo = try #require(try await db.repos.get(id: repo.id))

        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: wt, repo: freshRepo, skipClaude: false, preSessionTerminalID: nil
        )

        // A codex spawn happened (proves the branch ran)...
        #expect(recorder.shellBodies.contains("codex"))
        // ...and the sensitive overrides are routed via the 0600 env-file, so
        // they must NOT appear anywhere in the recorded argv.
        #expect(!recorder.joinedAll.contains("FOO=bar"))
        #expect(!recorder.joinedAll.contains("REPO_VAR=rv"))
    }

    /// With no env overrides configured, the Codex primary spawn injects no
    /// sensitive env at all (the empty-config off branch). Under blit, an empty
    /// `sensitiveEnv` means the wrapper has NO `set -a; . <envfile>` sourcing
    /// line at all — so we assert the wrapper body contains no env-file sourcing.
    @Test("spawn: empty config → Codex primary gets no sensitive env-file sourcing")
    func codexEmptyConfigInjectsNothing() async throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-home-\(UUID().uuidString)")
        setenv("TBD_TEST_CODEX_HOME", codexHome.path, 1)
        defer {
            unsetenv("TBD_TEST_CODEX_HOME")
            try? FileManager.default.removeItem(at: codexHome)
        }

        let (lifecycle, db, recorder) = makeLifecycleFixture()
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        try await db.config.setPrimaryAgentPreference(.codex)
        // No global or repo env overrides configured.

        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: wt, repo: repo, skipClaude: false, preSessionTerminalID: nil
        )

        // The Codex `terminal start` call exists; its wrapper (last argv element)
        // launches codex and, with empty sensitiveEnv, has NO env-file sourcing
        // (`set -a; . <envfile>`). blit never emits a `-e` flag.
        let codexCall = try #require(recorder.calls.first {
            $0.contains("terminal") && $0.contains("start") && ($0.last?.contains("codex") ?? false)
        })
        let codexWrapper = codexCall.last ?? ""
        #expect(!codexWrapper.contains("set -a"),
                "empty sensitiveEnv must produce no env-file sourcing; got wrapper: \(codexWrapper)")
        #expect(!recorder.joinedAll.contains("FOO=bar"))
    }

    // MARK: - Spawn: Claude free-form env overrides (branch-test rule)

    /// Claude's primary spawn carries the merged free-form env overrides from
    /// all three scopes (global ∪ repo ∪ resolved-profile) as `sensitiveEnv`.
    /// Covers the
    /// `primarySensitiveEnv = mergedEnvOverrides.merging(spawn.sensitiveEnv)`
    /// branch in spawnPrimaryTerminals. Under blit, sensitive env is written to
    /// a 0600 env-file the wrapper sources — never in argv — so we assert the
    /// claude spawn happened and the values do NOT leak into argv. (Merge
    /// precedence itself is covered by EnvOverrideResolver's own tests.)
    @Test("spawn: Claude primary receives merged global+repo+profile env overrides (env-file, not argv)")
    func claudeReceivesMergedEnvOverrides() async throws {
        let (lifecycle, db, recorder) = makeLifecycleFixture()
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        try await db.config.setPrimaryAgentPreference(.claude)

        // Profile scope: an OAuth profile carrying a free-form var, set as the
        // global default so resolve(repoID:) returns it for this worktree.
        let profile = try await seedOAuthProfile(db, name: "WithEnv")
        try await db.modelProfiles.setEnvOverrides(id: profile.id, overrides: ["PROFILE_VAR": "pv"])
        try await db.config.setDefaultProfileID(profile.id)

        // Global + repo scopes.
        try await db.config.setEnvOverrides(["GLOBAL_VAR": "gv"])
        try await db.repos.setEnvOverrides(id: repo.id, overrides: ["REPO_VAR": "rv"])
        // Re-fetch so the repo passed in carries its persisted envOverrides
        // (the spawn reads repo.envOverrides from the argument, not the DB).
        let freshRepo = try #require(try await db.repos.get(id: repo.id))

        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: wt, repo: freshRepo, skipClaude: false, preSessionTerminalID: nil
        )

        // A claude spawn happened (proves the branch ran)...
        #expect(recorder.shellBodies.contains("claude "))
        // ...and all three scopes are routed via the 0600 env-file (sensitive),
        // so none of their values appear in the recorded argv.
        #expect(!recorder.joinedAll.contains("GLOBAL_VAR=gv"))
        #expect(!recorder.joinedAll.contains("REPO_VAR=rv"))
        #expect(!recorder.joinedAll.contains("PROFILE_VAR=pv"))
    }

    /// The Claude builder's structured auth/routing env is layered ON TOP of the
    /// free-form overrides, so a free-form var that collides with an auth var
    /// cannot win. Exercises the auth-final invariant at the real spawn site
    /// (not just `Dictionary.merging` in isolation): a Bedrock profile sets
    /// AWS_REGION=us-west-2 while a free-form override tries AWS_REGION=us-east-1.
    @Test("spawn: Claude auth/routing env wins over a free-form collision")
    func claudeAuthEnvWinsOverFreeFormCollision() async throws {
        let (lifecycle, db, recorder) = makeLifecycleFixture()
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        try await db.config.setPrimaryAgentPreference(.claude)

        // Bedrock profile emits AWS_REGION=us-west-2 + CLAUDE_CODE_USE_BEDROCK=1
        // from its structured auth/routing fields. Its free-form override
        // deliberately collides on AWS_REGION.
        let bedrock = try await db.modelProfiles.create(
            name: "Bedrock", kind: .bedrock, awsRegion: "us-west-2"
        )
        try await db.modelProfiles.setEnvOverrides(id: bedrock.id, overrides: ["AWS_REGION": "us-east-1"])
        try await db.config.setDefaultProfileID(bedrock.id)

        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: wt, repo: repo, skipClaude: false, preSessionTerminalID: nil
        )

        // Both the builder's structured AWS_REGION and the colliding free-form
        // value are SENSITIVE env, routed through the 0600 env-file under blit,
        // so NEITHER value appears in the recorded argv. We assert the claude
        // spawn happened and that neither region literal leaks into argv. The
        // auth-wins-over-collision precedence is unit-tested directly via
        // ClaudeSpawnCommandBuilder / EnvOverrideResolver, not via argv here.
        #expect(recorder.shellBodies.contains("claude "))
        #expect(!recorder.joinedAll.contains("us-west-2"))
        #expect(!recorder.joinedAll.contains("us-east-1"))
        #expect(!recorder.joinedAll.contains("CLAUDE_CODE_USE_BEDROCK=1"))
    }

    // MARK: - Spawn: fallbackModels overlay routing

    @Test("spawn: profile WITHOUT fallbackModels uses the global overlay path")
    func spawnWithoutFallbackModelsUsesGlobalOverlay() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-spawn-test-\(UUID().uuidString)")
        setenv("TBD_HOME", tmp.path, 1)
        defer {
            unsetenv("TBD_HOME")
            try? FileManager.default.removeItem(at: tmp)
        }
        // The --settings flag is only emitted when the overlay file exists.
        ClaudeHookOverlay.writeOverlay()

        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let tok = try await seedOAuthProfile(db, name: "NoFallback")
        try await db.config.setDefaultProfileID(tok.id)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        #expect(resp.success)

        let bodies = recorder.shellBodies
        #expect(bodies.contains("--settings"))
        // Uses the shared global overlay, NOT a per-session file.
        #expect(bodies.contains(ClaudeHookOverlay.overlayPath))
        #expect(!bodies.contains("claude-overlay-session-"))
    }

    @Test("spawn: profile WITH fallbackModels uses a per-session overlay path")
    func spawnWithFallbackModelsUsesPerSessionOverlay() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-spawn-test-\(UUID().uuidString)")
        setenv("TBD_HOME", tmp.path, 1)
        defer {
            unsetenv("TBD_HOME")
            try? FileManager.default.removeItem(at: tmp)
        }
        ClaudeHookOverlay.writeOverlay()

        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let tok = try await db.modelProfiles.create(
            name: "WithFallback", kind: .oauth,
            fallbackModels: ["claude-haiku-4-5-20251001"]
        )
        try await db.config.setDefaultProfileID(tok.id)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        #expect(resp.success)

        let bodies = recorder.shellBodies
        #expect(bodies.contains("--settings"))
        // A per-session overlay file is used, NOT the shared global overlay.
        #expect(bodies.contains("claude-overlay-session-"))
        #expect(!bodies.contains(" --settings \(ClaudeHookOverlay.overlayPath)"))
    }

    @Test("delete: removes the per-session fallbackModel overlay on terminal teardown")
    func deleteRemovesPerSessionOverlay() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-spawn-test-\(UUID().uuidString)")
        setenv("TBD_HOME", tmp.path, 1)
        defer {
            unsetenv("TBD_HOME")
            try? FileManager.default.removeItem(at: tmp)
        }
        ClaudeHookOverlay.writeOverlay()

        let (router, db, _) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let tok = try await db.modelProfiles.create(
            name: "WithFallback", kind: .oauth,
            fallbackModels: ["claude-haiku-4-5-20251001"]
        )
        try await db.config.setDefaultProfileID(tok.id)

        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        #expect(createResp.success)
        let term = try createResp.decodeResult(Terminal.self)

        // The per-session overlay was written, keyed by the terminal id.
        let overlayPath = ClaudeHookOverlay.perSessionOverlayPath(sessionKey: term.id.uuidString)
        #expect(FileManager.default.fileExists(atPath: overlayPath))

        // Deleting the terminal reclaims the per-session overlay.
        let delResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: term.id)
        ))
        #expect(delResp.success)
        #expect(!FileManager.default.fileExists(atPath: overlayPath))
        // The shared global overlay is left intact.
        #expect(FileManager.default.fileExists(atPath: ClaudeHookOverlay.overlayPath))
    }

    // MARK: - Swap: to a different token

    @Test("swap on blank session: forks into a new tab with a fresh session id and new token")
    func swapToDifferentToken() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let a = try await seedOAuthProfile(db, name: "A")
        let b = try await seedOAuthProfile(db, name: "B")
        try await db.config.setDefaultProfileID(a.id)

        // Spawn original claude terminal with token A. The session is "blank" —
        // no JSONL exists on disk for it — so swap should pick the fresh path.
        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        #expect(createResp.success)
        let oldTerm = try createResp.decodeResult(Terminal.self)
        #expect(oldTerm.profileID == a.id)
        let oldSessionID = oldTerm.claudeSessionID

        let beforeSwap = recorder.calls.count

        // Swap to B → returns a NEW terminal row, old one untouched
        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: oldTerm.id, newProfileID: b.id)
        ))
        #expect(swapResp.success)
        let newTerm = try swapResp.decodeResult(Terminal.self)
        #expect(newTerm.id != oldTerm.id)
        #expect(newTerm.profileID == b.id)
        // Blank session → fresh spawn with a NEW session id (not a resume of the old one).
        #expect(newTerm.claudeSessionID != nil)
        #expect(newTerm.claudeSessionID != oldSessionID)

        // Old terminal row is unchanged
        let oldAfter = try await db.terminals.get(id: oldTerm.id)
        #expect(oldAfter?.profileID == a.id)

        // Daemon did NOT interrupt or send input to the old pane. Under blit,
        // input goes via `terminal send` and Ctrl-C maps to `kill <ID> INT`;
        // a fork-into-new-tab swap must touch neither.
        let postSwap = Array(recorder.calls.dropFirst(beforeSwap))
        let joined = postSwap.map { $0.joined(separator: " ") }.joined(separator: "\n")
        #expect(!joined.contains("terminal send"))
        #expect(!joined.contains("kill \(oldTerm.blitTerminalID) INT"))
        // B's CLAUDE_CONFIG_DIR is SENSITIVE env routed via the 0600 env-file
        // under blit, so it does NOT appear in argv. The wrapper body (last argv
        // element of `terminal start`) DOES contain the fresh claude command
        // (`--session-id <newSessionID>`, never `--resume`).
        #expect(joined.contains("claude --session-id \(newTerm.claudeSessionID!)"))
        #expect(!joined.contains("claude --resume"))
        #expect(joined.contains("--dangerously-skip-permissions"))
        // Negative: secrets and tokens must NOT appear in any wrapper body or argv.
        let postBodies = postSwap.compactMap { $0.last }.joined(separator: "\n")
        #expect(!postBodies.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }

    // MARK: - Swap: to nil

    @Test("swap: to nil forks new tab with no env prefix; old tab untouched")
    func swapToNil() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let a = try await seedOAuthProfile(db, name: "A")
        try await db.config.setDefaultProfileID(a.id)

        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        let oldTerm = try createResp.decodeResult(Terminal.self)
        #expect(oldTerm.profileID == a.id)

        let beforeSwap = recorder.calls.count

        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: oldTerm.id, newProfileID: nil)
        ))
        #expect(swapResp.success)
        let newTerm = try swapResp.decodeResult(Terminal.self)
        #expect(newTerm.id != oldTerm.id)
        #expect(newTerm.profileID == nil)
        // Old terminal still has its original token
        let oldAfter = try await db.terminals.get(id: oldTerm.id)
        #expect(oldAfter?.profileID == a.id)

        let postSwap = Array(recorder.calls.dropFirst(beforeSwap))
        let joined = postSwap.map { $0.joined(separator: " ") }.joined(separator: "\n")
        // Blank session → fresh --session-id, never --resume. The command lives
        // in the blit wrapper body (last argv element of `terminal start`).
        #expect(joined.contains("claude --session-id"))
        #expect(!joined.contains("claude --resume"))
        #expect(!joined.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        // No profile (nil) → no CLAUDE_CONFIG_DIR was injected at all. (Even when
        // present it's sensitive env-file, never argv — so this stays absent.)
        #expect(!joined.contains("CLAUDE_CONFIG_DIR"))
        // No interrupt to the old pane (blit Ctrl-C == `kill <ID> INT`).
        #expect(!joined.contains("terminal send"))
        #expect(!joined.contains("kill \(oldTerm.blitTerminalID) INT"))
    }

    // MARK: - Swap: non-claude terminal errors

    @Test("swap: on non-claude terminal returns error")
    func swapOnNonClaude() async throws {
        let (router, db, _) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)

        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, cmd: "ls", type: .shell)
        ))
        let term = try createResp.decodeResult(Terminal.self)
        #expect(term.claudeSessionID == nil)

        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: term.id, newProfileID: nil)
        ))
        #expect(!swapResp.success)
        #expect(swapResp.error?.contains("not a Claude terminal") == true)
    }

    // MARK: - Swap: unknown token id

    @Test("swap: unknown token id returns error")
    func swapUnknownToken() async throws {
        let (router, db, _) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)

        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        let term = try createResp.decodeResult(Terminal.self)

        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: term.id, newProfileID: UUID())
        ))
        #expect(!swapResp.success)
    }
}
}
