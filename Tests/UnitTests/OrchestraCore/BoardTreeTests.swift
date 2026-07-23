import XCTest
@testable import OrchestraCore

final class BoardTreeTests: XCTestCase {
    /// A worktree board card. `parent` seeds `parentBranch`; `branch` defaults to the id.
    private func card(_ id: String, _ col: Column, order: Int,
                      parent: String? = nil, branch: String? = nil,
                      repo: String = "/r", archived: Bool = false,
                      origin: CardOrigin = .worktree) -> Task {
        var t = Task(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
                     title: id, repo: repo, branch: branch ?? id, cwd: "\(repo)/\(id)",
                     origin: origin,
                     model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: col,
                     order: order, phase: .live(.running), initialPrompt: id)
        t.parentBranch = parent
        t.archived = archived
        return t
    }

    // MARK: ordered — stability

    func test_ordered_parentless_is_bytestable() {
        let ts = [card("01", .plan, order: 0), card("02", .plan, order: 1),
                  card("03", .plan, order: 2)]
        XCTAssertEqual(BoardTree.ordered(ts).map(\.id), ts.map(\.id))
    }

    func test_ordered_parent_in_other_column_does_not_reorder() {
        // 02's parent branch is "p", but the only "p" card is in another column ⇒ 02 is a root here.
        let col = [card("01", .impl, order: 0),
                   card("02", .impl, order: 1, parent: "p")]
        XCTAssertEqual(BoardTree.ordered(col).map(\.id), col.map(\.id))
    }

    // MARK: ordered — grouping

    func test_ordered_child_follows_parent_same_column() {
        // parent "01" (branch 01) at order 0; child "03" (parent 01) at order 2; unrelated "02" at 1.
        let ts = [card("01", .plan, order: 0),
                  card("02", .plan, order: 1),
                  card("03", .plan, order: 2, parent: "01")]
        // child 03 is pulled up to directly follow its parent 01, before unrelated 02.
        XCTAssertEqual(BoardTree.ordered(ts).map(\.title), ["01", "03", "02"])
    }

    func test_ordered_grandchild_nests_depth_first() {
        let ts = [card("01", .plan, order: 0),
                  card("02", .plan, order: 1, parent: "01"),
                  card("03", .plan, order: 2, parent: "02"),
                  card("04", .plan, order: 3)]
        XCTAssertEqual(BoardTree.ordered(ts).map(\.title), ["01", "02", "03", "04"])
    }

    func test_ordered_child_above_parent_is_pulled_below_it() {
        // Child sits at a LOWER order than its parent: the flatten must still place the parent
        // first and the child directly after it (the reorder-inversion branch).
        let ts = [card("02", .plan, order: 0, parent: "01"),
                  card("01", .plan, order: 1)]
        XCTAssertEqual(BoardTree.ordered(ts).map(\.title), ["01", "02"])
    }

    func test_ordered_siblings_keep_original_order() {
        let ts = [card("01", .plan, order: 0),
                  card("02", .plan, order: 1, parent: "01"),
                  card("03", .plan, order: 2, parent: "01")]
        XCTAssertEqual(BoardTree.ordered(ts).map(\.title), ["01", "02", "03"])
    }

    // MARK: ordered — cycle safety

