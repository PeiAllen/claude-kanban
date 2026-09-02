import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

/// A worktree spawn is `repo` + `branch` (the catalog says to omit BOTH for a freeform `cwd` card).
/// `branch` decodes to `""` when a caller omits it, and `Config.worktreePath` is a plain join — so a
/// repo-without-branch spawn silently addressed `<worktreesRoot>/<repoName>/`, the SHARED container
/// holding every live worktree of that repo, and reported it as a stale checkout to delete. Reject the
/// half-specified spawn at the boundary, before any card exists.
@Suite("Spawn — a worktree card requires a branch")
struct SpawnBranchValidationTests {

    /// The advertised contract is specifically `invalidParams` (JSON-RPC -32602) — a regression that
    /// answered `pathNotAllowed` would still create no card, so a bare `OrchestraError.self` would pass
    /// while the caller-visible code and remediation silently changed. Assert the case.
    private func expectInvalidParams(_ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("expected .invalidParams, but the spawn succeeded")
        } catch let e as OrchestraError {
            if case .invalidParams = e {} else { Issue.record("expected .invalidParams, got \(e)") }
        } catch {
            Issue.record("expected OrchestraError, got \(error)")
        }
    }

    @Test("repo + base with no branch is rejected, and creates no card")
    func rejectsWorktreeSpawnWithoutBranch() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        await expectInvalidParams {
            _ = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "review it", repo: repo,
                                                   access: .readOnly, base: "some-branch"))
        }
        #expect(await env.svc.list().isEmpty)   // fail-fast: nothing was created to go dead later
    }

    @Test("a whitespace-only branch is rejected too")
    func rejectsBlankBranch() async throws {
        let env = TestEnv.make()
        await expectInvalidParams {
            _ = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "p",
                                                   repo: TestEnv.repo(env.base), branch: "   "))
        }
        #expect(await env.svc.list().isEmpty)
    }

    /// `worktreePath("app", "orch-borrow-main")` == `borrowPath("app", "main")`, and the orphan sweep
    /// classifies a borrow by that basename alone — so the collision would put a real card's tree in
    /// reach of a forced removal.
    @Test("a branch in the reserved orch-borrow- namespace is rejected")
    func rejectsReservedBorrowPrefix() async throws {
        let env = TestEnv.make()
        await expectInvalidParams {
            _ = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "p",
                                                   repo: TestEnv.repo(env.base),
                                                   branch: "orch-borrow-main"))
        }
        #expect(await env.svc.list().isEmpty)
    }

    /// An explicitly EMPTY `cwd` is non-nil, so it selects the freeform arm — the same half-specified
    /// dead-card class as a blank branch.
    @Test("an empty cwd is rejected rather than landing a card with no directory")
    func rejectsBlankCwd() async throws {
        let env = TestEnv.make()
        await expectInvalidParams {
            _ = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "p", cwd: "  "))
        }
        #expect(await env.svc.list().isEmpty)
    }

    /// The guard trims; the trimmed value must be what reaches the worktree path and the card record,
    /// or a `" foo "` branch rides its whitespace into a path git rejects.
    @Test("a padded branch is normalized, not just accepted")
    func normalizesPaddedBranch() async throws {
        let env = TestEnv.make()
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: TestEnv.repo(env.base), branch: " feat/x "))
        #expect(t.branch == "feat/x")
        #expect(t.cwd.hasSuffix("/feat/x"))
    }

    @Test("a freeform cwd card still spawns with no repo or branch")
    func freeformSpawnUnaffected() async throws {
        let env = TestEnv.make()
        let dir = env.base + "/freeform"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "look around", cwd: dir, access: .readOnly))
        #expect(t.origin == .borrowed)
        #expect(t.cwd == dir)
    }
}
