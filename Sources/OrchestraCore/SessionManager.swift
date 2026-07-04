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

    /// Name of the throwaway *grouped* "view" session that pins one client to a single window.
    /// Multiple SwiftTerm clients can't share one tmux session — tmux forces every client of a
    /// session onto the same active window, so opening a shell would yank the agent terminal onto
    /// it. Each client instead attaches to its own grouped view session: same shared window list,
    /// but an independent active window. The double underscore can't collide with a session name
    /// (those are `orchestra-<uuid>`, no underscores) so prefix matching in `kill` is unambiguous.
    public static func viewSession(_ base: String, _ window: String) -> String { "\(base)__\(window)" }

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
    public func ensure(_ task: Task, argv: [String], env: [String: String] = [:]) throws -> (name: String, created: Bool) {
        let name = sessionName(task.id)
        if try isAlive(name) { return (name, false) }

        var args = ["new-session", "-d", "-s", name, "-n", "agent", "-c", task.cwd,
                    "-e", "ORCHESTRA_TASK_ID=\(task.id.uuidString.lowercased())",
                    "-e", "ORCHESTRA_SOCK=\(sockEnvPath)"]
        // Per-agent environment (e.g. Codex's pinned CODEX_HOME). Sorted for deterministic argv;
        // Claude passes none, so its launch command stays byte-identical.
        for (k, v) in env.sorted(by: { $0.key < $1.key }) { args += ["-e", "\(k)=\(v)"] }
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

    /// Close a shell window and its grouped view session. No-op for a missing window; refuses to
    /// touch the `agent` window (window 0) so a stray call can't kill the agent.
    public func closeShellWindow(_ name: String, window: String) throws {
        guard window != "agent" else { return }
        _ = try? tmux(["kill-session", "-t", SessionManager.viewSession(name, window)])
        let r = try tmux(["kill-window", "-t", "\(name):\(window)"])
        // A gone window isn't an error — the caller just wants it closed.
        if !r.ok, try isAlive(name), try windowNames(name).contains(window) {
            throw OrchestraError.io(r.stderr.isEmpty ? "tmux kill-window failed" : r.stderr)
        }
    }

    /// Grouped view sessions pinned to this base session's windows (named `<base>__<window>`).
    private func viewSessions(of base: String) throws -> [String] {
        let r = try tmux(["list-sessions", "-F", "#{session_name}"])
        guard r.ok else { return [] }
        let prefix = base + "__"
        return r.stdout.split(whereSeparator: \.isNewline).map(String.init).filter { $0.hasPrefix(prefix) }
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

    /// Send a line of input to the agent window (the `send` command / inline prompt).
    public func sendKeys(_ name: String, text: String, window: String = "agent") throws {
        guard try isAlive(name) else { throw OrchestraError.io("session not alive: \(name)") }
        // Literal text, then Enter — two calls so tmux doesn't interpret the text as a key name.
        // `--` ends option parsing so a message starting with `-` (e.g. "-x", "--foo") is sent as
        // literal text rather than swallowed as a tmux flag.
        _ = try tmux(["send-keys", "-t", "\(name):\(window)", "-l", "--", text])
        _ = try tmux(["send-keys", "-t", "\(name):\(window)", "Enter"])
    }

    /// Read-only snapshot of a window's pane via `capture-pane -p` — the non-attaching read the
    /// phone Agent tab uses. Captures the *visible* pane (no scrollback) so output is naturally
    /// bounded; `maxChars` is a hard safety cap on top. Never attaches, never resizes. Works for the
    /// `agent` window and any `shell-N` window. Throws if the target window/pane doesn't exist.
    public func capture(_ name: String, window: String = "agent",
                        maxChars: Int = 256 * 1024) throws -> CaptureResult {
        let target = "\(name):\(window)"
        let r = try tmux(["capture-pane", "-p", "-t", target])
        guard r.ok else {
            throw OrchestraError.io(r.stderr.isEmpty ? "tmux capture-pane failed for \(target)" : r.stderr)
        }
        let full = r.stdout
        let truncated = full.count > maxChars
        let text = truncated ? String(full.prefix(maxChars)) : full
        return CaptureResult(window: window, text: text, truncated: truncated)
    }

    public func kill(_ name: String) throws {
        // Kill every grouped view session first: they share (and so keep alive) the base session's
        // windows — including the agent pane — so killing only the base would leak the processes.
        for view in (try? viewSessions(of: name)) ?? [] {
            _ = try? tmux(["kill-session", "-t", view])
        }
        guard try isAlive(name) else { return }
        _ = try tmux(["kill-session", "-t", name])
    }
}
