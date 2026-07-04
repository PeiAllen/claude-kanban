import Foundation
import Testing
@testable import OrchestraCore

@Suite("SessionManager — real tmux", .enabled(if: IntegrationSupport.tmuxAvailable), .serialized)
final class SessionManagerTests {

    // A unique tmux socket per test instance so suites don't collide; killed in deinit.
    let socket = "orch-test-\(UUID().uuidString.prefix(8))"
    var createdSessions: [String] = []
    let sm: SessionManager

    init() {
        sm = SessionManager(socket: socket, confPath: SessionManager.bundledConf, sockEnvPath: "/tmp/fake.sock")
    }

    deinit {
        // Tear down the whole throwaway tmux server.
        _ = try? Proc.run(["tmux", "-L", socket, "kill-server"])
    }

    private func makeTask(cwd: String) -> Task {
        Task(title: "t", repo: cwd, branch: "b", cwd: cwd, model: AgentModel(id: "m"),
             startIn: .impl, column: .impl, order: 0, initialPrompt: "t")
    }

    /// A long-lived window command so the session stays alive for assertions.
    private var keepAliveArgv: [String] { ["sleep", "30"] }

    @Test("detachAgentViewClients drops clients of the agent view session; no-op when absent")
    func detachAgentView() throws {
        // Load-bearing guarantee: never throws when there is no such session/view.
        #expect(throws: Never.self) { try sm.detachAgentViewClients("orchestra-nonexistent") }

        // With a live agent view session standing, detaching still succeeds (best-effort).
        let cwd = IntegrationSupport.tempDir("sm-detach")
        let task = makeTask(cwd: cwd)
        let (name, _) = try sm.ensure(task, argv: keepAliveArgv)
        _ = try? Proc.run(["tmux", "-L", socket, "new-session", "-d",
                           "-s", SessionManager.viewSession(name, "agent"), "-t", name])
        #expect(throws: Never.self) { try sm.detachAgentViewClients(name) }
        try sm.kill(name)
    }

    @Test("ensure creates an agent window in the worktree cwd; idempotent; isAlive flips on kill")
    func ensureAndLiveness() throws {
        let cwd = IntegrationSupport.tempDir("sm")
        let task = makeTask(cwd: cwd)
        let (name, created) = try sm.ensure(task, argv: keepAliveArgv)
        #expect(created)
        #expect(try sm.isAlive(name))

        // idempotent
        let (_, created2) = try sm.ensure(task, argv: keepAliveArgv)
        #expect(!created2)

        // window 0 is the agent window
        let wins = try sm.windows(name)
        #expect(wins.first?.kind == .agent)
        #expect(wins.first?.window == "agent")
        #expect(wins.first?.attach.contains("attach -t \(name):agent") == true)

        try sm.kill(name)
        #expect(try !sm.isAlive(name))
        #expect(try sm.windows(name).isEmpty)
    }

    @Test("newShellWindow adds shell-N windows; windows() returns agent + shells")
    func shellWindows() throws {
        let cwd = IntegrationSupport.tempDir("sm")
        let task = makeTask(cwd: cwd)
        let (name, _) = try sm.ensure(task, argv: keepAliveArgv)
        let w1 = try sm.newShellWindow(name, cwd: cwd)
        #expect(w1 == "shell-1")
        let w2 = try sm.newShellWindow(name, cwd: cwd)
        #expect(w2 == "shell-2")

        let wins = try sm.windows(name)
        #expect(wins.contains { $0.kind == .agent && $0.window == "agent" })
        #expect(wins.contains { $0.kind == .shell && $0.window == "shell-1" })
        #expect(wins.contains { $0.kind == .shell && $0.window == "shell-2" })
        try sm.kill(name)
    }

    @Test("closeShellWindow removes one shell, leaves agent + siblings; refuses to kill agent")
    func closeShell() throws {
        let cwd = IntegrationSupport.tempDir("sm")
        let task = makeTask(cwd: cwd)
        let (name, _) = try sm.ensure(task, argv: keepAliveArgv)
        _ = try sm.newShellWindow(name, cwd: cwd)   // shell-1
        _ = try sm.newShellWindow(name, cwd: cwd)   // shell-2

        try sm.closeShellWindow(name, window: "shell-1")
        let wins = try sm.windows(name)
        #expect(!wins.contains { $0.window == "shell-1" })
        #expect(wins.contains { $0.window == "agent" })
        #expect(wins.contains { $0.window == "shell-2" })

        // Closing a missing window is a no-op, not an error.
        try sm.closeShellWindow(name, window: "shell-1")
        // The agent window is protected.
        try sm.closeShellWindow(name, window: "agent")
        #expect(try sm.windows(name).contains { $0.window == "agent" })
        try sm.kill(name)
    }

