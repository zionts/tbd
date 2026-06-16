import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "reaper")

/// Errors that can occur during worktree lifecycle operations.
public enum WorktreeLifecycleError: Error, CustomStringConvertible, LocalizedError {
    case repoNotFound(UUID)
    case worktreeNotFound(UUID)
    case worktreeNotArchived(UUID)
    case worktreeAlreadyActive(UUID)
    case createFailed(String)
    case invalidOperation(String)
    case worktreePathAlreadyExists(String)
    case worktreeAlreadyRegistered(String)
    /// The archived worktree's branch no longer exists and we have no captured
    /// HEAD SHA to fall back to — there's no safe way to recreate the working tree.
    case branchMissingNoFallback(branch: String)

    public var description: String {
        switch self {
        case .repoNotFound(let id):
            return "Repository not found: \(id)"
        case .worktreeNotFound(let id):
            return "Worktree not found: \(id)"
        case .worktreeNotArchived(let id):
            return "Worktree is not archived: \(id)"
        case .worktreeAlreadyActive(let id):
            return "Worktree is already active: \(id)"
        case .createFailed(let reason):
            return "Failed to create worktree: \(reason)"
        case .invalidOperation(let detail):
            return detail
        case .worktreePathAlreadyExists(let path):
            return "Cannot revive worktree: a file or directory already exists at \(path). Remove or move it and try again."
        case .worktreeAlreadyRegistered(let path):
            return "Cannot revive worktree: git already has a worktree registered at \(path). Run `git worktree remove \(path)` (or `git worktree prune`) from the main repo and try again."
        case .branchMissingNoFallback(let branch):
            return "Cannot revive worktree: branch '\(branch)' no longer exists in the repository, and no archived HEAD SHA was captured to fall back to. The branch may have been renamed or deleted before this worktree was archived."
        }
    }

    public var errorDescription: String? { description }
}

/// Orchestrates the full lifecycle of worktrees: create, archive, revive, and reconcile.
///
/// Coordinates between git, the database, tmux, and hooks to provide
/// high-level operations that maintain consistency across all subsystems.
public struct WorktreeLifecycle: Sendable {
    public let db: TBDDatabase
    public let git: GitManager
    public let tmux: TmuxManager
    /// Blit terminal backend. The daemon spawns terminals through this instead
    /// of tmux (Phase 4). `tmux` is retained for the agent reaper's
    /// process-introspection seams only, until the final tmux removal phase.
    public let blit: BlitManager
    public let hooks: HookResolver
    public let subscriptions: StateSubscriptionManager?
    public let modelProfileResolver: ModelProfileResolver?
    public let pendingQuestions: PendingQuestionStore
    /// How long to wait for a blocking `preSession` hook before giving up and
    /// spawning the primary terminals anyway. Injectable for tests.
    public let preSessionTimeout: TimeInterval
    /// Poll interval for the preSession completion marker file.
    public let preSessionPollInterval: TimeInterval
    /// Process-signal seam for the agent reaper. Injectable for tests.
    public let processSignaller: ProcessSignaller
    /// Reaper grace knobs (kept small in tests to avoid real sleeps).
    public let reaperGraceAttempts: Int
    public let reaperPollInterval: Duration

    /// Default `preSession` hook timeout (production value).
    public static let defaultPreSessionTimeout: TimeInterval = 600

    /// The user's default shell (from $SHELL, falls back to /bin/zsh)
    var defaultShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    public init(
        db: TBDDatabase,
        git: GitManager,
        tmux: TmuxManager,
        blit: BlitManager = BlitManager(),
        hooks: HookResolver,
        subscriptions: StateSubscriptionManager? = nil,
        modelProfileResolver: ModelProfileResolver? = nil,
        pendingQuestions: PendingQuestionStore = PendingQuestionStore(),
        preSessionTimeout: TimeInterval = WorktreeLifecycle.defaultPreSessionTimeout,
        preSessionPollInterval: TimeInterval = 0.5,
        processSignaller: ProcessSignaller = ProductionProcessSignaller(),
        reaperGraceAttempts: Int = 30,
        reaperPollInterval: Duration = .milliseconds(100)
    ) {
        self.db = db
        self.git = git
        self.tmux = tmux
        self.blit = blit
        self.hooks = hooks
        self.subscriptions = subscriptions
        self.modelProfileResolver = modelProfileResolver
        self.pendingQuestions = pendingQuestions
        self.preSessionTimeout = preSessionTimeout
        self.preSessionPollInterval = preSessionPollInterval
        self.processSignaller = processSignaller
        self.reaperGraceAttempts = reaperGraceAttempts
        self.reaperPollInterval = reaperPollInterval
    }

    /// The agent reaper composed from the injected tmux + signaller seams.
    var reaper: AgentReaper {
        AgentReaper(tmux: tmux, signaller: processSignaller,
                    graceAttempts: reaperGraceAttempts, pollInterval: reaperPollInterval)
    }

    /// Kill a blit terminal, then confirm the leader process actually died and
    /// escalate (SIGTERM→SIGKILL) if it survived (wedged agent). The leader PID
    /// comes from the per-terminal pidfile, since blit exposes no PID.
    func killTerminalAndReap(socket: String, terminalID: String, pidfile: String?) async {
        let leaderPID = pidfile.flatMap { blit.leaderPID(forPidfile: $0) }
        do {
            try await blit.killWindow(socket: socket, terminalID: terminalID)
        } catch {
            logger.warning("killWindow failed on \(socket, privacy: .public) terminal \(terminalID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        // Escalate even if killWindow threw — the leader process may still be alive.
        if let leaderPID { await reaper.escalateAfterHangup(leaderPID) }
    }

    /// Ensures the per-repo blit server + gateway are running for `worktree` and
    /// persists the resulting socket/port/passphrase onto the worktree row.
    /// Idempotent: re-running re-derives the socket (deterministic per repo
    /// path) and only spawns a gateway when one isn't already recorded. Returns
    /// the resolved socket path the caller threads into blit terminal calls.
    @discardableResult
    func ensureBlitProvisioned(worktree: Worktree, repoPath: String) async throws -> String {
        let socket = BlitManager.socketPath(forRepoPath: repoPath)
        try await blit.ensureServer(socket: socket)
        // Provision a gateway once per worktree. blit's gateway is an in-memory
        // child with a fresh loopback port each spawn; re-provisioning on every
        // call would churn ports the app is connected to. Only (re)provision
        // when the row has no recorded port yet.
        var port = worktree.gatewayPort
        var passphrase = worktree.gatewayPassphrase
        if port == nil || passphrase == nil {
            let gateway = try await blit.ensureGateway(socket: socket)
            port = gateway.port
            passphrase = gateway.passphrase
        }
        if worktree.blitSocket != socket
            || worktree.gatewayPort != port
            || worktree.gatewayPassphrase != passphrase {
            try await db.worktrees.updateBlitGateway(
                id: worktree.id,
                blitSocket: socket,
                gatewayPort: port,
                gatewayPassphrase: passphrase
            )
        }
        return socket
    }
}
