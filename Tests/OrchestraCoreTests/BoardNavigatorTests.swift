import XCTest
@testable import OrchestraCore

final class BoardNavigatorTests: XCTestCase {
    private func card(_ id: String, _ col: Column, order: Int) -> Task {
        Task(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
             title: id, repo: "/r", branch: id, cwd: "/r/\(id)",
             model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: col,
             order: order, status: .running, initialPrompt: id)
    }

    /// A freeform-dock card (non-worktree). `at` seeds `createdAt`, which drives freeform order.
    private func freeform(_ id: String, at: TimeInterval) -> Task {
        Task(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
             title: id, repo: "/r", branch: id, cwd: "/r/\(id)", origin: .borrowed,
             model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .plan,
             order: 0, status: .running, initialPrompt: id,
             createdAt: Date(timeIntervalSince1970: at))
    }

    func test_down_moves_within_column() {
        let ts = [card("01", .plan, order: 0), card("02", .plan, order: 1)]
        XCTAssertEqual(BoardNavigator.move(ts, selected: ts[0].id, .down), ts[1].id)
    }

    func test_down_at_bottom_stays() {
        let ts = [card("01", .plan, order: 0), card("02", .plan, order: 1)]
        XCTAssertEqual(BoardNavigator.move(ts, selected: ts[1].id, .down), ts[1].id)
    }

    func test_up_moves_within_column() {
        let ts = [card("01", .plan, order: 0), card("02", .plan, order: 1)]
        XCTAssertEqual(BoardNavigator.move(ts, selected: ts[1].id, .up), ts[0].id)
    }

    func test_right_moves_to_adjacent_column_same_row() {
        let ts = [card("01", .plan, order: 0),
                  card("11", .impl, order: 0), card("12", .impl, order: 1)]
        XCTAssertEqual(BoardNavigator.move(ts, selected: ts[0].id, .right), ts[1].id)
    }

    func test_right_clamps_row_to_shorter_column() {
        let ts = [card("01", .plan, order: 0), card("02", .plan, order: 1),
                  card("11", .impl, order: 0)]           // impl has one card; plan row 1 → impl row 0
        XCTAssertEqual(BoardNavigator.move(ts, selected: ts[1].id, .right), ts[2].id)
    }

    func test_right_into_empty_column_stays() {
        let ts = [card("01", .plan, order: 0)]           // impl + review empty
        XCTAssertEqual(BoardNavigator.move(ts, selected: ts[0].id, .right), ts[0].id)
    }

    func test_left_from_plan_stays() {
        let ts = [card("01", .plan, order: 0)]
        XCTAssertEqual(BoardNavigator.move(ts, selected: ts[0].id, .left), ts[0].id)
    }

    func test_move_with_no_selection_picks_first_plan() {
        let ts = [card("01", .plan, order: 0)]
        XCTAssertEqual(BoardNavigator.move(ts, selected: nil, .down), ts[0].id)
    }

    func test_end_last_and_first_of_column() {
        let ts = [card("01", .plan, order: 0), card("02", .plan, order: 1)]
        XCTAssertEqual(BoardNavigator.end(ts, selected: ts[0].id, first: false), ts[1].id)
        XCTAssertEqual(BoardNavigator.end(ts, selected: ts[1].id, first: true), ts[0].id)
    }

    // MARK: freeform dock

    func test_freeform_right_and_down_move_to_next() {
        let ts = [freeform("01", at: 1), freeform("02", at: 2), freeform("03", at: 3)]
        XCTAssertEqual(BoardNavigator.move(ts, selected: ts[0].id, .right), ts[1].id)
        XCTAssertEqual(BoardNavigator.move(ts, selected: ts[0].id, .down), ts[1].id)
    }

    func test_freeform_left_and_up_move_to_prev() {
        let ts = [freeform("01", at: 1), freeform("02", at: 2), freeform("03", at: 3)]
        XCTAssertEqual(BoardNavigator.move(ts, selected: ts[1].id, .left), ts[0].id)
        XCTAssertEqual(BoardNavigator.move(ts, selected: ts[1].id, .up), ts[0].id)
    }

    func test_freeform_stays_at_ends_never_deselects() {
        let ts = [freeform("01", at: 1), freeform("02", at: 2)]
        // The regression: a single freeform card must not clear the selection on any key.
        for dir in [Direction.up, .down, .left, .right] {
            XCTAssertEqual(BoardNavigator.move([ts[0]], selected: ts[0].id, dir), ts[0].id)
        }
        XCTAssertEqual(BoardNavigator.move(ts, selected: ts[0].id, .left), ts[0].id)   // already first
        XCTAssertEqual(BoardNavigator.move(ts, selected: ts[1].id, .right), ts[1].id)  // already last
    }

    func test_freeform_order_follows_createdAt_not_array_order() {
        let ts = [freeform("03", at: 3), freeform("01", at: 1), freeform("02", at: 2)]
        // Oldest-first: 01 → 02 → 03 regardless of array order.
        XCTAssertEqual(BoardNavigator.move(ts, selected: ts[1].id, .right), ts[2].id)
    }

    func test_freeform_end_first_and_last() {
        let ts = [freeform("01", at: 1), freeform("02", at: 2), freeform("03", at: 3)]
        XCTAssertEqual(BoardNavigator.end(ts, selected: ts[1].id, first: true), ts[0].id)
        XCTAssertEqual(BoardNavigator.end(ts, selected: ts[1].id, first: false), ts[2].id)
    }

    func test_firstBoardCard_prefers_plan_then_impl_then_review() {
        XCTAssertEqual(BoardNavigator.firstBoardCard([card("11", .impl, order: 0),
                                                      card("01", .plan, order: 0)]),
                       UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        XCTAssertEqual(BoardNavigator.firstBoardCard([card("21", .review, order: 0),
                                                      card("11", .impl, order: 0)]),
                       UUID(uuidString: "00000000-0000-0000-0000-000000000011"))
        XCTAssertNil(BoardNavigator.firstBoardCard([freeform("01", at: 1)]))
    }

    func test_columnOf() {
        let ts = [card("01", .plan, order: 0), card("11", .impl, order: 0)]
        XCTAssertEqual(BoardNavigator.columnOf(ts, ts[1].id), .impl)
        XCTAssertNil(BoardNavigator.columnOf(ts, UUID()))
    }
}
