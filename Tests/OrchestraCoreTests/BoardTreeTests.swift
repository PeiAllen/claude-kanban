import XCTest
@testable import OrchestraCore

final class BoardTreeTests: XCTestCase {
    /// A worktree board card. `parent` seeds `parentBranch`; `branch` defaults to the id.
    private func card(_ id: String, _ col: Column, order: Int,
                      parent: String? = nil, branch: String? = nil,
                      repo: String = "/r", archived: Bool = false) -> Task {
        var t = Task(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
                     title: id, repo: repo, branch: branch ?? id, cwd: "\(repo)/\(id)",
                     model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: col,
                     order: order, status: .running, initialPrompt: id)
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

    func test_parentCard_respects_repo() {
        // Same branch name in a different repo must not match.
        let other = card("01", .plan, order: 0, repo: "/other")
        let child = card("02", .impl, order: 0, parent: "01", repo: "/r")
        XCTAssertNil(BoardTree.parentCard([other, child], of: child))
    }
}
