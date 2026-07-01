# A1 — Seam-Contract Freeze Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Freeze the complete `AgentCapabilities` descriptor + `AdapterContext.seed` (defaulted) onto the `Adapter` seam and gate core resumption/session-seeding on capabilities instead of nil-return implications — with Claude behavior byte-for-byte unchanged.

**Architecture:** Add a new value type `AgentCapabilities` (7 enum-typed fields, every variant spelling frozen now, including later-only variants) as a required non-defaulted protocol member on `Adapter`; every conformer (`ClaudeCodeAdapter`, `StubAdapter`) implements it. Add `AdapterContext.seed: String?` defaulted to `nil` so no call site breaks. Refactor `OrchestraService` to switch on `capabilities.sessionId` where it currently infers session behavior from a nil return, and gate `isResumable` on the capability + the adapter's `sessionInfo` answer rather than a hardcoded `~/.claude` transcript stat.

**Tech Stack:** Swift, swift-testing (`@Suite`/`@Test`/`#expect`), XCTest (legacy read-only tests), `scripts/test.sh` + `scripts/typecheck-app.sh`.

## Global Constraints

- **Claude behavior UNCHANGED.** The Claude adapter's advertised tuple encodes the shipped behavior; no argv/telemetry/read-only change.
- **Behavior-preservation gate:** `ReportTests`, `AdapterTests`, `RecoveryTests` (and all existing suites) must stay GREEN **unchanged** (the test files are not edited; `Stubs.swift` harness may be extended additively).
- **Enum spellings are frozen and must match SSOT `agent-provider-interface.md` §4 classDiagram AND `02-contract.md` classDiagram EXACTLY** (the two are identical). The complete set:
  - `sessionId ∈ {seeded, discovered}`
  - `telemetry ∈ {hooksPush, fileTail, ptyScrape}`
  - `contextUsage ∈ {percent, tokens, none}`
  - `wakeTransport ∈ {nativeReinvoke, controlChannel, sendKeys, relaunch}`
  - `inboxDrain ∈ {stopHook, sessionSeed, none}`
  - `readOnlyEnforcement ∈ {sandboxed, toolGatedOnly, orchestraSandboxed}`
  - `authMode ∈ {subscription, apiKey}`
- **`capabilities` has NO meaningful protocol default** → both `ClaudeCodeAdapter` and `StubAdapter` must implement it or the package won't compile.
- **Additions are defaulted, never mutations:** `seed` defaults to `nil`; `StubAdapter`'s `capabilities` init param and `TestEnv.make`'s new param default so no existing call site changes.
- **Claude's frozen tuple:** `seeded / hooksPush / percent / nativeReinvoke / stopHook / sandboxed / subscription`.
- Tests never spawn a real vendor agent; `USE_REAL_CLAUDE` stays unset.
- Build/test require an **unsandboxed** shell (swift build fails under sandbox-exec); re-run with the sandbox disabled if `sandbox_apply: Operation not permitted` appears.

---

## File Structure

- **Create:** `Sources/OrchestraCore/Agents/AgentCapabilities.swift` — the frozen descriptor value type (struct + 7 nested enums + a `.claudeCode` static).
- **Modify:** `Sources/OrchestraCore/Agents/Adapter.swift` — add `var capabilities` to the protocol (no default extension); add `AdapterContext.seed` (defaulted).
- **Modify:** `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift` — implement `capabilities` (`.claudeCode`).
- **Modify:** `Sources/OrchestraCore/OrchestraService.swift` — `spawn` seeds the session id via an explicit `switch capabilities.sessionId`.
- **Modify:** `Sources/OrchestraCore/OrchestraService+Recovery.swift` — `restart` seeds via the same switch; `isResumable` gates on caps + `sessionInfo`.
- **Modify (harness only):** `Tests/OrchestraCoreTests/Stubs.swift` — `StubAdapter` gains a `capabilities` stored property (init param defaulting to `.claudeCode`); `TestEnv.make` gains a `capabilities` param (default `.claudeCode`).
- **Create:** `Tests/OrchestraCoreTests/CapabilitiesTests.swift` — freeze tripwire + caps-gating unit tests.

