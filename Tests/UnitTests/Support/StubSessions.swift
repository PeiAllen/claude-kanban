import Foundation
import TestSupport
@testable import OrchestraCore

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
