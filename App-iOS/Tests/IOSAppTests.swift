import XCTest
import UIKit
@testable import OrchestraiOS   // internal access to the app target's conformers
import OrchestraUI
import OrchestraKit
import MarkdownUI

@MainActor
final class IOSAppTests: XCTestCase {
    func testClipboardRoundTrip() {
        let clip = IOSClipboard()
        clip.copy("orchestra-ios")
        XCTAssertEqual(UIPasteboard.general.string, "orchestra-ios")
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

    func testMarkdownLinkRetainsItsDestination() {
        let html = MarkdownContent("[Docs](https://example.com/docs)").renderHTML()
        XCTAssertTrue(html.contains("href=\"https://example.com/docs\""))
    }

    func testMarkdownGFMTableAndStrikethroughRender() {
        let html = MarkdownContent("""
        | Feature | Status |
        | :--- | ---: |
        | Tables | ~~broken~~ fixed |
        """).renderHTML()
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("Feature"))
        XCTAssertTrue(html.contains("<del>broken</del>"))
    }

    func testCardTabOrderMatchesDesign() {
        // §3: the tab bar order is Agent · Terminal · Diff · Notes · Inbox · Info. Notes (M6) is promoted
        // to a first-class tab beside Diff — both are "what this branch changed" surfaces.
        XCTAssertEqual(CardTab.allCases, [.agent, .terminal, .diff, .notes, .inbox, .info])
        XCTAssertEqual(CardTab.allCases.map(\.title),
                       ["Agent", "Terminal", "Diff", "Notes", "Inbox", "Info"])
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

    func testDiffDefaultBaselinePrefersParentWhenStacked() {
        // §3 Diff (BT3): a stacked card opens on Parent; a non-stacked card opens on Branch.
        XCTAssertEqual(diffDefaultBaseline(parentBranch: nil), .branch)
        XCTAssertEqual(diffDefaultBaseline(parentBranch: "main-feature"), .parent)
    }

    /// §3 Info: the "Copy chat link" / "Copy tmux target" buttons must copy the *exact* strings the
    /// desktop copies, so a value yanked on the phone is interchangeable with one yanked on the Mac.
    /// The desktop's source of truth is `BoardModel.copySelected` (`t.ref()` / `"\(t.tmuxSession):agent"`)
    /// and the InspectorView breadcrumb — both call these same shared `Task` accessors, which we pin here.
    func testInfoTabCopyStringsMatchDesktopExactly() {
        let task = Task(id: UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!,
                        title: "Fix the Login Bug!", repo: "/r", branch: "feat/x", cwd: "/r/x",
                        model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                        order: 0, initialPrompt: "x")

        // Chat link — identical to the desktop's "Copy chat link" (`Task.ref()`): shortId + title slug.
        let chatLink = task.ref()
        XCTAssertEqual(chatLink, "orchestra://task/abcdef-fix-the-login-bug")

        // Tmux target — identical to the desktop's "Copy tmux target": the agent-window attach target.
        let tmuxTarget = "\(task.tmuxSession):agent"
        XCTAssertEqual(tmuxTarget, "orchestra-abcdef12-3456-7890-abcd-ef1234567890:agent")

        // And the button's real copy path (UIPasteboard via IOSClipboard) round-trips each value verbatim.
        let clip = IOSClipboard()
        clip.copy(chatLink)
        XCTAssertEqual(UIPasteboard.general.string, "orchestra://task/abcdef-fix-the-login-bug")
        clip.copy(tmuxTarget)
        XCTAssertEqual(UIPasteboard.general.string, "orchestra-abcdef12-3456-7890-abcd-ef1234567890:agent")
    }

    // MARK: - Push deep-link (N1)

    func testPushDeepLinkRoutesDiedToRecoveryElsePeek() {
        let id = UUID()
        // A died card deep-links to Recovery (matches the row's own Recover action).
        XCTAssertEqual(NeedsYouRoute.deepLink(cardId: id, display: .dead), .recover(id))
        // Everything else (waiting/running, or unknown) opens the card peek.
        XCTAssertEqual(NeedsYouRoute.deepLink(cardId: id, display: .idle), .peek(id))
        XCTAssertEqual(NeedsYouRoute.deepLink(cardId: id, display: .running), .peek(id))
        XCTAssertEqual(NeedsYouRoute.deepLink(cardId: id, display: nil), .peek(id))
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

    // MARK: - ConnectionStore is remote-only on iOS (no phantom local daemon)

    private func freshConnectionStore() -> ConnectionStore {
        ConnectionStore(defaults: UserDefaults(suiteName: "orch-ios-test-\(UUID().uuidString)")!)
    }

    /// A phone has no local daemon, so the built-in `.local` connection must never appear on iOS: a fresh
    /// store is empty (not `[.local]`), and nothing in `all` is `.local`.
    func testStoreHasNoLocalConnectionOnIOS() {
        let s = freshConnectionStore()
        XCTAssertTrue(s.all.isEmpty)                       // macOS would have `[.local]`; iOS starts empty
        XCTAssertFalse(s.all.contains { $0.isLocal })
    }

    /// `all` is exactly the persisted remotes on iOS — no synthesized local, in either position.
    func testStoreAllIsRemotesOnlyOnIOS() {
        let s = freshConnectionStore()
        let c = Connection(name: "My Mac", kind: .remote, sshTarget: "me@mac.ts.net",
                           remoteSocketPath: "~/x/orchestrad.sock")
        s.upsert(c)
        XCTAssertEqual(s.all.count, 1)
        XCTAssertEqual(s.all.first?.id, c.id)
        XCTAssertFalse(s.all.contains { $0.isLocal })
    }

    /// The default/active connection resolves to a remote (never `.local`), and after deleting the active
    /// remote it falls back to another remote — again never `.local`.
    func testActiveResolvesToRemoteOnIOS() {
        let s = freshConnectionStore()
        let a = Connection(name: "Mac A", kind: .remote, sshTarget: "a@a.ts.net", remoteSocketPath: "~/a.sock")
        let b = Connection(name: "Mac B", kind: .remote, sshTarget: "b@b.ts.net", remoteSocketPath: "~/b.sock")
        s.upsert(a); s.upsert(b)
        s.activeId = a.id
        XCTAssertEqual(s.active.id, a.id)
        XCTAssertFalse(s.active.isLocal)

        s.delete(a.id)                                     // deleting the active remote falls back…
        XCTAssertEqual(s.active.id, b.id)                  // …to the remaining remote, not `.local`
        XCTAssertFalse(s.active.isLocal)
    }
}
