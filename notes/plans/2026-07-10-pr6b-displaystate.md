# PR6b — `displayState` UI Honesty (Stage 6, Tasks 6.4–6.6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every Orchestra client render a card's label + available actions from **one** pure contract — `displayState(phase:connection:)` — so no surface can disagree, no action fires against a phase that forbids it, and no toast lies about a call that failed.

**Architecture:** Add a pure, table-testable `displayState(phase:connection:) -> DisplayState` in **OrchestraKit** whose `validActions` is *derived* from `CommandCatalog`'s `phaseGate` sets (never a hand-copied table). Every label/color/gating surface — mac `CardView`/`InspectorView`, iOS `BoardCardCell`/`CardDetailHeader`/`InfoTab`, both `RecoveryView`s, `orchestra list` — reads from it. Fix the three dishonest action paths in `BoardStore` (archive's unconditional toast, silent `move`/`send`, missing spawn in-flight guard). Finally, extract the iOS terminal's bounded-backoff reconnect into a shared `TerminalReconnectPolicy` and wire the mac terminal to it.

**Tech Stack:** Swift 6, SwiftUI (mac `App/`, iOS `App-iOS/`), swift-testing + XCTest, SwiftPM. `displayState` lives in the client-safe `OrchestraKit` target (Foundation + POSIX only — no AppKit/UIKit).

## Global Constraints

- **One render contract.** Every surface derives label + actions from `displayState`; no per-surface label switch; `validActions` derives from the `CommandCatalog.phaseGate` sets, not a hand-copy.
- **Honesty.** No fire-and-forget success toasts; a failed archive must NOT toast "Archived"; `dead(.spawnFailed)` renders as **Dead**, NEVER "Creating…"/"Starting".
- **Agent-agnostic.** No `if agentId == …` in any code path.
- **`swift test` green after every task.** Authoritative gate: `swift test --no-parallel` (836+ tests). Build the mac `App/` and iOS `App-iOS/` targets too when a task touches them (they build separately from the SPM package).
- **Client-safe Kit.** `Sources/OrchestraKit/DisplayState.swift` must not reference `Foundation.Process`/`posix_spawn`/AppKit/UIKit (verified by `scripts/typecheck-kit-ios.sh`). It may import Foundation.
- **Anchors** were verified at `f1aa568`/current worktree tip; if a line has drifted, search the named symbol.

---

## Decisions made (fold into the vault at merge-request)

