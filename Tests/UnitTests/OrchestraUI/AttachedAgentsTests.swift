import Testing
import Foundation
@testable import OrchestraUI
@testable import OrchestraKit

/// Attached-agents derivation + the desktop embedding gate (BLOCKER/MAJOR fixes from plan review):
/// pure `attachedTarget` (both cases + guards), deterministic `(createdAt, id)` ordering, the
/// `isEmbedded` search fail-safe (no recursion, borrowed card stays findable), the shared
/// `visibleTasks` projection reaching board render AND keyboard navigation, and the base-`BoardStore`
/// (iOS) no-strand guarantee. All pure over fixed timestamps — no timers/forks/real fs.
@Suite @MainActor struct AttachedAgentsTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func uuid(_ id: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!   // id: exactly 2 hex chars
    }

    private func worktree(_ id: String, branch: String, repo: String = "/repo", cwd: String? = nil,
                          access: CardAccess = .readWrite, parentBranch: String? = nil,
                          phase: Phase = .live(.running), createdAt: Date? = nil,
                          column: Column = .impl, order: Int = 0) -> Task {
        Task(id: uuid(id), title: "card-\(id)", repo: repo, branch: branch,
             cwd: cwd ?? "\(repo)/.wt/\(branch)", origin: .worktree, access: access,
             model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: column,
             order: order, phase: phase, initialPrompt: id,
             parentBranch: parentBranch, createdAt: createdAt ?? t0)
    }

    private func borrowed(_ id: String, cwd: String, access: CardAccess = .readOnly,
                          phase: Phase = .live(.running), createdAt: Date? = nil) -> Task {
        Task(id: uuid(id), title: "borrowed-\(id)", repo: "", branch: "", cwd: cwd,
             origin: .borrowed, access: access,
             model: AgentModel(id: "claude-opus-4-8"), startIn: .plan, column: .plan,
             order: 0, phase: phase, initialPrompt: id, createdAt: createdAt ?? t0)
    }

    // MARK: derivation (both cases + guards)

    @Test func worktreeReviewer_attachesTo_lineageParent() {
        let m = BoardModel(platform: .noop)
        let target = worktree("01", branch: "feat/x")
        let reviewer = worktree("02", branch: "review/x", access: .readOnly, parentBranch: "feat/x")
        m.tasks = [target, reviewer]
        #expect(m.attachedTarget(of: reviewer)?.id == target.id)
        #expect(m.isAttached(reviewer))
    }

    @Test func borrowedReviewer_attachesTo_worktreeByCwd() {
        let m = BoardModel(platform: .noop)
        let target = worktree("01", branch: "feat/x", cwd: "/repo/.wt/x")
        let reviewer = borrowed("02", cwd: "/repo/.wt/x")
        m.tasks = [target, reviewer]
        #expect(m.attachedTarget(of: reviewer)?.id == target.id)
    }

    @Test func readWrite_isNeverAttached() {
        let m = BoardModel(platform: .noop)
        let target = worktree("01", branch: "feat/x")
        let rwWorktree = worktree("02", branch: "review/x", access: .readWrite, parentBranch: "feat/x")
        let rwBorrowed = borrowed("03", cwd: target.cwd, access: .readWrite)
        m.tasks = [target, rwWorktree, rwBorrowed]
        #expect(m.attachedTarget(of: rwWorktree) == nil)
        #expect(m.attachedTarget(of: rwBorrowed) == nil)
    }

    @Test func archivedReviewer_isNeverAttached() {
        // The `!task.archived` guard: an archived read-only reviewer whose parent is still live must
        // still derive no target (it left the board).
        let m = BoardModel(platform: .noop)
        let target = worktree("01", branch: "feat/x")
        var reviewer = worktree("02", branch: "review/x", access: .readOnly, parentBranch: "feat/x")
        reviewer.archived = true
        m.tasks = [target, reviewer]
        #expect(m.attachedTarget(of: reviewer) == nil)
        #expect(!m.isAttached(reviewer))
    }

    @Test func noDerivableTarget_rendersAsToday() {
        // Read-only reviewer whose parent branch has no live card ⇒ nil target, not embedded, still drawn.
        let m = BoardModel(platform: .noop)
        let reviewer = worktree("02", branch: "review/x", access: .readOnly,
                                parentBranch: "gone", column: .impl)
        m.tasks = [reviewer]
        #expect(m.attachedTarget(of: reviewer) == nil)
        #expect(!m.isEmbedded(reviewer))
        #expect(m.cards(in: .impl).contains { $0.id == reviewer.id })
    }

    // MARK: deterministic ordering (second-resolution ties)

    @Test func attachedAgents_orderedDeterministically_underTie() {
        let m = BoardModel(platform: .noop)
        let target = worktree("01", branch: "feat/x")
        let r2 = worktree("02", branch: "r2", access: .readOnly, parentBranch: "feat/x", createdAt: t0)
        let r3 = worktree("03", branch: "r3", access: .readOnly, parentBranch: "feat/x", createdAt: t0)
        m.tasks = [target, r3, r2]                 // reversed input
        #expect(m.attachedAgents(of: target).map(\.id) == [r2.id, r3.id])
        m.tasks = [target, r2, r3]                 // forward input
        #expect(m.attachedAgents(of: target).map(\.id) == [r2.id, r3.id])
    }

    @Test func borrowedTarget_deterministic_underCwdTie() {
        // Two worktree cards sharing the borrowed reviewer's cwd, equal createdAt: the distinct-cwd
        // (case-2) selector must also break the tie by id, not input order.
        let m = BoardModel(platform: .noop)
        let sharedCwd = "/repo/.wt/x"
        let w1 = worktree("01", branch: "feat/a", cwd: sharedCwd, createdAt: t0)
        let w2 = worktree("04", branch: "feat/b", cwd: sharedCwd, createdAt: t0)
        let reviewer = borrowed("02", cwd: sharedCwd, createdAt: t0)
        m.tasks = [w2, w1, reviewer]
        #expect(m.attachedTarget(of: reviewer)?.id == w1.id)
        m.tasks = [w1, w2, reviewer]
        #expect(m.attachedTarget(of: reviewer)?.id == w1.id)
    }

    @Test func worktreeReviewer_noParent_doesNotFallBackToCwd() {
        // The worktree-first early return: a read-only worktree reviewer whose parentBranch matches no
        // card must return nil even if its cwd coincides with a worktree card — never a cwd fallback.
        let m = BoardModel(platform: .noop)
        let sibling = worktree("01", branch: "feat/x", cwd: "/repo/.wt/shared")
        let reviewer = worktree("02", branch: "review/x", cwd: "/repo/.wt/shared",
                                access: .readOnly, parentBranch: "no-such-branch")
        m.tasks = [sibling, reviewer]
        #expect(m.attachedTarget(of: reviewer) == nil)
    }

    @Test func worktreeReviewerTarget_deterministic_underTie() {
        // Two live cards on the SAME repo/branch, equal createdAt: case-1 must route through the fixed
        // BoardTree.parentCard selector and resolve to the same (lower-id) target regardless of order.
        let m = BoardModel(platform: .noop)
        let p1 = worktree("01", branch: "feat/x", createdAt: t0)
        let p2 = worktree("04", branch: "feat/x", createdAt: t0)
        let reviewer = worktree("02", branch: "review/x", access: .readOnly,
                                parentBranch: "feat/x", createdAt: t0)
        m.tasks = [p2, p1, reviewer]
        #expect(m.attachedTarget(of: reviewer)?.id == p1.id)
        m.tasks = [p1, p2, reviewer]
        #expect(m.attachedTarget(of: reviewer)?.id == p1.id)
    }

    // MARK: liveness roll-up

    @Test func liveness_greenIncludesBeingBorn_amberOnWaitingOrDead() {
        let m = BoardModel(platform: .noop)
        let target = worktree("01", branch: "feat/x")
        func reviewer(_ id: String, _ phase: Phase) -> Task {
            worktree(id, branch: "r\(id)", access: .readOnly, parentBranch: "feat/x", phase: phase)
        }
        m.tasks = [target, reviewer("02", .live(.running)),
                   reviewer("03", .launching), reviewer("04", .creatingWorktree)]
        #expect(m.attachedLiveness(of: target) == .allRunning)

        m.tasks = [target, reviewer("02", .live(.running)),
                   reviewer("03", .live(.waiting(.humanTurn)))]
        #expect(m.attachedLiveness(of: target) == .needsAttention)

        m.tasks = [target, reviewer("02", .dead(.sessionVanished))]
        #expect(m.attachedLiveness(of: target) == .needsAttention)

        m.tasks = [target]
        #expect(m.attachedLiveness(of: target) == nil)
    }

    // MARK: base BoardStore (iOS) never strands

    @Test func baseStore_doesNotEmbed_keepsCardVisible() {
        let base = BoardStore(platform: .noop)
        let target = worktree("01", branch: "feat/x", column: .impl)
        let reviewer = worktree("02", branch: "review/x", access: .readOnly,
                                parentBranch: "feat/x", column: .impl)
        base.tasks = [target, reviewer]
        #expect(base.isAttached(reviewer))             // derivation present on the base
        #expect(!base.isEmbedded(reviewer))            // base gate is false — nothing embedded
        #expect(base.visibleTasks.contains { $0.id == reviewer.id })
        #expect(base.cards(in: .impl).contains { $0.id == reviewer.id })
    }

    // MARK: desktop exclusion + search fail-safe + navigation

    @Test func desktop_embedsAttached_excludedFromBoard() {
        let m = BoardModel(platform: .noop)
        let target = worktree("01", branch: "feat/x", cwd: "/repo/.wt/x", column: .impl)
        let wtReviewer = worktree("02", branch: "review/x", access: .readOnly,
                                  parentBranch: "feat/x", column: .impl)
        let borrowReviewer = borrowed("03", cwd: "/repo/.wt/x")
        m.tasks = [target, wtReviewer, borrowReviewer]
        #expect(m.isEmbedded(wtReviewer))
        #expect(m.isEmbedded(borrowReviewer))
        #expect(!m.cards(in: .impl).contains { $0.id == wtReviewer.id })
        #expect(!m.freeformTasks.contains { $0.id == borrowReviewer.id })
        #expect(m.cards(in: .impl).contains { $0.id == target.id })     // target stays
    }

    @Test func matchingSearch_reappears_borrowed_noRecursion() {
        // The exact config that recursed / hid the card in the pre-fix design: active search + an
        // attached borrowed card in the dock. Must not crash, and the card must be findable.
        let m = BoardModel(platform: .noop)
        let target = worktree("01", branch: "feat/x", cwd: "/repo/.wt/x")
        let borrowReviewer = borrowed("03", cwd: "/repo/.wt/x")
        m.tasks = [target, borrowReviewer]
        #expect(!m.freeformTasks.contains { $0.id == borrowReviewer.id })   // hidden with no search
        m.searchQuery = "borrowed-03"
        #expect(!m.isEmbedded(borrowReviewer))                             // exempt under match
        #expect(m.freeformTasks.contains { $0.id == borrowReviewer.id })    // re-appears in the dock
        #expect(m.searchMatchIds.contains(borrowReviewer.id))              // and is findable
    }

    @Test func matchingSearch_reappears_worktreeReviewer_inColumn() {
        let m = BoardModel(platform: .noop)
        let target = worktree("01", branch: "feat/x", column: .impl)
        let wtReviewer = worktree("02", branch: "review/x", access: .readOnly,
                                  parentBranch: "feat/x", column: .impl)
        m.tasks = [target, wtReviewer]
        #expect(!m.cards(in: .impl).contains { $0.id == wtReviewer.id })
        m.searchQuery = "review/x"                                          // matches its branch
        #expect(m.cards(in: .impl).contains { $0.id == wtReviewer.id })
    }

    @Test func navigation_skipsEmbedded_reachableUnderSearch() {
        let m = BoardModel(platform: .noop)
        let a = worktree("01", branch: "feat/a", column: .impl, order: 0)
        let reviewer = worktree("02", branch: "review/x", access: .readOnly,
                                parentBranch: "feat/a", column: .impl, order: 1)
        let b = worktree("03", branch: "feat/b", column: .impl, order: 2)
        m.tasks = [a, reviewer, b]
        #expect(!m.orderedVisibleCards.contains { $0.id == reviewer.id })
        m.selectedId = a.id
        m.selectMove(.down)
        #expect(m.selectedId == b.id)                                       // skipped the hidden reviewer
        m.searchQuery = "review/x"
        #expect(m.orderedVisibleCards.contains { $0.id == reviewer.id })    // reachable again under search
    }

    @Test func readWrite_unaffected_byEmbedding() {
        let m = BoardModel(platform: .noop)
        let target = worktree("01", branch: "feat/x", column: .impl)
        let rw = worktree("02", branch: "feat/x2", access: .readWrite, parentBranch: "feat/x", column: .impl)
        m.tasks = [target, rw]
        #expect(!m.isEmbedded(rw))
        #expect(m.cards(in: .impl).contains { $0.id == rw.id })
    }
}
