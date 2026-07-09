import Foundation
@testable import OrchestraCore

/// In-memory worktree stub — never touches git.
final class StubWorktrees: WorktreeManaging, @unchecked Sendable {
    let root: String
    private let lock = NSLock()
    private(set) var removed: [String] = []
    private(set) var ensured: [String] = []   // repo+branch pairs ensure() was called for
    private var existingBranches: Set<String> = []   // branches ensure() should report as pre-existing
    init(root: String) { self.root = root }

    /// Mark a branch as pre-existing so `ensure` reports `branchExisted = true` (the churn scenario:
    /// re-spawn onto a branch whose worktree was removed but whose branch + lineage config remain).
    func markBranchExists(_ branch: String) {
        lock.lock(); existingBranches.insert(branch); lock.unlock()
    }

    func path(repo: String, branch: String) -> String {
        "\(root)/\((repo as NSString).lastPathComponent)/\(branch)"
    }
    private(set) var ensuredBases: [String: String?] = [:]   // branch -> base ensure() saw
    func ensure(repo: String, branch: String, base: String?) throws
        -> (worktree: String, created: Bool, branchExisted: Bool) {
        lock.lock()
        ensured.append("\(repo)#\(branch)")
        ensuredBases[branch] = base
        let existed = existingBranches.contains(branch)
        lock.unlock()
        let wt = path(repo: repo, branch: branch)
        try? FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        return (wt, true, existed)
    }
    func remove(worktree: String, force: Bool) throws {
        lock.lock(); removed.append(worktree); lock.unlock()
    }
    // O3 borrow stub — mkdir a fake borrow dir; real git behavior is covered by BorrowLifecycleTests
    // (makeReal). `pruneOrphanBorrows` is a no-op here (no git worktree list).
    func borrowPath(repo: String, branch: String) -> String {
        "\(root)/\((repo as NSString).lastPathComponent)/orch-borrow-\(branch.replacingOccurrences(of: "/", with: "-"))"
    }
    func borrow(repo: String, branch: String) throws -> String {
        let wt = borrowPath(repo: repo, branch: branch)
        try? FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        return wt
    }
    func pruneOrphanBorrows(repo: String) {}
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
    private(set) var sentKeys: [(name: String, text: String)] = []

    /// Keystrokes sent to a card's agent window, in order (the read-only shell launcher; historically also
    /// the retired send-keys nudge).
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
    /// Records every `isAlive` query (in order) so the nil-epoch kill-probe discipline can be asserted:
    /// a pre-upgrade SessionEnd must consult `isAlive` before it is allowed to kill the card.
    private(set) var isAliveQueries: [String] = []
    func isAlive(_ name: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        isAliveQueries.append(name)
        return alive.contains(name)
    }

    /// Non-recording liveness read for test setup/assertions (doesn't pollute `isAliveQueries`).
    func isAliveTest(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return alive.contains(sessionName(id)) }

    /// Per-session shell windows (excludes `agent`), so `windows()` faithfully reflects opens/closes —
    /// the shell-sync broadcast (`emitShells`) recomputes its set from here, so a canned single-agent
    /// list would make every `shellsChanged` empty.
    private var shellWins: [String: [String]] = [:]

