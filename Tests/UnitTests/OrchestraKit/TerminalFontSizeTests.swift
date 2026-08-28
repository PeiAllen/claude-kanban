import XCTest
@testable import OrchestraCore

final class TerminalFontSizeTests: XCTestCase {
    func test_zoom_changes_the_default_size_by_one_point() {
        XCTAssertEqual(TerminalFontSize.pointSize(after: .increase, current: nil), 13.5, accuracy: 0.001)
        XCTAssertEqual(TerminalFontSize.pointSize(after: .decrease, current: nil), 11.5, accuracy: 0.001)
    }

    func test_zoom_clamps_a_stored_size_to_the_supported_range() {
        XCTAssertEqual(TerminalFontSize.pointSize(after: .increase, current: 32), 32, accuracy: 0.001)
        XCTAssertEqual(TerminalFontSize.pointSize(after: .decrease, current: 8), 8, accuracy: 0.001)
        XCTAssertEqual(TerminalFontSize.pointSize(after: .increase, current: .infinity), 13.5, accuracy: 0.001)
    }

    func test_reset_restores_the_standard_size() {
        XCTAssertEqual(TerminalFontSize.pointSize(after: .reset, current: 20), 12.5, accuracy: 0.001)
    }

    func test_rendered_font_cancels_the_interface_canvas_scale() {
        XCTAssertEqual(TerminalFontSize.renderedPointSize(for: 12.5, interfaceScale: 0.5), 25, accuracy: 0.001)
        XCTAssertEqual(TerminalFontSize.renderedPointSize(for: 12.5, interfaceScale: 2.0), 6.25, accuracy: 0.001)
        XCTAssertEqual(TerminalFontSize.renderedPointSize(for: 8, interfaceScale: 2.0), 4, accuracy: 0.001)
        XCTAssertEqual(TerminalFontSize.renderedPointSize(for: 32, interfaceScale: 0.5), 64, accuracy: 0.001)
    }
}
