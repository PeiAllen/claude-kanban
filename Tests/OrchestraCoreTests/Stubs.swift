import Foundation
@testable import OrchestraCore

/// In-memory worktree stub — never touches git.
final class StubWorktrees: WorktreeManaging, @unchecked Sendable {
    let root: String
    private let lock = NSLock()
    private(set) var removed: [String] = []
    private(set) var ensured: [String] = []   // repo+branch pairs ensure() was called for
    init(root: String) { self.root = root }

    func path(repo: String, branch: String) -> String {
        "\(root)/\((repo as NSString).lastPathComponent)/\(branch)"
    }
    func ensure(repo: String, branch: String) throws -> (worktree: String, created: Bool) {
        lock.lock(); ensured.append("\(repo)#\(branch)"); lock.unlock()
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
    private(set) var ensureEnv: [String: [String: String]] = [:]
    private(set) var killed: [String] = []
    private(set) var ensureCount = 0
    private(set) var peakConcurrentEnsure = 0
    private var curConcurrentEnsure = 0
    var ensureSleepMs: UInt32 = 0
    private var captureText: [String: String] = [:]
    private(set) var sentKeys: [(name: String, text: String)] = []

    /// Seed the pane text `capture(_:window:)` returns for this card (drives C4 detect-and-defer).
    func setCapture(_ id: UUID, _ text: String) {
        lock.lock(); captureText[sessionName(id)] = text; lock.unlock()
    }

    /// Nudges/keystrokes sent to a card's agent window, in order (drives C4 nudge-only assertions).
    func keysSent(to id: UUID) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let n = sessionName(id)
        return sentKeys.filter { $0.name == n }.map(\.text)
    }

    /// Seed a session as alive without an ensure (for "still running" cards in recover tests).
    func setAlive(_ id: UUID, _ value: Bool) {
        lock.lock(); if value { alive.insert(sessionName(id)) } else { alive.remove(sessionName(id)) }; lock.unlock()
    }

    func sessionName(_ id: UUID) -> String { "orchestra-\(id.uuidString.lowercased())" }

    func ensure(_ task: Task, argv: [String], env: [String: String] = [:]) throws -> (name: String, created: Bool) {
        let name = sessionName(task.id)
        lock.lock(); curConcurrentEnsure += 1; peakConcurrentEnsure = max(peakConcurrentEnsure, curConcurrentEnsure); ensureCount += 1; lock.unlock()
        if ensureSleepMs > 0 { usleep(ensureSleepMs * 1000) }
        lock.lock(); curConcurrentEnsure -= 1; alive.insert(name); ensureArgv[name] = argv; ensureEnv[name] = env; lock.unlock()
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
    func capture(_ name: String, window: String) throws -> String {
        lock.lock(); defer { lock.unlock() }; return captureText[name] ?? ""
    }
    func sendKeys(_ name: String, text: String, window: String) throws {
        lock.lock(); sentKeys.append((name, text)); lock.unlock()
    }
    func kill(_ name: String) throws { lock.lock(); alive.remove(name); killed.append(name); lock.unlock() }
}

/// An adapter whose transcript path is under a test-controlled dir, so resumable/transcript-exists is
/// fully controllable. Registered with id "claude-code" so `spawn` finds it.
final class StubAdapter: Adapter, @unchecked Sendable {
    let id: String
    let name: String
    let icon = "sparkle"
    let bin = "fake-agent"
    let enabled = true
    let capabilities: AgentCapabilities
    let transcriptDir: String
    init(transcriptDir: String, capabilities: AgentCapabilities = .claudeCode,
         id: String = "claude-code", name: String = "Stub") {
        self.transcriptDir = transcriptDir
        self.capabilities = capabilities
        self.id = id
        self.name = name
    }

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
        var a = [bin, "--resume", s, "--name", ctx.name ?? ""]
        if let seed = ctx.seed, !seed.isEmpty { a.append(seed) }   // F1: deliver the seed like real adapters
        return a
    }
    /// A recognizable, NON-Claude parse: turns a tailed line into a marker report, proving parse is
    /// per-adapter (a Claude adapter returns nil for the same `.fileTail` raw).
    func parse(_ raw: RawTelemetry) -> StatusReport? {
        if case let .fileTail(line) = raw { return StatusReport(desc: "tail:\(line)", status: .running) }
        return nil
    }
    /// Stand in for a send-keys TUI agent's pane-gate: the send-keys wake tests feed Codex-style panes,
    /// so mirror `CodexAdapter.canNudge` (default `false` would make those tests never nudge).
    func canNudge(pane: String) -> Bool { CodexComposer.canNudge(pane) }
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

/// A minimal async mutex. Scratch-card tests share ONE global resource — the real
/// `Config.scratchRoot` (`~/.orchestra/scratch`, not test-overridable) — and one of them
/// (`sweepOrphanScratch`) deletes every dir there that isn't a live card. swift-testing runs suites
/// in parallel, so without serialization that sweep would yank a sibling suite's in-flight scratch
/// dir out from under it. `.serialized` only orders tests *within* one suite; this lock orders the
/// filesystem-touching scratch tests *across* suites. Wrap each such test body in `withScratchLock`.
final class AsyncLock: @unchecked Sendable {
    private let nslock = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            nslock.withLock {
                if !locked { locked = true; c.resume() } else { waiters.append(c) }
            }
        }
    }
    func release() {
        nslock.withLock {
            if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
        }
    }
}
let scratchTestLock = AsyncLock()
func withScratchLock<T>(_ body: () async throws -> T) async rethrows -> T {
    await scratchTestLock.acquire()
    defer { scratchTestLock.release() }
    return try await body()
}

