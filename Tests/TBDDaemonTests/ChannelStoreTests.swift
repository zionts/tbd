import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

@Suite struct ChannelStoreTests {
    func makeDB() throws -> TBDDatabase {
        try TBDDatabase(inMemory: true)
    }

    func createRepo(db: TBDDatabase) async throws -> Repo {
        try await db.repos.create(
            path: "/tmp/channel-repo-\(UUID().uuidString)",
            displayName: "Channel Repo",
            defaultBranch: "main"
        )
    }

    func createWorktree(
        db: TBDDatabase,
        repo: Repo,
        parent: UUID? = nil
    ) async throws -> Worktree {
        try await db.worktrees.create(
            repoID: repo.id,
            name: "wt-\(UUID().uuidString.prefix(8))",
            branch: "b-\(UUID().uuidString.prefix(8))",
            path: "/tmp/channel-wt-\(UUID().uuidString)",
            tmuxServer: "srv",
            parentWorktreeID: parent
        )
    }

    // MARK: - post then tail returns in order

    @Test func postThenTailReturnsInChronologicalOrder() async throws {
        let db = try makeDB()
        let team = UUID()
        let sender = UUID()

        let first = try await db.channel.post(
            teamID: team, senderWorktreeID: sender, type: .start, body: "first")
        let second = try await db.channel.post(
            teamID: team, senderWorktreeID: sender, type: .blocker, body: "second")
        let third = try await db.channel.post(
            teamID: team, senderWorktreeID: sender, type: .done, body: "third")

        let tailed = try await db.channel.tail(teamID: team)
        #expect(tailed.map(\.id) == [first.id, second.id, third.id])
        #expect(tailed.map(\.body) == ["first", "second", "third"])
        #expect(tailed.map(\.type) == [.start, .blocker, .done])
    }

    // MARK: - tail scopes by teamID

    @Test func tailReturnsOnlyMessagesForTheTeam() async throws {
        let db = try makeDB()
        let teamA = UUID()
        let teamB = UUID()
        let sender = UUID()

        _ = try await db.channel.post(teamID: teamA, senderWorktreeID: sender, type: .note, body: "a1")
        _ = try await db.channel.post(teamID: teamB, senderWorktreeID: sender, type: .note, body: "b1")
        _ = try await db.channel.post(teamID: teamA, senderWorktreeID: sender, type: .note, body: "a2")

        let tailedA = try await db.channel.tail(teamID: teamA)
        #expect(tailedA.map(\.body) == ["a1", "a2"])

        let tailedB = try await db.channel.tail(teamID: teamB)
        #expect(tailedB.map(\.body) == ["b1"])
    }

    // MARK: - sinceID cursor

    @Test func tailSinceIDReturnsOnlyLaterMessages() async throws {
        let db = try makeDB()
        let team = UUID()
        let sender = UUID()

        let first = try await db.channel.post(teamID: team, senderWorktreeID: sender, type: .note, body: "1")
        let second = try await db.channel.post(teamID: team, senderWorktreeID: sender, type: .note, body: "2")
        let third = try await db.channel.post(teamID: team, senderWorktreeID: sender, type: .note, body: "3")

        let after = try await db.channel.tail(teamID: team, sinceID: first.id.uuidString)
        #expect(after.map(\.id) == [second.id, third.id])
    }

    @Test func tailLimitCapsResults() async throws {
        let db = try makeDB()
        let team = UUID()
        let sender = UUID()
        for i in 0..<5 {
            _ = try await db.channel.post(teamID: team, senderWorktreeID: sender, type: .note, body: "m\(i)")
        }
        let limited = try await db.channel.tail(teamID: team, limit: 2)
        #expect(limited.count == 2)
        #expect(limited.map(\.body) == ["m0", "m1"])
    }

    // MARK: - append-only (store exposes no mutate/delete)

    @Test func postedMessagesAreImmutableAcrossReads() async throws {
        let db = try makeDB()
        let team = UUID()
        let sender = UUID()
        let posted = try await db.channel.post(
            teamID: team, senderWorktreeID: sender, type: .learning, body: "lesson")

        let firstRead = try await db.channel.tail(teamID: team)
        let secondRead = try await db.channel.tail(teamID: team)
        // Re-reads are byte-for-byte stable (append-only, no mutation path).
        #expect(firstRead == secondRead)
        #expect(firstRead.count == 1)
        // Identity/content of the posted message survives the round-trip
        // (createdAt is compared via the persisted copy to avoid sub-second
        // precision drift between the in-memory Date and SQLite's stored value).
        #expect(firstRead.first?.id == posted.id)
        #expect(firstRead.first?.body == posted.body)
        #expect(firstRead.first?.type == posted.type)
        #expect(firstRead.first?.senderWorktreeID == posted.senderWorktreeID)
    }

    // MARK: - teamID / root resolution

    @Test func rootResolutionForTopLevelWorktreeIsItself() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)
        let root = try await createWorktree(db: db, repo: repo)

        let resolved = try await db.worktrees.rootWorktreeID(of: root.id)
        #expect(resolved == root.id)
    }

    @Test func parentAndChildShareTheSameTeamID() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)
        let parent = try await createWorktree(db: db, repo: repo)
        let child = try await createWorktree(db: db, repo: repo, parent: parent.id)
        let grandchild = try await createWorktree(db: db, repo: repo, parent: child.id)

        let parentTeam = try await db.worktrees.rootWorktreeID(of: parent.id)
        let childTeam = try await db.worktrees.rootWorktreeID(of: child.id)
        let grandchildTeam = try await db.worktrees.rootWorktreeID(of: grandchild.id)

        #expect(parentTeam == parent.id)
        #expect(childTeam == parent.id)
        #expect(grandchildTeam == parent.id)
    }

    @Test func unknownWorktreeResolvesToItself() async throws {
        let db = try makeDB()
        let orphan = UUID()
        let resolved = try await db.worktrees.rootWorktreeID(of: orphan)
        #expect(resolved == orphan)
    }

    @Test func endToEndParentChildShareOneChannel() async throws {
        let db = try makeDB()
        let repo = try await createRepo(db: db)
        let parent = try await createWorktree(db: db, repo: repo)
        let child = try await createWorktree(db: db, repo: repo, parent: parent.id)

        // Both post using their own root as teamID — they must land in one thread.
        let parentTeam = try await db.worktrees.rootWorktreeID(of: parent.id)
        let childTeam = try await db.worktrees.rootWorktreeID(of: child.id)

        _ = try await db.channel.post(
            teamID: parentTeam, senderWorktreeID: parent.id, type: .start, body: "parent says hi")
        _ = try await db.channel.post(
            teamID: childTeam, senderWorktreeID: child.id, type: .done, body: "child says done")

        let thread = try await db.channel.tail(teamID: parent.id)
        #expect(thread.count == 2)
        #expect(thread.map(\.body) == ["parent says hi", "child says done"])
        #expect(thread.map(\.senderWorktreeID) == [parent.id, child.id])
    }
}
