import Foundation
import Testing
@testable import OrchestraCore

// The teardown ownership fence. A phase step is dispatched off a SNAPSHOT and runs asynchronously, so
// the card can leave `.archivedPending` while the step is in flight — `reopen` is a legal edge straight
// out of it (`archivedPending → creatingWorktree`). `TeardownStepper`'s duties are DESTRUCTIVE (kill the
// session, rm -rf a scratch cwd, release a worktree), so an unfenced stale step tears down the run dir of
// a card that is being brought back up — the agent then execs in a directory that no longer exists and
// its pane dies on the spot, landing the card `dead` instead of reopened.
//
// This is the same single-winner discipline `finishLaunch` already applies to ITS destructive hop
// (`stillOwns` before and after the `kill`+`ensure`), extended to teardown.
@Suite("TeardownStepper — ownership fence")
struct TeardownFenceTests {

    /// A scratch teardown that lost the card must NOT rm -rf its cwd.
    @Test("test_teardownStandsDownWhenCardReopenedUnderIt_scratch")
    func test_teardownStandsDownWhenCardReopenedUnderIt_scratch() async throws {
        let env = TestEnv.make()
        let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", scratch: true))

        // Archive → the step is DISPATCHED off this snapshot (card is `.archivedPending`).
        try await env.svc.archive(card.id)
        let dispatched = try #require(await env.svc.store.get(card.id))
        #expect(dispatched.phase.kind == .archivedPending)

        // …and while it is in flight, the card is reopened: it leaves `.archivedPending` and is
        // brought back up. The cwd is live again — it belongs to the reopened card now.
        _ = try await env.svc.reopen(card.id)
        #expect(await env.svc.store.get(card.id)?.phase.kind != .archivedPending)
        #expect(FileManager.default.fileExists(atPath: card.cwd))

        // Now the stale step lands. It must stand down, not delete the reopened card's run dir.
        try await TeardownStepper().step(dispatched, await env.svc.convergeContext())

        #expect(FileManager.default.fileExists(atPath: card.cwd))   // the cwd survives the stale teardown
        let after = try #require(await env.svc.store.get(card.id))
        #expect(after.phase.kind != .archivedComplete)              // and it is not force-archived back
        #expect(!after.archived)
    }

    /// The same fence for a worktree card: the stale teardown must not release the tree, nor kill the
    /// session, of a card a reopen already owns.
    @Test("test_teardownStandsDownWhenCardReopenedUnderIt_worktree")
    func test_teardownStandsDownWhenCardReopenedUnderIt_worktree() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))

        try await env.svc.archive(card.id)
        let dispatched = try #require(await env.svc.store.get(card.id))

        _ = try await env.svc.reopen(card.id)
        let killsBefore = env.sessions.killed.count

        try await TeardownStepper().step(dispatched, await env.svc.convergeContext())

        #expect(env.sessions.killed.count == killsBefore)           // the reopened card's session is not killed
        #expect(!env.worktrees.removed.contains(card.cwd))          // the tree is not released
        #expect(await env.svc.store.get(card.id)?.archived == false)
    }
}
