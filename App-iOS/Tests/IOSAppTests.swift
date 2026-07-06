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

    func testInitialPageDefaultsToPlan() {
        // Absent the ORCH_DEV_BOARD_PAGE dev override, the pager lands on Plan (no behavior change).
        if ProcessInfo.processInfo.environment["ORCH_DEV_BOARD_PAGE"] == nil {
            XCTAssertEqual(BoardPage.initial, .plan)
        }
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

    // MARK: - Card detail (M2)

    func testCardTabOrderMatchesDesign() {
        // §3: the tab bar order is Agent · Terminal · Diff · Inbox · Info.
        XCTAssertEqual(CardTab.allCases, [.agent, .terminal, .diff, .inbox, .info])
        XCTAssertEqual(CardTab.allCases.map(\.title), ["Agent", "Terminal", "Diff", "Inbox", "Info"])
    }

    func testNoTabIsStub() {
        // All five tabs are now built (Agent → T3, Terminal → T2, Diff/Inbox/Info → M2).
        XCTAssertFalse(CardTab.agent.isStub)
        XCTAssertFalse(CardTab.terminal.isStub)
        XCTAssertFalse(CardTab.diff.isStub)
        XCTAssertFalse(CardTab.inbox.isStub)
        XCTAssertFalse(CardTab.info.isStub)
    }

    func testCardTabInitialDefaultsToAgent() {
        // Absent the ORCH_DEV_CARD_TAB dev override, the detail lands on Agent (design-primary).
        if ProcessInfo.processInfo.environment["ORCH_DEV_CARD_TAB"] == nil {
            XCTAssertEqual(CardTab.initial, .agent)
        }
    }

    func testDiffBaselinesGateParentOnStackedCards() {
        // §3 Diff: Parent only appears for a stacked card carrying a parentBranch.
        XCTAssertEqual(diffBaselines(parentBranch: nil), [.working, .branch])
        XCTAssertEqual(diffBaselines(parentBranch: "main"), [.working, .branch, .parent])
    }

    // MARK: - Push deep-link (N1)

    func testPushDeepLinkRoutesDiedToRecoveryElsePeek() {
        let id = UUID()
        // A died card deep-links to Recovery (matches the row's own Recover action).
        XCTAssertEqual(NeedsYouRoute.deepLink(cardId: id, status: .dead), .recover(id))
        // Everything else (waiting/running, or unknown) opens the card peek.
        XCTAssertEqual(NeedsYouRoute.deepLink(cardId: id, status: .waiting), .peek(id))
        XCTAssertEqual(NeedsYouRoute.deepLink(cardId: id, status: .running), .peek(id))
        XCTAssertEqual(NeedsYouRoute.deepLink(cardId: id, status: nil), .peek(id))
    }

    func testPushCoordinatorDeepLinkSetAndConsume() {
        let coord = PushCoordinator.shared
        coord.consumeDeepLink()                    // clean slate
        XCTAssertNil(coord.pendingCardId)
        let id = UUID()
        coord.deepLink(cardId: id)
        XCTAssertEqual(coord.pendingCardId, id)     // a tapped push exposes the target…
        coord.consumeDeepLink()
        XCTAssertNil(coord.pendingCardId)           // …and consuming it clears so it fires once
    }

    func testCardBreadcrumbWorktreeVsFreeform() {
        // Worktree: `repo/branch → …/dir`.
        XCTAssertEqual(
            cardBreadcrumb(repo: "/Users/x/Projects/claude-kanban", branch: "mobile/m2",
                           cwd: "/Users/x/.orchestra/worktrees/claude-kanban/m2", origin: .worktree),
            "claude-kanban/mobile/m2 → …/claude-kanban/m2")
        // Freeform: the directory path alone — no branch is surfaced (§2a).
        XCTAssertEqual(
            cardBreadcrumb(repo: "", branch: "", cwd: "/Users/x/scratch/thing", origin: .borrowed),
            "…/scratch/thing")
    }

    // MARK: - Sixel inline images (C2)

    private static let esc = "\u{1b}"

    func testCaptureRunsPlainTextIsSingleRun() {
        // A pane with ANSI colour but no Sixel stays one text run — no false image detection, no decode.
        let runs = captureRuns(from: "hello \u{1b}[31mred\u{1b}[0m world\nsecond line")
        XCTAssertEqual(runs.count, 1)
        if case .text = runs.first {} else { XCTFail("expected a single text run") }
    }

    func testCaptureRunsSplitsSixelFromSurroundingText() {
        // A red 12×6 Sixel between two text runs → text · image · text, in order.
        let sixel = Self.esc + "Pq#0;2;100;0;0#0" + String(repeating: "~", count: 12) + Self.esc + "\\"
        let runs = captureRuns(from: "before\n" + sixel + "\nafter")
        XCTAssertEqual(runs.count, 3)
        if case .text(let t) = runs[0] { XCTAssertTrue(t.contains("before")) } else { XCTFail("run0 text") }
        if case .image(let img) = runs[1] {
            XCTAssertEqual(img.width, 12)
            XCTAssertEqual(img.height, 6)
        } else { XCTFail("run1 image") }
        if case .text(let t) = runs[2] { XCTAssertTrue(t.contains("after")) } else { XCTFail("run2 text") }
    }

    func testSixelDecoderRGBAndBands() {
        // Two 6px bands: green over blue, RLE-repeated 8 wide → an 8×12 image with the right corners.
        let body = "#0;2;0;100;0#1;2;0;0;100#0!8~$-#1!8~"
        let runs = captureRuns(from: Self.esc + "Pq" + body + Self.esc + "\\")
        guard case .image(let img) = runs.first else { return XCTFail("expected an image run") }
        XCTAssertEqual(img.width, 8)
        XCTAssertEqual(img.height, 12)
    }

    func testNonSixelDCSIsNotTreatedAsImage() {
        // A non-Sixel DCS (no `q` selector) must not be mis-parsed as an image.
        let dcs = Self.esc + "P0$r0m" + Self.esc + "\\"   // a DECRQSS-style reply, not Sixel
        let runs = captureRuns(from: "x" + dcs + "y")
        XCTAssertFalse(runs.contains { if case .image = $0 { return true } else { return false } })
    }

    // MARK: - Sixel decoder hardening (review #9)

    func testSixelHostileRunLengthIsBoundedAndFast() {
        // A hostile `!Pn` run-length used to feed `count` straight into `for _ in 0..<reps`, spinning
        // ~2 billion times on the MAIN thread (captureRuns runs inside CapturePaneText.body). The repeat
        // must clamp to maxDimension so decode stays bounded, and the image (if any) is clamped in width.
        let hostile = Self.esc + "Pq#0;2;100;100;100!2000000000~" + Self.esc + "\\"
        let start = Date()
        let runs = captureRuns(from: hostile)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "hostile run-length must decode fast")
        if case .image(let img) = runs.first {
            XCTAssertLessThanOrEqual(img.width, SixelDecoder.maxDimension)
            XCTAssertLessThanOrEqual(img.height, SixelDecoder.maxDimension)
        }
    }

    func testSixelOverflowRunLengthDoesNotTrap() {
        // A digit string too large for Int must saturate in readInt, not trap on integer overflow.
        let hostile = Self.esc + "Pq#0;2;100;100;100!99999999999999999999999~" + Self.esc + "\\"
        let runs = captureRuns(from: hostile)   // must not crash
        XCTAssertFalse(runs.isEmpty)
        if case .image(let img) = runs.first {
            XCTAssertLessThanOrEqual(img.width, SixelDecoder.maxDimension)
        }
    }

    func testSixelOversizedHeightIsClamped() {
        // Thousands of graphics-newlines drive `band` far past the cap; height must clamp to
        // maxDimension and the decode must stay bounded (each band plots a single 6px column).
        let body = "#0;2;100;100;100" + String(repeating: "~-", count: 5000)   // ~30000px tall
        let sixel = Self.esc + "Pq" + body + Self.esc + "\\"
        let start = Date()
        let runs = captureRuns(from: sixel)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "oversized raster must decode fast")
        if case .image(let img) = runs.first {
            XCTAssertLessThanOrEqual(img.height, SixelDecoder.maxDimension)
            XCTAssertLessThanOrEqual(img.width, SixelDecoder.maxDimension)
        }
    }

    func testSixelValidImageStillDecodesAfterHardening() {
        // Regression guard for the dense two-pass rewrite: a normal small Sixel still decodes to the
        // exact expected dimensions (a red 10×6 raster).
        let sixel = Self.esc + "Pq#0;2;100;0;0#0" + String(repeating: "~", count: 10) + Self.esc + "\\"
        let runs = captureRuns(from: sixel)
        guard case .image(let img) = runs.first else { return XCTFail("expected an image run") }
        XCTAssertEqual(img.width, 10)
        XCTAssertEqual(img.height, 6)
    }

    // MARK: - SSH host-key pinning / TOFU (security #5)

    private func pinStore() -> SSHHostKeyPinStore {
        SSHHostKeyPinStore(storage: InMemoryHostKeyPinStorage())
    }
    private func fp(_ key: String) -> Data {
        SSHHostKeyPinStore.fingerprint(openSSHKey: "ssh-ed25519 \(key)")
    }

    func testHostKeyFirstUsePinsTheKey() throws {
        // TOFU: the first connect to a host has no record, so the presented key is pinned there and then.
        let store = pinStore()
        XCTAssertFalse(try store.hasPin(host: "mac.ts.net"))
        XCTAssertEqual(try store.evaluate(host: "mac.ts.net", fingerprint: fp("A")), .pinnedFirstUse)
        XCTAssertTrue(try store.hasPin(host: "mac.ts.net"))   // persisted for next time
    }

    func testHostKeyMatchingKeyIsAccepted() throws {
        // A later connect presenting the SAME key matches the pin — the normal, safe path.
        let store = pinStore()
        _ = try store.evaluate(host: "mac.ts.net", fingerprint: fp("A"))   // first use pins
        XCTAssertEqual(try store.evaluate(host: "mac.ts.net", fingerprint: fp("A")), .matched)
    }

    func testHostKeyChangedIsRejected() throws {
        // A different key on a pinned host is a possible MITM → .changed (rejected), and the change must
        // NOT overwrite the pin — the original key stays the trusted one.
        let store = pinStore()
        _ = try store.evaluate(host: "mac.ts.net", fingerprint: fp("A"))
        XCTAssertEqual(try store.evaluate(host: "mac.ts.net", fingerprint: fp("EVIL")), .changed)
        XCTAssertEqual(try store.evaluate(host: "mac.ts.net", fingerprint: fp("A")), .matched)
    }

    func testHostKeyResetReenablesTrustOnFirstUse() throws {
        // Explicit reset clears the pin so a legitimate re-key re-pins on the next connect (no dead end).
        let store = pinStore()
        _ = try store.evaluate(host: "mac.ts.net", fingerprint: fp("A"))
        try store.reset(host: "mac.ts.net")
        XCTAssertFalse(try store.hasPin(host: "mac.ts.net"))
        XCTAssertEqual(try store.evaluate(host: "mac.ts.net", fingerprint: fp("B")), .pinnedFirstUse)
        XCTAssertEqual(try store.evaluate(host: "mac.ts.net", fingerprint: fp("B")), .matched)
    }

    func testHostKeyPinsAreScopedPerHost() throws {
        // Pins are keyed by host: one host's key never validates (or masks) another's.
        let store = pinStore()
        _ = try store.evaluate(host: "host-a", fingerprint: fp("A"))
        XCTAssertEqual(try store.evaluate(host: "host-b", fingerprint: fp("B")), .pinnedFirstUse)
        XCTAssertEqual(try store.evaluate(host: "host-a", fingerprint: fp("A")), .matched)
        XCTAssertEqual(try store.evaluate(host: "host-a", fingerprint: fp("B")), .changed)
    }

    func testHostKeyResetAllClearsEveryPin() throws {
        let store = pinStore()
        _ = try store.evaluate(host: "host-a", fingerprint: fp("A"))
        _ = try store.evaluate(host: "host-b", fingerprint: fp("B"))
        try store.resetAll()
        XCTAssertFalse(try store.hasPin(host: "host-a"))
        XCTAssertFalse(try store.hasPin(host: "host-b"))
    }

    func testHostKeyFingerprintIsStableAndKeyDependent() {
        // Same key → same 32-byte SHA-256 pin (stable across connects); a different key → a different pin
        // (so a substituted key is detectable).
        XCTAssertEqual(fp("A"), fp("A"))
        XCTAssertNotEqual(fp("A"), fp("B"))
        XCTAssertEqual(fp("A").count, 32)
    }

    // MARK: - Takeover teardown (#8)

    /// #8: the takeover surface now releases on ANY dismissal (`onDisappear` → `returnToDesktop()`), having
    /// deleted the misleading `suspend()`/"quick reopen resumes control" path — a `fullScreenCover` dismiss
    /// tears down the `@StateObject`, so a reopen builds a fresh controller that re-acquires from
    /// `.acquiring`. There's no daemon in a unit test, so we can't reach `.holding`; these lock in the
    /// *reachable* invariant the fix depends on: a non-held controller never claims control, and the new
    /// unconditional `onDisappear` release is a safe, idempotent no-op (guarded by `if isHolding`) so it
    /// can't fire a bogus release or crash on a dismiss during `.acquiring`/`.failed`.

    func testTakeoverWithoutDaemonEndsFailedAndNotHolding() async {
        let model = BoardModel(platform: .ios)   // never activated → no transport, RPCs fail fast
        let controller = TakeoverController(cardId: UUID(), model: model)
        await controller.begin()
        XCTAssertFalse(controller.isHolding, "no lease granted ⇒ must not read as 'You have control'")
        guard case .failed = controller.phase else {
            return XCTFail("expected .failed without a daemon, got \(controller.phase)")
        }
    }

    func testReturnToDesktopIsSafeAndIdempotentWhenNotHolding() async {
        let model = BoardModel(platform: .ios)
        let controller = TakeoverController(cardId: UUID(), model: model)
        await controller.begin()                 // .failed (no daemon)
        // The onDisappear path calls this unconditionally now; when we never held it must be a no-op — the
        // `if isHolding` guard skips the release RPC — and idempotent on the button-then-onDisappear repeat.
        await controller.returnToDesktop()
        await controller.returnToDesktop()
        XCTAssertFalse(controller.isHolding)
    }

    /// `suspend()` is gone: the only heartbeat-cancelling paths (`returnToDesktop`, `reconcile→.lostToDesktop`)
    /// also transition the phase away from holding, so the heartbeat can never be silently cancelled while
    /// the surface still shows control. Compile-time proof lives above (no call site references `suspend`);
    /// this asserts the surviving teardown entrypoint stays reachable.
    func testControllerExposesReturnToDesktopTeardown() async {
        let controller = TakeoverController(cardId: UUID(), model: BoardModel(platform: .ios))
        await controller.returnToDesktop()       // callable before any begin(); pure no-op, no crash
        XCTAssertFalse(controller.isHolding)
    }
}

/// In-memory `HostKeyPinStorage` for the TOFU tests — the unit-test bundle can't reach a real Keychain.
/// `@unchecked Sendable`: the tests drive it single-threaded on the main actor.
private final class InMemoryHostKeyPinStorage: HostKeyPinStorage, @unchecked Sendable {
    private var pins: [String: Data] = [:]
    func loadPin(host: String) throws -> Data? { pins[host] }
    func savePin(_ pin: Data, host: String) throws { pins[host] = pin }
    func deletePin(host: String) throws { pins[host] = nil }
    func deleteAllPins() throws { pins.removeAll() }
}