    @Test("kill tears down grouped view sessions so shared windows don't leak")
    func killReapsViewSessions() throws {
        let cwd = IntegrationSupport.tempDir("sm")
        let task = makeTask(cwd: cwd)
        let (name, _) = try sm.ensure(task, argv: keepAliveArgv)
        // Mimic a SwiftTerm client: a grouped "view" session pinned to the agent window.
        let view = SessionManager.viewSession(name, "agent")
        _ = try Proc.run(["tmux", "-L", socket, "new-session", "-d", "-s", view, "-t", name])
        #expect(try sm.isAlive(view))

        try sm.kill(name)
        #expect(try !sm.isAlive(name))
        #expect(try !sm.isAlive(view))
    }

    @Test("list filters to orchestra-* sessions")
    func listFilters() throws {
        let cwd = IntegrationSupport.tempDir("sm")
        let task = makeTask(cwd: cwd)
        let (name, _) = try sm.ensure(task, argv: keepAliveArgv)
        let sessions = try sm.list()
        #expect(sessions.contains { $0.name == name })
        try sm.kill(name)
    }

    @Test("ensure exports ORCHESTRA_TASK_ID into the window env")
    func envExported() throws {
        let cwd = IntegrationSupport.tempDir("sm")
        let task = makeTask(cwd: cwd)
        let (name, _) = try sm.ensure(task, argv: keepAliveArgv)
        // show-environment reads the session env we set with -e
        let r = try Proc.run(["tmux", "-L", socket, "show-environment", "-t", name, "ORCHESTRA_TASK_ID"])
        #expect(r.stdout.contains(task.id.uuidString.lowercased()))
        try sm.kill(name)
    }

    @Test("capture returns the agent pane's visible text; size-caps; missing window throws")
    func captureAgent() throws {
        let cwd = IntegrationSupport.tempDir("sm")
        let task = makeTask(cwd: cwd)
        let marker = "CAPTURE_MARKER_\(UInt32.random(in: 0..<1_000_000))"
        // Echo a known marker into the agent pane, then keep the window alive.
        let (name, _) = try sm.ensure(task, argv: ["sh", "-c", "echo \(marker); sleep 30"])

        // tmux needs a beat to render the echo; retry so the test isn't flaky.
        var cap = try sm.capture(name)
        for _ in 0..<20 where !cap.text.contains(marker) {
            Thread.sleep(forTimeInterval: 0.05)
            cap = try sm.capture(name)
        }
        #expect(cap.window == "agent")
        #expect(cap.text.contains(marker))
        #expect(!cap.truncated)

        // A tiny cap truncates and sets the flag.
        let small = try sm.capture(name, window: "agent", maxChars: 3)
        #expect(small.text.count == 3)
        #expect(small.truncated)

        // Capturing a non-existent window throws (target can't be found).
        #expect(throws: OrchestraError.self) { try sm.capture(name, window: "shell-9") }

        try sm.kill(name)
    }

    @Test("capture reads a shell window too (works for non-agent windows)")
    func captureShell() throws {
        let cwd = IntegrationSupport.tempDir("sm")
        let task = makeTask(cwd: cwd)
        let (name, _) = try sm.ensure(task, argv: keepAliveArgv)   // ["sleep", "30"]
        let win = try sm.newShellWindow(name, cwd: cwd)            // "shell-1"
        let marker = "SHELL_MARK_\(UInt32.random(in: 0..<1_000_000))"
        try sm.sendKeys(name, text: "echo \(marker)", window: win)

        var cap = try sm.capture(name, window: win)
        for _ in 0..<20 where !cap.text.contains(marker) {
            Thread.sleep(forTimeInterval: 0.05)
            cap = try sm.capture(name, window: win)
        }
        #expect(cap.window == win)
        #expect(cap.text.contains(marker))
        try sm.kill(name)
    }

