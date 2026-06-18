import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("AgentCLIProvisioner")
struct AgentCLIProvisionerTests {

    // MARK: - resolveCLIPath

    @Test("resolveCLIPath prefers TBD_CLI_PATH override when it exists")
    func resolveCLIPathHonorsOverride() {
        let resolved = AgentCLIProvisioner.resolveCLIPath(
            daemonExecutable: "/opt/tbd/.build/debug/TBDDaemon",
            environment: [AgentCLIProvisioner.cliPathOverrideEnvVar: "/custom/tbd-cli"],
            fileExists: { $0 == "/custom/tbd-cli" }
        )
        #expect(resolved == "/custom/tbd-cli")
    }

    @Test("resolveCLIPath ignores override that does not exist and falls back to sibling")
    func resolveCLIPathOverrideMissingFallsBack() {
        let daemon = "/opt/tbd/.build/debug/TBDDaemon"
        let sibling = "/opt/tbd/.build/debug/TBDCLI"
        let resolved = AgentCLIProvisioner.resolveCLIPath(
            daemonExecutable: daemon,
            environment: [AgentCLIProvisioner.cliPathOverrideEnvVar: "/does/not/exist"],
            fileExists: { $0 == sibling }
        )
        #expect(resolved == sibling)
    }

    @Test("resolveCLIPath resolves sibling TBDCLI next to the daemon")
    func resolveCLIPathResolvesSibling() {
        let daemon = "/opt/tbd/.build/debug/TBDDaemon"
        let sibling = "/opt/tbd/.build/debug/TBDCLI"
        let resolved = AgentCLIProvisioner.resolveCLIPath(
            daemonExecutable: daemon,
            environment: [:],
            fileExists: { $0 == sibling }
        )
        #expect(resolved == sibling)
    }

    @Test("resolveCLIPath returns nil when daemon path is nil")
    func resolveCLIPathNilDaemon() {
        let resolved = AgentCLIProvisioner.resolveCLIPath(
            daemonExecutable: nil,
            environment: [:],
            fileExists: { _ in true }
        )
        #expect(resolved == nil)
    }

    @Test("resolveCLIPath returns nil when sibling TBDCLI does not exist")
    func resolveCLIPathNoSibling() {
        let resolved = AgentCLIProvisioner.resolveCLIPath(
            daemonExecutable: "/opt/tbd/.build/debug/TBDDaemon",
            environment: [:],
            fileExists: { _ in false }
        )
        #expect(resolved == nil)
    }

    // MARK: - stageSymlink

    @Test("stageSymlink creates ${binDir}/tbd pointing at the CLI")
    func stageSymlinkCreatesLink() throws {
        let tempRoot = NSTemporaryDirectory() + "tbd-prov-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let binDir = URL(fileURLWithPath: tempRoot).appendingPathComponent("bin")

        // A real file to point the symlink at.
        let cliPath = tempRoot + "/TBDCLI"
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cliPath, contents: Data("x".utf8))

        let provisioner = AgentCLIProvisioner()
        let staged = provisioner.stageSymlink(cliPath: cliPath, binDir: binDir)

