# E2 — authMode Soft-Warn Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement
> this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a card is brought up on an adapter whose `authMode` is `.subscription`, warn (advisory
only, **no cap**) once the number of concurrent subscription-auth cards on that same adapter exceeds a
threshold — the "heavy parallel fan-out on one subscription seat" pattern both providers' anti-automation
clauses target (SSOT §9 / D12; q4 resolved → **soft-warn only**).

**Architecture:** A new pure value type `AuthRateMonitor` owns the **per-adapter rate state** — it tallies
active subscription-auth cards grouped by `agentId` (each provider subscription is a separate seat, so
Claude and Codex fan-outs are counted independently) and returns an optional `AuthWarning` when a spawn
pushes an adapter's tally past `threshold`. `OrchestraService.spawn` calls it after creating the card and,
on a warning, emits an `ActivityKind.warning` activity (the existing board/CLI soft-warn surface). The
monitor **never** blocks or caps a spawn — it only produces an advisory message.

**Tech Stack:** Swift 6, swift-testing (`@Suite`/`@Test`/`#expect`/`#require`), `OrchestraCore` package.
Build/test via `./scripts/test.sh`; app typecheck via `./scripts/typecheck-app.sh`.

## Global Constraints

- **Soft-warn ONLY — NO concurrency cap.** The spawn always proceeds; the monitor returns an advisory
  message and never throws, blocks, queues, or rejects. (q4 resolved 2026-07-01; SSOT §9, D12.)
- **Rate state is per-adapter** (keyed by `agentId`). A subscription card on one adapter must never push a
  *different* adapter over its threshold — each subscription seat is an independent pool.
- **apiKey adapters never warn.** Only `capabilities.authMode == .subscription` cards count and can trigger.
- **Core degrades on capabilities, never on identity** — the monitor reads `adapter.capabilities.authMode`,
  never `if agentId == "claude-code"`.
- **Additions are defaulted / behavior-preserving.** `ActivityKind.warning` is an additive enum case;
  existing suites (`ReportTests`, `AdapterTests`, `RecoveryTests`, `CapabilitiesTests`) stay green unchanged.
- **Offline, no real vendor binaries.** `USE_REAL_CLAUDE` stays unset; tests use `StubAdapter`/`StubSessions`.
- Swift build/test needs an **UNSANDBOXED** shell (sandbox-exec `sandbox_apply` error → re-run with sandbox
  disabled). `typecheck-app.sh` may need `DEVELOPER_DIR=/Library/Developer/CommandLineTools`.

---

## File Structure

- **Create** `Sources/OrchestraCore/Agents/AuthRateMonitor.swift` — `AuthWarning` value type + `AuthRateMonitor`
  (pure, `Sendable`). Sole owner of the per-adapter rate-state computation + the warn decision.
- **Modify** `Sources/OrchestraCore/Model.swift` — add `.warning` to `ActivityKind`.
- **Modify** `Sources/OrchestraCore/OrchestraService.swift` — hold an `AuthRateMonitor`; call it in `spawn`
  and emit a `.warning` activity when it returns one.
- **Modify** `Tests/OrchestraCoreTests/Stubs.swift` — make `StubAdapter.id`/`name` constructor-configurable
  (default unchanged) so monitor tests can register multiple adapters with distinct ids + authModes.
- **Create** `Tests/OrchestraCoreTests/AuthRateMonitorTests.swift` — unit tests for the pure monitor
  (per-adapter tally + warn trigger).
- **Create** `Tests/OrchestraCoreTests/AuthWarnSpawnTests.swift` — service-level tests that `spawn` emits the
  warning past threshold, stays silent under it, never warns for apiKey adapters, and **never caps**.

---

## Task 1: `AuthRateMonitor` + `AuthWarning` (the pure rate-state core)

**Files:**
- Create: `Sources/OrchestraCore/Agents/AuthRateMonitor.swift`
- Modify: `Tests/OrchestraCoreTests/Stubs.swift` (make `StubAdapter.id`/`name` configurable)
- Test: `Tests/OrchestraCoreTests/AuthRateMonitorTests.swift`

**Interfaces:**
- Consumes: `Task` (`agentId`), `AgentRegistry` (`get(_:) -> any Adapter`), `Adapter.capabilities.authMode`
  (`AgentCapabilities.AuthMode ∈ {subscription, apiKey}`) — all already defined.
