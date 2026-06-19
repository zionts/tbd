import Foundation
import TBDShared

// MARK: - Bench errors

enum BenchError: Error, CustomStringConvertible {
    case alreadyExists(String)
    case notFound(String)
    case noRepo(String)
    case noRuns(String)
    case runNotFound(String)
    case invalidName(String)

    var description: String {
        switch self {
        case .alreadyExists(let msg): return msg
        case .notFound(let msg): return msg
        case .noRepo(let msg): return msg
        case .noRuns(let msg): return msg
        case .runNotFound(let msg): return msg
        case .invalidName(let msg): return msg
        }
    }
}

// MARK: - Bench layout

/// Pure path/layout helpers for a Bench. All resolution is relative to a
/// `benchesDir` URL (injected so tests can point at a temp dir instead of
/// `$TBD_HOME/benches`).
enum BenchLayout {
    /// `$benchesDir/<name>/`
    static func benchDir(benchesDir: URL, name: String) -> URL {
        benchesDir.appendingPathComponent(name, isDirectory: true)
    }

    /// `$benchesDir/<name>/bench.md`
    static func runbookPath(benchDir: URL) -> URL {
        benchDir.appendingPathComponent("bench.md")
    }

    /// `$benchesDir/<name>/skills/`
    static func skillsDir(benchDir: URL) -> URL {
        benchDir.appendingPathComponent("skills", isDirectory: true)
    }

    /// `$benchesDir/<name>/runs/`
    static func runsDir(benchDir: URL) -> URL {
        benchDir.appendingPathComponent("runs", isDirectory: true)
    }

    /// `$benchesDir/<name>/runs/<timestamp>/`
    static func runDir(benchDir: URL, timestamp: String) -> URL {
        runsDir(benchDir: benchDir).appendingPathComponent(timestamp, isDirectory: true)
    }

    /// The deliverable the agent writes into a run dir.
    static func outputPath(runDir: URL) -> URL {
        runDir.appendingPathComponent("output.md")
    }

    /// The captured transcript for a run.
    static func transcriptPath(runDir: URL) -> URL {
        runDir.appendingPathComponent("transcript.md")
    }

    /// The run metadata file.
    static func runJSONPath(runDir: URL) -> URL {
        runDir.appendingPathComponent("run.json")
    }

    /// The capture marker dropped into the spawned worktree so session-end
    /// capture (or `tbd bench capture`) can locate the run dir.
    static let markerFileName = ".tbd-bench-run.json"

    static func markerPath(worktreePath: String) -> URL {
        URL(fileURLWithPath: worktreePath, isDirectory: true)
            .appendingPathComponent(markerFileName)
    }

    /// Validate a bench name: must be a single safe path component.
    static func validateName(_ name: String) throws {
        if name.isEmpty {
            throw BenchError.invalidName("Bench name must not be empty.")
        }
        if name == "." || name == ".." || name.contains("/") {
            throw BenchError.invalidName("Invalid bench name '\(name)'. Use a single path-safe segment.")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        if name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            throw BenchError.invalidName(
                "Invalid bench name '\(name)'. Use only letters, digits, hyphens, underscores, or dots."
            )
        }
    }
}

// MARK: - Filesystem ops (dir-injectable, testable)

/// Pure-ish filesystem operations for benches, parameterized on `benchesDir`
/// so tests can run them against a temp directory instead of `$TBD_HOME`.
enum BenchFileOps {
    /// Scaffold a new bench directory tree. Throws `.alreadyExists` if present.
    static func create(benchesDir: URL, name: String, repo: String?, created: String) throws -> URL {
        try BenchLayout.validateName(name)
        let benchDir = BenchLayout.benchDir(benchesDir: benchesDir, name: name)
        if FileManager.default.fileExists(atPath: benchDir.path) {
            throw BenchError.alreadyExists("Bench already exists: '\(name)' (\(benchDir.path)).")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: benchDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: BenchLayout.skillsDir(benchDir: benchDir), withIntermediateDirectories: true)
        try fm.createDirectory(at: BenchLayout.runsDir(benchDir: benchDir), withIntermediateDirectories: true)
        let runbook = BenchTemplate.runbook(name: name, repo: repo, created: created)
        try runbook.write(to: BenchLayout.runbookPath(benchDir: benchDir), atomically: true, encoding: .utf8)
        return benchDir
    }

