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

    @Test("builds from a broadcast ShellTab set (shellsChanged), preserving selection")
    func fromShellTabs() {
        let shells = [
            ShellTab(window: "shell-1", label: "shell-1", pwd: "/wt"),
            ShellTab(window: "phone-abc123", label: "phone-abc123", pwd: "/wt"),
        ]
        let state = ShellPanelState(shells: shells, previousSelection: "phone-abc123")
        #expect(state.windows == ["shell-1", "phone-abc123"])
        #expect(state.selected == "phone-abc123")
        #expect(state.isOpen)
    }

    @Test("empty ShellTab set closes the panel")
    func emptyShellTabs() {
        let state = ShellPanelState(shells: [], previousSelection: "shell-1")
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

@Suite("Shell owner")
struct ShellOwnerTests {
    @Test("a phone-<client> window is phone-owned and carries the client prefix")
    func phoneOwned() {
        let owner = ShellOwner(window: "phone-abc12345")
        #expect(owner == .phone(clientPrefix: "abc12345"))
        #expect(owner.isPhone)
        // Same derivation via ShellTab.owner.
        #expect(ShellTab(window: "phone-abc12345", label: "x", pwd: "/").owner.isPhone)
    }

    @Test("shell-N and inspect windows are desktop-owned")
    func desktopOwned() {
        #expect(ShellOwner(window: "shell-1") == .desktop)
        #expect(ShellOwner(window: "shell-12") == .desktop)
        #expect(!ShellOwner(window: "shell-1").isPhone)
    }
}

@Suite("shellsChanged event")
struct ShellsChangedEventTests {
    @Test("round-trips through Codable")
    func roundTrip() throws {
        let id = UUID()
        let state = ShellWindowsState(cardId: id, shells: [
            ShellTab(window: "shell-1", label: "shell-1", pwd: "/wt"),
            ShellTab(window: "phone-abc123", label: "phone-abc123", pwd: "/wt"),
        ])
        let event = Event.shellsChanged(state)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(Event.self, from: data)
        #expect(decoded == event)
        if case .shellsChanged(let s) = decoded {
            #expect(s.cardId == id)
            #expect(s.shells.map(\.window) == ["shell-1", "phone-abc123"])
        } else {
            Issue.record("expected .shellsChanged")
        }
    }
}
