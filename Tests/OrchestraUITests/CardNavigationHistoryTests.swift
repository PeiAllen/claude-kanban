import Foundation
import XCTest
@testable import OrchestraUI

final class CardNavigationHistoryTests: XCTestCase {
    func testBackAndForwardUseBrowserOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        var history = CardNavigationHistory()
        [a, b, c].forEach { history.record($0) }
        let valid = Set([a, b, c])

        XCTAssertEqual(history.back(validIds: valid), b)
        XCTAssertEqual(history.back(validIds: valid), a)
        XCTAssertNil(history.back(validIds: valid))
        XCTAssertEqual(history.forward(validIds: valid), b)
        XCTAssertEqual(history.forward(validIds: valid), c)
        XCTAssertNil(history.forward(validIds: valid))
    }

    func testDuplicateCurrentSelectionIsIgnored() {
        let a = UUID(), b = UUID()
        var history = CardNavigationHistory()
        history.record(a)
        history.record(b)
        history.record(b)

        XCTAssertEqual(history.back(validIds: Set([a, b])), a)
    }

    func testNewVisitAfterBackTruncatesForwardBranch() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var history = CardNavigationHistory()
        [a, b, c].forEach { history.record($0) }
        let valid = Set([a, b, c, d])

        XCTAssertEqual(history.back(validIds: valid), b)
        history.record(d)

        XCTAssertNil(history.forward(validIds: valid))
        XCTAssertEqual(history.back(validIds: valid), b)
    }

    func testTraversalSkipsRemovedCards() {
        let a = UUID(), b = UUID(), c = UUID()
        var history = CardNavigationHistory()
        [a, b, c].forEach { history.record($0) }
        let valid = Set([a, c])

        XCTAssertEqual(history.back(validIds: valid), a)
        XCTAssertEqual(history.forward(validIds: valid), c)
    }
}