/// Stub human-grant resolver: returns a fixed outcome and records what it was asked (drives the
/// approve / deny grant tests without a live MCP client or tty — O7).
final class StubGrantResolver: TrustGrantResolver, @unchecked Sendable {
    let outcome: TrustGrantOutcome
    private let lock = NSLock()
    private(set) var asked: [(path: String, source: ActivitySource)] = []
    init(_ outcome: TrustGrantOutcome) { self.outcome = outcome }
    func requestGrant(path: String, reason: String, source: ActivitySource) async -> TrustGrantOutcome {
        lock.withLock { asked.append((path, source)) }
        return outcome
    }
}

enum TestEnv {
    /// A service wired with stubs + a controllable adapter, all under a temp dir allowlist.
    static func make(maxRevivals: Int = 4, grace: Int = 1, capabilities: AgentCapabilities = .claudeCode,
                     grantResolver: any TrustGrantResolver = SurfaceGrantResolver(),
                     registry: AgentRegistry? = nil)
        -> (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String) {
        let base = NSTemporaryDirectory() + "orch-svc-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: base + "/repos", withIntermediateDirectories: true)
        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)],
                            maxConcurrentRevivals: maxRevivals, revivalGraceSeconds: grace)
        let sessions = StubSessions()
        let worktrees = StubWorktrees(root: config.worktreesRoot)
        let adapter = StubAdapter(transcriptDir: base + "/transcripts", capabilities: capabilities)
        let store = TaskStore(path: base + "/tasks.json")
        let trust = TrustLedger(path: base + "/trust-ledger.json")
        let inbox = Inbox(path: base + "/inbox.json")
        let svc = OrchestraService(config: config, store: store,
                                   registry: registry ?? AgentRegistry(adapters: [adapter]),
                                   worktrees: worktrees, sessions: sessions, trust: trust, inbox: inbox,
                                   grantResolver: grantResolver)
        return (svc, sessions, worktrees, adapter, trust, PathResolver.canonical(base))
    }

    /// Make a repo dir under reposRoot and return its path.
    static func repo(_ base: String, _ name: String = "app") -> String {
        let p = base + "/repos/" + name
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
}
