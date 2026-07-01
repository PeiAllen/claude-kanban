# C3 · F1 Resume-in-Card (handoff/resume with seed) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this
> plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the already-merged `resume` path so it can carry a **seed** (authored handoff/fork
context **plus** the card's pending inbox, folded together) into a *resumed* (not restarted) card —
delivering F1 "handoff → clean context, same card".

**Architecture:** The `seed` field is **already frozen on `AdapterContext` (A1)** and defaulted `nil`;
C3 only *reads* `ctx.seed`. We (1) add a pure `HandoffSeed.fold(handoff:inbox:)` helper that folds the
handoff context + drained inbox messages into one bounded seed string; (2) add a defaulted `seed:` param
to the **service** `OrchestraService.resume(_:)` that threads onto `ctx.seed` (all existing call sites
pass nothing → nil → byte-identical behavior); (3) add `OrchestraService.resumeInCard(_:seed:)` (F1)
which drains the inbox, folds it into the seed, and calls `resume` — **keeping the session id** (resume,
fresh process, clean context — never a blank `restart`); (4) make each adapter *deliver* `ctx.seed` as
the resumed session's opening positional turn (`ClaudeCodeAdapter`, `CodexAdapter`, and the test
`StubAdapter`). Every change is **additive/defaulted** — no existing conformer or caller breaks.

**Tech Stack:** Swift 6, swift-testing (`@Suite`/`@Test`/`#expect`/`#require`), `scripts/test.sh` +
`scripts/typecheck-app.sh`. Package `OrchestraCore`; tests in `Tests/OrchestraCoreTests`.

## Global Constraints

- **The `Adapter.resume(ctx) -> [String]?` protocol signature is UNCHANGED.** The seed rides on
  `ctx.seed` (frozen A1), never a new protocol param (`02-contract` §Area-2; `03-implementation` C3 row).
- **Additive, never a mutation.** Every new member is defaulted so all 14 `AdapterContext(...)` sites,
  every `resume` caller, and every `Adapter` conformer keep compiling with identical behavior.
- **Resume, NOT restart.** F1 keeps `agentSessionId` (the vendor transcript carries forward); it must
  never mint a fresh id or drop history the way `restart` does.
- **Inbox folds into the seed** (design §8 F1): a `.sessionSeed`-drain agent (Codex) has no Stop hook, so
  its pending messages must ride the resume seed. Drain happens *before* resume so nothing is
  double-delivered by a later Stop-drain.
- **No real vendor agents in tests** (rule O5): `StubSessions`/`StubAdapter` only; `USE_REAL_CLAUDE` unset.
- **Do NOT** add a `handoff` Command (that is D1) or any UI (D3). C3 only wires the seed *through* resume.
- Build/test needs an **unsandboxed** shell (`swift build`/`test` trip `sandbox-exec`); `typecheck-app.sh`
  self-pins CLT via `scripts/toolchain.sh`.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `Sources/OrchestraCore/HandoffSeed.swift` | pure fold of handoff text + inbox → one bounded seed | **create** |
| `Sources/OrchestraCore/OrchestraService+Recovery.swift` | add `seed:` to `resume`; add `resumeInCard` (F1) | modify |
| `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift` | deliver `ctx.seed` as resume opening positional | modify |
| `Sources/OrchestraCore/Agents/CodexAdapter.swift` | deliver `ctx.seed` as resume opening positional | modify |
| `Tests/OrchestraCoreTests/Stubs.swift` | `StubAdapter.resume` delivers `ctx.seed` | modify |
| `Tests/OrchestraCoreTests/HandoffResumeTests.swift` | F1 unit tests | **create** |

---

### Task 1: `HandoffSeed.fold` — fold handoff + inbox into one bounded seed

**Files:**
- Create: `Sources/OrchestraCore/HandoffSeed.swift`
- Test: `Tests/OrchestraCoreTests/HandoffResumeTests.swift`

