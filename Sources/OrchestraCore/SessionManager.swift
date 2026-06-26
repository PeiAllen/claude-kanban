import Foundation

public struct SessionInfo: Sendable, Equatable {
    public let name: String
    public let running: Bool
}

/// tmux control verbs via `Process` on a dedicated socket (`-L orchestra -f embedded.conf`).
/// One session per card (`orchestra-<id>`) with an `agent` window (0) and N `shell-N` windows.
/// Attach is client-side (SwiftTerm / CLI), never here.
public struct SessionManager: Sendable {
    let socket: String
    let confPath: String?
    let sockEnvPath: String

    public init(socket: String = Config.tmuxSocket,
                confPath: String? = SessionManager.bundledConf,
                sockEnvPath: String = Config.socketPath) {
        self.socket = socket
        self.confPath = confPath
        self.sockEnvPath = sockEnvPath
    }

    public static var bundledConf: String? {
        Bundle.module.path(forResource: "embedded", ofType: "conf")
    }

    public func sessionName(_ id: UUID) -> String { "orchestra-\(id.uuidString.lowercased())" }

    private func base() -> [String] {
        var b = ["tmux", "-L", socket]
        if let c = confPath { b += ["-f", c] }
        return b
    }

    private func tmux(_ args: [String]) throws -> ProcResult {
        try Proc.run(base() + args)
    }

    /// Ensure a session exists for the task, running `argv` (adapter start OR resume) in the agent
    /// window with ORCHESTRA_TASK_ID/ORCHESTRA_SOCK exported. Idempotent. Returns (name, created).
    @discardableResult
    public func ensure(_ task: Task, argv: [String]) throws -> (name: String, created: Bool) {
        let name = sessionName(task.id)
        if try isAlive(name) { return (name, false) }

        var args = ["new-session", "-d", "-s", name, "-n", "agent", "-c", task.worktree,
                    "-e", "ORCHESTRA_TASK_ID=\(task.id.uuidString.lowercased())",
                    "-e", "ORCHESTRA_SOCK=\(sockEnvPath)"]
        args.append("--")
        args += argv
        let r = try tmux(args)
        if !r.ok {
            throw OrchestraError.io(r.stderr.isEmpty ? "tmux new-session failed" : r.stderr)
        }
        return (name, true)
    }

    public func isAlive(_ name: String) throws -> Bool {
        // has-session returns non-zero (and a stderr) when the session is gone — that's not an error.
        let r = try tmux(["has-session", "-t", name])
        return r.ok
    }

    /// Add a `shell-N` window in the worktree; returns the window name.
    @discardableResult
    public func newShellWindow(_ name: String, cwd: String) throws -> String {
        let existing = try windowNames(name)
        var n = 1
        while existing.contains("shell-\(n)") { n += 1 }
        let win = "shell-\(n)"
        let r = try tmux(["new-window", "-t", name, "-n", win, "-c", cwd])
        if !r.ok { throw OrchestraError.io(r.stderr.isEmpty ? "tmux new-window failed" : r.stderr) }
        return win
    }

    private func windowNames(_ name: String) throws -> [String] {
        guard try isAlive(name) else { return [] }
        let r = try tmux(["list-windows", "-t", name, "-F", "#{window_name}"])
        guard r.ok else { return [] }
        return r.stdout.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// All attachable windows as `TmuxTarget`s (agent + shells). `[]` if the session is dead.
    public func windows(_ name: String) throws -> [TmuxTarget] {
        guard try isAlive(name) else { return [] }
        let r = try tmux(["list-windows", "-t", name, "-F", "#{window_index} #{window_name}"])
        guard r.ok else { return [] }
        var targets: [TmuxTarget] = []
        for line in r.stdout.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let idx = Int(parts[0]) else { continue }
            let window = String(parts[1])
            let kind: WindowKind = (idx == 0 || window == "agent") ? .agent : .shell
            let target = "\(name):\(window)"
            let attach = "tmux -L \(socket) attach -t \(target)"
            targets.append(TmuxTarget(socket: socket, session: name, window: window,
                                      kind: kind, target: target, attach: attach))
        }
        return targets
    }

    /// All live orchestra sessions.
    public func list() throws -> [SessionInfo] {
        let r = try tmux(["list-sessions", "-F", "#{session_name}"])
        guard r.ok else { return [] }   // no server / no sessions
        return r.stdout.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0.hasPrefix("orchestra-") }
            .map { SessionInfo(name: $0, running: true) }
    }

    /// Capture the agent pane (fallback for desc/ctxPct heuristics).
    public func capture(_ name: String, window: String = "agent") throws -> String {
        guard try isAlive(name) else { return "" }
        let r = try tmux(["capture-pane", "-p", "-t", "\(name):\(window)"])
        return r.ok ? r.stdout : ""
    }

    /// Send a line of input to the agent window (the `send` command / inline prompt).
    public func sendKeys(_ name: String, text: String, window: String = "agent") throws {
        guard try isAlive(name) else { throw OrchestraError.io("session not alive: \(name)") }
        // Literal text, then Enter — two calls so tmux doesn't interpret the text as a key name.
        // `--` ends option parsing so a message starting with `-` (e.g. "-x", "--foo") is sent as
        // literal text rather than swallowed as a tmux flag.
        _ = try tmux(["send-keys", "-t", "\(name):\(window)", "-l", "--", text])
        _ = try tmux(["send-keys", "-t", "\(name):\(window)", "Enter"])
    }

    public func kill(_ name: String) throws {
        guard try isAlive(name) else { return }
        _ = try tmux(["kill-session", "-t", name])
    }
}
