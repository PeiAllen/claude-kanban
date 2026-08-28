import XCTest
@testable import OrchestraKit

final class InterfaceScaleTests: XCTestCase {
    private let minimumBody = InterfaceScale.Size(width: 940, height: 548)

    func test_normalized_recovers_malformed_values_and_snaps_to_supported_tenths() {
        XCTAssertEqual(InterfaceScale.normalized(nil), 1.0, accuracy: 0.001)
        XCTAssertEqual(InterfaceScale.normalized(.infinity), 1.0, accuracy: 0.001)
        XCTAssertEqual(InterfaceScale.normalized(0.43), 0.5, accuracy: 0.001)
        XCTAssertEqual(InterfaceScale.normalized(1.26), 1.3, accuracy: 0.001)
        XCTAssertEqual(InterfaceScale.normalized(2.8), 2.0, accuracy: 0.001)
    }

    func test_zoom_commands_step_from_the_current_value_and_clamp_at_the_bounds() {
        XCTAssertEqual(InterfaceScale.scale(after: .increase, current: 1.0), 1.1, accuracy: 0.001)
        XCTAssertEqual(InterfaceScale.scale(after: .increase, current: 2.0), 2.0, accuracy: 0.001)
        XCTAssertEqual(InterfaceScale.scale(after: .decrease, current: 0.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(InterfaceScale.scale(after: .reset, current: 1.7), 1.0, accuracy: 0.001)
    }

    func test_fit_rounds_down_to_the_largest_supported_scale_that_fits() {
        let viewport = InterfaceScale.Size(width: 1_472, height: 1_000)

        XCTAssertEqual(InterfaceScale.maximumFittingScale(viewport: viewport,
                                                           minimumLogicalSize: minimumBody),
                       1.5,
                       accuracy: 0.001)
        XCTAssertEqual(InterfaceScale.effectiveScale(requested: 2.0,
                                                      viewport: viewport,
                                                      minimumLogicalSize: minimumBody),
                       1.5,
                       accuracy: 0.001)
        XCTAssertEqual(InterfaceScale.effectiveScale(requested: 1.2,
                                                      viewport: viewport,
                                                      minimumLogicalSize: minimumBody),
                       1.2,
                       accuracy: 0.001)
    }

    func test_fit_keeps_an_exact_supported_tenth_boundary() {
        XCTAssertEqual(InterfaceScale.maximumFittingScale(
            viewport: .init(width: 1_128, height: 657.6),
            minimumLogicalSize: minimumBody),
            1.2,
            accuracy: 0.001)
    }

    func test_fit_does_not_promote_a_genuinely_smaller_viewport() {
        XCTAssertEqual(InterfaceScale.maximumFittingScale(
            viewport: .init(width: 1_127.99, height: 657.594),
            minimumLogicalSize: minimumBody),
            1.1,
            accuracy: 0.001)
    }

    func test_retained_target_applies_again_when_the_viewport_grows() {
        XCTAssertEqual(InterfaceScale.effectiveScale(requested: 2.0,
                                                      viewport: .init(width: 940, height: 548),
                                                      minimumLogicalSize: minimumBody),
                       1.0,
                       accuracy: 0.001)
        XCTAssertEqual(InterfaceScale.effectiveScale(requested: 2.0,
                                                      viewport: .init(width: 1_880, height: 1_096),
                                                      minimumLogicalSize: minimumBody),
                       2.0,
                       accuracy: 0.001)
    }

    func test_zoom_at_a_fit_cap_retains_the_target_but_decreases_from_the_visible_scale() {
        XCTAssertEqual(InterfaceScale.requestedScale(after: .increase,
                                                      requested: 2.0,
                                                      applied: 1.2,
                                                      maximumFittingScale: 1.2),
                       2.0,
                       accuracy: 0.001)
        XCTAssertEqual(InterfaceScale.requestedScale(after: .decrease,
                                                      requested: 2.0,
                                                      applied: 1.2,
                                                      maximumFittingScale: 1.2),
                       1.1,
                       accuracy: 0.001)
        XCTAssertEqual(InterfaceScale.requestedScale(after: .increase,
                                                      requested: 1.1,
                                                      applied: 1.1,
                                                      maximumFittingScale: 1.2),
                       1.2,
                       accuracy: 0.001)
    }

    func test_logical_distance_divides_a_physical_drag_by_the_captured_scale() {
        XCTAssertEqual(InterfaceScale.logicalDistance(fromPhysical: 24, scale: 2.0), 12, accuracy: 0.001)
        XCTAssertEqual(InterfaceScale.logicalDistance(fromPhysical: 24, scale: 0.5), 48, accuracy: 0.001)
    }
}
