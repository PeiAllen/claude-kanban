# PR D4 — Agent-terminal ownership lease (daemon-authoritative) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the daemon authoritative, ephemeral ownership of each card's live `agent`
terminal — an epoch-guarded lease with four coordination RPCs — so a phone can *Take Over*
a card's agent TUI and the desktop can *Retake* it without two clients resize-fighting over one
tmux window.

**Architecture:** A pure, deterministic ownership state machine (`TerminalOwnershipStore`,
value type, `now` injected) is held actor-isolated by `OrchestraService`. Four service methods
(`agentTerminalOwner` / `takeOverAgentTerminal` / `releaseAgentTerminal` / `heartbeatAgentTerminal`)
mutate it and broadcast a new `Event.agentTerminalOwner` over the **existing** `subscribe` fan-out.
The RPCs are wired as **app-only dispatch cases** in `ControlServer` (the `diffText`/`diffStat`
precedent), **not** `CommandRegistry` verbs — so they never become MCP tools an agent could call.
Shared wire types live in `Model.swift` (post-F1 they re-file into `OrchestraKit`, a no-op move).
Ownership is **UI coordination, not durable card state** — nothing touches the task store.

**Tech Stack:** Swift 6, Swift Testing (`@Test`/`#expect`), UDS + NDJSON JSON-RPC, tmux
(`-L orchestra`, grouped view sessions), the shipped `subscribe`/`Event`/200-item ring, the shipped
`sessions`→`TmuxTarget` attach recipe.

## Global Constraints

- **Provider-neutral.** Ownership is about the card's `agent` *window*, not the agent. No
  `if agent == "claude"` branches — works identically for Claude and Codex.
- **Minimal wire changes.** Exactly these four coordination verbs + one new `Event` case. No
  transcript RPC, no TCP/WebSocket, no daemon PTY proxy.
- **No regressions.** `swift build` and `swift test` stay offline-green; `scripts/build-app.sh`
  (macOS app) and `scripts/build-linux-daemon.sh` keep working. A new `Event` case must not break
  the desktop app's exhaustive `switch` (`App/BoardModel.swift:320`).
- **Ephemeral, not durable.** The owner record is in-memory only. Never persist it to `TaskStore`;
  it is not part of `Task`.