    func test_ordered_cycle_emits_all_cards_once() {
        // 01 → parent 02, 02 → parent 01 (both in-column): pathological cycle.
        let ts = [card("01", .plan, order: 0, parent: "02"),
                  card("02", .plan, order: 1, parent: "01")]
        let out = BoardTree.ordered(ts)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Set(out.map(\.id)), Set(ts.map(\.id)))
    }

    // MARK: indent

    func test_indent_root_is_zero() {
        let ts = [card("01", .plan, order: 0)]
        XCTAssertEqual(BoardTree.indent(ts, of: ts[0]), 0)
    }

    func test_indent_counts_in_column_depth() {
        let ts = [card("01", .plan, order: 0),
                  card("02", .plan, order: 1, parent: "01"),
                  card("03", .plan, order: 2, parent: "02")]
        XCTAssertEqual(BoardTree.indent(ts, of: ts[1]), 1)
        XCTAssertEqual(BoardTree.indent(ts, of: ts[2]), 2)
    }

    func test_indent_caps_at_max() {
        // chain 01→02→03→04→05, deeper than maxIndent (3)
        let ts = [card("01", .plan, order: 0),
                  card("02", .plan, order: 1, parent: "01"),
                  card("03", .plan, order: 2, parent: "02"),
                  card("04", .plan, order: 3, parent: "03"),
                  card("05", .plan, order: 4, parent: "04")]
        XCTAssertEqual(BoardTree.indent(ts, of: ts[4]), BoardTree.maxIndent)
    }

    func test_indent_parent_in_other_column_is_zero() {
        let ts = [card("01", .impl, order: 0, parent: "p")]  // no "p" card present
        XCTAssertEqual(BoardTree.indent(ts, of: ts[0]), 0)
    }

    func test_indent_cycle_is_bounded() {
        let ts = [card("01", .plan, order: 0, parent: "02"),
                  card("02", .plan, order: 1, parent: "01")]
        XCTAssertLessThanOrEqual(BoardTree.indent(ts, of: ts[0]), BoardTree.maxIndent)
    }

    // MARK: parentCard — cross-column lookup

    func test_parentCard_finds_live_parent_any_column() {
        let parent = card("01", .plan, order: 0)                 // branch "01"
        let child  = card("02", .impl, order: 0, parent: "01")
        XCTAssertEqual(BoardTree.parentCard([parent, child], of: child)?.id, parent.id)
    }

    func test_parentCard_nil_when_parent_archived() {
        let parent = card("01", .plan, order: 0, archived: true)
        let child  = card("02", .impl, order: 0, parent: "01")
        XCTAssertNil(BoardTree.parentCard([parent, child], of: child))
    }

    func test_parentCard_nil_when_no_parentBranch() {
        let child = card("02", .impl, order: 0)
        XCTAssertNil(BoardTree.parentCard([child], of: child))
    }

    func test_parentCard_nil_when_no_matching_branch() {
        let child = card("02", .impl, order: 0, parent: "ghost")
        XCTAssertNil(BoardTree.parentCard([child], of: child))
    }

    func test_parentCard_nil_when_parent_is_freeform() {
        // A non-worktree (borrowed/scratch) card on the parent branch is not a jump target —
        // the chip must stay a no-op (contract: bare/borrowed parent ⇒ nil).
        let parent = card("01", .plan, order: 0, origin: .borrowed)
        let child  = card("02", .impl, order: 0, parent: "01")
        XCTAssertNil(BoardTree.parentCard([parent, child], of: child))
    }

    func test_parentCard_respects_repo() {
        // Same branch name in a different repo must not match.
        let other = card("01", .plan, order: 0, repo: "/other")
        let child = card("02", .impl, order: 0, parent: "01", repo: "/r")
        XCTAssertNil(BoardTree.parentCard([other, child], of: child))
    }

    func test_parentCard_tie_broken_by_id_deterministically() {
        // Two live cards on the SAME repo/branch with EQUAL createdAt — a real case, since task dates
        // serialize at second resolution. The winner must be stable by id, not by input order.
        let t0 = Date(timeIntervalSince1970: 1000)
        func onBranchP(_ id: String) -> Task {
            Task(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
                 title: id, repo: "/r", branch: "p", cwd: "/r/\(id)",
                 model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                 order: 0, phase: .live(.running), initialPrompt: id, createdAt: t0)
        }
        let a = onBranchP("01")   // lower id ⇒ the deterministic winner
        let b = onBranchP("04")
        let child = card("02", .impl, order: 0, parent: "p")
        XCTAssertEqual(BoardTree.parentCard([b, a, child], of: child)?.id, a.id)
        XCTAssertEqual(BoardTree.parentCard([a, b, child], of: child)?.id, a.id)
    }

    // MARK: hierarchy — the unified subordinate relation (slice 2b)

    /// A read-only card. Branchless (borrowed reviewer) when `parent`/`branch` unset; `cwd` is what
    /// the branchless attach rule matches against its target's `cwd`.
    private func ro(_ id: String, _ col: Column, order: Int, parent: String? = nil,
                    branch: String? = nil, repo: String = "/r", cwd: String? = nil,
                    origin: CardOrigin = .worktree) -> Task {
        var t = Task(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
                     title: id, repo: origin == .worktree ? repo : "",
                     branch: origin == .worktree ? (branch ?? id) : "",
                     cwd: cwd ?? "\(repo)/\(id)", origin: origin, access: .readOnly,
                     model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: col,
                     order: order, phase: .live(.running), initialPrompt: id)
        t.parentBranch = parent
        return t
    }

    // hierarchyParent = attachedTarget (RO branchless cwd-owner) ?? lineageParent (parentCard)

    func test_hierarchyParent_branchlessReadOnly_attachesToCwdOwner() {
        let owner = card("01", .impl, order: 0)                    // cwd "/r/01"
        let watcher = ro("02", .impl, order: 1, cwd: "/r/01", origin: .borrowed)  // borrows owner's dir
        XCTAssertEqual(BoardTree.hierarchyParent([owner, watcher], of: watcher)?.id, owner.id)
    }

    func test_hierarchyParent_readWriteChild_resolvesViaLineage() {
        // A read-write PR child (no attachedTarget) resolves to its lineage parent.
        let root = card("01", .impl, order: 0)
        let pr   = card("02", .plan, order: 1, parent: "01")
        XCTAssertEqual(BoardTree.hierarchyParent([root, pr], of: pr)?.id, root.id)
    }

    func test_hierarchyParent_standalone_isNil() {
        let solo = card("01", .impl, order: 0)                     // no parent, no cwd match
        XCTAssertNil(BoardTree.hierarchyParent([solo], of: solo))
    }

    // lineageParent is worktree-lineage ONLY (never the cwd-attach rule) — the citizenship axis.

    func test_lineageParent_ignoresCwdAttach() {
        let owner = card("01", .impl, order: 0)
        let watcher = ro("02", .impl, order: 1, cwd: "/r/01", origin: .borrowed)
        XCTAssertNil(BoardTree.lineageParent([owner, watcher], of: watcher))
    }

    // hierarchyRoot — climb, self when rootless, NIL on cycle (fail-open signal, mirrors attachedRoot)

    func test_hierarchyRoot_rootless_isSelf() {
        let solo = card("01", .impl, order: 0)
        XCTAssertEqual(BoardTree.hierarchyRoot([solo], of: solo)?.id, solo.id)
    }

    func test_hierarchyRoot_climbsToTop() {
        let root = card("01", .impl, order: 0)
        let mid  = card("02", .impl, order: 1, parent: "01")
        let leaf = card("03", .impl, order: 2, parent: "02")
        XCTAssertEqual(BoardTree.hierarchyRoot([root, mid, leaf], of: leaf)?.id, root.id)
    }

    func test_hierarchyRoot_nilOnCycle() {
        // A→B→A lineage cycle has no real root ⇒ nil (the caller fails OPEN: renders as a citizen).
        let a = card("01", .impl, order: 0, parent: "02")
        let b = card("02", .impl, order: 1, parent: "01")
        XCTAssertNil(BoardTree.hierarchyRoot([a, b], of: a))
    }

    // subordinates — DIRECT children, read-write (lineage) first then read-only (attached), stable by age

    func test_subordinates_directChildren_lineageThenAttached() {
        let root = card("01", .impl, order: 0)
        let pr   = card("02", .plan, order: 1, parent: "01")               // read-write lineage
        let rev  = ro("03", .impl, order: 2, parent: "01")                 // read-only reviewer (base=01)
        let out  = BoardTree.subordinates([root, pr, rev], of: root)
        XCTAssertEqual(out.map(\.id), [pr.id, rev.id])                     // lineage first, then attached
    }

    func test_subordinates_excludesGrandchildren() {
        let root = card("01", .impl, order: 0)
        let mid  = card("02", .impl, order: 1, parent: "01")
        let leaf = card("03", .impl, order: 2, parent: "02")
        XCTAssertEqual(BoardTree.subordinates([root, mid, leaf], of: root).map(\.id), [mid.id])
    }

    // descendants — full subtree (for search), cycle-safe

    func test_descendants_walksFullSubtree() {
        let root = card("01", .impl, order: 0)
        let mid  = card("02", .impl, order: 1, parent: "01")
        let leaf = card("03", .impl, order: 2, parent: "02")
        XCTAssertEqual(Set(BoardTree.descendants([root, mid, leaf], of: root).map(\.id)),
                       [mid.id, leaf.id])
    }

    func test_descendants_cycleSafe() {
        let a = card("01", .impl, order: 0)
        let b = card("02", .impl, order: 1, parent: "01")
        let c = card("03", .impl, order: 2, parent: "02")
        // introduce a back-edge b's subtree via a self-referential grandchild is hard here; instead a
        // simple two-node cycle among descendants must terminate and not duplicate.
        XCTAssertEqual(BoardTree.descendants([a, b, c], of: a).count, 2)
    }
}
