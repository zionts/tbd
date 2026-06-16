import Foundation
import Testing
@testable import TBDDaemonLib

@Suite struct WorktreeLifecycleReaperTests {
    /// Builds a WorktreeLifecycle with a dryRun blit (killWindow no-ops,
    /// leaderPID reads the real pidfile), an in-memory DB, tiny reaper grace
    /// knobs, and the injected process signaller.
    private func makeLifecycle(signaller: FakeProcessSignaller) throws -> WorktreeLifecycle {
        let db = try TBDDatabase(inMemory: true)
        return WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true),
            blit: BlitManager(dryRun: true),
            hooks: HookResolver(),
            processSignaller: signaller,
            reaperGraceAttempts: 2,
            reaperPollInterval: .milliseconds(1)
        )
    }

    /// Writes a per-terminal pidfile containing `pid` and returns its path.
    private func writePidfile(_ pid: Int32) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-reaper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("t.pid").path
        try "\(pid)\n".write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// A wedged agent process that survives kill's signal gets escalated.
    @Test func killTerminalAndReapEscalatesSurvivor() async throws {
        let sig = FakeProcessSignaller()
        // The pidfile resolves the leader PID to 0; the fake signaller scripts
        // its survival so the escalation path runs in isolation. (Production
        // isAlive(0) returns false via `guard pid > 0`, so only the fake
        // escalates here.)
        sig.behaviors[0] = .init(aliveInitially: true, aliveAfterTerminate: true, aliveAfterKill: false)
        let lifecycle = try makeLifecycle(signaller: sig)
        let pidfile = try writePidfile(0)
        await lifecycle.killTerminalAndReap(socket: "/tmp/blit.sock", terminalID: "1", pidfile: pidfile)
        #expect(sig.terminated == [0])
        #expect(sig.killed == [0])
    }

    @Test func killTerminalAndReapNoOpWhenAgentAlreadyDead() async throws {
        let sig = FakeProcessSignaller()
        sig.behaviors[0] = .init(aliveInitially: false)
        let lifecycle = try makeLifecycle(signaller: sig)
        let pidfile = try writePidfile(0)
        await lifecycle.killTerminalAndReap(socket: "/tmp/blit.sock", terminalID: "1", pidfile: pidfile)
        #expect(sig.terminated.isEmpty)
        #expect(sig.killed.isEmpty)
    }

    @Test func reapServerChildrenRunsForOwnedChildren() async {
        // Unit-level guard on the reaper method reconcile now calls before kill-server.
        let tmux = FakeTmuxQuerier(); let sig = FakeProcessSignaller()
        tmux.serverPIDs = ["tbd-x": 500]
        sig.childrenByServer = [500: [77]]
        sig.cmdlines = [77: "claude --plugin-dir /x/TBD/plugin"]
        sig.behaviors = [77: .init(aliveAfterTerminate: false)]
        let reaper = AgentReaper(tmux: tmux, signaller: sig, graceAttempts: 1, pollInterval: .milliseconds(1))
        await reaper.reapServerChildren(server: "tbd-x")
        #expect(sig.terminated == [77])
    }
}
