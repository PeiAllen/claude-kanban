import XCTest
import OrchestraKit
@testable import OrchestraUI
import TestSupport

/// The acceptance's "fake-platform test double": drive `BoardModel`'s three UI-op call sites through
/// spy protocol impls and assert they route correctly, with no daemon (the macOS host machinery is
/// `#if os(macOS)`-fenced and untouched by these paths).
@MainActor
final class BoardModelPlatformTests: XCTestCase {

    private func makeModel() -> (BoardModel, SpyClipboard, SpyOpener, SpyWindow) {
        let clip = SpyClipboard(); let open = SpyOpener(); let win = SpyWindow()
        let model = BoardModel(platform: PlatformUI(clipboard: clip, opener: open, window: win))
        return (model, clip, open, win)
    }

    private func planCard() -> Task {
        Task(title: "Design the seam", repo: "/repo", branch: "feat/seam",
             cwd: "/repo/.worktrees/feat-seam", model: AgentModel(id: "claude-opus-4-8"),
             startIn: .plan, column: .plan, order: 0, initialPrompt: "Design the seam")
    }

    private func makeCard(_ title: String) -> Task {
        Task(title: title, repo: "/repo", branch: "feat/\(title.lowercased())",
             cwd: "/repo/.worktrees/\(title.lowercased())", model: AgentModel(id: "claude-opus-4-8"),
             startIn: .plan, column: .plan, order: 0, initialPrompt: title)
    }

    func testCopySelectedRoutesEachTargetToClipboard() {
        let (model, clip, _, _) = makeModel()
        let t = planCard()
        model.tasks = [t]; model.selectedId = t.id

        model.copySelected(.path)
        XCTAssertEqual(clip.copied.last, t.cwd)

        model.copySelected(.chatLink)
        XCTAssertEqual(clip.copied.last, t.ref())

        model.copySelected(.tmux)
        XCTAssertEqual(clip.copied.last, "\(t.tmuxSession):agent")

        model.copySelected(.id)
        XCTAssertEqual(clip.copied.last, t.ref(slugging: false))

        XCTAssertEqual(clip.copied.count, 4)
    }

    /// The card-id badge copies the card it sits on, which need not be the selected one.
    func testCopyIdOfUnselectedCard() {
        let (model, clip, _, _) = makeModel()
        let a = makeCard("Alpha"), b = makeCard("Beta")
        model.tasks = [a, b]; model.selectedId = a.id

        model.copy(.id, of: b)
        XCTAssertEqual(clip.copied.last, b.ref(slugging: false))
        XCTAssertNotEqual(b.shortId, a.shortId)
    }

    func testCopySelectedNoSelectionDoesNothing() {
        let (model, clip, _, _) = makeModel()
        model.tasks = [planCard()]        // nothing selected
        model.copySelected(.path)
        XCTAssertTrue(clip.copied.isEmpty)
    }

    func testGoToSettingsRoutesToOpenerOnly() {
        let (model, _, open, _) = makeModel()
        let t = planCard()
        model.tasks = [t]

        model.goTo(.settings)
        XCTAssertEqual(open.openSettingsCount, 1)

        // A non-settings `goTo` mutates selection with no platform call.
        model.selectedId = nil
        model.goTo(.plan)
        XCTAssertEqual(model.selectedId, t.id)
        XCTAssertEqual(open.openSettingsCount, 1, "goTo(.plan) must not call the opener")
    }

    func testCloseFrontmostResignsInputFocusFromTerminalZone() {
        let (model, _, _, win) = makeModel()
        let t = planCard()
        model.tasks = [t]; model.selectedId = t.id
        model.focusZone = .terminal

        model.closeFrontmost()

        XCTAssertEqual(win.resignCount, 1)
        XCTAssertEqual(model.focusZone, .board)
    }

    func testCloseFrontmostPeelOrderPrefersConfirmDialogOverFocus() {
        let (model, _, _, win) = makeModel()
        let t = planCard()
        model.tasks = [t]; model.selectedId = t.id
        model.focusZone = .terminal
        model.archiveConfirm = t.id       // most-transient overlay is frontmost

        model.closeFrontmost()

        // The confirm dialog peels first; focus is untouched this call.
        XCTAssertNil(model.archiveConfirm)
        XCTAssertEqual(win.resignCount, 0)
        XCTAssertEqual(model.focusZone, .terminal)
    }

