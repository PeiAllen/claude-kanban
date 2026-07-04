import Foundation
import Testing
@testable import OrchestraCore

@Suite("Shell panel state")
struct ShellPanelStateTests {

    @Test("derives open shell windows from tmux targets and preserves live selection")
    func derivesShellWindows() {
        let targets = [
            target("agent", .agent),
            target("shell-1", .shell),
            target("shell-2", .shell),
        ]

        let state = ShellPanelState(targets: targets, previousSelection: "shell-2")

        #expect(state.windows == ["shell-1", "shell-2"])
        #expect(state.selected == "shell-2")
        #expect(state.isOpen)
    }

    @Test("falls back to first shell when previous selection is gone")
    func fallsBackToFirstShell() {
        let state = ShellPanelState(targets: [
            target("agent", .agent),
            target("shell-3", .shell),
        ], previousSelection: "shell-1")

        #expect(state.windows == ["shell-3"])
        #expect(state.selected == "shell-3")
        #expect(state.isOpen)
    }

    @Test("empty when only the agent window exists")
    func emptyWithOnlyAgent() {
        let state = ShellPanelState(targets: [target("agent", .agent)], previousSelection: "shell-1")

        #expect(state.windows.isEmpty)
        #expect(state.selected == nil)
        #expect(!state.isOpen)
    }

    private func target(_ window: String, _ kind: WindowKind) -> TmuxTarget {
        TmuxTarget(socket: "orchestra", session: "orchestra-card", window: window, kind: kind,
                   target: "orchestra-card:\(window)",
                   attach: "tmux -L orchestra attach -t orchestra-card:\(window)")
    }
}
