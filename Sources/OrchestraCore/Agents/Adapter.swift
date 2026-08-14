import Foundation

/// Context handed to an adapter when building launch argv.
public struct AdapterContext: Sendable {
    public let cwd: String          // the worktree
    public let repo: String?        // the source repo the worktree was cut from (for trust mirroring)
    public let model: String?
    public let startIn: StartIn?
    public let sessionId: String?   // seeded id for `start`; target id for `resume`
    public let prompt: String?      // initial prompt (launch positional arg); nil on restart/resume
    /// Card title -> `claude --name`. A `var` so a RETRIED launch (the startup-abort arm re-launches from
    /// a stored context) can refresh it from the live card — a `set-title` between the two must not come
    /// back up under the name the aborted launch happened to capture.
    public var name: String?
    public let orchestraBin: String // absolute path of the `orchestra` binary the agent's hooks call (agent-agnostic)
    public let orchestraMCPBin: String // absolute path of the bundled `orchestra-mcp` server
    public let access: CardAccess   // readWrite | readOnly — gates the read-only launch flags
    public let trustCwd: Bool       // Orchestra owns cwd (e.g. a scratch dir it made) → pre-trust it outright
    public let autoInstallMCPGlobally: Bool // opt-in add-only global MCP setup during launch preparation
    public let seed: String?        // authored system-level context (handoff / fork / additionalContext).
                                    // Frozen defaulted in A1; F1 (C3) reads ctx.seed. nil = no seed.
    public let since: Date?         // time-scope for discovered-session binding: bind only a rollout newer
                                    // than this durable launch cutoff, so an unbound fallback card never
                                    // adopts a sibling's or its own stale pre-reboot rollout.
    public init(cwd: String, repo: String? = nil, model: String? = nil, startIn: StartIn? = nil,
                sessionId: String? = nil, prompt: String? = nil, name: String? = nil,
                orchestraBin: String = siblingBinary("orchestra"), access: CardAccess = .readWrite,
                trustCwd: Bool = false, seed: String? = nil, since: Date? = nil,
                orchestraMCPBin: String = siblingBinary("orchestra-mcp"),
                autoInstallMCPGlobally: Bool = false) {
        self.cwd = cwd; self.repo = repo; self.model = model; self.startIn = startIn
        self.sessionId = sessionId; self.prompt = prompt; self.name = name; self.orchestraBin = orchestraBin
        self.orchestraMCPBin = orchestraMCPBin; self.access = access; self.trustCwd = trustCwd
        self.autoInstallMCPGlobally = autoInstallMCPGlobally; self.seed = seed; self.since = since
    }
}

/// How to launch and track one agent. Argv is always `[String]` (no interpolated shell string).
public protocol Adapter: Sendable {
    var id: String { get }
    var name: String { get }
    var icon: String { get }       // SF Symbol name
    var bin: String { get }
    var enabled: Bool { get }
    /// The frozen capability descriptor core degrades on. NO protocol default — every conformer MUST
    /// supply it (A1 seam-contract freeze), so a new adapter can't silently inherit Claude's shape.
    var capabilities: AgentCapabilities { get }
    func models() -> [AgentModel]
    func newSessionId() -> String?
    func start(_ ctx: AdapterContext) -> [String]
    func resume(_ ctx: AdapterContext) -> [String]?
    /// Convert one unit of raw transport telemetry into a normalized `StatusReport` (the D3 parse core).
    /// AGENT-DEPENDENT: each adapter owns its own mapping. The Orchestra transport (push endpoint /
    /// tailer / scrape, keyed by `capabilities.telemetry`) supplies only the raw bytes and merges the
    /// result via `OrchestraService.report`. DEFAULTED to `nil` (additive — no conformer breaks) so an
    /// adapter opts in per transport it actually receives.
    func parse(_ raw: RawTelemetry) -> StatusReport?
    /// Normalize provider observations into the replacement live-agent contract. During migration this
    /// is a dark path: adapters can map and compare these values, but only the legacy `parse` report may
    /// mutate a card until the single Core cutover. One raw event may eventually update more than one
    /// independent field, hence the array result.
    func agentSignals(from raw: RawTelemetry, context: AgentSignalContext) -> [AgentSignal]
    /// Encode core's agent-neutral `HookResponse` into THIS agent's hook stdout envelope (receive
    /// direction). AGENT-DEPENDENT format. DEFAULTED to `nil` (fail-safe, like `parse`) — so a divergent
    /// future agent that forgets can't silently emit another agent's shape (A1 "no silent inheritance").
    /// Claude/Codex implement it explicitly via `HookEnvelope`.
    func encode(_ response: HookResponse, for event: HookEvent) -> String?
    /// Normalize a raw SessionStart payload's `source` at the edge, so core never reads raw payload
    /// fields. DEFAULTED to reading `payload["source"]` (both current agents share it) → `.other`.
    func sessionSource(_ payload: JSONValue) -> SessionSource?
    func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo?
    /// Side-effecting prep run just before launch (default no-op). Claude uses it to pre-accept the
    /// worktree's directory-trust dialog so an autonomous agent never blocks on the "trust this
    /// folder?" prompt — every worktree is a fresh path the CLI would otherwise ask about each time.
    func prepareToLaunch(_ ctx: AdapterContext) throws
    /// The derived per-card file this adapter writes OUTSIDE the worktree (statusLine settings / launch
    /// profile), if any — so core can reap it generically (`sweepCardFiles`) without agent branching.
    /// DEFAULT nil (additive): an adapter that writes no such file opts out for free.
    var cardFile: CardFileSpec? { get }
    var env: [String: String] { get }
}

