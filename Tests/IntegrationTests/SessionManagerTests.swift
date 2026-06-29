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
}
