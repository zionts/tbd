import ArgumentParser
import Foundation
import TBDShared

/// `tbd bench` — manage Benches: persistent homes for recurring tasks.
///
/// A Bench is a folder (`$TBD_HOME/benches/<name>/`) holding a self-refining
/// runbook (`bench.md`), domain `skills/`, and one `runs/<timestamp>/` dir per
/// run. Each run spawns a disposable child worktree session (via the
/// orchestration-spine worktree-create RPC) that does the task, writes its
/// deliverable to the run dir's `output.md`, and appends durable learnings back
/// into `bench.md`.
struct BenchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Manage Benches (persistent homes for recurring tasks)",
        subcommands: [
            BenchCreate.self,
            BenchList.self,
            BenchRuns.self,
            BenchRun.self,
            BenchCapture.self,
        ]
    )
}

// MARK: - Shared helpers

/// A stable, filesystem-safe ISO-ish timestamp used for run directory names.
/// e.g. `20260617T143005Z`.
func benchRunTimestamp(_ date: Date = Date()) -> String {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return fmt.string(from: date)
}

// MARK: - bench create

struct BenchCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Scaffold a new bench"
    )

    @Argument(help: "Bench name (single path-safe segment)")
    var name: String

    @Option(name: .long, help: "Default repo for runs (written into bench.md frontmatter)")
    var repo: String?

    mutating func run() async throws {
        let created = ISO8601DateFormatter().string(from: Date())
        let benchDir = try BenchFileOps.create(
            benchesDir: TBDConstants.benchesDir,
            name: name,
            repo: repo,
            created: created
        )
        print("Created bench: \(name)")
        print("  Path: \(benchDir.path)")
    }
}

// MARK: - bench list

struct BenchList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List benches"
    )

    @Flag(name: .long, help: "Output JSON")
    var json = false

    struct Row: Encodable {
        let name: String
        let path: String
        let lastRun: String?
        let runCount: Int
    }

    mutating func run() async throws {
        let benchesDir = TBDConstants.benchesDir
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: benchesDir.path)) ?? []
        let names = entries
            .filter { entry in
                var isDir: ObjCBool = false
                let path = benchesDir.appendingPathComponent(entry).path
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }
            .sorted()

        var rows: [Row] = []
        for name in names {
            let benchDir = BenchLayout.benchDir(benchesDir: benchesDir, name: name)
            let timestamps = BenchFileOps.runTimestamps(benchDir: benchDir)
            rows.append(Row(name: name, path: benchDir.path, lastRun: timestamps.last, runCount: timestamps.count))
        }

        if json {
            printJSON(rows)
            return
        }
        if rows.isEmpty {
            print("No benches found. Create one with `tbd bench create <name>`.")
            return
        }
        let header = String(format: "%-24s  %-18s  %s", "NAME", "LAST RUN", "RUNS")
        print(header)
        print(String(repeating: "-", count: 56))
        for row in rows {
            print(String(format: "%-24s  %-18s  %d",
                row.name as NSString,
                (row.lastRun ?? "-") as NSString,
                row.runCount))
        }
    }
}

// MARK: - bench runs

struct BenchRuns: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runs",
        abstract: "List a bench's runs"
    )

    @Argument(help: "Bench name")
    var name: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    struct Row: Encodable {
        let timestamp: String
        let worktreeID: String?
        let hasOutput: Bool
        let hasTranscript: Bool
    }

    mutating func run() async throws {
        let benchDir = try BenchFileOps.requireBenchDir(benchesDir: TBDConstants.benchesDir, name: name)
        let fm = FileManager.default
        let timestamps = BenchFileOps.runTimestamps(benchDir: benchDir)

        var rows: [Row] = []
        for ts in timestamps {
            let runDir = BenchLayout.runDir(benchDir: benchDir, timestamp: ts)
            var worktreeID: String?
            if let data = try? Data(contentsOf: BenchLayout.runJSONPath(runDir: runDir)),
               let record = try? BenchRunRecord.decode(from: data) {
                worktreeID = record.worktreeID
            }
            rows.append(Row(
                timestamp: ts,
                worktreeID: worktreeID,
                hasOutput: fm.fileExists(atPath: BenchLayout.outputPath(runDir: runDir).path),
                hasTranscript: fm.fileExists(atPath: BenchLayout.transcriptPath(runDir: runDir).path)
            ))
        }

        if json {
            printJSON(rows)
            return
        }
        if rows.isEmpty {
            print("No runs for bench '\(name)'.")
            return
        }
        let header = String(format: "%-18s  %-36s  %-7s  %s", "TIMESTAMP", "WORKTREE", "OUTPUT", "TRANSCRIPT")
        print(header)
        print(String(repeating: "-", count: 80))
        for row in rows {
            print(String(format: "%-18s  %-36s  %-7s  %s",
                row.timestamp as NSString,
                (row.worktreeID ?? "-") as NSString,
                (row.hasOutput ? "yes" : "no") as NSString,
                (row.hasTranscript ? "yes" : "no") as NSString))
        }
    }
}

// MARK: - bench run

