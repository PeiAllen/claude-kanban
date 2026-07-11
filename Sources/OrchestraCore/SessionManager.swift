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
    public static func viewSession(_ base: String, _ window: String) -> String {
        // Delegate to the single source of truth in OrchestraKit (shared with the desktop/iOS terminal
        // clients) rather than re-spelling `"\(base)__\(window)"`. TmuxAttachTests pins them equal.
        TmuxAttach.viewSession(base: base, window: window)
    }

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

    /// The `ORCH_EPOCH` generation stamped into the session's environment at launch (Stage 2). Read back
    /// via `tmux show-environment -t <name> ORCH_EPOCH`; `nil` when the variable is absent/unset or the
    /// session is gone. Its consumer is the Stage-4 restart/reconcile path; the parse test keeps it live.
    public func stampedEpoch(name: String) throws -> Int? {
        // A never-set variable makes `show-environment` exit non-zero ("unknown variable"); that's not an
        // error here — it just means no stamp. A removed variable prints the `-ORCH_EPOCH` unset form.
        let r = try tmux(["show-environment", "-t", name, "ORCH_EPOCH"])
        guard r.ok else { return nil }
        return Self.parseStampedEpoch(r.stdout)
    }

    /// Parse a `tmux show-environment … ORCH_EPOCH` payload: `ORCH_EPOCH=<n>` → `n`; the `-ORCH_EPOCH`
    /// unset form, an absent line, or an unparseable value → `nil`. Pure so it is unit-testable without tmux.
    static func parseStampedEpoch(_ output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("ORCH_EPOCH=") else { continue }
            return Int(s.dropFirst("ORCH_EPOCH=".count))
        }
        return nil
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

    /// Ensure a **specifically-named** window exists in the worktree; returns its name. Unlike
    /// `newShellWindow` (which auto-increments `shell-N`), this is **idempotent** — if a window of that
    /// name already exists it is reused, never duplicated. This is the phone-owned-shell reconnect
    /// guarantee: the phone requests a deterministic `phone-<client>` window, so a re-attach lands on the
    /// same window instead of spawning a fresh one (phone-agent-terminal UX design, §"Reconnect churn").
    @discardableResult
    public func ensureShellWindow(_ name: String, window: String, cwd: String) throws -> String {
        guard Self.isValidShellWindowName(window) else {
            throw OrchestraError.invalidParams("invalid shell window name: \(window)")
        }
        if try windowNames(name).contains(window) { return window }
        let r = try tmux(["new-window", "-t", name, "-n", window, "-c", cwd])
        if !r.ok { throw OrchestraError.io(r.stderr.isEmpty ? "tmux new-window failed" : r.stderr) }
        return window
    }

    /// A client-supplied shell window name is restricted to `[A-Za-z0-9-]` and may never be the reserved
    /// `agent` window (window 0). This stops a client from re-targeting the `"\(name):\(window)"` tmux
    /// argument at another window/session (a `:`/`.` injection) or hijacking the agent window as its shell.
    /// The phone's deterministic `phone-<clientId>` names (clientId is a lowercased UUID) satisfy this.
    static func isValidShellWindowName(_ window: String) -> Bool {
        guard window != "agent", !window.isEmpty else { return false }
        return window.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
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

    /// Best-effort: detach every client of the card's `agent` grouped view session so a new owner's
    /// PTY (re)sizes the window. No-op if the session/view doesn't exist. Belt-and-suspenders behind
    /// the D5 desktop unmount — never load-bearing for the ownership lease itself.
    public func detachAgentViewClients(_ base: String) throws {
        _ = try? tmux(["detach-client", "-s", SessionManager.viewSession(base, "agent")])
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

    /// All attachable windows as `TmuxTarget`s (agent + shells). THROWS when it can't obtain an
    /// authoritative listing — a dead/unreachable session or a `list-windows` failure. Callers that
    /// broadcast this (`emitShells`) rely on the distinction: a SUCCESSFUL listing with no `shell`
    /// windows (only the `agent` window) is a genuine "no shells" state worth broadcasting, whereas a
    /// FAILURE must NOT be flattened to an empty set — doing so would wholesale-wipe every client's
    /// shell panel on a transient tmux hiccup. (`try?` at a call site recovers the old `?? []` behaviour
    /// where a caller genuinely wants "empty on any failure".)
    public func windows(_ name: String) throws -> [TmuxTarget] {
        guard try isAlive(name) else { throw OrchestraError.io("session not alive: \(name)") }
        let r = try tmux(["list-windows", "-t", name, "-F", "#{window_index} #{window_name}"])
        guard r.ok else { throw OrchestraError.io(r.stderr.isEmpty ? "tmux list-windows failed" : r.stderr) }
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

    /// Send a constrained key chord to a window — an ordered mix of named special keys and literal
    /// text runs. Distinct from `sendKeys` (line-only) and the inbox `send`: named keys are delivered
    /// as tmux key tokens (`Escape`, `Up`, `C-c`, …) and text as raw bytes; there is NO implicit Enter,
    /// so submitting requires an explicit `.named(.enter)` token.
    public func sendChord(_ name: String, tokens: [KeyToken], window: String = "agent") throws {
        // Validate the window before it is interpolated into the tmux `-t "\(name):\(window)"` target —
        // an unvalidated `window` (e.g. `agent.1`, `other:sess`) would retarget a different pane/window.
        // The reserved `agent` window is a legitimate target here (unlike `ensureShellWindow`).
        guard window == "agent" || Self.isValidShellWindowName(window) else {
            throw OrchestraError.invalidParams("invalid window name: \(window)")
        }
        guard try isAlive(name) else { throw OrchestraError.io("session not alive: \(name)") }
        let target = "\(name):\(window)"
        for token in tokens {
            let r: ProcResult
            switch token {
            case .named(let key):
                r = try tmux(["send-keys", "-t", target, key.tmuxToken])
            case .text(let text):
                // `-l` = literal; `--` ends option parsing so text starting with `-` isn't swallowed.
                r = try tmux(["send-keys", "-t", target, "-l", "--", text])
            }
            // A failed send-keys must NOT report success: the Needs-You gate's "Approve" would otherwise
            // return ok while the agent stays blocked (the keystroke never reached the pane — e.g. the
            // window vanished between the liveness check and the send). Surface it so the caller can retry.
            guard r.ok else {
                throw OrchestraError.io(r.stderr.isEmpty ? "tmux send-keys failed for \(target)" : r.stderr)
            }
        }
    }

    /// Read-only snapshot of a window's pane via `capture-pane -p` — the non-attaching read the
    /// phone Agent tab uses. Captures the *visible* pane (no scrollback) so output is naturally
    /// bounded; `maxChars` is a hard safety cap on top. Never attaches, never resizes. Works for the
    /// `agent` window and any `shell-N` window. Throws if the target window/pane doesn't exist.
    public func capture(_ name: String, window: String = "agent",
                        maxChars: Int = 256 * 1024) throws -> CaptureResult {
        // Validate the window before it is interpolated into the tmux `-t "\(name):\(window)"` target —
        // an unvalidated `window` would let a caller read a different pane. `agent` is a valid target here.
        guard window == "agent" || Self.isValidShellWindowName(window) else {
            throw OrchestraError.invalidParams("invalid window name: \(window)")
        }
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

    /// Set `remain-on-exit` on a window so a process that exits leaves its dead pane (and its final
    /// output) in place instead of tmux destroying the window/session. Armed on the `agent` window during
    /// the spawn startup grace so an immediate abort's stderr survives for `capture`; cleared on graduation.
    public func setRemainOnExit(_ name: String, window: String = "agent", on: Bool) throws {
        guard window == "agent" || Self.isValidShellWindowName(window) else {
            throw OrchestraError.invalidParams("invalid window name: \(window)")
        }
        // Surface a genuine tmux failure (non-zero exit) so a caller that MUST know the option took —
        // graduation turning remain-on-exit back OFF — can stay pending and retry rather than silently
        // leaving a dead pane undetectable on a later crash.
        let r = try tmux(["set-option", "-w", "-t", "\(name):\(window)", "remain-on-exit", on ? "on" : "off"])
        if !r.ok { throw OrchestraError.io(r.stderr.isEmpty ? "tmux set-option remain-on-exit failed" : r.stderr) }
    }

    /// Liveness of the `agent` pane. `.gone` when the session is absent; otherwise `.dead` iff the pane's
    /// process has exited (`#{pane_dead}` == 1 — requires `remain-on-exit` to have kept it), else `.alive`.
    /// Lets the startup-abort reconcile tell an immediate launch abort from a healthy just-spawned agent.
    public func agentPaneState(_ name: String) throws -> PaneLiveness {
        guard try isAlive(name) else { return .gone }
        let r = try tmux(["list-panes", "-t", "\(name):agent", "-F", "#{pane_dead}"])
        guard r.ok else { return .gone }
        let dead = r.stdout.split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "1" }
        return dead ? .dead : .alive
    }

    /// All orchestra sessions whose `agent` pane's process has exited (`#{pane_dead}` == 1). ONE server-wide
    /// `list-panes -a` so the continuous reconcile can converge an orphaned dead pane cheaply (no per-card
    /// query). A dead agent pane only exists while `remain-on-exit` is ON — i.e. a startup-armed pane that
    /// was orphaned (e.g. `spawnPending` lost on a daemon restart mid-grace).
    public func agentPaneDeadSessions() throws -> Set<String> {
        let r = try tmux(["list-panes", "-a", "-F", "#{session_name}\t#{window_name}\t#{pane_dead}"])
        guard r.ok else { return [] }
        var out: Set<String> = []
        for line in r.stdout.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, f[0].hasPrefix("orchestra-"), f[1] == "agent",
                  f[2].trimmingCharacters(in: .whitespaces) == "1" else { continue }
            out.insert(f[0])
        }
        return out
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
