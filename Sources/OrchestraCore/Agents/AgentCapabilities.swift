import Foundation

/// The capability descriptor every adapter advertises. Core degrades on these flags — never on adapter
/// identity (no `if agentId == "claude"`). This is the seam-contract root (A1): the COMPLETE set of
/// fields and every variant spelling is frozen here, so later PRs implement behavior behind variants
/// declared now but not yet exercised (e.g. `wakeTransport.controlChannel`, `inboxDrain.sessionSeed`,
/// `readOnlyEnforcement.orchestraSandboxed`, `telemetry.ptyScrape`, `contextUsage.none`). Additions to
/// the seam are defaulted; the one true drift vector is these enum spellings — hence the freeze.
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
    /// session (Claude); `controlChannel` = an app-server / RPC `turn/start` (future); `sendKeys` = a TUI
    /// keystroke nudge (Codex); `relaunch` = kill + resume (the F1 universal fallback).
    public enum WakeTransport: String, Sendable, Equatable, Codable, CaseIterable {
        case nativeReinvoke, controlChannel, sendKeys, relaunch
    }

    /// How the durable inbox is drained into the agent (F3). `stopHook` = a Stop hook injects at
    /// turn-end; `sessionSeed` = folded into the resume seed; `none` = no live drain.
    public enum InboxDrain: String, Sendable, Equatable, Codable, CaseIterable {
        case stopHook, sessionSeed, none
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

    public let sessionId: SessionId
    public let telemetry: Telemetry
    public let contextUsage: ContextUsage
    public let wakeTransport: WakeTransport
    public let inboxDrain: InboxDrain
    public let readOnlyEnforcement: ReadOnlyEnforcement
    public let authMode: AuthMode

    public init(sessionId: SessionId, telemetry: Telemetry, contextUsage: ContextUsage,
                wakeTransport: WakeTransport, inboxDrain: InboxDrain,
                readOnlyEnforcement: ReadOnlyEnforcement, authMode: AuthMode) {
        self.sessionId = sessionId
        self.telemetry = telemetry
        self.contextUsage = contextUsage
        self.wakeTransport = wakeTransport
        self.inboxDrain = inboxDrain
        self.readOnlyEnforcement = readOnlyEnforcement
        self.authMode = authMode
    }
}

public extension AgentCapabilities {
    /// The Claude Code adapter's shipped capabilities — the behavior A1 must preserve. Also the default
    /// for the test `StubAdapter`, so existing suites see Claude-shaped behavior unless they opt out.
    static let claudeCode = AgentCapabilities(
        sessionId: .seeded,
        telemetry: .hooksPush,
        contextUsage: .percent,
        wakeTransport: .nativeReinvoke,
        inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed,
        authMode: .subscription)
}
