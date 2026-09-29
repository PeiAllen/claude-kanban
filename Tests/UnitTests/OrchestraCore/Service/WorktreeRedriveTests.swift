import Foundation
import Testing
import OrchestraKit
import TestSupport
@testable import OrchestraCore

/// Boot re-drive: finish interrupted worktree removals for FULLY-archived cards. This is the retry
/// engine behind the orphan-leak fix — a removal interrupted by anything (timeout, daemon crash)
/// previously had no second attempt, ever. Candidacy is deliberately narrow: `origin == .worktree`
/// AND phase `archivedComplete` — the `archived` flag alone is written at `archivedPending` while
/// the agent session may still be alive, so it is NOT terminal evidence.
@Suite("Boot re-drive — archived worktree releases")
struct WorktreeRedriveTests {

    private func seed(_ svc: OrchestraService, id: UUID, cwd: String, origin: CardOrigin,
                      phase: Phase, repo: String = "app", branch: String = "b") async throws {
        try await svc.store.create(Task(
            id: id, title: "t", repo: repo, branch: branch, cwd: cwd, origin: origin,
            model: AgentModel(id: "m"), startIn: .impl, column: .impl, order: 0,
            phase: phase, initialPrompt: "", archived: true))
    }

    @Test("re-drives archivedComplete worktree cards; never touches archivedPending (session may live)")
    func test_redrivesOnlyTeardownComplete() async throws {
        let env = TestEnv.make()
        let done = UUID(), pending = UUID()
        let wDone = try await env.svc.worktrees.ensure(repo: "app", branch: "done", cardId: done)
        let wPend = try await env.svc.worktrees.ensure(repo: "app", branch: "pend", cardId: pending)
        try await seed(env.svc, id: done, cwd: wDone.path, origin: .worktree,
                       phase: .archived(teardownComplete: true), branch: "done")
        try await seed(env.svc, id: pending, cwd: wPend.path, origin: .worktree,
                       phase: .archived(teardownComplete: false), branch: "pend")

        await env.svc.redriveArchivedWorktreeReleases()

        #expect(env.worktrees.removed.contains(wDone.path))    // interrupted removal finished
        #expect(!env.worktrees.removed.contains(wPend.path))   // teardown not complete ⇒ untouched
    }

    @Test("skips non-worktree origins and prunes dangling registrations once per distinct repo")
    func test_skipsOtherOriginsAndPrunesPerRepo() async throws {
        let env = TestEnv.make()
        let a = UUID(), b = UUID(), s = UUID()
        let wa = try await env.svc.worktrees.ensure(repo: "app", branch: "a", cardId: a)
        let wb = try await env.svc.worktrees.ensure(repo: "app", branch: "b2", cardId: b)
        try await seed(env.svc, id: a, cwd: wa.path, origin: .worktree,
                       phase: .archived(teardownComplete: true), branch: "a")
        try await seed(env.svc, id: b, cwd: wb.path, origin: .worktree,
                       phase: .archived(teardownComplete: true), branch: "b2")
        let scratchDir = env.base + "/scratch/x"
        try FileManager.default.createDirectory(atPath: scratchDir, withIntermediateDirectories: true)
        try await seed(env.svc, id: s, cwd: scratchDir, origin: .scratch,
                       phase: .archived(teardownComplete: true), repo: "")

        await env.svc.redriveArchivedWorktreeReleases()

        #expect(env.worktrees.removed.contains(wa.path))
        #expect(env.worktrees.removed.contains(wb.path))
        #expect(!env.worktrees.removed.contains(scratchDir))   // scratch is TeardownStepper's job, never ours
        #expect(env.worktrees.prunedRepos == ["app"])          // dangling-registration GC, once per repo
    }

    @Test("keeps a tree with unsaved work — the re-drive inherits release's guards, not force")
    func test_redriveKeepsUnsavedWork() async throws {
        let env = TestEnv.make()
        let id = UUID()
        let w = try await env.svc.worktrees.ensure(repo: "app", branch: "dirty", cardId: id)
        env.worktrees.setUnsavedWork(w.path, true)
        try await seed(env.svc, id: id, cwd: w.path, origin: .worktree,
                       phase: .archived(teardownComplete: true), branch: "dirty")

        await env.svc.redriveArchivedWorktreeReleases()

        #expect(!env.worktrees.removed.contains(w.path))       // surfaced debt, never force-dropped
    }

    @Test("the re-drive flushes shared files before releasing; a refused flush keeps the tree")
    func test_redriveFlushesBeforeReleasing() async throws {
        let env = TestEnv.make()
        let ok = UUID(), refused = UUID()
        let wOk = try await env.svc.worktrees.ensure(repo: "app", branch: "ok", cardId: ok)
        let wNo = try await env.svc.worktrees.ensure(repo: "app", branch: "no", cardId: refused)
        try await seed(env.svc, id: ok, cwd: wOk.path, origin: .worktree,
                       phase: .archived(teardownComplete: true), branch: "ok")
        try await seed(env.svc, id: refused, cwd: wNo.path, origin: .worktree,
                       phase: .archived(teardownComplete: true), branch: "no")
        let noPath = wNo.path
        let flushed = FlushLog()
        await env.svc._setFlushSharedForTest { card in
            flushed.add(card.cwd)
            return card.cwd != noPath
        }

        await env.svc.redriveArchivedWorktreeReleases()

        #expect(Set(flushed.all) == [wOk.path, wNo.path])          // flushed before each release attempt
        #expect(env.worktrees.removed.contains(wOk.path))
        #expect(!env.worktrees.removed.contains(wNo.path))         // refused flush ⇒ never released
    }

    @Test("a reopen that lands while the flush runs keeps the tree: the release is re-fenced after the flush")
    func test_redriveRefencesAfterFlush() async throws {
        let env = TestEnv.make()
        let id = UUID()
        let w = try await env.svc.worktrees.ensure(repo: "app", branch: "reopen", cardId: id)
        try await seed(env.svc, id: id, cwd: w.path, origin: .worktree,
                       phase: .archived(teardownComplete: true), branch: "reopen")
        let svc = env.svc
        await svc._setFlushSharedForTest { card in
            // The reopen lands while git runs: the card leaves archivedComplete before the flush returns.
            _ = try? await svc.store.update(card.id) { $0.phase = .live(.running) }
            return true
        }

        await env.svc.redriveArchivedWorktreeReleases()

        #expect(!env.worktrees.removed.contains(w.path))
    }
}

final class FlushLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ p: String) { lock.withLock { paths.append(p) } }
    var all: [String] { lock.withLock { paths } }
}
