import Foundation

/// Pure, platform-neutral builders for the tmux *attach* recipe a terminal client runs on the host
/// where the tmux server lives. No process spawning here (the desktop shells out via SwiftTerm's
/// `startProcess`; the iOS client runs it over an SSH exec channel) — only the command *shape*, so it
/// is unit-tested and shared verbatim by every client.
///
/// This is the single source of truth for the grouped "view session" pattern that used to live only in
/// the desktop `AgentTerminalView.attachScript()` (+ `SessionManager.viewSession`). The iOS terminal
/// host (PR T1) reuses it so the phone and the desktop attach *identically*, which is what makes
/// reconnect idempotent and keeps per-window sizes independent (phone-agent-terminal UX design,
/// Problem 2).
public enum TmuxAttach {
    /// The grouped "view" session name for a `(base, window)` pair — a throwaway session `<base>__<window>`
    /// created with `new-session -t <base>`. It shares the base session's window *list* but holds its own
    /// *current window*, so several clients (the agent terminal + each shell; desktop + a phone-owned
    /// window) don't yank one another onto the same window. Mirrors `OrchestraCore.SessionManager.viewSession`
    /// byte-for-byte (kept in sync by `TmuxAttachTests`); duplicated here because `OrchestraCore` is not
    /// linked on iOS (see `Package.swift` — the iOS graph is Kit + UI + SwiftTerm only).
    public static func viewSession(base: String, window: String) -> String { "\(base)__\(window)" }

    /// Single-quote a token for safe embedding in a `/bin/sh -c` command (POSIX: wrap in `'…'`, and
    /// escape any embedded quote as `'\''`).
    static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The attach script the *tmux host* runs — the exact grouped view-session recipe the desktop uses,
    /// so a phone client and the desktop behave the same and reconnect is idempotent:
    ///
    /// 1. `new-session -d -s <view> -t <base>` — create the grouped view session **only if absent**
    ///    (`2>/dev/null` swallows the "duplicate session" error), so a reconnect *reuses* the live view
    ///    session instead of spawning a fresh client. This is the reconnect-idempotency guarantee the
    ///    phone-terminal design requires (§"Reconnect churn").
    /// 2. `select-window -t <view>:<window>` — point this client's current window at the target window.
    /// 3. (takeover only) `detach-client -s <view>` — kick any prior client of this view session first,
    ///    so an exclusive owner (T4 takeover / a re-attaching phone) doesn't leave a second client
    ///    resize-fighting on the same window (design §"Attach mechanics").
    /// 4. `exec tmux attach -t <view>` — replace the shell with the attached client.
    ///
    /// - Parameter takeover: insert the `detach-client` step (exclusive attach). Defaults to `false`
    ///   (additive attach — matches the desktop's non-exclusive behaviour).
    public static func attachScript(socket: String, session: String, window: String,
                                    takeover: Bool = false) -> String {
        let view = viewSession(base: session, window: window)
        let sock = shQuote(socket), v = shQuote(view), base = shQuote(session)
        let win = shQuote("\(view):\(window)")
        var lines = [
            "tmux -L \(sock) new-session -d -s \(v) -t \(base) 2>/dev/null",
            "tmux -L \(sock) select-window -t \(win) 2>/dev/null",
        ]
        if takeover {
            lines.append("tmux -L \(sock) detach-client -s \(v) 2>/dev/null")
        }
        lines.append("exec tmux -L \(sock) attach -t \(v)")
        return lines.joined(separator: "\n")
    }

    /// Wrap an attach script with a login-shell prelude for an **SSH exec channel**. sshd runs an exec
    /// command via the user's shell but does NOT source their interactive profile, so a bare `tmux`
    /// won't resolve when tmux lives in Homebrew — the same gap the desktop closes with an augmented
    /// PATH (`AgentTerminalView.attach`). We also pin a UTF-8 locale so tmux's box-drawing/multibyte
    /// glyphs don't render as `_` (the desktop's `ensureUTF8Locale`). `TERM` is set by sshd from the
    /// `pty-req`, so it isn't repeated here.
    public static func sshExecCommand(script: String) -> String {
        "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; " +
        "export LANG=\"${LANG:-en_US.UTF-8}\"; " +
        script
    }
}
