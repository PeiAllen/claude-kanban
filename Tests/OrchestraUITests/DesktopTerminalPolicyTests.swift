import XCTest
import OrchestraKit
@testable import OrchestraUI

/// Pure decision coverage for PR D5's desktop terminal ownership policy. The daemon (D4) is the
/// authority for *who* owns a card's `agent` terminal; these functions decide what the **desktop**
/// does about it. They take primitives (not D4's RPC struct) so they stay AppKit-free and unit-testable.
final class DesktopTerminalDecisionTests: XCTestCase {
    func testAvailableMounts() {
        XCTAssertEqual(desktopTerminalDecision(ownerKind: nil, isStale: false), .mount)
    }
    func testDesktopOwnerMounts() {
        XCTAssertEqual(desktopTerminalDecision(ownerKind: .desktop, isStale: false), .mount)
    }
    func testFreshPhoneOwnerShowsPlaceholder() {
        XCTAssertEqual(desktopTerminalDecision(ownerKind: .phone, isStale: false), .placeholder)
    }
    func testStalePhoneOwnerStillShowsPlaceholder() {
        // A stale phone owner is NOT auto-stolen — the desktop recovers via an explicit Retake.
        XCTAssertEqual(desktopTerminalDecision(ownerKind: .phone, isStale: true), .placeholder)
    }
}

final class ShouldAcquireDesktopOwnershipTests: XCTestCase {
    private let me = "desktop-abc"

    func testAvailableAcquires() {
        XCTAssertTrue(shouldAcquireDesktopOwnership(ownerKind: nil, ownerClientId: nil, desktopClientId: me))
    }
    func testAlreadyMineDoesNotReacquire() {
        // No redundant RPC on every hjkl re-select of a card we already own.
        XCTAssertFalse(shouldAcquireDesktopOwnership(ownerKind: .desktop, ownerClientId: me, desktopClientId: me))
    }
    func testAnotherDesktopClientAcquires() {
        // Desktops cooperate; the just-selected client takes the size.
        XCTAssertTrue(shouldAcquireDesktopOwnership(ownerKind: .desktop, ownerClientId: "desktop-xyz", desktopClientId: me))
    }
    func testPhoneOwnedNeverAutoAcquires() {
        // Never auto-steal from a phone; Retake is an explicit button.
        XCTAssertFalse(shouldAcquireDesktopOwnership(ownerKind: .phone, ownerClientId: "phone-1", desktopClientId: me))
    }
}

final class AgentTerminalStaleTests: XCTestCase {
    func testServerStaleWins() {
        let now = Date(timeIntervalSince1970: 1000)
        // Even a fresh heartbeat is stale if the server says so.
        XCTAssertTrue(isAgentTerminalStale(updatedAt: now, serverStale: true, now: now))
    }
    func testWithinTimeoutIsFresh() {
        let base = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(isAgentTerminalStale(updatedAt: base, serverStale: false,
                                            now: base.addingTimeInterval(agentTerminalStaleTimeout - 1)))
    }
    func testPastTimeoutIsStale() {
        let base = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(isAgentTerminalStale(updatedAt: base, serverStale: false,
                                           now: base.addingTimeInterval(agentTerminalStaleTimeout + 1)))
    }
}