| Decision | Why | Rejected |
|---|---|---|
| `DisplayState.isStale: Bool` (not the contract's `staleSince: Date`) | PR6a shipped `ConnectionState` as a timestamp-free enum (`connecting/live/retrying/down`), so a `Date` cannot be *purely* derived inside `displayState(phase:connection:)`. Staleness is a boolean signal; the "since when" is owned by the banner (`BoardStore` already observes the `connectionState` edge). | A `Date` field the pure function has no clock to produce |
| `validActions` holds daemon verbs (gated on `live` + phaseGate) **plus** local-only extras; offline it collapses to just the local extras | Honest gating: with the link down, no lifecycle RPC is dispatchable, so every *daemon* verb drops out — but a local affordance (`.openNotes`, a file open) touches no socket and stays. One `Set` (per the contract), not two. | Zeroing the whole set offline (would hide a working local action) OR a second `localActions` set (the contract specifies one `validActions`) |
| `.openNotes` is offered only when the worktree cwd is **materialized** (`launching`/`live`/`relaunching`, or `dead` for a non-`spawnFailed` reason) | A `creatingWorktree` or `dead(.spawnFailed)` card has no notes dir yet, so offering "Open notes" would fail — honesty means not offering it | `kind != .creatingWorktree` alone (would offer notes on a `spawnFailed` card with no worktree) |
| Action gating = `validActions` (the catalog is the SSOT); `isBusy` drives the being-born "…" pill, it does NOT additionally disable catalog-admitted verbs | The catalog's `gNonArchived` deliberately admits `move`/`send` on a being-born card (PR2 wake-on-live delivers a message queued during provisioning), and `archive`=`gAll` must stay available to cancel a stuck spawn — so forcing `!isBusy` on them would contradict the daemon policy | Requiring `!isBusy && validActions.contains(_)` for every action (fights the catalog SSOT) |
| `Verb` is a thin `struct Verb: Hashable { name: String }` with catalog-matching static members | `validActions` derives straight from `CommandSchema.name`, so a `Verb` is just a name; statics (`.restart`, `.shell`, …) give call sites type-checked spelling without a parallel enum that could drift from the catalog | A `Verb` enum hand-listing every command (a second table to keep in sync) |
| Label source of truth = `PhaseDisplayKey.label` in OrchestraKit | The CLI (which doesn't link OrchestraUI/`Theme`) needs the same label string as the GUI; putting it in Kit lets `DisplayState.label`, `Theme.statusLabel`, and the CLI all resolve to one string | Duplicating the label switch in `Theme` (GUI) and `CLIRunner` (raw value) — the pre-existing three-vocabulary drift |
| `isBusy` = transitional phase only (`starting`/`launching`/`relaunching`); `isStale` = `!live` | The contract ties `isBusy` to "in-flight" gating; a being-born card is the phase-level in-flight state. The *spawn* in-flight guard (double-spawn) is a separate `BoardStore.isSpawning` flag (a spawn RPC has no card/phase yet). | Overloading `isBusy` to also mean "disconnected" (conflates two distinct UI states) |
| Mac terminal budget resets only after a reattach survives a 5s **stabilize window** (or a new attach target), never when `attach()` returns | `attach()` only *starts* the tmux-attach process; resetting on start would let a tmux-gone card (reads `.live` for a beat, session already gone) re-exit and loop the bounded backoff forever. Staying alive is the mac analog of iOS's `.connected` reset (there is no explicit "connected" callback for a local process). | Reset on `attach()` return (round-2 finding — unbounded flap) |

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/OrchestraKit/DisplayState.swift` (new) | `Verb`, `DisplayState`, the pure `displayState(phase:connection:)`; `validActions` derived from `CommandCatalog.phaseGate` | 1 |
| `Sources/OrchestraKit/Model.swift` (modify `:614`) | Extract `Phase.displayKey` + `PhaseDisplayKey.label`; `Task.phaseDisplay` delegates | 1 |
| `Sources/OrchestraUI/BoardStore.swift` (modify `:20`, `:745`, `:739`, `:770`, `:902`, `:708`) | `ToastColor: Equatable`; honest `archive`/`move`/`send`/`inspect` toasts; `isSpawning` guard (`beginSpawn`/`endSpawn`); `spawn(id:)` + `spawnAttemptId` | 2 |
| `Tests/OrchestraUITests/DisplayStateTests.swift` (new) | `test_displayStateActionsByPhase` | 1 |
| `Tests/OrchestraUITests/BoardStoreHonestyTests.swift` (new) | `test_archiveFailureToastIsHonest`, `test_doubleSpawnGuarded`, `test_spawnRetryReusesId` | 2 |
| `Sources/OrchestraUI/Theme.swift` (modify `:145`) | `statusLabel(PhaseDisplayKey)` delegates to `PhaseDisplayKey.label` | 3 |
| mac: `App/Views/CardView.swift`, `InspectorView.swift`, `SpawnSheet.swift`, `RecoveryView.swift` | Render label/color/gating from `displayState`; disable-on-`isSpawning`; `spawnFailed` copy | 3 |
| iOS: `App-iOS/Views/BoardCardCell.swift`, `CardDetail/CardDetailHeader.swift`, `CardDetail/InfoTab.swift`, `CardDetail/RecoveryView.swift`, `SpawnSheet.swift` | Same | 3 |
| `Sources/orchestra/CLIRunner.swift` (modify `:268`) | List pill uses `displayState(...).label` | 3 |
| `Sources/OrchestraKit/TerminalReconnectPolicy.swift` (new) | Shared bounded-backoff schedule + budget | 4 |
| `App-iOS/Terminal/IOSTerminalView.swift` (modify `:315`) | `scheduleReconnect` uses the shared policy | 4 |
| `App/Views/AgentTerminalView.swift` (modify `:24-40,173`) | Optional `attachWhileLive` param; `processTerminated` re-attaches via the policy when `displayState` says live | 4 |
| `App/Views/InspectorView.swift` (modify `:357`) | Agent pane passes the `attachWhileLive` gate (`ShellTabsView:42` opts out via the default) | 4 |
| `Tests/OrchestraUITests/TerminalReconnectPolicyTests.swift` (new) | `test_reconnectPolicyBackoff` | 4 |
| `docs/02-architecture.md` | `#the-client-transport-seam-and-reconnect` + `#the-three-clients` (deadlines, keepalive, displayState) | 5 |

---

### Task 1: `displayState` — the one render contract (pure)

**Files:**
- Create: `Sources/OrchestraKit/DisplayState.swift`
- Modify: `Sources/OrchestraKit/Model.swift:614-626` (extract `Phase.displayKey`; add `PhaseDisplayKey.label`)
- Test: `Tests/OrchestraUITests/DisplayStateTests.swift`

**Interfaces:**
- Consumes: `Phase`, `Phase.Kind`, `PhaseDisplayKey` (`Model.swift`); `ConnectionState` (`Control/Transport.swift`); `CommandCatalog.all`, `CommandSchema.{name,phaseGate}` (`CommandCatalog.swift`).
- Produces:
  - `struct Verb: Hashable, Sendable { let name: String; init(_ name: String) }` with statics `.move .send .archive .reopen .restart .resume .shell .inspect .mergeRequest .openNotes`.
  - `struct DisplayState: Equatable, Sendable { let statusKey: PhaseDisplayKey; let label: String; let validActions: Set<Verb>; let isBusy: Bool; let isStale: Bool }`.
  - `func displayState(phase: Phase?, connection: ConnectionState) -> DisplayState`.
  - `var Phase.displayKey: PhaseDisplayKey`; `var PhaseDisplayKey.label: String`.

- [ ] **Step 1: Write the failing test**

Create `Tests/OrchestraUITests/DisplayStateTests.swift`:

```swift
import Testing
import Foundation
@testable import OrchestraKit

@Suite struct DisplayStateTests {

    /// The daemon verbs the catalog admits for a phase — the ground truth `validActions` must DERIVE from
    /// (a hand-copied table would diverge from this). `.openNotes` is the only non-catalog (local) extra.
    private func catalogVerbs(_ phase: Phase) -> Set<Verb> {
        Set(CommandCatalog.all.filter { $0.phaseGate.contains(phase.kind) }.map { Verb($0.name) })
    }

    // dead(.spawnFailed) is DEAD — never "Creating…"/"Starting" — and offers restart, not shell-while-born.
    @Test func test_displayStateActionsByPhase() {
        // DERIVATION (not a hand-copy): live's daemon verbs == exactly the catalog's phaseGate admits.
        let live = displayState(phase: .live(.running), connection: .live)
        #expect(live.validActions.subtracting([.openNotes]) == catalogVerbs(.live(.running)))
        #expect(live.statusKey == .running)
        #expect(live.validActions.isSuperset(of: [.shell, .inspect, .move, .send, .restart]))
        #expect(live.validActions.contains(.openNotes))   // cwd materialized
        #expect(live.isBusy == false)
        #expect(live.isStale == false)

        // creatingWorktree: busy, "Starting"; shell/inspect/restart NOT dispatchable yet; no notes dir yet.
        let born = displayState(phase: .creatingWorktree, connection: .live)
        #expect(born.validActions == catalogVerbs(.creatingWorktree))   // no .openNotes (cwd not materialized)
        #expect(born.statusKey == .starting)
        #expect(born.label == "Starting")
        #expect(born.isBusy == true)
        #expect(!born.validActions.contains(.shell))
        #expect(!born.validActions.contains(.inspect))
        #expect(!born.validActions.contains(.restart))
        #expect(!born.validActions.contains(.openNotes))

        // dead(.spawnFailed): DEAD, never "Creating…"; restart/archive/resume/shell available; not busy;
        // NO .openNotes (the worktree never materialized).
        let failed = displayState(phase: .dead(.spawnFailed), connection: .live)
        #expect(failed.validActions == catalogVerbs(.dead(.spawnFailed)))
        #expect(failed.statusKey == .dead)
        #expect(failed.label == "Dead")
        #expect(failed.label != "Starting" && failed.label != "Creating…")
        #expect(failed.isBusy == false)
        #expect(failed.validActions.isSuperset(of: [.restart, .archive, .resume, .shell]))
        #expect(!failed.validActions.contains(.openNotes))

        // Disconnected: EVERY daemon verb drops out; only the local extra remains; label stays honest.
        let offline = displayState(phase: .live(.running), connection: .retrying)
        #expect(offline.isStale == true)
        #expect(offline.validActions == [.openNotes])   // no catalog/daemon verb dispatchable offline
        #expect(!offline.validActions.contains(.shell))
        #expect(offline.statusKey == .running)          // staleness is a separate signal from the phase label
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DisplayStateTests`
Expected: FAIL — `displayState`, `Verb`, `DisplayState` undefined.

- [ ] **Step 3: Extract `Phase.displayKey` + `PhaseDisplayKey.label` in `Model.swift`**

Replace `Task.phaseDisplay`'s body (`Model.swift:614-626`) with a delegate, and add the two derivations next to the `Phase`/`PhaseDisplayKey` definitions:

```swift
// On `Phase` (near Model.swift:141, after the enum):
extension Phase {
    /// The coarse UI classification — the single `phase → display` map. `Task.phaseDisplay` delegates here
    /// so a phase with no `Task` (e.g. the `displayState` contract) classifies identically.
    public var displayKey: PhaseDisplayKey {
        switch self {
        case .creatingWorktree:            return .starting
        case .launching:                   return .launching
        case .relaunching:                 return .relaunching
        case .live(.running):              return .running
        case .live(.waiting(.permission)): return .needsPermission
        case .live(.waiting(.humanTurn)):  return .idle
        case .dead(.completed):            return .done
        case .archived:                    return .done
        case .dead:                        return .dead
        }
    }
}

// On `PhaseDisplayKey` (near Model.swift:157):
extension PhaseDisplayKey {
    /// The canonical human label — the ONE place `phaseDisplay → label` text lives, shared by the GUI
    /// (`Theme.statusLabel`), the CLI, and `DisplayState.label`.
    public var label: String {
        switch self {
        case .starting:        return "Starting"
        case .launching:       return "Launching"
        case .relaunching:     return "Relaunching"
        case .running:         return "Running"
        case .idle:            return "Waiting"
        case .needsPermission: return "Waiting"
        case .dead:            return "Dead"
        case .done:            return "Done"
        }
    }
}
```

And `Task.phaseDisplay` (`Model.swift:614`) becomes:

```swift
public var phaseDisplay: PhaseDisplayKey { phase.displayKey }
```

- [ ] **Step 4: Write `DisplayState.swift`**

Create `Sources/OrchestraKit/DisplayState.swift`:

```swift
import Foundation

/// A UI action a surface can offer. A verb is just its catalog name (so `validActions` derives straight
/// from `CommandCatalog` with no parallel table); the statics give call sites type-checked spelling.
public struct Verb: Hashable, Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

extension Verb {
    // Catalog-backed — rawValue MUST equal the `CommandSchema.name` it gates.
    public static let move = Verb("move")
    public static let send = Verb("send")
    public static let archive = Verb("archive")
    public static let reopen = Verb("reopen")
    public static let restart = Verb("restart")
    public static let resume = Verb("resume")
    public static let shell = Verb("shell")
    public static let inspect = Verb("inspect")
    public static let mergeRequest = Verb("merge-request")
    // UI-only extra (no catalog verb): opening the worktree notes is a local file op.
    public static let openNotes = Verb("openNotes")
}

/// The ONE render contract every surface consumes (mac, iOS, CLI). Pure + `Equatable` → table-tested.
/// `label`/`statusKey` come from `phase`; `validActions` from the catalog's `phaseGate` (gated to empty
/// when the link is down); `isBusy` marks a being-born phase; `isStale` feeds the offline banner/dim.
public struct DisplayState: Equatable, Sendable {
    public let statusKey: PhaseDisplayKey
    public let label: String
    public let validActions: Set<Verb>
    public let isBusy: Bool
    public let isStale: Bool
    public init(statusKey: PhaseDisplayKey, label: String, validActions: Set<Verb>,
                isBusy: Bool, isStale: Bool) {
        self.statusKey = statusKey; self.label = label; self.validActions = validActions
        self.isBusy = isBusy; self.isStale = isStale
    }
}

/// Derive the render contract from a card's `phase` and the board's link `connection`. Pure — no I/O,
/// no clock. `phase == nil` (card not yet known) reads as a being-born card.
public func displayState(phase: Phase?, connection: ConnectionState) -> DisplayState {
    let key = phase?.displayKey ?? .starting
    let live = (connection == .live)

    var actions = Set<Verb>()
    if live, let phase {
        // Derived from the catalog — a verb is dispatchable iff its phaseGate admits this phase's kind.
        // (No hand-copied table; the catalog is the single source of truth.)
        let kind = phase.kind
        for schema in CommandCatalog.all where schema.phaseGate.contains(kind) {
            actions.insert(Verb(schema.name))
        }
    }
    // UI-only extra: opening the worktree notes is a LOCAL file op — available (link or no link) only once
    // the cwd is materialized. A being-born card has no worktree yet; a spawn-failed card never got one.
    if cwdMaterialized(phase) { actions.insert(.openNotes) }

    let busy = (key == .starting || key == .launching || key == .relaunching)
    return DisplayState(statusKey: key, label: key.label,
                        validActions: actions, isBusy: busy, isStale: !live)
}

/// Does this phase have a materialized worktree cwd (so local file affordances like notes apply)?
private func cwdMaterialized(_ phase: Phase?) -> Bool {
    switch phase {
    case .launching, .live, .relaunching: return true
    case .dead(let reason):               return reason != .spawnFailed
    default:                              return false   // creatingWorktree, archived, nil
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter DisplayStateTests`
Expected: PASS. Then `scripts/typecheck-kit-ios.sh` (DisplayState stays client-safe) — expect success.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraKit/DisplayState.swift Sources/OrchestraKit/Model.swift Tests/OrchestraUITests/DisplayStateTests.swift
git commit -m "feat(ui): displayState render contract + Phase.displayKey / PhaseDisplayKey.label"
```

---

### Task 2: Honest `BoardStore` actions — toasts + double-spawn guard

**Files:**
- Modify: `Sources/OrchestraUI/BoardStore.swift` (`Toast.ToastColor` `:20` → `Equatable`; `archive` `:745`, `move` `:739`, `send` `:770`, `inspect` `:902`, `spawn` `:708`; add `isSpawning` + `beginSpawn`/`endSpawn` + `spawnAttemptId`)
- Test: `Tests/OrchestraUITests/BoardStoreHonestyTests.swift` (new)

**Interfaces:**
- Consumes: `BoardStore.toast(_:sub:color:)` (`:1094`), `Toast`/`ToastColor` (`:15-20`), the concrete `ControlClient` on `BoardStore` (`:143`).
- Produces: `BoardStore.isSpawning: Bool`; `BoardStore.beginSpawn() -> Bool`; `BoardStore.endSpawn()`; `BoardStore.spawn(id: UUID = UUID(), …)`; `static BoardStore.spawnAttemptId(reusing: UUID?) -> UUID`.

> **Test hermeticity (both reviewers verified):** an un-`start()`ed `BoardStore` has a `ControlClient` whose `transport` is `nil`, so `client.call(…)` fails fast at the write (`ControlClient.swift:243-244` → `resolve(.failure("write failed"))`) — no socket, no live daemon touched. So the failure-path honesty tests need **no** injected client or scripted transport: just don't call `start()`. (A success-path toast test would need a scripted responder; it's out of scope — 6.4 only requires "a failed archive does NOT toast 'Archived'".)

**PR6a carry-forward (client-minted id reuse-on-retry).** PR6a made the spawn `id` a required wire field with atomic server-side dedup (a retried spawn with the SAME id returns the existing card as-is) and deferred the app-side reuse-on-retry half to PR6b. Today `spawn` mints a fresh `UUID().uuidString` inline (`BoardStore.swift:715`) — so a retry after a transient failure would create a *duplicate* card. The fix: mint a stable id when a spawn attempt begins and **reuse** it across retries of the same attempt. This is the suspenders to the `isSpawning` belt — the guard stops the concurrent double-tap, the reused id makes a sequential retry idempotent → both converge to ONE card. The reuse *decision* is a pure shared helper (`spawnAttemptId(reusing:)`) both `SpawnSheet`s call; the pending id is each sheet's `@State` (scoped to one open sheet — a re-opened sheet for a different spawn mints fresh). **Merge-request note:** by PR6a's contract a retried spawn "returns the existing card as-is, whatever its phase" — so if the server-side card was actually created but the *response* was lost, then the user edits the prompt and retries with the same id, they get the original card back and the edit is ignored. That's the established PR6a idempotency contract, not a PR6b defect; call it out in the merge-request.

- [ ] **Step 1: Write the failing tests**

Create `Tests/OrchestraUITests/BoardStoreHonestyTests.swift`:

```swift
import Testing
import Foundation
@testable import OrchestraUI
@testable import OrchestraKit

@Suite @MainActor struct BoardStoreHonestyTests {

    // A failed archive must NOT toast "Archived" (the discarded-branch lie). The store is never start()ed,
    // so its client has no transport → client.call fails fast (write failed) → the honest catch fires a
    // red failure toast, never "Archived". Hermetic: no socket touched.
    @Test func test_archiveFailureToastIsHonest() async {
        let store = BoardStore(platform: .noop)         // un-started → client.call always fails
        await store.archive(UUID())
        #expect(!store.toasts.contains { $0.title == "Archived" })
        #expect(store.toasts.contains { $0.color == .red })     // needs ToastColor: Equatable
    }

    // The in-flight guard makes a second spawn (while one is "in flight") a genuine no-op: it returns nil
    // WITHOUT dispatching (no failure toast) and WITHOUT clearing the flag. Simulate the first spawn being
    // in flight by pre-setting isSpawning; a regression that dropped `guard beginSpawn()` from spawn()
    // would instead run the body, hit the failing client, and produce a red "Spawn failed" toast → fails.
    @Test func test_doubleSpawnGuarded() async {
        let store = BoardStore(platform: .noop)
        store.isSpawning = true                         // a spawn is already in flight
        let second = await store.spawn(prompt: "x", repo: "/r", branch: "b", model: nil, startIn: .plan)
        #expect(second == nil)                          // guarded → no-op
        #expect(store.isSpawning == true)               // early return did NOT run `defer { endSpawn() }`
        #expect(store.toasts.isEmpty)                   // no dispatch attempt → no failure toast

        // And the guard primitive itself:
        store.isSpawning = false
        #expect(store.beginSpawn() == true)
        #expect(store.beginSpawn() == false)            // second acquire while held → refused
        store.endSpawn()
        #expect(store.beginSpawn() == true)
    }

    // PR6a carry-forward: a retry of the SAME attempt reuses its client-minted id (→ idempotent dedup =
    // one card); a fresh attempt mints a new id.
    @Test func test_spawnRetryReusesId() {
        let first = BoardStore.spawnAttemptId(reusing: nil)     // first attempt mints
        let retry = BoardStore.spawnAttemptId(reusing: first)   // retry reuses
        #expect(retry == first)
        let fresh = BoardStore.spawnAttemptId(reusing: nil)     // a new attempt mints fresh
        #expect(fresh != first)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BoardStoreHonestyTests`
Expected: FAIL — `beginSpawn`/`endSpawn`/`isSpawning`/`spawnAttemptId` undefined; `ToastColor` not `Equatable`; `archive` still toasts "Archived" unconditionally.

- [ ] **Step 3: Implement the honest actions + guard**

First make `Toast.ToastColor` comparable (the honesty test asserts `$0.color == .red`) — `:20`:

```swift
public enum ToastColor: Equatable { case green, blue, red }
```

(No injected init / scripted transport is needed — see the hermeticity note above; the un-started `BoardStore` from `init(platform:)` already fails every `client.call`.)

Make `archive` honest (`:745-749`). The current body's only local mutation is `if selectedId == id { selectedId = nil }` (`:747`) — keep it, but only on success:

```swift
public func archive(_ id: UUID) async {
    do {
        _ = try await client.call("archive", .object(["ref": .string(id.uuidString)]))
        if selectedId == id { selectedId = nil }     // the existing local mutation (:747), now success-only
        toast("Archived", sub: nil)
    } catch {
        toast("Couldn't archive", sub: "\(error)", color: .red)
    }
}
```

Make `move` + `send` surface failure honestly (`:739`, `:770`):

```swift
public func move(_ id: UUID, to col: Column) async {
    guard tasks.first(where: { $0.id == id })?.origin == .worktree else { return }
    do { _ = try await client.call("move", .object(["ref": .string(id.uuidString), "col": .string(col.rawValue)])) }
    catch { toast("Couldn't move card", sub: "\(error)", color: .red) }
}

public func send(_ id: UUID, _ message: String) async {
    do { _ = try await client.call("send", .object(["ref": .string(id.uuidString), "message": .string(message)])) }
    catch { toast("Couldn't send message", sub: "\(error)", color: .red) }
}
```

Make `inspect` honest too (`:902-904`, currently fire-and-forget) — a failed read-only inspect must surface, not silently swallow:

```swift
public func inspect(_ id: UUID) async {
    do { _ = try await client.call("inspect", .object(["ref": .string(id.uuidString)])) }
    catch { toast("Couldn't open inspector", sub: "\(error)", color: .red) }
}
```

Add the spawn in-flight guard. Near the published state (`:58`):

```swift
/// True while a `spawn` RPC is in flight — the double-spawn guard both `SpawnSheet`s bind to.
@Published public var isSpawning = false

/// Acquire the spawn in-flight lock; `false` if a spawn is already running (the second click is a no-op).
public func beginSpawn() -> Bool {
    if isSpawning { return false }
    isSpawning = true
    return true
}
public func endSpawn() { isSpawning = false }

/// The client-minted spawn id for an attempt: reuse the pending (in-flight / just-failed) attempt's id
/// so a retry is idempotent (PR6a dedups on it → one card), else mint a fresh one. Pure + `static` so both
/// `SpawnSheet`s share the decision and it's unit-testable.
public static func spawnAttemptId(reusing pending: UUID?) -> UUID { pending ?? UUID() }
```

Wire `spawn` (`:708`) to the guard AND accept the client-minted id (default-mint for non-sheet callers), replacing the inline `UUID().uuidString` mint at `:715`:

```swift
public func spawn(id: UUID = UUID(), prompt: String, repo: String, branch: String, model: String?,
                  startIn: StartIn, agent: String? = nil, cwd: String? = nil,
                  access: CardAccess = .readWrite, scratch: Bool = false, base: String? = nil) async -> Task? {
    guard beginSpawn() else { return nil }
    defer { endSpawn() }
    var p: [String: JSONValue] = [
        "id": .string(id.uuidString),          // was `UUID().uuidString` (:715) — now the caller's stable id
        "prompt": .string(prompt), "repo": .string(repo), "branch": .string(branch),
        "col": .string(startIn.rawValue),
    ]
    // ... rest of the existing body unchanged ...
}
```

(`beginSpawn`/`endSpawn`/`isSpawning` are `@MainActor` via `BoardStore`; the `async` `spawn` runs on the main actor, so the check-and-set is race-free. The default `id: UUID = UUID()` preserves every existing call site; only the `SpawnSheet`s pass an explicit reused id.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BoardStoreHonestyTests`
Expected: PASS. Then the full UI suite: `swift test --filter OrchestraUITests` — expect no regressions.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraUI/BoardStore.swift Tests/OrchestraUITests/BoardStoreHonestyTests.swift
git commit -m "feat(ui): honest archive/move/send/inspect toasts + spawn in-flight guard + client-id reuse-on-retry"
```

---

### Task 3: Route every surface through `displayState` (label · color · gating · copy)

**Files (all modify):**
- `Sources/OrchestraUI/Theme.swift:145` (delegate `statusLabel(PhaseDisplayKey)` to `PhaseDisplayKey.label`)
- mac: `App/Views/CardView.swift:13-105`, `App/Views/InspectorView.swift:54-130,477-508`, `App/Views/RecoveryView.swift:16-131`, `App/Views/SpawnSheet.swift:302-330`
- iOS: `App-iOS/Views/BoardCardCell.swift:15-203`, `App-iOS/Views/CardDetail/CardDetailHeader.swift:13-82`, `App-iOS/Views/CardDetail/InfoTab.swift:87-129`, `App-iOS/Views/CardDetail/RecoveryView.swift:30-170`, `App-iOS/Views/SpawnSheet.swift:202,474`
- CLI: `Sources/orchestra/CLIRunner.swift:268`

**Interfaces:** Consumes `displayState(phase:connection:)`, `DisplayState`, `Verb` (Task 1); `BoardStore.isSpawning` (Task 2); `BoardModel.connectionState` (`BoardStore.swift:141`).

> This task is UI wiring — mostly non-unit-testable SwiftUI. Its gate is: both app targets build, `swift test` stays green, and the manual honesty checks below hold. **No behavior may diverge between surfaces.**

- [ ] **Step 1: `Theme.statusLabel` delegates** (`Theme.swift:145-156`)

```swift
public func statusLabel(_ key: PhaseDisplayKey) -> String { key.label }
```

(Leave the legacy `statusLabel(_ status: String)` string overload at `:124` untouched — `ThemeTests.testStatusMappingUnchanged` covers it. Leave `statusColor(PhaseDisplayKey)` at `:135` untouched — surfaces still map `displayState().statusKey` → color through it.)

- [ ] **Step 2: mac label/color/gating surfaces**

`CardView.swift` (`:13-15`): replace the bare `task.phaseDisplay` derivation with the contract:

```swift
private var ds: DisplayState { displayState(phase: task.phase, connection: model.connectionState) }
// (`connectionState` is `@Published` on BoardModel/BoardStore — BoardStore.swift:141. Thread it in via
//  the model the cell already has; if CardView lacks `model`, pass `connection:` down from BoardView's ForEach.)
private var display: PhaseDisplayKey { ds.statusKey }
```

Pill label (`:87-91`): use `ds.label` in place of `theme.statusLabel(display)`. Dim/stale: OR the existing dead-dim with `ds.isStale` (a disconnected board reads dim). Keep `theme.statusColor(ds.statusKey)` for color.

`InspectorView.swift`: header pill (`:487,499-502`) → `ds.label` + `theme.statusColor(ds.statusKey)`. Gate the action buttons on `ds.validActions`:
- Archive (`:97-110`): `.disabled(!ds.validActions.contains(.archive))`.
- Inbox/send (`:95`): `.disabled(!ds.validActions.contains(.send))`.
- inspect eye (`:477-485`): `.disabled(!ds.validActions.contains(.inspect))`.

`SpawnSheet.swift` (mac, `:302-330`): two changes.
- **In-flight disable:** change `.disabled(!canSpawn)` (`:330`) to `.disabled(!canSpawn || model.isSpawning)`. (The `BoardStore.spawn` guard from Task 2 is the real no-op; this is the UX belt.)
- **Stable-id reuse (PR6a carry-forward):** add `@State private var pendingSpawnId: UUID? = nil`. In the submit closure (`:302`), mint/reuse the id, pass it, and clear only on success:
  ```swift
  let sid = BoardStore.spawnAttemptId(reusing: pendingSpawnId)
  pendingSpawnId = sid
  _Concurrency.Task {
      let spawned = await model.spawn(id: sid, prompt: …, repo: …, branch: …, model: …, startIn: …, …)
      if spawned != nil { pendingSpawnId = nil; model.showSpawn = false }   // success → close + drop id
      // failure → keep pendingSpawnId so a retry reuses it (idempotent dedup → one card)
  }
  ```

`RecoveryView.swift` (mac):
- `whyLine` (`:23`) `spawnFailed` copy → make it name the failure honestly with its detail:
  ```swift
  case .spawnFailed: return "Creating the workspace failed" + (task.deadDetail.map { " — \($0)" } ?? "") + "."
  ```
- Gate the panel buttons on `displayState(phase: task.phase, connection: model.connectionState).validActions`: "Start new session" (`:90`) on `.restart`; "Archive" (`:101`) on `.archive`; "Try resume" (`:111`) on `.resume` (in addition to the existing `agentSessionId != nil`). Restart re-materializes the tree (PR4b degraded path), so the "Start new session" copy is honest for `spawnFailed`.

- [ ] **Step 3: iOS label/color/gating surfaces**

`BoardCardCell.swift` (`:15,60,178-203`): derive `let ds = displayState(phase: task.phase, connection: model.connectionState)`; `StatusPill` label → `ds.label`; color → `theme.statusColor(ds.statusKey)`; dead/stale opacity ORs `ds.isStale`.

`CardDetailHeader.swift` (`:13,25,57-82`): `DetailStatusPill` label → `ds.label`, color → `theme.statusColor(ds.statusKey)`.

`InfoTab.swift` (`:87-96`): gate "Restart session" on `ds.validActions.contains(.restart)`; **remove the unconditional local `flash("restart")`** at `:90-96` — `model.restart` already toasts truthfully (success *and* failure), so the local optimistic flash is the dishonest bit; drop it and let the store's toast be the single signal. Gate Archive (`:32`) on `.archive`.

`RecoveryView.swift` (iOS, `:37,133-170`): mirror the mac `spawnFailed` copy (Step 2) and the same `validActions` gating on "Start new session"/`.restart`, "Try resume"/`.resume`, "Archive"/`.archive`.

`SpawnSheet.swift` (iOS, `:202,474`): mirror the mac changes — `.disabled(!canSpawn || model.isSpawning)` on the CTA (`:202`), and in `spawn()` (`:474`) add `@State private var pendingSpawnId: UUID?`, `let sid = BoardStore.spawnAttemptId(reusing: pendingSpawnId); pendingSpawnId = sid`, pass `id: sid` to `model.spawn`, and clear `pendingSpawnId = nil` only on a non-nil result.

Also check the **takeover chrome** (`App/Views/InspectorView.swift:562`, `App-iOS/Views/AgentTakeoverView.swift:93`, `App-iOS/Views/NeedsYouTab.swift:236`) — those read `sib.phaseDisplay`/`card?.phaseDisplay` for a sibling status dot. Because `displayState().statusKey == phase.displayKey`, the label/color stay honest if they keep using `phaseDisplay`; only route them through `displayState` if they render a status *label* the contract owns (a dot-only usage can stay). Verify and note in the merge-request.

- [ ] **Step 4: CLI label** (`CLIRunner.swift:264-269`)

The list pill currently prints `t.phaseDisplay.rawValue` (`:268`) sized to `PhaseDisplayKey.allCases.map(\.rawValue.count).max() ?? 7` (`:266`) — a terse machine vocabulary (`idle`, `needsPermission`). Unify onto the one label vocabulary:

```swift
let pillWidth = PhaseDisplayKey.allCases.map(\.label.count).max() ?? 7   // was \.rawValue.count
// ...
let pill = displayState(phase: t.phase, connection: .live).label        // was t.phaseDisplay.rawValue
    .padding(toLength: pillWidth, withPad: " ", startingAt: 0)
```

(CLI is a one-shot fetch — `connection: .live` is correct. No CLI list golden/snapshot test exists — verified `grep -rl renderTasks Tests/` is empty — so the vocabulary change (`idle`→`Waiting`, `needsPermission`→`Waiting`) breaks nothing.)

- [ ] **Step 5: Build + regression + manual honesty check**

```bash
swift build            # SPM package (Kit/Core/UI/CLI)
swift test --no-parallel   # full suite stays green
scripts/build-app.sh   # mac App/ target builds
scripts/typecheck-ios.sh && scripts/typecheck-ios-ui.sh   # iOS App-iOS/ typechecks
```

Expected: all green. Manual (isolated app per the project UI-verify recipe — `scripts/orch-ui-shot.sh`, NEVER the live board): a `dead(.spawnFailed)` card shows **Dead** on the board pill AND the detail header (no "Creating…"/"Starting"), and its Recovery panel reads "Creating the workspace failed — …" with an enabled "Start new session".

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraUI/Theme.swift App/Views/CardView.swift App/Views/InspectorView.swift App/Views/RecoveryView.swift App/Views/SpawnSheet.swift App-iOS/Views/BoardCardCell.swift App-iOS/Views/CardDetail/CardDetailHeader.swift App-iOS/Views/CardDetail/InfoTab.swift App-iOS/Views/CardDetail/RecoveryView.swift App-iOS/Views/SpawnSheet.swift Sources/orchestra/CLIRunner.swift
git commit -m "feat(ui): every surface renders label + gates actions via displayState"
```

---

### Task 4: Shared terminal reconnect policy (mac reuses iOS)

**Files:**
- Create: `Sources/OrchestraKit/TerminalReconnectPolicy.swift`
- Modify: `App-iOS/Terminal/IOSTerminalView.swift:315-351` (use the policy)
- Modify: `App/Views/AgentTerminalView.swift:24-40,166-173` (add an optional `attachWhileLive` param + wire `processTerminated`)
- Modify: `App/Views/InspectorView.swift:357` (pass the `attachWhileLive` gate — this is the agent pane)
- Test: `Tests/OrchestraUITests/TerminalReconnectPolicyTests.swift`

> **Note (call sites):** `AgentTerminalView` currently takes **no** `BoardModel`/`phase` — only `socket/session/window/host/...` (`:24-40`). The new gate is a single **optional-with-default** param `attachWhileLiveGate: (() -> Bool)? = nil`, so the *other* call site — `App/Views/ShellTabsView.swift:42` (shell panes) — compiles unchanged and opts out of auto-reattach (only the agent pane in `InspectorView.swift:357` opts in).

**Interfaces:** Produces `struct TerminalReconnectPolicy { let maxReconnects: Int; init(maxReconnects: Int = 5); func delay(forAttempt n: Int) -> Int? }`.

- [ ] **Step 1: Write the failing test**

Create `Tests/OrchestraUITests/TerminalReconnectPolicyTests.swift`:

```swift
import Testing
@testable import OrchestraKit

@Suite struct TerminalReconnectPolicyTests {
    // The iOS schedule, now shared: 1,2,4,8,8 (capped at 8), then give up past the budget.
    @Test func test_reconnectPolicyBackoff() {
        let p = TerminalReconnectPolicy()          // maxReconnects = 5
        // `delay` returns Int?, so compare against an [Int?] literal (a plain [Int] won't type-check).
        #expect((1...5).map { p.delay(forAttempt: $0) } == [1, 2, 4, 8, 8].map(Optional.some))
        #expect(p.delay(forAttempt: 6) == nil)     // budget spent → give up
        #expect(p.delay(forAttempt: 0) == nil)     // 1-based; 0 is not a valid attempt
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TerminalReconnectPolicyTests`
Expected: FAIL — `TerminalReconnectPolicy` undefined.

- [ ] **Step 3: Write the policy**

Create `Sources/OrchestraKit/TerminalReconnectPolicy.swift`:

```swift
import Foundation

/// The bounded exponential backoff shared by both terminal hosts (iOS `IOSTerminalView`, mac
/// `AgentTerminalView`): attempt `n` (1-based) waits `min(8, 2^(n-1))` seconds, up to `maxReconnects`
/// attempts, then gives up. Pure — the host owns the timer, the pending-dedup flag, and the live gate.
public struct TerminalReconnectPolicy: Sendable, Equatable {
    public let maxReconnects: Int
    public init(maxReconnects: Int = 5) { self.maxReconnects = maxReconnects }

    /// Seconds to wait before attempt `n` (1-based), or `nil` to give up (budget spent / invalid attempt).
    public func delay(forAttempt n: Int) -> Int? {
        guard n >= 1, n <= maxReconnects else { return nil }
        return min(8, 1 << (n - 1))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TerminalReconnectPolicyTests`
Expected: PASS.

- [ ] **Step 5: Refactor iOS to the shared policy** (`IOSTerminalView.swift:315-338`)

Replace the ad-hoc budget/delay math with the policy while keeping the existing `reconnects`/`reconnectPending`/`shouldReconnect`/`intentionalClose` control flow:

```swift
private let reconnectPolicy = TerminalReconnectPolicy()   // maxReconnects = 5 (was a local constant)
// ... in scheduleReconnect(), replace the budget guard + delay line:
guard let delaySecs = reconnectPolicy.delay(forAttempt: reconnects + 1) else {
    intentionalClose = true
    channel?.close()
    feedStatus("[giving up after \(reconnectPolicy.maxReconnects) attempts — reopen or foreground to retry]")
    return
}
reconnectPending = true
reconnects += 1
let delay = Double(delaySecs)   // 1,2,4,8,8…
```

(`retryConnection()`'s `reconnects >= maxReconnects` check at `:358` becomes `reconnects >= reconnectPolicy.maxReconnects`.) Behavior is identical to before — this is a pure extraction, so the existing iOS terminal tests stay green.

- [ ] **Step 6: Wire the mac `processTerminated`** (`AgentTerminalView.swift:167-173`)

Give the coordinator a reconnect budget + a live gate, and re-attach on process death only while `displayState` says the card is live and the link is up:

```swift
final class Coordinator {   // extend the existing coordinator (:166)
    var attached: String?
    private let reconnectPolicy = TerminalReconnectPolicy()
    private var reconnects = 0
    private var reconnectPending = false
    /// A reattach only counts as SUCCESS if the process stays alive past this window — see below. Cancelled
    /// (never fires) if the pane re-exits first, so a rapid tmux-gone flap can never reset the budget.
    private var stabilizeWork: DispatchWorkItem?
    private let stabilizeWindow: TimeInterval = 5   // a failed `tmux attach` exits ~instantly; 5s ⇒ genuinely up
    /// Bumped when the attach target changes; a backoff block captures it and bails if it no longer matches,
    /// so a stale reattach queued against the OLD target can't fire against the new one.
    private var attachGeneration = 0
    /// Set by the representable's update from the owning view: is this card renderable-live right now?
    /// (Derived from `displayState(phase:connection:).statusKey == .running/.idle/.needsPermission` — i.e.
    /// a `.live` phase on a live link. A dead/creating card must NOT auto-re-attach.)
    var attachWhileLive: () -> Bool = { false }
    /// Re-attach closure the representable installs (calls `attach(term)` on the tracked view).
    var reattach: () -> Void = {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // The pane died: if a stabilize window was pending, this reattach did NOT survive it → keep the
        // (already-incremented) budget so the flap stays bounded. Never reset here.
        stabilizeWork?.cancel(); stabilizeWork = nil
        guard !reconnectPending, attachWhileLive() else { return }
        guard let delaySecs = reconnectPolicy.delay(forAttempt: reconnects + 1) else { return }  // budget spent → stop
        reconnectPending = true
        reconnects += 1
        let gen = attachGeneration   // capture: a target change (resetForNewTarget) invalidates this block
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delaySecs)) { [weak self] in
            guard let self, self.attachGeneration == gen, self.attachWhileLive() else {
                self?.reconnectPending = false; return
            }
            self.reconnectPending = false
            self.reattach()
            self.scheduleStabilize()   // if THIS reattach survives the window, restore the full budget
        }
    }

    /// A reattach that survives `stabilizeWindow` is a genuine success (the iOS `.connected` analog — the
    /// local process has no explicit "connected" callback, so staying alive IS the signal). Restoring the
    /// budget means a LATER, independent drop gets a fresh [1,2,4,8,8]; a pane that re-exits inside the
    /// window cancels this in `processTerminated`, so a tmux-gone flap stays bounded by `maxReconnects`.
    private func scheduleStabilize() {
        stabilizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconnects = 0 }
        stabilizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stabilizeWindow, execute: work)
    }

    /// The attach TARGET changed (a genuinely new session/window) → a fresh terminal, fresh budget. Bumping
    /// `attachGeneration` also invalidates any in-flight backoff block queued against the old target.
    func resetForNewTarget() {
        attachGeneration &+= 1
        stabilizeWork?.cancel(); stabilizeWork = nil
        reconnects = 0; reconnectPending = false
    }
}
```

> **Assumption:** SwiftTerm delivers `processTerminated` **asynchronously** (on the runloop), not synchronously inside `reattach()`'s `startProcess` — matching the existing coordinator. The whole scheme (cancel-then-reschedule, generation capture) relies on that; all three fields are mutated only on the main thread, so there is no cross-thread race.

> **Why not reset the budget when `attach()` returns (round-2 finding):** `attach()` only *starts* `/bin/sh -c "tmux attach …"` — it is NOT evidence the pane stayed up. If the tmux session is gone (a card that reads `.live` for a beat while its session already vanished), the process exits immediately and `processTerminated` re-fires; resetting `reconnects` on attach-start would let the bounded `[1,2,4,8,8]` loop **forever**. So the budget resets ONLY via `scheduleStabilize` (a reattach that survives `stabilizeWindow`) or `resetForNewTarget` (a new session) — never on attempt-start. This mirrors iOS, which resets on the channel's genuine `.connected` event (`IOSTerminalView.swift:299-301`), not on "attempt started".

Thread the gate in via a new **optional** representable param (NOT a `BoardModel` — keeps `AgentTerminalView` model-free). Add to the struct + its `init` (`:24-40`):

```swift
/// When set, a dead pane auto-re-attaches while this returns true (a `.live` card on a live link).
/// nil (default) → no auto-reattach, so ShellTabsView's shells opt out unchanged.
var attachWhileLiveGate: (() -> Bool)? = nil   // named distinctly from the Coordinator's own `attachWhileLive`
```

In `makeNSView`/`updateNSView` (`:60,75`) install the gate onto the coordinator (re-install in `updateNSView` so it snapshots the *current* phase/connection): `context.coordinator.attachWhileLive = { attachWhileLiveGate?() ?? false }` and `context.coordinator.reattach = { [weak view] in if let view { attach(view) } }`. In `updateNSView`, when the attach **target changes** (the existing `coordinator.attached != target` branch at `:75`), call `context.coordinator.resetForNewTarget()` (a genuinely new terminal ⇒ fresh budget). Do **not** reset the budget from `attach()`.

The single opt-in call site — `InspectorView.swift:357` (the agent pane) — passes:

```swift
AgentTerminalView(socket: model.terminalTmuxSocket, session: task.tmuxSession, window: "agent",
                  /* existing args… */,
                  attachWhileLiveGate: { !displayState(phase: task.phase, connection: model.connectionState).isStale
                                     && [.running, .idle, .needsPermission].contains(task.phaseDisplay) })
```

> The gate is "a `.live(_)` phase (`statusKey ∈ {.running, .idle, .needsPermission}`) on a non-stale link" — a `dead`/`creatingWorktree` card, or a down link, must NOT auto-re-attach.

- [ ] **Step 7: Build + manual mac check (isolated instance)**

```bash
swift test --no-parallel     # policy + full suite green
scripts/build-app.sh         # mac App builds with the new coordinator wiring
```

Manual (ISOLATED app per the project recipe — `scripts/orch-ui-shot.sh` / `scripts/orch-test.sh`, NEVER the live app):
- with a `.live` card, kill its tmux attach pane once and confirm the mac terminal re-attaches (matches iOS);
- with a `dead` card, confirm it does NOT auto-re-attach;
- **bounded-flap (round-2 finding):** kill the whole tmux *session* under a `.live` card so every reattach exits immediately — confirm it retries at most `maxReconnects` (5) times with `[1,2,4,8,8]`s backoff and then STOPS (does not loop forever), because a pane that never survives the 5s stabilize window never resets the budget.
Paste the screenshot back.

- [ ] **Step 8: Commit**

```bash
git add Sources/OrchestraKit/TerminalReconnectPolicy.swift App-iOS/Terminal/IOSTerminalView.swift App/Views/AgentTerminalView.swift App/Views/InspectorView.swift Tests/OrchestraUITests/TerminalReconnectPolicyTests.swift
git commit -m "feat(ui): shared TerminalReconnectPolicy; mac terminal reuses the iOS bounded backoff"
```

---

### Task 5: Docs

**Files:** Modify `docs/02-architecture.md`.

- [ ] **Step 1:** Under `#the-client-transport-seam-and-reconnect`, document (a) the per-RPC deadline + ping keepalive from PR6a and (b) the shared `TerminalReconnectPolicy` (bounded exponential `min(8, 2^(n-1))`, `maxReconnects` budget) now shared by both terminal hosts.

- [ ] **Step 2:** Under `#the-three-clients`, document `displayState(phase:connection:)` as the one render contract — every surface derives its label (via `PhaseDisplayKey.label`), color (`Theme.statusColor`), and `validActions` (from `CommandCatalog.phaseGate`) from it; a disconnected link drops every daemon verb from `validActions` (local-only affordances remain) and sets `isStale`; `dead(.spawnFailed)` renders **Dead**, never "Creating…".

- [ ] **Step 3: Commit**

```bash
git add docs/02-architecture.md
git commit -m "docs(arch): displayState contract + deadlines/keepalive + shared reconnect policy"
```

---

## Self-Review

**1. Spec coverage (Tasks 6.4–6.6):**
- 6.4 `displayState` + derived `validActions` → Task 1. ✔ Honest toasts (archive/move/send) → Task 2. ✔ Double-spawn guard → Task 2. ✔ PR6a carry-forward: client-minted id reuse-on-retry (`spawnAttemptId` + sheet `pendingSpawnId`) → Task 2 (`test_spawnRetryReusesId`) + Task 3. ✔ Every surface renders from it + action gating → Task 3. ✔ `dead(.spawnFailed)` ≠ "Creating…" → Task 1 test + Task 3 copy. ✔ Both Recovery panels explain `spawnFailed` + offer restart → Task 3. ✔
- 6.5 shared `TerminalReconnectPolicy` + mac wire + manual check → Task 4. ✔
- 6.6 docs → Task 5. ✔
- Named tests present: `test_displayStateActionsByPhase`, `test_archiveFailureToastIsHonest`, `test_doubleSpawnGuarded`, `test_reconnectPolicyBackoff`. ✔

**2. Placeholder scan:** every code step shows the code; every command names its expected result; UI-wiring steps that can't be unit-tested state the build/manual gate explicitly. No "TBD"/"handle edge cases". ✔

**3. Type consistency:** `displayState(phase:connection:)`, `DisplayState{statusKey,label,validActions,isBusy,isStale}`, `Verb`, `Phase.displayKey`, `PhaseDisplayKey.label`, `TerminalReconnectPolicy.delay(forAttempt:)`, `BoardStore.{isSpawning,beginSpawn,endSpawn,spawn(id:),spawnAttemptId}` are spelled identically across tasks. ✔

**4. Agent-agnostic:** no `if agentId ==` anywhere; `displayState` and the reconnect policy are phase/connection-only. ✔

**5. Contract fidelity:** `validActions` derives from `CommandCatalog.phaseGate` (Task 1 loop over `CommandCatalog.all`), never a hand-copied table; the one deviation (`isStale: Bool` vs `staleSince: Date`) is recorded in Decisions with its cause (PR6a's timestamp-free `ConnectionState`). ✔