    func newShellWindow(_ name: String, cwd: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        var ws = shellWins[name] ?? []
        var n = 1
        while ws.contains("shell-\(n)") { n += 1 }
        let win = "shell-\(n)"
        ws.append(win); shellWins[name] = ws
        return win
    }
    func ensureShellWindow(_ name: String, window: String, cwd: String) throws -> String {
        guard SessionManager.isValidShellWindowName(window) else {
            throw OrchestraError.invalidParams("invalid shell window name: \(window)")
        }
        lock.lock(); defer { lock.unlock() }
        var ws = shellWins[name] ?? []
        if !ws.contains(window) { ws.append(window); shellWins[name] = ws }
        return window
    }
    func closeShellWindow(_ name: String, window: String) throws {
        guard window != "agent" else { return }
        lock.lock(); shellWins[name]?.removeAll { $0 == window }; lock.unlock()
    }
    func windows(_ name: String) throws -> [TmuxTarget] {
        // Mirror the real SessionManager contract: a dead session can't yield an authoritative
        // listing, so THROW rather than return `[]` (so `emitShells` skips instead of wiping).
        guard try isAlive(name) else { throw OrchestraError.io("session not alive: \(name)") }
        func t(_ window: String, _ kind: WindowKind) -> TmuxTarget {
            TmuxTarget(socket: "orchestra", session: name, window: window, kind: kind,
                       target: "\(name):\(window)", attach: "tmux -L orchestra attach -t \(name):\(window)")
        }
        lock.lock(); let ws = shellWins[name] ?? []; lock.unlock()
        return [t("agent", .agent)] + ws.map { t($0, .shell) }
    }
    func list() throws -> [SessionInfo] { lock.lock(); defer { lock.unlock() }; return alive.map { SessionInfo(name: $0, running: true) } }
    func sendKeys(_ name: String, text: String, window: String) throws {
        lock.lock(); sentKeys.append((name, text)); lock.unlock()
    }
    /// Records a chord's rendered wire form (`key:<name>` / raw text) so command tests can assert
    /// what would reach tmux without a real server. Throws if the session isn't alive, mirroring the
    /// real manager's guard.
    private(set) var sentChords: [(name: String, tokens: [KeyToken])] = []
    func sendChord(_ name: String, tokens: [KeyToken], window: String) throws {
        guard try isAlive(name) else { throw OrchestraError.io("session not alive: \(name)") }
        lock.lock(); sentChords.append((name, tokens)); lock.unlock()
    }
    func capture(_ name: String, window: String, maxChars: Int) throws -> CaptureResult {
        guard try isAlive(name) else { throw OrchestraError.io("session not alive: \(name)") }
        let text = "stub-pane:\(name):\(window)"
        return CaptureResult(window: window, text: String(text.prefix(maxChars)), truncated: false)
    }
    func kill(_ name: String) throws { lock.lock(); alive.remove(name); shellWins[name] = nil; killed.append(name); lock.unlock() }
}

/// An adapter whose transcript path is under a test-controlled dir, so resumable/transcript-exists is
/// fully controllable. Registered with id "claude-code" so `spawn` finds it.
extension AgentCapabilities {
    /// The default test-stub capability: Claude-shaped on every axis EXCEPT readiness confirmation, which
    /// is `.relaunchLiveness` so a blank spawn/reopen and a resume both land immediately on a successful
    /// `ensure` — no readiness signal to hand-deliver. This keeps the many tests that spawn/resume a card
    /// merely as SETUP green and synchronous under 2.6's capability-gated launch readiness. Tests that
    /// specifically exercise the awaited signal path opt into `.claudeCode` (`.sessionStartHook`) or
    /// `.codex` (`.rolloutMeta`) explicitly.
    static let stub = AgentCapabilities(
        sessionId: .seeded, telemetry: .hooksPush, contextUsage: .percent,
        wakeTransport: .nativeReinvoke, inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed, authMode: .subscription,
        terminalImagePaste: .controlV, readinessConfirmation: .relaunchLiveness)
}

