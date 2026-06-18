import Foundation
import os
import TBDShared

/// Guarantees that an agent session spawned by THIS daemon resolves a
/// version-matched, channel-capable `tbd` ahead of any globally-installed CLI.
///
/// ## Why this exists
///
/// Spawned agents coordinate via `tbd channel post/tail`. But an agent shell
/// inherits the user's PATH, so `tbd` resolves to whatever is globally
/// installed (e.g. `~/.local/bin/tbd`) — frequently an OLDER build with no
/// `channel` subcommand. The agent then sees "channel isn't available in this
/// CLI build" and silently degrades to `tbd notify`, killing the coordination
/// loop whenever the global `tbd` drifts from the running daemon.
///
/// The session env already propagates `TBD_HOME` / `TBD_SOCKET_PATH` /
/// `TBD_WORKTREE_ID`, so a channel-capable `tbd` pointed at the right socket
/// just works. The only missing piece is guaranteeing the `tbd` on PATH
/// matches this daemon's version. We do that by staging a `tbd` symlink in
/// `${TBD_HOME}/bin` → the daemon's sibling `TBDCLI` and prepending that dir
/// to the spawned session's PATH.
///
/// ## Gating
///
/// Every step is best-effort. If the CLI can't be resolved or the symlink
/// can't be created, `pathPrependForSession` returns `nil` and the session is
/// spawned WITHOUT the PATH injection — never blocking or breaking session
/// creation. The agent then falls back to whatever global `tbd` exists, which
/// is exactly today's behavior.
struct AgentCLIProvisioner: Sendable {
    /// Env var that lets an operator pin the CLI binary explicitly, bypassing
    /// the daemon-sibling resolution (useful for unusual install layouts or
    /// tests). Takes precedence over the sibling lookup when it points at an
    /// existing file.
    static let cliPathOverrideEnvVar = "TBD_CLI_PATH"

    private let logger = Logger(subsystem: "com.tbd.daemon", category: "agentCLIProvisioner")

    /// The daemon's own executable path, resolved once at module load. CWD is
    /// captured at startup (not at call time) so a later `chdir` can't break
    /// resolution when `argv[0]` is relative. Symlinks are followed so we get
    /// the real binary path — `CLIInstaller.cliPath(forDaemonExecutable:)` looks
    /// for `TBDCLI` next to the actual TBDDaemon binary, not next to a symlink.
    static let resolvedDaemonExecutablePath: String? = {
        guard let argv0 = CommandLine.arguments.first, !argv0.isEmpty else { return nil }
        let url: URL
        if argv0.hasPrefix("/") {
            url = URL(fileURLWithPath: argv0)
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            url = URL(fileURLWithPath: argv0, relativeTo: URL(fileURLWithPath: cwd))
        }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }()

    /// Resolve the version-matched, channel-capable CLI binary, pure & testable.
    ///
    /// Resolution order:
    /// 1. `TBD_CLI_PATH` override, when it points at an existing file.
    /// 2. The `TBDCLI` binary sitting next to the daemon's own executable
    ///    (`dirname(daemonExecutable)/TBDCLI`), when it exists.
    /// 3. `nil` — caller spawns without PATH injection.
    ///
    /// - Parameters:
    ///   - daemonExecutable: Absolute path to the running daemon binary, or nil
    ///     when it could not be resolved.
    ///   - environment: Env dict to read the override from (injected for tests).
    ///   - fileExists: Filesystem probe seam (injected for tests).
    static func resolveCLIPath(
        daemonExecutable: String?,
        environment: [String: String],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        if let override = environment[cliPathOverrideEnvVar],
           !override.isEmpty,
           fileExists(override) {
            return override
        }
        guard let daemonExecutable, !daemonExecutable.isEmpty else { return nil }
        let sibling = CLIInstaller.cliPath(forDaemonExecutable: daemonExecutable)
        return fileExists(sibling) ? sibling : nil
    }

    /// Idempotently stage `${binDir}/tbd` as a symlink to `cliPath`. Returns the
    /// staged `tbd` path on success, nil on any failure (logged).
    ///
    /// A symlink (not a hard link) is correct here: this lives under TBD_HOME,
    /// is re-staged on every spawn, and pointing at the current `.build` CLI is
    /// exactly what "version-matched to the running daemon" means. If the build
    /// inode changes, the next spawn refreshes the link.
    func stageSymlink(
        cliPath: String,
        binDir: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let linkPath = binDir.appendingPathComponent("tbd").path
        do {
            try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        } catch {
            logger.error("failed to create bin dir \(binDir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // Fast path: an existing symlink already pointing at the right target.
        if let existing = try? fileManager.destinationOfSymbolicLink(atPath: linkPath),
           existing == cliPath {
            return linkPath
        }

        // Remove any stale entry (wrong-target symlink, hard link, or file)
        // using lstat semantics so we don't follow/miss a dangling link.
        var st = stat()
        if lstat(linkPath, &st) == 0 {
            do {
                try fileManager.removeItem(atPath: linkPath)
            } catch {
                logger.error("failed to remove stale \(linkPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        do {
            try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: cliPath)
            return linkPath
        } catch {
            logger.error("failed to symlink \(linkPath, privacy: .public) -> \(cliPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The gating conditional, end to end: resolve the CLI, stage the symlink,
    /// and return the bin directory to prepend to the session PATH — or `nil`
    /// when any step fails, in which case the caller spawns without injection.
    ///
    /// - Parameters:
    ///   - daemonExecutable: Absolute path to the running daemon binary, or nil.
    ///   - environment: Env dict (reads `TBD_HOME` and `TBD_CLI_PATH`); defaults
    ///     to the live process environment.
    func pathPrependForSession(
        daemonExecutable: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let cliPath = Self.resolveCLIPath(
            daemonExecutable: daemonExecutable,
            environment: environment
        ) else {
            logger.debug("no channel-capable CLI resolved; spawning session without PATH injection")
            return nil
        }
        let binDir = TBDConstants.binDir(environment: environment)
        guard stageSymlink(cliPath: cliPath, binDir: binDir) != nil else {
            return nil
        }
        return binDir.path
    }
}
