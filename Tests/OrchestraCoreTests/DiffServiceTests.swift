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

    /// Turn `dir` into a real repo with topology: main(base) → parent(parent's own commit) →
    /// child=HEAD(child's own file). `.parent` should see only the child's file; `.branch` (vs main)
    /// sees both the parent's and the child's changes.
    private func gitParentChild(_ dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func git(_ a: String...) { #expect((try? Proc.run(["git"] + a, cwd: dir))?.ok == true) }
        git("init", "-q", "-b", "main"); git("config", "user.email", "t@t"); git("config", "user.name", "t")
        try "base\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        git("add", "-A"); git("commit", "-q", "-m", "base")
        git("checkout", "-q", "-b", "parent")
        try "base\nPARENT\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        git("commit", "-q", "-am", "parent work")
        git("checkout", "-q", "-b", "child")
        try "child\n".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)
        git("add", "-A"); git("commit", "-q", "-m", "child work")
    }

    /// main(a.txt) → parent(+parent.md) → child=HEAD(+child.md). Once the card baselines against its
    /// parent, only `child.md` counts as the card's changed note.
    private func gitParentChildNotes(_ dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func git(_ a: String...) { #expect((try? Proc.run(["git"] + a, cwd: dir))?.ok == true) }
        git("init", "-q", "-b", "main"); git("config", "user.email", "t@t"); git("config", "user.name", "t")
        try "base\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        git("add", "-A"); git("commit", "-q", "-m", "base")
        git("checkout", "-q", "-b", "parent")
        try "# parent\n".write(toFile: dir + "/parent.md", atomically: true, encoding: .utf8)
        git("add", "-A"); git("commit", "-q", "-m", "parent note")
        git("checkout", "-q", "-b", "child")
        try "# child\n".write(toFile: dir + "/child.md", atomically: true, encoding: .utf8)
        git("add", "-A"); git("commit", "-q", "-m", "child note")
    }

    @Test("footer diffstat auto-selects the parent baseline for a card with a parent")
    func footerSelectsParentBaseline() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "task", repo: repo, branch: "child"))
        try gitParentChild(t.cwd)
        _ = try await env.svc.store.update(t.id) { $0.parentBranch = "parent" }

        // No explicit base ⇒ the funnel/default path. Parent-relative ⇒ only the child's own file.
        let s = try #require(await env.svc.recomputeDiffStat(t.id))
        #expect(s.filesChanged == 1)   // b.txt only — NOT the parent's a.txt change

        // The .branch baseline (vs main) instead includes the parent's work too (a.txt + b.txt).
        let branchStat = try #require(await env.svc.recomputeDiffStat(t.id, base: .branch))
        #expect(branchStat.filesChanged == 2)
    }

    @Test("changedNotes baselines against the parent — the parent's note is excluded")
    func changedNotesUsesParentBaseline() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "task", repo: repo, branch: "child"))
        try gitParentChildNotes(t.cwd)
        _ = try await env.svc.store.update(t.id) { $0.parentBranch = "parent" }
        let notes = try await env.svc.changedNotes(t.id)
        #expect(notes.map(\.path) == ["child.md"])   // parent.md excluded
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
        try await env.svc.report(t.id, StatusReport(desc: "working", run: .running))
        try await pollUntil {
            await env.svc.list().first { $0.id == t.id }?.diffStat?.filesChanged == 1
        }
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