    // MARK: focusZone invariant — no selection / no inspector ⇒ .board

    func testDeselectResetsFocusZoneToBoard() {
        let (model, _, _, _) = makeModel()
        let t = planCard()
        model.tasks = [t]; model.selectedId = t.id
        model.focusZone = .terminal

        // Closing the inspector (selection → nil, e.g. the header's ✕ button) must drop focus back
        // to the board — the terminal zone only makes sense while an inspector is mounted.
        model.selectedId = nil

        XCTAssertEqual(model.focusZone, .board)
    }

    func testIdempotentDeselectReassertsBoardZone() {
        let (model, _, _, _) = makeModel()
        XCTAssertNil(model.selectedId)
        model.focusZone = .terminal

        // Preserve the pre-history invariant seam: even a repeated nil assignment repairs stale
        // focus state. Only history recording needs to be gated on a real selection transition.
        model.selectedId = nil

        XCTAssertEqual(model.focusZone, .board)
    }

    func testArchivingSelectedCardResetsFocusZoneToBoard() {
        let (model, _, _, _) = makeModel()
        let t = planCard()
        model.tasks = [t]; model.selectedId = t.id
        model.focusZone = .terminal

        // Archiving the selected card clears the selection (here via the daemon's archived-upsert
        // reconcile — the same `selectedId = nil` path `archive(_:)` and every other client hit);
        // focus must follow it back to the board instead of stranding on a terminal with no inspector.
        var archivedTask = t; archivedTask.archived = true
        model.apply(.taskUpserted(archivedTask))

        XCTAssertNil(model.selectedId)
        XCTAssertEqual(model.focusZone, .board)
    }

    func testSelectingAnotherCardDoesNotForceBoardZone() {
        let (model, _, _, _) = makeModel()
        let a = planCard(); let b = planCard()
        model.tasks = [a, b]; model.selectedId = a.id
        model.focusZone = .terminal

        // Switching selection to another card (still non-nil) must NOT reset the zone — the reset is
        // scoped to *clearing* the selection, so descending into a card's terminal survives a reselect.
        model.selectedId = b.id

        XCTAssertEqual(model.focusZone, .terminal)
    }

    func testEnterTerminalZoneRoutesFocusIn() {
        let (model, _, _, win) = makeModel()
        let t = planCard()
        model.tasks = [t]; model.selectedId = t.id

        model.enterTerminalZone()

        XCTAssertEqual(win.enterCount, 1)
        XCTAssertEqual(model.focusZone, .terminal)
    }

    // MARK: card navigation history

    func testCardHistoryRecordsEverySelectedIdTransitionAndDoesNotSelfRecord() {
        let (model, _, _, _) = makeModel()
        let a = makeCard("A"), b = makeCard("B"), c = makeCard("C")
        model.tasks = [a, b, c]
        model.selectedId = a.id
        model.selectedId = b.id
        model.selectedId = c.id

        model.navigateCardHistoryBack(fromTerminal: false)
        XCTAssertEqual(model.selectedId, b.id)
        model.navigateCardHistoryBack(fromTerminal: false)
        XCTAssertEqual(model.selectedId, a.id)
        model.navigateCardHistoryForward(fromTerminal: false)
        XCTAssertEqual(model.selectedId, b.id)
    }

    func testNewSelectionAfterHistoryBackDropsForwardHistory() {
        let (model, _, _, _) = makeModel()
        let a = makeCard("A"), b = makeCard("B"), c = makeCard("C"), d = makeCard("D")
        model.tasks = [a, b, c, d]
        model.selectedId = a.id
        model.selectedId = b.id
        model.selectedId = c.id
        model.navigateCardHistoryBack(fromTerminal: false)

        model.selectedId = d.id
        model.navigateCardHistoryForward(fromTerminal: false)

        XCTAssertEqual(model.selectedId, d.id)
    }