**Interfaces:**
- Consumes: `InboxMessage` (C1, `Inbox.swift`), `StopDrain.maxPayloadChars` (C1, `= 10_000`).
- Produces: `enum HandoffSeed { static func fold(handoff: String?, inbox: [InboxMessage]) -> String? }`
  — handoff context first (trimmed, dropped if empty), then inbox messages in FIFO order, joined by
  `"\n\n"`; `nil` when nothing to deliver; clamped to `maxPayloadChars` with a `[…truncated]` prefix.

- [ ] **Step 1: Write the failing test** (create `HandoffResumeTests.swift`)

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("C3 · F1 — HandoffSeed.fold")
struct HandoffSeedTests {

    private func msg(_ card: UUID, _ text: String) -> InboxMessage { InboxMessage(cardId: card, text: text) }

    @Test("fold: handoff first, then inbox in FIFO order, joined by blank lines")
    func order() {
        let c = UUID()
        let s = HandoffSeed.fold(handoff: "HANDOFF", inbox: [msg(c, "one"), msg(c, "two")])
        #expect(s == "HANDOFF\n\none\n\ntwo")
    }

    @Test("fold: nil handoff falls back to inbox only")
    func handoffNil() {
        let c = UUID()
        #expect(HandoffSeed.fold(handoff: nil, inbox: [msg(c, "only")]) == "only")
    }

    @Test("fold: whitespace-only handoff is dropped")
    func handoffBlank() {
        let c = UUID()
        #expect(HandoffSeed.fold(handoff: "   \n ", inbox: [msg(c, "x")]) == "x")
    }

    @Test("fold: empty handoff + empty inbox → nil (no seed delivered)")
    func empty() {
        #expect(HandoffSeed.fold(handoff: nil, inbox: []) == nil)
        #expect(HandoffSeed.fold(handoff: "", inbox: []) == nil)
    }

