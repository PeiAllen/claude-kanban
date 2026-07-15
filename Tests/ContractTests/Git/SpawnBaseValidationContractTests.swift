import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

// Contract mover (extracted from the unit SpawnBaseValidationTests at the Task-9/11 flip, card-lifecycle):
// the rollback is driven by a real `.git/config.lock` held during `recordSpawnBase`'s `git config` write,
// and its teeth is a REAL on-disk branch rollback (`rev-parse --verify refs/heads/nb` → false). Both are
// real-git integration effects. The service-level analogue (a lineage-record failure → dead + tree released
// force:false) is the unit StepperConvergeTests.test_materializeLineageRecordFailureRollsBack.
@Suite("Contract: a lineage-record failure rolls back the just-created worktree + branch (S2-3iii)")
struct SpawnBaseValidationContractTests {

    /// A real git repo (real worktree manager, via the registry) on `main` with a `foo` branch.
    static func repo() throws -> (svc: OrchestraService, repo: String) {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func g(_ a: String...) throws { #expect(try Proc.run(["git", "-C", repo] + a).ok) }
        try g("init", "-q", "-b", "main"); try g("config", "user.email", "t@t"); try g("config", "user.name", "t")
        try "0\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try g("add", "-A"); try g("commit", "-q", "-m", "base"); try g("branch", "foo")
        return (svc, repo)
    }

    @Test("S2-3(iii): a lineage-record failure rolls back the just-created worktree + branch")
    func rollbackOnLineageFailure() async throws {
        let (svc, repo) = try Self.repo()
        // Force the `git config` write in recordSpawnBase to fail by holding the config lock — the
        // failure fires AFTER `ensure` cut the worktree + branch, exercising the rollback path.
        let lock = repo + "/.git/config.lock"
        FileManager.default.createFile(atPath: lock, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: lock) }

        // Non-blocking spawn: the lineage-record failure + rollback now fire inside the reconciler-driven
        // MaterializeStepper (the card goes .dead(.spawnFailed)), not as a synchronous throw from spawn.
        let card = try await svc.spawn(SpawnInput(id: UUID(), prompt: "n", repo: repo, branch: "nb", base: "foo"))
        try await pollUntil {
            await svc.reconcile()
            return await svc.list(includeArchived: true).first { $0.id == card.id }?.phase.kind == .dead
        }
        try? FileManager.default.removeItem(atPath: lock)   // release before asserting (rev-parse is a read)
        // Rolled back: the just-created nb branch is gone (no orphan for a retry to silently adopt).
        #expect(try Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/nb"]).ok == false)
    }
}
