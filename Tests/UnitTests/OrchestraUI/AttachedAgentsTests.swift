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

    @Test func liveness_threeTier_needsAttentionDominates_greenDominatesIdle() {
        let m = BoardModel(platform: .noop)
        let target = worktree("01", branch: "feat/x")
        func reviewer(_ id: String, _ phase: Phase) -> Task {
            worktree(id, branch: "r\(id)", access: .readOnly, parentBranch: "feat/x", phase: phase)
        }
        // Running + being-born → green.
        m.tasks = [target, reviewer("02", .live(.running)),
                   reviewer("03", .launching), reviewer("04", .creatingWorktree)]
        #expect(m.attachedLiveness(of: target) == .running)

        // GREEN DOMINATES IDLE: a concluded (humanTurn) reviewer beside a running one stays green —
        // a finished reviewer is idle, NOT attention. (This is the bug the old test enshrined.)
        m.tasks = [target, reviewer("02", .live(.running)),
                   reviewer("03", .live(.waiting(.humanTurn)))]
        #expect(m.attachedLiveness(of: target) == .running)

        // All concluded, none running, none blocked → idle (grey), still not amber.
        m.tasks = [target, reviewer("02", .live(.waiting(.humanTurn))),
                   reviewer("03", .live(.waiting(.humanTurn)))]
        #expect(m.attachedLiveness(of: target) == .idle)

        // NEEDS-YOU-NOW DOMINATES: a permission block ambers even beside a running reviewer.
        m.tasks = [target, reviewer("02", .live(.running)),
                   reviewer("03", .live(.waiting(.permission)))]
        #expect(m.attachedLiveness(of: target) == .needsAttention)

        // Dead is needs-you-now too.
        m.tasks = [target, reviewer("02", .dead(.sessionVanished))]
        #expect(m.attachedLiveness(of: target) == .needsAttention)

        // None attached → nil (badge hidden).
        m.tasks = [target]
        #expect(m.attachedLiveness(of: target) == nil)
    }

    @Test func livenessTier_perAgentClassification() {
        #expect(BoardStore.AttachedLiveness(phase: .live(.running)) == .running)
        #expect(BoardStore.AttachedLiveness(phase: .launching) == .running)
        #expect(BoardStore.AttachedLiveness(phase: .live(.waiting(.humanTurn))) == .idle)
        #expect(BoardStore.AttachedLiveness(phase: .live(.waiting(.permission))) == .needsAttention)
        #expect(BoardStore.AttachedLiveness(phase: .dead(.sessionVanished)) == .needsAttention)
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

    @Test func matchingSearch_borrowedReviewer_revealedInPlace() {
        // A matching borrowed reviewer STAYS embedded (a subcard, never a standalone dock card) and is
        // surfaced in place: its target reveals the row and the reviewer joins the search-match set.
        let m = BoardModel(platform: .noop)
        let target = worktree("01", branch: "feat/x", cwd: "/repo/.wt/x")
        let borrowReviewer = borrowed("03", cwd: "/repo/.wt/x")
        m.tasks = [target, borrowReviewer]
        #expect(!m.freeformTasks.contains { $0.id == borrowReviewer.id })   // hidden with no search
        m.searchQuery = "borrowed-03"
        #expect(m.isEmbedded(borrowReviewer))                              // stays a subcard (no un-embed)
        #expect(!m.freeformTasks.contains { $0.id == borrowReviewer.id })  // never a standalone dock card
        #expect(m.revealsSearchMatchRow(target))                          // target auto-reveals the row
        #expect(m.showsInlineRows(target))
        #expect(m.searchMatchIds.contains(borrowReviewer.id))             // findable via n/N
    }

    @Test func matchingSearch_worktreeReviewer_revealedNotInColumn() {
        let m = BoardModel(platform: .noop)
        let target = worktree("01", branch: "feat/x", column: .impl)
        let wtReviewer = worktree("02", branch: "review/x", access: .readOnly,
                                  parentBranch: "feat/x", column: .impl)
        m.tasks = [target, wtReviewer]
        m.searchQuery = "review/x"                                          // matches its branch
        #expect(m.isEmbedded(wtReviewer))                                  // stays a subcard
        #expect(!m.cards(in: .impl).contains { $0.id == wtReviewer.id })   // never a standalone column card
        #expect(m.showsInlineRows(target))                                 // revealed in place under target
        #expect(m.searchMatchIds.contains(wtReviewer.id))
    }

    @Test func navigation_skipsEmbedded_reviewerReachableViaSearchMatch() {
        let m = BoardModel(platform: .noop)
        let a = worktree("01", branch: "feat/a", column: .impl, order: 0)
        let reviewer = worktree("02", branch: "review/x", access: .readOnly,
                                parentBranch: "feat/a", column: .impl, order: 1)
        let b = worktree("03", branch: "feat/b", column: .impl, order: 2)
        m.tasks = [a, reviewer, b]
        #expect(!m.orderedVisibleCards.contains { $0.id == reviewer.id })
        m.selectedId = a.id
        m.selectMove(.down)
        #expect(m.selectedId == b.id)                                       // j/k skips the embedded reviewer
        m.searchQuery = "review/x"
        #expect(!m.orderedVisibleCards.contains { $0.id == reviewer.id })   // STILL embedded (a subcard)
        #expect(m.searchMatchIds.contains(reviewer.id))                     // reachable via n/N instead
        m.selectedId = reviewer.id                                          // selecting the match…
        #expect(m.revealsAttached(a))                                       // …reveals its target's rows
    }

    @Test func readWriteChild_isNeverAttached_butEmbedsAsNonRootAtTopLevel() {
        // A read-write lineage child is NEVER an attached agent — attachment is a read-only relation, so
        // the target has no reviewers to embed. (This is the invariant the old readWrite_unaffected test
        // protected.) What CHANGED in slice 2b: the roots-only top level now embeds the child as a
        // non-root DESCENDANT (revealed via peek under its root), not as a column citizen — so it leaves
        // `cards(in:)` but stays reachable through its visible root (`cardLevelAnchor`). Full scope
        // behaviour is covered in BoardHierarchyScopeTests.
        let m = BoardModel(platform: .noop)
        let target = worktree("01", branch: "feat/x", column: .impl)
        let rw = worktree("02", branch: "feat/x2", access: .readWrite, parentBranch: "feat/x", column: .impl)
        m.tasks = [target, rw]
        #expect(!m.isAttached(rw))                                  // not a reviewer
        #expect(m.attachedAgents(of: target).isEmpty)              // target embeds no attached agents
        #expect(m.isEmbedded(rw))                                  // roots-only: the child embeds…
        #expect(!m.cards(in: .impl).contains { $0.id == rw.id })   // …so it isn't a column card…
        #expect(m.cardLevelAnchor(rw.id) == target.id)            // …but it's reachable via its root
    }

    // MARK: nested chain — flatten via attachedRoot (Codex BLOCKER)

    /// A reviewer-of-a-reviewer (C ← R1 ← R2): both flatten onto the visible root C, so R2 is never
    /// orphaned behind the hidden R1, and R1 (itself attached) never self-reveals.
    @Test func nestedChain_flattensOntoVisibleRoot() {
        let m = BoardModel(platform: .noop)
        let c  = worktree("01", branch: "feat/x", column: .impl)
        let r1 = worktree("02", branch: "review/x", access: .readOnly, parentBranch: "feat/x", column: .impl)
        let r2 = worktree("05", branch: "review/x2", access: .readOnly, parentBranch: "review/x", column: .impl)
        m.tasks = [c, r1, r2]
        #expect(m.attachedRoot(of: r1)?.id == c.id)
        #expect(m.attachedRoot(of: r2)?.id == c.id)         // climbs past the embedded intermediate R1
        #expect(m.attachedRoot(of: c) == nil)               // a real card has no root
        #expect(m.attachedAgents(of: c).map(\.id) == [r1.id, r2.id])   // both flattened under C
        #expect(m.attachedAgents(of: r1).isEmpty)           // R1 owns no rows of its own
        #expect(!m.revealsAttached(r1))                     // and never self-reveals
    }

    @Test func attachedRoot_nilForUnattached() {
        let m = BoardModel(platform: .noop)
        let rw = worktree("01", branch: "feat/x")
        m.tasks = [rw]
        #expect(m.attachedRoot(of: rw) == nil)
    }

    // MARK: reveal state (revealsAttached / showsInlineRows / expandedRows)

    @Test func revealsAttached_onCardOrRowSelection_notOtherwise() {
        let m = BoardModel(platform: .noop)
        let c  = worktree("01", branch: "feat/x")
        let r1 = worktree("02", branch: "review/x", access: .readOnly, parentBranch: "feat/x")
        m.tasks = [c, r1]
        m.selectedId = nil
        #expect(!m.revealsAttached(c))                      // nothing selected
        m.selectedId = c.id
        #expect(m.revealsAttached(c))                       // target selected
        m.selectedId = r1.id
        #expect(m.revealsAttached(c))                       // one of its rows selected
    }

    @Test func revealsAttached_falseWhenNoneAttached() {
        let m = BoardModel(platform: .noop)
        let solo = worktree("01", branch: "feat/x")
        m.tasks = [solo]
        m.selectedId = solo.id
        #expect(!m.revealsAttached(solo))
    }

    @Test func expandedRows_revealedBySelectionOrSearchMatch() {
        let m = BoardModel(platform: .noop)
        let c  = worktree("01", branch: "feat/x", column: .impl)
        let r1 = worktree("02", branch: "review/x", access: .readOnly, parentBranch: "feat/x", column: .impl)
        m.tasks = [c, r1]
        #expect(!m.showsInlineRows(c))                       // nothing selected, no search ⇒ collapsed
        m.selectedId = c.id
        #expect(m.showsInlineRows(c))                        // selection reveals
        #expect(m.expandedRows(for: c).map(\.id) == [r1.id])
        // With nothing selected, a matching row still reveals the target IN PLACE (no un-embed).
        m.selectedId = nil
        m.searchQuery = "review/x"
        #expect(m.revealsSearchMatchRow(c))
        #expect(m.showsInlineRows(c))
        #expect(m.expandedRows(for: c).map(\.id) == [r1.id])
    }

    // MARK: card-level anchor (j/k treats an expanded card as one unit)

    @Test func cardLevelAnchor_rowResolvesToVisibleRoot() {
        let m = BoardModel(platform: .noop)
        let c  = worktree("01", branch: "feat/x", column: .impl)
        let r1 = worktree("02", branch: "review/x", access: .readOnly, parentBranch: "feat/x", column: .impl)
        let r2 = worktree("05", branch: "review/x2", access: .readOnly, parentBranch: "review/x", column: .impl)
        m.tasks = [c, r1, r2]
        #expect(m.cardLevelAnchor(r1.id) == c.id)           // embedded row → its visible target
        #expect(m.cardLevelAnchor(r2.id) == c.id)           // nested row → climbs to the visible root
        #expect(m.cardLevelAnchor(c.id) == c.id)            // a normal card → itself
        #expect(m.cardLevelAnchor(nil) == nil)
    }

    @Test func selectMove_fromRow_stepsOffVisibleTarget_notFirstPlan() {
        // j from a selected row must land on the card after its visible target, never fall through to
        // the first Plan card (the stranding bug the anchor fixes).
        let m = BoardModel(platform: .noop)
        let plan = worktree("09", branch: "feat/plan", column: .plan, order: 0)
        let c  = worktree("01", branch: "feat/x", column: .impl, order: 0)
        let r1 = worktree("02", branch: "review/x", access: .readOnly, parentBranch: "feat/x", column: .impl, order: 1)
        let d  = worktree("03", branch: "feat/d", column: .impl, order: 2)
        m.tasks = [plan, c, r1, d]
        m.selectedId = r1.id
        m.selectMove(.down)
        #expect(m.selectedId == d.id)                       // C → D within Impl, not the Plan card
    }

    // MARK: row axis (selectRowMove within the group only)

    @Test func selectRowMove_walksGroup_clampsBothEnds() {
        let m = BoardModel(platform: .noop)
        let c  = worktree("01", branch: "feat/x", column: .impl)
        let r1 = worktree("02", branch: "r1", access: .readOnly, parentBranch: "feat/x", createdAt: t0, column: .impl)
        let r2 = worktree("05", branch: "r2", access: .readOnly, parentBranch: "feat/x",
                          createdAt: Date(timeIntervalSince1970: 1_000_001), column: .impl)
        m.tasks = [c, r1, r2]
        m.selectedId = c.id
        m.selectRowMove(.down); #expect(m.selectedId == r1.id)     // main card → first row
        m.selectRowMove(.down); #expect(m.selectedId == r2.id)     // → second row
        m.selectRowMove(.down); #expect(m.selectedId == r2.id)     // clamp past the last row
        m.selectRowMove(.up);   #expect(m.selectedId == r1.id)
        m.selectRowMove(.up);   #expect(m.selectedId == c.id)      // back up INTO the main card
        m.selectRowMove(.up);   #expect(m.selectedId == c.id)      // clamp at the main card (never above)
    }

    @Test func selectRowMove_noopFromNilAndNoRows() {
        let m = BoardModel(platform: .noop)
        let solo = worktree("01", branch: "feat/x", column: .impl)
        m.tasks = [solo]
        m.selectedId = nil
        m.selectRowMove(.down); #expect(m.selectedId == nil)       // arrows aren't a board-entry path
        m.selectedId = solo.id
        m.selectRowMove(.down); #expect(m.selectedId == solo.id)   // no rows → single-element group
        m.selectRowMove(.up);   #expect(m.selectedId == solo.id)
    }

    // MARK: base BoardStore (iOS) parity

    @Test func baseStore_anchorIdentity_showsRowsWithoutSearchGate() {
        let base = BoardStore(platform: .noop)
        let c  = worktree("01", branch: "feat/x", column: .impl)
        let r1 = worktree("02", branch: "review/x", access: .readOnly, parentBranch: "feat/x", column: .impl)
        base.tasks = [c, r1]
        base.selectedId = c.id
        #expect(base.cardLevelAnchor(r1.id) == r1.id)       // nothing embedded ⇒ identity anchor
        #expect(base.showsInlineRows(c))                    // base gate == revealsAttached (no / search)
        #expect(base.expandedRows(for: c).map(\.id) == [r1.id])
    }

    // MARK: malformed-lineage fail-open (Codex impl-review MAJOR)

    /// A read-only cycle (R1↔R2 each naming the other's branch) has no real root: `attachedRoot` must
    /// fail OPEN (nil) so neither is embedded, leaving both as reachable board cards rather than hidden
    /// behind each other.
    @Test func malformedCycle_failsOpen_bothReachable() {
        let m = BoardModel(platform: .noop)
        let r1 = worktree("02", branch: "loop/a", access: .readOnly, parentBranch: "loop/b", column: .impl)
        let r2 = worktree("05", branch: "loop/b", access: .readOnly, parentBranch: "loop/a", column: .impl)
        m.tasks = [r1, r2]
        #expect(m.attachedRoot(of: r1) == nil)
        #expect(m.attachedRoot(of: r2) == nil)
        #expect(!m.isEmbedded(r1))
        #expect(!m.isEmbedded(r2))
        #expect(m.cards(in: .impl).contains { $0.id == r1.id })
        #expect(m.cards(in: .impl).contains { $0.id == r2.id })
        #expect(m.cardLevelAnchor(r1.id) == r1.id)          // visible ⇒ anchors to itself, no strand
    }

    // MARK: gg/G from a row (Codex impl-review minor)

    @Test func selectEnd_fromRow_operatesOnTargetColumn() {
        let m = BoardModel(platform: .noop)
        let c  = worktree("01", branch: "feat/x", column: .impl, order: 0)
        let r1 = worktree("02", branch: "review/x", access: .readOnly, parentBranch: "feat/x", column: .impl, order: 1)
        let d  = worktree("03", branch: "feat/d", column: .impl, order: 2)
        m.tasks = [c, r1, d]
        m.selectedId = r1.id
        m.selectEnd(first: false); #expect(m.selectedId == d.id)   // G → last card of the target's column
        m.selectedId = r1.id
        m.selectEnd(first: true);  #expect(m.selectedId == c.id)   // gg → first card
    }

    // MARK: search reveals reviewer rows in place (reviewers stay embedded)

    @Test func selectRowMove_intoRow_whenTargetSelectedDuringSearch() {
        // Selecting a card reveals its rows regardless of search (no more !searchActive suppression), so
        // ↑/↓ steps into them normally.
        let m = BoardModel(platform: .noop)
        let c  = worktree("01", branch: "feat/x", column: .impl)
        let r1 = worktree("02", branch: "review/x", access: .readOnly, parentBranch: "feat/x", column: .impl)
        m.tasks = [c, r1]
        m.selectedId = c.id
        m.searchQuery = "feat/x"                             // matches the target, not the row
        m.selectRowMove(.down); #expect(m.selectedId == r1.id)   // group is [c, r1]; ↓ enters the row
    }

    @Test func nestedChain_underSearch_bothStayEmbedded_revealedUnderRoot() {
        // R1 matches; R2 doesn't. Neither un-embeds — both flatten under the visible root C, which
        // reveals its rows in place, and both climb to C for card-axis nav.
        let m = BoardModel(platform: .noop)
        let c  = worktree("01", branch: "feat/x", column: .impl)
        let r1 = worktree("02", branch: "review/match", access: .readOnly, parentBranch: "feat/x", column: .impl)
        let r2 = worktree("05", branch: "review/x2", access: .readOnly, parentBranch: "review/match", column: .impl)
        m.tasks = [c, r1, r2]
        m.searchQuery = "review/match"
        #expect(m.isEmbedded(r1))                            // matched but STILL a subcard (no un-embed)
        #expect(m.isEmbedded(r2))
        #expect(m.revealsSearchMatchRow(c))                  // the match is revealed under the root C
        #expect(m.showsInlineRows(c))
        #expect(m.searchMatchIds.contains(r1.id))            // and reachable via n/N
        #expect(m.cardLevelAnchor(r1.id) == c.id)            // both climb to the visible root
        #expect(m.cardLevelAnchor(r2.id) == c.id)
    }

    // MARK: peek rows — generalized reveal over lineage children (slice 2b)

    @Test func rootWithOnlyReadWriteChildRevealsOnSelection() {
        // The MAJOR fix: the old reveal only recognised attached agents, so a root whose only subordinate
        // is a read-write lineage child stayed collapsed. Now selecting it reveals the child as a peek row.
        let m = BoardModel(platform: .noop)
        let root = worktree("01", branch: "feat/x", column: .impl)
        let child = worktree("02", branch: "feat/x-pr", access: .readWrite, parentBranch: "feat/x", column: .plan)
        m.tasks = [root, child]
        #expect(!m.revealsPeek(root))                        // nothing selected → collapsed
        m.selectedId = root.id
        #expect(m.revealsPeek(root))
        #expect(m.peekRows(of: root).map(\.task.id) == [child.id])
        #expect(m.peekRows(of: root).first?.depth == 0)
    }

    @Test func peekExpandsSelectedChildOneLevelDeeper() {
        // Selecting a grandchild expands the path to it: the child row (depth 0) followed by the
        // grandchild (depth 1) — the "reveals them one level down when selected" recursion.
        let m = BoardModel(platform: .noop)
        let root  = worktree("01", branch: "feat/x", column: .impl)
        let child = worktree("02", branch: "feat/x-c", parentBranch: "feat/x", column: .impl)
        let grand = worktree("03", branch: "feat/x-g", parentBranch: "feat/x-c", column: .review)
        m.tasks = [root, child, grand]
        m.selectedId = grand.id
        let rows = m.peekRows(of: root)
        #expect(rows.map(\.task.id) == [child.id, grand.id])
        #expect(rows.map(\.depth) == [0, 1])
    }

    @Test func groupSequenceWalksPeekRows() {
        let m = BoardModel(platform: .noop)
        let root  = worktree("01", branch: "feat/x", column: .impl)
        let child = worktree("02", branch: "feat/x-c", parentBranch: "feat/x", column: .impl)
        let rev   = worktree("05", branch: "review/x", access: .readOnly, parentBranch: "feat/x", column: .impl)
        m.tasks = [root, child, rev]
        m.selectedId = root.id
        #expect(m.groupSequence() == [root.id, child.id, rev.id])   // anchor + lineage-then-attached rows
    }

    @Test func selectedChildStaysOnVisibleRow() {
        // Esc-out-of-terminal-lands-on-row: an embedded child, once selected, remains a revealed row and
        // the card-axis anchor is its visible root, so `j`/`k` step off the root, not into the void.
        let m = BoardModel(platform: .noop)
        let root  = worktree("01", branch: "feat/x", column: .impl)
        let child = worktree("02", branch: "feat/x-c", parentBranch: "feat/x", column: .impl)
        m.tasks = [root, child]
        m.selectedId = child.id
        #expect(m.peekRows(of: root).map(\.task.id).contains(child.id))   // row still drawn
        #expect(m.cardLevelAnchor(child.id) == root.id)                  // card-axis anchor is the root
    }

    // MARK: search reveals subordinates in place (slice 2b, Task 5)

    @Test func searchMatchOnDeepGrandchildRevealsAncestorPath() {
        // R → C → G, no selection. Searching G's title surfaces G (not just C) and auto-expands the path.
        let m = BoardModel(platform: .noop)
        let root  = worktree("01", branch: "feat/x", column: .impl)
        let child = worktree("02", branch: "feat/x-c", parentBranch: "feat/x", column: .impl)
        let grand = worktree("03", branch: "feat/x-g", parentBranch: "feat/x-c", column: .review)
        m.tasks = [root, child, grand]
        m.searchQuery = "card-03"                            // matches ONLY the grandchild
        #expect(m.searchMatchIds.contains(grand.id))         // deep match reachable via n/N
        #expect(m.revealsSearchMatchRow(root))               // root reveals the path
        #expect(m.peekRows(of: root).map(\.task.id) == [child.id, grand.id])   // path expanded to the match
    }

    @Test func searchMatchIdsOrderChildAfterRoot() {
        let m = BoardModel(platform: .noop)
        let root  = worktree("01", branch: "match-root", column: .impl)
        let child = worktree("02", branch: "match-child", parentBranch: "match-root", column: .impl)
        m.tasks = [root, child]
        m.searchQuery = "match-"                             // matches both branch names
        #expect(m.searchMatchIds == [root.id, child.id])     // child ordered right after its root
    }
}