final class StubAdapter: Adapter, @unchecked Sendable {
    let id: String
    let name: String
    let icon = "sparkle"
    let bin = "fake-agent"
    let enabled = true
    let capabilities: AgentCapabilities
    let transcriptDir: String
    init(transcriptDir: String, capabilities: AgentCapabilities = .stub,
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
        if case let .fileTail(line) = raw { return StatusReport(desc: "tail:\(line)", run: .running) }
        return nil
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
    func start(_ stream: AsyncStream<EventEnvelope>) {
        _Concurrency.Task { for await e in stream { self.append(e.event) } }
    }
    private func append(_ e: Event) { events.append(e) }
    var activities: [ActivityItem] {
        events.compactMap { if case .activity(let a) = $0 { return a } else { return nil } }
    }
    var upserts: [Task] {
        events.compactMap { if case .taskUpserted(let t) = $0 { return t } else { return nil } }
    }
    var ownerStates: [AgentTerminalOwnerState] {
        events.compactMap { if case .agentTerminalOwner(let s) = $0 { return s } else { return nil } }
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
    static func make(maxRevivals: Int = 4, grace: Int = 1, capabilities: AgentCapabilities = .stub,
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

    /// Rebuild a fresh service over the SAME on-disk stores as an earlier `make()` — simulates a daemon
    /// restart (in-memory timers/loops are gone; the file-backed store/inbox/trust reload from disk).
    /// Pass the canonical `base` that `make()` returned: `make` writes those files under the non-canonical
    /// `NSTemporaryDirectory()` prefix, which is the same inode via the macOS `/var → /private/var` symlink,
    /// so this reads exactly the files `make` wrote. Non-path knobs (revival tuning) reset to defaults —
    /// itself a realistic "fresh daemon" trait.
    static func remake(base: String, capabilities: AgentCapabilities = .stub)
        -> (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String) {
        let config = Config(reposRoot: base + "/repos",
                            worktreesRoot: base + "/worktrees",
                            allowlist: [base])
        let sessions = StubSessions()
        let worktrees = StubWorktrees(root: config.worktreesRoot)
        let adapter = StubAdapter(transcriptDir: base + "/transcripts", capabilities: capabilities)
        let store = TaskStore(path: base + "/tasks.json")
        let trust = TrustLedger(path: base + "/trust-ledger.json")
        let inbox = Inbox(path: base + "/inbox.json")
        let svc = OrchestraService(config: config, store: store,
                                   registry: AgentRegistry(adapters: [adapter]),
                                   worktrees: worktrees, sessions: sessions, trust: trust, inbox: inbox)
        return (svc, sessions, worktrees, adapter, trust, base)
    }

    /// Make a repo dir under reposRoot and return its path.
    static func repo(_ base: String, _ name: String = "app") -> String {
        let p = base + "/repos/" + name
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// Spawn through the AWAITING launch path (`.sessionStartHook`/`.rolloutMeta` caps) and drive the
    /// launch's readiness signal so it reaches `.live`. Under 2.6 a capability-gated blank spawn inline-
    /// awaits its ready signal; a test using such caps merely as setup has no live poll loop, so this
    /// finds the card mid-launch (spawn persists it at `.creatingWorktree`→`.launching` before it awaits)
    /// and delivers SessionStart(startup) to unblock it. Use for resume/relaunch-mechanics tests that need
    /// `.claudeCode` (the awaited resume path) but still spawn a live card first.
    @discardableResult
    static func spawnAwaited(_ svc: OrchestraService, _ input: SpawnInput) async throws -> Task {
        async let spawned = svc.spawn(input)
        try await pollUntil {
            await svc.list().contains { $0.branch == input.branch && $0.phase.kind == .launching }
        }
        if let id = await svc.list().first(where: { $0.branch == input.branch })?.id {
            try? await svc.report(id, StatusReport(sessionSource: "startup"))
        }
        return try await spawned
    }

    /// Drive being-born cards to `.live` via the universal N=3 liveness-tick fallback (no readiness signal
    /// hand-delivered): repeatedly run `reconcileLiveness` until at least `count` cards are live. Used by
    /// Codex (`.rolloutMeta`) spawn setups whose fixture rollout can't bind DURING launch (its mtime
    /// predates the card's `phaseChangedAt`, so the time-scoped launch bind refuses it) — the fallback
    /// reaches live, then post-live discovery (unrestricted) binds the rollout for telemetry.
    static func reconcileUntilLive(_ svc: OrchestraService, count: Int) async throws {
        try await pollUntil {
            await svc.reconcileLiveness()
            return await svc.list().filter { $0.phase.kind == .live }.count >= count
        }
    }

    /// A service wired with the REAL `WorktreeManager` (git worktrees actually cut) — needed for the
    /// remote-tier tests, where a spawn's start-point must resolve against a real fetched ref. Everything
    /// else (store/trust/inbox/adapter) is stubbed as in `make`. Returns the service + its allowlisted base
    /// (the git working repo + its bare origin are created UNDER `base` by `makeRemoteRepo`).
    static func makeReal(capabilities: AgentCapabilities = .stub)
        -> (svc: OrchestraService, sessions: StubSessions, adapter: StubAdapter, base: String) {
        let base = PathResolver.canonical(NSTemporaryDirectory() + "orch-rsvc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: base + "/repos", withIntermediateDirectories: true)
        let config = Config(reposRoot: base + "/repos",
                            worktreesRoot: base + "/worktrees",
                            allowlist: [base])
        let resolver = PathResolver(config: config)
        let sessions = StubSessions()
        let adapter = StubAdapter(transcriptDir: base + "/transcripts", capabilities: capabilities)
        let store = TaskStore(path: base + "/tasks.json")
        let trust = TrustLedger(path: base + "/trust-ledger.json")
        let inbox = Inbox(path: base + "/inbox.json")
        let worktrees = WorktreeManager(config: config, resolver: resolver)
        let svc = OrchestraService(config: config, store: store,
                                   registry: AgentRegistry(adapters: [adapter]),
                                   worktrees: worktrees, sessions: sessions, resolver: resolver,
                                   trust: trust, inbox: inbox)
        return (svc, sessions, adapter, base)
    }
}
