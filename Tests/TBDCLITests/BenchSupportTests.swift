import Foundation
import Testing

@testable import TBDCLI
@testable import TBDShared

@Suite("Bench support — pure helpers")
struct BenchSupportTests {

    // MARK: - Name validation

    @Test func validNameAccepted() throws {
        try BenchLayout.validateName("daily-standup")
        try BenchLayout.validateName("report_v2.1")
    }

    @Test func emptyNameRejected() {
        #expect(throws: BenchError.self) { try BenchLayout.validateName("") }
    }

    @Test func slashInNameRejected() {
        #expect(throws: BenchError.self) { try BenchLayout.validateName("a/b") }
    }

    @Test func dotSegmentsRejected() {
        #expect(throws: BenchError.self) { try BenchLayout.validateName(".") }
        #expect(throws: BenchError.self) { try BenchLayout.validateName("..") }
    }

    @Test func spaceInNameRejected() {
        #expect(throws: BenchError.self) { try BenchLayout.validateName("my bench") }
    }

    // MARK: - benchesDir follows TBD_HOME

    @Test func benchesDirFollowsTBDHome() {
        let env = ["TBD_HOME": "/tmp/tbd-test-home"]
        let dir = TBDConstants.benchesDir(environment: env)
        #expect(dir.path == "/tmp/tbd-test-home/benches")
    }

    @Test func benchesDirDefaultsUnderHome() {
        // With no TBD_HOME override, falls back to ~/tbd/benches.
        let env: [String: String] = [:]
        let dir = TBDConstants.benchesDir(environment: env)
        #expect(dir.lastPathComponent == "benches")
        #expect(dir.deletingLastPathComponent().lastPathComponent == "tbd")
    }

    // MARK: - Layout

    @Test func layoutPaths() {
        let benches = URL(fileURLWithPath: "/tmp/benches", isDirectory: true)
        let bench = BenchLayout.benchDir(benchesDir: benches, name: "standup")
        #expect(bench.path == "/tmp/benches/standup")
        #expect(BenchLayout.runbookPath(benchDir: bench).path == "/tmp/benches/standup/bench.md")
        #expect(BenchLayout.skillsDir(benchDir: bench).path == "/tmp/benches/standup/skills")
        #expect(BenchLayout.runsDir(benchDir: bench).path == "/tmp/benches/standup/runs")

        let runDir = BenchLayout.runDir(benchDir: bench, timestamp: "20260101T000000Z")
        #expect(runDir.path == "/tmp/benches/standup/runs/20260101T000000Z")
        #expect(BenchLayout.outputPath(runDir: runDir).lastPathComponent == "output.md")
        #expect(BenchLayout.transcriptPath(runDir: runDir).lastPathComponent == "transcript.md")
        #expect(BenchLayout.runJSONPath(runDir: runDir).lastPathComponent == "run.json")
    }

    @Test func markerPath() {
        let p = BenchLayout.markerPath(worktreePath: "/work/wt-1")
        #expect(p.path == "/work/wt-1/.tbd-bench-run.json")
        #expect(BenchLayout.markerFileName == ".tbd-bench-run.json")
    }

    // MARK: - Frontmatter parsing

    @Test func frontmatterParsesKnownKeys() {
        let md = """
        ---
        name: standup
        repo: my-repo
        created: 2026-01-01T00:00:00Z
        extra: ignored
        ---

        # standup
        body here
        """
        let fm = BenchFrontmatter.parse(markdown: md)
        #expect(fm.name == "standup")
        #expect(fm.repo == "my-repo")
        #expect(fm.created == "2026-01-01T00:00:00Z")
    }

    @Test func frontmatterStripsQuotes() {
        let md = """
        ---
        repo: "quoted-repo"
        ---
        """
        let fm = BenchFrontmatter.parse(markdown: md)
        #expect(fm.repo == "quoted-repo")
    }

    @Test func frontmatterAbsentReturnsEmpty() {
        let fm = BenchFrontmatter.parse(markdown: "# no frontmatter\nbody")
        #expect(fm.name == nil)
        #expect(fm.repo == nil)
    }

    // MARK: - Repo precedence

    @Test func repoPrecedenceExplicitWins() throws {
        let fm = BenchFrontmatter(name: nil, repo: "fm-repo", created: nil)
        let resolved = try resolveBenchRepo(explicit: "cli-repo", frontmatter: fm, benchName: "b")
        #expect(resolved == "cli-repo")
    }

