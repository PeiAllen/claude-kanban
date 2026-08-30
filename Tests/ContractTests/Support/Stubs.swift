import Foundation
import TestSupport
@testable import OrchestraCore

/// In-memory worktree stub — never touches git.
final class StubWorktrees: WorktreeManaging, @unchecked Sendable {
    let root: String
    private let lock = NSLock()
    private(set) var removed: [String] = []
    private(set) var ensured: [String] = []   // repo+branch pairs ensure() was called for
    private var existingBranches: Set<String> = []   // branches ensure() should report as pre-existing
    /// Deterministic rendezvous inside `ensure` (`git worktree add`), so concurrent-`ensure` tests can
    /// genuinely contend on the actor: the stub PARKS (blocking, bounded — the same thread semantics as
    /// the sleep knob it replaced) until the test `release()`s it. Sync seam ⇒ `SyncGate`, not `Gate`.
    var ensureGate: SyncGate? = nil
    init(root: String) { self.root = root }

    /// A test-armed gate proving an RPC can return WHILE `ensure` is still provisioning: `blockEnsure`
    /// parks the next `ensure` call on a semaphore (bounded by a safety timeout so a mis-armed test can't
    /// hang the suite); `releaseEnsure` opens it. Distinct from `ensureGate` (a test-scheduled rendezvous).
    private let blockEnsureSem = DispatchSemaphore(value: 0)
    private var ensureBlocked = false
    func blockEnsure() { lock.lock(); ensureBlocked = true; lock.unlock() }
    func releaseEnsure() {
        lock.lock(); let wasBlocked = ensureBlocked; ensureBlocked = false; lock.unlock()
        if wasBlocked { blockEnsureSem.signal() }
    }

    /// Mark a branch as pre-existing so `ensure` reports `branchExisted = true` (the churn scenario:
    /// re-spawn onto a branch whose worktree was removed but whose branch + lineage config remain).
    func markBranchExists(_ branch: String) {
        lock.lock(); existingBranches.insert(branch); lock.unlock()
    }

    func path(repo: String, branch: String) -> String {
        "\(root)/\((repo as NSString).lastPathComponent)/\(branch)"
    }
    private(set) var ensuredBases: [String: String?] = [:]   // branch -> base ensure() saw
    /// When set, `ensure` throws it (drives the materialize failure-classification tests). An error whose
    /// description contains "timed out" exercises the explicit timeout wording.
    var ensureError: Error?
    func ensure(repo: String, branch: String, base: String?) throws
        -> (worktree: String, created: Bool, branchExisted: Bool) {
        lock.lock()
        ensured.append("\(repo)#\(branch)")
        ensuredBases[branch] = base
        let existed = existingBranches.contains(branch)
        let blocked = ensureBlocked
        let err = ensureError
        lock.unlock()
        if let err { throw err }
        if let g = ensureGate { g.parkBlocking() }
        if blocked { _ = blockEnsureSem.wait(timeout: .now() + .seconds(30)) }   // parked until releaseEnsure (safety-bounded)
        let wt = path(repo: repo, branch: branch)
        try? FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        return (wt, true, existed)
    }
    /// `(path, force)` pairs, in call order — the rollback-routing test discriminates old `force:true`
    /// callers from new `force:false` callers.
    private(set) var removedForce: [(path: String, force: Bool)] = []
    func remove(worktree: String, force: Bool) throws {
        lock.lock(); removed.append(worktree); removedForce.append((worktree, force)); lock.unlock()
        try? FileManager.default.removeItem(atPath: worktree)
    }
    // O3 borrow stub — mkdir a fake borrow dir; real git behavior is covered by BorrowLifecycleTests
    // (makeReal).
    func borrowPath(repo: String, branch: String) -> String {
        "\(root)/\((repo as NSString).lastPathComponent)/orch-borrow-\(branch.replacingOccurrences(of: "/", with: "-"))"
    }
    func borrow(repo: String, branch: String) throws -> String {
        let wt = borrowPath(repo: repo, branch: branch)
        try? FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        return wt
    }

    /// Controllable dirty set, driven by `WorktreeRegistryTests` via `setDirty`.
    private var dirtyPaths: Set<String> = []
    func setDirty(_ path: String, _ v: Bool) { lock.lock(); if v { dirtyPaths.insert(path) } else { dirtyPaths.remove(path) }; lock.unlock() }
    func isDirty(worktree: String) -> Bool { lock.lock(); defer { lock.unlock() }; return dirtyPaths.contains(worktree) }

    func orphanBorrowPaths(repo: String) -> [String] {
        let dir = "\(root)/\((repo as NSString).lastPathComponent)"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return entries.filter { $0.hasPrefix("orch-borrow-") }.map { "\(dir)/\($0)" }
    }
}

