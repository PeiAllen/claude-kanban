import XCTest
@testable import OrchestraiOS   // for the internal `PlatformUI.ios` bundle (like IOSAppTests)
import OrchestraUI
import OrchestraKit

/// The iOS embedding GATE + the tap-driven inline reveal (`IOSBoardModel`), exercised on the phone build
/// where `BoardModel = IOSBoardModel`. The shared derivation + the desktop selection-reveal are covered
/// cross-platform in `Tests/UnitTests/OrchestraUI/AttachedAgentsTests.swift` (which runs under
/// `BoardModel = BoardUX`), so it never touches the iOS subclass. This one does.
///
/// `isEmbedded`/`showsInlineRows` are `internal`; this bundle imports OrchestraUI normally (not
/// `@testable`), so we assert the PUBLIC projections the board actually renders — `cards(in:)` /
/// `visibleTasks` / `freeformTasks` / `attachedAgents(of:)` / `expandedRows(for:)` — never the internals.
@MainActor
final class AttachedAgentsGateTests: XCTestCase {

    private func uuid(_ id: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!   // id: exactly 2 hex chars
    }

    private func worktree(_ id: String, branch: String, repo: String = "/repo", cwd: String? = nil,
                          access: CardAccess = .readWrite, parentBranch: String? = nil,
                          phase: Phase = .live(.running), column: Column = .impl) -> Task {
        Task(id: uuid(id), title: "card-\(id)", repo: repo, branch: branch,
             cwd: cwd ?? "\(repo)/.wt/\(branch)", origin: .worktree, access: access,
             model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: column,
             order: 0, phase: phase, initialPrompt: id, parentBranch: parentBranch,
             createdAt: Date(timeIntervalSince1970: 1_000_000))
    }

    private func borrowed(_ id: String, cwd: String, access: CardAccess = .readOnly) -> Task {
        Task(id: uuid(id), title: "borrowed-\(id)", repo: "", branch: "", cwd: cwd,
             origin: .borrowed, access: access, model: AgentModel(id: "claude-opus-4-8"),
             startIn: .plan, column: .plan, order: 0, phase: .live(.running), initialPrompt: id,
             createdAt: Date(timeIntervalSince1970: 1_000_000))
    }

    /// The iOS typealias resolves to the embedding subclass (guards the alias flip).
    func testIOSBoardModelIsTheEmbeddingSubclass() {
        XCTAssertTrue(BoardModel(platform: .ios) is IOSBoardModel)
    }

    // MARK: embedding gate + fail-safes

    /// An attached read-only worktree reviewer is embedded: dropped from its column, while the target
    /// stays and lists it via `attachedAgents`.
    func testWorktreeReviewerEmbedded_targetKeepsIt() {
        let model = BoardModel(platform: .ios)
        let target = worktree("01", branch: "feat/x", column: .impl)
        let reviewer = worktree("02", branch: "review/x", access: .readOnly,
                                parentBranch: "feat/x", column: .impl)
        model.tasks = [target, reviewer]

        XCTAssertFalse(model.cards(in: .impl).contains { $0.id == reviewer.id })   // embedded → not on board
        XCTAssertFalse(model.visibleTasks.contains { $0.id == reviewer.id })
        XCTAssertTrue(model.cards(in: .impl).contains { $0.id == target.id })      // target stays
        XCTAssertEqual(model.attachedAgents(of: target).map(\.id), [reviewer.id])
    }

    /// An attached branchless borrowed reviewer is dropped from the freeform dock; the target keeps it.
    func testBorrowedReviewerEmbedded_droppedFromFreeform() {
        let model = BoardModel(platform: .ios)
        let target = worktree("01", branch: "feat/x", cwd: "/repo/.wt/x")
        let reviewer = borrowed("02", cwd: "/repo/.wt/x")
        model.tasks = [target, reviewer]

        XCTAssertFalse(model.freeformTasks.contains { $0.id == reviewer.id })
        XCTAssertEqual(model.attachedAgents(of: target).map(\.id), [reviewer.id])
    }

    /// Fail-safe: a read-write card with the same lineage is NEVER embedded.
    func testReadWriteNeverEmbedded() {
        let model = BoardModel(platform: .ios)
        let target = worktree("01", branch: "feat/x", column: .impl)
        let rw = worktree("02", branch: "feat/x2", access: .readWrite,
                          parentBranch: "feat/x", column: .impl)
        model.tasks = [target, rw]

        XCTAssertTrue(model.cards(in: .impl).contains { $0.id == rw.id })
    }

    /// Fail-safe: a read-only reviewer whose parent branch has no live card derives no target, so it is
    /// not embedded and renders as today (never stranded).
    func testNoDerivableTargetRendersAsToday() {
        let model = BoardModel(platform: .ios)
        let reviewer = worktree("02", branch: "review/x", access: .readOnly,
                                parentBranch: "gone", column: .impl)
        model.tasks = [reviewer]

        XCTAssertFalse(model.isAttached(reviewer))
        XCTAssertTrue(model.cards(in: .impl).contains { $0.id == reviewer.id })
    }