- Produces (later tasks rely on these exact names/types):
  - `struct AuthWarning: Sendable, Equatable { let agentId: String; let agentName: String; let count: Int; let threshold: Int; var message: String { get } }`
  - `struct AuthRateMonitor: Sendable`
    - `static let defaultThreshold = 3`
    - `init(threshold: Int = AuthRateMonitor.defaultThreshold)`
    - `func subscriptionTally(active: [Task], registry: AgentRegistry) -> [String: Int]`
    - `func warning(for agentId: String, active: [Task], registry: AgentRegistry) -> AuthWarning?`

- [ ] **Step 1: Make `StubAdapter.id`/`name` configurable (prep so tests can register distinct adapters)**

In `Tests/OrchestraCoreTests/Stubs.swift`, change the `StubAdapter` fixed `id`/`name` to stored properties
with backward-compatible defaults, and set them in `init`:

```swift
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
    // ... rest of StubAdapter unchanged ...
```

(The previous `let id = "claude-code"` and `let name = "Stub"` lines are replaced by the stored
properties above; every existing call site omits `id`/`name`, so they keep the defaults.)

- [ ] **Step 2: Write the failing test file**

Create `Tests/OrchestraCoreTests/AuthRateMonitorTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("AuthRateMonitor — per-adapter subscription rate state (soft-warn, no cap)")
struct AuthRateMonitorTests {

    // Two adapters: a subscription one ("claude-code") and an apiKey one ("keyed"), distinct ids so the
    // registry can hold both and the monitor tallies each seat independently.
    static let subAdapter = StubAdapter(transcriptDir: NSTemporaryDirectory(),
                                        capabilities: .claudeCode, id: "claude-code", name: "Claude")
    static let apiKeyCaps = AgentCapabilities(
        sessionId: .discovered, telemetry: .fileTail, contextUsage: .tokens,
        wakeTransport: .sendKeys, inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed, authMode: .apiKey)
    static let keyAdapter = StubAdapter(transcriptDir: NSTemporaryDirectory(),
                                        capabilities: apiKeyCaps, id: "keyed", name: "Keyed")
    static let registry = AgentRegistry(adapters: [subAdapter, keyAdapter])

    /// A minimal active card on an adapter. Only `agentId` + `status`/`archived` matter to the monitor.
    static func card(_ agentId: String, status: AgentStatus = .running, archived: Bool = false) -> Task {
        var t = Task(title: "c", repo: "/r", branch: "b", cwd: "/c", agentId: agentId,
                     model: AgentModel(id: "m"), startIn: .impl, column: .impl, order: 0,
                     status: status, initialPrompt: "p")
        t.archived = archived
        return t
    }

    @Test("subscriptionTally counts subscription cards per adapter; excludes apiKey adapters")
    func tallyPerAdapter() {
        let mon = AuthRateMonitor()
        let active = [card("claude-code"), card("claude-code"), card("keyed"), card("keyed"), card("keyed")]
        let tally = mon.subscriptionTally(active: active, registry: Self.registry)
        #expect(tally["claude-code"] == 2)   // subscription seat counted
        #expect(tally["keyed"] == nil)        // apiKey adapter excluded entirely
    }

    @Test("no warning at or below threshold")
    func silentUnderThreshold() {
        let mon = AuthRateMonitor(threshold: 3)
        let active = [card("claude-code"), card("claude-code"), card("claude-code")]  // exactly 3
        #expect(mon.warning(for: "claude-code", active: active, registry: Self.registry) == nil)
    }

    @Test("warning fires when the subscription tally exceeds threshold")
    func warnsPastThreshold() throws {
        let mon = AuthRateMonitor(threshold: 3)
        let active = (0..<4).map { _ in card("claude-code") }  // 4 > 3
        let warn = try #require(mon.warning(for: "claude-code", active: active, registry: Self.registry))
        #expect(warn.agentId == "claude-code")
        #expect(warn.agentName == "Claude")
        #expect(warn.count == 4)
        #expect(warn.threshold == 3)
        #expect(warn.message.contains("Claude"))
    }

    @Test("apiKey adapter never warns, however many are running")
    func apiKeyNeverWarns() {
        let mon = AuthRateMonitor(threshold: 1)
        let active = (0..<10).map { _ in card("keyed") }
        #expect(mon.warning(for: "keyed", active: active, registry: Self.registry) == nil)
    }

    @Test("rate state is per-adapter: another seat's cards don't push this adapter over")
    func perAdapterIsolation() {
        let mon = AuthRateMonitor(threshold: 3)
        // 10 apiKey cards + only 2 subscription cards → subscription adapter is under its own threshold.
        let active = (0..<10).map { _ in card("keyed") } + [card("claude-code"), card("claude-code")]
        #expect(mon.warning(for: "claude-code", active: active, registry: Self.registry) == nil)
    }

    @Test("unknown agentId (not in registry) yields no warning and no tally entry")
    func unknownAgentSafe() {
        let mon = AuthRateMonitor(threshold: 0)
        let active = [card("ghost"), card("ghost")]
        #expect(mon.subscriptionTally(active: active, registry: Self.registry)["ghost"] == nil)
        #expect(mon.warning(for: "ghost", active: active, registry: Self.registry) == nil)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run (UNSANDBOXED): `./scripts/test.sh --filter AuthRateMonitorTests`
Expected: FAIL — `cannot find 'AuthRateMonitor' in scope` (and `AuthWarning`).

- [ ] **Step 4: Write the minimal implementation**

Create `Sources/OrchestraCore/Agents/AuthRateMonitor.swift`:

```swift
import Foundation