    @Test func repoPrecedenceFallsBackToFrontmatter() throws {
        let fm = BenchFrontmatter(name: nil, repo: "fm-repo", created: nil)
        let resolved = try resolveBenchRepo(explicit: nil, frontmatter: fm, benchName: "b")
        #expect(resolved == "fm-repo")
    }

    @Test func repoPrecedenceEmptyExplicitFallsBack() throws {
        let fm = BenchFrontmatter(name: nil, repo: "fm-repo", created: nil)
        let resolved = try resolveBenchRepo(explicit: "", frontmatter: fm, benchName: "b")
        #expect(resolved == "fm-repo")
    }

    @Test func repoPrecedenceNoneThrows() {
        let fm = BenchFrontmatter(name: nil, repo: nil, created: nil)
        #expect(throws: BenchError.self) {
            _ = try resolveBenchRepo(explicit: nil, frontmatter: fm, benchName: "b")
        }
    }

    // MARK: - Template

    @Test func runbookTemplateHasFixedSections() {
        let md = BenchTemplate.runbook(name: "standup", repo: "r", created: "2026-01-01")
        #expect(md.contains("name: standup"))
        #expect(md.contains("repo: r"))
        #expect(md.contains("## Purpose"))
        #expect(md.contains("## Runbook"))
        #expect(md.contains("## Preferences"))
        #expect(md.contains("## Run protocol"))
        #expect(md.contains("output.md"))
        // Frontmatter parses back out cleanly.
        let fm = BenchFrontmatter.parse(markdown: md)
        #expect(fm.name == "standup")
        #expect(fm.repo == "r")
    }

    @Test func runbookTemplateOmitsRepoLineWhenNil() {
        let md = BenchTemplate.runbook(name: "standup", repo: nil, created: "2026-01-01")
        #expect(!md.contains("repo:"))
    }

    @Test func bodyStripsFrontmatter() {
        let md = """
        ---
        name: x
        ---

        # Heading
        content
        """
        let body = BenchTemplate.body(ofMarkdown: md)
        #expect(!body.contains("name: x"))
        #expect(body.contains("# Heading"))
        #expect(body.contains("content"))
    }

    @Test func bodyWithoutFrontmatterReturnsAll() {
        let md = "# Heading\ncontent"
        #expect(BenchTemplate.body(ofMarkdown: md) == md)
    }

    @Test func runBriefInterpolatesAbsolutePaths() {
        let brief = BenchTemplate.runBrief(
            runbookBody: "# standup\nsteps",
            runDirPath: "/home/benches/standup/runs/T1",
            runbookPath: "/home/benches/standup/bench.md"
        )
        #expect(brief.contains("# standup"))
        #expect(brief.contains("/home/benches/standup/runs/T1/output.md"))
        #expect(brief.contains("/home/benches/standup/bench.md"))
        #expect(brief.contains("## This run"))
    }

    // MARK: - run.json round-trip

    @Test func runRecordRoundTrips() throws {
        let rec = BenchRunRecord(
            benchName: "standup",
            worktreeID: "11111111-1111-1111-1111-111111111111",
            startedAt: "2026-01-01T00:00:00Z",
            repo: "my-repo"
        )
        let data = try rec.encoded()
        let decoded = try BenchRunRecord.decode(from: data)
        #expect(decoded == rec)
    }

    @Test func markerRoundTrips() throws {
        let marker = BenchRunMarker(benchName: "standup", runDir: "/abs/runs/T1")
        let data = try marker.encoded()
        let decoded = try BenchRunMarker.decode(from: data)
        #expect(decoded == marker)
    }

    // MARK: - Transcript rendering

    @Test func transcriptMarkdownRendersItems() {
        let items: [TranscriptItem] = [
            .userPrompt(id: "1", text: "do the thing", timestamp: nil),
            .assistantText(id: "2", text: "done", timestamp: nil, usage: nil),
            .toolCall(id: "3", name: "Bash", inputJSON: "{\"cmd\":\"ls\"}",
                      inputTruncatedTo: nil, result: nil, subagent: nil, timestamp: nil, usage: nil),
        ]
        let md = BenchTranscript.markdown(items: items, sessionID: "sess-1", benchName: "standup")
        #expect(md.contains("# Transcript — standup"))
        #expect(md.contains("Session: `sess-1`"))
        #expect(md.contains("## User"))
        #expect(md.contains("do the thing"))
        #expect(md.contains("## Assistant"))
        #expect(md.contains("### Tool: Bash"))
        #expect(md.contains("ls"))
    }

    @Test func transcriptMarkdownEmpty() {
        let md = BenchTranscript.markdown(items: [], sessionID: nil, benchName: "standup")
        #expect(md.contains("No transcript items captured"))
    }

    // MARK: - Run selector (latest vs named)

    @Test func selectorLatestPicksLast() throws {
        let avail = ["20260101T000000Z", "20260102T000000Z", "20260103T000000Z"]
        #expect(try resolveBenchRunSelector("latest", available: avail, benchName: "b") == "20260103T000000Z")
    }

    @Test func selectorNamedPicksExact() throws {
        let avail = ["20260101T000000Z", "20260102T000000Z"]
        #expect(try resolveBenchRunSelector("20260101T000000Z", available: avail, benchName: "b") == "20260101T000000Z")
    }

    @Test func selectorUnknownThrows() {
        let avail = ["20260101T000000Z"]
        #expect(throws: BenchError.self) {
            _ = try resolveBenchRunSelector("nope", available: avail, benchName: "b")
        }
    }

    @Test func selectorEmptyThrows() {
        #expect(throws: BenchError.self) {
            _ = try resolveBenchRunSelector("latest", available: [], benchName: "b")
        }
    }
}

