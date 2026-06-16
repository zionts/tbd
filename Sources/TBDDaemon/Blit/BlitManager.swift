import Foundation
import os
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "BlitManager")

/// Drives the `blit` CLI (v0.35.0) as TBD's terminal backend, mirroring the
/// method surface of `TmuxManager` so the RPC handlers / lifecycle can swap
/// backends with minimal change in a later phase.
///
/// Phase 2 is purely additive: this type is not yet wired into any RPC handler,
/// lifecycle path, or the DB. It exists so the rest of the migration can be
/// built and tested against a real, verified CLI contract.
///
/// ## Verified blit contract (0.35.0, macOS arm64)
/// - Per-repo isolation via a unix socket: `blit server --socket <path>` (or
///   `BLIT_SOCK=<path>`). Set `BLIT_PROXY=0` so blit's proxy daemon doesn't
///   auto-start and interfere.
/// - `blit terminal start [--rows N --cols N] [-t TAG] -- <cmd…>` prints an
///   **integer** terminal ID. There is **no** `--cwd` and **no** `--env`, so we
///   wrap the real command in `/bin/zsh -lic '<wrapper>'` that `cd`s, sources an
///   env-file for secrets, exports non-sensitive env, records its PID to a
///   pidfile, then `exec`s the command.
/// - `blit terminal send <ID> -` reads literal text from stdin (no C-escape
///   interpretation). `blit terminal send <ID> <SEQ>` interprets C-escapes for
///   named keys (Enter→`\n`, Escape→`\x1b`).
/// - `blit terminal show <ID> [--ansi]` returns the visible screen; `--ansi`
///   preserves color.
/// - `blit terminal kill <ID> [SIGNAL]` signals the child; `close <ID>` frees
///   the slot.
/// - `blit terminal list` prints TSV: `ID  TAG  TITLE  COMMAND  STATUS`. No PID.
/// - `blit gateway` is env-configured: `BLIT_PASSPHRASE` (required),
///   `BLIT_ADDR` (bind addr), `BLIT_PROXY`, targeting the server via `BLIT_SOCK`.
public struct BlitManager: Sendable {
    public let dryRun: Bool
    private let counter: Counter
    /// Optional override for the `blit` binary path (tests inject a fake so no
    /// real binary is required). When nil, the path is resolved at call time
    /// from common install locations / PATH.
    private let blitBinaryOverride: String?

    /// Records every dryRun command invocation. When set, dry-run paths still
    /// no-op, but the recorder receives the argv that would have been passed to
    /// `blit`. Mirrors `TmuxManager.dryRunRecorder` — spawn / swap tests assert
    /// command shapes without spawning a real blit server.
    public let dryRunRecorder: (@Sendable ([String]) -> Void)?
    /// Consulted by `windowExists` in dryRun mode: return `true` for a terminal
    /// ID to simulate that terminal having died. Without it, dryRun reports
    /// every terminal as alive. Mirrors `TmuxManager.dryRunWindowIsDead`.
    public let dryRunWindowIsDead: (@Sendable (String) -> Bool)?
    /// Consulted by `listWindows` in dryRun mode: `socket` → the terminal IDs to
    /// report. Without it, dryRun reports no terminals. Mirrors
    /// `TmuxManager.dryRunListWindows` (blit has no session concept, so the
    /// closure takes only the socket).
    public let dryRunListWindows: (@Sendable (String) -> [String])?

    // Thread-safe counter for generating unique mock IDs in dry-run mode.
    private final class Counter: Sendable {
        private let _value = OSAllocatedUnfairLock(initialState: 0)

        func next() -> Int {
            _value.withLock { value in
                let current = value
                value += 1
                return current
            }
        }
    }

