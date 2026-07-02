import Foundation

/// Context handed to an adapter when building launch argv.
public struct AdapterContext: Sendable {
    public let cwd: String          // the worktree
    public let repo: String?        // the source repo the worktree was cut from (for trust mirroring)
    public let model: String?
    public let startIn: StartIn?
    public let sessionId: String?   // seeded id for `start`; target id for `resume`
    public let prompt: String?      // initial prompt (launch positional arg); nil on restart/resume
    public let name: String?        // card title -> `claude --name`
    public let hooksPath: String    // managed --settings file
    public let access: CardAccess   // readWrite | readOnly — gates the read-only launch flags
    public let trustCwd: Bool       // Orchestra owns cwd (e.g. a scratch dir it made) → pre-trust it outright
    public let seed: String?        // authored system-level context (handoff / fork / additionalContext).
                                    // Frozen defaulted in A1; F1 (C3) reads ctx.seed. nil = no seed.
    public init(cwd: String, repo: String? = nil, model: String? = nil, startIn: StartIn? = nil,
                sessionId: String? = nil, prompt: String? = nil, name: String? = nil,
                hooksPath: String = Config.hooksPath, access: CardAccess = .readWrite,
                trustCwd: Bool = false, seed: String? = nil) {
        self.cwd = cwd; self.repo = repo; self.model = model; self.startIn = startIn
        self.sessionId = sessionId; self.prompt = prompt; self.name = name; self.hooksPath = hooksPath
        self.access = access; self.trustCwd = trustCwd; self.seed = seed
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
    /// send-keys wake gate (F2): given the just-captured agent pane, is it safe to fire the fixed nudge?
    /// AGENT-DEPENDENT and keyed to `wakeTransport == .sendKeys` — the adapter reads its OWN TUI rendering
    /// (idle + empty composer), so core never has to know one agent's screen from another's. DEFAULTED to
    /// `false` (additive; a non-send-keys agent wakes another way and never calls this).
    func canNudge(pane: String) -> Bool
    func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo?
    /// Side-effecting prep run just before launch (default no-op). Claude uses it to pre-accept the
    /// worktree's directory-trust dialog so an autonomous agent never blocks on the "trust this
    /// folder?" prompt — every worktree is a fresh path the CLI would otherwise ask about each time.
    func prepareToLaunch(_ ctx: AdapterContext) throws
    var env: [String: String] { get }
}

public extension Adapter {
    var env: [String: String] { [:] }
    func prepareToLaunch(_ ctx: AdapterContext) throws {}
    func parse(_ raw: RawTelemetry) -> StatusReport? { nil }
    func canNudge(pane: String) -> Bool { false }   // only send-keys agents read their pane; others never nudge

    /// Resolve a launch id to a full `AgentModel`: the catalog entry if known, else a heuristic
    /// handle derived from the id. Keeps callers from ever fabricating a bad launch model.
    func model(for id: String) -> AgentModel {
        models().first { $0.id == id } ?? AgentModel(id: id)
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