        let linkPath = binDir.appendingPathComponent("tbd").path
        #expect(staged == linkPath)
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        #expect(dest == cliPath)
    }

    @Test("stageSymlink is idempotent and refreshes a stale link target")
    func stageSymlinkRefreshesStaleTarget() throws {
        let tempRoot = NSTemporaryDirectory() + "tbd-prov-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let binDir = URL(fileURLWithPath: tempRoot).appendingPathComponent("bin")
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)

        let oldCLI = tempRoot + "/TBDCLI-old"
        let newCLI = tempRoot + "/TBDCLI-new"
        FileManager.default.createFile(atPath: oldCLI, contents: Data("old".utf8))
        FileManager.default.createFile(atPath: newCLI, contents: Data("new".utf8))

        let provisioner = AgentCLIProvisioner()
        // First stage at the old target.
        _ = provisioner.stageSymlink(cliPath: oldCLI, binDir: binDir)
        // Re-stage at a new target — must overwrite the stale link.
        let staged = provisioner.stageSymlink(cliPath: newCLI, binDir: binDir)

        let linkPath = binDir.appendingPathComponent("tbd").path
        #expect(staged == linkPath)
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        #expect(dest == newCLI)
    }

    // MARK: - pathPrependForSession: the gating conditional

    /// Branch (a): CLI resolves → the symlink is created and the bin dir
    /// (which follows TBD_HOME) is returned for the PATH prepend.
    @Test("pathPrependForSession returns ${TBD_HOME}/bin and stages tbd when CLI resolves")
    func pathPrependReturnsBinDirWhenCLIResolves() throws {
        let tempHome = NSTemporaryDirectory() + "tbd-home-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempHome) }
        try FileManager.default.createDirectory(atPath: tempHome, withIntermediateDirectories: true)

        // Stage a daemon dir with a sibling TBDCLI so resolution succeeds.
        let buildDir = tempHome + "/.build/debug"
        try FileManager.default.createDirectory(atPath: buildDir, withIntermediateDirectories: true)
        let daemonExe = buildDir + "/TBDDaemon"
        let cliExe = buildDir + "/TBDCLI"
        FileManager.default.createFile(atPath: daemonExe, contents: Data("d".utf8))
        FileManager.default.createFile(atPath: cliExe, contents: Data("c".utf8))

        let env = ["TBD_HOME": tempHome]
        let provisioner = AgentCLIProvisioner()
        let prepend = provisioner.pathPrependForSession(
            daemonExecutable: daemonExe, environment: env
        )

        let expectedBin = TBDConstants.binDir(environment: env).path
        #expect(prepend == expectedBin)
        // The symlink must actually exist and point at the resolved CLI.
        let linkPath = expectedBin + "/tbd"
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        #expect(dest == cliExe)
    }

    /// Branch (b): CLI cannot be resolved → returns nil, no symlink, no crash.
    /// The session would then spawn with the user's unmodified PATH.
    @Test("pathPrependForSession returns nil and stages nothing when CLI cannot be resolved")
    func pathPrependReturnsNilWhenCLIUnresolved() {
        let tempHome = NSTemporaryDirectory() + "tbd-home-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempHome) }

        let env = ["TBD_HOME": tempHome]
        let provisioner = AgentCLIProvisioner()
        // No daemon executable → resolution fails on the sibling branch and the
        // override env is absent.
        let prepend = provisioner.pathPrependForSession(
            daemonExecutable: nil, environment: env
        )

        #expect(prepend == nil)
        // No bin dir / symlink should have been created.
        let binPath = TBDConstants.binDir(environment: env).path
        #expect(!FileManager.default.fileExists(atPath: binPath + "/tbd"))
    }

    // MARK: - PATH prepend reaches the spawned shell command

    @Test("newWindowCommand prepends the bin dir to PATH ahead of $PATH")
    func newWindowCommandEmitsPathPrepend() {
        let args = TmuxManager.newWindowCommand(
            server: "srv", session: "main", cwd: "/tmp",
            shellCommand: "claude",
            env: ["TBD_WORKTREE_ID": "abc"],
            pathPrepend: "/Users/dev/tbd/bin"
        )
        let full = args.last ?? ""
        // The PATH export must come first and keep $PATH live (double-quoted).
        #expect(full.contains("export PATH='/Users/dev/tbd/bin':\"$PATH\";"))
        #expect(full.hasPrefix("export PATH="))
        // The other env var still follows.
        #expect(full.contains("export TBD_WORKTREE_ID='abc';"))
        #expect(full.contains("claude"))
    }

    @Test("newWindowCommand omits PATH prepend when nil (unchanged behavior)")
    func newWindowCommandNoPathPrepend() {
        let args = TmuxManager.newWindowCommand(
            server: "srv", session: "main", cwd: "/tmp",
            shellCommand: "claude",
            env: ["TBD_WORKTREE_ID": "abc"],
            pathPrepend: nil
        )
        let full = args.last ?? ""
        #expect(!full.contains("export PATH="))
        #expect(full.hasPrefix("export TBD_WORKTREE_ID='abc';"))
    }
}
