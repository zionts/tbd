import ArgumentParser
import Foundation
import TBDShared

/// `tbd hooks bench-capture` — Stop-hook handler that auto-captures a bench
/// run's transcript at end-of-turn.
///
/// This is wired as an ADDITIVE Stop-hook matcher in the Claude overlay,
/// independent of the existing notification / rename-check Stop hooks — it
/// never touches that sensitive logic. It is a strict no-op unless the
/// session's cwd contains a `.tbd-bench-run.json` marker (dropped by
/// `tbd bench run`), so it does nothing for ordinary (non-bench) sessions.
///
/// Because Claude's Stop hook fires at the end of every turn (not just the
/// final one), this re-captures on each turn; `transcript.md` is overwritten
/// atomically so it always reflects the latest state. Every failure path is a
/// silent exit 0 — a hook must never wedge the agent.
struct BenchCaptureHookCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench-capture",
        abstract: "Internal: Stop-hook handler that captures a bench run's transcript",
        shouldDisplay: false
    )

    mutating func run() async throws {
        // 1. Look for the marker in cwd (Claude runs Stop hooks in the
        //    session's working directory, i.e. the worktree path). Absent →
        //    not a bench run; silent exit.
        let cwd = FileManager.default.currentDirectoryPath
        let markerPath = BenchLayout.markerPath(worktreePath: cwd)
        guard let markerData = try? Data(contentsOf: markerPath),
              let marker = try? BenchRunMarker.decode(from: markerData) else {
            return
        }

        // 2. Daemon down → silent exit; the next turn's Stop hook retries.
        let client = SocketClient()
        guard client.isDaemonRunning else { return }

        // 3. Capture into the marker's run dir. Reuses the exact logic that
        //    `tbd bench capture` uses. Errors are swallowed — best-effort.
        let runDir = URL(fileURLWithPath: marker.runDir, isDirectory: true)
        _ = try? BenchCaptureCore.capture(runDir: runDir, benchName: marker.benchName, client: client)
    }
}
