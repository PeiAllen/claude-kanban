import XCTest
@testable import OrchestraUI

/// The freeform-trust state machine shared by both spawn sheets. The headline test is the generation
/// race guard (deep-review bug #7): a slow, stale `trustState` reply that lands AFTER a successful grant
/// must NOT flip `cwdTrusted` back to false ("I granted trust but the UI silently reverted to read-only").
/// Hoisting the logic here makes this guard protect BOTH surfaces — the desktop previously lacked it.
@MainActor
final class FreeformTrustModelTests: XCTestCase {

    /// A one-shot async gate: `wait()` suspends until `signal()` fires (or returns immediately if already
    /// signalled). Lets a test suspend a stub daemon call at a precise point and release it on cue.
    private actor Gate {
        private var signalled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if signalled { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func signal() {
            signalled = true
            for w in waiters { w.resume() }
            waiters.removeAll()
        }
    }

    /// Basic refresh: an untrusted reply sets `cwdTrusted = false` and reports `.untrusted`; a trusted
    /// reply sets it true and reports `.trusted`.
    func testRefreshReflectsTrustState() async {
        let trust = FreeformTrustModel()
        let untrusted = await trust.refresh(path: "/dir") { _ in false }
        XCTAssertEqual(untrusted, .untrusted)
        XCTAssertEqual(trust.cwdTrusted, false)

        let trusted = await trust.refresh(path: "/dir") { _ in true }
        XCTAssertEqual(trusted, .trusted)
        XCTAssertEqual(trust.cwdTrusted, true)
    }

    /// A successful grant flips `cwdTrusted` to true, reports `.granted`, and leaves `granting` cleared.
    func testGrantSucceeds() async {
        let trust = FreeformTrustModel()
        _ = await trust.refresh(path: "/dir") { _ in false }
        let result = await trust.grant { _ in true }
        XCTAssertEqual(result, .granted)
        XCTAssertEqual(trust.cwdTrusted, true)
        XCTAssertFalse(trust.granting)
    }

    /// Bug #7 — the race guard. A refresh whose `trustState` reply is held until AFTER a grant has
    /// succeeded must be dropped as `.stale`: `cwdTrusted` stays true, never reverting to false.
    func testStaleRefreshAfterGrantDoesNotRevertTrust() async {
        let trust = FreeformTrustModel()
        let refreshStarted = Gate()   // fires once the refresh has captured its generation and suspended
        let releaseRefresh = Gate()   // held until the grant has completed

        // Launch a refresh whose (untrusted) reply is stalled inside the daemon call.
        let refreshTask = _Concurrency.Task { @MainActor in
            await trust.refresh(path: "/dir") { _ in
                await refreshStarted.signal()
                await releaseRefresh.wait()
                return false            // the slow, stale "untrusted" reply
            }
        }

        // Ensure the refresh is parked mid-flight (generation captured) before the grant runs.
        await refreshStarted.wait()

        // Grant succeeds — bumps the generation past the in-flight refresh.
        let grant = await trust.grant { _ in true }
        XCTAssertEqual(grant, .granted)
        XCTAssertEqual(trust.cwdTrusted, true)

        // Now let the stale refresh reply land. It must be recognized as superseded.
        await releaseRefresh.signal()
        let refreshOutcome = await refreshTask.value
        XCTAssertEqual(refreshOutcome, .stale, "the superseded refresh reply must be dropped")
        XCTAssertEqual(trust.cwdTrusted, true, "grant must not be reverted by the stale refresh")
    }

    /// The path guard: a reply for a dir that has since changed (here: `reset`) is dropped, not applied.
    func testStaleReplyForChangedDirIsDropped() async {
        let trust = FreeformTrustModel()
        let started = Gate()
        let release = Gate()

        let task = _Concurrency.Task { @MainActor in
            await trust.refresh(path: "/old") { _ in
                await started.signal()
                await release.wait()
                return false
            }
        }
        await started.wait()
        trust.reset()                       // dir changed out from under the in-flight refresh
        await release.signal()
        let outcome = await task.value
        XCTAssertEqual(outcome, .stale)
        XCTAssertNil(trust.cwdTrusted)      // reset's nil stands; the stale reply didn't write false
    }
}
