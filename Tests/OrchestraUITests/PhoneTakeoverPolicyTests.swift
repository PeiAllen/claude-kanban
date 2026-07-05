import XCTest
import OrchestraKit
@testable import OrchestraUI

/// Pure decision coverage for PR T4's phone-side takeover policy — the mirror of D5's desktop policy.
/// Given the epoch/clientId this phone took the lease at, each later owner snapshot must resolve to
/// "still holding" or "lost" (drop the attach). Fail-safe default is `.lost`.
final class PhoneTakeoverStatusTests: XCTestCase {
    private let me = "phone-abc"
    private let card = UUID()

    private func owner(_ kind: AgentTerminalOwnerKind, client: String, epoch: Int) -> AgentTerminalOwner {
        AgentTerminalOwner(ownerKind: kind, clientId: client, epoch: epoch,
                           cardId: card, window: "agent", updatedAt: Date(timeIntervalSince1970: 1000))
    }

    func testHoldingWhenThisPhoneOwnsAtSameEpoch() {
        let o = owner(.phone, client: me, epoch: 5)
        XCTAssertEqual(phoneTakeoverStatus(myClientId: me, myEpoch: 5, owner: o), .holding)
    }

    func testHoldingAfterSelfRetakeBumpsEpoch() {
        // A reconnect re-take under the same client bumps the epoch; still ours → still holding.
        let o = owner(.phone, client: me, epoch: 7)
        XCTAssertEqual(phoneTakeoverStatus(myClientId: me, myEpoch: 5, owner: o), .holding)
    }

    func testLostWhenReleased() {
        XCTAssertEqual(phoneTakeoverStatus(myClientId: me, myEpoch: 5, owner: nil), .lost)
    }

    func testLostWhenDesktopRetakes() {
        // The signal for "Desktop retook control": ownerKind flips to .desktop at a higher epoch.
        let o = owner(.desktop, client: "desktop-1", epoch: 6)
        XCTAssertEqual(phoneTakeoverStatus(myClientId: me, myEpoch: 5, owner: o), .lost)
    }

    func testLostWhenAnotherPhoneTakesOver() {
        let o = owner(.phone, client: "phone-other", epoch: 6)
        XCTAssertEqual(phoneTakeoverStatus(myClientId: me, myEpoch: 5, owner: o), .lost)
    }

    func testLostOnStaleLowerEpochSnapshot() {
        // A snapshot from *before* our takeover (lower epoch) must not read as held.
        let o = owner(.phone, client: me, epoch: 4)
        XCTAssertEqual(phoneTakeoverStatus(myClientId: me, myEpoch: 5, owner: o), .lost)
    }
}
