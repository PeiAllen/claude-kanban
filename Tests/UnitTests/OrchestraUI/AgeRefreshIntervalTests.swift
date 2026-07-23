import Testing
import Foundation
@testable import OrchestraUI

/// The pill's refresh cadence tracks the AGE, not the phase — so a card whose age still reads in
/// seconds ticks every second whatever its phase, and none freezes at "· 0s" for its first minute.
/// Mirrors `ageRefreshInterval` in `SharedUI`.
@Suite struct AgeRefreshIntervalTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// Under a minute old — the stamp reads in seconds, so it must re-render every second.
    @Test func test_subMinuteAgeTicksEverySecond() {
        #expect(ageRefreshInterval(now.addingTimeInterval(-0), now: now) == 1)    // just changed phase
        #expect(ageRefreshInterval(now.addingTimeInterval(-3), now: now) == 1)
        #expect(ageRefreshInterval(now.addingTimeInterval(-59), now: now) == 1)
    }

    /// A minute or older — the stamp never reads finer than minutes, so a per-second tick is wasted.
    @Test func test_minutePlusAgeTicksOncePerMinute() {
        #expect(ageRefreshInterval(now.addingTimeInterval(-60), now: now) == 60)
        #expect(ageRefreshInterval(now.addingTimeInterval(-3600), now: now) == 60)  // hours old
    }

    /// The decision is phase-independent by construction — it only sees the timestamp. This is the
    /// property the fix rests on: a being-born (`.creatingWorktree`) or `.dead` card ages in seconds
    /// exactly like a running one, and the same sub-minute timestamp yields the same 1 s cadence
    /// regardless of which phase produced it.
    @Test func test_cadenceIsPurelyAgeDriven() {
        let bornAt = now.addingTimeInterval(-2)        // a card that just entered any phase
        #expect(ageRefreshInterval(bornAt, now: now) == 1)
    }
}