public extension Adapter {
    var env: [String: String] { [:] }
    var cardFile: CardFileSpec? { nil }
    func prepareToLaunch(_ ctx: AdapterContext) throws {}
    func parse(_ raw: RawTelemetry) -> StatusReport? { nil }
    func agentSignals(from raw: RawTelemetry, context: AgentSignalContext) -> [AgentSignal] { [] }
    func encode(_ response: HookResponse, for event: HookEvent) -> String? { nil }   // fail-safe: no output
    func sessionSource(_ payload: JSONValue) -> SessionSource? {
        payload["source"]?.stringValue.flatMap(SessionSource.init(rawValue:)) ?? .other
    }
    /// Resolve a launch id to a full `AgentModel`: the catalog entry if known, else a heuristic
    /// handle derived from the id. Keeps callers from ever fabricating a bad launch model.
    func model(for id: String) -> AgentModel {
        models().first { $0.id == id } ?? AgentModel(id: id)
    }

    /// Shared policy for token-based context reporters: prefer the adapter's model table when a model id
    /// is present, and fall back to an explicit telemetry window only when the model window is unknown.
    func tokenContextPercent(usedTokens: Int?, modelId: String?, reportedContextWindow: Int?) -> Double? {
        guard let usedTokens else { return nil }
        if let modelId, let pct = model(for: modelId).ctxPct(usedTokens: usedTokens) {
            return pct
        }
        guard let window = reportedContextWindow, window > 0 else { return nil }
        return min(100, max(0, Double(usedTokens) / Double(window) * 100))
    }
}

/// Look up / list adapters; list an agent's models.
public struct AgentRegistry: Sendable {
    private var adapters: [String: any Adapter]

    public init(adapters: [any Adapter] = [ClaudeCodeAdapter(), CodexAdapter()]) {
        var dict: [String: any Adapter] = [:]
        for a in adapters { dict[a.id] = a }
        self.adapters = dict
    }

    public func get(_ id: String) throws -> any Adapter {
        guard let a = adapters[id] else { throw OrchestraError.unknownAgent(id) }
        return a
    }

    public func list() -> [any Adapter] {
        adapters.values.filter(\.enabled).sorted { $0.id < $1.id }
    }

    /// The enabled adapter that catalogs `modelId`, if any. Routes a spawn that names a model but not an
    /// agent (the app's flat model picker sends only the model id) to the adapter that owns it. Catalog-
    /// driven — never sniffs the id string. First match wins (model ids don't overlap across adapters).
    public func adapter(forModel modelId: String) -> (any Adapter)? {
        list().first { a in a.models().contains { $0.id == modelId } }
    }
}