- **Small commits.** One task = one reviewable commit, each ending on a green test.
- **`clientId` is a `String`** (D3's per-install id). Coordinate the owner-event payload's `clientId`
  field with D3's wire shape (see "Dependency: D3" below).
- **Do not conflate with `recovering`.** `OrchestraService.recovering` / `scheduleRecoveringRelease`
  (`OrchestraService+Recovery.swift`) is a session *crash-grace* timer — unrelated to this lease.

## Dependency: D3 (client identity) and the D3↔D4 contract

D4's branch stacks on D3 (`mobile/d3-client-identity`). D3 adds a stable `clientId: String` to the
client↔server session (handshake on `subscribe`/connect; carried on `RPCRequest` alongside `source`)
and lets `ControlServer` map a `PeerConnection` → `clientId` + detect that client's disconnect.

**D4 does not hard-depend on D3's wire mechanism for its acceptance.** The four RPCs take `clientId`
as an **explicit string parameter**, and staleness is **time-based** (`updatedAt` + timeout), so the
lease and every acceptance criterion work even before D3's `RPCRequest.clientId` lands. What D3
*unblocks* is an optional **disconnect fast-path** (Task 6): on a `PeerConnection` drop, if the
dropped connection's `clientId` owns a fresh agent terminal, mark it stale immediately instead of
waiting out the heartbeat window. That fast-path is a latency optimization, not a correctness
requirement.

**The coordination point:** `clientId` is a `String` on both sides. The owner-event payload
(`AgentTerminalOwner.clientId`) uses the identical type and value D3 puts on the wire. If D3 chooses a
different representation (e.g. a struct), revisit Task 1's `clientId` field — but `String` is the
forest's stated shape.

## Design decisions locked in (resolving the forest's open questions)

1. **Placement — app-only dispatch cases, NOT `CommandRegistry` verbs.** The forest's D4 "Files" line
   says "`Commands.swift` (4 verbs)", but the design's open question ("Ownership API placement … not
   necessarily MCP tools") is explicitly unresolved. We resolve it: these are UI-coordination RPCs
   that must **not** surface as MCP tools (an agent taking over a terminal is nonsensical/harmful).
   The shipped precedent is exact — `diffText`/`diffStat`/`openNotes` are app-only `case`s inside
   `ControlServer.dispatch`, commented "*Internal + app-only — NOT a registry Command, so it never
   surfaces as an MCP tool*" (`ControlServer.swift:166-190`). D4 follows that seam. **`Commands.swift`
   is not modified.**
2. **Owner store is a pure value type with injected `now`.** `TerminalOwnershipStore` has no clock,
   no actor, no socket — every mutation takes `now: Date`. This makes the whole state machine
   (CAS, epoch monotonicity, staleness) unit-testable deterministically without sleeping (Task 2),
   while `OrchestraService` (already an `actor`) owns an instance and supplies `Date()` at the edge.
3. **Takeover is unconditional; CAS guards release + heartbeat.** `takeOverAgentTerminal` always
   wins (it reads the current epoch and sets `epoch+1`). That is how a desktop Retake or a second
   phone overrides an older/stale owner. `releaseAgentTerminal` and `heartbeatAgentTerminal` succeed
   **only** if the caller holds the current epoch *and* clientId — otherwise they throw
   `ownershipDenied`. Epoch is **monotonic per card** and never decreases (even across release), so a
   stale release can never match a newer owner. This is the multi-phone / stale-release guard.
4. **`available → desktopOwned → phoneOwned → desktopOwned` is three `takeOver`s** (kinds
   `desktop`, `phone`, `desktop`). The final `→ desktopOwned` is a desktop **Retake** (a `takeOver`
   with `kind: .desktop`), matching design transition 6 — not a `release`.
5. **Owner events are live-only (not ring-replayed).** Only `.activity` items hit the 200-item replay
   ring (`ControlServer.swift:200`). `.agentTerminalOwner` events are delivered live only. A
   (re)connecting client reconciles current ownership by calling `agentTerminalOwner(ref)` — the
   query RPC is the reconcile-on-connect path. **This is part of the D5 contract.**
6. **Heartbeat does not emit; staleness is derived from `updatedAt`.** A heartbeat is a keepalive —
   emitting on every one would spam the stream. Only `takeOver` and `release` emit (ownership
   identity changed). Both the event payload and the query response carry `owner.updatedAt`, so a
   consumer computes staleness locally (`now - updatedAt > heartbeatTimeout`) and the server also
   reports `stale` in query responses. **`heartbeatTimeout = 30s`; recommended client heartbeat
   cadence = every 10s (⅓ of the window).**

## File structure

- **Create** `Sources/OrchestraCore/TerminalOwnership.swift` — the pure `TerminalOwnershipStore`
  state machine (`OwnerKey`, slots, `snapshot`/`takeOver`/`release`/`heartbeat`). Daemon-only.
- **Modify** `Sources/OrchestraCore/Model.swift` — shared wire types (`AgentTerminalOwnerKind`,
  `AgentTerminalOwner`, `AgentTerminalOwnerState`, `TakeOverResult`) + the new `Event` case.
  *(Post-F1 these re-file into `OrchestraKit`; that move is a no-op rename — call it out in the F1
  plan, not here.)*
- **Modify** `Sources/OrchestraCore/Errors.swift` — add `ownershipDenied`.
- **Modify** `Sources/OrchestraCore/OrchestraService.swift` — hold the store; add the four service
  methods + the `agentTarget` helper; emit events.
- **Modify** `Sources/OrchestraCore/SessionManager.swift` — best-effort `detachAgentViewClients`.
- **Modify** `Sources/OrchestraCore/Control/ControlServer.swift` — four app-only `dispatch` cases.
- **Modify** `Sources/OrchestraCore/Control/ControlClient.swift` — four typed convenience methods.
- **Modify** `App/BoardModel.swift` — a no-op `case .agentTerminalOwner: break` so the desktop build
  stays green (D5 wires real behavior).
- **Test** `Tests/OrchestraCoreTests/TerminalOwnershipTests.swift` (Task 2, pure state machine).
- **Test** `Tests/OrchestraCoreTests/TerminalOwnershipServiceTests.swift` (Task 3, service + emit).
- **Test** `Tests/OrchestraCoreTests/TerminalOwnershipRoundTripTests.swift` (Task 4 + Task 5, the
  acceptance integration test over a real UDS socket).

---

### Task 1: Shared wire types + `Event` case + error

**Files:**
- Modify: `Sources/OrchestraCore/Model.swift` (after the `TmuxTarget` block, ~line 429; and the
  `Event` enum at `:577-581`)
- Modify: `Sources/OrchestraCore/Errors.swift`
- Modify: `App/BoardModel.swift:320-357` (the `switch event` block)
- Test: `Tests/OrchestraCoreTests/TerminalOwnershipTests.swift` (codec suite; state-machine tests
  land in Task 2)

**Interfaces:**
- Produces (consumed by every later task and by D5/T4):
  - `enum AgentTerminalOwnerKind: String, Codable, Sendable, Equatable { case desktop, phone }`
  - `struct AgentTerminalOwner: Codable, Sendable, Equatable` — fields
    `ownerKind: AgentTerminalOwnerKind`, `clientId: String`, `epoch: Int`, `cardId: UUID`,
    `window: String`, `updatedAt: Date`.
  - `struct AgentTerminalOwnerState: Codable, Sendable, Equatable` — fields `ref: String`,
    `cardId: UUID`, `window: String`, `owner: AgentTerminalOwner?` (`nil` ⇒ available), `epoch: Int`,
    `stale: Bool`.
  - `struct TakeOverResult: Codable, Sendable, Equatable` — fields `state: AgentTerminalOwnerState`,
    `target: TmuxTarget`.
  - `Event.agentTerminalOwner(AgentTerminalOwnerState)`.
  - `OrchestraError.ownershipDenied(String)` (code `1012`).

- [ ] **Step 1: Write the failing codec test**

Create `Tests/OrchestraCoreTests/TerminalOwnershipTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Agent-terminal ownership — wire types")
struct TerminalOwnershipWireTests {

    @Test("AgentTerminalOwnerState round-trips through the shared JSON codec")
    func stateRoundTrips() throws {
        let card = UUID()
        let owner = AgentTerminalOwner(ownerKind: .phone, clientId: "phone-abc", epoch: 3,
                                       cardId: card, window: "agent",
                                       updatedAt: Date(timeIntervalSince1970: 1_000_000))
        let state = AgentTerminalOwnerState(ref: "ab12cd", cardId: card, window: "agent",
                                            owner: owner, epoch: 3, stale: false)
        let data = try OrchestraJSON.wire.encode(state)
        let back = try OrchestraJSON.decoder.decode(AgentTerminalOwnerState.self, from: data)
        #expect(back == state)
        #expect(back.owner?.ownerKind == .phone)
        #expect(back.owner?.clientId == "phone-abc")
    }

    @Test("an available state encodes owner == null")
    func availableEncodesNull() throws {
        let state = AgentTerminalOwnerState(ref: "x", cardId: UUID(), window: "agent",
                                            owner: nil, epoch: 0, stale: false)
        let data = try OrchestraJSON.wire.encode(state)
        let back = try OrchestraJSON.decoder.decode(AgentTerminalOwnerState.self, from: data)
        #expect(back.owner == nil)
    }

    @Test("Event.agentTerminalOwner survives the same Event codec the stream uses")
    func eventRoundTrips() throws {
        let state = AgentTerminalOwnerState(ref: "x", cardId: UUID(), window: "agent",
                                            owner: nil, epoch: 0, stale: false)
        let event = Event.agentTerminalOwner(state)
        let data = try OrchestraJSON.wire.encode(event)
        let back = try OrchestraJSON.decoder.decode(Event.self, from: data)
        #expect(back == event)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TerminalOwnershipWireTests`
Expected: FAIL — `AgentTerminalOwner` / `AgentTerminalOwnerState` / `Event.agentTerminalOwner` are
undefined (compile error).

- [ ] **Step 3: Add the wire types to `Model.swift`**

Insert after the `TmuxTarget` struct (after `Model.swift:429`):

```swift
// MARK: - Agent-terminal ownership (ephemeral UI coordination — NOT durable card state)

/// Which surface currently owns a card's live `agent` terminal.
public enum AgentTerminalOwnerKind: String, Codable, Sendable, Equatable {
    case desktop, phone
}

/// The ephemeral owner of one card's `agent` window. `epoch` is a monotonic per-card counter that
/// makes stale releases/heartbeats safe: only the holder of the *current* epoch may release or refresh.
public struct AgentTerminalOwner: Codable, Sendable, Equatable {
    public let ownerKind: AgentTerminalOwnerKind
    public let clientId: String       // D3's per-install client id; the owning surface
    public let epoch: Int
    public let cardId: UUID
    public let window: String          // always "agent" in v1; keyed for future windows
    public let updatedAt: Date
    public init(ownerKind: AgentTerminalOwnerKind, clientId: String, epoch: Int,
                cardId: UUID, window: String, updatedAt: Date) {
        self.ownerKind = ownerKind; self.clientId = clientId; self.epoch = epoch
        self.cardId = cardId; self.window = window; self.updatedAt = updatedAt
    }
}

/// Snapshot returned by `agentTerminalOwner` and broadcast on the event stream. `owner == nil` means
/// *available*. `epoch` is the current per-card epoch even when available (monotonic). `stale` is true
/// when an owner exists but hasn't heartbeated within the timeout.
public struct AgentTerminalOwnerState: Codable, Sendable, Equatable {
    public let ref: String
    public let cardId: UUID
    public let window: String
    public let owner: AgentTerminalOwner?
    public let epoch: Int
    public let stale: Bool
    public init(ref: String, cardId: UUID, window: String,
                owner: AgentTerminalOwner?, epoch: Int, stale: Bool) {
        self.ref = ref; self.cardId = cardId; self.window = window
        self.owner = owner; self.epoch = epoch; self.stale = stale
    }
}

/// `takeOverAgentTerminal` result: the new ownership state + the tmux attach target for the caller
/// (the card's `agent` window, reusing the shipped `sessions`→`TmuxTarget` discovery).
public struct TakeOverResult: Codable, Sendable, Equatable {
    public let state: AgentTerminalOwnerState
    public let target: TmuxTarget
    public init(state: AgentTerminalOwnerState, target: TmuxTarget) {
        self.state = state; self.target = target
    }
}
```

- [ ] **Step 4: Add the `Event` case**

Modify the `Event` enum (`Model.swift:577-581`):

```swift
public enum Event: Codable, Sendable, Equatable {
    case taskUpserted(Task)
    case taskRemoved(UUID)
    case activity(ActivityItem)
    /// Ephemeral agent-terminal ownership change. Live-only — NOT ring-replayed (only `.activity`
    /// is). A (re)connecting client reconciles via `agentTerminalOwner(ref)`.
    case agentTerminalOwner(AgentTerminalOwnerState)
}
```

- [ ] **Step 5: Add the error case**

In `Errors.swift`, add to the enum (after `.trustDenied`):

```swift
    case ownershipDenied(String)   // CAS failure: release/heartbeat by a non-current epoch/clientId
```

to `description`:

```swift
        case .ownershipDenied(let m): return "ownership denied: \(m)"
```

to `code`:

```swift
        case .ownershipDenied:  return 1012
```

- [ ] **Step 6: Keep the desktop build green — add the no-op `Event` case**

The new `Event` case makes `App/BoardModel.swift:320`'s `switch event` non-exhaustive, which breaks
`scripts/build-app.sh`. Add a no-op arm inside that switch (alongside `case .taskUpserted` /
`.taskRemoved` / `.activity`):

```swift
        case .agentTerminalOwner:
            break   // D5 (desktop-unmount) consumes this; D4 keeps the desktop build green with a no-op.
```

- [ ] **Step 7: Run the codec test to verify it passes**

Run: `swift test --filter TerminalOwnershipWireTests`
Expected: PASS (3 tests).

- [ ] **Step 8: Confirm no build regressions**

Run: `swift build && swift test 2>&1 | tail -5`
Expected: build succeeds, existing suite green.
Run: `scripts/build-app.sh 2>&1 | tail -3` (macOS app — confirms the `BoardModel` switch compiles).
Expected: app builds.

- [ ] **Step 9: Commit**

```bash
git add Sources/OrchestraCore/Model.swift Sources/OrchestraCore/Errors.swift \
        App/BoardModel.swift Tests/OrchestraCoreTests/TerminalOwnershipTests.swift
git commit -m "feat(d4): agent-terminal ownership wire types + Event case"
```

---

### Task 2: `TerminalOwnershipStore` — the pure state machine

**Files:**
- Create: `Sources/OrchestraCore/TerminalOwnership.swift`
- Test: `Tests/OrchestraCoreTests/TerminalOwnershipTests.swift` (extend with a state-machine suite)

**Interfaces:**
- Consumes: `AgentTerminalOwner`, `AgentTerminalOwnerState`, `AgentTerminalOwnerKind`,
  `OrchestraError.ownershipDenied` (Task 1).
- Produces (consumed by Task 3):
  - `struct TerminalOwnershipStore: Sendable` with `var heartbeatTimeout: TimeInterval` (default `30`)
    and `static let agentWindow = "agent"`.
  - `func snapshot(cardId:ref:now:window:) -> AgentTerminalOwnerState`
  - `mutating func takeOver(cardId:ref:clientId:kind:now:window:) -> AgentTerminalOwnerState`
  - `mutating func release(cardId:ref:clientId:epoch:now:window:) throws -> AgentTerminalOwnerState`
  - `mutating func heartbeat(cardId:ref:clientId:epoch:now:window:) throws -> AgentTerminalOwnerState`
  - (all `window:` params default to `agentWindow`).

- [ ] **Step 1: Write the failing state-machine test**

Append to `Tests/OrchestraCoreTests/TerminalOwnershipTests.swift`:

```swift
@Suite("Agent-terminal ownership — state machine")
struct TerminalOwnershipStateTests {
    let card = UUID()
    let ref = "ab12cd"
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("drives available → desktopOwned → phoneOwned → desktopOwned with a monotonic epoch")
    func fullDrive() throws {
        var s = TerminalOwnershipStore()
        #expect(s.snapshot(cardId: card, ref: ref, now: t0).owner == nil)          // available
        #expect(s.snapshot(cardId: card, ref: ref, now: t0).epoch == 0)

        let d1 = s.takeOver(cardId: card, ref: ref, clientId: "desk", kind: .desktop, now: t0)
        #expect(d1.owner?.ownerKind == .desktop)
        #expect(d1.epoch == 1)

        let p2 = s.takeOver(cardId: card, ref: ref, clientId: "phone", kind: .phone, now: t0)
        #expect(p2.owner?.ownerKind == .phone)
        #expect(p2.owner?.clientId == "phone")
        #expect(p2.epoch == 2)

        let d3 = s.takeOver(cardId: card, ref: ref, clientId: "desk", kind: .desktop, now: t0)  // Retake
        #expect(d3.owner?.ownerKind == .desktop)
        #expect(d3.epoch == 3)
    }

    @Test("a release by the current epoch+clientId clears the owner; epoch stays monotonic")
    func releaseByCurrent() throws {
        var s = TerminalOwnershipStore()
        let a = s.takeOver(cardId: card, ref: ref, clientId: "phone", kind: .phone, now: t0)
        let after = try s.release(cardId: card, ref: ref, clientId: "phone", epoch: a.epoch, now: t0)
        #expect(after.owner == nil)                 // available
        #expect(after.epoch == 1)                   // epoch preserved
        // next takeOver must increment PAST the released epoch
        #expect(s.takeOver(cardId: card, ref: ref, clientId: "desk", kind: .desktop, now: t0).epoch == 2)
    }

    @Test("a stale-epoch release is REJECTED and does not clear the newer owner")
    func staleReleaseRejected() throws {
        var s = TerminalOwnershipStore()
        let p1 = s.takeOver(cardId: card, ref: ref, clientId: "phoneA", kind: .phone, now: t0)  // epoch 1
        _ = s.takeOver(cardId: card, ref: ref, clientId: "phoneB", kind: .phone, now: t0)       // epoch 2 wins
        #expect(throws: OrchestraError.self) {
            _ = try s.release(cardId: card, ref: ref, clientId: "phoneA", epoch: p1.epoch, now: t0)
        }
        // phoneB is still the fresh owner
        let now = s.snapshot(cardId: card, ref: ref, now: t0)
        #expect(now.owner?.clientId == "phoneB")
        #expect(now.epoch == 2)
    }

    @Test("a release with the right epoch but the wrong clientId is REJECTED")
    func wrongClientReleaseRejected() throws {
        var s = TerminalOwnershipStore()
        let a = s.takeOver(cardId: card, ref: ref, clientId: "phone", kind: .phone, now: t0)
        #expect(throws: OrchestraError.self) {
            _ = try s.release(cardId: card, ref: ref, clientId: "intruder", epoch: a.epoch, now: t0)
        }
    }

    @Test("heartbeat by the current owner refreshes updatedAt and stays fresh")
    func heartbeatRefreshes() throws {
        var s = TerminalOwnershipStore()
        s.heartbeatTimeout = 30
        let a = s.takeOver(cardId: card, ref: ref, clientId: "phone", kind: .phone, now: t0)
        let t20 = t0.addingTimeInterval(20)
        let hb = try s.heartbeat(cardId: card, ref: ref, clientId: "phone", epoch: a.epoch, now: t20)
        #expect(hb.stale == false)
        #expect(hb.owner?.updatedAt == t20)
        // 20s after the heartbeat is still inside the 30s window
        #expect(s.snapshot(cardId: card, ref: ref, now: t20.addingTimeInterval(20)).stale == false)
    }

    @Test("a stale-epoch heartbeat is REJECTED")
    func staleHeartbeatRejected() throws {
        var s = TerminalOwnershipStore()
        let p1 = s.takeOver(cardId: card, ref: ref, clientId: "phoneA", kind: .phone, now: t0)
        _ = s.takeOver(cardId: card, ref: ref, clientId: "phoneB", kind: .phone, now: t0)
        #expect(throws: OrchestraError.self) {
            _ = try s.heartbeat(cardId: card, ref: ref, clientId: "phoneA", epoch: p1.epoch, now: t0)
        }
    }

    @Test("an owner with no heartbeat goes stale after the timeout (a phone disconnect)")
    func goesStaleAfterTimeout() throws {
        var s = TerminalOwnershipStore()
        s.heartbeatTimeout = 30
        _ = s.takeOver(cardId: card, ref: ref, clientId: "phone", kind: .phone, now: t0)
        #expect(s.snapshot(cardId: card, ref: ref, now: t0.addingTimeInterval(29)).stale == false)
        #expect(s.snapshot(cardId: card, ref: ref, now: t0.addingTimeInterval(31)).stale == true)
        // stale, but the owner is NOT cleared — a desktop Force Retake overrides it
        let s31 = s.snapshot(cardId: card, ref: ref, now: t0.addingTimeInterval(31))
        #expect(s31.owner?.ownerKind == .phone)
        let retake = s.takeOver(cardId: card, ref: ref, clientId: "desk", kind: .desktop,
                                now: t0.addingTimeInterval(31))
        #expect(retake.owner?.ownerKind == .desktop)
        #expect(retake.epoch == 2)
        #expect(retake.stale == false)
    }

    @Test("ownership is per-card: two cards keep independent epochs and owners")
    func perCardIsolation() throws {
        var s = TerminalOwnershipStore()
        let cardB = UUID()
        _ = s.takeOver(cardId: card, ref: "a", clientId: "p1", kind: .phone, now: t0)
        _ = s.takeOver(cardId: card, ref: "a", clientId: "p1", kind: .phone, now: t0)  // epoch 2 on card A
        let b = s.takeOver(cardId: cardB, ref: "b", clientId: "p2", kind: .desktop, now: t0)
        #expect(b.epoch == 1)                                                          // card B independent
        #expect(s.snapshot(cardId: card, ref: "a", now: t0).epoch == 2)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TerminalOwnershipStateTests`
Expected: FAIL — `TerminalOwnershipStore` is undefined.

- [ ] **Step 3: Implement `TerminalOwnership.swift`**

Create `Sources/OrchestraCore/TerminalOwnership.swift`:

```swift
import Foundation

/// Key for an owned terminal: a card + a window (only `agent` in v1).
struct OwnerKey: Hashable, Sendable {
    let cardId: UUID
    let window: String
}

/// The daemon-authoritative, ephemeral ownership store for card `agent` terminals. A PURE value type:
/// every mutation takes an injected `now`, so the state machine (CAS, epoch monotonicity, staleness)
/// is deterministically unit-testable without a clock, an actor, or a socket. `OrchestraService`
/// (an actor) owns one instance and supplies `Date()` at the edge.
///
/// Per-card machine: available → desktopOwned → phoneOwned → desktopOwned (any→any via `takeOver`).
/// `epoch` is monotonic per card and never decreases — even across `release` — which is exactly what
/// makes a stale release/heartbeat safe: it can never match a newer owner.
struct TerminalOwnershipStore: Sendable {
    /// An owner goes stale this long after its last `takeOver`/`heartbeat`.
    var heartbeatTimeout: TimeInterval = 30
    static let agentWindow = "agent"

    private struct Slot { var owner: AgentTerminalOwner?; var epoch: Int }
    private var slots: [OwnerKey: Slot] = [:]

    private func isStale(_ owner: AgentTerminalOwner, now: Date) -> Bool {
        now.timeIntervalSince(owner.updatedAt) > heartbeatTimeout
    }

    private func state(_ key: OwnerKey, _ ref: String, now: Date) -> AgentTerminalOwnerState {
        let slot = slots[key]
        let owner = slot?.owner
        return AgentTerminalOwnerState(
            ref: ref, cardId: key.cardId, window: key.window,
            owner: owner, epoch: slot?.epoch ?? 0,
            stale: owner.map { isStale($0, now: now) } ?? false)
    }

    /// Current ownership snapshot (read-only).
    func snapshot(cardId: UUID, ref: String, now: Date,
                  window: String = agentWindow) -> AgentTerminalOwnerState {
        state(OwnerKey(cardId: cardId, window: window), ref, now: now)
    }

    /// Unconditional acquisition: bump the epoch, set the owner, refresh `updatedAt`. ALWAYS wins —
    /// this is how a desktop Retake or a second phone overrides a stale/older owner.
    mutating func takeOver(cardId: UUID, ref: String, clientId: String,
                           kind: AgentTerminalOwnerKind, now: Date,
                           window: String = agentWindow) -> AgentTerminalOwnerState {
        let key = OwnerKey(cardId: cardId, window: window)
        let nextEpoch = (slots[key]?.epoch ?? 0) + 1
        let owner = AgentTerminalOwner(ownerKind: kind, clientId: clientId, epoch: nextEpoch,
                                       cardId: cardId, window: window, updatedAt: now)
        slots[key] = Slot(owner: owner, epoch: nextEpoch)
        return state(key, ref, now: now)
    }

    /// Clear the owner ONLY if the caller holds the current epoch AND clientId. Epoch is preserved
    /// (monotonic) so a later `takeOver` still increments past it. Throws `ownershipDenied` on CAS miss.
    mutating func release(cardId: UUID, ref: String, clientId: String, epoch: Int, now: Date,
                          window: String = agentWindow) throws -> AgentTerminalOwnerState {
        let key = OwnerKey(cardId: cardId, window: window)
        guard let slot = slots[key], let owner = slot.owner,
              owner.epoch == epoch, owner.clientId == clientId else {
            throw OrchestraError.ownershipDenied("release: not the current owner (epoch \(epoch))")
        }
        slots[key] = Slot(owner: nil, epoch: slot.epoch)   // keep epoch monotonic
        return state(key, ref, now: now)
    }

    /// Refresh the owner's `updatedAt` ONLY if the caller holds the current epoch AND clientId. Throws
    /// on CAS miss (owner changed / was taken over). Returns the refreshed (fresh) state.
    mutating func heartbeat(cardId: UUID, ref: String, clientId: String, epoch: Int, now: Date,
                            window: String = agentWindow) throws -> AgentTerminalOwnerState {
        let key = OwnerKey(cardId: cardId, window: window)
        guard let slot = slots[key], let owner = slot.owner,
              owner.epoch == epoch, owner.clientId == clientId else {
            throw OrchestraError.ownershipDenied("heartbeat: not the current owner (epoch \(epoch))")
        }
        let refreshed = AgentTerminalOwner(ownerKind: owner.ownerKind, clientId: owner.clientId,
                                           epoch: owner.epoch, cardId: owner.cardId,
                                           window: owner.window, updatedAt: now)
        slots[key] = Slot(owner: refreshed, epoch: slot.epoch)
        return state(key, ref, now: now)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter TerminalOwnershipStateTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/TerminalOwnership.swift Tests/OrchestraCoreTests/TerminalOwnershipTests.swift
git commit -m "feat(d4): pure epoch-guarded TerminalOwnershipStore state machine"
```

---

### Task 3: Wire the store into `OrchestraService` + emit owner events

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (add a stored `terminalOwnership` field near
  the other fan-out state ~`:41`; add the four methods + `agentTarget` near the `exec`/`sessions`
  methods ~`:567-590`)
- Test: `Tests/OrchestraCoreTests/TerminalOwnershipServiceTests.swift`

**Interfaces:**
- Consumes: `TerminalOwnershipStore` (Task 2); the shipped `resolveRef` (`OrchestraService:625`),
  `sessions(_ id:)` (`:577`), `emit(_:)` (`:98`), `Task.ref()`.
- Produces (consumed by Task 4):
  - `var terminalOwnership: TerminalOwnershipStore` (actor-isolated; also lets tests set the timeout).
  - `func agentTerminalOwner(_ ref: String) async throws -> AgentTerminalOwnerState`
  - `func takeOverAgentTerminal(_ ref: String, clientId: String, kind: AgentTerminalOwnerKind) async throws -> TakeOverResult`
  - `func releaseAgentTerminal(_ ref: String, clientId: String, epoch: Int) async throws -> AgentTerminalOwnerState`
  - `func heartbeatAgentTerminal(_ ref: String, clientId: String, epoch: Int) async throws -> AgentTerminalOwnerState`

> Note: `SessionManager.detachAgentViewClients` (called by `takeOverAgentTerminal`) is added in
> Task 5. Until then, `takeOverAgentTerminal` compiles by omitting the detach line; Task 5 adds it.
> To keep each task green, **write the detach call in Task 5**, not here.

- [ ] **Step 1: Write the failing service test**

Create `Tests/OrchestraCoreTests/TerminalOwnershipServiceTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("OrchestraService — agent-terminal ownership", .serialized)
struct TerminalOwnershipServiceTests {

    @Test("drives available → desktop → phone → desktop and emits an owner event each takeOver")
    func driveAndEmit() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        let task = try await env.svc.spawn(
            SpawnInput(prompt: "own me", repo: repo, branch: "feat"), source: .app)
        let ref = task.shortId

        // available
        #expect(try await env.svc.agentTerminalOwner(ref).owner == nil)

        // desktop takeover → epoch 1, returns an attach target for the agent window
        let d = try await env.svc.takeOverAgentTerminal(ref, clientId: "desk", kind: .desktop)
        #expect(d.state.owner?.ownerKind == .desktop)
        #expect(d.state.epoch == 1)
        #expect(d.target.kind == .agent)

        // phone takeover → epoch 2
        let p = try await env.svc.takeOverAgentTerminal(ref, clientId: "phone", kind: .phone)
        #expect(p.state.owner?.ownerKind == .phone)
        #expect(p.state.epoch == 2)

        // desktop retake → epoch 3
        let r = try await env.svc.takeOverAgentTerminal(ref, clientId: "desk", kind: .desktop)
        #expect(r.state.epoch == 3)

        // three ownership events reached subscribers
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        let owns = await collector.ownerStates
        #expect(owns.filter { $0.cardId == task.id }.count >= 3)
        #expect(owns.last?.owner?.ownerKind == .desktop)
    }

    @Test("a stale-epoch release is rejected and leaves the fresh owner intact")
    func staleReleaseRejected() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await env.svc.spawn(
            SpawnInput(prompt: "x", repo: repo, branch: "b"), source: .app)
        let ref = task.shortId
        let a = try await env.svc.takeOverAgentTerminal(ref, clientId: "phoneA", kind: .phone)
        _ = try await env.svc.takeOverAgentTerminal(ref, clientId: "phoneB", kind: .phone)
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.releaseAgentTerminal(ref, clientId: "phoneA", epoch: a.state.epoch)
        }
        #expect(try await env.svc.agentTerminalOwner(ref).owner?.clientId == "phoneB")
    }
}
```

This test needs the shared `EventCollector` (`Tests/OrchestraCoreTests/Stubs.swift:132`) to expose an
`ownerStates` accessor. It stores raw `events: [Event]` and derives typed views as **computed
properties** (`activities`, `upserts`) — add a matching one (do NOT add a switch/accumulator):

```swift
// in EventCollector (Stubs.swift), alongside `activities`/`upserts`:
var ownerStates: [AgentTerminalOwnerState] {
    events.compactMap { if case .agentTerminalOwner(let s) = $0 { return s } else { return nil } }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TerminalOwnershipServiceTests`
Expected: FAIL — `agentTerminalOwner`/`takeOverAgentTerminal`/etc. are undefined on `OrchestraService`
(and `ownerStates` if the collector wasn't extended).

- [ ] **Step 3: Add the store field**

In `OrchestraService.swift`, near the fan-out state (after `subscribers` at `:41`):

```swift
    // Ephemeral, daemon-authoritative agent-terminal ownership (UI coordination — never persisted).
    var terminalOwnership = TerminalOwnershipStore()
```

- [ ] **Step 4: Add the four service methods + the attach-target helper**

In `OrchestraService.swift`, after `sessions(_ id:)` (~`:590`):

```swift
    // MARK: - Agent-terminal ownership (ephemeral UI coordination)

    /// Current owner of the card's `agent` terminal (owner + epoch + stale/fresh). Read-only.
    public func agentTerminalOwner(_ ref: String) async throws -> AgentTerminalOwnerState {
        let t = try await resolveRef(ref)
        return terminalOwnership.snapshot(cardId: t.id, ref: t.ref(), now: Date())
    }

    /// Compare-and-set acquisition of the card's `agent` terminal: bump the epoch, set the owner,
    /// emit an owner event, and return the tmux attach target. Always wins (desktop Retake / takeover).
    public func takeOverAgentTerminal(_ ref: String, clientId: String,
                                      kind: AgentTerminalOwnerKind) async throws -> TakeOverResult {
        let t = try await resolveRef(ref)
        let state = terminalOwnership.takeOver(cardId: t.id, ref: t.ref(), clientId: clientId,
                                               kind: kind, now: Date())
        // (Task 5 adds a best-effort detach of prior agent-view clients here.)
        emit(.agentTerminalOwner(state))
        let target = try await agentTarget(t.id)
        return TakeOverResult(state: state, target: target)
    }

    /// Release the card's `agent` terminal — clears the owner ONLY if the caller still holds the
    /// current epoch + clientId; otherwise throws `ownershipDenied`. Emits on success.
    public func releaseAgentTerminal(_ ref: String, clientId: String,
                                     epoch: Int) async throws -> AgentTerminalOwnerState {
        let t = try await resolveRef(ref)
        let state = try terminalOwnership.release(cardId: t.id, ref: t.ref(),
                                                  clientId: clientId, epoch: epoch, now: Date())
        emit(.agentTerminalOwner(state))
        return state
    }

    /// Refresh a takeover across reconnects — succeeds ONLY for the current epoch + clientId; throws
    /// otherwise. Keepalive: does NOT emit (staleness is derived from `updatedAt` by consumers).
    public func heartbeatAgentTerminal(_ ref: String, clientId: String,
                                       epoch: Int) async throws -> AgentTerminalOwnerState {
        let t = try await resolveRef(ref)
        return try terminalOwnership.heartbeat(cardId: t.id, ref: t.ref(),
                                               clientId: clientId, epoch: epoch, now: Date())
    }

    /// The card's `agent` window as a ready-to-attach `TmuxTarget` (reuses the shipped `sessions`
    /// discovery). Throws if the card has no live `agent` window.
    private func agentTarget(_ id: UUID) async throws -> TmuxTarget {
        let cs = try await sessions(id)
        guard let agent = cs.targets.first(where: { $0.kind == .agent }) else {
            throw OrchestraError.io("no agent window for card \(id)")
        }
        return agent
    }
```

> `agentTarget` resolves in the harness: the fake `SessionManaging.windows(_:)`
> (`Tests/OrchestraCoreTests/Stubs.swift:64-68`) returns one `agent` `TmuxTarget` **when the session
> isAlive**, and `spawn` marks the fake session alive — so a spawned card has an `agent` target. No
> harness change needed for the happy path.

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter TerminalOwnershipServiceTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Full suite green**

Run: `swift build && swift test 2>&1 | tail -5`
Expected: green.

- [ ] **Step 7: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift \
        Tests/OrchestraCoreTests/TerminalOwnershipServiceTests.swift \
        Tests/OrchestraCoreTests/*.swift   # if EventCollector was extended
git commit -m "feat(d4): ownership service methods + owner-event emit on the subscribe stream"
```

---

### Task 4: App-only dispatch RPCs + `ControlClient` methods (the acceptance integration test)

**Files:**
- Modify: `Sources/OrchestraCore/Control/ControlServer.swift` (four `case`s in `dispatch`, after the
  `diffStat` case ~`:183`)
- Modify: `Sources/OrchestraCore/Control/ControlClient.swift` (four typed convenience methods)
- Test: `Tests/OrchestraCoreTests/TerminalOwnershipRoundTripTests.swift`

**Interfaces:**
- Consumes: the service methods (Task 3); the `dispatch` switch + `p.optString`/`p.decode` param
  helpers (`ControlServer.swift:104-190`); `ControlClient.call(_:_:as:)` (`ControlClient.swift:94`).
- Produces (consumed by D5/T4 clients):
  - Wire verbs `agentTerminalOwner` / `takeOverAgentTerminal` / `releaseAgentTerminal` /
    `heartbeatAgentTerminal` (app-only; NOT MCP tools).
  - `ControlClient.agentTerminalOwner(_:) async throws -> AgentTerminalOwnerState`
  - `ControlClient.takeOverAgentTerminal(_:clientId:kind:) async throws -> TakeOverResult`
  - `ControlClient.releaseAgentTerminal(_:clientId:epoch:) async throws -> AgentTerminalOwnerState`
  - `ControlClient.heartbeatAgentTerminal(_:clientId:epoch:) async throws -> AgentTerminalOwnerState`

- [ ] **Step 1: Write the failing acceptance integration test**

Create `Tests/OrchestraCoreTests/TerminalOwnershipRoundTripTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Agent-terminal ownership ⇄ ControlServer — the acceptance harness", .serialized)
struct TerminalOwnershipRoundTripTests {
    static func sock() -> String { "/tmp/orch-\(UUID().uuidString.prefix(8)).sock" }

    /// Isolated harness: a hermetic ControlServer+ControlClient over a throwaway UDS socket.
    @Test("available → desktop → phone → desktop; stale release rejected; owner events reach subscribers")
    func acceptance() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        // Shrink the heartbeat window so the disconnect-staleness assertion doesn't sleep 30s.
        await env.svc.setOwnershipHeartbeatTimeout(0.2)

        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }

        // Two clients: "desktop" and "phone".
        let desktop = ControlClient(socketPath: path, source: .app)
        try desktop.connect(); defer { desktop.close() }
        let phone = ControlClient(socketPath: path, source: .app)
        try phone.connect(); defer { phone.close() }

        // Subscribe on the desktop to observe owner events.
        let box = EventBox()
        let stream = desktop.subscribe()
        _Concurrency.Task { for await e in stream { await box.add(e) } }
        try await _Concurrency.Task.sleep(for: .milliseconds(50))

        let task = try await desktop.call("spawn", .object([
            "prompt": .string("own me"), "repo": .string(repo), "branch": .string("feat")]))
            .decode(Task.self)
        let ref = task.shortId

        // available
        #expect(try await desktop.agentTerminalOwner(ref).owner == nil)

        // desktop takeover (epoch 1)
        let d = try await desktop.takeOverAgentTerminal(ref, clientId: "desk", kind: .desktop)
        #expect(d.state.epoch == 1)
        #expect(d.target.kind == .agent)

        // phone takeover (epoch 2)
        let p = try await phone.takeOverAgentTerminal(ref, clientId: "phone", kind: .phone)
        #expect(p.state.owner?.ownerKind == .phone)
        #expect(p.state.epoch == 2)

        // desktop retake (epoch 3)
        let r = try await desktop.takeOverAgentTerminal(ref, clientId: "desk", kind: .desktop)
        #expect(r.state.epoch == 3)
        #expect(r.state.owner?.ownerKind == .desktop)

        // a stale-epoch release (phone's old epoch 2) is REJECTED
        await #expect(throws: (any Error).self) {
            _ = try await phone.releaseAgentTerminal(ref, clientId: "phone", epoch: p.state.epoch)
        }
        #expect(try await desktop.agentTerminalOwner(ref).owner?.ownerKind == .desktop)

        // owner events reached the subscriber (≥ 3 takeovers)
        try await _Concurrency.Task.sleep(for: .milliseconds(100))
        let owners = await box.events.compactMap {
            if case .agentTerminalOwner(let s) = $0 { return s } else { return nil }
        }
        #expect(owners.filter { $0.cardId == task.id }.count >= 3)
    }

    @Test("a phone that stops heartbeating goes stale after the window (disconnect staleness)")
    func staleAfterDisconnect() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        await env.svc.setOwnershipHeartbeatTimeout(0.2)
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }
        let phone = ControlClient(socketPath: path, source: .app)
        try phone.connect(); defer { phone.close() }

        let task = try await phone.call("spawn", .object([
            "prompt": .string("x"), "repo": .string(repo), "branch": .string("b")])).decode(Task.self)
        let ref = task.shortId

        _ = try await phone.takeOverAgentTerminal(ref, clientId: "phone", kind: .phone)
        #expect(try await phone.agentTerminalOwner(ref).stale == false)   // fresh right after
        try await _Concurrency.Task.sleep(for: .milliseconds(300))        // let the 0.2s window lapse
        let after = try await phone.agentTerminalOwner(ref)
        #expect(after.stale == true)              // stale — but still the phone owner
        #expect(after.owner?.ownerKind == .phone)
    }
}
```

This test needs a small test-only setter on the service (the store's `heartbeatTimeout` is a `var`):

```swift
// OrchestraService.swift — near the ownership methods
/// Test hook: shrink/enlarge the ownership heartbeat window (default 30s) so staleness tests
/// don't have to sleep the real timeout. Not called in production.
func setOwnershipHeartbeatTimeout(_ t: TimeInterval) { terminalOwnership.heartbeatTimeout = t }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TerminalOwnershipRoundTripTests`
Expected: FAIL — the `agentTerminalOwner`/`takeOverAgentTerminal`/etc. verbs are method-not-found, and
`ControlClient.agentTerminalOwner(...)` is undefined.

- [ ] **Step 3: Add the four app-only dispatch cases**

In `ControlServer.swift`, inside `dispatch`, after the `diffStat` case (~`:183`, before `default`):

```swift
        case "agentTerminalOwner":
            // App/phone UI coordination — internal + app-only, NOT a registry Command (an agent must
            // never take over a terminal). Ephemeral lease; nothing is persisted to the task store.
            guard let p = req.params, let ref = p.optString("ref") else {
                throw OrchestraError.invalidParams("agentTerminalOwner needs ref")
            }
            return try JSONValue(encodable: await service.agentTerminalOwner(ref))
        case "takeOverAgentTerminal":
            guard let p = req.params, let ref = p.optString("ref"),
                  let clientId = p.optString("clientId"),
                  let kind = p.optString("kind").flatMap(AgentTerminalOwnerKind.init(rawValue:)) else {
                throw OrchestraError.invalidParams("takeOverAgentTerminal needs ref, clientId, kind")
            }
            return try JSONValue(encodable:
                await service.takeOverAgentTerminal(ref, clientId: clientId, kind: kind))
        case "releaseAgentTerminal":
            guard let p = req.params, let ref = p.optString("ref"),
                  let clientId = p.optString("clientId"), let epoch = p.optInt("epoch") else {
                throw OrchestraError.invalidParams("releaseAgentTerminal needs ref, clientId, epoch")
            }
            return try JSONValue(encodable:
                try await service.releaseAgentTerminal(ref, clientId: clientId, epoch: epoch))
        case "heartbeatAgentTerminal":
            guard let p = req.params, let ref = p.optString("ref"),
                  let clientId = p.optString("clientId"), let epoch = p.optInt("epoch") else {
                throw OrchestraError.invalidParams("heartbeatAgentTerminal needs ref, clientId, epoch")
            }
            return try JSONValue(encodable:
                try await service.heartbeatAgentTerminal(ref, clientId: clientId, epoch: epoch))
```

> `p.optInt(_:)` is the shipped param helper (used by `exec`'s `timeout` at `Commands.swift:251`).
> `AgentTerminalOwnerKind(rawValue:)` maps the wire strings `"desktop"`/`"phone"`.

- [ ] **Step 4: Add the four `ControlClient` convenience methods**

In `ControlClient.swift` (after the typed `call<T>` at `:97`):

```swift
    // MARK: - Agent-terminal ownership (app/phone UI coordination)

    public func agentTerminalOwner(_ ref: String) async throws -> AgentTerminalOwnerState {
        try await call("agentTerminalOwner", .object(["ref": .string(ref)]),
                       as: AgentTerminalOwnerState.self)
    }

    public func takeOverAgentTerminal(_ ref: String, clientId: String,
                                      kind: AgentTerminalOwnerKind) async throws -> TakeOverResult {
        try await call("takeOverAgentTerminal", .object([
            "ref": .string(ref), "clientId": .string(clientId), "kind": .string(kind.rawValue),
        ]), as: TakeOverResult.self)
    }

    public func releaseAgentTerminal(_ ref: String, clientId: String,
                                     epoch: Int) async throws -> AgentTerminalOwnerState {
        try await call("releaseAgentTerminal", .object([
            "ref": .string(ref), "clientId": .string(clientId), "epoch": .int(epoch),
        ]), as: AgentTerminalOwnerState.self)
    }

    public func heartbeatAgentTerminal(_ ref: String, clientId: String,
                                       epoch: Int) async throws -> AgentTerminalOwnerState {
        try await call("heartbeatAgentTerminal", .object([
            "ref": .string(ref), "clientId": .string(clientId), "epoch": .int(epoch),
        ]), as: AgentTerminalOwnerState.self)
    }
```

> `JSONValue.int(Int)` (`JSONValue.swift:8`) and `optInt` (`:82`) are the shipped helpers used here.

- [ ] **Step 5: Run the acceptance test to verify it passes**

Run: `swift test --filter TerminalOwnershipRoundTripTests`
Expected: PASS (2 tests) — the full state-machine drive, the rejected stale release, owner events
reaching a subscriber, and disconnect-staleness all green over a real socket.

- [ ] **Step 6: Full suite + no regressions**

Run: `swift build && swift test 2>&1 | tail -6`
Expected: green.
Run: `scripts/build-linux-daemon.sh 2>&1 | tail -3` (the daemon cross-build; source
`~/.swiftly/env.sh` first if needed).
Expected: cross-compiles.

- [ ] **Step 7: Commit**

```bash
git add Sources/OrchestraCore/Control/ControlServer.swift \
        Sources/OrchestraCore/Control/ControlClient.swift \
        Sources/OrchestraCore/OrchestraService.swift \
        Tests/OrchestraCoreTests/TerminalOwnershipRoundTripTests.swift
git commit -m "feat(d4): app-only ownership RPCs + ControlClient methods + acceptance harness"
```

---

### Task 5: Best-effort detach of prior agent-view clients on takeover

**Files:**
- Modify: `Sources/OrchestraCore/SessionManager.swift` (add `detachAgentViewClients`)
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (call it inside `takeOverAgentTerminal`)
- Test: `Tests/IntegrationTests/SessionManagerTests.swift` (real-tmux integration; gated like the
  existing tests in that file)

**Interfaces:**
- Consumes: `SessionManager.tmux(_:)` (`:44`), `SessionManager.viewSession(_:_:)` (`:36`).
- Produces: `SessionManager.detachAgentViewClients(_ base: String) throws` (no-op when the view
  session is absent).

> **Why this is separate and best-effort.** The authoritative desktop unmount is **D5** (the desktop
> app consumes `.agentTerminalOwner` and tears down its `AgentTerminalView`). This `detach-client` is
> belt-and-suspenders so a lingering old client's PTY can't keep sizing the window between the event
> and the unmount. It touches real tmux, so it lives behind the `SessionManaging` protocol and is
> verified with the real-tmux integration suite — the lease tests in Tasks 2–4 never depend on it.

- [ ] **Step 1: Write the failing integration test**

Add to `Tests/IntegrationTests/SessionManagerTests.swift` (match the file's existing scratch-tmux
setup/teardown and its skip-if-no-tmux guard):

```swift
    @Test("detachAgentViewClients drops clients of the agent view session; no-op when absent")
    func detachAgentView() throws {
        let sm = SessionManager(socket: Self.scratchSocket)   // match the suite's isolated socket
        // No-op path first: never throws when there is no such session/view.
        #expect(throws: Never.self) { try sm.detachAgentViewClients("orchestra-nonexistent") }
        // (If the suite already stands up a real agent session, assert the view session has zero
        //  attached clients after the call via `tmux list-clients -t <base>__agent`.)
    }
```

> Keep the assertion minimal and aligned with how `SessionManagerTests` already drives scratch tmux.
> The load-bearing guarantee is "never throws on a missing session"; a fuller attached-client check
> is optional and only where the suite already has a live session to attach to.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SessionManagerTests 2>&1 | tail -20`
Expected: FAIL — `detachAgentViewClients` is undefined.

- [ ] **Step 3: Implement `detachAgentViewClients`**

In `SessionManager.swift` (near `closeShellWindow` ~`:90`):

```swift
    /// Best-effort: detach every client of the card's `agent` grouped view session so a new owner's
    /// PTY (re)sizes the window. No-op if the session/view doesn't exist. Belt-and-suspenders behind
    /// the D5 desktop unmount — never load-bearing for the ownership lease itself.
    public func detachAgentViewClients(_ base: String) throws {
        _ = try? tmux(["detach-client", "-s", SessionManager.viewSession(base, "agent")])
    }
```

> `detachAgentViewClients` is a protocol requirement on `SessionManaging` only if the service calls it
> through the protocol. It does — `OrchestraService.sessions` is `any SessionManaging`. Add the method
> to the `SessionManaging` protocol and provide a no-op default (or a fake impl) so `TestEnv`'s mock
> and the real `SessionManager` both satisfy it:
>
> ```swift
> // in the SessionManaging protocol
> func detachAgentViewClients(_ base: String) throws
> // default no-op so existing conformers/mocks don't have to implement it
> extension SessionManaging { public func detachAgentViewClients(_ base: String) throws {} }
> ```

- [ ] **Step 4: Call it from `takeOverAgentTerminal`**

Replace the `// (Task 5 adds …)` comment in `OrchestraService.takeOverAgentTerminal` with:

```swift
        // Belt-and-suspenders: drop any existing clients of the agent view session so the new owner's
        // PTY drives the window size. Authoritative unmount is D5 (it consumes this event).
        try? sessions.detachAgentViewClients(sessions.sessionName(t.id))
```

> `sessions` here is the `SessionManaging` **property**; `sessions.sessionName(t.id)` builds
> `orchestra-<id>`. (`self.sessions(_ id:)` — the method — is a different symbol, disambiguated by
> call syntax.) `try?` keeps takeover succeeding even if tmux isn't reachable.

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter SessionManagerTests 2>&1 | tail -20`
Expected: PASS.
Run: `swift test --filter TerminalOwnershipRoundTripTests`
Expected: still PASS (the fake `SessionManaging`'s default no-op `detachAgentViewClients` keeps the
socket acceptance test green).

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/SessionManager.swift Sources/OrchestraCore/OrchestraService.swift \
        Tests/IntegrationTests/SessionManagerTests.swift
git commit -m "feat(d4): best-effort detach of prior agent-view clients on takeover"
```

---

### Task 6 (OPTIONAL, D3-gated): disconnect fast-path for staleness

**Files:**
- Modify: `Sources/OrchestraCore/Control/ControlServer.swift` (in `removeSubscriber`/`serve` teardown)
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (a `markOwnerStaleOnDisconnect(clientId:)`)
- Test: `Tests/OrchestraCoreTests/TerminalOwnershipRoundTripTests.swift` (a disconnect-drops-owner case)

> **Only implement this once D3 has landed** the `PeerConnection` → `clientId` map. It is a latency
> optimization: instead of waiting out the 30s heartbeat window, a hard `PeerConnection` drop whose
> `clientId` owns a fresh agent terminal marks that owner stale immediately (and emits, so the desktop
> can offer Force Retake at once). **Not required for D4 acceptance** — time-based staleness (Task 2/4)
> already satisfies "a phone disconnect marks the owner stale after the heartbeat window." If D3 isn't
> merged when D4 executes, **skip this task** and note it in the PR description as a D3 follow-up.

- [ ] **Step 1:** When D3's connection→clientId map exists, on connection teardown look up the
  dropped `clientId`; if it is the fresh owner of any agent terminal, set that owner's `updatedAt`
  far enough in the past (or add an explicit `markStale`) that `snapshot` reports `stale == true`,
  then `emit(.agentTerminalOwner(state))`.
- [ ] **Step 2:** Test: two clients; phone takes over; drop the phone connection; assert the
  desktop's next `agentTerminalOwner(ref)` reports `stale == true` *before* the heartbeat window
  would have elapsed.
- [ ] **Step 3:** Commit `feat(d4): mark agent-terminal owner stale on owning client disconnect`.

---

## The D5 desktop-consumer contract (hand-off to PR D5)

D5 (desktop unmount + "Taken over by phone" placeholder + Retake) consumes exactly this surface:

- **Event:** `Event.agentTerminalOwner(AgentTerminalOwnerState)` on the shipped `subscribe` stream.
  Payload: `ref`, `cardId`, `window` (`"agent"`), `owner` (`nil` ⇒ available; else `{ ownerKind,
  clientId, epoch, updatedAt }`), `epoch`, `stale`.
- **Reconcile-on-connect:** owner events are **live-only** (not ring-replayed). On (re)subscribe the
  desktop MUST call `agentTerminalOwner(ref)` per visible card to learn current ownership; thereafter
  it tracks the stream.
- **Desktop reactions:**
  - `owner == nil` (available) or `owner.ownerKind == .desktop` → normal `AgentTerminalView` attach.
  - `owner.ownerKind == .phone && !stale` → tear down `AgentTerminalView`, show "Taken over by phone"
    placeholder + **Retake Terminal**.
  - `owner.ownerKind == .phone && stale` → same placeholder but offer **Force Retake**.
  - **Retake / Force Retake / desktop-select-acquire** → `takeOverAgentTerminal(ref,
    clientId: <desktopClientId>, kind: .desktop)` — always wins (epoch++), returns the attach target,
    emits the flip.
- **Staleness is derived, not pushed:** the desktop computes stale locally from `owner.updatedAt +
  heartbeatTimeout` (30s) for its own UI timer; the server also reports `stale` in query responses.
- **clientId:** the desktop passes its own stable `clientId: String` (D3). The phone (T4) passes its
  own and heartbeats every ~10s while it holds the lease.

## Self-review

**1. Spec coverage (forest PR D4 + design + acceptance):**
- Owner record `{ ownerKind, clientId, epoch, cardId, window, updatedAt }` → `AgentTerminalOwner`
  (Task 1). ✓
- State machine `available → desktopOwned → phoneOwned → desktopOwned` → Task 2 `fullDrive`, Task 3/4
  drive tests. ✓
- `agentTerminalOwner(ref)` → owner + epoch + stale/fresh → Task 3/4. ✓
- `takeOverAgentTerminal(ref, clientId)` → CAS/epoch++/emit/attach target → Task 3/4 (kind added so
  desktop Retake shares the verb, per design transition 6). ✓
- `releaseAgentTerminal(ref, clientId, epoch)` → clear only if current epoch → Task 2/3/4;
  stale-epoch release REJECTED → Task 2 `staleReleaseRejected`, Task 4 acceptance. ✓
- `heartbeatAgentTerminal(ref, clientId, epoch)` → refresh, stale after timeout → Task 2, Task 4
  `staleAfterDisconnect`. ✓
- Broadcast over existing `subscribe` stream → new `Event` case, `emit` reuse (Task 1/3). ✓
- CAS-on-epoch guards multi-phone / stale-release → Task 2 `staleReleaseRejected`,
  `wrongClientReleaseRejected`, `staleHeartbeatRejected`. ✓
- Ephemeral, not durable → store is in-memory on the actor; nothing writes `TaskStore`. ✓
- Reuse `sessions`→`TmuxTarget` → `agentTarget` (Task 3). ✓
- Provider-neutral → no agent branching anywhere; keyed on `cardId`+`window`. ✓
- No regressions → Task 1 Step 6/8 (BoardModel no-op case + build-app), Task 4 Step 6 (linux build). ✓
- Verify via isolated harness → Task 4's hermetic ControlServer+ControlClient over a throwaway
  `/tmp` socket IS the isolated harness. ✓
- D3 coordination → `clientId: String`, explicit-param design, optional Task 6 fast-path. ✓

**2. Placeholder scan:** every step ships real, compilable code and exact commands. No TBD/TODO.

**3. Type consistency:** `AgentTerminalOwner`/`AgentTerminalOwnerState`/`TakeOverResult`/
`AgentTerminalOwnerKind` names, `clientId: String`, `epoch: Int`, `kind:` labels, and the store method
signatures are identical across Tasks 1–5 and the client/server/service call sites.

**Seams verified against the real code (not assumptions):**
- Fake `SessionManaging.windows(_:)` returns an `agent` `TmuxTarget` when alive
  (`Stubs.swift:64-68`); `spawn` makes it alive → `agentTarget` resolves in the harness.
- `JSONValue.int(Int)` (`JSONValue.swift:8`) + `optInt` (`:82`) exist.
- `EventCollector` (`Stubs.swift:132`) derives typed views as computed properties over `events`;
  add `ownerStates` the same way (Task 3 Step 1).
- `SessionManaging` is a protocol (`Protocols.swift:12`) — add a defaulted `detachAgentViewClients`
  so existing conformers/mocks compile without edits (Task 5 Step 3).
- Only two exhaustive `switch`es over `Event` exist: `App/BoardModel.swift:320` (handled, Task 1
  Step 6) and `ControlServer.swift:200` (an `if case .activity` — non-exhaustive, safe).
  `OrchestraService.swift:438`'s `switch event` is over `HookEvent`, not `Event`.
