import Foundation
import Testing
import OrchestraKit
@testable import OrchestraCore

@Suite("TmuxAttach recipe")
struct TmuxAttachTests {

    @Test("view session name matches the desktop SessionManager naming")
    func viewSessionMatchesSessionManager() {
        // The iOS recipe (OrchestraKit) and the desktop (OrchestraCore) MUST agree on the grouped
        // view-session name, or a phone reconnect would spawn a *different* view session than the one
        // already live and lose idempotency. This pins them together so a change to one fails here.
        #expect(TmuxAttach.viewSession(base: "orchestra-abc", window: "agent")
                == SessionManager.viewSession("orchestra-abc", "agent"))
        #expect(TmuxAttach.viewSession(base: "orchestra-abc", window: "shell-1")
                == SessionManager.viewSession("orchestra-abc", "shell-1"))
    }

    @Test("attach script matches the desktop grouped view-session recipe verbatim")
    func attachScriptMatchesDesktopRecipe() {
        // Byte-for-byte the recipe `AgentTerminalView.attachScript()` produces, so the phone and the
        // desktop attach identically. If the desktop recipe changes, update both and this test.
        let script = TmuxAttach.attachScript(socket: "orchestra", session: "orchestra-abc", window: "agent")
        #expect(script == """
        tmux -L 'orchestra' new-session -d -s 'orchestra-abc__agent' -t 'orchestra-abc' 2>/dev/null
        tmux -L 'orchestra' select-window -t 'orchestra-abc__agent:agent' 2>/dev/null
        exec tmux -L 'orchestra' attach -t 'orchestra-abc__agent'
        """)
    }

    @Test("takeover inserts a detach-client before the attach")
    func takeoverDetachesPriorClients() {
        let script = TmuxAttach.attachScript(socket: "orchestra", session: "orchestra-abc",
                                             window: "agent", takeover: true)
        #expect(script == """
        tmux -L 'orchestra' new-session -d -s 'orchestra-abc__agent' -t 'orchestra-abc' 2>/dev/null
        tmux -L 'orchestra' select-window -t 'orchestra-abc__agent:agent' 2>/dev/null
        tmux -L 'orchestra' detach-client -s 'orchestra-abc__agent' 2>/dev/null
        exec tmux -L 'orchestra' attach -t 'orchestra-abc__agent'
        """)
    }

    @Test("sshExecCommand prepends a PATH + locale prelude to the script")
    func sshExecCommandWrapsPrelude() {
        let script = TmuxAttach.attachScript(socket: "orchestra", session: "orchestra-abc", window: "agent")
        let cmd = TmuxAttach.sshExecCommand(script: script)
        #expect(cmd.hasPrefix("export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; "))
        #expect(cmd.contains("export LANG="))
        #expect(cmd.hasSuffix(script))   // the attach recipe is preserved verbatim at the end
    }

    @Test("shell metacharacters in the socket name are single-quote escaped")
    func quotesHostileSocketNames() {
        // A socket / session with a quote must not break out of the sh command. `'\\''` is the POSIX
        // idiom for an embedded single quote.
        let script = TmuxAttach.attachScript(socket: "o'r", session: "s", window: "agent")
        #expect(script.contains("tmux -L 'o'\\''r' "))
        #expect(!script.contains("tmux -L 'o'r' "))
    }
}
