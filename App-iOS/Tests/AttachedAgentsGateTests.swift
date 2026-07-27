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

    /// BT slice 5 INVERTS the old "read-write never embedded" invariant: at TOP LEVEL a read-write lineage
    /// CHILD embeds behind its root (so the top level is roots-only), and becomes a column citizen only
    /// inside a drill of its parent. (The old test asserted the child stays a citizen — the exact behaviour
    /// this slice reverses.)
    func testReadWriteLineageChildEmbedsAtTopLevel_citizenInDrill() {
        let model = BoardModel(platform: .ios)
        let root = worktree("01", branch: "feat/x", column: .impl)
        let child = worktree("02", branch: "feat/x2", parentBranch: "feat/x", column: .impl)   // rw
        model.tasks = [root, child]

        // Top level: only the root is a citizen; the child embeds (reached via peek / drill).
        XCTAssertTrue(model.cards(in: .impl).contains { $0.id == root.id })
        XCTAssertFalse(model.cards(in: .impl).contains { $0.id == child.id })
        XCTAssertEqual(model.subordinates(of: root).map(\.id), [child.id])

        // Drill into the root: the child is now the scope's direct citizen; the root leaves the columns.
        model.drillInto(root.id)
        XCTAssertTrue(model.cards(in: .impl).contains { $0.id == child.id })
        XCTAssertFalse(model.cards(in: .impl).contains { $0.id == root.id })
    }

    /// Roots-only top level, recursively: a grandchild embeds too — only the forest root is a citizen.
    func testTopLevelShowsRootsOnly() {
        let model = BoardModel(platform: .ios)
        let root = worktree("01", branch: "feat/x", column: .impl)
        let child = worktree("02", branch: "feat/x2", parentBranch: "feat/x", column: .impl)
        let grandchild = worktree("03", branch: "feat/x3", parentBranch: "feat/x2", column: .impl)
        let standalone = worktree("04", branch: "feat/y", column: .impl)   // its own root
        model.tasks = [root, child, grandchild, standalone]

        XCTAssertEqual(Set(model.cards(in: .impl).map(\.id)), [root.id, standalone.id])
    }

    /// Attachment never becomes citizenship under drill: a reviewer stays embedded both at top level and
    /// inside a drill of its target (the plan-review invariant, on iOS).
    func testAttachedAlwaysEmbedded_topLevelAndInDrill() {
        let model = BoardModel(platform: .ios)
        let root = worktree("01", branch: "feat/x", column: .impl)
        let child = worktree("02", branch: "feat/x2", parentBranch: "feat/x", column: .impl)
        let reviewer = worktree("03", branch: "review/x", access: .readOnly,
                                parentBranch: "feat/x", column: .impl)
        model.tasks = [root, child, reviewer]

        XCTAssertFalse(model.cards(in: .impl).contains { $0.id == reviewer.id })   // embedded at top level
        model.drillInto(root.id)
        XCTAssertFalse(model.cards(in: .impl).contains { $0.id == reviewer.id })   // still embedded in drill
        XCTAssertTrue(model.cards(in: .impl).contains { $0.id == child.id })       // child is the citizen
        // ...and the drilled root hosts its own reviewer as a row (else it'd be unreachable in the drill).
        XCTAssertEqual(model.drillHostedRows().map(\.id), [reviewer.id])
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

    /// The three-tier liveness roll-up that colours the badge: needsAttention (permission block / dead)
    /// dominates; else running (any active or being-born) dominates idle; else idle; nil when none attached.
    func testLivenessRollUp() {
        let model = BoardModel(platform: .ios)
        let target = worktree("01", branch: "feat/x")
        func reviewer(_ id: String, _ phase: Phase) -> Task {
            worktree(id, branch: "r\(id)", access: .readOnly, parentBranch: "feat/x", phase: phase)
        }
        model.tasks = [target, reviewer("02", .live(.running)), reviewer("03", .launching)]
        XCTAssertEqual(model.attachedLiveness(of: target), .running)

        // GREEN DOMINATES IDLE: a concluded (humanTurn) reviewer beside a running one stays green —
        // a finished reviewer is idle, NOT attention.
        model.tasks = [target, reviewer("02", .live(.running)),
                       reviewer("03", .live(.waiting(.humanTurn)))]
        XCTAssertEqual(model.attachedLiveness(of: target), .running)

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
        XCTAssertFalse(model.isPeekExpanded(target))

        // The tap toggle reveals.
        model.togglePeek(target)
        XCTAssertTrue(model.isPeekExpanded(target))
        XCTAssertEqual(model.expandedRows(for: target).map(\.id), [reviewer.id])

        // ...and collapses.
        model.togglePeek(target)
        XCTAssertFalse(model.isPeekExpanded(target))
        XCTAssertTrue(model.expandedRows(for: target).isEmpty)
    }

    /// Two independent guarantees when a target stops being a target:
    /// (1) the read-time guard — `showsInlineRows` also requires current agents, so no rows render even
    ///     while the id still sits in the set; and
    /// (2) the REAP itself actually drops the id, so it can't leak or silently re-open later. Asserting
    ///     only (1) would not prove (2) — `tasks` assignment alone bypasses both reap paths, which is
    ///     exactly why `refresh()` (a wholesale `tasks` replace) needs its own override.
    func testStaleExpandIdShowsNoRows_andIsReaped() {
        let model = BoardModel(platform: .ios)
        let target = worktree("01", branch: "feat/x")
        let reviewer = worktree("02", branch: "review/x", access: .readOnly, parentBranch: "feat/x")
        model.tasks = [target, reviewer]
        model.togglePeek(target)
        XCTAssertEqual(model.expandedRows(for: target).map(\.id), [reviewer.id])

        // The reviewer leaves → target is no longer a target. (1) nothing renders...
        model.tasks = [target]
        XCTAssertTrue(model.expandedRows(for: target).isEmpty)
        // ...(2) and the reap drops the id, so a returning reviewer does NOT silently re-open the card.
        model.reapExpandedPeekTargets()
        XCTAssertFalse(model.expandedPeekTargets.contains(target.id))
        model.tasks = [target, reviewer]
        XCTAssertTrue(model.expandedRows(for: target).isEmpty)   // stays collapsed until a fresh tap
    }

    /// A card removed entirely (not just de-targeted) is reaped too — the path a reconnect `refresh()`
    /// wholesale-replace takes, which never routes through `apply`.
    func testRemovedCardIsReaped() {
        let model = BoardModel(platform: .ios)
        let target = worktree("01", branch: "feat/x")
        let reviewer = worktree("02", branch: "review/x", access: .readOnly, parentBranch: "feat/x")
        model.tasks = [target, reviewer]
        model.togglePeek(target)
        XCTAssertTrue(model.expandedPeekTargets.contains(target.id))

        model.tasks = []                       // card gone (snapshot replace)
        model.reapExpandedPeekTargets()
        XCTAssertTrue(model.expandedPeekTargets.isEmpty)
    }

    /// The expand set is per-card and reaped when a card leaves the board (no leak).
    func testExpandStateIsPerCard_andReapedOnRemoval() {
        let model = BoardModel(platform: .ios)
        let a = worktree("01", branch: "feat/a")
        let ra = worktree("02", branch: "rev/a", access: .readOnly, parentBranch: "feat/a")
        let b = worktree("03", branch: "feat/b")
        let rb = worktree("04", branch: "rev/b", access: .readOnly, parentBranch: "feat/b")
        model.tasks = [a, ra, b, rb]

        model.togglePeek(a)
        XCTAssertTrue(model.isPeekExpanded(a))
        XCTAssertFalse(model.isPeekExpanded(b))   // independent per card

        // A leaves the board; the next toggle prunes its stale id.
        model.tasks = [b, rb]
        model.togglePeek(b)
        XCTAssertFalse(model.expandedPeekTargets.contains(a.id))   // reaped
        XCTAssertTrue(model.isPeekExpanded(b))
    }

    // MARK: peek generalizes to lineage children (slice 5)

    /// Peek is no longer attached-only: a root with a plain lineage child reveals it when tapped.
    func testPeekRevealsLineageChildren() {
        let model = BoardModel(platform: .ios)
        let root = worktree("01", branch: "feat/x")
        let child = worktree("02", branch: "feat/x2", parentBranch: "feat/x")
        model.tasks = [root, child]

        XCTAssertTrue(model.expandedRows(for: root).isEmpty)   // collapsed
        model.togglePeek(root)
        XCTAssertEqual(model.expandedRows(for: root).map(\.id), [child.id])
    }

    /// Reap keys on "has subordinates" now (not attached-liveness): a card whose LAST lineage child leaves
    /// drops its expand id, on both the direct reap and a wholesale `tasks` replace.
    func testPeekReapDropsIdWhenSubordinatesVanish() {
        let model = BoardModel(platform: .ios)
        let root = worktree("01", branch: "feat/x")
        let child = worktree("02", branch: "feat/x2", parentBranch: "feat/x")
        model.tasks = [root, child]
        model.togglePeek(root)
        XCTAssertTrue(model.expandedPeekTargets.contains(root.id))

        model.tasks = [root]              // child gone → root has no subordinates
        model.reapExpandedPeekTargets()
        XCTAssertFalse(model.expandedPeekTargets.contains(root.id))
    }

    /// Nested-reviewer reachability (the plan-review MAJOR): in a chain `C ← R1 ← R2`, R2 is NOT in C's
    /// peek (it hangs off R1), so it is reachable only via R1's own peek — which is exactly what the
    /// subordinates-gated toggle in the detail expands. Both R1 and R2 are embedded (never board citizens).
    func testNestedReviewerReachableViaIntermediate() {
        let model = BoardModel(platform: .ios)
        let root = worktree("01", branch: "feat/x")
        let r1 = worktree("02", branch: "review1", access: .readOnly, parentBranch: "feat/x")
        let r2 = worktree("03", branch: "review2", access: .readOnly, parentBranch: "review1")
        model.tasks = [root, r1, r2]

        XCTAssertFalse(model.visibleTasks.contains { $0.id == r1.id })   // both embedded
        XCTAssertFalse(model.visibleTasks.contains { $0.id == r2.id })

        model.togglePeek(root)
        XCTAssertEqual(model.expandedRows(for: root).map(\.id), [r1.id])   // C's peek = R1 only, not R2
        model.togglePeek(r1)
        XCTAssertEqual(model.expandedRows(for: r1).map(\.id), [r2.id])     // R1's peek reveals R2
    }

    // MARK: drill scope reap (slice 5)

    /// The drill retargets across card succession: when the scoped root's OWNING card is replaced by a
    /// successor on the same branch, the drill follows the branch to the new owner rather than clearing.
    func testDrillReapRetargetsOnBranchSuccession() {
        let model = BoardModel(platform: .ios)
        let planner = worktree("01", branch: "feat/x")
        let child = worktree("02", branch: "feat/x2", parentBranch: "feat/x")
        model.tasks = [planner, child]
        model.drillInto(planner.id)
        XCTAssertEqual(model.drillScope, planner.id)

        // The planning card is replaced by an orchestrator on the SAME branch (a newer card).
        let orchestrator = worktreeCreated("05", branch: "feat/x", at: Date(timeIntervalSince1970: 2_000_000))
        model.tasks = [orchestrator, child]
        model.reapDrillScope()
        XCTAssertEqual(model.drillScope, orchestrator.id, "drill follows the branch to its new owner")

        // The branch leaves entirely → the drill clears to the top level (never strands on a gone scope).
        model.tasks = [child]
        model.reapDrillScope()
        XCTAssertNil(model.drillScope)
    }

    private func worktreeCreated(_ id: String, branch: String, at: Date) -> Task {
        Task(id: uuid(id), title: "card-\(id)", repo: "/repo", branch: branch,
             cwd: "/repo/.wt/\(branch)", origin: .worktree, access: .readWrite,
             model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
             order: 0, phase: .live(.running), initialPrompt: id, createdAt: at)
    }

    // MARK: Needs You snooze — reconcile against the UNSNOOZED fold, not the filtered list

    /// Regression: the Needs You tab reconciles snoozes against the full `needsYouRows` fold, NOT the
    /// snooze-filtered `items` it renders. Reconciling against the filtered list is the self-cancel bug:
    /// snoozing a still-active card drops it from `items`, `reconcile` reads that as "resolved" and prunes
    /// the snooze the tap just set, so the row reappears on the next render. This pins the contract the
    /// view relies on — a snooze survives while its card is in the fold, and is pruned only when it leaves.
    func testSnoozeSurvivesReconcileWhileCardStaysInFold() {
        let snooze = NeedsYouSnooze()
        let x = worktree("01", branch: "x")
        let y = worktree("02", branch: "y")
        let fold = [NeedsYouRow(task: x, signals: [AttentionSignal(.stalled, "12m")]),
                    NeedsYouRow(task: y, signals: [AttentionSignal(.stalled, "9m")])]

        snooze.snooze(x.id, for: 3600)
        // The tab hides x from what it renders...
        XCTAssertEqual(snooze.visible(fold).map(\.id), [y.id])
        // ...but reconciles against the FULL fold (x still needs you, just suppressed).
        snooze.reconcile(activeIds: Set(fold.map(\.id)))
        XCTAssertTrue(snooze.isSnoozed(x.id), "snooze must survive: x is still in the fold")
        XCTAssertEqual(snooze.visible(fold).map(\.id), [y.id], "x stays suppressed, not re-alerted")

        // When x genuinely resolves and leaves the fold, the snooze is pruned so a fresh alert later shows.
        snooze.reconcile(activeIds: [y.id])
        XCTAssertFalse(snooze.isSnoozed(x.id), "snooze pruned once the card leaves the fold")
    }
}
