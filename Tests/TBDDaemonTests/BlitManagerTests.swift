import Foundation
import Testing
@testable import TBDDaemonLib

// MARK: - serverName / socketPath hashing

@Test func blitServerNameMatchesTmuxHash() {
    // BlitManager must reuse the EXACT djb2 hash TmuxManager uses so a repo's
    // blit socket name lines up 1:1 with its old tmux server name.
    let path = "/Users/dev/projects/tbd"
    #expect(BlitManager.serverName(forRepoPath: path) == TmuxManager.serverName(forRepoPath: path))
}

@Test func blitServerNameShapeAndDeterminism() {
    let path = "/tmp/some/repo"
    let name1 = BlitManager.serverName(forRepoPath: path)
    let name2 = BlitManager.serverName(forRepoPath: path)
    #expect(name1 == name2)
    #expect(name1.hasPrefix("tbd-"))
}

@Test func blitSocketPathUnderRunDirHonorsTBDHome() {
    let env = ["TBD_HOME": "/tmp/tbdhome"]
    let path = "/tmp/repo"
    let socket = BlitManager.socketPath(forRepoPath: path, environment: env)
    let name = BlitManager.serverName(forRepoPath: path)
    #expect(socket == "/tmp/tbdhome/run/\(name).sock")
    // Production-shaped path stays well under darwin's sun_path cap.
    #expect(socket.utf8.count < BlitManager.maxSocketPathLength)
}

@Test func blitPidfilePathHonorsTBDHome() {
    let env = ["TBD_HOME": "/tmp/tbdhome"]
    let path = "/tmp/repo"
    let pidfile = BlitManager.pidfilePath(forRepoPath: path, tag: "t-abc", environment: env)
    let name = BlitManager.serverName(forRepoPath: path)
    #expect(pidfile == "/tmp/tbdhome/run/\(name)-t-abc.pid")
}

// MARK: - Static command shapes

@Test func blitServerStartCommandShape() {
    #expect(BlitManager.serverStartCommand(socket: "/tmp/s.sock")
        == ["server", "--socket", "/tmp/s.sock"])
}

@Test func blitListCommandShape() {
    #expect(BlitManager.listCommand() == ["terminal", "list"])
}

@Test func blitShowCommands() {
    #expect(BlitManager.showCommand(terminalID: "3") == ["terminal", "show", "3"])
    #expect(BlitManager.showAnsiCommand(terminalID: "3") == ["terminal", "show", "--ansi", "3"])
}

@Test func blitSendKeysUsesStdinDash() {
    // Literal text path: `send <ID> -` (text supplied on stdin, not argv) so
    // blit doesn't C-escape-interpret it.
    #expect(BlitManager.sendKeysCommand(terminalID: "7") == ["terminal", "send", "7", "-"])
}

@Test func blitSendKeyEscapeSequences() {
    #expect(BlitManager.keySequences["Enter"] == "\\n")
    #expect(BlitManager.keySequences["Escape"] == "\\x1b")
    let args = BlitManager.sendKeyCommand(terminalID: "2", sequence: "\\n")
    #expect(args == ["terminal", "send", "2", "\\n"])
}

@Test func blitKillAndCloseCommands() {
    #expect(BlitManager.killCommand(terminalID: "5", signal: "TERM") == ["terminal", "kill", "5", "TERM"])
    #expect(BlitManager.closeCommand(terminalID: "5") == ["terminal", "close", "5"])
}

@Test func blitTerminalStartCommandWithSize() {
    let args = BlitManager.terminalStartCommand(tag: "t-x", wrapper: "echo hi", cols: 220, rows: 50)
    // Size flags use blit's --rows/--cols (not tmux's -x/-y).
    #expect(args.contains("--rows"))
    #expect(args.contains("50"))
    #expect(args.contains("--cols"))
    #expect(args.contains("220"))
    #expect(args.contains("-t"))
    #expect(args.contains("t-x"))
    // The `--` separator precedes the shell, and the wrapper is the last arg.
    #expect(args.contains("--"))
    #expect(args.last == "echo hi")
    #expect(args.contains("-lic"))
}

@Test func blitTerminalStartCommandWithoutSize() {
    let args = BlitManager.terminalStartCommand(tag: "t-x", wrapper: "echo hi")
    #expect(!args.contains("--rows"))
    #expect(!args.contains("--cols"))
}

@Test func blitTerminalStartIgnoresBelowMinimumSize() {
    let args = BlitManager.terminalStartCommand(tag: "t-x", wrapper: "echo hi", cols: 40, rows: 10)
    #expect(!args.contains("--rows"))
    #expect(!args.contains("--cols"))
}

// MARK: - Wrapper shape