    func testHistoryBackFromBoardKeepsBoardFocus() {
        let (model, _, _, win) = makeModel()
        let a = makeCard("A"), b = makeCard("B")
        model.tasks = [a, b]
        model.selectedId = a.id
        model.selectedId = b.id

        model.navigateCardHistoryBack(fromTerminal: false)

        XCTAssertEqual(model.selectedId, a.id)
        XCTAssertEqual(model.focusZone, .board)
        XCTAssertEqual(win.enterCount, 0)
    }

    func testHistoryBackFromTerminalKeepsTerminalFocus() async throws {
        let (model, _, _, win) = makeModel()
        let a = makeCard("A"), b = makeCard("B")
        model.tasks = [a, b]
        model.selectedId = a.id
        model.selectedId = b.id
        model.focusZone = .terminal

        model.navigateCardHistoryBack(fromTerminal: true)

        XCTAssertEqual(model.selectedId, a.id)
        XCTAssertEqual(model.focusZone, .terminal)
        try await pollUntil("the terminal focus re-enter lands") { await win.enterCount == 1 }
        XCTAssertEqual(win.enterCount, 1)
    }

    // MARK: shell-sync (shellsChanged reconciliation)

    func testShellsChangedPopulatesSharedListForBothSurfaces() {
        let (model, _, _, _) = makeModel()
        let t = planCard()
        let shells = [ShellTab(window: "shell-1", label: "shell-1", pwd: t.cwd),
                      ShellTab(window: "phone-abc123", label: "phone-abc123", pwd: t.cwd)]

        model.ingestShellsChanged(ShellWindowsState(cardId: t.id, shells: shells))

        // Both a desktop and a phone shell now appear in the one shared list — the sync fix.
        XCTAssertEqual(model.shellWindows[t.id], ["shell-1", "phone-abc123"])
        XCTAssertEqual(model.selectedShell[t.id], "shell-1")
        XCTAssertTrue(model.shellOpen.contains(t.id))
    }

    func testShellsChangedPreservesSelectionAndReconcilesClose() {
        let (model, _, _, _) = makeModel()
        let t = planCard()
        model.ingestShellsChanged(ShellWindowsState(cardId: t.id, shells: [
            ShellTab(window: "shell-1", label: "shell-1", pwd: t.cwd),
            ShellTab(window: "phone-abc123", label: "phone-abc123", pwd: t.cwd)]))
        model.selectedShell[t.id] = "phone-abc123"

        // A close on the OTHER surface drops shell-1; the surviving selection is preserved.
        model.ingestShellsChanged(ShellWindowsState(cardId: t.id, shells: [
            ShellTab(window: "phone-abc123", label: "phone-abc123", pwd: t.cwd)]))
        XCTAssertEqual(model.shellWindows[t.id], ["phone-abc123"])
        XCTAssertEqual(model.selectedShell[t.id], "phone-abc123")

        // Closing the last shell clears the panel entirely.
        model.ingestShellsChanged(ShellWindowsState(cardId: t.id, shells: []))
        XCTAssertNil(model.shellWindows[t.id])
        XCTAssertNil(model.selectedShell[t.id])
        XCTAssertFalse(model.shellOpen.contains(t.id))
    }

    // MARK: activity feed dedup (#3)

    func testActivityFeedDedupsByIdOnResubscribe() {
        let (model, _, _, _) = makeModel()
        // The daemon replays its whole activity ring to EVERY subscribe, so a reconnect re-delivers items
        // the board already holds. Without client-side dedup these become duplicate Identifiable ids in
        // ForEach. The same item delivered twice must land once.
        let item = ActivityItem(taskId: nil, ref: nil, source: .daemon, kind: .command, text: "spawned card")
        model.apply(.activity(item))
        model.apply(.activity(item))                       // ring re-replay on reconnect
        XCTAssertEqual(model.activity.count, 1)
        XCTAssertEqual(model.activity.filter { $0.id == item.id }.count, 1)

        // A genuinely different item (distinct id) is still appended.
        let other = ActivityItem(taskId: nil, ref: nil, source: .daemon, kind: .moved, text: "moved card")
        model.apply(.activity(other))
        XCTAssertEqual(model.activity.count, 2)
    }
}
