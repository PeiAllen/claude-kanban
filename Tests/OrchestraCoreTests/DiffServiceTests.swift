import Foundation
import Testing
@testable import OrchestraCore

@Suite("OrchestraService — diff endpoints + event-driven refresh")
struct DiffServiceTests {
    typealias Env = (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String)

    /// Spawn a `.worktree` card and turn its cwd into a real git repo (`a.txt` committed on `main`).
    private func worktreeCardWithRepo() async throws -> (env: Env, task: Task) {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "task", repo: repo, branch: "b"))
        try gitInit(t.cwd)
        return (env, t)
    }

    private func gitInit(_ dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            #expect(try Proc.run(["git"] + args, cwd: dir).ok)
        }
        try "one\ntwo\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        #expect(try Proc.run(["git", "add", "-A"], cwd: dir).ok)
        #expect(try Proc.run(["git", "commit", "-q", "-m", "base"], cwd: dir).ok)
    }
    private func modify(_ dir: String) throws {
        try "one\ntwo\nthree\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
    }

    @Test("recomputeDiffStat sets the stat + emits; a no-change recompute does not re-emit")
    func recomputeEmitsOnChange() async throws {
        let (env, t) = try await worktreeCardWithRepo()
        try modify(t.cwd)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        let s = await env.svc.recomputeDiffStat(t.id)
        #expect(s?.filesChanged == 1)
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.diffStat?.filesChanged == 1)

        _ = await env.svc.recomputeDiffStat(t.id)   // no tree change → must not re-emit
        try await _Concurrency.Task.sleep(for: .milliseconds(150))   // let the AsyncStream drain
        // Exactly one diffstat-bearing upsert for this card — the first recompute; the second was a no-op.
        let statUpserts = await collector.upserts.filter { $0.id == t.id && $0.diffStat != nil }.count
        #expect(statUpserts == 1)
    }

    @Test("a plain report (no tool info) schedules a coalesced re-stat — adapter-agnostic")
    func reportTriggersRestat() async throws {
        let (env, t) = try await worktreeCardWithRepo()
        try modify(t.cwd)
        // A normalized snapshot carrying NO tool_name — the diff core must still refresh off it.
        try await env.svc.report(t.id, StatusReport(desc: "working", status: .running))
        try await _Concurrency.Task.sleep(for: .milliseconds(1100))   // > 750ms debounce
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.diffStat?.filesChanged == 1)
    }

    @Test("diffText returns a rendered diff for a worktree card")
    func diffTextWorktree() async throws {
        let (env, t) = try await worktreeCardWithRepo()
        try modify(t.cwd)
        #expect(try await env.svc.diffText(t.id, base: .branch).isEmpty == false)
    }

    @Test("non-worktree (borrowed) card: diffText empty, diffStat stays nil")
    func borrowedGuarded() async throws {
        let env = TestEnv.make()
        let dir = env.base + "/data"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", cwd: dir, access: .readWrite))
        #expect(t.origin == .borrowed)
        #expect(try await env.svc.diffText(t.id) == "")
        _ = await env.svc.recomputeDiffStat(t.id)
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.diffStat == nil)
    }

    @Test("unknown card → unknownTask")
    func unknownCard() async throws {
        let env = TestEnv.make()
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.diffText(UUID())
        }
    }
}