struct BenchRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start a new run of a bench (spawns a child worktree session)"
    )

    @Argument(help: "Bench name")
    var name: String

    @Option(name: .long, help: "Repo for this run (overrides bench.md frontmatter repo:)")
    var repo: String?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let benchDir = try BenchFileOps.requireBenchDir(benchesDir: TBDConstants.benchesDir, name: name)
        let runbookPath = BenchLayout.runbookPath(benchDir: benchDir)
        let runbookMarkdown = (try? String(contentsOf: runbookPath, encoding: .utf8)) ?? ""
        let frontmatter = BenchFrontmatter.parse(markdown: runbookMarkdown)

        // Repo precedence: --repo > frontmatter repo: > error.
        let repoSpec = try resolveBenchRepo(explicit: repo, frontmatter: frontmatter, benchName: name)

        let client = SocketClient()
        let repoID: UUID
        if let id = UUID(uuidString: repoSpec) {
            repoID = id
        } else {
            let resolver = PathResolver(client: client)
            repoID = try resolver.resolveRepoID(path: repoSpec)
        }

        // Create the run dir.
        let timestamp = benchRunTimestamp()
        let runDir = BenchLayout.runDir(benchDir: benchDir, timestamp: timestamp)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

        // Compose the session seed.
        let body = BenchTemplate.body(ofMarkdown: runbookMarkdown)
        let brief = BenchTemplate.runBrief(
            runbookBody: body,
            runDirPath: runDir.path,
            runbookPath: runbookPath.path
        )
        let prompt = "Begin this bench run. Follow your Runbook and Run protocol."

        // Position: child of the caller if running inside a TBD terminal, else root.
        let callerEnvID = ProcessInfo.processInfo.environment["TBD_WORKTREE_ID"]
            .flatMap { UUID(uuidString: $0) }
        let parenting = (callerEnvID != nil ? WorktreePosition.child : WorktreePosition.root)
            .rpcFields(callerEnvID: callerEnvID)

        let displayName = "\(name) · \(timestamp)"

        let worktree: Worktree = try client.call(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(
                repoID: repoID,
                displayName: displayName,
                prompt: prompt,
                siblingOfWorktreeID: parenting.siblingOfWorktreeID,
                callerWorktreeID: parenting.callerWorktreeID,
                suppressAutoParent: parenting.suppressAutoParent,
                role: .worker,
                brief: brief
            ),
            resultType: Worktree.self
        )

        // Persist run.json.
        let record = BenchRunRecord(
            benchName: name,
            worktreeID: worktree.id.uuidString,
            startedAt: ISO8601DateFormatter().string(from: Date()),
            repo: repoSpec
        )
        try record.encoded().write(to: BenchLayout.runJSONPath(runDir: runDir))

        // Drop the capture marker into the spawned worktree so session-end
        // capture (or `tbd bench capture`) can find the run dir.
        let marker = BenchRunMarker(benchName: name, runDir: runDir.path)
        if !worktree.path.isEmpty {
            let markerPath = BenchLayout.markerPath(worktreePath: worktree.path)
            try? marker.encoded().write(to: markerPath)
        }

        if json {
            struct Out: Encodable {
                let benchName: String
                let worktreeID: String
                let runDir: String
                let worktreePath: String
            }
            printJSON(Out(
                benchName: name,
                worktreeID: worktree.id.uuidString,
                runDir: runDir.path,
                worktreePath: worktree.path
            ))
        } else {
            print("Started bench run: \(name)")
            print("  Worktree: \(worktree.id)")
            print("  Run dir:  \(runDir.path)")
        }
    }
}

// MARK: - bench capture

struct BenchCapture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Capture a run's worktree transcript into the run dir"
    )

    @Argument(help: "Bench name")
    var name: String

    @Option(name: .long, help: "Run timestamp, or 'latest' (default: latest)")
    var run: String = "latest"

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let benchDir = try BenchFileOps.requireBenchDir(benchesDir: TBDConstants.benchesDir, name: name)
        let timestamps = BenchFileOps.runTimestamps(benchDir: benchDir)
        let ts = try resolveBenchRunSelector(run, available: timestamps, benchName: name)

        let runDir = BenchLayout.runDir(benchDir: benchDir, timestamp: ts)
        let client = SocketClient()
        let written = try BenchCaptureCore.capture(runDir: runDir, benchName: name, client: client)

        if json {
            printJSON(["status": "captured", "transcript": written])
        } else {
            print("Captured transcript: \(written)")
        }
    }
}

// MARK: - Capture core (shared by `bench capture` and auto-capture)

/// Reusable transcript-capture logic. Resolves a terminal in the run's
/// worktree, pulls its transcript via the `terminal.transcript` RPC, renders
/// markdown, and writes `transcript.md` into the run dir. Returns the path
/// written.
enum BenchCaptureCore {
    static func capture(runDir: URL, benchName: String, client: SocketClient) throws -> String {
        // Read run.json for the worktree ID.
        let recordData = try Data(contentsOf: BenchLayout.runJSONPath(runDir: runDir))
        let record = try BenchRunRecord.decode(from: recordData)
        guard let worktreeID = UUID(uuidString: record.worktreeID) else {
            throw BenchError.runNotFound("Run \(runDir.lastPathComponent) has no valid worktree ID.")
        }

        // Find a terminal in that worktree. Prefer the first one.
        let terminals: [Terminal] = try client.call(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: worktreeID),
            resultType: [Terminal].self
        )
        guard let terminal = terminals.first else {
            throw BenchError.runNotFound("No terminal found in worktree \(worktreeID) for bench '\(benchName)'.")
        }

        let result: TerminalTranscriptResult = try client.call(
            method: RPCMethod.terminalTranscript,
            params: TerminalTranscriptParams(terminalID: terminal.id),
            resultType: TerminalTranscriptResult.self
        )

        let md = BenchTranscript.markdown(items: result.messages, sessionID: result.sessionID, benchName: benchName)
        let transcriptPath = BenchLayout.transcriptPath(runDir: runDir)
        try md.write(to: transcriptPath, atomically: true, encoding: .utf8)
        return transcriptPath.path
    }
}
