# Spawn Startup-Abort Classification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A freshly-spawned agent that exits within its first few seconds is classified as a distinct, diagnosable, self-healing **startup abort** (captured stderr + bounded auto-retry) instead of a silent permanent `dead(sessionVanished)` with no detail.

**Architecture:** The fix lives entirely at the `SessionManager.ensure` + `reconcileLiveness` seam and is agent-agnostic (no `if agent==…`). Spawn turns on tmux `remain-on-exit` for the agent window and records the card as **startup-pending** with a short grace deadline. The existing 2-second `reconcileLiveness` poll (which spawn's `recovering` guard already skips during the create→ensure window) grows a startup-pending branch: it inspects the agent **pane** (not just session presence). A *pane that died while the session persists* (only possible because `remain-on-exit` kept it) is an unambiguous startup abort → capture the pane's final output as `deadDetail`, bounded-retry the launch, or mark `dead(.spawnExitedImmediately)`. A card that survives to its deadline **graduates** (remain-on-exit back off → normal mid-run liveness restored). A fully-*gone* session is left to the existing `sessionVanished` path, so a genuine mid-run crash is unchanged.

**Tech Stack:** Swift 6, swift-testing (`@Test`), tmux control verbs via `Process`.

## Global Constraints

- Agent-agnostic: NO `if agent == "codex"` / `"claude"` branches. Ride capability/adapter seams. (project CLAUDE.md)
- Do NOT touch codex auth/binary/infra. Tests must not spawn real agents — use `StubSessions`/`StubAdapter`.
- `lifecycle-convergence` redesign has **NOT** landed on main (still in `design/impl/orch lifecycle-convergence` branches; main's `DeadReason` still has only 4 cases). Implement cleanly on main; leave a reconciliation note.
- `Config` is Codable and `ConfigStore.load` falls back to **all-defaults on any decode failure** — so do NOT add new non-optional persisted `Config` fields (an old config.json would silently reset every setting). Tuning knobs go on `OrchestraService` as non-persisted injectable `var`s (the established `remoteWatchIntervals` / `mergeRequestNudgeInterval` pattern).
- Keep the `recovering` guard's create→ensure window intact; do NOT hold the card in `recovering` across the whole grace (that would no-op an immediate `send` at wake gate A). Startup-pending is a *separate* set from `recovering`.

## File Structure

- `Sources/OrchestraKit/Model.swift` — add `.spawnExitedImmediately` to `DeadReason`.
- `Sources/OrchestraCore/Protocols.swift` — extend `SessionManaging` with `agentPaneState` + `setRemainOnExit` (default impls so only real + stub conform); add `PaneLiveness` enum.
- `Sources/OrchestraCore/SessionManager.swift` — real tmux impls of `agentPaneState` (via `list-panes … #{pane_dead}`) + `setRemainOnExit` (via `set-option -w … remain-on-exit`).
- `Sources/OrchestraCore/OrchestraService.swift` — startup-pending state (`spawnPending`/`spawnAttempts`/`spawnRelaunch`), tuning knobs, test setter; spawn arms remain-on-exit + records pending after `ensure`.
- `Sources/OrchestraCore/OrchestraService+Recovery.swift` — `reconcileLiveness` startup-pending branch; `confirmSpawnStartup` + `handleStartupAbort` + `startupEvidence`; clear pending in `markDead`.
- `App/Views/RecoveryView.swift`, `App-iOS/Views/CardDetail/RecoveryView.swift` — add the new `DeadReason` case to the `whyLine` switch (compile-forced parity).
- `Tests/OrchestraCoreTests/Stubs.swift` — `StubSessions` pane-death modeling (`setPaneDead`, `setPaneText`, `agentPaneState`, `setRemainOnExit`).
- `Tests/OrchestraCoreTests/StartupAbortTests.swift` — new suite (the 4 required tests + agent-agnostic parametrization).

---

### Task 1: New `DeadReason` case + UI copy parity

**Files:**
- Modify: `Sources/OrchestraKit/Model.swift:30-35`
- Modify: `App/Views/RecoveryView.swift:16-24`
- Modify: `App-iOS/Views/CardDetail/RecoveryView.swift:30-38`

**Interfaces:**
- Produces: `DeadReason.spawnExitedImmediately`.

- [ ] **Step 1: Add the enum case**

```swift
public enum DeadReason: String, Codable, Sendable {
    case agentExited       // SessionEnd reason exit/logout — the agent quit (mid-life, usually resumable)
    case sessionVanished   // poll liveness reconcile: tmux session gone, no SessionEnd (crash / `tmux kill`)
    case spawnExitedImmediately  // agent exited during its startup grace — a launch abort (captured in deadDetail)
    case rebootUnrevived   // reboot sweep couldn't auto-revive (no id / transcript gone / resume failed at boot)
    case resumeFailed      // a `resume` attempt (auto or user "Try resume") failed — see `deadDetail`
}
```

- [ ] **Step 2: Desktop RecoveryView copy** — add to `whyLine` switch (`App/Views/RecoveryView.swift`), surfacing `deadDetail` like `.resumeFailed`:

```swift
        case .spawnExitedImmediately:
            return "The agent exited right after launching." + (task.deadDetail.map { " \($0)" } ?? "")
```

- [ ] **Step 3: iOS RecoveryView copy** — same case in `App-iOS/Views/CardDetail/RecoveryView.swift`:

```swift
        case .spawnExitedImmediately:
            return "The agent exited right after launching." + (task.deadDetail.map { " \($0)" } ?? "")
```

- [ ] **Step 4: Build** — `swift build` (Kit compiles; the two app switches are compile-forced but only built by `scripts/build-app.sh`, run later). Expected: PASS.

- [ ] **Step 5: Commit** — `feat(model): add DeadReason.spawnExitedImmediately + recovery copy`

---

### Task 2: `SessionManaging` pane-liveness + remain-on-exit primitives

**Files:**
- Modify: `Sources/OrchestraCore/Protocols.swift`
- Modify: `Sources/OrchestraCore/SessionManager.swift`

**Interfaces:**
- Produces: `enum PaneLiveness { case alive, dead, gone }`; `func agentPaneState(_ name: String) throws -> PaneLiveness`; `func setRemainOnExit(_ name: String, window: String, on: Bool) throws`.
- `.dead` = session present but the agent pane's process exited (only observable with remain-on-exit ON). `.gone` = session absent. `.alive` = pane running.

- [ ] **Step 1: Protocol additions + safe defaults** (`Protocols.swift`)

```swift
/// Liveness of a card's `agent` pane, finer-grained than session presence. `.dead` (pane process
/// exited but the session persists) is only observable when `remain-on-exit` is ON — it is the
/// signal that distinguishes a startup abort from a genuine session vanish.
public enum PaneLiveness: Sendable { case alive, dead, gone }

// add to `protocol SessionManaging`:
    func agentPaneState(_ name: String) throws -> PaneLiveness
    func setRemainOnExit(_ name: String, window: String, on: Bool) throws
```

```swift
// add to `public extension SessionManaging` (defaults so only the real manager + StubSessions override):
    /// Default: session-presence only (never reports `.dead`) — a conformer without pane introspection.
    func agentPaneState(_ name: String) throws -> PaneLiveness {
        (try? isAlive(name)) == true ? .alive : .gone
    }
    func setRemainOnExit(_ name: String, window: String, on: Bool) throws {}
```

- [ ] **Step 2: Real tmux impls** (`SessionManager.swift`, near `capture`/`kill`)

```swift
    /// Set `remain-on-exit` on a window so a process that exits leaves its dead pane (and final output)
    /// in place instead of tmux destroying the window/session. Armed on the `agent` window during the
    /// spawn startup grace so an immediate abort's stderr survives for capture; cleared on graduation.
    public func setRemainOnExit(_ name: String, window: String = "agent", on: Bool) throws {
        guard window == "agent" || Self.isValidShellWindowName(window) else {
            throw OrchestraError.invalidParams("invalid window name: \(window)")
        }
        _ = try tmux(["set-option", "-w", "-t", "\(name):\(window)", "remain-on-exit", on ? "on" : "off"])
    }

    /// Liveness of the `agent` pane. `.gone` when the session is absent; otherwise `.dead` iff the pane's
    /// process has exited (`#{pane_dead}` == 1, requires remain-on-exit), else `.alive`. Used by the
    /// startup-abort reconcile to tell an immediate launch abort from a healthy just-spawned agent.
    public func agentPaneState(_ name: String) throws -> PaneLiveness {
        guard try isAlive(name) else { return .gone }
        let r = try tmux(["list-panes", "-t", "\(name):agent", "-F", "#{pane_dead}"])
        guard r.ok else { return .gone }
        let dead = r.stdout.split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "1" }
        return dead ? .dead : .alive
    }
```

- [ ] **Step 3: Build** — `swift build`. Expected: PASS (existing conformers get the defaults; `StubSessions` still compiles via defaults until Task 4).

- [ ] **Step 4: Commit** — `feat(session): pane-liveness + remain-on-exit tmux primitives`

---

### Task 3: Startup-pending state + spawn arming

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (properties ~L96 near `recovering`; init/spawn ~L403-422)

**Interfaces:**
- Produces on the actor: `var spawnPending: [UUID: Date]`, `var spawnAttempts: [UUID: Int]`, `var spawnRelaunch: [UUID: (adapterId: String, ctx: AdapterContext)]`, `var spawnGraceSeconds: Int = 4`, `var maxStartupRetries: Int = 1`, `func setStartupConfirmation(graceSeconds: Int, maxRetries: Int)`.
- Consumed by Task 5 (`reconcileLiveness`/`confirmSpawnStartup`).

- [ ] **Step 1: Add actor state** (below `var recovering: Set<UUID> = []`)

```swift
    // Startup-abort confirmation (spawn only). A freshly-spawned card is tracked here with a grace
    // DEADLINE until it proves it survived launch; the liveness reconcile inspects its agent pane and
    // classifies an immediate exit as `.spawnExitedImmediately` (with captured stderr + bounded retry)
    // rather than a generic `.sessionVanished`. Separate from `recovering` so an immediate `send` still
    // wakes the card (recovering would no-op wake gate A). Cleared on graduation / give-up / markDead.
    var spawnPending: [UUID: Date] = [:]
    var spawnAttempts: [UUID: Int] = [:]
    var spawnRelaunch: [UUID: (adapterId: String, ctx: AdapterContext)] = [:]
    /// Non-persisted tuning (short in tests). `spawnGraceSeconds` = how long a spawned card is watched
    /// for an immediate exit before it graduates; `maxStartupRetries` = bounded auto-respawns first.
    var spawnGraceSeconds: Int = 4
    var maxStartupRetries: Int = 1
```

- [ ] **Step 2: Test setter** (near the other test-injection knobs / helpers)

```swift
    /// Test hook: tighten the startup-confirmation grace + retry budget (production uses the defaults).
    func setStartupConfirmation(graceSeconds: Int, maxRetries: Int) {
        spawnGraceSeconds = graceSeconds; maxStartupRetries = maxRetries
    }
```

- [ ] **Step 3: Arm remain-on-exit + record pending in spawn** — after the existing `try sessions.ensure(created, argv: adapter.start(ctx), env: adapter.env)` (OrchestraService.swift ~L422), BEFORE `emit(.taskUpserted(created))`:

```swift
        // Startup-abort watch: keep the dying pane's output for capture, and mark the card
        // startup-pending so the liveness reconcile classifies an immediate exit distinctly + retries.
        try? sessions.setRemainOnExit(sessions.sessionName(id), window: "agent", on: true)
        spawnPending[id] = Date().addingTimeInterval(Double(spawnGraceSeconds))
        spawnAttempts[id] = 0
        spawnRelaunch[id] = (adapter.id, ctx)
```

Note: the existing `recovering.insert(id)` / `defer { recovering.remove(id) }` block is left exactly as-is (it still guards create→ensure). `spawnPending` is set while `recovering` is still held; `recovering` is dropped on return, `spawnPending` persists until graduation/give-up.

- [ ] **Step 4: Build** — `swift build`. Expected: PASS.

- [ ] **Step 5: Commit** — `feat(spawn): arm remain-on-exit + record startup-pending`

---

### Task 4: `StubSessions` pane-death modeling

**Files:**
- Modify: `Tests/OrchestraCoreTests/Stubs.swift` (`StubSessions`)

**Interfaces:**
- Produces (test-only): `func setPaneDead(_ id: UUID)`, `func setPaneText(_ id: UUID, _ text: String)`, plus `agentPaneState`/`setRemainOnExit` overrides + `remainOnExit` recording. A `setPaneDead` session stays in `alive` (so `list()`/`isAlive` still see it — session present) but reports pane `.dead`; `ensure` (fresh launch) clears the dead mark; `kill` clears both.

- [ ] **Step 1: Add pane state + overrides** to `StubSessions`

```swift
    private var deadPanes: Set<String> = []       // sessions whose agent pane process exited (remain-on-exit)
    private var paneText: [String: String] = [:]  // canned capture-pane text per session (the "stderr")
    private(set) var remainOnExit: [String: Bool] = [:]

    /// Simulate an immediate startup abort: the agent pane's process exited, but remain-on-exit keeps the
    /// session present with a dead pane (the state a real startup abort leaves behind).
    func setPaneDead(_ id: UUID) {
        lock.lock(); deadPanes.insert(sessionName(id)); lock.unlock()
    }
    /// Canned final pane output (the dying process's stderr) returned by `capture` for this session.
    func setPaneText(_ id: UUID, _ text: String) {
        lock.lock(); paneText[sessionName(id)] = text; lock.unlock()
    }
    func setRemainOnExit(_ name: String, window: String, on: Bool) throws {
        lock.lock(); remainOnExit[name] = on; lock.unlock()
    }
    func agentPaneState(_ name: String) throws -> PaneLiveness {
        lock.lock(); defer { lock.unlock() }
        if !alive.contains(name) { return .gone }
        return deadPanes.contains(name) ? .dead : .alive
    }
```

- [ ] **Step 2: Fresh `ensure` clears the dead mark** — in `StubSessions.ensure`, where it does `alive.insert(name)`, also `deadPanes.remove(name)` (a relaunch re-mints a live pane):

```swift
        lock.lock(); curConcurrentEnsure -= 1; alive.insert(name); deadPanes.remove(name); ensureArgv[name] = argv; ensureEnv[name] = env; lock.unlock()
```

- [ ] **Step 3: `kill` clears pane state; `capture` returns canned text** — in `kill` add `deadPanes.remove(name); paneText[name] = nil`; make `capture` prefer the canned text:

```swift
    func capture(_ name: String, window: String, maxChars: Int) throws -> CaptureResult {
        guard try isAlive(name) else { throw OrchestraError.io("session not alive: \(name)") }
        lock.lock(); let canned = paneText[name]; lock.unlock()
        let text = canned ?? "stub-pane:\(name):\(window)"
        return CaptureResult(window: window, text: String(text.prefix(maxChars)), truncated: false)
    }
```

- [ ] **Step 4: Build tests** — `swift build --build-tests`. Expected: PASS.

- [ ] **Step 5: Commit** — `test(stubs): model agent-pane death + canned capture in StubSessions`

---

### Task 5: `reconcileLiveness` startup-pending branch + confirm/retry/evidence

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Recovery.swift` (`reconcileLiveness` ~L236; `markDead` ~L298; new helpers)

**Interfaces:**
- Consumes: `spawnPending`, `spawnAttempts`, `spawnRelaunch`, `spawnGraceSeconds`, `maxStartupRetries` (Task 3); `agentPaneState`/`setRemainOnExit`/`capture` (Task 2); `DeadReason.spawnExitedImmediately` (Task 1).

- [ ] **Step 1: Reconcile branch** — replace the `reconcileLiveness` loop body:

```swift
    public func reconcileLiveness() async {
        let tasks = await store.all()
        let aliveNames = Set((try? sessions.list())?.map(\.name) ?? [])
        for t in tasks where !t.archived && t.status != .dead && t.status != .done {
            if recovering.contains(t.id) { continue }
            if let deadline = spawnPending[t.id] {
                await confirmSpawnStartup(t, deadline: deadline)   // startup-abort classification + graduation
                continue
            }
            if !aliveNames.contains(sessions.sessionName(t.id)) {
                await markDead(t.id, reason: .sessionVanished, detail: nil, source: .daemon)
            }
        }
    }
```

- [ ] **Step 2: `confirmSpawnStartup`** — the startup-pending state machine (add near `reconcileLiveness`):

```swift
    /// Resolve a startup-pending card. Inspects the `agent` pane (remain-on-exit keeps a dead one visible):
    ///  • `.alive` past its deadline → GRADUATE: clear remain-on-exit + drop pending (normal monitoring).
    ///  • `.alive` before its deadline → keep watching.
    ///  • `.dead` (session present, pane exited) → STARTUP ABORT → capture + bounded retry / mark dead.
    ///  • `.gone` (session absent — killed or a lost remain-on-exit race) → hand to the normal
    ///    `.sessionVanished` path (revivable), NOT a startup abort.
    func confirmSpawnStartup(_ t: Task, deadline: Date) async {
        let id = t.id
        let name = sessions.sessionName(id)
        let state = (try? await offActor { [sessions] in try sessions.agentPaneState(name) }) ?? .gone
        switch state {
        case .alive:
            guard Date() >= deadline else { return }   // still within grace — keep watching
            try? await offActor { [sessions] in try? sessions.setRemainOnExit(name, window: "agent", on: false) }
            clearSpawnPending(id)
        case .dead:
            await handleStartupAbort(t)
        case .gone:
            clearSpawnPending(id)
            await markDead(id, reason: .sessionVanished, detail: nil, source: .daemon)
        }
    }

    /// A startup abort: capture the dying pane's final output as evidence, then bounded-retry the launch
    /// (an immediate exit is usually a transient launch hiccup) or give up with `.spawnExitedImmediately`.
    private func handleStartupAbort(_ t: Task) async {
        let id = t.id
        let name = sessions.sessionName(id)
        let evidence = (try? await offActor { [sessions] in
            (try? sessions.capture(name, window: "agent", maxChars: 4096))?.text
        }).flatMap { Self.startupEvidence(from: $0) }

        let attempt = spawnAttempts[id] ?? 0
        if attempt < maxStartupRetries, let spec = spawnRelaunch[id], let adapter = try? registry.get(spec.adapterId) {
            spawnAttempts[id] = attempt + 1
            try? adapter.prepareToLaunch(spec.ctx)
            let env = adapter.env
            let argv = adapter.start(spec.ctx)
            let launchTask = t
            do {
                try await offActor { [sessions] in
                    _ = try sessions.kill(name)                      // reap the dead-pane session
                    _ = try sessions.ensure(launchTask, argv: argv, env: env)
                    try? sessions.setRemainOnExit(name, window: "agent", on: true)
                }
                spawnPending[id] = Date().addingTimeInterval(Double(spawnGraceSeconds))
                emitActivity(.recovered, t, .daemon, "restarted “\(t.title)” after a startup abort (retry \(attempt + 1))")
                return
            } catch {
                clearSpawnPending(id)
                await markDead(id, reason: .spawnExitedImmediately, detail: evidence ?? "\(error)", source: .daemon)
                return
            }
        }
        // Out of retries → give up. Reap the dead-pane session, then mark dead WITH evidence.
        clearSpawnPending(id)
        try? await offActor { [sessions] in try? sessions.kill(name) }
        await markDead(id, reason: .spawnExitedImmediately, detail: evidence, source: .daemon)
    }

    func clearSpawnPending(_ id: UUID) {
        spawnPending[id] = nil; spawnAttempts[id] = nil; spawnRelaunch[id] = nil
    }

    /// Distil captured pane text to the meaningful tail (last few non-empty lines), trimmed + capped, so
    /// `deadDetail` surfaces the real error ("usage limit", "unauthorized", a config parse error) not noise.
    static func startupEvidence(from pane: String) -> String? {
        let lines = pane.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return String(lines.suffix(6).joined(separator: " | ").prefix(500))
    }
```

- [ ] **Step 3: Clear pending on death** — in `markDead`, after the successful `store.update`, add `clearSpawnPending(id)` so a card dead for any reason drops its startup-pending bookkeeping:

```swift
    func markDead(_ id: UUID, reason: DeadReason, detail: String?, source: ActivitySource) async {
        guard let updated = try? await store.update(id, {
            $0.status = .dead; $0.deadReason = reason; $0.deadDetail = detail
        }) else { return }
        clearSpawnPending(id)
        emit(.taskUpserted(updated))
        emitActivity(.dead, updated, source, "session lost (\(reason.rawValue))")
    }
```

- [ ] **Step 4: Build** — `swift build`. Expected: PASS.

- [ ] **Step 5: Commit** — `feat(recovery): classify + retry spawn startup aborts in reconcileLiveness`

---

### Task 6: Tests — the four required scenarios + agent-agnostic parametrization

**Files:**
- Create: `Tests/OrchestraCoreTests/StartupAbortTests.swift`

**Interfaces:**
- Consumes: `TestEnv.make`, `StubSessions.setPaneDead/setPaneText`, `svc.setStartupConfirmation`, `svc.reconcileLiveness`, `svc.spawn`.

- [ ] **Step 1: Write the suite (failing first — run before Task 1-5 land if executing pure-TDD; here we write after the seam exists and assert behavior).**

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("OrchestraService — spawn startup-abort classification")
struct StartupAbortTests {

    /// (i) An agent that exits immediately → dead with the NEW reason + non-empty detail, NOT sessionVanished.
    @Test("startup abort with no retries → dead(spawnExitedImmediately) + captured detail")
    func immediateExitClassified() async throws {
        let env = TestEnv.make(grace: 1)
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 0)   // no retry, deadline already past
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        env.sessions.setPaneText(t.id, "Error: usage limit reached\nprocess exited")
        env.sessions.setPaneDead(t.id)                                          // agent aborted (pane dead, session present)

        await env.svc.reconcileLiveness()

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.status == .dead)
        #expect(after.deadReason == .spawnExitedImmediately)
        #expect(after.deadReason != .sessionVanished)
        #expect(after.deadDetail?.isEmpty == false)
        #expect(after.deadDetail?.contains("usage limit") == true)
    }

    /// (ii) Auto-retry fires; the retry stays up → card ends alive (not dead), exactly one extra launch.
    @Test("startup abort then healthy retry → alive, one bounded re-spawn")
    func retryRecovers() async throws {
        let env = TestEnv.make(grace: 1)
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        let ensureAfterSpawn = env.sessions.ensureCount
        env.sessions.setPaneDead(t.id)                     // first launch aborts

        await env.svc.reconcileLiveness()                  // detects abort → retry (kill + fresh ensure → live pane)
        #expect(env.sessions.ensureCount == ensureAfterSpawn + 1)   // exactly one retry launch

        await env.svc.reconcileLiveness()                  // retry is alive + past deadline → graduate

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.status != .dead)
        #expect(after.deadReason == nil)
        // No worktree churn: retry reused the same session/cwd (StubWorktrees.ensured is spawn-only).
        #expect(env.worktrees.ensured.filter { $0.contains("#b") }.count == 1)
    }

    /// (iii) A genuine mid-session vanish (gone session, past startup) still → sessionVanished (no regression).
    @Test("graduated card that later vanishes → sessionVanished, not a startup abort")
    func midRunVanishStillSessionVanished() async throws {
        let env = TestEnv.make(grace: 1)
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))

        await env.svc.reconcileLiveness()                  // pane alive + deadline past → graduate (pending cleared)
        env.sessions.setAlive(t.id, false)                 // NOW it vanishes mid-run (session gone)
        await env.svc.reconcileLiveness()

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.status == .dead)
        #expect(after.deadReason == .sessionVanished)
    }

    /// (iv) Agent-agnostic: the SAME startup-abort path runs for a Claude-shaped and a Codex-shaped adapter
    /// (capability profiles differ; the classification does not). No `if agent==…` anywhere.
    @Test(arguments: [AgentCapabilities.claudeCode, AgentCapabilities.codex])
    func agentAgnostic(_ caps: AgentCapabilities) async throws {
        let env = TestEnv.make(grace: 1, capabilities: caps)
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 0)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        env.sessions.setPaneText(t.id, "unauthorized")
        env.sessions.setPaneDead(t.id)

        await env.svc.reconcileLiveness()

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.deadReason == .spawnExitedImmediately)
        #expect(after.deadDetail?.contains("unauthorized") == true)
    }
}
```

- [ ] **Step 2: Confirm `AgentCapabilities.codex` exists** — if the codex preset is named differently, adjust the `arguments:` array to the real presets. (Grep `AgentCapabilities` presets before running.)

- [ ] **Step 3: Run the suite** — `swift test --no-parallel --filter StartupAbortTests`. Expected: 4 (well, 5 with the parametrized pair) PASS.

- [ ] **Step 4: Full suite** — `swift test --no-parallel`. Expected: green, including the untouched `RecoveryTests.reconcile`, `SpawnRaceTests`, `WakeMergeWatchTests` (their `setAlive(false)` = *gone*, which routes to `sessionVanished`, so they are unaffected).

- [ ] **Step 5: Commit** — `test: cover spawn startup-abort classification, retry, no-regression, agent-agnostic`

---

### Task 7: App build + reconciliation note + review

- [ ] **Step 1: mac app build** — `scripts/build-app.sh`. Expected: PASS (both `RecoveryView` switches now exhaustive).
- [ ] **Step 2: Reconciliation note** — append a short note to `notes/designs/` (or the lifecycle-convergence design dir) recording that spawn-abort classification landed on main via `spawnPending` + `reconcileLiveness`, so the convergence reconciler can fold it into its funnel/epoch model.
- [ ] **Step 3: Code review** — superpowers:requesting-code-review (cost-efficient Claude + GPT); address findings.
- [ ] **Step 4: merge-request** up to `main`; `orchestra send 760000 "<status>"`.

---

## Self-Review

- **Spec coverage:** A) post-launch confirmation → Task 3 (arm) + Task 5 (`confirmSpawnStartup` grace/graduate). B) preserve evidence → Task 2 (`setRemainOnExit`/`agentPaneState`) + Task 5 (`capture`→`startupEvidence`→`deadDetail`). C) distinct classification + UI parity → Task 1. D) bounded retry, no double-create/worktree-leak, don't fight a kill → Task 5 (`handleStartupAbort` kills before re-ensure, reuses cwd; `reconcileLiveness` skips archived/dead/done; `.gone`→sessionVanished not retried). Agent-agnostic → Task 6 (iv). Coordination note → Task 7.
- **Placeholder scan:** none — every code step is complete.
- **Type consistency:** `PaneLiveness{alive,dead,gone}`, `agentPaneState`, `setRemainOnExit`, `spawnPending/spawnAttempts/spawnRelaunch`, `clearSpawnPending`, `startupEvidence`, `confirmSpawnStartup`, `handleStartupAbort`, `setStartupConfirmation` used consistently across Tasks 2/3/5/6.
- **Risk — `AgentCapabilities.codex`:** verify the exact preset name before Task 6 (Step 2 guards this).
- **Risk — retry deadline in tests:** with `graceSeconds: 0`, every reconcile tick re-evaluates immediately (deadline in the past), so the two-tick retry test is deterministic without sleeps.