@Test func blitWrapperOrderAndContents() {
    let wrapper = BlitManager.buildWrapper(
        cwd: "/tmp/work",
        shellCommand: "claude --dangerously-skip-permissions",
        env: ["FOO": "bar", "BAZ": "qux"],
        envFilePath: "/tmp/tbdhome/run/tbd-abc-t-x.env",
        pidfilePath: "/tmp/tbdhome/run/tbd-abc-t-x.pid"
    )
    // cd is first.
    #expect(wrapper.hasPrefix("cd '/tmp/work'"))
    // env-file is sourced and removed before env exports.
    #expect(wrapper.contains("set -a; . '/tmp/tbdhome/run/tbd-abc-t-x.env'; rm -f '/tmp/tbdhome/run/tbd-abc-t-x.env'; set +a"))
    // non-sensitive env exported (sorted).
    #expect(wrapper.contains("export BAZ='qux'"))
    #expect(wrapper.contains("export FOO='bar'"))
    // pidfile written then exec, in order, at the end.
    #expect(wrapper.contains("echo $$ > '/tmp/tbdhome/run/tbd-abc-t-x.pid'"))
    #expect(wrapper.hasSuffix("exec claude --dangerously-skip-permissions"))

    // Source must precede the exports, which must precede the pidfile/exec.
    let srcIdx = wrapper.range(of: "set -a;")!.lowerBound
    let pidIdx = wrapper.range(of: "echo $$")!.lowerBound
    let execIdx = wrapper.range(of: "exec ")!.lowerBound
    #expect(srcIdx < pidIdx)
    #expect(pidIdx < execIdx)
}

@Test func blitWrapperWithoutEnvFileOmitsSourceBlock() {
    let wrapper = BlitManager.buildWrapper(
        cwd: "/tmp/work",
        shellCommand: "zsh",
        env: [:],
        envFilePath: nil,
        pidfilePath: "/tmp/p.pid"
    )
    #expect(!wrapper.contains("set -a"))
    #expect(wrapper.hasPrefix("cd '/tmp/work'"))
    #expect(wrapper.hasSuffix("exec zsh"))
}

// MARK: - createWindow dry-run argv (the load-bearing assertions)

@Test func blitCreateWindowDryRunArgvShapeNoSecretLeak() async throws {
    let recorder = LockedCommandRecorder()
    let manager = BlitManager(dryRun: true, dryRunRecorder: { recorder.append($0) })
    let env = ["TBD_HOME": "/tmp/tbdhome"]
    let result = try await manager.createWindow(
        forRepoPath: "/tmp/repo",
        socket: "/tmp/tbdhome/run/s.sock",
        cwd: "/tmp/work",
        shellCommand: "claude",
        env: ["PUBLIC_VAR": "visible"],
        sensitiveEnv: ["ANTHROPIC_API_KEY": "sk-secret-do-not-leak"],
        cols: 220,
        rows: 50,
        environment: env
    )
    let calls = recorder.snapshot()
    #expect(calls.count == 1)
    let argv = calls[0]
    // Correct subcommand + size flags + tag + wrapper invocation.
    #expect(argv[0] == "terminal")
    #expect(argv[1] == "start")
    #expect(argv.contains("--rows"))
    #expect(argv.contains("--cols"))
    #expect(argv.contains("-t"))
    #expect(argv.contains("--"))
    #expect(argv.contains("-lic"))

    // The full argv must NOT contain the secret value anywhere — it lives only
    // in the 0600 env-file, sourced by the wrapper.
    let joined = argv.joined(separator: " ")
    #expect(!joined.contains("sk-secret-do-not-leak"))
    // The wrapper references the env-file and the pidfile.
    #expect(joined.contains(".env"))
    #expect(joined.contains(result.pidfilePath))
    // dry-run returns an integer-as-string ID.
    #expect(Int(result.terminalID) != nil)
    // pidfile path is under the TBD_HOME run dir.
    #expect(result.pidfilePath.hasPrefix("/tmp/tbdhome/run/"))
}

@Test func blitCreateWindowDryRunIDsIncrement() async throws {
    let manager = BlitManager(dryRun: true)
    let env = ["TBD_HOME": "/tmp/tbdhome"]
    let r1 = try await manager.createWindow(
        forRepoPath: "/tmp/repo", socket: "/tmp/s.sock", cwd: "/tmp",
        shellCommand: "zsh", environment: env
    )
    let r2 = try await manager.createWindow(
        forRepoPath: "/tmp/repo", socket: "/tmp/s.sock", cwd: "/tmp",
        shellCommand: "zsh", environment: env
    )
    #expect(r1.terminalID == "0")
    #expect(r2.terminalID == "1")
}

// MARK: - send / sendKey / sendCommand dry-run

