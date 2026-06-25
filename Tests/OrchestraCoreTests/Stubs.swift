import Foundation
@testable import OrchestraCore

/// In-memory worktree stub — never touches git.
final class StubWorktrees: WorktreeManaging, @unchecked Sendable {
    let root: String
    private let lock = NSLock()
    private(set) var removed: [String] = []
    init(root: String) { self.root = root }

    func path(repo: String, branch: String) -> String {
        "\(root)/\((repo as NSString).lastPathComponent)/\(branch)"
    }
    func ensure(repo: String, branch: String) throws -> (worktree: String, created: Bool) {
        let wt = path(repo: repo, branch: branch)
        try? FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        return (wt, true)
    }
    func remove(worktree: String, force: Bool) throws {
        lock.lock(); removed.append(worktree); lock.unlock()
    }
}

/// In-memory tmux stub — tracks alive sessions and records launch argv; thread-safe (offActor runs
/// ensure on a background queue). `ensureSleepMs` lets the throttle test create overlap.
final class StubSessions: SessionManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var alive: Set<String> = []
    private(set) var ensureArgv: [String: [String]] = [:]
    private(set) var killed: [String] = []
    private(set) var ensureCount = 0
    private(set) var peakConcurrentEnsure = 0
    private var curConcurrentEnsure = 0
    var ensureSleepMs: UInt32 = 0

    /// Seed a session as alive without an ensure (for "still running" cards in recover tests).
    func setAlive(_ id: UUID, _ value: Bool) {
        lock.lock(); if value { alive.insert(sessionName(id)) } else { alive.remove(sessionName(id)) }; lock.unlock()
    }

    func sessionName(_ id: UUID) -> String { "orchestra-\(id.uuidString.lowercased())" }

    func ensure(_ task: Task, argv: [String]) throws -> (name: String, created: Bool) {
        let name = sessionName(task.id)
        lock.lock(); curConcurrentEnsure += 1; peakConcurrentEnsure = max(peakConcurrentEnsure, curConcurrentEnsure); ensureCount += 1; lock.unlock()
        if ensureSleepMs > 0 { usleep(ensureSleepMs * 1000) }
        lock.lock(); curConcurrentEnsure -= 1; alive.insert(name); ensureArgv[name] = argv; lock.unlock()
        return (name, true)
    }
    func isAlive(_ name: String) throws -> Bool { lock.lock(); defer { lock.unlock() }; return alive.contains(name) }
    func newShellWindow(_ name: String, cwd: String) throws -> String { "shell-1" }
    func windows(_ name: String) throws -> [TmuxTarget] {
        guard try isAlive(name) else { return [] }
        return [TmuxTarget(socket: "orchestra", session: name, window: "agent", kind: .agent,
                           target: "\(name):agent", attach: "tmux -L orchestra attach -t \(name):agent")]
    }
    func list() throws -> [SessionInfo] { lock.lock(); defer { lock.unlock() }; return alive.map { SessionInfo(name: $0, running: true) } }
    func capture(_ name: String, window: String) throws -> String { "" }
    func sendKeys(_ name: String, text: String, window: String) throws {}
    func kill(_ name: String) throws { lock.lock(); alive.remove(name); killed.append(name); lock.unlock() }
}

/// An adapter whose transcript path is under a test-controlled dir, so resumable/transcript-exists is
/// fully controllable. Registered with id "claude-code" so `spawn` finds it.
final class StubAdapter: Adapter, @unchecked Sendable {
    let id = "claude-code"
    let name = "Stub"
    let icon = "sparkle"
    let bin = "fake-agent"
    let enabled = true
    let transcriptDir: String
    init(transcriptDir: String) { self.transcriptDir = transcriptDir }

    func models() -> [AgentModel] { [AgentModel(id: "m1"), AgentModel(id: "m2")] }
    func newSessionId() -> String? { UUID().uuidString.lowercased() }
    func start(_ ctx: AdapterContext) -> [String] {
        var a = [bin]
        if let s = ctx.sessionId { a += ["--session-id", s] }
        if let n = ctx.name { a += ["--name", n] }
        if let p = ctx.prompt { a.append(p) }
        return a
    }
    func resume(_ ctx: AdapterContext) -> [String]? {
        guard let s = ctx.sessionId else { return nil }
        return [bin, "--resume", s, "--name", ctx.name ?? ""]
    }
    func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo? {
        let sid = current
        return AgentSessionInfo(agentId: id, sessionId: sid,
                                transcriptPath: sid.map { "\(transcriptDir)/\($0).jsonl" },
                                priorSessionIds: prior, priorTranscripts: [],
                                resumeCmd: sid.map { [bin, "--resume", $0] })
    }
    func writeTranscript(for sessionId: String) {
        try? FileManager.default.createDirectory(atPath: transcriptDir, withIntermediateDirectories: true)
        try? "{}".write(toFile: "\(transcriptDir)/\(sessionId).jsonl", atomically: true, encoding: .utf8)
    }
    func deleteTranscript(for sessionId: String) {
        try? FileManager.default.removeItem(atPath: "\(transcriptDir)/\(sessionId).jsonl")
    }
}

/// Collect events from a service subscription for assertions.
actor EventCollector {
    private(set) var events: [Event] = []
    func start(_ stream: AsyncStream<Event>) {
        _Concurrency.Task { for await e in stream { self.append(e) } }
    }
    private func append(_ e: Event) { events.append(e) }
    var activities: [ActivityItem] {
        events.compactMap { if case .activity(let a) = $0 { return a } else { return nil } }
    }
    var upserts: [Task] {
        events.compactMap { if case .taskUpserted(let t) = $0 { return t } else { return nil } }
    }
}

enum TestEnv {
    /// A service wired with stubs + a controllable adapter, all under a temp dir allowlist.
    static func make(maxRevivals: Int = 4, grace: Int = 1)
        -> (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, base: String) {
        let base = NSTemporaryDirectory() + "orch-svc-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: base + "/repos", withIntermediateDirectories: true)
        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)],
                            maxConcurrentRevivals: maxRevivals, revivalGraceSeconds: grace)
        let sessions = StubSessions()
        let worktrees = StubWorktrees(root: config.worktreesRoot)
        let adapter = StubAdapter(transcriptDir: base + "/transcripts")
        let store = TaskStore(path: base + "/tasks.json")
        let svc = OrchestraService(config: config, store: store,
                                   registry: AgentRegistry(adapters: [adapter]),
                                   worktrees: worktrees, sessions: sessions)
        return (svc, sessions, worktrees, adapter, PathResolver.canonical(base))
    }

    /// Make a repo dir under reposRoot and return its path.
    static func repo(_ base: String, _ name: String = "app") -> String {
        let p = base + "/repos/" + name
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
}
