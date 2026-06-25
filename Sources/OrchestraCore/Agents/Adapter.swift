import Foundation

/// Context handed to an adapter when building launch argv.
public struct AdapterContext: Sendable {
    public let cwd: String          // the worktree
    public let model: String?
    public let startIn: StartIn?
    public let sessionId: String?   // seeded id for `start`; target id for `resume`
    public let prompt: String?      // initial prompt (launch positional arg); nil on restart/resume
    public let name: String?        // card title -> `claude --name`
    public let hooksPath: String    // managed --settings file
    public init(cwd: String, model: String? = nil, startIn: StartIn? = nil, sessionId: String? = nil,
                prompt: String? = nil, name: String? = nil, hooksPath: String = Config.hooksPath) {
        self.cwd = cwd; self.model = model; self.startIn = startIn; self.sessionId = sessionId
        self.prompt = prompt; self.name = name; self.hooksPath = hooksPath
    }
}

/// How to launch and track one agent. Argv is always `[String]` (no interpolated shell string).
public protocol Adapter: Sendable {
    var id: String { get }
    var name: String { get }
    var icon: String { get }       // SF Symbol name
    var bin: String { get }
    var enabled: Bool { get }
    func models() -> [AgentModel]
    func newSessionId() -> String?
    func start(_ ctx: AdapterContext) -> [String]
    func resume(_ ctx: AdapterContext) -> [String]?
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

    /// Resolve a launch id to a full `AgentModel`: the catalog entry if known, else a heuristic
    /// handle derived from the id. Keeps callers from ever fabricating a bad launch model.
    func model(for id: String) -> AgentModel {
        models().first { $0.id == id } ?? AgentModel(id: id)
    }
}

/// Look up / list adapters; list an agent's models.
public struct AgentRegistry: Sendable {
    private var adapters: [String: any Adapter]

    public init(adapters: [any Adapter] = [ClaudeCodeAdapter()]) {
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
}
