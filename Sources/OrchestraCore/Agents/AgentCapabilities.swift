import Foundation

/// The capability descriptor every adapter advertises. Core degrades on these flags — never on adapter
/// identity (no `if agentId == "claude"`). This is the seam-contract root (A1): the COMPLETE set of
/// fields and every variant spelling is declared here, so later PRs implement behavior behind variants
/// declared now but not yet exercised (e.g. `wakeTransport.controlChannel`,
/// `readOnlyEnforcement.orchestraSandboxed`, `telemetry.ptyScrape`, `contextUsage.none`). Additions are
/// defaulted; spellings are stable BUT not immortal — a variant that was exercised and then retired is
/// removed, not kept as dead vocabulary (capabilities are computed from the adapter, never persisted, so a
/// removal breaks nothing). `wakeTransport.sendKeys` + `inboxDrain.sessionSeed` were retired when Codex
/// moved to resume-seed wake + the Stop-hook drain.
public struct AgentCapabilities: Sendable, Equatable, Codable {

    /// How the agent's session id is obtained. `seeded` = Orchestra mints it pre-launch (Claude
    /// `--session-id`); `discovered` = read back from the agent's own output post-launch (Codex rollout).
    public enum SessionId: String, Sendable, Equatable, Codable, CaseIterable {
        case seeded, discovered
    }

    /// How raw telemetry reaches the daemon transport. `hooksPush` = the agent pushes to the `_report`
    /// endpoint; `fileTail` = the daemon tails a rollout/transcript file; `ptyScrape` = the daemon reads
    /// the pane buffer (`capture-pane`).
    public enum Telemetry: String, Sendable, Equatable, Codable, CaseIterable {
        case hooksPush, fileTail, ptyScrape
    }

    /// How context-window usage is expressed. `percent` = the agent reports a %; `tokens` = raw tokens ÷
    /// the model's context window (offline table); `none` = no usage signal.
    public enum ContextUsage: String, Sendable, Equatable, Codable, CaseIterable {
        case percent, tokens, none
    }

    /// How an idle agent is woken to start a turn (F2). `nativeReinvoke` = the harness re-invokes it in
    /// session (Claude); `relaunch` = kill + resume-seed (Codex, and the universal fallback);
    /// `controlChannel` = an app-server / RPC `turn/start` (future — wakes without tearing the session down).
    public enum WakeTransport: String, Sendable, Equatable, Codable, CaseIterable {
        case nativeReinvoke, relaunch, controlChannel
    }

    /// How the durable inbox is drained into the agent (F3). `stopHook` = a Stop hook injects at
    /// turn-end (both shipped agents); `none` = no live drain. (Delivery to an *idle* card is F2 wake —
    /// a resume-seed folds the inbox into the opening turn — not an `inboxDrain` mode.)
    public enum InboxDrain: String, Sendable, Equatable, Codable, CaseIterable {
        case stopHook, none
    }

    /// The strength of the read-only guarantee. `sandboxed` = an OS sandbox is the boundary (true RO);
    /// `toolGatedOnly` = tool-gating only, no OS sandbox (weak — core surfaces a badge); `orchestraSandboxed`
    /// = Orchestra wraps the process in its own sandbox (future).
    public enum ReadOnlyEnforcement: String, Sendable, Equatable, Codable, CaseIterable {
        case sandboxed, toolGatedOnly, orchestraSandboxed
    }

    /// The auth posture. `subscription` = the agent's own OAuth/subscription; `apiKey` = a provider API key.
    public enum AuthMode: String, Sendable, Equatable, Codable, CaseIterable {
        case subscription, apiKey
    }

    /// How Orchestra should handle host Cmd-V image paste for a terminal-hosted agent. `direct` delegates
    /// to the terminal/agent's normal paste path. `controlV` means the TUI has a native Ctrl-V image paste
    /// action that reads the clipboard itself, so Orchestra may send that pty byte for Cmd-V image paste
    /// without materializing files or inventing prompt text.
    public enum TerminalImagePaste: String, Sendable, Equatable, Codable, CaseIterable {
        case direct, controlV

        public var canPasteImages: Bool {
            switch self {
            case .direct: true
            case .controlV: true
            }
        }
    }

    public let sessionId: SessionId
    public let telemetry: Telemetry
    public let contextUsage: ContextUsage
    public let wakeTransport: WakeTransport
    public let inboxDrain: InboxDrain
    public let readOnlyEnforcement: ReadOnlyEnforcement
    public let authMode: AuthMode
    public let terminalImagePaste: TerminalImagePaste

    public init(sessionId: SessionId, telemetry: Telemetry, contextUsage: ContextUsage,
                wakeTransport: WakeTransport, inboxDrain: InboxDrain,
                readOnlyEnforcement: ReadOnlyEnforcement, authMode: AuthMode,
                terminalImagePaste: TerminalImagePaste = .direct) {
        self.sessionId = sessionId
        self.telemetry = telemetry
        self.contextUsage = contextUsage
        self.wakeTransport = wakeTransport
        self.inboxDrain = inboxDrain
        self.readOnlyEnforcement = readOnlyEnforcement
        self.authMode = authMode
        self.terminalImagePaste = terminalImagePaste
    }
}
