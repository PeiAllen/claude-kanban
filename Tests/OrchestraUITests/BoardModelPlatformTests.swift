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
}
