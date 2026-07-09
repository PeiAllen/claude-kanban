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
    /// continuous liveness reconcile (`reconcileLiveness`, 2s) is the safety net for every variant.
    public enum ReadinessConfirmation: String, Sendable, Equatable, Codable, CaseIterable {
        case sessionStartHook, rolloutMeta, relaunchLiveness
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
    public let readinessConfirmation: ReadinessConfirmation

    /// The key chord the Needs-You gate sends to APPROVE a `waitReason == .permission` prompt, and the
    /// chord that DENIES it. These are agent-terminal-layout facts, not provider-neutral truths: Claude's
    /// TUI accepts the pre-highlighted "Yes" with `Enter` and cancels with `Esc`. They live on the
    /// capability (not on the neutral Needs-You queue) so each adapter states its own gate keys — a
    /// structured-approval agent (Codex's `PermissionRequest`) overrides these per-adapter instead of
    /// inheriting Claude's keystrokes. An empty chord means "this agent has no send-keys gate" and the
    /// gate is a no-op (its approval rides a different channel).
    public let approveChord: [KeyToken]
    public let denyChord: [KeyToken]

    public init(sessionId: SessionId, telemetry: Telemetry, contextUsage: ContextUsage,
                wakeTransport: WakeTransport, inboxDrain: InboxDrain,
                readOnlyEnforcement: ReadOnlyEnforcement, authMode: AuthMode,
                terminalImagePaste: TerminalImagePaste = .direct,
                readinessConfirmation: ReadinessConfirmation = .sessionStartHook,
                approveChord: [KeyToken] = [.named(.enter)],
                denyChord: [KeyToken] = [.named(.esc)]) {
        self.sessionId = sessionId
        self.telemetry = telemetry
        self.contextUsage = contextUsage
        self.wakeTransport = wakeTransport
        self.inboxDrain = inboxDrain
        self.readOnlyEnforcement = readOnlyEnforcement
        self.authMode = authMode
        self.terminalImagePaste = terminalImagePaste
        self.readinessConfirmation = readinessConfirmation
        self.approveChord = approveChord
        self.denyChord = denyChord
    }
}

public extension AgentCapabilities {
    /// The Claude Code adapter's shipped capabilities. Also the default for the test `StubAdapter` and
    /// the shared `BoardModel`'s capability fallback, so existing suites and the client see Claude-shaped
    /// behavior unless they opt out. Lives in OrchestraKit (moved from the Core adapter in F2) so the
    /// shared, client-side `BoardModel` can use it on iOS.
    static let claudeCode = AgentCapabilities(
        sessionId: .seeded,
        telemetry: .hooksPush,
        contextUsage: .percent,
        wakeTransport: .nativeReinvoke,
        inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed,
        authMode: .subscription,
        terminalImagePaste: .controlV,
        // Claude fires SessionStart(startup) on a fresh launch and SessionStart(resume) on a relaunch, both
        // via hooksPush — one hook capability confirms BOTH being-born phases.
        readinessConfirmation: .sessionStartHook)
}
