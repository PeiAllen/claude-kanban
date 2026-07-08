import XCTest
import OrchestraKit
@testable import OrchestraUI

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

        XCTAssertEqual(clip.copied.count, 3)
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

    func testEnterTerminalZoneRoutesFocusIn() {
        let (model, _, _, win) = makeModel()
        let t = planCard()
        model.tasks = [t]; model.selectedId = t.id

        model.enterTerminalZone()

        XCTAssertEqual(win.enterCount, 1)
        XCTAssertEqual(model.focusZone, .terminal)
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