    /// Resolve an existing bench dir, throwing `.notFound` if absent.
    static func requireBenchDir(benchesDir: URL, name: String) throws -> URL {
        try BenchLayout.validateName(name)
        let dir = BenchLayout.benchDir(benchesDir: benchesDir, name: name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw BenchError.notFound("Bench not found: '\(name)' (expected at \(dir.path)). Create it with `tbd bench create \(name)`.")
        }
        return dir
    }

    /// Sorted (ascending) run timestamps for a bench (directory names under runs/).
    static func runTimestamps(benchDir: URL) -> [String] {
        let runsDir = BenchLayout.runsDir(benchDir: benchDir)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: runsDir.path)) ?? []
        return entries
            .filter { entry in
                var isDir: ObjCBool = false
                let path = runsDir.appendingPathComponent(entry).path
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }
            .sorted()
    }
}

/// Resolve which run timestamp a capture/inspect command should target.
/// `selector` is either `"latest"` or an exact timestamp. Pure so the
/// latest-vs-named branch is unit-testable.
func resolveBenchRunSelector(_ selector: String, available: [String], benchName: String) throws -> String {
    guard !available.isEmpty else {
        throw BenchError.noRuns("No runs to capture for bench '\(benchName)'.")
    }
    if selector == "latest" {
        return available.last!
    }
    if available.contains(selector) {
        return selector
    }
    throw BenchError.runNotFound("No run '\(selector)' for bench '\(benchName)'.")
}

// MARK: - run.json model

/// Metadata persisted for a single bench run at `runs/<ts>/run.json`.
struct BenchRunRecord: Codable, Equatable {
    let benchName: String
    let worktreeID: String
    let startedAt: String
    let repo: String

    init(benchName: String, worktreeID: String, startedAt: String, repo: String) {
        self.benchName = benchName
        self.worktreeID = worktreeID
        self.startedAt = startedAt
        self.repo = repo
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(from data: Data) throws -> BenchRunRecord {
        try JSONDecoder().decode(BenchRunRecord.self, from: data)
    }
}

// MARK: - capture marker model

/// The `.tbd-bench-run.json` marker file written into a run's worktree.
/// `runDir` is an absolute path so the capture step needs no other context.
struct BenchRunMarker: Codable, Equatable {
    let benchName: String
    let runDir: String

    init(benchName: String, runDir: String) {
        self.benchName = benchName
        self.runDir = runDir
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(from data: Data) throws -> BenchRunMarker {
        try JSONDecoder().decode(BenchRunMarker.self, from: data)
    }
}

// MARK: - bench.md frontmatter + templating

/// Minimal frontmatter parsed from a `bench.md` runbook. Only the keys the
/// CLI cares about are extracted; anything else is ignored.
struct BenchFrontmatter: Equatable {
    var name: String?
    var repo: String?
    var created: String?

    /// Parse a leading `--- ... ---` YAML-ish frontmatter block. We only need
    /// flat `key: value` pairs, so this is a deliberately tiny scanner rather
    /// than a YAML dependency.
    static func parse(markdown: String) -> BenchFrontmatter {
        var fm = BenchFrontmatter()
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return fm
        }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Strip optional surrounding quotes.
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if value.isEmpty { continue }
            switch key {
            case "name": fm.name = value
            case "repo": fm.repo = value
            case "created": fm.created = value
            default: break
            }
        }
        return fm
    }
}

/// Resolve the repo for a run with the documented precedence:
/// explicit `--repo` > bench.md frontmatter `repo:` > error.
func resolveBenchRepo(explicit: String?, frontmatter: BenchFrontmatter, benchName: String) throws -> String {
    if let explicit, !explicit.isEmpty {
        return explicit
    }
    if let fmRepo = frontmatter.repo, !fmRepo.isEmpty {
        return fmRepo
    }
    throw BenchError.noRepo(
        "No repo for bench '\(benchName)'. Pass --repo <repo> or add a `repo:` line to its bench.md frontmatter."
    )
}

// MARK: - bench.md template

