import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "reconcile")

extension WorktreeLifecycle {
    // MARK: - Git Status

    /// Recompute conflict status for all active worktrees in a repo.
    /// Also detects branch name changes (e.g., `git checkout -b` inside a worktree).
    /// Runs git checks concurrently and updates the DB + broadcasts deltas.
    public func refreshGitStatuses(repoID: UUID) async {
        guard let repo = try? await db.repos.get(id: repoID) else { return }
        var worktrees = (try? await db.worktrees.list(repoID: repoID, status: .active)) ?? []

        // Sync branch names: one `git worktree list` call gives us
        // the current branch for every worktree — update DB if changed.
        if let gitWorktrees = try? await git.worktreeList(repoPath: repo.path) {
            let branchByPath = Dictionary(gitWorktrees.map { ($0.path, $0.branch) }, uniquingKeysWith: { _, b in b })
            for (i, wt) in worktrees.enumerated() {
                if let gitBranch = branchByPath[wt.path], gitBranch != wt.branch {
                    try? await db.worktrees.updateBranch(id: wt.id, branch: gitBranch)
                    worktrees[i].branch = gitBranch  // use updated branch for conflict check below
                }
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for wt in worktrees {
                group.addTask {
                    guard let newHasConflicts = await self.checkHasConflicts(
                        repoPath: repo.path,
                        defaultBranch: repo.defaultBranch,
                        branch: wt.branch
                    ), newHasConflicts != wt.hasConflicts else { return }
                    try? await self.db.worktrees.updateHasConflicts(id: wt.id, hasConflicts: newHasConflicts)
                    self.subscriptions?.broadcast(delta: .worktreeConflictsChanged(
                        WorktreeConflictDelta(worktreeID: wt.id, hasConflicts: newHasConflicts)
                    ))
                }
            }
        }
    }

    /// Check whether a branch would conflict if merged into the default branch.
    /// Returns nil if git commands fail (leaves status unchanged).
    private func checkHasConflicts(repoPath: String, defaultBranch: String, branch: String) async -> Bool? {
        guard let isAncestor = await git.isMergeBaseAncestor(
            repoPath: repoPath, base: "origin/\(defaultBranch)", branch: branch
        ) else {
            // git error or origin/<defaultBranch> doesn't exist yet —
            // leave hasConflicts at its previous value. For purely local repos
            // (no origin remote) this is a permanent no-op, which is acceptable.
            return nil
        }
        if isAncestor { return false }

        // Branches have diverged — check for conflicts
        let (hasConflicts, _) = await git.checkMergeConflicts(
            repoPath: repoPath, branch: branch, targetBranch: "origin/\(defaultBranch)"
        )
        return hasConflicts
    }

    // MARK: - Reconcile

    /// Reconciles the database state with actual git worktrees on disk.
    ///
    /// - Worktrees in db but missing from git: marked as archived
    /// - Worktrees in git but missing from db: added with default names
    public func reconcile(repoID: UUID) async throws {
        // Null out parent pointers whose target is missing OR archived. Either
        // case would leave the child unreachable in the sidebar — missing rows
        // can't render, and archived parents are filtered out of the subtree
        // walk. Promoting to top-level is the only sensible recovery. Cheap
        // single UPDATE — safe to run per repo.
        try await db.worktrees.nullOrphanedParents()

        guard let repo = try await db.repos.get(id: repoID) else {
            throw WorktreeLifecycleError.repoNotFound(repoID)
        }

        // If the repo's filesystem path is gone, don't try to talk to git.
        // The startup health validator will (or already has) flipped its status
        // to .missing. Reconcile becomes a no-op until the user runs `tbd repo
        // relocate`. The daemon must not crash or hang on stale paths.
        if repo.status == .missing {
            return
        }

        let gitWorktrees = try await git.worktreeList(repoPath: repo.path)
        // The per-repo blit server socket is deterministic from the repo path
        // (BlitManager.socketPath), so there's no stale-name fix-up to do as
        // there was for tmux server names. The DB's blitSocket value is
        // refreshed lazily by ensureBlitProvisioned on next spawn.
        let blitSocket = BlitManager.socketPath(forRepoPath: repo.path)
        let dbWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)

        let gitPaths = Set(gitWorktrees.map(\.path))
        // Include `.creating` rows so a worktree whose pre-session phase-3
        // wait is still in flight (status flips to .active only when the hook
        // finishes) isn't "unknown" to the re-adopt pass below — re-adopting
        // its path would violate the UNIQUE path constraint and abort this
        // repo's reconcile.
        let creatingPaths = Set(
            (try await db.worktrees.list(repoID: repoID, status: .creating)).map(\.path)
        )
        let dbPaths = Set(dbWorktrees.map(\.path)).union(creatingPaths)

        // Mark missing worktrees as archived — also kill their blit terminals
        for wt in dbWorktrees where !gitPaths.contains(wt.path) {
            let terminals = try await db.terminals.list(worktreeID: wt.id)
            let wtSocket = wt.blitSocket.isEmpty ? blitSocket : wt.blitSocket
            for terminal in terminals where !terminal.blitTerminalID.isEmpty {
                await killTerminalAndReap(
                    socket: wtSocket,
                    terminalID: terminal.blitTerminalID,
                    pidfile: terminal.blitPidfilePath
                )
            }
            try await db.terminals.deleteForWorktree(worktreeID: wt.id)
            try await db.tabs.deleteForWorktree(worktreeID: wt.id)
            for terminal in terminals {
                await pendingQuestions.clear(terminalID: terminal.id)
                // Reclaim any per-session fallbackModel overlay (keyed by terminal
                // id), mirroring handleTerminalDelete. No-op when none was written.
                ClaudeHookOverlay.removePerSessionOverlay(sessionKey: terminal.id.uuidString)
            }
            try await db.worktrees.archive(id: wt.id)
        }

        // Add unknown worktrees (skip the main repo worktree).
        // LEGACY-WORKTREE-LOCATION: remove after 2026-06-01
        // Reads worktrees from <repo>/.tbd/worktrees/ for backward compatibility with
        // worktrees created before the canonical-location switch. New worktrees are
        // always created under ~/tbd/worktrees/<repo>/<name>. After 2026-06-01, all
        // pre-switch worktrees will have archived naturally and this path can be deleted.
        // Dual-prefix view: accept worktrees living under either the canonical
        // (~/tbd/worktrees/<slot>/) or legacy (<repo>/.tbd/worktrees/) layout.
        let layout = WorktreeLayout()
        let acceptablePrefixes = layout.legacyAndCanonicalPrefixes(for: repo)
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        for gitWt in gitWorktrees where !dbPaths.contains(gitWt.path) {
            guard acceptablePrefixes.contains(where: { gitWt.path.hasPrefix($0) }) else { continue }

            let name = (gitWt.path as NSString).lastPathComponent
            let tmuxServer = TmuxManager.serverName(forRepoPath: repo.path)
            _ = try await db.worktrees.create(
                repoID: repoID,
                name: name,
                branch: gitWt.branch,
                path: gitWt.path,
                tmuxServer: tmuxServer
            )
        }

        // Rebuild terminals from the DB for blit's in-memory model.
        //
        // blit's server holds all terminals/scrollback in memory and starts
        // EMPTY after a daemon (or machine) restart. So unlike the old tmux
        // reconcile — which re-synced the DB against still-live windows — the
        // correct action here is "rebuild from the DB":
        //
        //   - If the blit terminal is still present on the live server (the
        //     daemon restarted but the server survived, e.g. a `--app`-only
        //     restart), leave it alone.
        //   - Otherwise the terminal's in-memory state is gone. Resumable
        //     Claude terminals are respawned from their snapshot + session ID
        //     (`recreateAfterReboot`); everything else is respawned fresh so
        //     the user always sees a live pane.
        let allLiveWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)
            + (try await db.worktrees.list(repoID: repoID, status: .main))
        let serverAlive = await blit.serverExists(socket: blitSocket)
        let liveTerminalIDs: Set<String>
        if serverAlive {
            liveTerminalIDs = Set((try? await blit.listWindows(socket: blitSocket)) ?? [])
        } else {
            liveTerminalIDs = []
        }
        for wt in allLiveWorktrees {
            let terminals = try await db.terminals.list(worktreeID: wt.id)
            for terminal in terminals where terminal.suspendedAt == nil {
                let alive = serverAlive
                    && !terminal.blitTerminalID.isEmpty
                    && liveTerminalIDs.contains(terminal.blitTerminalID)
                if alive { continue }
                do {
                    try await recreateAfterReboot(terminal: terminal, worktree: wt)
                    logger.info("reconcile: rebuilt terminal \(terminal.id, privacy: .public) in worktree \(wt.id, privacy: .public) — blit terminal gone")
                } catch {
                    logger.error("reconcile: failed to rebuild terminal \(terminal.id, privacy: .public): \(error, privacy: .public)")
                }
            }
        }