---

## Task 1: Freeze the `AgentCapabilities` descriptor

**Files:**
- Create: `Sources/OrchestraCore/Agents/AgentCapabilities.swift`
- Test: `Tests/OrchestraCoreTests/CapabilitiesTests.swift`

**Interfaces:**
- Produces: `public struct AgentCapabilities: Sendable, Equatable, Codable` with fields `sessionId: SessionId`, `telemetry: Telemetry`, `contextUsage: ContextUsage`, `wakeTransport: WakeTransport`, `inboxDrain: InboxDrain`, `readOnlyEnforcement: ReadOnlyEnforcement`, `authMode: AuthMode`; a memberwise `init(sessionId:telemetry:contextUsage:wakeTransport:inboxDrain:readOnlyEnforcement:authMode:)`; nested `String`-raw `CaseIterable` enums; and `static let claudeCode: AgentCapabilities`.

- [ ] **Step 1: Write the failing freeze-tripwire test**

Create `Tests/OrchestraCoreTests/CapabilitiesTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("AgentCapabilities — frozen contract")
struct CapabilitiesTests {

    // The COMPLETE variant spelling, locked against SSOT §4 + 02-contract classDiagram.
    // If any spelling drifts (add/rename/remove a case), this fails — that is the point.
    @Test("every enum variant spelling is frozen exactly")
    func variantSpellingsFrozen() {
        #expect(AgentCapabilities.SessionId.allCases.map(\.rawValue) == ["seeded", "discovered"])
        #expect(AgentCapabilities.Telemetry.allCases.map(\.rawValue) == ["hooksPush", "fileTail", "ptyScrape"])
        #expect(AgentCapabilities.ContextUsage.allCases.map(\.rawValue) == ["percent", "tokens", "none"])
        #expect(AgentCapabilities.WakeTransport.allCases.map(\.rawValue)
                == ["nativeReinvoke", "controlChannel", "sendKeys", "relaunch"])
        #expect(AgentCapabilities.InboxDrain.allCases.map(\.rawValue) == ["stopHook", "sessionSeed", "none"])
        #expect(AgentCapabilities.ReadOnlyEnforcement.allCases.map(\.rawValue)
                == ["sandboxed", "toolGatedOnly", "orchestraSandboxed"])
        #expect(AgentCapabilities.AuthMode.allCases.map(\.rawValue) == ["subscription", "apiKey"])
    }

    @Test("Claude advertises its frozen shipped tuple")
    func claudeTupleFrozen() {
        let c = AgentCapabilities.claudeCode
        #expect(c.sessionId == .seeded)
        #expect(c.telemetry == .hooksPush)
        #expect(c.contextUsage == .percent)
        #expect(c.wakeTransport == .nativeReinvoke)
        #expect(c.inboxDrain == .stopHook)
        #expect(c.readOnlyEnforcement == .sandboxed)
        #expect(c.authMode == .subscription)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test.sh --filter CapabilitiesTests`
Expected: FAIL to compile — `cannot find 'AgentCapabilities' in scope`.

- [ ] **Step 3: Write the descriptor**

Create `Sources/OrchestraCore/Agents/AgentCapabilities.swift`:

```swift
import Foundation

/// The capability descriptor every adapter advertises. Core degrades on these flags — never on adapter
/// identity (no `if agentId == "claude"`). This is the seam-contract root (A1): the COMPLETE set of
/// fields and every variant spelling is frozen here, so later PRs implement behavior behind variants
/// declared now but not yet exercised (e.g. `wakeTransport.controlChannel`, `inboxDrain.sessionSeed`,
/// `readOnlyEnforcement.orchestraSandboxed`, `telemetry.ptyScrape`, `contextUsage.none`). Additions to
/// the seam are defaulted; the one true drift vector is these enum spellings — hence the freeze.
public struct AgentCapabilities: Sendable, Equatable, Codable {

    /// How the agent's session id is obtained. `seeded` = Orchestra mints it pre-launch (Claude
    /// `--session-id`); `discovered` = read back from the agent's own output post-launch (Codex rollout).
    public enum SessionId: String, Sendable, Equatable, Codable, CaseIterable {
        case seeded, discovered
    }

    /// How raw telemetry reaches the daemon transport. `hooksPush` = the agent pushes to the `_report`
    /// endpoint; `fileTail` = the daemon tails a rollout/transcript file; `ptyScrape` = the daemon reads
    /// the pane buffer (`capture-pane`).
    public enum Telemetry: String, Sendable, Equatable, Codable, CaseIterable {
        case hooksPush, fileTail, ptyScrape
    }

    /// How context-window usage is expressed. `percent` = the agent reports a %; `tokens` = raw tokens ÷
    /// the model's context window (offline table); `none` = no usage signal.
    public enum ContextUsage: String, Sendable, Equatable, Codable, CaseIterable {
        case percent, tokens, none
    }

    /// How an idle agent is woken to start a turn (F2). `nativeReinvoke` = the harness re-invokes it in
    /// session (Claude); `controlChannel` = an app-server / RPC `turn/start` (future); `sendKeys` = a TUI
    /// keystroke nudge (Codex); `relaunch` = kill + resume (the F1 universal fallback).
    public enum WakeTransport: String, Sendable, Equatable, Codable, CaseIterable {
        case nativeReinvoke, controlChannel, sendKeys, relaunch
    }

    /// How the durable inbox is drained into the agent (F3). `stopHook` = a Stop hook injects at
    /// turn-end; `sessionSeed` = folded into the resume seed; `none` = no live drain.
    public enum InboxDrain: String, Sendable, Equatable, Codable, CaseIterable {
        case stopHook, sessionSeed, none
    }

    /// The strength of the read-only guarantee. `sandboxed` = an OS sandbox is the boundary (true RO);
    /// `toolGatedOnly` = tool-gating only, no OS sandbox (weak — core surfaces a badge); `orchestraSandboxed`
    /// = Orchestra wraps the process in its own sandbox (future).
    public enum ReadOnlyEnforcement: String, Sendable, Equatable, Codable, CaseIterable {
        case sandboxed, toolGatedOnly, orchestraSandboxed
    }

    /// The auth posture. `subscription` = the agent's own OAuth/subscription; `apiKey` = a provider API key.
    public enum AuthMode: String, Sendable, Equatable, Codable, CaseIterable {
        case subscription, apiKey
    }

    public let sessionId: SessionId
    public let telemetry: Telemetry
    public let contextUsage: ContextUsage
    public let wakeTransport: WakeTransport
    public let inboxDrain: InboxDrain
    public let readOnlyEnforcement: ReadOnlyEnforcement
    public let authMode: AuthMode

    public init(sessionId: SessionId, telemetry: Telemetry, contextUsage: ContextUsage,
                wakeTransport: WakeTransport, inboxDrain: InboxDrain,
                readOnlyEnforcement: ReadOnlyEnforcement, authMode: AuthMode) {
        self.sessionId = sessionId
        self.telemetry = telemetry
        self.contextUsage = contextUsage
        self.wakeTransport = wakeTransport
        self.inboxDrain = inboxDrain
        self.readOnlyEnforcement = readOnlyEnforcement
        self.authMode = authMode
    }
}

public extension AgentCapabilities {
    /// The Claude Code adapter's shipped capabilities — the behavior A1 must preserve. Also the default
    /// for the test `StubAdapter`, so existing suites see Claude-shaped behavior unless they opt out.
    static let claudeCode = AgentCapabilities(
        sessionId: .seeded,
        telemetry: .hooksPush,
        contextUsage: .percent,
        wakeTransport: .nativeReinvoke,
        inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed,
        authMode: .subscription)
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test.sh --filter CapabilitiesTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Agents/AgentCapabilities.swift Tests/OrchestraCoreTests/CapabilitiesTests.swift
git commit -m "feat(seam): freeze complete AgentCapabilities descriptor (A1)"
```

---

## Task 2: Require `capabilities` on the `Adapter` protocol + add `AdapterContext.seed`

**Files:**
- Modify: `Sources/OrchestraCore/Agents/Adapter.swift`
- Modify: `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift`
- Modify: `Tests/OrchestraCoreTests/Stubs.swift`