enum BenchTemplate {
    /// Render the initial `bench.md` runbook for a freshly-created bench.
    /// The Run protocol section is FIXED boilerplate; the run command later
    /// interpolates the concrete run-dir / bench.md paths when it composes
    /// the session brief (the template keeps placeholder language so a human
    /// reading the file understands the contract).
    static func runbook(name: String, repo: String?, created: String) -> String {
        var lines: [String] = []
        lines.append("---")
        lines.append("name: \(name)")
        if let repo, !repo.isEmpty {
            lines.append("repo: \(repo)")
        }
        lines.append("created: \(created)")
        lines.append("---")
        lines.append("")
        lines.append("# \(name)")
        lines.append("")
        lines.append("## Purpose")
        lines.append("")
        lines.append("_Describe what this bench is for — the recurring task it owns._")
        lines.append("")
        lines.append("## Runbook")
        lines.append("")
        lines.append("_The steps the agent follows on each run. Keep them concrete and ordered._")
        lines.append("")
        lines.append("1. ")
        lines.append("")
        lines.append("## Preferences")
        lines.append("")
        lines.append("_User preferences for this task. The agent self-refines this section: when it")
        lines.append("learns a durable preference during a run, it appends it here._")
        lines.append("")
        lines.append("## Run protocol")
        lines.append("")
        lines.append("_Fixed instructions for every run — do not remove:_")
        lines.append("")
        lines.append("- Write your deliverable for this run to the run directory's `output.md`.")
        lines.append("- Before finishing, append any durable learnings to this bench's `bench.md`")
        lines.append("  under **Preferences** (user prefs) or **Runbook** (process improvements),")
        lines.append("  so future runs start smarter. This is a self-refining runbook.")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Compose the session brief for a run: the bench.md body plus a concrete
    /// Run protocol with the ABSOLUTE run-dir and bench.md paths interpolated,
    /// so the spawned agent knows exactly where to write `output.md` and which
    /// file to append learnings to.
    static func runBrief(runbookBody: String, runDirPath: String, runbookPath: String) -> String {
        var out = runbookBody
        if !out.hasSuffix("\n") { out += "\n" }
        out += """

        ---

        ## This run

        You are executing one run of this bench. Concrete paths for THIS run:

        - Run directory: `\(runDirPath)`
        - Write your deliverable to: `\(runDirPath)/output.md`
        - This bench's runbook (append durable learnings here before finishing): `\(runbookPath)`

        Follow the Runbook and Run protocol above. When you finish:
        1. Ensure your deliverable is saved at `\(runDirPath)/output.md`.
        2. Append any durable learnings (user preferences, process improvements)
           to `\(runbookPath)` under its Preferences or Runbook section.
        """
        return out
    }

    /// Strip a leading frontmatter block from a bench.md, returning just the
    /// body (so the brief doesn't leak frontmatter into the system prompt).
    static func body(ofMarkdown markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return markdown
        }
        var idx = 1
        while idx < lines.count {
            if lines[idx].trimmingCharacters(in: .whitespaces) == "---" {
                idx += 1
                break
            }
            idx += 1
        }
        // Skip a single blank line right after the closing fence for tidiness.
        if idx < lines.count, lines[idx].trimmingCharacters(in: .whitespaces).isEmpty {
            idx += 1
        }
        return lines[idx...].joined(separator: "\n")
    }
}

// MARK: - transcript → markdown

enum BenchTranscript {
    /// Render a captured `[TranscriptItem]` list into readable markdown for
    /// `transcript.md`. Pure so it's unit-testable without a daemon.
    static func markdown(items: [TranscriptItem], sessionID: String?, benchName: String) -> String {
        var out: [String] = []
        out.append("# Transcript — \(benchName)")
        out.append("")
        if let sessionID, !sessionID.isEmpty {
            out.append("Session: `\(sessionID)`")
            out.append("")
        }
        if items.isEmpty {
            out.append("_No transcript items captured._")
            out.append("")
            return out.joined(separator: "\n")
        }
        for item in items {
            switch item {
            case .userPrompt(_, let text, _):
                out.append("## User")
                out.append("")
                out.append(text)
            case .assistantText(_, let text, _, _):
                out.append("## Assistant")
                out.append("")
                out.append(text)
            case .thinking(_, let text, _):
                out.append("## Thinking")
                out.append("")
                out.append(text)
            case .toolCall(_, let name, let inputJSON, _, _, _, _, _):
                out.append("### Tool: \(name)")
                out.append("")
                out.append("```json")
                out.append(inputJSON)
                out.append("```")
            case .slashCommand(_, let name, let args, _):
                out.append("## /\(name) \(args ?? "")")
            case .systemReminder(_, _, let text, _):
                out.append("> system: \(text)")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}
