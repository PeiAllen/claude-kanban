import Foundation

/// The capability descriptor every adapter advertises. Core degrades on these flags — never on adapter
/// identity (no `if agentId == "claude"`). This is the seam-contract root (A1): the COMPLETE set of
/// fields and every variant spelling is declared here, so later PRs implement behavior behind variants
/// declared now but not yet exercised (e.g. `readOnlyEnforcement.orchestraSandboxed`,
/// `telemetry.ptyScrape`, `contextUsage.none`). Additions are
/// defaulted; spellings are stable BUT not immortal — a variant that was exercised and then retired is
/// removed, not kept as dead vocabulary (capabilities are computed from the adapter, never persisted, so a
/// removal breaks nothing).
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

    /// How a card being BORN — `launching` (blank spawn/reopen) OR `relaunching` (resume/restart) — is
    /// confirmed alive (D1: one axis covers both being-born phases). `sessionStartHook` = wait for the
    /// agent's own SessionStart telemetry to reach `report()` (Claude `hooksPush`: `startup` confirms a
    /// launch, `resume` confirms a relaunch — precise + fast). `rolloutMeta` = wait for the agent's rollout
    /// `session_meta` line, tailed post-launch (Codex `.discovered`): a fresh launch writes one so the tail
    /// observer resolves readiness on it; a `codex resume` writes NO rollout, so the universal N=3
    /// liveness-tick fallback (`launchReadyTicks`) resolves the still-pending waiter within the grace —
    /// keeping the relaunch ON the readiness gate rather than off it. `relaunchLiveness` = the successful
    /// relaunch (tmux `ensure`) IS the confirmation because the agent emits no marker at all; waiting for a
    /// signal that never comes would time out at the grace and fail-DANGEROUSLY `markDead` a live card. The
    /// continuous liveness reconcile (folded into the 2s `reconcile()` tick) is the safety net for every variant.
    public enum ReadinessConfirmation: String, Sendable, Equatable, Codable, CaseIterable {
        case sessionStartHook, rolloutMeta, relaunchLiveness
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
    public let readOnlyEnforcement: ReadOnlyEnforcement
    public let authMode: AuthMode
    public let terminalImagePaste: TerminalImagePaste
    public let readinessConfirmation: ReadinessConfirmation

    public init(sessionId: SessionId, telemetry: Telemetry, contextUsage: ContextUsage,
                readOnlyEnforcement: ReadOnlyEnforcement, authMode: AuthMode,
                terminalImagePaste: TerminalImagePaste = .direct,
                readinessConfirmation: ReadinessConfirmation = .sessionStartHook) {
        self.sessionId = sessionId
        self.telemetry = telemetry
        self.contextUsage = contextUsage
        self.readOnlyEnforcement = readOnlyEnforcement
        self.authMode = authMode
        self.terminalImagePaste = terminalImagePaste
        self.readinessConfirmation = readinessConfirmation
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, telemetry, contextUsage, readOnlyEnforcement, authMode
        case terminalImagePaste, readinessConfirmation
    }

    /// Capability payloads cross the daemon/client boundary. Decode additive fields with their historical
    /// defaults so a newly installed client can still talk to an older daemon.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(SessionId.self, forKey: .sessionId)
        telemetry = try c.decode(Telemetry.self, forKey: .telemetry)
        contextUsage = try c.decode(ContextUsage.self, forKey: .contextUsage)
        readOnlyEnforcement = try c.decode(ReadOnlyEnforcement.self, forKey: .readOnlyEnforcement)
        authMode = try c.decode(AuthMode.self, forKey: .authMode)
        terminalImagePaste = try c.decodeIfPresent(TerminalImagePaste.self, forKey: .terminalImagePaste)
            ?? .direct
        readinessConfirmation = try c.decodeIfPresent(ReadinessConfirmation.self, forKey: .readinessConfirmation)
            ?? .sessionStartHook
    }
}
