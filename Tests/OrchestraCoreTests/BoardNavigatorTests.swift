import XCTest
@testable import OrchestraCore

final class BoardNavigatorTests: XCTestCase {
    private func card(_ id: String, _ col: Column, order: Int) -> Task {
        Task(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
             title: id, repo: "/r", branch: id, cwd: "/r/\(id)",
             model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: col,
             order: order, status: .running, initialPrompt: id)
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

    func test_columnOf() {
        let ts = [card("01", .plan, order: 0), card("11", .impl, order: 0)]
        XCTAssertEqual(BoardNavigator.columnOf(ts, ts[1].id), .impl)
        XCTAssertNil(BoardNavigator.columnOf(ts, UUID()))
    }
}
