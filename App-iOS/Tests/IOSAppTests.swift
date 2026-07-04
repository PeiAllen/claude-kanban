import XCTest
@testable import OrchestraiOS   // internal access to the app target's conformers
import OrchestraUI
import OrchestraKit

@MainActor
final class IOSAppTests: XCTestCase {
    func testClipboardRoundTrip() {
        let clip = IOSClipboard()
        clip.copy("orchestra-ios")
        XCTAssertEqual(clip.string, "orchestra-ios")
    }

    // MARK: - Board pager (M1)

    func testBoardPageOrderIsFreeformFirst() {
        // §2a: the pager order is Freeform · Plan · Impl · Review — Freeform is the leftmost peer page.
        XCTAssertEqual(BoardPage.allCases, [.freeform, .plan, .impl, .review])
        XCTAssertEqual(BoardPage.allCases.map(\.title), ["Freeform", "Plan", "Impl", "Review"])
    }

    func testBoardPageColumnMapping() {
        XCTAssertNil(BoardPage.freeform.column)          // freeform cards have no lifecycle column
        XCTAssertTrue(BoardPage.freeform.isFreeform)
        XCTAssertEqual(BoardPage.plan.column, .plan)
        XCTAssertEqual(BoardPage.impl.column, .impl)
        XCTAssertEqual(BoardPage.review.column, .review)
        XCTAssertFalse(BoardPage.review.isFreeform)
    }

    func testMoveTargetsExcludeCurrentColumn() {
        XCTAssertEqual(moveTargets(from: .impl), [.plan, .review])
        XCTAssertEqual(moveTargets(from: .plan), [.impl, .review])
        XCTAssertEqual(moveTargets(from: .review), [.plan, .impl])
    }

    func testAdjacentColumnClampsAtEnds() {
        XCTAssertEqual(adjacentColumn(from: .plan, movingRight: true), .impl)
        XCTAssertEqual(adjacentColumn(from: .impl, movingRight: true), .review)
        XCTAssertNil(adjacentColumn(from: .review, movingRight: true))     // no column right of Review
        XCTAssertEqual(adjacentColumn(from: .review, movingRight: false), .impl)
        XCTAssertEqual(adjacentColumn(from: .impl, movingRight: false), .plan)
        XCTAssertNil(adjacentColumn(from: .plan, movingRight: false))      // no column left of Plan
    }

    func testActivityFilterSplitsLiveFromCli() {
        func item(_ source: ActivitySource) -> ActivityItem {
            ActivityItem(taskId: nil, ref: nil, source: source, kind: .command, text: "x")
        }
        XCTAssertTrue(ActivityFilter.cli.matches(item(.cli)))
        XCTAssertFalse(ActivityFilter.cli.matches(item(.app)))
        XCTAssertTrue(ActivityFilter.live.matches(item(.app)))
        XCTAssertTrue(ActivityFilter.live.matches(item(.agent)))
        XCTAssertTrue(ActivityFilter.live.matches(item(.mcp)))    // MCP rides with Live
        XCTAssertFalse(ActivityFilter.live.matches(item(.cli)))
    }

    func testWindowConfigHasNoTerminalToFocus() {
        // The placeholder iOS window seam mounts no terminal, so a focus request honestly fails.
        XCTAssertFalse(IOSWindowConfig().enterTerminalFocus())
    }

    func testPlatformBundleIsWired() {
        // The bundle handed to BoardModel(platform:) must carry the iOS conformers, not the no-ops.
        let bundle = PlatformUI.ios
        XCTAssertTrue(bundle.clipboard is IOSClipboard)
        XCTAssertTrue(bundle.opener is IOSSystemOpener)
        XCTAssertTrue(bundle.window is IOSWindowConfig)
    }
}
