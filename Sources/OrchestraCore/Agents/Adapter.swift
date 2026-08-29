import Foundation

/// Ephemeral provider connection details for sending a message into one live harness session.
/// Core carries this value without interpreting it; the owning adapter builds the provider sender.
/// Deliberately not `Codable`: credentials may cross the hook RPC, but must never enter durable state.
public enum AgentMessageEndpoint: Sendable, Equatable {
    case claudeHookRPC(socketPath: String, token: String)
}

/// One hook-reported endpoint plus the provider session identity it belongs to. Also deliberately
/// non-Codable: `HookRPC` manually encodes the short-lived wire value and Core retains it only in
/// `CardRuntime`.
public struct AgentMessageEndpointReport: Sendable, Equatable {
    public let providerId: String
    public let harnessSessionId: String
    public let endpoint: AgentMessageEndpoint

    public init(providerId: String, harnessSessionId: String, endpoint: AgentMessageEndpoint) {
        self.providerId = providerId
        self.harnessSessionId = harnessSessionId
        self.endpoint = endpoint
    }
}

/// A provider-native path into one live harness session. Implementations own their connection and must
/// make `shutdown` synchronously prevent any later send from using superseded session credentials.
public protocol AgentMessageSender: AnyObject, Sendable {
    func send(_ message: String) async throws
    func shutdown()
}

/// Provider observation endpoint prepared for one card launch. The enum keeps the adapter/core seam
/// provider-neutral even though the first source (Codex app-server) uses a Unix domain socket.
public enum AgentObservationEndpoint: Sendable, Equatable {
    case unixSocket(path: String)
    /// Provider observations pushed into Orchestra. Hooks use the existing control socket; the optional
    /// URL is the daemon's local OTLP trace receiver for providers with a missing terminal hook.
    case pushed(otlpHTTPURL: String?)

    public var unixSocketPath: String? {
        guard case .unixSocket(let path) = self else { return nil }
        return path
    }

    public var otlpHTTPURL: String? {
        guard case .pushed(let url) = self else { return nil }
        return url
    }

    var isPushOnly: Bool {
        if case .pushed = self { return true }
        return false
    }
}

/// Card/session identity and daemon observation infrastructure offered to an adapter. Core allocates the
/// infrastructure; the adapter decides whether and how its provider consumes it.
public struct AgentObservationSetup: Sendable, Equatable {
    public let cardId: UUID
    public let cardRef: String
    public let sessionEpoch: Int
    public let runtimeStateDir: String
    public let traceHTTPBaseURL: String?

    public init(cardId: UUID, cardRef: String, sessionEpoch: Int, runtimeStateDir: String,
                traceHTTPBaseURL: String? = nil) {
        self.cardId = cardId
        self.cardRef = cardRef
        self.sessionEpoch = sessionEpoch
        self.runtimeStateDir = runtimeStateDir
        self.traceHTTPBaseURL = traceHTTPBaseURL
    }
}