**Interfaces:**
- Produces: `Adapter.capabilities: AgentCapabilities { get }` (required, no default); `AdapterContext.seed: String?` (init param defaulted `nil`); `StubAdapter(transcriptDir:capabilities:)` with `capabilities` defaulting to `.claudeCode`.
- Consumes: `AgentCapabilities` + `.claudeCode` (Task 1).

- [ ] **Step 1: Write the failing test (stub is capability-parameterized)**

Append to `Tests/OrchestraCoreTests/CapabilitiesTests.swift` inside the `CapabilitiesTests` suite:

```swift
    @Test("ClaudeCodeAdapter conforms and advertises the Claude tuple")
    func claudeAdapterAdvertises() {
        #expect(ClaudeCodeAdapter().capabilities == .claudeCode)
    }

    @Test("StubAdapter is capability-parameterized and returns what it was given")
    func stubAdvertisesTuple() {
        let custom = AgentCapabilities(
            sessionId: .discovered, telemetry: .fileTail, contextUsage: .tokens,
            wakeTransport: .sendKeys, inboxDrain: .stopHook,
            readOnlyEnforcement: .toolGatedOnly, authMode: .apiKey)
        let stub = StubAdapter(transcriptDir: NSTemporaryDirectory(), capabilities: custom)
        #expect(stub.capabilities == custom)
        // Default stays Claude-shaped so existing suites are unaffected.
        #expect(StubAdapter(transcriptDir: NSTemporaryDirectory()).capabilities == .claudeCode)
    }

    @Test("AdapterContext.seed defaults to nil and round-trips when set")
    func seedField() {
        #expect(AdapterContext(cwd: "/wt").seed == nil)
        #expect(AdapterContext(cwd: "/wt", seed: "handoff summary").seed == "handoff summary")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter CapabilitiesTests`
Expected: FAIL to compile — `value of type 'ClaudeCodeAdapter' has no member 'capabilities'` / `StubAdapter` has no `capabilities:` argument / `AdapterContext` has no `seed:` argument.

- [ ] **Step 3a: Add the protocol requirement + `seed` field**

In `Sources/OrchestraCore/Agents/Adapter.swift`, add the `seed` stored property to `AdapterContext` (after `trustCwd`) and thread it through the init:

```swift
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
```

In the same file, add the requirement to the `Adapter` protocol (place it next to the other capability-shaped members, e.g. right after `var enabled: Bool { get }`):

```swift
    var enabled: Bool { get }
    /// The frozen capability descriptor core degrades on. NO protocol default — every conformer MUST
    /// supply it (A1 seam-contract freeze), so a new adapter can't silently inherit Claude's shape.
    var capabilities: AgentCapabilities { get }
```

Do NOT add a `capabilities` default to the `public extension Adapter` block.

- [ ] **Step 3b: Implement `capabilities` on `ClaudeCodeAdapter`**

In `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift`, add after `public let enabled = true`:

```swift
    public let enabled = true

    /// Claude Code's shipped seam behavior, frozen as the descriptor (A1). Unchanged behavior.
    public var capabilities: AgentCapabilities { .claudeCode }
```

- [ ] **Step 3c: Make `StubAdapter` capability-parameterized**

In `Tests/OrchestraCoreTests/Stubs.swift`, change `StubAdapter` to store and return capabilities:

```swift
final class StubAdapter: Adapter, @unchecked Sendable {
    let id = "claude-code"
    let name = "Stub"
    let icon = "sparkle"
    let bin = "fake-agent"
    let enabled = true
    let capabilities: AgentCapabilities
    let transcriptDir: String
    init(transcriptDir: String, capabilities: AgentCapabilities = .claudeCode) {
        self.transcriptDir = transcriptDir
        self.capabilities = capabilities
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter CapabilitiesTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Full suite — behavior preservation still green**

Run: `./scripts/test.sh`
Expected: PASS (all suites, including `ReportTests`, `AdapterTests`, `RecoveryTests`, `ReadOnlyAdapterTests`). Nothing regressed by the additive members.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/Agents/Adapter.swift Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift Tests/OrchestraCoreTests/Stubs.swift Tests/OrchestraCoreTests/CapabilitiesTests.swift
git commit -m "feat(seam): require Adapter.capabilities + add AdapterContext.seed (A1)"
```

