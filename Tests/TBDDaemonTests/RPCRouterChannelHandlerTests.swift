import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("channel.* handlers")
struct RPCRouterChannelHandlerTests {

    /// Router whose handlers broadcast into a captured StateSubscriptionManager.
    private func makeRouter(db: TBDDatabase) -> (router: RPCRouter, deltas: ChannelBroadcastDeltas) {
        let deltas = ChannelBroadcastDeltas()
        let subs = StateSubscriptionManager()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver(),
                subscriptions: subs
            ),
            tmux: TmuxManager(dryRun: true),
            subscriptions: subs
        )
        return (router, deltas)
    }

    private func makeRepo(db: TBDDatabase) async throws -> Repo {
        try await db.repos.create(
            path: "/tmp/channel-handler-repo-\(UUID().uuidString)",
            displayName: "Repo",
            defaultBranch: "main"
        )
    }

    private func makeWorktree(db: TBDDatabase, repo: Repo, parent: UUID? = nil) async throws -> Worktree {
        try await db.worktrees.create(
            repoID: repo.id,
            name: "wt-\(UUID().uuidString.prefix(8))",
            branch: "b-\(UUID().uuidString.prefix(8))",
            path: "/tmp/channel-handler-wt-\(UUID().uuidString)",
            tmuxServer: "srv",
            parentWorktreeID: parent
        )
    }

    @Test func postResolvesTeamAndBroadcastsDelta() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db: db)
        let repo = try await makeRepo(db: db)
        let parent = try await makeWorktree(db: db, repo: repo)
        let child = try await makeWorktree(db: db, repo: repo, parent: parent.id)

        let request = try RPCRequest(
            method: RPCMethod.channelPost,
            params: ChannelPostParams(senderWorktreeID: child.id, type: .blocker, body: "stuck")
        )
        let response = await router.handle(request)
        #expect(response.success)

        let message = try response.decodeResult(ChannelMessage.self)
        // teamID derived from the sender's root (the parent).
        #expect(message.teamID == parent.id)
        #expect(message.senderWorktreeID == child.id)
        #expect(message.type == .blocker)
        #expect(message.body == "stuck")

        let broadcasts = deltas.snapshot().compactMap { delta -> ChannelMessageDelta? in
            if case .channelMessage(let d) = delta { return d }
            return nil
        }
        #expect(broadcasts.count == 1)
        #expect(broadcasts.first?.messageID == message.id)
        #expect(broadcasts.first?.teamID == parent.id)
    }

    @Test func tailResolvesTeamAndReturnsThread() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (router, _) = makeRouter(db: db)
        let repo = try await makeRepo(db: db)
        let parent = try await makeWorktree(db: db, repo: repo)
        let child = try await makeWorktree(db: db, repo: repo, parent: parent.id)

        // Parent and child each post; both belong to one team.
        for (sender, body) in [(parent.id, "p"), (child.id, "c")] {
            let req = try RPCRequest(
                method: RPCMethod.channelPost,
                params: ChannelPostParams(senderWorktreeID: sender, type: .note, body: body)
            )
            #expect(await router.handle(req).success)
        }

        // Tail from the child's perspective — must see the whole shared thread.
        let tailReq = try RPCRequest(
            method: RPCMethod.channelTail,
            params: ChannelTailParams(worktreeID: child.id)
        )
        let tailResponse = await router.handle(tailReq)
        #expect(tailResponse.success)

        let result = try tailResponse.decodeResult(ChannelTailResult.self)
        #expect(result.teamID == parent.id)
        #expect(result.messages.map(\.body) == ["p", "c"])
    }

    @Test func postForUnknownWorktreeFails() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (router, _) = makeRouter(db: db)
        let request = try RPCRequest(
            method: RPCMethod.channelPost,
            params: ChannelPostParams(senderWorktreeID: UUID(), body: "orphan")
        )
        let response = await router.handle(request)
        #expect(!response.success)
    }

    @Test func postRejectsOverCapBody() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db: db)
        let repo = try await makeRepo(db: db)
        let worktree = try await makeWorktree(db: db, repo: repo)

        // One byte over the cap (ASCII "a" is 1 byte each).
        let oversized = String(repeating: "a", count: RPCRouter.maxChannelBodyBytes + 1)
        let request = try RPCRequest(
            method: RPCMethod.channelPost,
            params: ChannelPostParams(senderWorktreeID: worktree.id, body: oversized)
        )
        let response = await router.handle(request)
        #expect(!response.success)

        // Rejected before persistence/broadcast: nothing stored, nothing emitted.
        let stored = try await db.channel.tail(teamID: worktree.id)
        #expect(stored.isEmpty)
        let broadcasts = deltas.snapshot().compactMap { delta -> ChannelMessageDelta? in
            if case .channelMessage(let d) = delta { return d }
            return nil
        }
        #expect(broadcasts.isEmpty)
    }

    @Test func postAcceptsAtCapBody() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (router, _) = makeRouter(db: db)
        let repo = try await makeRepo(db: db)
        let worktree = try await makeWorktree(db: db, repo: repo)

        // Exactly at the cap must succeed.
        let atCap = String(repeating: "a", count: RPCRouter.maxChannelBodyBytes)
        let request = try RPCRequest(
            method: RPCMethod.channelPost,
            params: ChannelPostParams(senderWorktreeID: worktree.id, body: atCap)
        )
        let response = await router.handle(request)
        #expect(response.success)

        let message = try response.decodeResult(ChannelMessage.self)
        #expect(message.body.utf8.count == RPCRouter.maxChannelBodyBytes)
    }
}

/// Thread-safe collector for broadcast StateDeltas.
private final class ChannelBroadcastDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func append(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        deltas.append(delta)
    }

    func snapshot() -> [StateDelta] {
        lock.lock(); defer { lock.unlock() }
        return deltas
    }
}