        // Clean up orphaned blit terminals — terminals not tracked by any
        // worktree row (active, main, or creating). `.creating` worktrees count
        // as live: a pre-session hook wait still in flight (or just resumed by
        // the startup recovery sweep) owns a real blit terminal, and phase 3
        // spawns primary/setup terminals before the row flips `.active`.
        // Treating those rows as dead would kill the hook mid-run (interrupting
        // e.g. a running npm install) and spawn the agent prematurely.
        let activeWorktrees = try await db.worktrees.list(repoID: repoID, status: .active)
        let mainWorktreesForCleanup = try await db.worktrees.list(repoID: repoID, status: .main)
        let creatingWorktreesForCleanup = try await db.worktrees.list(repoID: repoID, status: .creating)
        let allLiveWorktreesForCleanup = activeWorktrees + mainWorktreesForCleanup + creatingWorktreesForCleanup
        if allLiveWorktreesForCleanup.isEmpty {
            // No live worktrees (including `.creating` ones) — quit the blit
            // server (which kills all its terminals). A repo whose only live row
            // is mid-pre-session must NOT land here, or the hook's terminal dies
            // with the server.
            if await blit.serverExists(socket: blitSocket) {
                do {
                    try await blit.killServer(socket: blitSocket)
                } catch {
                    logger.warning("reconcile: failed to quit blit server \(blitSocket, privacy: .public): \(error, privacy: .public)")
                }
            }
        } else if await blit.serverExists(socket: blitSocket) {
            // Collect all tracked blit terminal IDs (active + main + creating).
            var trackedTerminalIDs: Set<String> = []
            for wt in allLiveWorktreesForCleanup {
                let terminals = try await db.terminals.list(worktreeID: wt.id)
                for t in terminals where !t.blitTerminalID.isEmpty {
                    trackedTerminalIDs.insert(t.blitTerminalID)
                }
            }

            // List actual blit terminals and kill any that aren't tracked.
            do {
                let blitTerminals = try await blit.listWindows(socket: blitSocket)
                for terminalID in blitTerminals where !trackedTerminalIDs.contains(terminalID) {
                    await killTerminalAndReap(
                        socket: blitSocket,
                        terminalID: terminalID,
                        pidfile: nil
                    )
                }
            } catch {
                logger.warning("reconcile: failed to list blit terminals for socket \(blitSocket, privacy: .public): \(error, privacy: .public)")
            }
        }

