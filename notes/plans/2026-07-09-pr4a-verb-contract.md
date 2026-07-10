# PR4a — Gate Before Window: `PhaseStepper` skeleton + typed `VerbSpec` + dispatch gate

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Strict TDD — write the failing test, run red, implement minimally, run green, commit.

**Goal:** Land the verb `phaseGate` gate chokepoint (bug #3 fix — `shell`/`inspect` may not claim the agent session while a card is being born) **before** PR4b opens the non-blocking spawn window, plus the empty `PhaseStepper`/`ConvergeContext` skeleton the four real steppers plug into in PR4b.

**Architecture:** Two independent deliverables. (1) A stateless `PhaseStepper` protocol + `ConvergeContext` deps bundle in `OrchestraCore` with an **empty** phase→stepper map (the four real steppers are PR4b). (2) Extend `CommandSchema` (OrchestraKit) with `kind: VerbKind` + `phaseGate` (an allow-set, deny-by-default), classify all 32 registered verbs per spec §6, and enforce the gate at **one** dispatch chokepoint in `CommandRegistry` — resolve the verb's target card, check its phase against the allow-set, return a typed error naming the phase before the handler runs.

**Tech Stack:** Swift 6, Swift actors, `swift-testing` (`@Test`/`#expect`) + XCTest, the existing `OrchestraService`/`TaskStore`/`CommandRegistry`/`ControlServer` machinery.

## Global Constraints

- **Agent-agnostic.** No `if agentId == "claude"` in shared code. Gate policy is data; it never branches on agent.
- **Deny-by-default gating.** `phaseGate` is an *allow-set*; any phase not in the set is denied (fail-safe for future phases). No per-verb "explicit declaration" ceremony.
- **The gate lands before the window.** Keep the gate correct even though the non-blocking spawn window does not exist yet — tests construct gated phases directly (`store.update { $0.phase = … }`), never by racing a real spawn.
- **Do NOT implement PR4b.** No real steppers (Materialize/Launch/Relaunch/Teardown), no non-blocking spawn, no reconciler discipline, no watch-registry persistence, no conservative mode. Spawn stays synchronous. `test_gatePolicyConformance` (Task 4.6) and the stepper crash-convergence battery are PR4b.
- **`swift test` green after every task** — never leave the suite red.
- **Break the wire/API freely; ship together.** Per the effort's Global Constraint ("no cross-version interop; ship the daemon + all clients together"), OrchestraKit is an internal monorepo package with **no external consumers**. Verified: every `CommandSchema(...)` construction lives in `CommandCatalog.all` (zero other call sites). So `kind` + `phaseGate` are added as **required** init params (no defaults) — required *forces* every present and future verb to classify itself at its call site, which §6 explicitly wants ("future verbs easy to add correctly"); a defaulted `phaseGate` would let a new verb silently ship unclassified. The `CommandRegistryCatalogTests` 1:1 conformance test still guards against drift.
- **Fold deviations into the vault** (`notes/designs/lifecycle-convergence/02-contract.md` → "As-built deviations") and mention them in the merge-request.
- Anchors verified @ `f1aa568`; if a line drifted, search the symbol.

---

## Pre-flight facts (verified against the worktree @ `f1aa568`)

These are **already true** — do not re-create them:

- `Phase.Kind` **already exists** (`Sources/OrchestraKit/Model.swift:83`): `enum Kind: String, Sendable { case creatingWorktree, launching, live, relaunching, dead, archivedPending, archivedComplete }`, with a `Phase.kind` computed property (`:87`) that flattens `archived(Bool)` into `archivedPending`/`archivedComplete`. **The task brief's "add this discriminator" is a no-op — reuse the existing `Phase.Kind`.** (Deviation to fold in.)
- `PhaseStepper.drives: Phase.Kind` uses only 4 of those 7 kinds: `creatingWorktree | launching | relaunching | archivedPending`.
- `TransitionResult` (`Sources/OrchestraCore/OrchestraService+Lifecycle.swift:7`) is `Equatable, Sendable`.
- The funnel is `OrchestraService.transition(_ id:to:observedEpoch:mutate:) async -> TransitionResult` (`+Lifecycle.swift:38`). Legal edges are `OrchestraService.isLegalEdge(from:to:viaSignal:)` (`+Lifecycle.swift:111`). Relevant edges: `reopen` (`archivedPending`/`archivedComplete → creatingWorktree`), `archive` (any non-archived → archived), `resume`/`restart` (`live`/`dead`/`relaunching → relaunching`).
- `OrchestraService` stored deps (all `@testable`-visible): `store: TaskStore`, `worktrees: WorktreeRegistry`, `sessions: any SessionManaging`, `registry: AgentRegistry`.
- Dispatch executes at **`Sources/OrchestraCore/Control/ControlServer.swift:271`**: `return try await cmd.run(service, req.params ?? .object([:]), source)` (the `default:` case, after `registry.command(req.method)`).
- `CommandRegistry` (`Sources/OrchestraCore/CommandRegistry.swift`) holds `commands: [Command]` + `byName`; each `Command` has `schema: CommandSchema` and `run`. There is **no** dispatch method yet — this task adds one.
- `resolveRef(_:) async throws -> Task` (`OrchestraService.swift:1136`) resolves over `store.all()`, which **includes archived cards** — so gating `reopen` on an archived card resolves fine.
- Tests seed a being-born phase with `env.svc.store.update(card.id) { $0.phase = .launching }` (pattern from `PhaseTransitionTests.runProvisioningDelivery`). The session stub exposes `env.sessions.ensureCount` and `env.sessions.ensureArgv[name]`.
- The 32 registered verbs are locked by `CommandRegistryCatalogTests.testCatalogHasAllCommands`.

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/OrchestraCore/PhaseStepper.swift` (**new**) | `PhaseStepper` protocol + `ConvergeContext` struct + the empty reconciler-owned `Phase.Kind → PhaseStepper` map skeleton | 4.1 |
| `Sources/OrchestraCore/OrchestraService.swift` (**modify**) | Add `convergeContext()` factory (bundles the real deps for stubs/PR4b) | 4.1 |
| `Sources/OrchestraKit/CommandCatalog.swift` (**modify**) | `VerbKind` enum; `CommandSchema.kind` + `CommandSchema.phaseGate`; classify all 32 verbs | 4.5 |
| `Sources/OrchestraKit/Errors.swift` (**modify**) | New typed error `OrchestraError.phaseGated(verb:phase:)` (+ code) | 4.5 |
| `Sources/OrchestraCore/CommandRegistry.swift` (**modify**) | `dispatch(...)` chokepoint: resolve target card + enforce `phaseGate` before `run`; `targetCardParam(for:)` mapping | 4.5 |
| `Sources/OrchestraCore/Control/ControlServer.swift` (**modify**) | `default:` case calls `registry.dispatch(...)` instead of `cmd.run(...)` | 4.5 |
| `Tests/OrchestraCoreTests/StepperTests.swift` (**new**) | `test_stepperStepIsIdempotent` (minimal test-double stepper) | 4.1 |
| `Tests/OrchestraCoreTests/VerbContractTests.swift` (**new**) | `test_everyVerbDeclaresKind`, `test_gateEnforcedAtDispatch`, `test_openShellDeniedWhileLaunching` | 4.5 |

---

## Task 4.1: `PhaseStepper` protocol + `ConvergeContext` (skeleton only)

**Files:**
- Create: `Sources/OrchestraCore/PhaseStepper.swift`
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (add `convergeContext()` factory near the other actor helpers, e.g. after `resolveRef`)
- Test: `Tests/OrchestraCoreTests/StepperTests.swift`

**Interfaces:**
- Consumes: `Phase`, `Phase.Kind` (OrchestraKit); `TaskStore`, `WorktreeRegistry`, `any SessionManaging`, `AgentRegistry`, `TransitionResult`, `OrchestraService.transition` (OrchestraCore).
- Produces:
  ```swift
  public protocol PhaseStepper: Sendable {
      static var drives: Phase.Kind { get }                              // creatingWorktree | launching | relaunching | archivedPending
      func step(_ card: Task, _ ctx: ConvergeContext) async throws       // idempotent: advance one edge toward the target
      func verify(_ card: Task, _ ctx: ConvergeContext) async -> Bool     // has the target been reached?
  }

  public struct ConvergeContext: Sendable {
      public let store: TaskStore
      public let worktrees: WorktreeRegistry
      public let sessions: any SessionManaging
      public let adapters: AgentRegistry
      public let transition: @Sendable (_ id: UUID, _ to: Phase, _ observedEpoch: Int?) async -> TransitionResult
      public init(store: TaskStore, worktrees: WorktreeRegistry, sessions: any SessionManaging,
                  adapters: AgentRegistry,
                  transition: @escaping @Sendable (UUID, Phase, Int?) async -> TransitionResult) { … }
  }

  /// Reconciler-owned dispatch map. EMPTY in PR4a — the four real steppers land in PR4b.
  enum PhaseSteppers { static let byKind: [Phase.Kind: any PhaseStepper] = [:] }
  ```
  And on `OrchestraService`:
  ```swift
  func convergeContext() -> ConvergeContext   // bundles store/worktrees/sessions/registry + a transition closure
  ```

- [ ] **Step 1: Write the failing test** — `Tests/OrchestraCoreTests/StepperTests.swift`

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("PhaseStepper — protocol contract (skeleton, PR4a)")
struct StepperTests {

    /// A trivial conforming stepper used ONLY to exercise the protocol's idempotency contract.
    /// (The four real steppers — Materialize/Launch/Relaunch/Teardown — are PR4b.) It advances a
    /// card creatingWorktree → launching through the real funnel; a second `step` is a funnel no-op,
    /// so no side effect repeats.
    private struct DoubleStepper: PhaseStepper {
        static var drives: Phase.Kind { .creatingWorktree }
        func step(_ card: Task, _ ctx: ConvergeContext) async throws {
            _ = await ctx.transition(card.id, .launching, nil)
        }
        func verify(_ card: Task, _ ctx: ConvergeContext) async -> Bool {
            (await ctx.store.get(card.id))?.phase.kind == .launching
        }
    }

    @Test("the reconciler-owned stepper map is an empty skeleton in PR4a")
    func test_stepperMapEmptyInPR4a() {
        #expect(PhaseSteppers.byKind.isEmpty)
    }

    @Test("test_stepperStepIsIdempotent")
    func test_stepperStepIsIdempotent() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        // Seed a being-born phase directly (live→creatingWorktree is not a legal verb edge).
        _ = try await env.svc.store.update(card.id) { $0.phase = .creatingWorktree }

        let ctx = await env.svc.convergeContext()
        let stepper = DoubleStepper()

        try await stepper.step(card, ctx)
        let after1 = try #require(await env.svc.store.get(card.id))
        #expect(after1.phase.kind == .launching)
        #expect(await stepper.verify(card, ctx))

        // Second call from the same phase: the funnel rejects/no-ops the redundant edge — no repeat side
        // effect. `phaseChangedAt` is stamped ONLY on an applied edge, so it must be unchanged.
        try await stepper.step(card, ctx)
        let after2 = try #require(await env.svc.store.get(card.id))
        #expect(after2.phase.kind == .launching)
        #expect(after2.phaseChangedAt == after1.phaseChangedAt)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StepperTests`
Expected: compile FAIL — `cannot find 'PhaseStepper'`, `ConvergeContext`, `PhaseSteppers`, `convergeContext` in scope.

- [ ] **Step 3: Write minimal implementation** — create `Sources/OrchestraCore/PhaseStepper.swift`

```swift
import Foundation

/// A stateless, idempotent driver for ONE transitional phase. The reconciler (PR4b) dispatches by
/// `Phase.Kind`; verbs never reference steppers. A stepper holds NO per-card state — the card arrives
/// as an argument because crash recovery's whole premise is that phase + persisted fields re-derive
/// everything from disk. The four concrete steppers (Materialize/Launch/Relaunch/Teardown) land in PR4b.
public protocol PhaseStepper: Sendable {
    /// The phase this stepper drives toward its target.
    static var drives: Phase.Kind { get }   // creatingWorktree | launching | relaunching | archivedPending
    /// Advance the card one edge toward the target. MUST be idempotent — re-running from the same
    /// persisted phase produces no additional side effect.
    func step(_ card: Task, _ ctx: ConvergeContext) async throws
    /// Has the target been reached? The crash-convergence oracle (PR4b's matrix tests).
    func verify(_ card: Task, _ ctx: ConvergeContext) async -> Bool
}

/// A plain dependency bundle handed to every stepper, so steppers are testable with stubs and steppable
/// off the service actor. Carries no behavior — just references to the real machinery.
public struct ConvergeContext: Sendable {
    public let store: TaskStore
    public let worktrees: WorktreeRegistry
    public let sessions: any SessionManaging
    public let adapters: AgentRegistry
    /// The sole `phase` writer, closed over the service actor. Steppers make progress ONLY through here.
    public let transition: @Sendable (_ id: UUID, _ to: Phase, _ observedEpoch: Int?) async -> TransitionResult

    public init(store: TaskStore, worktrees: WorktreeRegistry, sessions: any SessionManaging,
                adapters: AgentRegistry,
                transition: @escaping @Sendable (UUID, Phase, Int?) async -> TransitionResult) {
        self.store = store; self.worktrees = worktrees; self.sessions = sessions
        self.adapters = adapters; self.transition = transition
    }
}

/// The reconciler-owned `Phase.Kind → PhaseStepper` map. EMPTY in PR4a — the four real steppers plug in
/// here in PR4b. Kept as a single named seam so PR4b is a one-line registration, not a structural change.
enum PhaseSteppers {
    static let byKind: [Phase.Kind: any PhaseStepper] = [:]
}
```

Add to `Sources/OrchestraCore/OrchestraService.swift` (inside the actor, near `resolveRef`):

```swift
    /// Bundle the live dependencies a `PhaseStepper` needs. PR4b's reconciler builds one per tick; the
    /// `transition` closure re-enters this actor so the funnel stays the sole `phase` writer.
    func convergeContext() -> ConvergeContext {
        ConvergeContext(store: store, worktrees: worktrees, sessions: sessions, adapters: registry,
                        transition: { [self] id, to, epoch in
                            await transition(id, to: to, observedEpoch: epoch)
                        })
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StepperTests`
Expected: PASS (both tests).

- [ ] **Step 5: Full suite green + commit**

Run: `swift test` → green.
```bash
git add Sources/OrchestraCore/PhaseStepper.swift Sources/OrchestraCore/OrchestraService.swift Tests/OrchestraCoreTests/StepperTests.swift
git commit -m "feat(converge): stateless PhaseStepper protocol + ConvergeContext (skeleton)"
```

---

## Task 4.5: Typed `VerbSpec` + the gate-enforcement dispatch chokepoint

**Files:**
- Modify: `Sources/OrchestraKit/CommandCatalog.swift` (`VerbKind`, `CommandSchema.kind`/`.phaseGate`, classify 32 verbs)
- Modify: `Sources/OrchestraKit/Errors.swift` (`phaseGated` case + `code`)
- Modify: `Sources/OrchestraCore/CommandRegistry.swift` (`dispatch(...)` + `targetCardParam(for:)`)
- Modify: `Sources/OrchestraCore/Control/ControlServer.swift:271` (call `registry.dispatch`)
- Test: `Tests/OrchestraCoreTests/VerbContractTests.swift`

**Interfaces:**
- Consumes: `Phase.Kind`, `CommandSchema`, `CommandCatalog.all`, `OrchestraError`; `resolveRef`, `Command`, `CommandRegistry`.
- Produces:
  ```swift
  public enum VerbKind: String, Sendable, Equatable { case query, mutation, convergence }
  // CommandSchema gains:  public let kind: VerbKind ;  public let phaseGate: Set<Phase.Kind>
  // OrchestraError gains: case phaseGated(verb: String, phase: String)
  // CommandRegistry gains: func dispatch(_ cmd: Command, _ service: OrchestraService, _ params: JSONValue,
  //                                       _ source: ActivitySource) async throws -> JSONValue
  ```

### Design decisions (fold into the vault)

- **`phaseGate` is `Set<Phase.Kind>`, not `Set<Phase>`.** The spec/contract classDiagram writes `Set<Phase>`, but `Phase` carries associated values (`live(RunState)`, `dead(DeadReason)`, `archived(Bool)`) and is **not** `Hashable`, so `Set<Phase>` neither compiles nor can express "all `live`" without enumerating every `RunState`. The gate policy is entirely **coarse** — it never distinguishes sub-states — and `Phase.Kind` (which already splits `archived` into `archivedPending`/`archivedComplete`) is exactly the dispatch granularity the reconciler and `PhaseStepper.drives` already use. Deny-by-default therefore operates at the `Kind` granularity: a future `Kind` is denied. This is the faithful realization of the spec's intent.
- **Enforcement lives in `CommandRegistry.dispatch`, and `ControlServer` routes through it** (the plan lists `CommandRegistry` as the chokepoint file). One place, before any handler.
- **Target-card param is a `CommandRegistry`-local map, not a `CommandSchema` field.** The interface spec says `CommandSchema` gains only `kind` + `phaseGate`. "Verbs declare which param names their target card" is realized as `targetCardParam(for:)` in the dispatcher: default `"ref"`, `nil` for verbs with no single pre-existing target card (`spawn`, `batch-spawn` create; `trust`/`trustState` are path-scoped; `wait` is multi-target + all-phase; `list` has no ref).
- **Query verbs are never gated** — they are read-only, all-phase, and some (`list`, `capture`) are polled on timers; the dispatcher short-circuits them before any card resolution. They still declare `kind: .query` + `phaseGate` = all kinds for the taxonomy test.
- **`spawn`/`batch-spawn` declare `phaseGate` = all kinds** (a retried spawn returns the existing card **as-is, whatever its phase**), and are not dispatch-gated (`targetCardParam` = `nil`).
- **The gate resolves an *effective* `Phase.Kind` via the archived-Bool bridge.** In PR4a an archived card carries `phase == .dead(.completed)` + a separate `archived == true` Bool (the sync `archive` handler at `OrchestraService.swift:768`; `reopen:211` normalizes this Bool back into a real `.archived(_)` phase). So a *raw* `phase.kind` gate would read every archived card as `.dead` and wrongly **deny `reopen`** (whose real archived check is its own `guard t.archived`). The dispatcher therefore computes `gatedKind(of:) = card.archived ? .archivedComplete : card.phase.kind` — mirroring `reopen`'s own bridge and `migratedPhase`'s `archived → .archived` mapping. This keeps every gate **set** at its *final* value (identical in PR4b); PR4b simply deletes the bridge once `phase == .archived` is the sole representation.
- **`archive.phaseGate` = all kinds (deviation from spec §6's "archive = non-archived").** Spec §6's gate table says archive gates to non-archived, but §P1/§6/§11 give an *explicit, repeated* guarantee: "a retried `archive` of an archived card is `.noop` success, **not an error**." With the effective-kind bridge an archived card reads as `archivedComplete` ∉ `nonArchived`, so an idempotent re-archive would be `phaseGated`-denied — a regression (today `archive` has no gate and re-archive no-ops via the handler). `archive` is a universal, always-safe teardown intent; the funnel/handler is the real entry-edge enforcer (non-archived → archived applies; already-archived → the handler no-ops). So `archive.phaseGate = gAll`. Folded into the vault.

### The full classification (all 32 verbs)

Convenience sets over `Phase.Kind`: `all` = every case; `nonArchived` = `{creatingWorktree, launching, live, relaunching, dead}`; `sessionOrDead` = `{live, dead}`.

| Verb | kind | phaseGate | target param |
|---|---|---|---|
| `list` | query | all | — |
| `status` | query | all | — |
| `sessions` | query | all | — |
| `capture` | query | all | — |
| `tree` | query | all | — |
| `trustState` | query | all | — |
| `inbox` | query | all | — |
| `move` | mutation | nonArchived | ref |
| `send` | mutation | nonArchived | ref |
| `trust` | mutation | nonArchived | — (path) |
| `wait` | mutation | all | — (refs) |
| `inbox-edit` | mutation | nonArchived | ref |
| `inbox-remove` | mutation | nonArchived | ref |
| `inbox-reorder` | mutation | nonArchived | ref |
| `set-parent` | mutation | `{live, dead}` | ref |
| `synced` | mutation | `{live, dead}` | ref |
| `shipped` | mutation | `{live, dead}` | ref |
| `merge-request` | mutation | `{live, dead}` | ref |
| `borrow` | mutation | `{live, dead}` | ref |
| `release` | mutation | `{live, dead}` | ref |
| `shell` | mutation | `{live, dead}` | ref |
| `inspect` | mutation | `{live, dead}` | ref |
| `closeShell` | mutation | `{live, dead}` | ref |
| `exec` | mutation | `{live, dead}` | ref |
| `send-keys` | mutation | `{live, dead}` | ref |
| `spawn` | convergence | all | — (creates) |
| `batch-spawn` | convergence | all | — (creates) |
| `archive` | convergence | **all** (idempotency deviation — see decisions) | ref |
| `reopen` | convergence | `{archivedPending, archivedComplete}` | ref |
| `resume` | convergence | `{live, dead, relaunching}` | ref |
| `restart` | convergence | `{live, dead, relaunching}` | ref |
| `handoff` | convergence | `{live, dead}` | ref |

> Session-touching + lineage mutations both resolve to `{live, dead}` — deny being-born (bug #3 / worktree-may-not-exist) and archived (effective kind `archivedComplete`). `reopen` = the 2 archived kinds (matched via the effective-kind bridge); `archive` = all kinds (idempotent re-archive must no-op, not error — see decisions). `resume`/`restart` include `relaunching` (the supersede self-edge); `handoff` does not (spec §6).

- [ ] **Step 1: Write the failing tests** — `Tests/OrchestraCoreTests/VerbContractTests.swift`

```swift
import Foundation
import Testing
@testable import OrchestraCore   // @_exported brings in OrchestraKit

@Suite("Verb contract — kind + phaseGate + dispatch gate (PR4a)")
struct VerbContractTests {

    // The expected policy, mirrored from spec §6 (deny-by-default allow-sets over Phase.Kind).
    private static let allKinds: Set<Phase.Kind> =
        [.creatingWorktree, .launching, .live, .relaunching, .dead, .archivedPending, .archivedComplete]
    private static let nonArchived: Set<Phase.Kind> =
        [.creatingWorktree, .launching, .live, .relaunching, .dead]
    private static let liveDead: Set<Phase.Kind> = [.live, .dead]

    private static let expected: [String: (VerbKind, Set<Phase.Kind>)] = [
        "list": (.query, allKinds), "status": (.query, allKinds), "sessions": (.query, allKinds),
        "capture": (.query, allKinds), "tree": (.query, allKinds), "trustState": (.query, allKinds),
        "inbox": (.query, allKinds),
        "move": (.mutation, nonArchived), "send": (.mutation, nonArchived), "trust": (.mutation, nonArchived),
        "wait": (.mutation, allKinds),
        "inbox-edit": (.mutation, nonArchived), "inbox-remove": (.mutation, nonArchived),
        "inbox-reorder": (.mutation, nonArchived),
        "set-parent": (.mutation, liveDead), "synced": (.mutation, liveDead), "shipped": (.mutation, liveDead),
        "merge-request": (.mutation, liveDead), "borrow": (.mutation, liveDead), "release": (.mutation, liveDead),
        "shell": (.mutation, liveDead), "inspect": (.mutation, liveDead), "closeShell": (.mutation, liveDead),
        "exec": (.mutation, liveDead), "send-keys": (.mutation, liveDead),
        "spawn": (.convergence, allKinds), "batch-spawn": (.convergence, allKinds),
        "archive": (.convergence, allKinds),   // idempotency deviation: re-archive must no-op, not error
        "reopen": (.convergence, [.archivedPending, .archivedComplete]),
        "resume": (.convergence, [.live, .dead, .relaunching]),
        "restart": (.convergence, [.live, .dead, .relaunching]),
        "handoff": (.convergence, liveDead),
    ]

    @Test("test_everyVerbDeclaresKind")
    func test_everyVerbDeclaresKind() {
        for schema in CommandCatalog.all {
            guard let (kind, gate) = Self.expected[schema.name] else {
                Issue.record("verb '\(schema.name)' is unclassified in the expected §6 policy"); continue
            }
            #expect(schema.kind == kind, "verb '\(schema.name)' kind")
            #expect(schema.phaseGate == gate, "verb '\(schema.name)' phaseGate")
            if schema.kind != .query {
                #expect(!schema.phaseGate.isEmpty, "Mutation/Convergence verb '\(schema.name)' must declare a non-empty gate")
            }
        }
        // Completeness: the catalog and the expected policy cover exactly the same verbs.
        #expect(Set(CommandCatalog.all.map(\.name)) == Set(Self.expected.keys))
    }

    /// Records whether a wrapped handler was ever invoked — the direct "handler never reached" oracle.
    private actor RunProbe { var ran = false; func mark() { ran = true } }

    @Test("test_gateEnforcedAtDispatch")
    func test_gateEnforcedAtDispatch() async throws {
        // A gated-out call must never reach its handler. Proven TWO ways: (1) a probe handler wrapping the
        // real denied schema records if it runs; (2) an observable side-effect absence (the real `send`
        // handler would enqueue to the inbox). `send` (board mutation, gate = non-archived) is denied on an
        // archived card (effective kind archivedComplete via the bridge).
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        // Seed the archived terminal state exactly as the sync `archive` handler does (phase + Bool).
        _ = try await env.svc.store.update(card.id) { $0.phase = .dead(.completed); $0.archived = true }

        // (1) Wrap the REAL `send` schema around a probe `run` that MUST NOT fire.
        let sendSchema = try #require(CommandRegistry().command("send")).schema
        let probe = RunProbe()
        let probed = Command(schema: sendSchema, run: { _, _, _ in await probe.mark(); return .ok() })
        await #expect(throws: OrchestraError.phaseGated(verb: "send", phase: "archivedComplete")) {
            _ = try await CommandRegistry().dispatch(probed, env.svc,
                            .object(["ref": .string(card.shortId), "message": .string("blocked")]), .cli)
        }
        #expect(await probe.ran == false, "the gated handler must never be invoked")

        // (2) And the REAL handler leaves no side effect — nothing enqueued.
        let realSend = try #require(CommandRegistry().command("send"))
        await #expect(throws: OrchestraError.phaseGated(verb: "send", phase: "archivedComplete")) {
            _ = try await CommandRegistry().dispatch(realSend, env.svc,
                            .object(["ref": .string(card.shortId), "message": .string("blocked")]), .cli)
        }
        #expect(try await env.svc.inboxPeek(card.id).isEmpty, "gated `send` must not reach the inbox handler")
    }

    @Test("test_openShellDeniedWhileLaunching")
    func test_openShellDeniedWhileLaunching() async throws {
        // Bug #3: shell/inspect must NOT claim the agent session while a card is being born.
        for phase in [Phase.creatingWorktree, .launching, .relaunching] {
            for verb in ["shell", "inspect"] {
                let env = TestEnv.make()
                let repo = TestEnv.repo(env.base)
                let card = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
                _ = try await env.svc.store.update(card.id) { $0.phase = phase }
                // Make the session NOT alive, so an UNGATED shell/inspect WOULD call
                // `sessions.ensure(argv:["/bin/sh"])` (both guard behind `if !isAlive`). This makes the
                // "ensureCount unchanged" assertion below a genuine proof of bug #3, not a vacuous one.
                env.sessions.setAlive(card.id, false)
                let ensureBefore = env.sessions.ensureCount   // captured AFTER killing the session

                let reg = CommandRegistry()
                let cmd = try #require(reg.command(verb))
                await #expect(throws: OrchestraError.phaseGated(verb: verb, phase: phase.kind.rawValue)) {
                    _ = try await reg.dispatch(cmd, env.svc, .object(["ref": .string(card.shortId)]), .cli)
                }
                // The agent session name was never claimed by /bin/sh — the gate fired before `ensure`.
                #expect(env.sessions.ensureCount == ensureBefore,
                        "\(verb) on \(phase.kind.rawValue) must not claim the session with /bin/sh (bug #3)")
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter VerbContractTests`
Expected: compile FAIL — `CommandSchema` has no `kind`/`phaseGate`; `VerbKind` and `OrchestraError.phaseGated` undefined; `CommandRegistry.dispatch` undefined.

- [ ] **Step 3a: Add `VerbKind` + `CommandSchema` fields** — `Sources/OrchestraKit/CommandCatalog.swift`

Add above `CommandSchema`:

```swift
/// The three verb kinds (spec §6). Query: read-only, retry-free. Mutation: completes inline, idempotent,
/// never changes `phase`. Convergence: sync part persists intent (one `transition`) + returns; the
/// reconciler's phase-keyed stepper drives the rest.
public enum VerbKind: String, Sendable, Equatable { case query, mutation, convergence }
```

Extend `CommandSchema` with **required** `kind` + `phaseGate` (verified: every `CommandSchema(...)` construction lives in `CommandCatalog.all` — no external call site, so no defaults are needed, and *required* forces every future verb to classify itself, satisfying §6's "future verbs easy to add correctly"):

```swift
public struct CommandSchema: Sendable, Equatable {
    public let name: String
    public let summary: String
    public let params: JSONValue
    public let exposure: CommandExposure
    public let kind: VerbKind
    /// Deny-by-default ALLOW-set: a phase whose `Phase.Kind` is absent is denied. A future `Kind` is
    /// therefore denied — the fail-safe direction. Enforced at the one dispatch chokepoint.
    public let phaseGate: Set<Phase.Kind>
    public init(name: String, summary: String, params: JSONValue, exposure: CommandExposure = .all,
                kind: VerbKind, phaseGate: Set<Phase.Kind>) {
        self.name = name; self.summary = summary; self.params = params; self.exposure = exposure
        self.kind = kind; self.phaseGate = phaseGate
    }
}
```

> `CommandSchema` lives in OrchestraKit and `Phase.Kind` is in the same module — no import needed. `Set<Phase.Kind>` compiles with **zero** `Model.swift` change: `Phase.Kind` is `enum Kind: String, Sendable` with **no associated values**, so Swift synthesizes `Hashable` implicitly. Do **not** edit `Model.swift` to add `Hashable` — it is redundant and out of this task's file scope.

- [ ] **Step 3b: Classify all 32 verbs in the catalog** — add `kind:` + `phaseGate:` to every `CommandSchema(...)` in `CommandCatalog.all`.

Introduce private helpers just above `all` to keep the table readable:

```swift
    // Gate allow-sets over Phase.Kind (spec §6 default gate policy).
    private static let gAll: Set<Phase.Kind> =
        [.creatingWorktree, .launching, .live, .relaunching, .dead, .archivedPending, .archivedComplete]
    private static let gNonArchived: Set<Phase.Kind> =
        [.creatingWorktree, .launching, .live, .relaunching, .dead]
    private static let gLiveDead: Set<Phase.Kind> = [.live, .dead]
```

Then, per verb, append the two labels (values from the classification table above). Examples (apply the same shape to all 32):

```swift
        CommandSchema(name: "list", …, kind: .query, phaseGate: gAll),
        CommandSchema(name: "spawn", …, kind: .convergence, phaseGate: gAll),
        CommandSchema(name: "move", …, kind: .mutation, phaseGate: gNonArchived),
        CommandSchema(name: "send", …, kind: .mutation, phaseGate: gNonArchived),
        CommandSchema(name: "wait", …, kind: .mutation, phaseGate: gAll),
        CommandSchema(name: "shell", …, kind: .mutation, phaseGate: gLiveDead),
        CommandSchema(name: "inspect", …, kind: .mutation, phaseGate: gLiveDead),
        CommandSchema(name: "merge-request", …, kind: .mutation, phaseGate: gLiveDead),
        CommandSchema(name: "archive", …, kind: .convergence, phaseGate: gAll),  // idempotency deviation — see decisions
        CommandSchema(name: "reopen", …, kind: .convergence, phaseGate: [.archivedPending, .archivedComplete]),
        CommandSchema(name: "resume", …, kind: .convergence, phaseGate: [.live, .dead, .relaunching]),
        CommandSchema(name: "restart", …, kind: .convergence, phaseGate: [.live, .dead, .relaunching]),
        CommandSchema(name: "handoff", …, kind: .convergence, phaseGate: gLiveDead),
        // …every remaining verb per the classification table (Query=gAll; board mutation=gNonArchived;
        //   session/lineage mutation=gLiveDead; trust=gNonArchived; batch-spawn=gAll).
```

Full per-verb assignment (the executor sets exactly these): Query (`list, status, sessions, capture, tree, trustState, inbox`) → `.query, gAll`. Board mutations (`move, send, trust, inbox-edit, inbox-remove, inbox-reorder`) → `.mutation, gNonArchived`. `wait` → `.mutation, gAll`. Session + lineage mutations (`set-parent, synced, shipped, merge-request, borrow, release, shell, inspect, closeShell, exec, send-keys`) → `.mutation, gLiveDead`. Convergence: `spawn, batch-spawn` → `.convergence, gAll`; `archive` → `.convergence, gAll` (idempotency deviation — see decisions); `reopen` → `.convergence, [.archivedPending, .archivedComplete]`; `resume, restart` → `.convergence, [.live, .dead, .relaunching]`; `handoff` → `.convergence, gLiveDead`.

- [ ] **Step 3c: Add the typed error** — `Sources/OrchestraKit/Errors.swift`

Add the case, its `description`, and a `code`:

```swift
    case phaseGated(verb: String, phase: String)   // the target card's phase denies this verb (deny-by-default gate)
```
```swift
        case .phaseGated(let verb, let phase):
            return "verb '\(verb)' is not allowed while the card is '\(phase)'"
```
```swift
        case .phaseGated:       return 1016
```

- [ ] **Step 3d: Add the dispatch chokepoint** — `Sources/OrchestraCore/CommandRegistry.swift`

Add to `CommandRegistry`:

```swift
    /// The single dispatch chokepoint. Resolves the verb's target card (if it names one) and enforces its
    /// `phaseGate` against the card's current `Phase.Kind` BEFORE the handler runs — a gated-out call never
    /// reaches its handler. Deny-by-default: a kind absent from the allow-set is denied. Query verbs and
    /// verbs with no single pre-existing target card (spawn/batch-spawn/trust/wait) are not phase-gated here.
    public func dispatch(_ cmd: Command, _ service: OrchestraService,
                         _ params: JSONValue, _ source: ActivitySource) async throws -> JSONValue {
        if cmd.schema.kind != .query,
           let paramName = Self.targetCardParam(for: cmd.name),
           let raw = params.optString(paramName) {
            let card = try await service.resolveRef(raw)   // throws .unknownTask (fail fast, same as the handler)
            let kind = Self.gatedKind(of: card)
            guard cmd.schema.phaseGate.contains(kind) else {
                throw OrchestraError.phaseGated(verb: cmd.name, phase: kind.rawValue)
            }
        }
        return try await cmd.run(service, params, source)
    }

    /// Which param names the single existing card a verb's `phaseGate` applies to. `nil` ⇒ the verb has no
    /// single pre-existing target: `spawn`/`batch-spawn` create, `trust`/`trustState` are path-scoped,
    /// `wait` is multi-target + all-phase, `list` has no ref. Everything else targets `"ref"`.
    static func targetCardParam(for verb: String) -> String? {
        switch verb {
        case "spawn", "batch-spawn", "trust", "trustState", "wait", "list": return nil
        default: return "ref"
        }
    }

    /// The card's EFFECTIVE lifecycle kind for gating. PR4a transitional bridge: an archived card carries
    /// `phase == .dead(.completed)` + `archived == true` (the sync `archive` handler; `reopen` normalizes
    /// the Bool back into a real `.archived(_)` phase), so a raw `phase.kind` would read every archived card
    /// as `.dead` and wrongly deny `reopen`. Mirror `reopen`'s own bridge here. PR4b deletes this once
    /// `phase == .archived` is the sole archived representation (the gate SETS never change).
    static func gatedKind(of card: Task) -> Phase.Kind {
        card.archived ? .archivedComplete : card.phase.kind
    }
```

> **Double-resolve + snapshot contract (explicit).** Gated verbs resolve `resolveRef` twice (once in the gate, once in the handler). This is cheap (an actor read + string match) and fail-fast on an unknown ref. The gate is a **snapshot-at-dispatch coarse pre-filter, not a lock**: because `OrchestraService` is a single actor, a verb body runs to its first `await` atomically, but a concurrent transition *can* land in the window between the gate's `resolveRef` and the handler's — so the gate guarantees "the phase was denied *at dispatch time*," not a held phase across the whole handler. That is sufficient for PR4a's purpose (declaring + enforcing the policy; the bug-#3 window is narrow under single-actor serialization). The **deeper** session-claim safety — never claim a session mid-launch even under a race — is PR4b's job: the launch/relaunch steppers require the session layer's `created == true` and the reconciler's orphan-session sweep reclaims a session created after a superseding intent. PR4a deliberately does not add a second re-check at the session-claim boundary (it would duplicate policy the steppers own). Folded into the vault.

- [ ] **Step 3e: Route dispatch through the chokepoint** — `Sources/OrchestraCore/Control/ControlServer.swift:271`

Replace the `default:` case body:

```swift
        default:
            guard let cmd = registry.command(req.method) else {
                throw RPCError(code: -32601, message: "method not found: \(req.method)")
            }
            return try await registry.dispatch(cmd, service, req.params ?? .object([:]), source)
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter VerbContractTests`
Expected: PASS (all three tests). Then `swift test --filter CommandRegistryCatalogTests` → PASS (schema equality still holds; the two new fields are set by the catalog and mirrored by the registry).

- [ ] **Step 5: Full suite green + commit**

Run: `swift test` → green.
```bash
git add Sources/OrchestraKit/CommandCatalog.swift Sources/OrchestraKit/Errors.swift \
        Sources/OrchestraCore/CommandRegistry.swift Sources/OrchestraCore/Control/ControlServer.swift \
        Tests/OrchestraCoreTests/VerbContractTests.swift
git commit -m "feat(verbs): VerbSpec kind+phaseGate with one dispatch-time enforcement chokepoint"
```

---

## Task 4.V: Fold deviations into the vault + final green

- [ ] **Step 1** — Append to `notes/designs/lifecycle-convergence/02-contract.md` → "As-built deviations folded in":
  - **PR4a:** `phaseGate` realized as `Set<Phase.Kind>` (not `Set<Phase>`) — `Phase` has associated values / is not `Hashable`; the gate policy is coarse; `Phase.Kind` is the existing dispatch granularity. Deny-by-default operates per `Kind`.
  - **PR4a:** `Phase.Kind` already existed (PR2, `Model.swift:83`) — the brief's "add the discriminator" was a no-op.
  - **PR4a:** target-card param is a `CommandRegistry.targetCardParam(for:)` map (not a `CommandSchema` field) — the interface fixes `CommandSchema` at `kind` + `phaseGate`. `nil` for `spawn`/`batch-spawn`/`trust`/`trustState`/`wait`/`list`.
  - **PR4a:** Query verbs are never gated (short-circuited before card resolution); `spawn`/`batch-spawn` declare `gAll` (idempotent retry returns the existing card as-is) and are not dispatch-gated.
  - **PR4a:** the gate resolves an **effective** `Phase.Kind` via the archived-Bool bridge `gatedKind(of:) = card.archived ? .archivedComplete : card.phase.kind` — because in PR4a an archived card is `phase == .dead(.completed)` + `archived == true` (a raw `phase.kind` gate would read it as `.dead` and deny `reopen`). Mirrors `reopen`'s own normalization. **PR4b removes the bridge** once `phase == .archived` is the sole archived representation — the gate SETS do not change.
  - **PR4a (deviation from spec §6):** `archive.phaseGate = gAll`, not `nonArchived`. §6's gate table conflicts with the §P1/§6/§11 idempotency guarantee ("retried archive → `.noop` success, **not an error**"); with the effective-kind bridge an archived card reads as `archivedComplete`, so `nonArchived` would `phaseGated`-deny an idempotent re-archive (a regression). `archive` is a universal safe teardown intent; the funnel/handler is the real entry-edge enforcer. **PR4b note:** when Task 4.3 routes `archive` through `transition(.archivedPending)` + the Teardown stepper, re-archive idempotency must stay a `.noop` (funnel `to == from`), not a `phaseGated` error — keep `archive.phaseGate = gAll` (or make the funnel the sole idempotency point).
  - **PR4a:** the chokepoint is the new `CommandRegistry.dispatch`; `ControlServer.swift:271` routes through it. The four real steppers + `test_gatePolicyConformance` remain PR4b.
  - **PR4a (behavior note):** with the gate live, `reopen` and session/lineage mutations on a *non-archived* card now return a typed `phaseGated` error where the bare handler previously silently no-op'd (e.g. `reopen`'s `guard t.archived else { return t }`). This is spec-§6-conformant (a clearer, typed denial) and only reachable via `dispatch`; no existing test exercised the old no-op.
- [ ] **Step 2** — `swift test` → full green. Paste real output (superpowers:verification-before-completion).
- [ ] **Step 3** — Commit the vault update:
```bash
git add notes/designs/lifecycle-convergence/02-contract.md
git commit -m "docs(lifecycle): fold PR4a as-built deviations (Set<Phase.Kind>, target-param map)"
```

---

## Self-Review

**Spec coverage (task-scope = Stage 4 tasks 4.1 + 4.5 only):**
- 4.1 `PhaseStepper` + `ConvergeContext` skeleton + empty map + `test_stepperStepIsIdempotent` (test-double) → Task 4.1. ✔
- 4.5 `CommandSchema.kind` + `phaseGate` (deny-by-default `Set<Phase.Kind>`), all 32 verbs classified per §6, one dispatch chokepoint, typed phase-naming error, `test_everyVerbDeclaresKind`/`test_gateEnforcedAtDispatch`/`test_openShellDeniedWhileLaunching` → Task 4.5. ✔
- Out of scope (PR4b), explicitly excluded: 4.2/4.3 real steppers, 4.4 reconciler + durable registries + conservative mode, 4.6 `test_gatePolicyConformance` + crash-convergence battery, non-blocking spawn. ✔

**Placeholder scan:** every code step shows the exact code; every gate value is enumerated in the classification table and the per-verb assignment paragraph. No TODO/TBD. ✔

**Type consistency:** `VerbKind`(`.query`/`.mutation`/`.convergence`), `CommandSchema.kind`/`.phaseGate: Set<Phase.Kind>`, `OrchestraError.phaseGated(verb:phase:)`, `CommandRegistry.dispatch(_:_:_:_:)`, `CommandRegistry.targetCardParam(for:)`, `PhaseStepper`/`ConvergeContext`/`PhaseSteppers.byKind`, `OrchestraService.convergeContext()` — used identically across tasks and tests. ✔