// MARK: - Filesystem branch tests (temp dir, no $TBD_HOME)

@Suite("Bench filesystem ops")
struct BenchFileOpsTests {
    private func makeTempBenchesDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-bench-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func createScaffoldsTree() throws {
        let benches = try makeTempBenchesDir()
        defer { try? FileManager.default.removeItem(at: benches) }

        let benchDir = try BenchFileOps.create(benchesDir: benches, name: "standup", repo: "r", created: "2026-01-01")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: BenchLayout.runbookPath(benchDir: benchDir).path))
        #expect(fm.fileExists(atPath: BenchLayout.skillsDir(benchDir: benchDir).path))
        #expect(fm.fileExists(atPath: BenchLayout.runsDir(benchDir: benchDir).path))

        let runbook = try String(contentsOf: BenchLayout.runbookPath(benchDir: benchDir), encoding: .utf8)
        #expect(runbook.contains("## Run protocol"))
    }

    @Test func createAlreadyExistsThrows() throws {
        let benches = try makeTempBenchesDir()
        defer { try? FileManager.default.removeItem(at: benches) }

        _ = try BenchFileOps.create(benchesDir: benches, name: "dup", repo: nil, created: "2026-01-01")
        #expect(throws: BenchError.self) {
            _ = try BenchFileOps.create(benchesDir: benches, name: "dup", repo: nil, created: "2026-01-01")
        }
    }

    @Test func requireMissingBenchThrows() throws {
        let benches = try makeTempBenchesDir()
        defer { try? FileManager.default.removeItem(at: benches) }

        #expect(throws: BenchError.self) {
            _ = try BenchFileOps.requireBenchDir(benchesDir: benches, name: "ghost")
        }
    }

    @Test func requireExistingBenchSucceeds() throws {
        let benches = try makeTempBenchesDir()
        defer { try? FileManager.default.removeItem(at: benches) }

        _ = try BenchFileOps.create(benchesDir: benches, name: "real", repo: nil, created: "2026-01-01")
        let dir = try BenchFileOps.requireBenchDir(benchesDir: benches, name: "real")
        #expect(dir.lastPathComponent == "real")
    }

    @Test func runTimestampsSortedAscending() throws {
        let benches = try makeTempBenchesDir()
        defer { try? FileManager.default.removeItem(at: benches) }

        let benchDir = try BenchFileOps.create(benchesDir: benches, name: "ts", repo: nil, created: "2026-01-01")
        let fm = FileManager.default
        for ts in ["20260103T000000Z", "20260101T000000Z", "20260102T000000Z"] {
            try fm.createDirectory(at: BenchLayout.runDir(benchDir: benchDir, timestamp: ts), withIntermediateDirectories: true)
        }
        // A stray file (not a dir) under runs/ must be ignored.
        try "x".write(to: BenchLayout.runsDir(benchDir: benchDir).appendingPathComponent("not-a-run.txt"), atomically: true, encoding: .utf8)

        let stamps = BenchFileOps.runTimestamps(benchDir: benchDir)
        #expect(stamps == ["20260101T000000Z", "20260102T000000Z", "20260103T000000Z"])
    }
}