    @Test("fold: over-long payload is clamped with a truncation marker")
    func clamp() {
        let c = UUID()
        let big = String(repeating: "z", count: StopDrain.maxPayloadChars + 500)
        let s = try! #require(HandoffSeed.fold(handoff: big, inbox: [msg(c, "tail")]))
        #expect(s.count <= StopDrain.maxPayloadChars)
        #expect(s.hasPrefix("[…truncated]"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter HandoffSeedTests`
Expected: FAIL — `cannot find 'HandoffSeed' in scope`.

- [ ] **Step 3: Write minimal implementation** (`Sources/OrchestraCore/HandoffSeed.swift`)

```swift
import Foundation

/// Folds an authored handoff/fork seed **plus** a card's pending inbox into ONE bounded string that is
/// delivered as the resumed session's opening turn (F1). The inbox "folds into the seed" (design §8 F1):
/// a `.sessionSeed`-drain agent (Codex) has no Stop hook, so its queued messages must ride the resume
/// seed rather than a later drain. Handoff context comes first, then the inbox in FIFO order. Pure +
/// synchronous → trivially testable and callable from `resumeInCard`.
public enum HandoffSeed {
    /// Handoff text (trimmed; dropped if empty) followed by `inbox` messages, joined by blank lines.
    /// `nil` when there is nothing to deliver. Bounded to `StopDrain.maxPayloadChars` (the same 10k
    /// live-delivery channel bound) with a `[…truncated]` prefix when it overflows.
    public static func fold(handoff: String?, inbox: [InboxMessage]) -> String? {
        var parts: [String] = []
        if let h = handoff?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty { parts.append(h) }
        parts.append(contentsOf: inbox.map(\.text))
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: "\n\n")
        guard joined.count > StopDrain.maxPayloadChars else { return joined }
        let marker = "[…truncated]\n"
        let keep = StopDrain.maxPayloadChars - marker.count
        return marker + String(joined.prefix(max(0, keep)))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter HandoffSeedTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/HandoffSeed.swift Tests/OrchestraCoreTests/HandoffResumeTests.swift
git commit -m "feat(c3): HandoffSeed.fold — fold handoff ctx + inbox into one bounded seed (F1)"
```

---

### Task 2: Adapters deliver `ctx.seed` on resume (per-agent seed delivery)

**Files:**
- Modify: `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift:169-177` (`resume`)
- Modify: `Sources/OrchestraCore/Agents/CodexAdapter.swift:74-80` (`resume`)
- Modify: `Tests/OrchestraCoreTests/Stubs.swift:93-96` (`StubAdapter.resume`)
- Test: `Tests/OrchestraCoreTests/HandoffResumeTests.swift`

**Interfaces:**
- Consumes: `AdapterContext.seed` (A1, defaulted `nil`).
- Produces: for each adapter, `resume(ctx)` argv gains a **trailing positional** equal to `ctx.seed`
  when it is non-empty; **unchanged** (no trailing positional) when `seed == nil`. Signature stays
  `resume(_ ctx: AdapterContext) -> [String]?`.

- [ ] **Step 1: Write the failing test** (append to `HandoffResumeTests.swift`)

```swift
@Suite("C3 · F1 — adapters deliver ctx.seed on resume")
struct SeedDeliveryTests {
    private func ctx(seed: String?) -> AdapterContext {
        AdapterContext(cwd: "/tmp/wt", model: "m", sessionId: "sid-1", name: "Card", seed: seed)
    }

    @Test("Claude resume appends the seed as the trailing positional turn")
    func claudeCarriesSeed() {
        let argv = try! #require(ClaudeCodeAdapter().resume(ctx(seed: "SEED-CTX")))
        #expect(argv.contains("--resume"))
        #expect(argv.last == "SEED-CTX")
    }

    @Test("Claude resume without a seed adds no trailing positional (unchanged)")
    func claudeNoSeed() {
        let argv = try! #require(ClaudeCodeAdapter().resume(ctx(seed: nil)))
        #expect(argv.contains("--resume"))
        #expect(argv.last != "SEED-CTX")
        // Last token is the settings/name/model tail, never a bare positional.
        #expect(argv.last?.hasPrefix("--") == false || argv.contains("--name"))
    }

    @Test("Codex resume appends the seed as the trailing positional turn")
    func codexCarriesSeed() {
        let argv = try! #require(CodexAdapter().resume(ctx(seed: "SEED-CTX")))
        #expect(argv.contains("resume"))
        #expect(argv.last == "SEED-CTX")
    }

    @Test("Codex resume without a seed adds no trailing positional (unchanged)")
    func codexNoSeed() {
        let argv = try! #require(CodexAdapter().resume(ctx(seed: nil)))
        #expect(argv.last == "never")   // ...-a never is the tail with no model/seed
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter SeedDeliveryTests`
Expected: FAIL — `argv.last == "SEED-CTX"` is false (seed not yet delivered).

- [ ] **Step 3a: Implement Claude delivery** — replace `ClaudeCodeAdapter.resume`:

```swift
    public func resume(_ ctx: AdapterContext) -> [String]? {
        guard let sid = ctx.sessionId else { return nil }
        var argv = [binary, "--resume", sid, "--settings", ctx.hooksPath]
        if let n = ctx.name, !n.isEmpty { argv += ["--name", n] }
        argv += modelFlag(ctx.model)
        argv += accessFlags(ctx.access)
        argv += accessSettingsFlags(ctx)
        // F1 (C3): a handoff/fork seed (authored ctx + folded inbox) rides as the resumed session's
        // opening positional turn — history holds the task, the seed adds the new instruction.
        if let seed = ctx.seed, !seed.isEmpty { argv.append(seed) }
        return argv
    }
```

- [ ] **Step 3b: Implement Codex delivery** — replace `CodexAdapter.resume`:

```swift
    public func resume(_ ctx: AdapterContext) -> [String]? {
        guard let sid = ctx.sessionId else { return nil }
        var argv = [binary, "resume", sid]
        argv += readOnlyFlags
        argv += modelFlag(ctx.model)
        // F1 (C3): Codex has no Stop hook (`inboxDrain == .sessionSeed`), so the folded seed (handoff
        // ctx + pending inbox) rides the resume as its opening positional turn.
        if let seed = ctx.seed, !seed.isEmpty { argv.append(seed) }
        return argv   // no prompt beyond the seed — the rollout holds prior task history
    }
```

- [ ] **Step 3c: Implement Stub delivery** — replace `StubAdapter.resume` (`Tests/.../Stubs.swift`):

```swift
    func resume(_ ctx: AdapterContext) -> [String]? {
        guard let s = ctx.sessionId else { return nil }
        var a = [bin, "--resume", s, "--name", ctx.name ?? ""]
        if let seed = ctx.seed, !seed.isEmpty { a.append(seed) }   // F1: deliver the seed like real adapters
        return a
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter SeedDeliveryTests` → PASS (4 tests).
Then run the regression suites that assert resume argv:
Run: `./scripts/test.sh --filter RecoveryTests` and `./scripts/test.sh --filter CodexAdapterTests`
Expected: PASS (seed defaults nil → argv unchanged for every existing test).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift Sources/OrchestraCore/Agents/CodexAdapter.swift Tests/OrchestraCoreTests/Stubs.swift Tests/OrchestraCoreTests/HandoffResumeTests.swift
git commit -m "feat(c3): adapters deliver ctx.seed as resume opening turn (per-agent, additive)"
```

---

### Task 3: `OrchestraService.resume(seed:)` — thread a seed onto `ctx.seed`

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Recovery.swift:49-97` (`resume`)
- Test: `Tests/OrchestraCoreTests/HandoffResumeTests.swift`

**Interfaces:**
- Consumes: existing `resume` machinery (kill → ensure → `awaitResume`), `AdapterContext(seed:)`.
- Produces: `resume(_ id: UUID, graceSeconds: Int? = nil, seed: String? = nil, source:) -> Task` — a
  **defaulted** `seed:` param inserted before `source:`; when non-nil it is set on `ctx.seed` so the
  adapter's `resume` delivers it. All existing callers (recovery, `Commands.swift:135`, `RecoveryTests`,
  `WakeMergeWatchTests`) pass no `seed` → nil → argv byte-identical.

- [ ] **Step 1: Write the failing test** (append to `HandoffResumeTests.swift`)

```swift
@Suite("C3 · F1 — OrchestraService.resume(seed:)")
struct ResumeSeedTests {

    @Test("resume(seed:) sets ctx.seed so the launch argv carries the seed; id kept")
    func resumeWithSeed() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)
        let oldId = t.agentSessionId

        async let resumed = env.svc.resume(t.id, seed: "SEEDED-CTX")
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"))
        let updated = try await resumed

        #expect(updated.status == .waiting)
        #expect(updated.agentSessionId == oldId)   // resume keeps the id — NOT a fresh restart
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.contains("--resume"))
        #expect(argv.last == "SEEDED-CTX")          // seed delivered as the opening turn
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter ResumeSeedTests`
Expected: FAIL — `resume` has no `seed:` param (compile error / wrong argv).

- [ ] **Step 3: Write minimal implementation** — edit `resume` signature + ctx.

Change the signature (line ~50):
```swift
    public func resume(_ id: UUID, graceSeconds: Int? = nil, seed: String? = nil,
                       source: ActivitySource = .daemon) async throws -> Task {
```
Change the ctx construction (line ~63) to thread the seed:
```swift
        let ctx = AdapterContext(cwd: task.cwd, repo: task.repo, model: task.model.id,
                                 sessionId: task.agentSessionId, name: task.title, hooksPath: Config.hooksPath,
                                 trustCwd: trustDecision == .trusted, seed: seed)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter ResumeSeedTests` → PASS.
Run: `./scripts/test.sh --filter RecoveryTests` → PASS (no-seed callers unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Recovery.swift Tests/OrchestraCoreTests/HandoffResumeTests.swift
git commit -m "feat(c3): OrchestraService.resume(seed:) threads a seed onto ctx.seed (defaulted, additive)"
```

---

### Task 4: `OrchestraService.resumeInCard` — F1 (drain inbox → fold → resume-not-restart)

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Recovery.swift` (add method near `resume`)
- Test: `Tests/OrchestraCoreTests/HandoffResumeTests.swift`

**Interfaces:**
- Consumes: `inbox.drain(_:)` (C1), `HandoffSeed.fold(handoff:inbox:)` (Task 1), `resume(_:seed:)` (Task 3).
- Produces: `resumeInCard(_ id: UUID, seed: String? = nil, graceSeconds: Int? = nil, source:) -> Task`
  — F1 public entry point. Drains the card's inbox, folds it with `seed`, resumes (session id kept).
  This is what D1's `handoff` Command will call.

- [ ] **Step 1: Write the failing test** (append to `HandoffResumeTests.swift`)

```swift
@Suite("C3 · F1 — OrchestraService.resumeInCard")
struct ResumeInCardTests {

    /// Spawn a dead-but-resumable card with a transcript on disk.
    private func makeResumable(_ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String), branch: String) async throws -> Task {
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: branch))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)
        return t
    }

    @Test("resumeInCard carries the handoff seed; keeps the session id (resume, not blank restart)")
    func carriesSeedKeepsId() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await makeResumable(env, branch: "b")
        let oldId = t.agentSessionId

        async let resumed = env.svc.resumeInCard(t.id, seed: "HANDOFF")
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"))
        let updated = try await resumed

        #expect(updated.agentSessionId == oldId)   // SAME session id — resume, not restart
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.contains("--resume"))          // resume argv, never a fresh `start`
        #expect(argv.last == "HANDOFF")
    }

    @Test("resumeInCard folds the pending inbox into the seed and drains it")
    func inboxFoldsIntoSeed() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await makeResumable(env, branch: "b")
        try await env.svc.send(t.id, "queued-1")
        try await env.svc.send(t.id, "queued-2")

        async let resumed = env.svc.resumeInCard(t.id, seed: "HANDOFF")
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"))
        _ = try await resumed

        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        let seed = try #require(argv.last)
        #expect(seed.contains("HANDOFF"))
        #expect(seed.contains("queued-1"))
        #expect(seed.contains("queued-2"))
        // Inbox was drained by the fold — nothing left to double-deliver via a later Stop-drain.
        #expect(await env.svc.drainForStop(t.id) == nil)
    }

    @Test("resumeInCard with no seed and empty inbox delivers no positional (pure resume)")
    func noSeedNoInbox() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await makeResumable(env, branch: "b")

        async let resumed = env.svc.resumeInCard(t.id)
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"))
        _ = try await resumed

        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.contains("--resume"))
        // StubAdapter.resume tail is `--name <title>`; with no seed nothing follows the name value.
        let nameIdx = try #require(argv.firstIndex(of: "--name"))
        #expect(argv.count == nameIdx + 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter ResumeInCardTests`
Expected: FAIL — `value of type 'OrchestraService' has no member 'resumeInCard'`.

- [ ] **Step 3: Write minimal implementation** — add to `OrchestraService+Recovery.swift`
(immediately after `resume`):

```swift
    /// F1 (C3) — resume THIS card into a fresh process with CLEAN context, seeded with the handoff/fork
    /// context AND its pending inbox (folded into one seed delivered as the resumed session's opening
    /// turn). This is **resume, not a blank restart**: `agentSessionId` is KEPT, so the vendor transcript
    /// carries forward and the seed adds new context to a continued session. The inbox "folds into the
    /// seed" (design §8 F1) — drained BEFORE resume so a `.sessionSeed` agent (Codex, no Stop hook) still
    /// receives its queued messages, and they are not double-delivered by a later Claude Stop-drain.
    /// Backs D1's `handoff` Command.
    @discardableResult
    public func resumeInCard(_ id: UUID, seed: String? = nil, graceSeconds: Int? = nil,
                             source: ActivitySource = .daemon) async throws -> Task {
        let drained = (try? await inbox.drain(id)) ?? []
        let folded = HandoffSeed.fold(handoff: seed, inbox: drained)
        return try await resume(id, graceSeconds: graceSeconds, seed: folded, source: source)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter ResumeInCardTests` → PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Recovery.swift Tests/OrchestraCoreTests/HandoffResumeTests.swift
git commit -m "feat(c3): OrchestraService.resumeInCard (F1) — drain inbox, fold into seed, resume-not-restart"
```

---

### Task 5: Full gate — whole suite + typecheck + advisory e2e

**Files:** none (verification only).

- [ ] **Step 1: Full unit suite green**

Run: `./scripts/test.sh`
Expected: PASS. Known flake: if `RecoveryTests` "resume success: confirmed within grace" is the **only**
failure, re-run `./scripts/test.sh --filter RecoveryTests` in isolation to confirm green.

- [ ] **Step 2: App typecheck green**

Run: `./scripts/typecheck-app.sh`
Expected: PASS (C3 touches no app target, but the gate must be clean).

- [ ] **Step 3: Advisory UX e2e (O6 — NOT a merge gate)**

Run: `./scripts/orch-ux-e2e.sh --run-id c3handoff`
Expected: unit/typecheck are the gate; a screenshot-step failure on a headless/locked window server is
environmental (O6), not a defect — record it and proceed.

- [ ] **Step 4: Docs truthfulness (planning hygiene)** — flip the C3 rows in the layer docs to as-built:
`notes/designs/agent-provider-interface/02-contract.md` (`resumeInCard` (F1) row) and `04-tests.md`
(`resumeInCard` test row) get an **As-built (C3, shipped)** note naming the real symbols
(`HandoffSeed.fold`, `OrchestraService.resume(seed:)`, `resumeInCard`, adapter seed positional). Commit.

- [ ] **Step 5: Move to `review`** and report `DONE: live/03-handoff-resume — tests green` + one-liner.
Do NOT merge/archive — the orchestrator merges.

---

## Self-Review

**Spec coverage** (`03-implementation` C3 "Plan must cover" + `04-tests` `resumeInCard` row):
- *resume-not-restart* → Task 4 `carriesSeedKeepsId` asserts `agentSessionId == oldId` + `--resume` argv (never a fresh `start`). ✅
- *inbox-into-seed* → Task 1 `HandoffSeed.fold` + Task 4 `inboxFoldsIntoSeed` (drain-then-fold, no double-deliver). ✅
- *`seed` frozen A1, only read; `resume` signature unchanged* → C3 reads `ctx.seed` only; `Adapter.resume(ctx) -> [String]?` unchanged (Task 2); service `resume` gains a *defaulted* param (additive, not the adapter seam). ✅
- *per-agent seed delivery* → Task 2 covers Claude + Codex + Stub. ✅
- Tests `resume carries seed` / `uses resume not blank restart` / `inbox folds into seed` → Tasks 3+4. ✅

**Placeholder scan:** none — every code + test step is complete literal code.

**Type consistency:** `HandoffSeed.fold(handoff:inbox:)`, `resume(_:graceSeconds:seed:source:)`,
`resumeInCard(_:seed:graceSeconds:source:)`, `ctx.seed`, `InboxMessage`, `StopDrain.maxPayloadChars`,
`StatusReport(sessionSource:)`, `.agentExited` — all match the merged source read for this plan.

**Out of scope (guarded):** no `handoff` Command (D1), no UI (D3), no adapter-protocol signature change,
no `restart` changes.