@Test func blitSendKeyDryRunRecordsEscapeArgv() async throws {
    let recorder = LockedCommandRecorder()
    let manager = BlitManager(dryRun: true, dryRunRecorder: { recorder.append($0) })
    try await manager.sendKey(socket: "/tmp/s.sock", terminalID: "3", key: "Enter")
    let calls = recorder.snapshot()
    #expect(calls.count == 1)
    #expect(calls[0] == ["terminal", "send", "3", "\\n"])
}

@Test func blitSendKeyCtrlCDispatchesKillInt() async throws {
    let recorder = LockedCommandRecorder()
    let manager = BlitManager(dryRun: true, dryRunRecorder: { recorder.append($0) })
    try await manager.sendKey(socket: "/tmp/s.sock", terminalID: "3", key: "C-c")
    let calls = recorder.snapshot()
    // Ctrl-C maps to kill <ID> INT (no close).
    #expect(calls.count == 1)
    #expect(calls[0] == ["terminal", "kill", "3", "INT"])
}

@Test func blitKillWindowDryRunRecordsKillThenClose() async throws {
    let recorder = LockedCommandRecorder()
    let manager = BlitManager(dryRun: true, dryRunRecorder: { recorder.append($0) })
    try await manager.killWindow(socket: "/tmp/s.sock", terminalID: "9")
    let calls = recorder.snapshot()
    #expect(calls.count == 2)
    #expect(calls[0] == ["terminal", "kill", "9", "TERM"])
    #expect(calls[1] == ["terminal", "close", "9"])
}

@Test func blitEnsureServerDryRunRecords() async throws {
    let recorder = LockedCommandRecorder()
    let manager = BlitManager(dryRun: true, dryRunRecorder: { recorder.append($0) })
    try await manager.ensureServer(socket: "/tmp/s.sock")
    let calls = recorder.snapshot()
    #expect(calls.count == 1)
    #expect(calls[0] == ["server", "--socket", "/tmp/s.sock"])
}

// MARK: - list parsing / windowExists hooks

@Test func blitParseTerminalListSkipsHeader() {
    let tsv = """
    ID\tTAG\tTITLE\tCOMMAND\tSTATUS
    1\tt-a\tclaude\tclaude\trunning
    2\tt-b\tzsh\tzsh\trunning
    """
    #expect(BlitManager.parseTerminalList(tsv) == ["1", "2"])
}

@Test func blitParseTerminalListEmpty() {
    #expect(BlitManager.parseTerminalList("ID\tTAG\tTITLE\tCOMMAND\tSTATUS").isEmpty)
    #expect(BlitManager.parseTerminalList("").isEmpty)
}

@Test func blitListWindowsDryRunUsesHook() async throws {
    let manager = BlitManager(dryRun: true, dryRunListWindows: { _ in ["1", "2", "3"] })
    let ids = try await manager.listWindows(socket: "/tmp/s.sock")
    #expect(ids == ["1", "2", "3"])
}

@Test func blitListWindowsDryRunDefaultsEmpty() async throws {
    let manager = BlitManager(dryRun: true)
    let ids = try await manager.listWindows(socket: "/tmp/s.sock")
    #expect(ids.isEmpty)
}

@Test func blitWindowExistsDryRunHonorsDeadHook() async throws {
    let manager = BlitManager(dryRun: true, dryRunWindowIsDead: { $0 == "dead" })
    #expect(await manager.windowExists(socket: "/tmp/s.sock", terminalID: "alive") == true)
    #expect(await manager.windowExists(socket: "/tmp/s.sock", terminalID: "dead") == false)
}

// MARK: - leaderPID

@Test func blitLeaderPIDReadsPidfile() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("blit-pid-\(UUID().uuidString).pid")
    try "12345\n".write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let manager = BlitManager(dryRun: true)
    #expect(manager.leaderPID(forPidfile: tmp.path) == 12345)
}

@Test func blitLeaderPIDMissingFileReturnsNil() {
    let manager = BlitManager(dryRun: true)
    #expect(manager.leaderPID(forPidfile: "/tmp/does-not-exist-\(UUID().uuidString).pid") == nil)
}

// MARK: - ensureGateway (dry-run returns port + passphrase without spawning)

@Test func blitEnsureGatewayDryRunReturnsPortAndPassphrase() async throws {
    let recorder = LockedCommandRecorder()
    let manager = BlitManager(dryRun: true, dryRunRecorder: { recorder.append($0) })
    let result = try await manager.ensureGateway(socket: "/tmp/s.sock")
    #expect(result.port > 0)
    #expect(!result.passphrase.isEmpty)
    let calls = recorder.snapshot()
    #expect(calls.count == 1)
    #expect(calls[0] == ["gateway"])
}