/// One blocking connection to a provider's structured event stream. Core owns its lifetime and treats it
/// as a passive source: provider RPC choreography and decoding stay behind the adapter boundary, while
/// cancellation must synchronously unblock `run` so a superseded card session cannot leak a reader.
public protocol AgentObservationSource: AnyObject, Sendable {
    func run(onObservation: @escaping @Sendable (RawTelemetry) -> Void) throws
    func shutdown()
}

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
    public let observationEndpoint: AgentObservationEndpoint?
    public init(cwd: String, repo: String? = nil, model: String? = nil, startIn: StartIn? = nil,
                sessionId: String? = nil, prompt: String? = nil, name: String? = nil,
                orchestraBin: String = siblingBinary("orchestra"), access: CardAccess = .readWrite,
                trustCwd: Bool = false, seed: String? = nil, since: Date? = nil,
                orchestraMCPBin: String = siblingBinary("orchestra-mcp"),
                autoInstallMCPGlobally: Bool = false,
                observationEndpoint: AgentObservationEndpoint? = nil) {
        self.cwd = cwd; self.repo = repo; self.model = model; self.startIn = startIn
        self.sessionId = sessionId; self.prompt = prompt; self.name = name; self.orchestraBin = orchestraBin
        self.orchestraMCPBin = orchestraMCPBin; self.access = access; self.trustCwd = trustCwd
        self.autoInstallMCPGlobally = autoInstallMCPGlobally; self.seed = seed; self.since = since
        self.observationEndpoint = observationEndpoint
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
    /// Normalize provider observations into the live-agent contract. One raw event may update more than
    /// one independent field, hence the array result. This is the sole status-authority path; `parse`
    /// remains responsible only for lifecycle and presentation metadata.
    func agentSignals(from raw: RawTelemetry, context: AgentSignalContext) -> [AgentSignal]
    /// Select the compact, provider-owned portion of a hook payload needed by `agentSignals`. The edge
    /// helper sends this alongside the metadata report so Core can apply the current Card/session fences
    /// before normalization. Returning nil means this hook carries no agent-state observation.
    func hookObservationPayload(event: HookEvent, payload: JSONValue) -> JSONValue?
    /// Extract a provider-native message endpoint from one hook invocation. The edge passes the raw hook
    /// environment without interpreting provider keys; adapters that do not expose an endpoint return nil.
    func hookMessageEndpoint(
        event: HookEvent,
        payload: JSONValue,
        environment: [String: String]
    ) -> AgentMessageEndpointReport?
    /// The launch-local endpoint this adapter needs for structured observation, if any. Core only
    /// allocates and carries the endpoint; provider-specific launch and connection details stay here.
    func observationEndpoint(_ setup: AgentObservationSetup) -> AgentObservationEndpoint?
    /// Build one fresh connection attempt for an endpoint + provider session. Core may call this again
    /// after a disconnect; returning nil means this adapter has no structured source for that endpoint.
    func makeObservationSource(
        endpoint: AgentObservationEndpoint,
        harnessSessionId: String
    ) -> (any AgentObservationSource)?
    /// Build a sender for one ephemeral provider endpoint. Core owns the returned sender through the
    /// exact card/provider/session identity in `CardRuntime` and shuts it down on replacement/teardown.
    func makeMessageSender(for endpoint: AgentMessageEndpoint) -> (any AgentMessageSender)?
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
    /// Context-dependent launch environment. The default preserves the original static `env` seam; an
    /// adapter uses this only when its prepared observation endpoint must be handed to the provider.
    func launchEnvironment(_ context: AdapterContext) -> [String: String]
}

public extension Adapter {
    var env: [String: String] { [:] }
    var cardFile: CardFileSpec? { nil }
    func prepareToLaunch(_ ctx: AdapterContext) throws {}
    func parse(_ raw: RawTelemetry) -> StatusReport? { nil }
    func agentSignals(from raw: RawTelemetry, context: AgentSignalContext) -> [AgentSignal] { [] }
    func hookObservationPayload(event: HookEvent, payload: JSONValue) -> JSONValue? { nil }
    func hookMessageEndpoint(
        event: HookEvent,
        payload: JSONValue,
        environment: [String: String]
    ) -> AgentMessageEndpointReport? { nil }
    func observationEndpoint(_ setup: AgentObservationSetup) -> AgentObservationEndpoint? { nil }
    func makeObservationSource(
        endpoint: AgentObservationEndpoint,
        harnessSessionId: String
    ) -> (any AgentObservationSource)? { nil }
    func makeMessageSender(for endpoint: AgentMessageEndpoint) -> (any AgentMessageSender)? { nil }
    func encode(_ response: HookResponse, for event: HookEvent) -> String? { nil }   // fail-safe: no output
    func launchEnvironment(_ context: AdapterContext) -> [String: String] { env }
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

/// Keep hook control messages bounded: tool hook payloads can contain entire file bodies, while the
/// status mapper normally needs only session identity and a few small discriminator fields.
func projectedHookPayload(_ payload: JSONValue, keys: [String]) -> JSONValue {
    .object(Dictionary(uniqueKeysWithValues: keys.compactMap { key in
        payload[key].map { (key, $0) }
    }))
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