    public init(
        dryRun: Bool = false,
        blitBinaryOverride: String? = nil,
        dryRunRecorder: (@Sendable ([String]) -> Void)? = nil,
        dryRunWindowIsDead: (@Sendable (String) -> Bool)? = nil,
        dryRunListWindows: (@Sendable (String) -> [String])? = nil
    ) {
        self.dryRun = dryRun
        self.counter = Counter()
        self.blitBinaryOverride = blitBinaryOverride
        self.dryRunRecorder = dryRunRecorder
        self.dryRunWindowIsDead = dryRunWindowIsDead
        self.dryRunListWindows = dryRunListWindows
    }

    // MARK: - Static Path Builders

    /// Stable per-repo identifier, reusing the EXACT djb2 hash that
    /// `TmuxManager.serverName(forRepoPath:)` uses. Returns `tbd-<hex>` so a
    /// repo's blit socket name matches its old tmux server name 1:1 (eases
    /// migration reasoning and keeps the value stable across DB recreations and
    /// process restarts — Swift's `Hasher` is randomized per process and must
    /// NOT be used here).
    public static func serverName(forRepoPath path: String) -> String {
        var hash: UInt64 = 5381
        for byte in path.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte) // hash * 33 + byte
        }
        let hex = String(hash & 0xFFFFFFFF, radix: 16, uppercase: false)
        return "tbd-\(hex)"
    }

    /// The directory under the TBD config base where blit unix sockets and
    /// per-terminal pidfiles live. Honors `TBD_HOME` via `TBDConstants`.
    public static func runDir(environment: [String: String]) -> URL {
        TBDConstants.configDir(environment: environment).appendingPathComponent("run", isDirectory: true)
    }

    public static var runDir: URL { runDir(environment: ProcessInfo.processInfo.environment) }

    /// The blit server unix socket path for a repo, derived from the repo path.
    ///
    /// darwin caps `sun_path` (the unix socket address) at ~104 bytes. The
    /// socket name is fixed-length (`tbd-` + 8 hex + `.sock` = 17 chars), so the
    /// only way to overflow is a deep `TBD_HOME`. Production `~/tbd/run/…` is
    /// well under the limit; deep test homes should set `TBD_SOCKET_PATH`-style
    /// shallow overrides (see CLAUDE.md "Tests must not touch ~/tbd"). Callers
    /// that need to guard against overflow can check the returned path's
    /// `utf8.count` against `Self.maxSocketPathLength`.
    public static func socketPath(forRepoPath path: String, environment: [String: String]) -> String {
        let name = serverName(forRepoPath: path)
        return runDir(environment: environment).appendingPathComponent("\(name).sock").path
    }

    public static func socketPath(forRepoPath path: String) -> String {
        socketPath(forRepoPath: path, environment: ProcessInfo.processInfo.environment)
    }

    /// darwin's documented `sun_path` capacity (104 on macOS). Exposed so
    /// callers / tests can assert a derived socket path will actually bind.
    public static let maxSocketPathLength = 104

    /// Per-terminal pidfile path. The spawn wrapper writes its post-`exec` PID
    /// here (`echo $$ > <pidfile>`) so the daemon can map a terminal ID to a
    /// real PID — blit exposes no PID itself. The tag uniquifies the file.
    public static func pidfilePath(forRepoPath path: String, tag: String, environment: [String: String]) -> String {
        let name = serverName(forRepoPath: path)
        return runDir(environment: environment).appendingPathComponent("\(name)-\(tag).pid").path
    }

    public static func pidfilePath(forRepoPath path: String, tag: String) -> String {
        pidfilePath(forRepoPath: path, tag: tag, environment: ProcessInfo.processInfo.environment)
    }

    // MARK: - Sizing

    /// Minimum sane terminal size. Smaller values are dropped (blit picks its
    /// own default), matching `TmuxManager`'s floor.
    public static let minCols: Int = 80
    public static let minRows: Int = 24

    /// Default size when a caller supplies none. Larger than 80x24 so Claude
    /// doesn't render into hard-wrapped scrollback before the web client
    /// attaches and resizes.
    public static let defaultCols: Int = 220
    public static let defaultRows: Int = 50

    /// `--rows N --cols N` flags when the caller supplied a usable size; empty
    /// otherwise (blit uses its own default).
    private static func sizeFlags(cols: Int?, rows: Int?) -> [String] {
        guard let cols, let rows, cols >= minCols, rows >= minRows else { return [] }
        return ["--rows", "\(rows)", "--cols", "\(cols)"]
    }

    // MARK: - Static Command Builders

    /// `blit server --socket <path>`. Run detached with `BLIT_PROXY=0`.
    public static func serverStartCommand(socket: String) -> [String] {
        ["server", "--socket", socket]
    }

    /// `blit quit` — stops the server cleanly (targeted via `BLIT_SOCK`).
    public static func serverQuitCommand() -> [String] {
        ["quit"]
    }

    /// `blit gateway` — env-only configuration (BLIT_ADDR / BLIT_PASSPHRASE /
    /// BLIT_SOCK), so there are no flags.
    public static func gatewayStartCommand() -> [String] {
        ["gateway"]
    }

    /// `blit terminal start [--rows N --cols N] -t <tag> -- /bin/zsh -lic '<wrapper>'`.
    ///
    /// blit has no `--cwd`/`--env`, so the wrapper encodes cwd, env, secrets,
    /// and the pidfile. Secrets are sourced from `envFilePath` (a 0600 temp file
    /// the caller writes before spawn and the wrapper `rm`s), so they never
    /// appear in argv / `ps`.
    public static func terminalStartCommand(
        tag: String,
        wrapper: String,
        cols: Int? = nil,
        rows: Int? = nil
    ) -> [String] {
        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return ["terminal", "start"]
            + sizeFlags(cols: cols, rows: rows)
            + ["-t", tag, "--", userShell, "-lic", wrapper]
    }

    /// Builds the zsh wrapper script run inside the blit terminal. Order:
    /// 1. `cd <cwd>` (blit has no `--cwd`; defaults to the server's cwd).
    /// 2. Source secrets from the env-file with `set -a`, then `rm` it so the
    ///    plaintext secrets exist on disk only momentarily and never in argv.
    /// 3. Export non-sensitive env.
    /// 4. Record the post-exec PID (`$$`) to the pidfile so the daemon can map
    ///    terminal→PID for `~/.claude/sessions/<pid>.json` lookups.
    /// 5. `exec <shellCommand>` so the real process replaces the wrapper shell.
    public static func buildWrapper(
        cwd: String,
        shellCommand: String,
        env: [String: String],
        envFilePath: String?,
        pidfilePath: String
    ) -> String {
        var parts: [String] = []
        parts.append("cd \(shellQuote(cwd))")
        if let envFilePath {
            // `set -a` auto-exports everything sourced; `rm -f` removes the
            // plaintext file immediately; `set +a` restores normal behavior.
            parts.append("set -a; . \(shellQuote(envFilePath)); rm -f \(shellQuote(envFilePath)); set +a")
        }
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            parts.append("export \(key)=\(shellQuote(value))")
        }
        // `$$` after `exec` is the same PID as the wrapper shell (exec reuses
        // the PID), so writing it here correctly identifies the real process.
        parts.append("echo $$ > \(shellQuote(pidfilePath))")
        parts.append("exec \(shellCommand)")
        return parts.joined(separator: "; ")
    }

    /// `blit terminal send <ID> -` — literal text is fed on stdin to avoid
    /// C-escape interpretation (replaces `tmux send-keys -l`).
    public static func sendKeysCommand(terminalID: String) -> [String] {
        ["terminal", "send", terminalID, "-"]
    }

    /// `blit terminal send <ID> <SEQ>` — the sequence is C-escape interpreted by
    /// blit, so named keys are passed as their escape sequence.
    public static func sendKeyCommand(terminalID: String, sequence: String) -> [String] {
        ["terminal", "send", terminalID, sequence]
    }

    /// `blit terminal show <ID>` — visible screen, no ANSI.
    public static func showCommand(terminalID: String) -> [String] {
        ["terminal", "show", terminalID]
    }

    /// `blit terminal show --ansi <ID>` — visible screen with color preserved.
    public static func showAnsiCommand(terminalID: String) -> [String] {
        ["terminal", "show", "--ansi", terminalID]
    }

    /// `blit terminal kill <ID> <SIGNAL>`.
    public static func killCommand(terminalID: String, signal: String) -> [String] {
        ["terminal", "kill", terminalID, signal]
    }

    /// `blit terminal close <ID>` — frees the slot after kill.
    public static func closeCommand(terminalID: String) -> [String] {
        ["terminal", "close", terminalID]
    }

    /// `blit terminal list` — TSV `ID  TAG  TITLE  COMMAND  STATUS`.
    public static func listCommand() -> [String] {
        ["terminal", "list"]
    }

    /// Named-key → C-escape sequence map for `sendKey`. blit interprets these
    /// when the text is passed as an argument (not via stdin).
    public static let keySequences: [String: String] = [
        "Enter": "\\n",
        "Return": "\\n",
        "Escape": "\\x1b",
        "Esc": "\\x1b",
        "Tab": "\\t",
        "Space": " ",
        "Backspace": "\\x7f",
        "Up": "\\x1b[A",
        "Down": "\\x1b[B",
        "Right": "\\x1b[C",
        "Left": "\\x1b[D",
    ]

    // MARK: - Instance Execution Methods

    /// Ensures a blit server is running for the given socket. Spawns
    /// `blit server --socket <path>` detached (env `BLIT_PROXY=0`) if the socket
    /// doesn't already exist, then waits for the socket file to appear.
    /// Idempotent: a no-op if the socket already exists.
    public func ensureServer(socket: String) async throws {
        let args = Self.serverStartCommand(socket: socket)
        if dryRun {
            dryRunRecorder?(args)
            return
        }
        if FileManager.default.fileExists(atPath: socket) {
            return
        }
        // Ensure the run dir exists so blit can bind the socket.
        let runDir = (socket as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)

        logger.info("ensureServer: starting blit server on socket \(socket, privacy: .public)")
        try spawnDetached(args, extraEnv: ["BLIT_PROXY": "0"])
        // Wait for the socket to appear (server is ready once it binds).
        try await waitForSocket(socket)
    }

    /// Stops the blit server bound to `socket` (targeted via `BLIT_SOCK`).
    public func killServer(socket: String) async throws {
        let args = Self.serverQuitCommand()
        if dryRun {
            dryRunRecorder?(args)
            return
        }
        logger.info("killServer: quitting blit server on socket \(socket, privacy: .public)")
        _ = try await runBlit(args, socket: socket)
    }

    /// Allocates a free loopback TCP port, generates a random passphrase, and
    /// spawns `blit gateway` (env `BLIT_ADDR`, `BLIT_PASSPHRASE`, `BLIT_SOCK`,
    /// `BLIT_PROXY=0`) detached, targeting the server on `socket`.
    ///
    /// Nothing calls this in Phase 2 — the app needs it in a later phase to
    /// connect a WKWebView client to the gateway.
    /// - Returns: the allocated port and the generated passphrase.
    @discardableResult
    public func ensureGateway(socket: String) async throws -> (port: Int, passphrase: String) {
        let port = try Self.allocateFreeLoopbackPort()
        let passphrase = Self.randomPassphrase()
        let args = Self.gatewayStartCommand()
        if dryRun {
            dryRunRecorder?(args)
            return (port: port, passphrase: passphrase)
        }
        logger.info("ensureGateway: starting blit gateway on 127.0.0.1:\(port, privacy: .public) for socket \(socket, privacy: .public)")
        try spawnDetached(args, extraEnv: [
            "BLIT_ADDR": "127.0.0.1:\(port)",
            "BLIT_PASSPHRASE": passphrase,
            "BLIT_SOCK": socket,
            "BLIT_PROXY": "0",
        ])
        return (port: port, passphrase: passphrase)
    }

    /// Creates a blit terminal running `shellCommand` in `cwd` with the given
    /// env. Secrets in `sensitiveEnv` are written to a 0600 env-file the wrapper
    /// sources and deletes, keeping them out of argv / `ps`.
    /// - Returns: the blit terminal ID (as a String to fit existing opaque-ID
    ///   patterns) and the path to the per-terminal pidfile.
    public func createWindow(
        forRepoPath repoPath: String,
        socket: String,
        cwd: String,
        shellCommand: String,
        env: [String: String] = [:],
        sensitiveEnv: [String: String] = [:],
        cols: Int? = nil,
        rows: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> (terminalID: String, pidfilePath: String) {
        // A unique tag per spawn — used both as blit's `-t` tag and to
        // uniquify the pidfile (and the env-file) so concurrent spawns on the
        // same repo don't collide.
        let tag = "t-\(UUID().uuidString.prefix(8).lowercased())"
        let pidfile = Self.pidfilePath(forRepoPath: repoPath, tag: tag, environment: environment)

        // Write secrets to a 0600 env-file before spawn so they never appear in
        // the blit invocation's argv. The wrapper sources then deletes it.
        var envFilePath: String?
        if !sensitiveEnv.isEmpty {
            envFilePath = try Self.writeEnvFile(sensitiveEnv, repoPath: repoPath, tag: tag, environment: environment)
        }

        let wrapper = Self.buildWrapper(
            cwd: cwd,
            shellCommand: shellCommand,
            env: env,
            envFilePath: envFilePath,
            pidfilePath: pidfile
        )
        let args = Self.terminalStartCommand(tag: tag, wrapper: wrapper, cols: cols, rows: rows)

        if dryRun {
            dryRunRecorder?(args)
            let n = counter.next()
            return (terminalID: "\(n)", pidfilePath: pidfile)
        }

        // Ensure run dir exists for the pidfile the wrapper writes.
        let runDir = (pidfile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)

        let output = try await runBlit(args, socket: socket)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // blit prints an integer ID on stdout; take the first integer token.
        guard let idToken = trimmed.split(whereSeparator: { $0 == "\n" || $0 == " " }).first,
              Int(idToken) != nil else {
            throw BlitError.unexpectedOutput(output)
        }
        return (terminalID: String(idToken), pidfilePath: pidfile)
    }

    /// Sends literal text to a terminal via stdin (`send <ID> -`).
    public func sendKeys(socket: String, terminalID: String, text: String) async throws {
        let args = Self.sendKeysCommand(terminalID: terminalID)
        if dryRun {
            dryRunRecorder?(args)
            return
        }
        _ = try await runBlit(args, socket: socket, stdin: text)
    }

    /// Sends a named key (Enter / Escape / arrows / …) as its escape sequence.
    /// Ctrl-C is special-cased to a kill-with-INT, mirroring the verified
    /// recommendation (blit `kill <ID> INT` delivers a clean interrupt).
    public func sendKey(socket: String, terminalID: String, key: String) async throws {
        if key == "C-c" || key == "Ctrl-C" || key == "^C" {
            try await killWindow(socket: socket, terminalID: terminalID, signal: "INT", close: false)
            return
        }
        let sequence = Self.keySequences[key] ?? key
        let args = Self.sendKeyCommand(terminalID: terminalID, sequence: sequence)
        if dryRun {
            dryRunRecorder?(args)
            return
        }
        _ = try await runBlit(args, socket: socket)
    }

    /// Sends a literal command followed by Enter.
    public func sendCommand(socket: String, terminalID: String, command: String) async throws {
        try await sendKeys(socket: socket, terminalID: terminalID, text: command)
        try await sendKey(socket: socket, terminalID: terminalID, key: "Enter")
    }

    /// Visible screen text without ANSI.
    public func capturePaneOutput(socket: String, terminalID: String) async throws -> String {
        if dryRun { return "" }
        let args = Self.showCommand(terminalID: terminalID)
        return try await runBlit(args, socket: socket)
    }

    /// Visible screen text with ANSI escape sequences preserved (for snapshots).
    public func capturePaneWithAnsi(socket: String, terminalID: String) async throws -> String {
        if dryRun { return "" }
        let args = Self.showAnsiCommand(terminalID: terminalID)
        return try await runBlit(args, socket: socket)
    }

    /// Kills a terminal (`kill <ID> <signal>`) then frees the slot
    /// (`close <ID>`). When `close` is false (used by Ctrl-C), only the signal
    /// is delivered.
    public func killWindow(socket: String, terminalID: String, signal: String = "TERM", close: Bool = true) async throws {
        let killArgs = Self.killCommand(terminalID: terminalID, signal: signal)
        let closeArgs = Self.closeCommand(terminalID: terminalID)
        if dryRun {
            dryRunRecorder?(killArgs)
            if close { dryRunRecorder?(closeArgs) }
            return
        }
        _ = try await runBlit(killArgs, socket: socket)
        if close {
            // Best-effort: the kill already succeeded; don't fail if the slot is
            // already gone.
            _ = try? await runBlit(closeArgs, socket: socket)
        }
    }

    /// All live terminal IDs on the server (first TSV column of
    /// `blit terminal list`, header row skipped).
    public func listWindows(socket: String) async throws -> [String] {
        if dryRun { return dryRunListWindows?(socket) ?? [] }
        let args = Self.listCommand()
        let output = try await runBlit(args, socket: socket)
        return Self.parseTerminalList(output)
    }

    /// Parses `blit terminal list` TSV (`ID  TAG  TITLE  COMMAND  STATUS`) into
    /// the list of terminal IDs. Skips a header row whose first column is not an
    /// integer (the literal `ID` header).
    public static func parseTerminalList(_ output: String) -> [String] {
        var ids: [String] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Columns are tab- or whitespace-separated; the ID is the first.
            guard let first = trimmed.split(whereSeparator: { $0 == "\t" || $0 == " " }).first else { continue }
            let token = String(first)
            // Skip the header row ("ID …").
            if Int(token) == nil { continue }
            ids.append(token)
        }
        return ids
    }

    /// Whether a terminal ID is present in `blit terminal list`.
    public func windowExists(socket: String, terminalID: String) async -> Bool {
        if dryRun { return !(dryRunWindowIsDead?(terminalID) ?? false) }
        guard let ids = try? await listWindows(socket: socket) else { return false }
        return ids.contains(terminalID)
    }

    /// Whether a blit server is reachable on `socket` (the socket file exists
    /// AND `blit terminal list` succeeds).
    public func serverExists(socket: String) async -> Bool {
        if dryRun { return true }
        guard FileManager.default.fileExists(atPath: socket) else { return false }
        return (try? await runBlit(Self.listCommand(), socket: socket)) != nil
    }

    /// Reads the post-`exec` PID the spawn wrapper wrote to `pidfile`. blit
    /// exposes no PID, so this is how the daemon maps a terminal to a real PID
    /// for `~/.claude/sessions/<pid>.json` lookups. Returns nil if the file is
    /// missing or unparsable.
    public func leaderPID(forPidfile pidfile: String) -> Int32? {
        guard let contents = try? String(contentsOfFile: pidfile, encoding: .utf8) else { return nil }
        return Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Private helpers

    /// Resolves the `blit` binary path: explicit override first, then common
    /// install locations, then bare `blit` (PATH lookup via the resolved
    /// executable). The CDN installer drops it at `~/.local/bin/blit`.
    private func blitPath() -> String {
        if let blitBinaryOverride { return blitBinaryOverride }
        return Self.resolveBlitPath()
    }

    static func resolveBlitPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/blit",
            "/opt/homebrew/bin/blit",
            "/usr/local/bin/blit",
            "/usr/bin/blit",
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        // Fall back to a PATH lookup via /usr/bin/env so a blit on PATH still
        // works even if it's in none of the well-known locations.
        return "/usr/bin/env"
    }

    /// Whether the resolved path needs `blit` prepended to argv (the env
    /// fallback) vs. being a direct path to the binary.
    private func argvPrefix(for path: String) -> [String] {
        path == "/usr/bin/env" ? ["blit"] : []
    }

    /// Writes `secrets` to a 0600 temp file under the run dir for the wrapper to
    /// source. Format: `export KEY='value'` lines won't work with `set -a; .`,
    /// so we emit plain `KEY=value` and let `set -a` export them.
    static func writeEnvFile(_ secrets: [String: String], repoPath: String, tag: String, environment: [String: String]) throws -> String {
        let runDir = runDir(environment: environment)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let name = serverName(forRepoPath: repoPath)
        let path = runDir.appendingPathComponent("\(name)-\(tag).env").path
        var lines = ""
        for (key, value) in secrets.sorted(by: { $0.key < $1.key }) {
            // Single-quote the value for `.`/`source` parsing; escape embedded
            // single quotes the POSIX way.
            let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
            lines += "\(key)='\(escaped)'\n"
        }
        try lines.write(toFile: path, atomically: true, encoding: .utf8)
        // Tighten to 0600 — secrets must not be world/group readable.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return path
    }

    /// POSIX single-quote a string for safe inclusion in a shell wrapper.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Allocates a free loopback TCP port by binding to 127.0.0.1:0 and reading
    /// back the kernel-assigned port, then closing. There's an inherent TOCTOU
    /// window, but it's the standard approach for "give me a free port".
    static func allocateFreeLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BlitError.portAllocationFailed }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ask the kernel for any free port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw BlitError.portAllocationFailed }
        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &len)
            }
        }
        guard nameResult == 0 else { throw BlitError.portAllocationFailed }
        return Int(UInt16(bigEndian: boundAddr.sin_port))
    }

    /// A URL-safe random passphrase for the gateway handshake.
    static func randomPassphrase() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Polls for the socket file to appear, up to ~5s. blit's server binds the
    /// socket once it's ready to accept commands.
    private func waitForSocket(_ path: String, timeout: TimeInterval = 5.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        if !FileManager.default.fileExists(atPath: path) {
            throw BlitError.serverNotReady(path)
        }
    }

    /// Spawns a long-lived detached blit process (server / gateway). Does not
    /// wait for exit. Inherits the environment plus `extraEnv`.
    private func spawnDetached(_ arguments: [String], extraEnv: [String: String]) throws {
        let path = blitPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = argvPrefix(for: path) + arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Runs a one-shot blit command targeting `socket` (via `BLIT_SOCK`), with
    /// `BLIT_PROXY=0` so the proxy daemon doesn't interfere. Optional `stdin`
    /// is fed to the process (used by `send <ID> -`). Returns stdout.
    @discardableResult
    private func runBlit(_ arguments: [String], socket: String, stdin: String? = nil) async throws -> String {
        let path = blitPath()
        let prefix = argvPrefix(for: path)
        let fullArgs = prefix + arguments
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe = stdin != nil ? Pipe() : nil

            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = fullArgs
            var env = ProcessInfo.processInfo.environment
            env["BLIT_SOCK"] = socket
            env["BLIT_PROXY"] = "0"
            process.environment = env
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            if let stdinPipe { process.standardInput = stdinPipe }

            let commandDescription = "blit " + arguments.joined(separator: " ")

            process.terminationHandler = { _ in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: stdoutData, encoding: .utf8) ?? ""
                let err = String(data: stderrData, encoding: .utf8) ?? ""
                if process.terminationStatus != 0 {
                    continuation.resume(throwing: BlitError.commandFailed(
                        command: commandDescription,
                        status: process.terminationStatus,
                        output: out.isEmpty ? err : out
                    ))
                } else {
                    continuation.resume(returning: out)
                }
            }

            do {
                try process.run()
                if let stdin, let stdinPipe {
                    let handle = stdinPipe.fileHandleForWriting
                    handle.write(Data(stdin.utf8))
                    try? handle.close()
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

public enum BlitError: Error, Sendable {
    case commandFailed(command: String, status: Int32, output: String)
    case unexpectedOutput(String)
    case serverNotReady(String)
    case portAllocationFailed
}
