import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit

func makeRegistry() -> (reg: WorktreeRegistry, stub: StubWorktrees, base: String) {
    let base = PathResolver.canonical(NSTemporaryDirectory() + "orch-reg-\(UUID().uuidString)")
    let config = Config(reposRoot: base + "/repos", worktreesRoot: base + "/worktrees", allowlist: [base])
    try? FileManager.default.createDirectory(atPath: config.worktreesRoot, withIntermediateDirectories: true)
    let stub = StubWorktrees(root: config.worktreesRoot)
    let reg = WorktreeRegistry(config: config, resolver: PathResolver(config: config), manager: stub,
                               borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")
    return (reg, stub, base)
}

// Defined ONCE here (shared by the sweep tests below and Task 3.4's release tests) — do NOT redefine
// it in 3.4 or the duplicate symbol breaks the build.
func card(_ id: UUID, cwd: String, archived: Bool = false, origin: CardOrigin = .worktree) -> Task {
    Task(id: id, title: "t", repo: "app", branch: "b-\(id.uuidString.prefix(4))", cwd: cwd,
         origin: origin, model: AgentModel(id: "m"), startIn: .impl, column: .impl, order: 0,
         phase: .live(.running), initialPrompt: "", archived: archived)
}

@Suite("WorktreeRegistry — ensure + materialized marker + persisted borrows")
struct WorktreeRegistryTests {

    @Test func test_concurrentSameBranchEnsureJoins() async throws {
        let (reg, stub, _) = makeRegistry()
        stub.ensureSleepMs = 40   // widen the window: a regression that inserted an `await` mid-critical-section
                                  // would let the 2nd call cut a 2nd tree (ensured.count==2). Serialization is
                                  // structural (no await), so on correct code the count stays 1 regardless.
        // DISTINCT card ids on the SAME branch — proves joining is keyed on branch/PATH, not on card id
        // (a registry that deduped by cardId would wrongly pass with equal ids).
        async let a = reg.ensure(repo: "app", branch: "feat/x", cardId: UUID())
        async let b = reg.ensure(repo: "app", branch: "feat/x", cardId: UUID())
        let (wa, wb) = try await (a, b)
        #expect(wa.path == wb.path)
        #expect(stub.ensured.count == 1)          // exactly ONE git worktree add
        #expect((wa.created ? 1 : 0) + (wb.created ? 1 : 0) == 1)   // one created, one adopted
    }

    @Test func test_markerlessCleanDirRecreated() async throws {
        let (reg, stub, _) = makeRegistry()
        let wt = stub.path(repo: "app", branch: "feat/x")
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)  // marker-less dir
        stub.setDirty(wt, false)
        let w = try await reg.ensure(repo: "app", branch: "feat/x", cardId: UUID())
        #expect(stub.removed.contains(wt))        // pruned
        #expect(stub.ensured.count == 1)          // re-created
        #expect(w.created)
    }

    @Test func test_markerlessDirtyDirNeverRemoved() async throws {
        let (reg, stub, _) = makeRegistry()
        let wt = stub.path(repo: "app", branch: "feat/x")
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        try "work".write(toFile: wt + "/scratch.txt", atomically: true, encoding: .utf8)
        stub.setDirty(wt, true)
        await #expect(throws: OrchestraError.worktreeNeedsManualCleanup(wt)) {
            _ = try await reg.ensure(repo: "app", branch: "feat/x", cardId: UUID())
        }
        #expect(!stub.removed.contains(wt))                                        // never removed
        #expect(FileManager.default.fileExists(atPath: wt + "/scratch.txt"))       // byte-intact
        #expect(stub.ensured.isEmpty)                                             // no add attempted
    }

    @Test func test_ensureReMaterializesMissingTree() async throws {
        let (reg, stub, _) = makeRegistry()
        let id = UUID()
        let w1 = try await reg.ensure(repo: "app", branch: "feat/x", cardId: id)      // materialize + marker
        try FileManager.default.removeItem(atPath: w1.path)                            // tree vanishes (marker stays)
        stub.markBranchExists("feat/x")                                               // branch still exists
        let w2 = try await reg.ensure(repo: "app", branch: "feat/x", cardId: id)      // re-materialize
        #expect(w2.path == w1.path)
        #expect(w2.created)
        #expect(stub.ensured.count == 2)
    }

    @Test func test_ensureRejectsPathEscape() async throws {
        let (reg, stub, _) = makeRegistry()
        await #expect(throws: (any Error).self) {
            _ = try await reg.ensure(repo: "app", branch: "../../../../etc/evil", cardId: UUID())
        }
        #expect(stub.ensured.isEmpty)
    }

    @Test func test_exactlyOneBorrower() async throws {
        let (reg, _, _) = makeRegistry()
        _ = try await reg.ensureBorrow(repo: "app", parentBranch: "main", borrowerCardId: UUID())
        await #expect(throws: OrchestraError.parentAlreadyBorrowed("main")) {
            _ = try await reg.ensureBorrow(repo: "app", parentBranch: "main", borrowerCardId: UUID())
        }
    }

    @Test func test_borrowRegistrationSurvivesRestart() async throws {
        let (reg, stub, base) = makeRegistry()
        let borrower = UUID()
        let w = try await reg.ensureBorrow(repo: "app", parentBranch: "main", borrowerCardId: borrower)
        // Fresh registry instance reading the SAME borrows.json (simulates daemon restart).
        let config = Config(reposRoot: base + "/repos", worktreesRoot: base + "/worktrees", allowlist: [base])
        let reg2 = WorktreeRegistry(config: config, resolver: PathResolver(config: config), manager: stub,
                                    borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")
        // A different child cannot re-borrow the still-registered parent.
        await #expect(throws: OrchestraError.parentAlreadyBorrowed("main")) {
            _ = try await reg2.ensureBorrow(repo: "app", parentBranch: "main", borrowerCardId: UUID())
        }
        // The original borrower's re-borrow is idempotent (same path).
        let again = try await reg2.ensureBorrow(repo: "app", parentBranch: "main", borrowerCardId: borrower)
        #expect(again.path == w.path)
    }

    @Test func test_sweepKeepsLiveBorrowerTree() async throws {
        let (reg, stub, _) = makeRegistry()
        let live = UUID(), gone = UUID()
        let wLive = try await reg.ensureBorrow(repo: "app", parentBranch: "main", borrowerCardId: live)
        let wGone = try await reg.ensureBorrow(repo: "app", parentBranch: "other", borrowerCardId: gone)
        let liveCard = card(live, cwd: "/anywhere")          // present + non-archived ⇒ kept
        var goneCard = card(gone, cwd: "/anywhere"); goneCard.archived = true   // present + archived ⇒ reclaimed
        await reg.sweepOrphanBorrows(cards: [liveCard, goneCard])
        #expect(!stub.removed.contains(wLive.path))           // live borrower kept
        #expect(stub.removed.contains(wGone.path))            // terminated borrower reclaimed
    }

    @Test func test_sweepKeepsBorrowWhenCardsAmbiguous() async throws {
        let (reg, stub, _) = makeRegistry()
        let b = UUID()
        let w = try await reg.ensureBorrow(repo: "app", parentBranch: "main", borrowerCardId: b)
        await reg.sweepOrphanBorrows(cards: [])              // empty/partial load ⇒ ambiguity ⇒ keep everything
        #expect(!stub.removed.contains(w.path))
        // A borrower merely ABSENT (present-but-unknown) is also ambiguous ⇒ kept.
        await reg.sweepOrphanBorrows(cards: [card(UUID(), cwd: "/x")])
        #expect(!stub.removed.contains(w.path))
    }
    // (`card(_:cwd:)` is the helper defined once above in this file. The path canonicalization added to
    // `sweepOrphanBorrows` is what makes this hold when `worktreesRoot` is non-canonical; the stub uses
    // one root string so this test proves the liveness guard, and the canonicalization is asserted by
    // review of the `PathResolver.canonical` calls.)

    // MARK: - Task 3.4: release() — the single removal policy

    @Test func test_releaseNeverRemovesWhileReferenced() async throws {
        let (reg, stub, _) = makeRegistry()
        let a = UUID(), b = UUID()
        let w = try await reg.ensure(repo: "app", branch: "shared", cardId: a)   // materialized (marker present)
        var deadSibling = card(b, cwd: w.path); deadSibling.phase = .dead(.completed)   // dead still holds
        try await reg.release(cardId: a, cards: [card(a, cwd: w.path), deadSibling], force: false)
        #expect(!stub.removed.contains(w.path))   // kept — a dead sibling references it
    }

    @Test func test_releaseNeverRemovesDirtyWithoutForce() async throws {
        let (reg, stub, _) = makeRegistry()
        let a = UUID()
        let w = try await reg.ensure(repo: "app", branch: "d", cardId: a)
        stub.setDirty(w.path, true)
        try await reg.release(cardId: a, cards: [card(a, cwd: w.path)], force: false)   // no throw
        #expect(!stub.removed.contains(w.path))   // dirty + !force ⇒ kept
        try await reg.release(cardId: a, cards: [card(a, cwd: w.path)], force: true)
        #expect(stub.removed.contains(w.path))    // force ⇒ removed
    }

    @Test func test_releaseHonorsCreatedFlag() async throws {
        let (reg, stub, _) = makeRegistry()
        let a = UUID()
        let wt = stub.path(repo: "app", branch: "adopted")
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)  // NO marker
        stub.setDirty(wt, false)
        try await reg.release(cardId: a, cards: [card(a, cwd: wt)], force: false)
        #expect(!stub.removed.contains(wt))   // no marker ⇒ not "created by us" ⇒ kept
    }

    @Test func test_releaseIdempotentToMissingTree() async throws {
        let (reg, stub, _) = makeRegistry()
        let a = UUID()
        let w = try await reg.ensure(repo: "app", branch: "g", cardId: a)
        try FileManager.default.removeItem(atPath: w.path)   // tree already gone
        try await reg.release(cardId: a, cards: [card(a, cwd: w.path)], force: false)   // no throw
        #expect(!stub.removed.contains(w.path))   // nothing to remove
    }

    @Test func test_releaseKeepsTreeWithInflightAdopter() async throws {
        let (reg, stub, _) = makeRegistry()
        let a = UUID(), b = UUID()
        let w = try await reg.ensure(repo: "app", branch: "nb", cardId: a)   // A creates + marks; inflight {a}
        _ = try await reg.ensure(repo: "app", branch: "nb", cardId: b)       // B ADOPTS; inflight {a,b}
        // A's rollback: A is present (as a synthetic), B is NOT in the store yet.
        try await reg.release(cardId: a, cards: [card(a, cwd: w.path)], force: false)
        #expect(!stub.removed.contains(w.path))   // kept — B is an in-flight holder
        // Now B settles (archive/teardown) with no other holder ⇒ removable.
        try await reg.release(cardId: b, cards: [card(b, cwd: w.path)], force: false)
        #expect(stub.removed.contains(w.path))    // last holder gone ⇒ removed
    }

    @Test func test_releaseNeverRemovesOutsideOwnedRoots() async throws {
        let (reg, stub, base) = makeRegistry()
        let a = UUID()
        let outside = base + "/repos/app"   // under reposRoot, NOT worktreesRoot
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        await reg.stampMarkers(forMigratedPaths: [outside])   // satisfy the `created`(marker) guard so ONLY
                                                              // the owned-roots guard can prevent removal
        try await reg.release(cardId: a, cards: [card(a, cwd: outside)], force: true)
        #expect(!stub.removed.contains(outside))              // kept SOLELY because it's outside worktreesRoot
    }
}
