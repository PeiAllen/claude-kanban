import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

/// A canned `DiffProvider` recording which baseline the service asked for and returning scripted
/// `DiffStat`/render per `DiffBase` — so `DiffServiceTests` exercises the service's baseline-selection
/// and emit LOGIC without a real repo. The real `git diff --numstat`/render shape these canned values
/// stand in for is the fidelity pin owned by `DiffProviderTests` (now in ContractTests/Git): this
/// suite asserts "the service asked the provider with baseline X and emitted its result", NEVER a real
/// byte count.
final class StubDiffProvider: DiffProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let stats: [DiffBase: DiffStat?]
    private let renders: [DiffBase: String]
    private var _statCalls: [(base: DiffBase, parentBranch: String?)] = []
    private var _renderCalls: [(base: DiffBase, parentBranch: String?)] = []

    init(stats: [DiffBase: DiffStat?] = [:], renders: [DiffBase: String] = [:]) {
        self.stats = stats; self.renders = renders
    }
    var statCalls: [(base: DiffBase, parentBranch: String?)] { lock.withLock { _statCalls } }
    var renderCalls: [(base: DiffBase, parentBranch: String?)] { lock.withLock { _renderCalls } }

    func stat(worktree: String, base: DiffBase, parentBranch: String?) throws -> DiffStat? {
        lock.withLock { _statCalls.append((base, parentBranch)) }
        return stats[base] ?? nil
    }
    func render(worktree: String, base: DiffBase, parentBranch: String?) throws -> String {
        lock.withLock { _renderCalls.append((base, parentBranch)) }
        return renders[base] ?? ""
    }
}

@Suite("OrchestraService — diff endpoints + event-driven refresh")
struct DiffServiceTests {
    typealias Env = (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String)

    /// Spawn a `.worktree` card wired to a canned `StubDiffProvider` — the card cwd needs no real repo,
    /// the stub answers the diff. Returns the env, the live card, and the stub for call/return assertions.
    private func worktreeCard(stub: StubDiffProvider, branch: String = "b")
        async throws -> (env: Env, task: Task) {
        let env = TestEnv.make(proc: FakeProc())
        await env.svc._setDiffProviderForTest(stub)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "task", repo: repo, branch: branch))
        return (env, t)
    }

    @Test("footer diffstat auto-selects the parent baseline for a card with a parent; an explicit base overrides")
    func footerSelectsParentBaseline() async throws {
        let stub = StubDiffProvider(stats: [.parent: DiffStat(filesChanged: 1, insertions: 0, deletions: 0),
                                            .branch: DiffStat(filesChanged: 2, insertions: 0, deletions: 0)])
        let (env, t) = try await worktreeCard(stub: stub, branch: "child")
        _ = try await env.svc.store.update(t.id) { $0.parentBranch = "parent" }

        // No explicit base ⇒ the service resolves the card's parent and asks the provider for `.parent`.
        let s = try #require(await env.svc.recomputeDiffStat(t.id))
        #expect(s.filesChanged == 1)                             // the provider's parent-baseline stat
        #expect(stub.statCalls.last?.base == .parent)            // ← the behavior under test: baseline picked
        #expect(stub.statCalls.last?.parentBranch == "refs/heads/parent")

        // An explicit `.branch` base overrides the default; the provider's branch-baseline stat comes back.
        let branchStat = try #require(await env.svc.recomputeDiffStat(t.id, base: .branch))
        #expect(branchStat.filesChanged == 2)
        #expect(stub.statCalls.last?.base == .branch)
    }

    @Test("recomputeDiffStat sets the stat + emits; a no-change recompute does not re-emit")
    func recomputeEmitsOnChange() async throws {
        let stub = StubDiffProvider(stats: [.branch: DiffStat(filesChanged: 1, insertions: 1, deletions: 0)])
        let (env, t) = try await worktreeCard(stub: stub)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        let s = await env.svc.recomputeDiffStat(t.id)
        #expect(s?.filesChanged == 1)
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.diffStat?.filesChanged == 1)

        _ = await env.svc.recomputeDiffStat(t.id)   // provider returns the same stat → must not re-emit
        // Exactly one diffstat-bearing upsert for this card — the first recompute; the second was a no-op.
        try await pollUntil("first diffstat upsert delivered") {
            await collector.upserts.contains { $0.id == t.id && $0.diffStat != nil }
        }
        await yieldBriefly()   // settle: a wrongful second upsert gets its chance to land
        let statUpserts = await collector.upserts.filter { $0.id == t.id && $0.diffStat != nil }.count
        #expect(statUpserts == 1)
    }

    @Test("a plain report (no tool info) schedules a coalesced re-stat — adapter-agnostic")
    func reportTriggersRestat() async throws {
        let stub = StubDiffProvider(stats: [.branch: DiffStat(filesChanged: 1, insertions: 1, deletions: 0)])
        let (env, t) = try await worktreeCard(stub: stub)
        // A normalized snapshot carrying NO tool_name — the diff core must still refresh off it.
        try await env.svc.report(t.id, StatusReport(desc: "working", run: .running))
        try await pollUntil {
            await env.svc.list().first { $0.id == t.id }?.diffStat?.filesChanged == 1
        }
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.diffStat?.filesChanged == 1)
    }

    @Test("diffText returns the provider's rendered diff for a worktree card")
    func diffTextWorktree() async throws {
        let stub = StubDiffProvider(renders: [.branch: "diff --git a/a.txt b/a.txt\n@@ -1 +1,2 @@\n+three\n"])
        let (env, t) = try await worktreeCard(stub: stub)
        #expect(try await env.svc.diffText(t.id, base: .branch).isEmpty == false)
        #expect(stub.renderCalls.last?.base == .branch)
    }

    @Test("non-worktree (borrowed) card: diffText empty, diffStat stays nil, provider never asked")
    func borrowedGuarded() async throws {
        let env = TestEnv.make(proc: FakeProc())
        // Arm the stub with data it would return IF asked — proving the origin guard short-circuits BEFORE
        // the provider (a stronger statement than the old real-git version, which couldn't observe that).
        let stub = StubDiffProvider(stats: [.branch: DiffStat(filesChanged: 9, insertions: 9, deletions: 9)],
                                    renders: [.branch: "SHOULD NOT APPEAR"])
        await env.svc._setDiffProviderForTest(stub)
        let dir = env.base + "/data"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", cwd: dir, access: .readWrite))
        #expect(t.origin == .borrowed)
        #expect(try await env.svc.diffText(t.id) == "")
        _ = await env.svc.recomputeDiffStat(t.id)
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.diffStat == nil)
        #expect(stub.statCalls.isEmpty)     // the origin guard fired before any provider call
        #expect(stub.renderCalls.isEmpty)
    }

    @Test("unknown card → unknownTask")
    func unknownCard() async throws {
        let env = TestEnv.make(proc: FakeProc())
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.diffText(UUID())
        }
    }
}