/// Advisory result of the authMode soft-warn: one adapter is running "too many" concurrent
/// subscription-auth cards. Carries the numbers so the surface (activity feed) can render a message.
/// This is **never** an error — q4 resolved to soft-warn only, with NO concurrency cap.
public struct AuthWarning: Sendable, Equatable {
    /// The adapter (subscription seat) the warning is about.
    public let agentId: String
    /// The adapter's display name, for the message.
    public let agentName: String
    /// Concurrent subscription-auth cards on this adapter (INCLUDING the card being brought up).
    public let count: Int
    /// The threshold `count` exceeded to trigger this warning.
    public let threshold: Int

    public init(agentId: String, agentName: String, count: Int, threshold: Int) {
        self.agentId = agentId; self.agentName = agentName; self.count = count; self.threshold = threshold
    }

    /// The human-readable advisory shown in the activity feed.
    public var message: String {
        "\(count) concurrent \(agentName) subscription agents running — heavy parallel fan-out on one "
        + "subscription seat can trip shared rate limits / anti-automation limits. "
        + "Consider API-key mode for large fan-outs (advisory only — not blocked)."
    }
}

/// Owns the **per-adapter rate state** for the authMode soft-warn (D12 / SSOT §9). It tallies active
/// subscription-auth cards grouped by `agentId` — each provider subscription is its own seat, so Claude
/// and Codex fan-outs are counted independently — and returns an `AuthWarning` when bringing up one more
/// card pushes that adapter's tally past `threshold`.
///
/// Pure and stateless: the "rate state" is DERIVED from the live card set (the SSOT), so it can't drift
/// and survives a daemon restart. It **never** caps — q4 resolved to warn-only; the caller always spawns.
public struct AuthRateMonitor: Sendable {
    /// Concurrent subscription cards (per adapter) that must be EXCEEDED to warn. `3` → the 4th+ warns.
    public static let defaultThreshold = 3

    public let threshold: Int
    public init(threshold: Int = AuthRateMonitor.defaultThreshold) { self.threshold = threshold }

    /// Whether an adapter is on subscription auth (only these count / can warn). Unknown ids → false.
    private func isSubscription(_ agentId: String, _ registry: AgentRegistry) -> Bool {
        (try? registry.get(agentId))?.capabilities.authMode == .subscription
    }

    /// Per-adapter count of active SUBSCRIPTION-auth cards. apiKey adapters (and unknown ids) are
    /// excluded entirely — they never appear in the tally.
    public func subscriptionTally(active: [Task], registry: AgentRegistry) -> [String: Int] {
        var tally: [String: Int] = [:]
        for t in active where isSubscription(t.agentId, registry) {
            tally[t.agentId, default: 0] += 1
        }
        return tally
    }

