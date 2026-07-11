import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit

/// O2 backoff + give-up cap. The re-nudge loop used to re-prod the parent every 300s FOREVER; it now
/// backs off geometrically and gives up after `mergeRequestNudgeCap` unanswered reminders, flipping the
/// child to the terminal `mergeStalled` badge so a human can see the stuck merge-request.
/// Design: `notes/designs/2026-07-11-merge-request-nudge-backoff.md`.
@Suite("merge-request re-nudge — model")
struct MergeRequestBackoffModelTests {

    @Test("a TreeStat persisted before this change decodes with nudges == 0")
    func legacyTreeStatDecodesWithZeroNudges() throws {
        let legacy = #"{"state":"mergeRequested","behind":0,"parentIsRemote":false}"#
        let ts = try JSONDecoder().decode(TreeStat.self, from: Data(legacy.utf8))
        #expect(ts.state == .mergeRequested)
        #expect(ts.nudges == 0)
    }

    @Test("nudges round-trips through Codable")
    func nudgesRoundTrips() throws {
        let ts = TreeStat(state: .mergeStalled, nudges: 8)
        let back = try JSONDecoder().decode(TreeStat.self, from: JSONEncoder().encode(ts))
        #expect(back == ts)
        #expect(back.nudges == 8)
    }

    @Test("isMergePending covers both waiting and stalled, and nothing else")
    func isMergePendingCoversBoth() {
        #expect(TreeState.mergeRequested.isMergePending)
        #expect(TreeState.mergeStalled.isMergePending)
        #expect(!TreeState.inSync.isMergePending)
        #expect(!TreeState.stale.isMergePending)
        #expect(!TreeState.restackNeeded.isMergePending)
    }
}

@Suite("merge-request re-nudge — backoff schedule")
struct NudgeDelayTests {
    private let base = Duration.seconds(300)

    @Test("the delay doubles from the base until it hits the 12x ceiling")
    func doublesThenCeilings() {
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 0) == .seconds(300))   // 1x
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 1) == .seconds(600))   // 2x
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 2) == .seconds(1200))  // 4x
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 3) == .seconds(2400))  // 8x
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 4) == .seconds(3600))  // 12x ceiling
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 5) == .seconds(3600))  // held
    }

    @Test("the ceiling is relative to the base, so an injected fast base stays fast")
    func ceilingIsBaseRelative() {
        let fast = Duration.milliseconds(20)
        #expect(OrchestraService.nudgeDelay(base: fast, attempt: 9) == .milliseconds(240))  // 12 x 20ms
    }

    @Test("a corrupt or absurd persisted count neither traps nor sleeps forever")
    func absurdAttemptIsClamped() {
        #expect(OrchestraService.nudgeDelay(base: base, attempt: Int.max) == .seconds(3600))
        #expect(OrchestraService.nudgeDelay(base: base, attempt: -5) == .seconds(300))
    }
}