// (`WorktreeManaging` no longer declares `pruneOrphanBorrows` — Task 3.5 dropped it; the registry's
// `sweepOrphanBorrows(cards:)` guarded loop replaced its only caller.)

/// In-memory tmux stub — tracks alive sessions and records launch argv; thread-safe (offActor runs
/// ensure on a background queue). `ensureGate` lets overlap/ordering tests park inside `ensure`.
final class StubSessions: SessionManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var alive: Set<String> = []
    private(set) var ensureArgv: [String: [String]] = [:]
    private(set) var ensureEnv: [String: [String: String]] = [:]
    private(set) var killed: [String] = []
    private(set) var ensureCount = 0
    private(set) var peakConcurrentEnsure = 0
    private var curConcurrentEnsure = 0
    /// Deterministic rendezvous inside `ensure` — the stub parks (blocking, bounded) until the test
    /// releases it. Lets a test land another event in the exact off-actor bring-up window.
    var ensureGate: SyncGate? = nil
    private(set) var sentKeys: [(name: String, text: String)] = []
    private var deadPanes: Set<String> = []       // sessions whose agent pane process exited (remain-on-exit)
    private var paneText: [String: String] = [:]  // canned capture-pane text per session (the "stderr")
    private(set) var remainOnExit: [String: Bool] = [:]
    var captureGate: SyncGate? = nil               // park `capture` to open a race window in tests
    var failRemainOnExitOff = false               // make `setRemainOnExit(on:false)` throw (tmux-hiccup sim)
    /// Simulate a HOST that has run out of a launch resource (see `hostResourceFault`). nil = healthy host.
    var simulatedHostFault: HostResource?
    /// Make `ensure` throw the given stderr — models tmux failing to create the session (e.g. the real
    /// "create window failed: fork failed: Device not configured" of an empty pty pool).
    var ensureError: String?

    /// Simulate an immediate startup abort: the agent pane's process exited, but remain-on-exit keeps the
    /// session PRESENT with a dead pane (the exact state a real startup abort leaves behind).
    func setPaneDead(_ id: UUID) {
        lock.lock(); deadPanes.insert(sessionName(id)); lock.unlock()
    }
    /// Canned final pane output (the dying process's stderr) returned by `capture` for this session.
    func setPaneText(_ id: UUID, _ text: String) {
        lock.lock(); paneText[sessionName(id)] = text; lock.unlock()
    }
    func setRemainOnExit(_ name: String, window: String, on: Bool) throws {
        if !on, failRemainOnExitOff { throw OrchestraError.io("stub: remain-on-exit off failed") }
        lock.lock(); remainOnExit[name] = on; lock.unlock()
    }
    /// HERMETIC by construction: the stub creates no real terminals, so it is never starved by the actual
    /// machine — it reports only what the evidence says, plus whatever fault the test explicitly simulates.
    /// This is why a developer's drained pty pool can't make unrelated stubbed tests fail.
    func hostResourceFault(evidence: String?) -> HostResourceReport? {
        if let named = HostResource.classify(evidence) { return HostResourceReport(resource: named, max: 511, free: 0) }
        lock.lock(); defer { lock.unlock() }
        return simulatedHostFault.map { HostResourceReport(resource: $0, max: 511, free: 0) }
    }
    func agentPaneState(_ name: String) throws -> PaneLiveness {
        lock.lock(); defer { lock.unlock() }
        if !alive.contains(name) { return .gone }
        return deadPanes.contains(name) ? .dead : .alive
    }
    /// One-shot hook invoked synchronously INSIDE `agentPaneDeadSessions()` — the reconciler's SECOND
    /// off-actor probe, which runs after the `list()` session snapshot and before the card phases are read.
    /// That gap is the actor-released window a real bring-up step lands in, so a test can inject "the
    /// relaunch just finished" exactly there. Same shape as `onStampedEpochProbe`. Fires once, then clears.
    var onAgentPaneDeadProbe: (@Sendable () -> Void)?
    func agentPaneDeadSessions() throws -> Set<String> {
        let hook: (@Sendable () -> Void)?
        lock.lock(); hook = onAgentPaneDeadProbe; onAgentPaneDeadProbe = nil; lock.unlock()
        hook?()   // OUTSIDE the lock so the test's concurrent actor work can't deadlock on it
        lock.lock(); defer { lock.unlock() }
        return deadPanes.intersection(alive)   // only present sessions with a dead pane
    }

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

    /// Seed a session as alive AND stamp its `ORCH_EPOCH` (as an `ensure` would) so `stampedEpoch` reads
    /// it back — drives the reconciler's epoch-identity adoption / orphan-probe tests without a real launch.
    func setStampedEpoch(_ id: UUID, _ epoch: Int) {
        lock.lock(); let n = sessionName(id); alive.insert(n)
        ensureEnv[n, default: [:]]["ORCH_EPOCH"] = String(epoch); lock.unlock()
    }

    /// Optional rendezvous inside `isAlive` (the reconciler's pre-kill probe), so a test can prove the
    /// probe runs OFF the service actor: a concurrent fast RPC returns while the probe is parked.
    var isAliveGate: SyncGate? = nil

    func sessionName(_ id: UUID) -> String { "orchestra-\(id.uuidString.lowercased())" }

    /// Called INSIDE `ensure`, i.e. while the bring-up is off-actor mid-hop. Lets a test land a supersede
    /// (a launch-timeout death, an archive) in the exact window `finishLaunch` cannot hold the actor across,
    /// and then assert the bring-up reaps the session it created instead of leaking it under a dead card.
    var onEnsure: (@Sendable () -> Void)?

    func ensure(_ task: Task, argv: [String], env: [String: String] = [:]) throws -> (name: String, created: Bool) {
        let name = sessionName(task.id)
        lock.lock(); curConcurrentEnsure += 1; peakConcurrentEnsure = max(peakConcurrentEnsure, curConcurrentEnsure); ensureCount += 1; lock.unlock()
        onEnsure?()
        // Models tmux refusing to create the session at all (`OrchestraError.io(stderr)`), exactly as the
        // real `SessionManager.ensure` throws when `tmux new-session` exits non-zero.
        if let stderr = ensureError {
            lock.lock(); curConcurrentEnsure -= 1; lock.unlock()
            throw OrchestraError.io(stderr)
        }
        if let g = ensureGate { g.parkBlocking() }
        // A fresh launch re-mints a LIVE pane — clear any prior dead-pane mark (models a healthy retry).
        lock.lock(); curConcurrentEnsure -= 1; alive.insert(name); deadPanes.remove(name); ensureArgv[name] = argv; ensureEnv[name] = env; lock.unlock()
        return (name, true)
    }
    /// Records every `isAlive` query (in order) so the nil-epoch kill-probe discipline can be asserted:
    /// a pre-upgrade SessionEnd must consult `isAlive` before it is allowed to kill the card.
    private(set) var isAliveQueries: [String] = []
    func isAlive(_ name: String) throws -> Bool {
        lock.lock(); isAliveQueries.append(name); let g = isAliveGate; let a = alive.contains(name); lock.unlock()
        if let g { g.parkBlocking() }   // simulate a slow off-actor probe (isAliveGate), deterministically
        return a
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
    /// Recorded call count for `windows()` — the boardSnapshot-cache tests (PR5 actor-hygiene Task 5.2)
    /// assert a cache HIT shells zero times and a MISS shells exactly once.
    private(set) var windowsCount = 0
    func windows(_ name: String) throws -> [TmuxTarget] {
        // Mirror the real SessionManager contract: a dead session can't yield an authoritative
        // listing, so THROW rather than return `[]` (so `emitShells` skips instead of wiping).
        guard try isAlive(name) else { throw OrchestraError.io("session not alive: \(name)") }
        lock.lock(); windowsCount += 1; lock.unlock()
        func t(_ window: String, _ kind: WindowKind) -> TmuxTarget {
            TmuxTarget(socket: "orchestra", session: name, window: window, kind: kind,
                       target: "\(name):\(window)", attach: "tmux -L orchestra attach -t \(name):\(window)")
        }
        lock.lock(); let ws = shellWins[name] ?? []; lock.unlock()
        return [t("agent", .agent)] + ws.map { t($0, .shell) }
    }
    /// Non-recording `windows()` query for test assertions (doesn't pollute `windowsCount`) — mirrors
    /// `isAliveTest`.
    func windowsForTest(_ id: UUID) throws -> [TmuxTarget] {
        let name = sessionName(id)
        guard try isAlive(name) else { throw OrchestraError.io("session not alive: \(name)") }
        func t(_ window: String, _ kind: WindowKind) -> TmuxTarget {
            TmuxTarget(socket: "orchestra", session: name, window: window, kind: kind,
                       target: "\(name):\(window)", attach: "tmux -L orchestra attach -t \(name):\(window)")
        }
        lock.lock(); let ws = shellWins[name] ?? []; lock.unlock()
        return [t("agent", .agent)] + ws.map { t($0, .shell) }
    }
    /// `listCount` records how many times `list()` (the reconcile/reconcileLiveness batched liveness
    /// snapshot) was queried. (The off-actor-ness of that call is proven by `ActorHygieneTests`, whose
    /// own `SlowListSessionStub` carries the latency knob — not by this stub.)
    private(set) var listCount = 0
    func list() throws -> [SessionInfo] {
        lock.lock(); listCount += 1; let out = alive.map { SessionInfo(name: $0, running: true) }; lock.unlock()
        return out
    }
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
        lock.lock(); let canned = paneText[name]; let g = captureGate; lock.unlock()
        if let g { g.parkBlocking() }   // hold the capture window open so a concurrent report can race
        let text = canned ?? "stub-pane:\(name):\(window)"
        return CaptureResult(window: window, text: String(text.prefix(maxChars)), truncated: false)
    }
    func kill(_ name: String) throws {
        // Mirror real tmux: killing a session that isn't alive is a no-op — do NOT record it. (finishLaunch
        // idempotently kills any predecessor before `ensure`; for a FRESH launch there is none, so that
        // harmless no-op must not show up as a spurious `killed` entry.)
        lock.lock(); let wasAlive = alive.remove(name) != nil; shellWins[name] = nil
        deadPanes.remove(name); paneText[name] = nil
        if wasAlive { killed.append(name) }; lock.unlock()
    }

    /// Parse the `ORCH_EPOCH` stamped into the session's launch env (the reconciler's identity oracle).
    /// nil when the session is gone (not alive) or was launched without the stamp — mirroring the real
    /// `SessionManager.stampedEpoch` (which returns nil for an absent variable / dead session).
    /// One-shot hook invoked synchronously INSIDE `stampedEpoch` — which the reconciler runs OFF the
    /// service actor. Lets a test inject a concurrent restart during the probe's actor-released window
    /// (to prove the adoption shortcut is epoch-fenced). Fires once, then clears itself.
    var onStampedEpochProbe: (@Sendable (String) -> Void)?
    func stampedEpoch(name: String) throws -> Int? {
        let hook: (@Sendable (String) -> Void)?
        lock.lock(); hook = onStampedEpochProbe; onStampedEpochProbe = nil; lock.unlock()
        hook?(name)   // run OUTSIDE the lock so the test's concurrent actor work can't deadlock on it
        lock.lock(); defer { lock.unlock() }
        guard alive.contains(name), let v = ensureEnv[name]?["ORCH_EPOCH"] else { return nil }
        return Int(v)
    }
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
    /// The stub's model catalog. Per-instance so a test can stand up two adapters with DISJOINT catalogs
    /// and prove a cross-adapter `--model` (a Codex id on a claude-code card) is rejected.
    let modelIds: [String]
    init(transcriptDir: String, capabilities: AgentCapabilities = .stub,
         id: String = "claude-code", name: String = "Stub", modelIds: [String] = ["m1", "m2", "m3"]) {
        self.transcriptDir = transcriptDir
        self.capabilities = capabilities
        self.id = id
        self.name = name
        self.modelIds = modelIds
    }

    func models() -> [AgentModel] { modelIds.map { AgentModel(id: $0) } }
    func newSessionId() -> String? { UUID().uuidString.lowercased() }
    /// Both argv builders emit the model flag from `ctx.model`, like the real adapters
    /// (ClaudeCodeAdapter `--model`, Codex `-m`) — so a test can assert which model a launch actually
    /// went up on. Emitted BEFORE the trailing prompt/seed positional, again like the real ones.
    private func modelFlag(_ model: String?) -> [String] {
        guard let m = model, !m.isEmpty else { return [] }
        return ["--model", m]
    }
    /// The read-only posture, emitted on BOTH launch paths like the real adapters (Claude's locked-down
    /// tool list, Codex's `-s read-only -a never`) — so a test can prove a read-only card stays read-only
    /// across a resume, not only on the spawn that created it.
    private func accessFlags(_ access: CardAccess) -> [String] {
        access == .readOnly ? ["--read-only"] : []
    }
    func start(_ ctx: AdapterContext) -> [String] {
        var a = [bin]
        if let s = ctx.sessionId { a += ["--session-id", s] }
        if let n = ctx.name { a += ["--name", n] }
        a += accessFlags(ctx.access)
        a += modelFlag(ctx.model)
        if let p = ctx.prompt { a.append(p) }
        return a
    }
    func resume(_ ctx: AdapterContext) -> [String]? {
        guard let s = ctx.sessionId else { return nil }
        var a = [bin, "--resume", s, "--name", ctx.name ?? ""]
        a += accessFlags(ctx.access)
        a += modelFlag(ctx.model)
        if let seed = ctx.seed, !seed.isEmpty { a.append(seed) }   // F1: deliver the seed like real adapters
        return a
    }
    /// A recognizable, NON-Claude parse: turns a tailed line into a marker report, proving parse is
    /// per-adapter (a Claude adapter returns nil for the same `.fileTail` raw).
    func parse(_ raw: RawTelemetry) -> StatusReport? {
        if case let .fileTail(line) = raw { return StatusReport(desc: "tail:\(line)") }
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
    /// `extraAgents` registers ADDITIONAL stub adapters beside the default `claude-code` one, each with its
    /// own model catalog — so a test can prove a model id that is valid for ANOTHER agent is still rejected
    /// on this card (a card's `agentId` never changes, so its catalog is the only one that may authorize a
    /// re-seat). They share the default adapter's transcript dir, so `writeTranscript` works for all of them.
    static func make(maxRevivals: Int = 4, grace: Int = 1, capabilities: AgentCapabilities = .stub,
                     grantResolver: any TrustGrantResolver = SurfaceGrantResolver(),
                     registry: AgentRegistry? = nil,
                     extraAgents: [(id: String, models: [String])] = [],
                     clock: any Clock<Duration> = ContinuousClock(),
                     proc: (any ProcRunning)? = nil)
        -> (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String) {
        let base = NSTemporaryDirectory() + "orch-svc-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: base + "/repos", withIntermediateDirectories: true)
        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)],
                            maxConcurrentRevivals: maxRevivals, revivalGraceSeconds: grace,
                            // A launch timeout the test cannot outlive. The product default is 30s, which is
                            // right for a real daemon — but a test's bring-up is driven by ITS OWN
                            // `reconcile()` polling, and under `--parallel` load a single reconcile can cost
                            // ~20s. The card then blows the 30s launch deadline and the reconciler correctly
                            // concludes `dead(spawnFailed)` — so the test's premise ("the card reaches
                            // `.live`") evaporates and it fails asserting a behavior that never got to run.
                            // Same trap as the startup grace (see `spawnStartupPending`): a wall-clock
                            // deadline the machine, not the product, decides.
                            //
                            // Tests that genuinely EXERCISE the timeout are unaffected: they back-date
                            // `phaseChangedAt` by `-(config.sessionLaunchTimeout + n)`, reading the value
                            // from config, so the arm still fires deterministically at any setting.
                            sessionLaunchTimeout: 3600,
                            scratchRoot: PathResolver.canonical(base) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(base) + "/state")
        let sessions = StubSessions()
        let worktrees = StubWorktrees(root: config.worktreesRoot)
        let wtRegistry = WorktreeRegistry(config: config, manager: worktrees,
                                          borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")
        let adapter = StubAdapter(transcriptDir: base + "/transcripts", capabilities: capabilities)
        let store = TaskStore(path: base + "/tasks.json", clock: clock)
        let trust = TrustLedger(path: base + "/trust-ledger.json")
        let inbox = Inbox(path: base + "/inbox.json")
        let extras = extraAgents.map {
            StubAdapter(transcriptDir: base + "/transcripts", capabilities: capabilities,
                        id: $0.id, name: $0.id, modelIds: $0.models)
        }
        let svc = OrchestraService(config: config, store: store,
                                   registry: registry ?? AgentRegistry(adapters: [adapter] + extras),
                                   worktrees: wtRegistry, sessions: sessions, trust: trust, inbox: inbox,
                                   grantResolver: grantResolver,
                                   watchStore: WatchRegistryStore(path: base + "/watch-registry.json"),
                                   clock: clock, proc: proc ?? Self.defaultFakeProc(),
                                   gitRemotesProbe: OrchestraService.defaultGitRemotesProbe)
        return (svc, sessions, worktrees, adapter, trust, PathResolver.canonical(base))
    }

    /// Rebuild a fresh service over the SAME on-disk stores as an earlier `make()` — simulates a daemon
    /// restart (in-memory timers/loops are gone; the file-backed store/inbox/trust reload from disk).
    /// Pass the canonical `base` that `make()` returned: `make` writes those files under the non-canonical
    /// `NSTemporaryDirectory()` prefix, which is the same inode via the macOS `/var → /private/var` symlink,
    /// so this reads exactly the files `make` wrote. Non-path knobs (revival tuning) reset to defaults —
    /// itself a realistic "fresh daemon" trait.
    static func remake(base: String, capabilities: AgentCapabilities = .stub,
                       proc: (any ProcRunning)? = nil)
        -> (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String) {
        let config = Config(reposRoot: base + "/repos",
                            worktreesRoot: base + "/worktrees",
                            allowlist: [base], sessionLaunchTimeout: 3600,
                            scratchRoot: base + "/scratch", runtimeStateDir: base + "/state")
        let sessions = StubSessions()
        let worktrees = StubWorktrees(root: config.worktreesRoot)
        let wtRegistry = WorktreeRegistry(config: config, manager: worktrees,
                                          borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")
        let adapter = StubAdapter(transcriptDir: base + "/transcripts", capabilities: capabilities)
        let store = TaskStore(path: base + "/tasks.json")
        let trust = TrustLedger(path: base + "/trust-ledger.json")
        let inbox = Inbox(path: base + "/inbox.json")
        let svc = OrchestraService(config: config, store: store,
                                   registry: AgentRegistry(adapters: [adapter]),
                                   worktrees: wtRegistry, sessions: sessions, trust: trust, inbox: inbox,
                                   watchStore: WatchRegistryStore(path: base + "/watch-registry.json"),
                                   proc: proc ?? Self.defaultFakeProc(),
                                   gitRemotesProbe: OrchestraService.defaultGitRemotesProbe)
        return (svc, sessions, worktrees, adapter, trust, base)
    }

    /// Tier honesty (Task 10 flip): the DEFAULT git seam for a stub-wired service is a fresh FakeProc
    /// with the GitConfigEmulator pre-installed — never a real fork. A test that genuinely needs real
    /// git threads its own `proc:` (or uses `makeReal`, which keeps the OrchestraService RealProc
    /// default for the real-worktree tier). One fresh instance per call: no cross-test sharing.
    static func defaultFakeProc() -> any ProcRunning {
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        return fake
    }

    /// **Intent-only-archive migration helper (PR4b Task 4).** `archive` now records the intent
    /// (`→ archivedPending` + the `archived` Bool) and RETURNS; the reconciler's `TeardownStepper` runs the
    /// full duty list (kill / releaseBorrow / release / cancel debounces+watches / nudge-children) and flips
    /// `→ archivedComplete`. This archives THEN drives `reconcile()` until teardown completes — a behavior-
    /// preserving drop-in for the pre-flip synchronous `archive` that most tests used as SETUP.
    static func archiveAndTeardown(_ svc: OrchestraService, _ id: UUID, source: ActivitySource = .daemon) async throws {
        try await svc.archive(id, source: source)
        try await pollUntil {
            await svc.reconcile()
            return await svc.list(includeArchived: true).first { $0.id == id }?.phase.kind == .archivedComplete
        }
    }

    /// **Intent-only relaunch/reopen migration helper (PR4b Task 4).** `resume`/`restart`/`reopen`/`handoff`
    /// now record the intent (`→ .relaunching` or `→ .creatingWorktree`) and RETURN; the reconciler's steppers
    /// drive the walk to `.live`. This drives `reconcile()` until `id` is `.live`, hand-delivering the agent's
    /// readiness signal each transitional tick when `inject` is set (needed for AWAITING caps —
    /// `.sessionStartHook`/`.rolloutMeta`; harmless for the immediate `.relaunchLiveness` stub). Returns the
    /// live card.
    @discardableResult
    /// A `ControlClient` pointed at an IN-PROCESS test daemon, with deadlines sized for the test machine.
    ///
    /// `ControlClient`'s 15s call/probe defaults are a PRODUCT default: the right bound for a real daemon in
    /// its own process, answering a client on an idle box. A test daemon shares a machine oversubscribed by
    /// the whole `--parallel` suite (900 tests, thousands of git/tmux forks), where even a trivial `version`
    /// reply — which never touches the service actor — waits tens of seconds for a thread. Inheriting the
    /// product default therefore makes every round-trip test a wall-clock assertion about the HOST, and it
    /// fails as `daemon did not answer version probe (connection closed)`: the daemon is healthy, merely
    /// descheduled. Deadlines are client POLICY (see `CLIRunner.rpcTimeout`, which exposes the same knob to
    /// the real CLI for a loaded host) — so give the in-process tests room and let them assert behavior.
    static func controlClient(_ socketPath: String, source: ActivitySource) -> ControlClient {
        ControlClient(socketPath: socketPath, source: source,
                      callTimeout: .seconds(120), probeTimeout: .seconds(120))
    }

    /// Spawn, drive to `.live`, and leave the card STILL STARTUP-PENDING — with a grace the spawn cannot
    /// outlive.
    ///
    /// `spawnPending[id]` bakes its deadline at ARM time (`Date() + spawnGraceSeconds`, inside the spawn), so
    /// raising the grace afterwards CANNOT re-arm an existing deadline — the widespread
    /// `spawnAndAwaitLive(…)` then `setStartupConfirmation(graceSeconds: …)` order was arming the default 4s
    /// and only *then* asking for a longer one. And `spawnAndAwaitLive` itself polls `reconcile()`, which
    /// folds in the liveness pass: under `--parallel` load the spawn routinely outlives its own 4s deadline,
    /// so `confirmSpawnStartup` sees `.alive` past-deadline and GRADUATES the card (`clearSpawnPending`).
    /// A later `setPaneDead` is then classified `.sessionVanished` rather than `.spawnExitedImmediately`,
    /// and the test fails asserting a product behavior that never had a chance to run.
    ///
    /// Arming a grace the spawn cannot outlive makes these tests about the BEHAVIOR (how an abort is
    /// classified) instead of about whether the machine was fast enough. Tests that need the retry's or the
    /// graduation's deadline to be in the PAST set `graceSeconds: 0` AFTER this call — that re-arms on the
    /// retry, which is exactly the deadline they mean.
    static func spawnStartupPending(_ svc: OrchestraService, _ input: SpawnInput,
                                    maxRetries: Int = 1) async throws -> Task {
        await svc.setStartupConfirmation(graceSeconds: 3600, maxRetries: maxRetries)
        return try await spawnAndAwaitLive(svc, input)
    }

    /// Drive the reconciler until `id` is `.live`. On timeout, re-read the card and say what phase it was
    /// ACTUALLY stuck in — "never reached .live" is useless on its own; "stuck in .dead(.agentExited)" names
    /// the bug. A card that lands `.dead` will never reach `.live`, so the wait was doomed, not merely slow.
    static func reconcileToLive(_ svc: OrchestraService, _ id: UUID, inject: Bool = false) async throws -> Task {
        do {
            try await pollUntilInner(svc, id, inject: inject)
        } catch let e as PollTimeout {
            let card = await svc.list(includeArchived: true).first { $0.id == id }
            let phase = card.map { "\($0.phase.kind)\($0.deadReason.map { r in "(\(r))" } ?? "")" } ?? "<no such card>"
            throw PollTimeout(what: "\(e.what) — card was stuck in phase: \(phase)", waited: e.waited, polls: e.polls)
        }
        guard let live = await svc.list(includeArchived: true).first(where: { $0.id == id }) else {
            throw OrchestraError.unknownTask(id.uuidString)
        }
        return live
    }

    private static func pollUntilInner(_ svc: OrchestraService, _ id: UUID, inject: Bool) async throws {
        try await pollUntil("card \(id) to reconcile to .live (inject: \(inject))") {
            await svc.reconcile()
            let card = await svc.list(includeArchived: true).first { $0.id == id }
            // Deliver the readiness signal only once the stepper's finishLaunch has REGISTERED its waiter
            // (not merely on phase kind): a signal delivered before the waiter exists is dropped by
            // finishLaunch's "start clean" pendingReadiness.remove, and under parallel-suite load the
            // off-actor step can lag the phase write — the race behind the reopen/relaunch flakes.
            if inject, await svc.hasReadinessWaiter(id), let k = card?.phase.kind {
                if k == .relaunching { try? await svc.report(id, StatusReport(sessionSource: "resume")) }
                else if k == .launching { try? await svc.report(id, StatusReport(sessionSource: "startup")) }
            }
            return card?.phase.kind == .live
        }
    }

    /// Make a repo dir under reposRoot and return its path.
    static func repo(_ base: String, _ name: String = "app") -> String {
        let p = base + "/repos/" + name
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// **Non-blocking-spawn migration helper (PR4b Task 3).** `spawn` now returns a `.creatingWorktree`
    /// card; the reconciler's steppers (Materialize → Launch) drive it to `.live`. This spawns then drives
    /// `reconcile()` in a poll loop (~2s cap) until the card is `.live`, returning it — a behavior-preserving
    /// drop-in for the pre-flip synchronous `spawn` that most tests used purely as SETUP.
    ///
    /// Readiness-cap contract: the DEFAULT stub adapter is `.relaunchLiveness` (readiness = a successful
    /// `ensure`, immediate — the reconcile ticks alone suffice). For an AWAITING cap
    /// (`.sessionStartHook`/`.rolloutMeta`) the N=3 `launchReadyTicks` fallback (now `inFlightSteps`-
    /// independent, per Task 2 finding 2) resolves the launch waiter within three ticks, so this STILL
    /// converges with no hand-delivered signal. Use `spawnAwaited` when a test must exercise the agent's
    /// OWN readiness signal deterministically (it injects `report(sessionSource:)`).
    @discardableResult
    static func spawnAndAwaitLive(_ svc: OrchestraService, _ input: SpawnInput,
                                 source: ActivitySource = .daemon) async throws -> Task {
        let created = try await svc.spawn(input, source: source)
        do {
            try await pollUntil("spawned card \(created.id) to reach .live") {
                await svc.reconcile()
                return await svc.list(includeArchived: true).first { $0.id == created.id }?.phase.kind == .live
            }
        } catch let e as PollTimeout {
            // Say what phase it got STUCK in — "never reached .live" alone names no bug.
            let card = await svc.list(includeArchived: true).first { $0.id == created.id }
            let phase = card.map { "\($0.phase.kind)\($0.deadReason.map { r in "(\(r))" } ?? "")" } ?? "<no such card>"
            throw PollTimeout(what: "\(e.what) — card was stuck in phase: \(phase)", waited: e.waited, polls: e.polls)
        }
        guard let live = await svc.list(includeArchived: true).first(where: { $0.id == created.id }) else {
            throw OrchestraError.unknownTask(created.id.uuidString)
        }
        return live
    }

    /// Spawn through the AWAITING launch path and reach `.live` by hand-delivering the agent's readiness
    /// signal. `spawn` persists the card at `.creatingWorktree`; this drives `reconcile()` (Materialize →
    /// Launch), and each tick the card is `.launching` with a pending waiter it delivers
    /// SessionStart(startup) so an awaiting cap (`.sessionStartHook`/`.rolloutMeta`) confirms on its OWN
    /// signal (not the N=3 fallback). Returns the live card. Use for resume/relaunch-mechanics tests that
    /// need `.claudeCode`/`.codex` but still want a deterministically-live card first.
    @discardableResult
    static func spawnAwaited(_ svc: OrchestraService, _ input: SpawnInput,
                            source: ActivitySource = .daemon) async throws -> Task {
        let created = try await svc.spawn(input, source: source)
        try await pollUntil {
            await svc.reconcile()
            let card = await svc.list(includeArchived: true).first { $0.id == created.id }
            // Deliver on WAITER-REGISTERED, not phase kind (see reconcileToLive): avoids the
            // pendingReadiness-clear race that flakes under parallel-suite contention.
            if await svc.hasReadinessWaiter(created.id) {
                try? await svc.report(created.id, StatusReport(sessionSource: "startup"))
            }
            return card?.phase.kind == .live
        }
        guard let live = await svc.list(includeArchived: true).first(where: { $0.id == created.id }) else {
            throw OrchestraError.unknownTask(created.id.uuidString)
        }
        return live
    }

    /// Drive being-born cards to `.live` via the reconciler: repeatedly run `reconcile()` (steps
    /// Materialize → Launch, N=3 liveness fallback) until at least `count` cards are live. Used by Codex
    /// (`.rolloutMeta`) spawn setups whose fixture rollout cannot bind during launch. A fallback card keeps
    /// its durable launch cutoff until discovery binds one unambiguous, post-cutoff rollout for telemetry.
    static func reconcileUntilLive(_ svc: OrchestraService, count: Int) async throws {
        try await pollUntil {
            await svc.reconcile()
            return await svc.list().filter { $0.phase.kind == .live }.count >= count
        }
    }

    /// A service wired with the REAL worktree manager (git worktrees actually cut, via the registry) —
    /// needed for the remote-tier tests, where a spawn's start-point must resolve against a real fetched
    /// ref. Everything else (store/trust/inbox/adapter) is stubbed as in `make`. Returns the service + its
    /// allowlisted base (the git working repo + its bare origin are created UNDER `base` by `makeRemoteRepo`).
    static func makeReal(capabilities: AgentCapabilities = .stub)
        -> (svc: OrchestraService, sessions: StubSessions, adapter: StubAdapter, base: String) {
        let base = PathResolver.canonical(NSTemporaryDirectory() + "orch-rsvc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: base + "/repos", withIntermediateDirectories: true)
        let config = Config(reposRoot: base + "/repos",
                            worktreesRoot: base + "/worktrees",
                            allowlist: [base], sessionLaunchTimeout: 3600,
                            scratchRoot: base + "/scratch", runtimeStateDir: base + "/state")
        let resolver = PathResolver(config: config)
        let sessions = StubSessions()
        let adapter = StubAdapter(transcriptDir: base + "/transcripts", capabilities: capabilities)
        let store = TaskStore(path: base + "/tasks.json")
        let trust = TrustLedger(path: base + "/trust-ledger.json")
        let inbox = Inbox(path: base + "/inbox.json")
        let worktrees = WorktreeRegistry(config: config, resolver: resolver,
                                         borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")
        let svc = OrchestraService(config: config, store: store,
                                   registry: AgentRegistry(adapters: [adapter]),
                                   worktrees: worktrees, sessions: sessions, resolver: resolver,
                                   trust: trust, inbox: inbox,
                                   proc: RealProc(), gitRemotesProbe: OrchestraService.defaultGitRemotesProbe)
        return (svc, sessions, adapter, base)
    }

    /// Wrap a stub worktree manager in a registry with test-local (base-relative) borrows/markers paths.
    /// For the handful of direct `OrchestraService(config:…, worktrees:)` constructions that don't go
    /// through `make`/`remake`/`makeReal` (Codex/Readiness fixtures) — a bare `StubWorktrees` no longer
    /// satisfies the `worktrees:` parameter now that it's typed `WorktreeRegistry?`.
    static func registry(_ stub: StubWorktrees, base: String, config: Config) -> WorktreeRegistry {
        WorktreeRegistry(config: config, manager: stub,
                         borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")
    }
}