---

## Task 3: Gate session-seeding on `capabilities.sessionId` (replace nil-return implication)

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift:94` (in `spawn`)
- Modify: `Sources/OrchestraCore/OrchestraService+Recovery.swift:107` (in `restart`)
- Modify: `Tests/OrchestraCoreTests/Stubs.swift` (add `capabilities` param to `TestEnv.make`)
- Test: `Tests/OrchestraCoreTests/CapabilitiesTests.swift`

**Interfaces:**
- Consumes: `Adapter.capabilities` (Task 2).
- Produces: `TestEnv.make(..., capabilities: AgentCapabilities = .claudeCode)` — the tuple the injected `StubAdapter` advertises.

**Rationale:** Today `spawn`/`restart` seed the session id by calling `adapter.newSessionId()` and using whatever it returns — a `nil` return would *imply* a discovered-session agent. Replace the implicit nil with an explicit `switch capabilities.sessionId`. For `.seeded` (Claude/Stub default) behavior is identical (mint via `newSessionId()`); for `.discovered` core deliberately leaves the id `nil` to be read back post-launch. This makes the capability the authority, not the return value.

- [ ] **Step 1: Add a `capabilities` knob to `TestEnv.make`, then write the failing gate test**

In `Tests/OrchestraCoreTests/Stubs.swift`, extend `TestEnv.make` signature + adapter construction (defaults keep every existing caller intact):

```swift
    static func make(maxRevivals: Int = 4, grace: Int = 1, capabilities: AgentCapabilities = .claudeCode)
        -> (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, base: String) {
```

and change the adapter line inside it to:

```swift
        let adapter = StubAdapter(transcriptDir: base + "/transcripts", capabilities: capabilities)
```

Append to `CapabilitiesTests`:

```swift
    @Test("spawn seeds a session id for a .seeded adapter (Claude behavior preserved)")
    func spawnSeedsWhenSeeded() async throws {
        let env = TestEnv.make()   // default .claudeCode → .seeded
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        #expect(t.agentSessionId != nil)
        // Seeded id is passed to launch as --session-id.
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.contains("--session-id"))
    }

    @Test("spawn does NOT seed a session id for a .discovered adapter (core gates on caps, not identity)")
    func spawnDiscoveredDoesNotSeed() async throws {
        let discovered = AgentCapabilities(
            sessionId: .discovered, telemetry: .fileTail, contextUsage: .tokens,
            wakeTransport: .sendKeys, inboxDrain: .stopHook,
            readOnlyEnforcement: .sandboxed, authMode: .subscription)
        let env = TestEnv.make(capabilities: discovered)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        #expect(t.agentSessionId == nil)   // discovered → read back post-launch, not seeded
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(!argv.contains("--session-id"))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter CapabilitiesTests`
Expected: FAIL — `spawnDiscoveredDoesNotSeed` fails (`t.agentSessionId` is non-nil because `StubAdapter.newSessionId()` still mints unconditionally). `spawnSeedsWhenSeeded` passes.

- [ ] **Step 3a: Gate `spawn`**

In `Sources/OrchestraCore/OrchestraService.swift`, replace line 94:

```swift
        let sid = adapter.newSessionId()
```

with:

```swift
        // Session identity is capability-gated, not inferred from a nil return: a `.seeded` agent
        // (Claude) gets its id minted pre-launch; a `.discovered` agent is left nil and reads its id
        // back from its own output post-launch (design §5, D5).
        let sid: String?
        switch adapter.capabilities.sessionId {
        case .seeded:     sid = adapter.newSessionId()
        case .discovered: sid = nil
        }
```

- [ ] **Step 3b: Gate `restart`**

In `Sources/OrchestraCore/OrchestraService+Recovery.swift`, replace line 107:

```swift
        let freshId = adapter.newSessionId()
```

with:

```swift
        // Same capability gate as spawn: only a `.seeded` agent mints a fresh id on restart.
        let freshId: String?
        switch adapter.capabilities.sessionId {
        case .seeded:     freshId = adapter.newSessionId()
        case .discovered: freshId = nil
        }
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter CapabilitiesTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Behavior preservation — recovery/report suites still green**

Run: `./scripts/test.sh --filter "RecoveryTests|ReportTests"`
Expected: PASS (Stub defaults to `.seeded`, so `newSessionId()` is still called — identical behavior).

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Sources/OrchestraCore/OrchestraService+Recovery.swift Tests/OrchestraCoreTests/Stubs.swift Tests/OrchestraCoreTests/CapabilitiesTests.swift
git commit -m "refactor(seam): gate session-seeding on capabilities.sessionId (A1)"
```

---

## Task 4: Gate `isResumable` on caps + `sessionInfo` (drop the transcript-stat assumption)

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Recovery.swift:154-161` (`isResumable`)
- Test: `Tests/OrchestraCoreTests/CapabilitiesTests.swift`

**Interfaces:**
- Consumes: `Adapter.capabilities`, `Adapter.sessionInfo`.

**Rationale:** Today `isResumable` reaches into the adapter's `sessionInfo(...).transcriptPath` and stats it, but the framing hardwires the Claude "a transcript file exists ⇒ resumable" assumption. Reframe as an explicit `switch capabilities.sessionId` gate: a card is resumable only when its adapter has a session-identity capability, a stored id, and the adapter's `sessionInfo` yields a state path that is present on disk. Behavior is identical for the seeded Stub/Claude adapters (RecoveryTests unchanged); the core no longer *assumes* the transcript model — it asks the adapter and gates on the capability, so a `.discovered` agent with no stored id short-circuits to non-resumable.

- [ ] **Step 1: Write the failing caps-gated resumability test**

Append to `CapabilitiesTests`:

```swift
    @Test("isResumable: seeded adapter with a stored id + state on disk is resumable; absent → not")
    func isResumableGatedByCaps() async throws {
        let env = TestEnv.make()   // .seeded
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        // No transcript yet → not resumable.
        #expect(await env.svc.isResumable(t) == false)
        // Adapter's state (transcript) now on disk → resumable.
        env.adapter.writeTranscript(for: t.agentSessionId!)
        #expect(await env.svc.isResumable(t) == true)
        // Remove it → not resumable again (core consults the adapter's sessionInfo path, not ~/.claude).
        env.adapter.deleteTranscript(for: t.agentSessionId!)
        #expect(await env.svc.isResumable(t) == false)
    }

    @Test("isResumable: a discovered adapter with no stored id is not resumable")
    func isResumableDiscoveredNoId() async throws {
        let discovered = AgentCapabilities(
            sessionId: .discovered, telemetry: .fileTail, contextUsage: .tokens,
            wakeTransport: .sendKeys, inboxDrain: .stopHook,
            readOnlyEnforcement: .sandboxed, authMode: .subscription)
        let env = TestEnv.make(capabilities: discovered)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        #expect(t.agentSessionId == nil)               // discovered → unseeded
        #expect(await env.svc.isResumable(t) == false) // no id ⇒ nothing to resume
    }
```

- [ ] **Step 2: Run to verify it fails / compiles**

Run: `./scripts/test.sh --filter CapabilitiesTests`
Expected: `isResumableGatedByCaps` PASSES already (current impl works for seeded), `isResumableDiscoveredNoId` PASSES already (nil id short-circuits). NOTE: these two lock behavior; if both already pass, keep them as the regression net and proceed to make the gating explicit in Step 3 (the refactor must keep them green). If either fails to compile (`isResumable` not visible), confirm `@testable import` + that `isResumable` is not `private`.

- [ ] **Step 3: Make the capability gate explicit in `isResumable`**

In `Sources/OrchestraCore/OrchestraService+Recovery.swift`, replace the whole `isResumable` body:

```swift
    func isResumable(_ t: Task) -> Bool {
        guard let sid = t.agentSessionId, !sid.isEmpty else { return false }
        let adapter = (try? registry.get(t.agentId))
        let ctx = AdapterContext(cwd: t.cwd, sessionId: sid, name: t.title, hooksPath: Config.hooksPath)
        guard let tp = adapter?.sessionInfo(ctx, current: sid, prior: t.priorSessionIds)?.transcriptPath
        else { return false }
        return FileManager.default.fileExists(atPath: tp)
    }
```

with:

```swift
    /// Whether a card can be resumed. Capability-gated (design §5): resumability is an adapter answer
    /// keyed on `capabilities.sessionId` + `sessionInfo`, NOT a hardcoded `~/.claude` transcript stat in
    /// core. Both current variants require a stored session id and the adapter's own state path to be
    /// present on disk; a discovered agent with no id short-circuits.
    func isResumable(_ t: Task) -> Bool {
        guard let adapter = try? registry.get(t.agentId) else { return false }
        switch adapter.capabilities.sessionId {
        case .seeded, .discovered:
            guard let sid = t.agentSessionId, !sid.isEmpty else { return false }
            let ctx = AdapterContext(cwd: t.cwd, sessionId: sid, name: t.title, hooksPath: Config.hooksPath)
            guard let statePath = adapter.sessionInfo(ctx, current: sid, prior: t.priorSessionIds)?.transcriptPath
            else { return false }
            return FileManager.default.fileExists(atPath: statePath)
        }
    }
```

- [ ] **Step 4: Run to verify the gate tests + recovery pass**

Run: `./scripts/test.sh --filter "CapabilitiesTests|RecoveryTests"`
Expected: PASS (9 CapabilitiesTests + all RecoveryTests — behavior preserved).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Recovery.swift Tests/OrchestraCoreTests/CapabilitiesTests.swift
git commit -m "refactor(seam): gate isResumable on capabilities + sessionInfo (A1)"
```

---

## Task 5: Full verification gate

**Files:** none (verification only).

- [ ] **Step 1: Full test suite green**

Run: `./scripts/test.sh`
Expected: PASS — every suite, no skips. Confirm `ReportTests`, `AdapterTests`, `RecoveryTests`, `ReadOnlyAdapterTests` are green and unmodified.

- [ ] **Step 2: App type-checks against the updated core**

Run: `./scripts/typecheck-app.sh`
Expected: exit 0, no diagnostics (the app does not touch `AdapterContext`/`Adapter`/`capabilities`, so it should be unaffected; this confirms the core module still builds for the app target).

- [ ] **Step 3: Confirm no stray edits to behavior-gate test files**

Run: `git diff --stat main -- Tests/OrchestraCoreTests/ReportTests.swift Tests/OrchestraCoreTests/AdapterTests.swift Tests/OrchestraCoreTests/RecoveryTests.swift Tests/OrchestraCoreTests/ReadOnlyAdapterTests.swift`
Expected: empty (these files are untouched).

---

## Self-Review (spec coverage)

- **Complete `AgentCapabilities` (all fields + every variant incl. later-only):** Task 1 — enums carry all frozen variants; `variantSpellingsFrozen` locks spellings against both diagrams.
- **`AdapterContext.seed` defaulted nil, 0 of 14 call sites break:** Task 2 — `seed: String? = nil` appended to the init; all 14 existing `AdapterContext(...)` sites use labeled args + defaults, so none change. Full-suite run (Task 2 Step 5) proves it.
- **`capabilities` has no meaningful default → every conformer implements:** Task 2 — protocol member with no extension default; `ClaudeCodeAdapter` + `StubAdapter` both implement or it won't compile.
- **StubAdapter capability-parameterized:** Task 2 Step 3c + Task 3 (`TestEnv.make` knob).
- **Gate core on caps — replace nil-return implications with explicit switches:** Task 3 (`spawn`/`restart` `newSessionId` sites).
- **Gate `isResumable` on caps + `sessionInfo`, drop transcript-stat assumption:** Task 4.
- **Claude behavior UNCHANGED / behavior-preservation gate:** Every task ends re-running the relevant existing suites; Task 5 runs the full suite + typecheck + confirms the gate test files are untouched. Stub defaults to `.claudeCode` (`.seeded`), so all existing paths are byte-identical.
- **Enum spellings match SSOT §4 == 02-contract:** verified identical during planning; `variantSpellingsFrozen` is the executable lock.