    /// Fail-safe (malformed lineage): a read-only R1↔R2 cycle has `isAttached == true` for both but no
    /// real `attachedRoot` — the gate must key on `attachedRoot != nil` (like `BoardUX`), NOT `isAttached`,
    /// or both members would be hidden AND rooted nowhere → unreachable. They must stay board citizens.
    func testMalformedCycleNotEmbedded_reachable() {
        let model = BoardModel(platform: .ios)
        let r1 = worktree("02", branch: "r1", access: .readOnly, parentBranch: "r2", column: .impl)
        let r2 = worktree("03", branch: "r2", access: .readOnly, parentBranch: "r1", column: .impl)
        model.tasks = [r1, r2]

        XCTAssertTrue(model.isAttached(r1))   // isAttached is true (attachedTarget resolves)...
        XCTAssertNil(model.attachedRoot(of: r1))   // ...but there is no real root (cycle → fail open)
        XCTAssertTrue(model.cards(in: .impl).contains { $0.id == r1.id })   // so both stay on the board
        XCTAssertTrue(model.cards(in: .impl).contains { $0.id == r2.id })
    }

    /// The liveness roll-up that colours the badge: green all-running/being-born, amber on waiting/dead,
    /// nil when none attached.
    func testLivenessRollUp() {
        let model = BoardModel(platform: .ios)
        let target = worktree("01", branch: "feat/x")
        func reviewer(_ id: String, _ phase: Phase) -> Task {
            worktree(id, branch: "r\(id)", access: .readOnly, parentBranch: "feat/x", phase: phase)
        }
        model.tasks = [target, reviewer("02", .live(.running)), reviewer("03", .launching)]
        XCTAssertEqual(model.attachedLiveness(of: target), .allRunning)

        model.tasks = [target, reviewer("02", .live(.running)),
                       reviewer("03", .live(.waiting(.humanTurn)))]
        XCTAssertEqual(model.attachedLiveness(of: target), .needsAttention)

        model.tasks = [target]
        XCTAssertNil(model.attachedLiveness(of: target))
    }

    // MARK: tap-driven inline reveal (iOS-specific)

    /// `expandedRows` is empty until the target is tap-expanded, then lists its attached agents —
    /// proving the iOS `showsInlineRows` override is tap-driven, NOT selectedId-driven.
    func testExpandedRowsFollowTapToggle_notSelection() {
        let model = BoardModel(platform: .ios)
        let target = worktree("01", branch: "feat/x")
        let reviewer = worktree("02", branch: "review/x", access: .readOnly, parentBranch: "feat/x")
        model.tasks = [target, reviewer]

        // Selecting the target does NOT reveal on iOS (selection drives full-screen nav, not the board).
        model.selectedId = target.id
        XCTAssertTrue(model.expandedRows(for: target).isEmpty)
        XCTAssertFalse(model.isAttachedExpanded(target))

        // The tap toggle reveals.
        model.toggleAttachedExpanded(target)
        XCTAssertTrue(model.isAttachedExpanded(target))
        XCTAssertEqual(model.expandedRows(for: target).map(\.id), [reviewer.id])

        // ...and collapses.
        model.toggleAttachedExpanded(target)
        XCTAssertFalse(model.isAttachedExpanded(target))
        XCTAssertTrue(model.expandedRows(for: target).isEmpty)
    }

    /// A stale expand id never renders rows: `showsInlineRows` also requires current agents, so a target
    /// that was expanded then lost all its reviewers shows nothing even if its id lingers in the set (the
    /// read-time guard; the `apply`-time reap clears the id itself on the next live event).
    func testStaleExpandIdShowsNoRows() {
        let model = BoardModel(platform: .ios)
        let target = worktree("01", branch: "feat/x")
        let reviewer = worktree("02", branch: "review/x", access: .readOnly, parentBranch: "feat/x")
        model.tasks = [target, reviewer]
        model.toggleAttachedExpanded(target)
        XCTAssertEqual(model.expandedRows(for: target).map(\.id), [reviewer.id])

        // The reviewer leaves → target is no longer a target. Even though its id is still in the set,
        // no rows render (and toggling would not re-open it either).
        model.tasks = [target]
        XCTAssertTrue(model.expandedRows(for: target).isEmpty)
    }

    /// The expand set is per-card and reaped when a card leaves the board (no leak).
    func testExpandStateIsPerCard_andReapedOnRemoval() {
        let model = BoardModel(platform: .ios)
        let a = worktree("01", branch: "feat/a")
        let ra = worktree("02", branch: "rev/a", access: .readOnly, parentBranch: "feat/a")
        let b = worktree("03", branch: "feat/b")
        let rb = worktree("04", branch: "rev/b", access: .readOnly, parentBranch: "feat/b")
        model.tasks = [a, ra, b, rb]

        model.toggleAttachedExpanded(a)
        XCTAssertTrue(model.isAttachedExpanded(a))
        XCTAssertFalse(model.isAttachedExpanded(b))   // independent per card

        // A leaves the board; the next toggle prunes its stale id.
        model.tasks = [b, rb]
        model.toggleAttachedExpanded(b)
        XCTAssertFalse(model.expandedAttachedTargets.contains(a.id))   // reaped
        XCTAssertTrue(model.isAttachedExpanded(b))
    }
}