    // MARK: - send-keys (D2)

    /// Poll a pane via `sm.capture` until it contains `needle` or the attempt budget runs out.
    /// Pane reactions are asynchronous (the program processes the key after tmux delivers it),
    /// so assertions poll rather than read once. Returns the last capture for failure messages.
    @discardableResult
    private func waitForPane(_ name: String, window: String = "agent",
                             contains needle: String, attempts: Int = 40) throws -> String {
        var last = ""
        for _ in 0..<attempts {
            last = (try? sm.capture(name, window: window))?.text ?? ""
            if last.contains(needle) { return last }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return last
    }

    private var menuFixturePath: String {
        Bundle.module.path(forResource: "Fixtures/menu", ofType: "sh")
            ?? Bundle.module.path(forResource: "menu", ofType: "sh") ?? ""
    }

    @Test("literal text token types into the pane; Enter token submits it")
    func chordTextThenEnter() throws {
        let cwd = IntegrationSupport.tempDir("sm")
        let task = makeTask(cwd: cwd)
        // A plain shell in the agent window reads commands from its pty.
        let (name, _) = try sm.ensure(task, argv: ["/bin/sh"])

        // Text alone types the line; the explicit Enter token then submits it and it runs.
        try sm.sendChord(name, tokens: [.text("echo D2_SUBMIT_OK")], window: "agent")
        try sm.sendChord(name, tokens: [.named(.enter)], window: "agent")
        let pane = try waitForPane(name, contains: "D2_SUBMIT_OK")
        #expect(pane.contains("D2_SUBMIT_OK"))
        try sm.kill(name)
    }

    @Test("C-c interrupts a running foreground command")
    func chordCtrlCInterrupts() throws {
        let cwd = IntegrationSupport.tempDir("sm")
        let task = makeTask(cwd: cwd)
        let (name, _) = try sm.ensure(task, argv: ["/bin/sh"])

        // Block the shell on a long sleep.
        try sm.sendChord(name, tokens: [.text("sleep 30")], window: "agent")
        try sm.sendChord(name, tokens: [.named(.enter)], window: "agent")
        // Interrupt it, then prove the shell is interactive again.
        try sm.sendChord(name, tokens: [.named(.ctrlC)], window: "agent")
        try sm.sendChord(name, tokens: [.text("echo BACK_ALIVE")], window: "agent")
        try sm.sendChord(name, tokens: [.named(.enter)], window: "agent")
        // If C-c had NOT interrupted, the shell would still be blocked on sleep and never echo.
        let pane = try waitForPane(name, contains: "BACK_ALIVE")
        #expect(pane.contains("BACK_ALIVE"))
        try sm.kill(name)
    }

    @Test("arrow keys move a menu selection; Enter chooses it")
    func chordArrowsMoveMenu() throws {
        #expect(!menuFixturePath.isEmpty)
        let cwd = IntegrationSupport.tempDir("sm")
        let task = makeTask(cwd: cwd)
        // Run the menu fixture as the agent-window program (bash <path> — no exec bit needed).
        let (name, _) = try sm.ensure(task, argv: ["bash", menuFixturePath])
        _ = try waitForPane(name, contains: "SELECTED=ALPHA")   // initial render

        try sm.sendChord(name, tokens: [.named(.down)], window: "agent")   // ALPHA -> BRAVO
        _ = try waitForPane(name, contains: "SELECTED=BRAVO")
        try sm.sendChord(name, tokens: [.named(.down)], window: "agent")   // BRAVO -> CHARLIE
        _ = try waitForPane(name, contains: "SELECTED=CHARLIE")
        try sm.sendChord(name, tokens: [.named(.up)], window: "agent")     // CHARLIE -> BRAVO
        _ = try waitForPane(name, contains: "SELECTED=BRAVO")
        try sm.sendChord(name, tokens: [.named(.enter)], window: "agent")  // choose BRAVO
        let pane = try waitForPane(name, contains: "CHOSE=BRAVO")
        #expect(pane.contains("CHOSE=BRAVO"))
        try sm.kill(name)
    }

    @Test("sendChord on a dead session throws")
    func chordDeadSession() throws {
        #expect(throws: OrchestraError.self) {
            try sm.sendChord("orchestra-does-not-exist", tokens: [.named(.enter)], window: "agent")
        }
    }
}
