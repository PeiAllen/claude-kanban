import XCTest
import OrchestraKit
@testable import OrchestraUI

/// Pure decision coverage for PR D5's desktop terminal ownership policy. The daemon (D4) is the
/// authority for *who* owns a card's `agent` terminal; these functions decide what the **desktop**
/// does about it. They take primitives (not D4's RPC struct) so they stay AppKit-free and unit-testable.
final class DesktopTerminalDecisionTests: XCTestCase {
    func testAvailableMounts() {
        XCTAssertEqual(desktopTerminalDecision(ownerKind: nil), .mount)
    }
    func testDesktopOwnerMounts() {
        XCTAssertEqual(desktopTerminalDecision(ownerKind: .desktop), .mount)
    }
    func testPhoneOwnerShowsPlaceholder() {
        // A phone owner — fresh or stale — is the placeholder; the desktop recovers via an explicit
        // Retake, never by silently stealing the lease. Staleness only shifts the placeholder's copy.
        XCTAssertEqual(desktopTerminalDecision(ownerKind: .phone), .placeholder)
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