    /// The warn decision for `agentId`, given the current `active` card set (which MUST already include
    /// the card being brought up, so the tally reflects post-spawn concurrency). Returns nil for apiKey /
    /// unknown adapters, or when the tally does not exceed `threshold`. NEVER caps.
    public func warning(for agentId: String, active: [Task], registry: AgentRegistry) -> AuthWarning? {
        guard let adapter = try? registry.get(agentId),
              adapter.capabilities.authMode == .subscription else { return nil }
        let count = subscriptionTally(active: active, registry: registry)[agentId] ?? 0
        guard count > threshold else { return nil }
        return AuthWarning(agentId: agentId, agentName: adapter.name, count: count, threshold: threshold)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run (UNSANDBOXED): `./scripts/test.sh --filter AuthRateMonitorTests`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/Agents/AuthRateMonitor.swift \
        Tests/OrchestraCoreTests/AuthRateMonitorTests.swift \
        Tests/OrchestraCoreTests/Stubs.swift
git commit -m "feat(authmode): AuthRateMonitor — per-adapter subscription rate state + soft-warn (E2)"
```

---

## Task 2: Wire the warning into `spawn` (the soft-warn surface)

**Files:**
- Modify: `Sources/OrchestraCore/Model.swift` (add `ActivityKind.warning`)
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (hold `AuthRateMonitor`; emit in `spawn`)
- Test: `Tests/OrchestraCoreTests/AuthWarnSpawnTests.swift`

**Interfaces:**
- Consumes: `AuthRateMonitor` / `AuthWarning` (Task 1); `OrchestraService.spawn`, `store.all()`,
  `emitActivity(_:_:_:_:)`, `EventCollector` (existing test helper).
- Produces: a `.warning` `ActivityItem` on the event stream when a spawn crosses the threshold.

- [ ] **Step 1: Write the failing service-level test file**

Create `Tests/OrchestraCoreTests/AuthWarnSpawnTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("authMode soft-warn on spawn — advisory only, never caps")
struct AuthWarnSpawnTests {

    static let apiKeyCaps = AgentCapabilities(
        sessionId: .discovered, telemetry: .fileTail, contextUsage: .tokens,
        wakeTransport: .sendKeys, inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed, authMode: .apiKey)

    @Test("spawning past the default threshold emits a .warning activity; the spawn still succeeds (no cap)")
    func warnsPastThresholdAndStillSpawns() async throws {
        // Default StubAdapter caps = .claudeCode → subscription; default threshold = 3, so the 4th warns.
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let collector = EventCollector()
        await collector.start(env.svc.subscribe())

        var tasks: [Task] = []
        for i in 0..<4 { tasks.append(try await env.svc.spawn(SpawnInput(prompt: "p\(i)", repo: repo, branch: "b\(i)"))) }

        // No cap: all four cards were created and launched.
        #expect(tasks.count == 4)
        let launched = env.sessions.ensureArgv.count
        #expect(launched == 4)

        // Let the async event stream flush, then assert exactly one warning fired (only the 4th spawn).
        try await Task.sleepMS(50)
        let warnings = await collector.activities.filter { $0.kind == .warning }
        #expect(warnings.count == 1)
        #expect(warnings.first?.text.contains("subscription") == true)
    }

    @Test("no warning at or below the threshold")
    func silentUnderThreshold() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let collector = EventCollector()
        await collector.start(env.svc.subscribe())

        for i in 0..<3 { _ = try await env.svc.spawn(SpawnInput(prompt: "p\(i)", repo: repo, branch: "b\(i)")) }

        try await Task.sleepMS(50)
        let warnings = await collector.activities.filter { $0.kind == .warning }
        #expect(warnings.isEmpty)
    }

    @Test("apiKey adapter never warns, even for a big fan-out")
    func apiKeyNeverWarns() async throws {
        let env = TestEnv.make(capabilities: Self.apiKeyCaps)   // single adapter, apiKey
        let repo = TestEnv.repo(env.base)
        let collector = EventCollector()
        await collector.start(env.svc.subscribe())

        for i in 0..<6 { _ = try await env.svc.spawn(SpawnInput(prompt: "p\(i)", repo: repo, branch: "b\(i)")) }

        try await Task.sleepMS(50)
        let warnings = await collector.activities.filter { $0.kind == .warning }
        #expect(warnings.isEmpty)
    }
}

private extension Task where Success == Never, Failure == Never {
    /// Small sleep helper for letting the event stream drain (ms).
    static func sleepMS(_ ms: UInt64) async throws { try await Task<Never, Never>.sleep(nanoseconds: ms * 1_000_000) }
}
```

> Note: `Task` here is Swift Concurrency's `_Concurrency.Task`, distinct from Orchestra's `Task` card
> model. The existing suites reference the card `Task` unqualified inside `OrchestraCore`; in this test
> file the sleep helper is namespaced to the concurrency `Task`. If the name collision is ambiguous at
> compile time, replace `Task.sleepMS(50)` with `try await _Concurrency.Task.sleep(nanoseconds: 50_000_000)`
> and drop the helper extension.

- [ ] **Step 2: Run the test to verify it fails**

Run (UNSANDBOXED): `./scripts/test.sh --filter AuthWarnSpawnTests`
Expected: FAIL — `.warning` is not a member of `ActivityKind` (and no warning is emitted yet).

- [ ] **Step 3: Add the `ActivityKind.warning` case**

In `Sources/OrchestraCore/Model.swift`, extend the enum (additive — existing cases unchanged):

```swift
public enum ActivityKind: String, Codable, Sendable {
    case spawned, moved, archived, statusChanged, dead, recovered, command, warning
}
```

- [ ] **Step 4: Hold an `AuthRateMonitor` and emit the warning in `spawn`**

In `Sources/OrchestraCore/OrchestraService.swift`, add a stored property alongside the other collaborators
(after `let launcher: Launcher`):

```swift
    let authRate = AuthRateMonitor()
```

Then, in `spawn(_:source:)`, immediately before `return created` (after the existing
`emitActivity(.spawned, created, source, "Spawned “\(title)”")` line), add:

```swift
        // authMode soft-warn (E2 / q4 — advisory only, NEVER caps). Count active subscription-auth cards
        // for this adapter (the just-created card is already in the store) and warn past the threshold.
        let active = await store.all().filter { !$0.archived && $0.status != .dead }
        if let warn = authRate.warning(for: adapter.id, active: active, registry: registry) {
            emitActivity(.warning, created, source, warn.message)
        }
```

- [ ] **Step 5: Run the test to verify it passes**

Run (UNSANDBOXED): `./scripts/test.sh --filter AuthWarnSpawnTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Run the FULL suite + app typecheck (regression gate)**

```bash
./scripts/test.sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools ./scripts/typecheck-app.sh
```

Expected: all green. In particular `CapabilitiesTests`, `ReportTests`, `AdapterTests`, `RecoveryTests`,
`OrchestraServiceTests` unchanged (behavior-preserved: no warning fires for the ≤3-card suites).

- [ ] **Step 7: Commit**

```bash
git add Sources/OrchestraCore/Model.swift Sources/OrchestraCore/OrchestraService.swift \
        Tests/OrchestraCoreTests/AuthWarnSpawnTests.swift
git commit -m "feat(authmode): emit soft-warn activity on subscription fan-out in spawn (E2)"
```

---

## Task 3: Record as-built symbols in the planning docs (truthful-input for docs auto-sync)

**Files:**
- Modify: `notes/designs/agent-provider-interface/03-implementation.md` (E2 row — add as-built note)

Per the Definition of Done step 2 (keep planning docs truthful so the `docs/` auto-sync has accurate
input). This is doc-only; no code, no test.

- [ ] **Step 1: Add an as-built note to the E2 row / decisions**

Append to the E2 row's "Plan must cover" cell (or add a short as-built line under the forest table) noting
the shipped symbols: `AuthRateMonitor` + `AuthWarning` (`Agents/AuthRateMonitor.swift`), the per-adapter
subscription tally, `ActivityKind.warning` as the soft-warn surface, default threshold 3, **no cap**.

- [ ] **Step 2: Commit**

```bash
git add notes/designs/agent-provider-interface/03-implementation.md
git commit -m "docs(authmode): record E2 as-built symbols (AuthRateMonitor / ActivityKind.warning)"
```

---

## Self-Review

**1. Spec coverage** (E2 row: "authMode soft-warn (no cap) — soft-warn only, q4 resolved, no concurrency
cap; rate state per adapter"):
- Soft-warn only, no cap → Task 2 asserts all cards spawn + N ensure calls; the monitor never throws/blocks. ✓
- Rate state per adapter → `subscriptionTally` groups by `agentId`; Task 1 `perAdapterIsolation` +
  `tallyPerAdapter` assert isolation. ✓
- Warn when authMode indicates shared/subscription auth that could collide → `warning(for:)` gates on
  `authMode == .subscription` and a >threshold concurrent tally. ✓
- Docs land (DoD) → Task 3 records as-built symbols; `docs/09`+`docs/10` auto-sync on the orchestrator's
  merge to `main`. ✓

**2. Placeholder scan:** every step carries the actual code / exact command / expected output. No TBD. ✓

**3. Type consistency:** `AuthRateMonitor` / `AuthWarning` member names (`subscriptionTally`,
`warning(for:active:registry:)`, `agentId`, `agentName`, `count`, `threshold`, `message`,
`defaultThreshold`) match between Task 1's definition and Task 2's use. `ActivityKind.warning` spelled
identically in Model.swift, spawn, and both test files. ✓
