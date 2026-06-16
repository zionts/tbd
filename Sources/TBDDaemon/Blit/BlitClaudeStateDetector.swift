import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "BlitClaudeState")

/// Blit-backed Claude idle/session detector.
///
/// Mirrors the idle/busy marker logic of the tmux `ClaudeStateDetector`
/// (`statusIndicators` / `busyIndicators`) on captured screen output, but
/// adapts the process-introspection guards to blit's model. blit exposes no
/// `pane_current_command` / `pane_pid`, so:
///
/// - the "is this pane actually running claude?" guard reads the leader PID
///   from the per-terminal pidfile (`BlitManager.leaderPID(forPidfile:)`),
///   confirms it is alive, and checks `ps -o comm= -p <pid>` is `claude`.
/// - `captureSessionID` maps the leader PID → `~/.claude/sessions/<pid>.json`,
///   keeping the `pgrep -P <pid> -x claude` child fallback for the case where
///   the leader is a shell that forked claude.
///
/// The pure static helpers (`checkIdle`, `parseSessionID`) reuse the tmux
/// detector's logic so behavior — and its tests — stay identical.
public struct BlitClaudeStateDetector: Sendable {
    private let blit: BlitManager

    public init(blit: BlitManager) { self.blit = blit }

    // MARK: - Pure marker helpers (delegate to the shared tmux detector)

    /// True when captured screen output shows Claude's idle prompt + status bar.
    public static func checkIdle(output: String) -> Bool {
        ClaudeStateDetector.checkIdle(output: output)
    }

    public static func parseSessionID(from json: String) -> String? {
        ClaudeStateDetector.parseSessionID(from: json)
    }

    public static func isClaudeProcess(_ command: String) -> Bool {
        ClaudeStateDetector.isClaudeProcess(command)
    }

    // MARK: - Process introspection (blit-specific)

    /// `ps -o comm= -p <pid>` → the executable name, trimmed. nil when the
    /// process is gone or `ps` fails. Used to confirm a pidfile's leader PID is
    /// actually `claude` (replaces tmux's `pane_current_command`).
    static func processName(pid: Int32) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "comm=", "-p", String(pid)]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the leader process recorded in `pidfile` is alive AND its
    /// executable basename is `claude`. The tmux detector matched a semver via
    /// `pane_current_command`; blit has no such field, so we resolve the PID and
    /// inspect the real process name instead.
    func isClaudeRunning(pidfile: String?) -> Bool {
        guard let pidfile, let pid = blit.leaderPID(forPidfile: pidfile) else { return false }
        guard kill(pid, 0) == 0 else { return false }
        guard let name = Self.processName(pid: pid) else { return false }
        let basename = (name as NSString).lastPathComponent
        return basename == "claude"
    }

    // MARK: - Idle detection

    public func isIdle(socket: String, terminalID: String, pidfile: String?) async -> Bool {
        guard isClaudeRunning(pidfile: pidfile) else { return false }
        do {
            let output = try await blit.capturePaneOutput(socket: socket, terminalID: terminalID)
            return Self.checkIdle(output: output)
        } catch { return false }
    }

    public func isIdleConfirmed(socket: String, terminalID: String, pidfile: String?) async -> Bool {
        guard await isIdle(socket: socket, terminalID: terminalID, pidfile: pidfile) else { return false }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return false }
        return await isIdle(socket: socket, terminalID: terminalID, pidfile: pidfile)
    }

    // MARK: - Session ID capture

    /// Resolves the Claude session ID for a blit terminal by mapping its leader
    /// PID (from the pidfile) → `~/.claude/sessions/<pid>.json`. Falls back to a
    /// single `claude` child (`pgrep -P <pid> -x claude`) when the leader is a
    /// shell that forked claude. Returns nil when nothing resolves.
    public func captureSessionID(pidfile: String?) async -> String? {
        guard let pidfile, let leaderPID = blit.leaderPID(forPidfile: pidfile) else { return nil }

        // The wrapper `exec`s claude, so the leader PID usually IS claude.
        if let id = readSessionID(forPID: Int(leaderPID)) { return id }

        // Fallback: leader is a shell, claude is a child process.
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(leaderPID), "-x", "claude"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let pids = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").compactMap { Int($0) }
        guard pids.count == 1, let claudePID = pids.first else { return nil }
        return readSessionID(forPID: claudePID)
    }

    /// Read a Claude session file for a given PID. Returns nil if the file
    /// doesn't exist or is invalid.
    private func readSessionID(forPID pid: Int) -> String? {
        let sessionPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions/\(pid).json")
        guard let json = try? String(contentsOf: sessionPath, encoding: .utf8) else { return nil }
        return Self.parseSessionID(from: json)
    }
}