        // Recompute health so the next call sees the right status. A repo that
        // just transitioned ok→missing here would otherwise stay ok in memory
        // until the next startup sweep.
        let validator = RepoHealthValidator(git: git)
        let observed = await validator.validate(repo: repo)
        if observed != repo.status {
            try? await db.repos.updateStatus(id: repo.id, status: observed)
            // Broadcast a coarse refresh so the sidebar dims/un-dims immediately
            // when reconcile is triggered via an RPC (e.g. cleanup) with active
            // subscribers. .repoAdded is the existing coarse signal — see the
            // matching call site in RPCRouter+RelocateHandler.
            subscriptions?.broadcast(delta: .repoAdded(RepoDelta(
                repoID: repo.id, path: repo.path, displayName: repo.displayName
            )))
        }
    }

    // MARK: - Reboot Recovery

    /// Respawns a blit terminal for a terminal record whose in-memory blit state
    /// was lost (daemon/machine restart — blit's server is in-memory). Resumable
    /// Claude terminals come back via `claude --resume <sessionID>`; everything
    /// else respawns fresh. The saved ANSI snapshot is retained on the row so
    /// the app can show it until live output arrives. Updates the terminal's
    /// stored blit terminal ID + pidfile in the DB.
    ///
    /// Visibility: `internal` (not `private`) so tests in the same module can
    /// drive this path directly.
    internal func recreateAfterReboot(terminal: Terminal, worktree: Worktree) async throws {
        // Free-form env overrides applied to recreated agent panes (global <
        // repo < profile). Codex takes the merged map as-is; Claude layers the
        // builder's auth/routing env on top; plain shells get nothing. The repo
        // record is fetched once here; the blit socket is derived from its path.
        let rebootRepo = try? await db.repos.get(id: worktree.repoID)
        let repoPath = rebootRepo?.path ?? worktree.path
        // Ensure the per-repo blit server + gateway are running and persisted.
        let blitSocket = try await ensureBlitProvisioned(worktree: worktree, repoPath: repoPath)

        let rebootConfig = try? await db.config.get()
        let claudeEnvOverrides = rebootConfig?.envSettingOverrides ?? [:]
        let spawn: ClaudeSpawnCommandBuilder.Result
        // Per-branch free-form env layered into the recreated pane; defaults to
        // none (plain shells stay clean).
        var primarySensitiveEnv: [String: String] = [:]
        var env: [String: String] = [:]
        // Always announce the worktree to recreated panes. Without this, the
        // pane inherits whatever TBD_WORKTREE_ID the tmux server was spawned
        // with — which would misattribute notifications to a different
        // worktree. Applies to all branches below (claude, codex, shell/cmd).
        env["TBD_WORKTREE_ID"] = worktree.id.uuidString
        // Persist the terminal ID into the spawned env so the SessionStart
        // hook bridge can route session events for `/clear`/`/compact`
        // rollovers without depending on cwd-based heuristics.
        env["TBD_TERMINAL_ID"] = terminal.id.uuidString

        if terminal.isCodexTerminal {
            // Codex's SessionStart hook records session metadata into the
            // shared Claude fields, so terminal kind must win over the
            // presence of a captured session ID during reboot recovery.
            let codexHome = try CodexHomeManager().ensureProfilePlugin()
            env["CODEX_HOME"] = codexHome.path
            // Codex: the merged free-form overrides ARE the entire sensitive env.
            let rebootGlobalRepoEnv = EnvOverrideResolver.merge(
                global: rebootConfig?.envOverrides,
                repo: rebootRepo?.envOverrides,
                profile: nil
            )
            primarySensitiveEnv = rebootGlobalRepoEnv
            spawn = ClaudeSpawnCommandBuilder.build(
                resumeID: nil,
                freshSessionID: nil,
                appendSystemPrompt: nil,
                initialPrompt: nil,
                profileSecret: nil,
                cmd: CodexSpawnCommandBuilder.command,
                shellFallback: defaultShell
            )
        } else if terminal.isClaudeResumable, let sessionID = terminal.claudeSessionID {
            // Claude terminal — resume existing session with persisted profile
            var resolvedProfile: ResolvedModelProfile? = nil
            if let profileID = terminal.profileID, let resolver = modelProfileResolver {
                resolvedProfile = try? await resolver.loadByID(profileID)
            }
            spawn = ClaudeSpawnCommandBuilder.build(
                resumeID: sessionID,
                freshSessionID: nil,
                appendSystemPrompt: nil,
                initialPrompt: nil,
                profileSecret: resolvedProfile?.secret,
                profileKind: resolvedProfile?.kind,
                profileBaseURL: resolvedProfile?.baseURL,
                profileModel: resolvedProfile?.model,
                profileAwsRegion: resolvedProfile?.awsRegion,
                profileAwsProfile: resolvedProfile?.awsProfile,
                profileConfigDir: ClaudeProfileConfigDirManager.resolveConfigDir(for: resolvedProfile),
                cmd: nil,
                shellFallback: defaultShell,
                settingsOverlayPath: ClaudeHookOverlay.resolveOverlayPath(
                    fallbackModels: resolvedProfile?.fallbackModels,
                    sessionKey: terminal.id.uuidString
                ),
                pluginDirPath: PluginDirWriter.pluginDirPath,
                envSettingOverrides: claudeEnvOverrides
            )
            // Claude: layer the builder's auth/routing env ON TOP of the merged
            // free-form overrides (incl. this terminal's profile scope) so auth wins.
            let mergedEnvOverrides = EnvOverrideResolver.merge(
                global: rebootConfig?.envOverrides,
                repo: rebootRepo?.envOverrides,
                profile: resolvedProfile?.envOverrides
            )
            primarySensitiveEnv = mergedEnvOverrides.merging(spawn.sensitiveEnv) { _, builder in builder }
        } else {
            // Shell or custom-cmd terminal. Plain shell terminals have label nil or
            // TerminalLabel.shell; custom-cmd terminals store the command string directly in label.
            let cmd = (terminal.label == TerminalLabel.shell || terminal.label == nil) ? nil : terminal.label
            spawn = ClaudeSpawnCommandBuilder.build(
                resumeID: nil,
                freshSessionID: nil,
                appendSystemPrompt: nil,
                initialPrompt: nil,
                profileSecret: nil,
                cmd: cmd,
                shellFallback: defaultShell
            )
        }

        let window = try await blit.createWindow(
            forRepoPath: repoPath,
            socket: blitSocket,
            cwd: worktree.path,
            shellCommand: spawn.command,
            env: env,
            sensitiveEnv: primarySensitiveEnv
        )
        // Record the new blit terminal ID + pidfile. The saved ANSI snapshot on
        // the row is intentionally retained so the app can show it until live
        // output arrives over the gateway.
        try await db.terminals.updateBlitTerminal(
            id: terminal.id,
            blitTerminalID: window.terminalID,
            blitPidfilePath: window.pidfilePath
        )
    }
}
