# PR D5 — Desktop unmount + "Taken over by phone" placeholder + Retake — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the desktop macOS app relinquish a card's agent terminal when a phone takes it over — tearing down the `AgentTerminalView`, showing a "Taken over by phone" placeholder with a **Retake Terminal** button — and acquire `desktopOwned` on card select unless the phone owns it, so the desktop never resize-fights the phone.

**Architecture:** D4 already made the daemon the authority for agent-terminal ownership (owner record + `agentTerminalOwner`/`takeOverAgentTerminal` RPCs + an owner-changed event on the existing `subscribe` stream). D5 is **pure desktop consumption**: (1) a small pure decision policy in `OrchestraCore` (`swift test`-able), (2) `BoardModel` mirrors the owner event into an observable `agentOwners` map (same main-actor `apply(_:)` path it already uses for `taskUpserted`), and (3) the inspector's AGENT region renders either the live `AgentTerminalView` or a placeholder based on that state, acquiring desktop ownership on mount. No new wire verbs — D5 consumes D4's contract and adds nothing to the protocol.

**Tech Stack:** Swift 6 / SwiftUI + AppKit (`NSViewRepresentable`), `swift-testing` (`import Testing`), XcodeGen app target, tmux grouped view sessions, the `orch-test.sh` (isolated daemon) and `orch-ui-shot.sh` (headless screenshot) harnesses.

## Global Constraints

- **Design for every agent (Claude AND Codex).** No `if agent == "claude"` branches. Ownership is provider-neutral (keyed by `cardId` + `window = agent`); the placeholder/Retake behave identically for a Claude or Codex card.
- **Daemon wire protocol changes: NONE.** D5 consumes D4's `agentTerminalOwner` / `takeOverAgentTerminal` RPCs and the owner-changed event. It adds **no** new verbs, no `embedded.conf` change.
- **Do not regress the desktop or the Linux daemon build.** `swift build` / `swift test` stay offline-green; `scripts/build-app.sh` (macOS) and `scripts/build-linux-daemon.sh` keep working. The new pure policy lives in `OrchestraCore`, which cross-compiles to Linux — keep it AppKit-free.
- **`embedded.conf` (`window-size latest` + `aggressive-resize on`) is unchanged.** Unmount/reattach relies on SwiftUI tearing down the `NSViewRepresentable` (which detaches the tmux client), NOT on `resize-window` (which would pin `window-size manual`).
- **Small stacked PRs over big ones; small commits.** One commit per task.
- **Ownership is ephemeral UI coordination, not durable card state.** The desktop never persists owner state; it is rebuilt from daemon events on every (re)connect.

---

## Prerequisites & Dependency contract (from D4)

**This PR does not compile until D4 is merged into the impl branch.** The impl card branches `mobile/d5-desktop-unmount` off the **completed** `mobile/d4-ownership-lease`. Before Task 1, confirm these D4-provided symbols exist; **if D4's actual names differ, this section is the single place to reconcile** — update the references below and everywhere they are used follows.

D4 (per `notes/plans/2026-07-04-mobile-orchestra-implementation-forest.md` §PR D4 and `notes/designs/2026-07-03-phone-agent-terminal-ux-design.md` §"Control surface") provides, in `OrchestraCore`:

```swift
// Sources/OrchestraCore/TerminalOwnership.swift (D4 — CONSUMED here, do NOT redefine)
public struct AgentTerminalOwner: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case desktop, phone }
    public let cardId: UUID
    public let window: String        // always "agent" for this PR
    public let ownerKind: Kind
    public let clientId: String      // the owning client's D3 identity
    public let epoch: Int
    public let updatedAt: Date
    public let isStale: Bool          // heartbeat-derived: true once the owner missed its heartbeat window
}

// Sources/OrchestraCore/Model.swift — D4 adds ONE case to the existing event enum:
//   public enum Event: Codable, Sendable, Equatable {
//       case taskUpserted(Task)
//       case taskRemoved(UUID)
//       case activity(ActivityItem)
//       case agentTerminalOwnerChanged(AgentTerminalOwner)   // <-- added by D4
//   }

// Sources/OrchestraCore/Control/ControlClient.swift — D4 adds:
//   public var clientId: String { get }                                   // (D3) this client's stable id
//   public func agentTerminalOwner(ref: String) async throws -> AgentTerminalOwner?   // nil == available
//   public func takeOverAgentTerminal(ref: String) async throws -> AgentTerminalOwner // CAS as THIS client
```

Notes on the contract D5 relies on:
- **`agentTerminalOwnerChanged` is broadcast on the existing `subscribe` stream** and decoded by `ControlClient.readUntilEOF` exactly like the other cases (see `ControlClient.swift:150` — `msg.method == "event"` → `decode(Event.self)`), so `BoardModel.subscribe`/`apply(_:)` receives it with zero client-transport changes.
- **`takeOverAgentTerminal` uses the client's own `source`/`clientId`** and sets `ownerKind = .desktop` for a desktop app client. If D4's signature takes an explicit `ownerKind`, pass `.desktop`.
- **`isStale`** is how the desktop distinguishes a live phone owner from a phone that dropped without releasing (design transition 7 + failure mode "Stale phone owner"). If D4 instead exposes only `updatedAt` + a timeout constant, compute `isStale` in `BoardModel` from `updatedAt` and feed the boolean into the pure policy (Task 1) — the policy takes the boolean, not the struct, precisely so this detail stays out of it.

**Testing reality — read before Task 2.** `BoardModel` and all `App/` SwiftUI code live in the **XcodeGen macOS app target, which has no XCTest/swift-testing bundle** (the only test targets are `OrchestraCoreTests` and `IntegrationTests`, both over `OrchestraCore` — see `Package.swift:49-54`). Therefore:
- **The decision logic is TDD'd as a pure function in `OrchestraCore` (Task 1)** — full red→green→commit under `swift test`.
- **The `BoardModel`/SwiftUI wiring (Tasks 2–4) is verified behaviorally by the harnesses (Tasks 5–6)** — `orch-ui-shot.sh` screenshots the placeholder, `orch-test.sh` drives a real `phoneOwned`→unmount→Retake→reattach round-trip. Each of Tasks 2–4 still ends with a green `scripts/build-app.sh` as its gate; the behavioral assertion is the harness task that follows. This is the honest cycle given the app target has no unit-test bundle — do not fabricate an app-target XCTest.

---

## File structure

| File | Create / Modify | Responsibility |
|---|---|---|
| `Sources/OrchestraCore/DesktopTerminalPolicy.swift` | **Create** | Pure, AppKit-free decision functions: given the current owner + this desktop's clientId, decide **mount vs placeholder** and **whether to acquire desktop ownership**. The single source of the desktop's ownership rules. |
| `Tests/OrchestraCoreTests/DesktopTerminalPolicyTests.swift` | **Create** | `swift test` coverage of every policy branch (available / mine / other-desktop / phone-fresh / phone-stale). |
| `App/BoardModel.swift` | **Modify** (`apply(_:)` ~`:319`; new `@Published` + methods) | Mirror `agentTerminalOwnerChanged` into `@Published var agentOwners: [UUID: AgentTerminalOwner]`; expose `desktopTerminalDecision(for:)` + `acquireDesktopTerminal(_:)` + `retakeAgentTerminal(_:)` that call the Task 1 policy and D4's RPCs. |
| `App/Views/AgentTerminalPlaceholder.swift` | **Create** | The "Taken over by phone" placeholder SwiftUI view + **Retake Terminal** button. |
| `App/Views/InspectorView.swift` | **Modify** (`AgentChrome.body` AGENT region, terminal host at `:349`) | Swap `AgentTerminalView` ↔ `AgentTerminalPlaceholder` on the decision; `.onAppear` acquires desktop ownership. |
| `App/OrchestraApp.swift` | **Modify** (`DebugLaunchHook` + `ORCH_SHOW` switch ~`:559`) | Add `ORCH_SHOW=takeover` hook seeding a mock phone owner so `orch-ui-shot.sh` can screenshot the placeholder with no daemon. |
| `scripts/orch-ui-shot.sh` | **Modify** (extend, don't rewrite) | Add a shot that launches with `ORCH_SHOW=takeover` and captures the placeholder + a normal-terminal control shot. |

**Decomposition rationale:** the pure rule is isolated in `OrchestraCore` so it is testable and Linux-safe; `BoardModel` owns the observable state (it already mirrors events on the main actor); the placeholder is its own small view so the swap site in `InspectorView` stays a one-line branch; the debug hook + harness edits are folded into the tasks whose acceptance needs them.

---

## Task 1: Desktop terminal ownership policy (pure, TDD in OrchestraCore)

**Files:**
- Create: `Sources/OrchestraCore/DesktopTerminalPolicy.swift`
- Test: `Tests/OrchestraCoreTests/DesktopTerminalPolicyTests.swift`

**Interfaces:**
- Consumes: `AgentTerminalOwner.Kind` (D4). The functions take **primitives** (kind, owner clientId, staleness, this desktop's clientId) — never the daemon RPC — so they stay pure and decoupled from D4's struct shape.
- Produces (used by Task 2):
  - `enum DesktopTerminalDecision: Equatable { case mount, placeholder }`
  - `func desktopTerminalDecision(ownerKind: AgentTerminalOwner.Kind?, isStale: Bool) -> DesktopTerminalDecision`
  - `func shouldAcquireDesktopOwnership(ownerKind: AgentTerminalOwner.Kind?, ownerClientId: String?, desktopClientId: String) -> Bool`

**The rules (from design transitions 1/4/6 + failure modes "Desktop reattaches during phone ownership" / "Stale phone owner"):**
- **Decision (what the desktop renders):** phone-owned ⇒ `.placeholder` (fresh *or* stale — a stale phone owner is not auto-stolen; the desktop offers an explicit Retake). Everything else ⇒ `.mount`.
- **Acquire (should the desktop CAS to `desktopOwned` on select/mount):**
  - `available` (nil owner) ⇒ **true** (claim it).
  - `desktopOwned` by *this* desktop ⇒ **false** (already mine — no redundant RPC, avoids select-churn spam).
  - `desktopOwned` by *another* desktop client ⇒ **true** (desktops cooperate; the just-selected client takes the size).
  - `phoneOwned` (fresh or stale) ⇒ **false** (never auto-steal from a phone; Retake is an explicit button, per the fail-safe default).

- [ ] **Step 1: Write the failing tests**

Create `Tests/OrchestraCoreTests/DesktopTerminalPolicyTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("DesktopTerminalPolicy — render decision")
struct DesktopTerminalDecisionTests {
    @Test("available owner mounts the terminal")
    func availableMounts() {
        #expect(desktopTerminalDecision(ownerKind: nil, isStale: false) == .mount)
    }
    @Test("desktop owner mounts the terminal")
    func desktopMounts() {
        #expect(desktopTerminalDecision(ownerKind: .desktop, isStale: false) == .mount)
    }
    @Test("fresh phone owner shows the placeholder")
    func phoneFreshPlaceholder() {
        #expect(desktopTerminalDecision(ownerKind: .phone, isStale: false) == .placeholder)
    }
    @Test("stale phone owner still shows the placeholder (Retake is explicit, never auto-steal)")
    func phoneStalePlaceholder() {
        #expect(desktopTerminalDecision(ownerKind: .phone, isStale: true) == .placeholder)
    }
}

@Suite("DesktopTerminalPolicy — acquire decision")
struct ShouldAcquireDesktopOwnershipTests {
    let me = "desktop-abc"
    @Test("available → acquire")
    func available() {
        #expect(shouldAcquireDesktopOwnership(ownerKind: nil, ownerClientId: nil, desktopClientId: me))
    }
    @Test("already owned by me → do not re-acquire (no select-churn spam)")
    func mine() {
        #expect(!shouldAcquireDesktopOwnership(ownerKind: .desktop, ownerClientId: me, desktopClientId: me))
    }
    @Test("owned by another desktop client → acquire (last selected desktop wins)")
    func otherDesktop() {
        #expect(shouldAcquireDesktopOwnership(ownerKind: .desktop, ownerClientId: "desktop-xyz", desktopClientId: me))
    }
    @Test("phone-owned → never auto-acquire (Retake is explicit)")
    func phone() {
        #expect(!shouldAcquireDesktopOwnership(ownerKind: .phone, ownerClientId: "phone-1", desktopClientId: me))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter DesktopTerminal`
Expected: FAIL — "cannot find 'desktopTerminalDecision' in scope" / "cannot find 'DesktopTerminalDecision'".

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/OrchestraCore/DesktopTerminalPolicy.swift`:

```swift
import Foundation

/// Pure desktop-side rules for the agent-terminal ownership lease (PR D5). The daemon (PR D4) is the
/// authority for *who* owns a card's `agent` terminal; these functions decide what the **desktop** does
/// about it — whether to render the live terminal or a "Taken over by phone" placeholder, and whether
/// selecting a card should claim `desktopOwned`.
///
/// AppKit-free and dependency-free (takes primitives, not the RPC) so it lives in `OrchestraCore`,
/// cross-compiles to Linux, and is exercised directly by `swift test`.

/// What the desktop should render for a card's agent terminal.
public enum DesktopTerminalDecision: Equatable {
    case mount        // attach the live AgentTerminalView
    case placeholder  // tear the terminal down, show "Taken over by phone" + Retake
}

/// Render decision: a phone owner (fresh OR stale) means the desktop shows the placeholder and must not
/// be attached to the same tmux window (the hard tmux one-size-per-window invariant). A stale phone
/// owner is still the placeholder — the desktop recovers via an explicit Retake, never by silently
/// stealing the lease.
public func desktopTerminalDecision(ownerKind: AgentTerminalOwner.Kind?, isStale: Bool) -> DesktopTerminalDecision {
    ownerKind == .phone ? .placeholder : .mount
}

/// Whether selecting/mounting this card should CAS the lease to `desktopOwned`.
/// - available            → yes, claim it.
/// - desktopOwned by me   → no (avoid a redundant RPC on every hjkl re-select).
/// - desktopOwned by other→ yes (desktops cooperate; the just-selected client takes the size).
/// - phoneOwned           → no (never auto-steal from a phone; Retake is explicit).
public func shouldAcquireDesktopOwnership(ownerKind: AgentTerminalOwner.Kind?,
                                          ownerClientId: String?,
                                          desktopClientId: String) -> Bool {
    switch ownerKind {
    case .none:    return true
    case .phone:   return false
    case .desktop: return ownerClientId != desktopClientId
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter DesktopTerminal`
Expected: PASS (8 tests).

- [ ] **Step 5: Verify no build regressions**

Run: `swift build`
Expected: builds clean (the new file compiles into `OrchestraCore`).

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/DesktopTerminalPolicy.swift Tests/OrchestraCoreTests/DesktopTerminalPolicyTests.swift
git commit -m "feat(d5): pure desktop terminal ownership policy (mount vs placeholder, acquire rule)"
```

---

## Task 2: BoardModel consumes D4 owner events + exposes terminal state

**Files:**
- Modify: `App/BoardModel.swift` (add `@Published var agentOwners`; extend `apply(_:)` at `:319`; add three methods near the other `func`s, e.g. after `select(ref:)` ~`:543`)

**Interfaces:**
- Consumes: `Event.agentTerminalOwnerChanged(AgentTerminalOwner)`, `AgentTerminalOwner`, `ControlClient.clientId`, `ControlClient.takeOverAgentTerminal(ref:)` (D4); `desktopTerminalDecision(...)`, `shouldAcquireDesktopOwnership(...)`, `DesktopTerminalDecision` (Task 1); `Task.ref()` (`Model.swift:346`).
- Produces (used by Tasks 3–4):
  - `@Published var agentOwners: [UUID: AgentTerminalOwner]`
  - `func desktopTerminalDecision(for cardId: UUID) -> DesktopTerminalDecision`
  - `func agentOwner(for cardId: UUID) -> AgentTerminalOwner?`
  - `func acquireDesktopTerminal(_ cardId: UUID)`  (fire-and-forget; only CAS when the policy says to)
  - `func retakeAgentTerminal(_ cardId: UUID)`     (explicit user action from the placeholder)

**Note on testing:** the app target has no unit-test bundle (see Prerequisites), so this task's gate is a green `scripts/build-app.sh`; behavior is asserted in Tasks 5–6. The event-application shape deliberately mirrors the existing `taskUpserted`/`taskRemoved` cases at `BoardModel.swift:321-357`.

- [ ] **Step 1: Add the observable owner map**

In `App/BoardModel.swift`, next to the other per-card `@Published` state (after `selectedShell` at `:84`), add:

```swift
    /// Daemon-authoritative agent-terminal ownership (PR D4), mirrored per card so the inspector can
    /// render the live terminal vs the "Taken over by phone" placeholder (PR D5). Ephemeral UI
    /// coordination only — rebuilt from `agentTerminalOwnerChanged` events on every (re)connect, never
    /// persisted. An entry is absent when the terminal is `available` (no owner).
    @Published var agentOwners: [UUID: AgentTerminalOwner] = [:]
```

- [ ] **Step 2: Mirror the owner event in `apply(_:)`**

In `App/BoardModel.swift`, extend the `switch event` in `apply(_:)` (`:320`). Add a case before the closing brace of the switch (after `.activity` at `:357`):

```swift
        case .agentTerminalOwnerChanged(let owner):
            // Available (no owner) is represented by ABSENCE, so the render decision never has to special-
            // case an "available desktop" sentinel. D4 emits an event with the current owner; if D4 signals
            // "released/available" with a distinct payload, clear the key instead (see contract note).
            agentOwners[owner.cardId] = owner
```

> If D4 models "released → available" as a dedicated event/payload rather than an owner with a nil-ish kind, clear the map on it: `agentOwners[cardId] = nil`. Keep the map's invariant: **key present ⇔ non-available owner**.

- [ ] **Step 3: Add the decision + action methods**

In `App/BoardModel.swift`, add near `select(ref:)` (~`:543`):

```swift
    /// The current owner of a card's agent terminal, or nil when available.
    func agentOwner(for cardId: UUID) -> AgentTerminalOwner? { agentOwners[cardId] }

    /// Whether the inspector should mount the live terminal or the "Taken over by phone" placeholder.
    func desktopTerminalDecision(for cardId: UUID) -> DesktopTerminalDecision {
        let o = agentOwners[cardId]
        return OrchestraCore.desktopTerminalDecision(ownerKind: o?.ownerKind, isStale: o?.isStale ?? false)
    }

    /// Called when the desktop selects/mounts a card's terminal: claim `desktopOwned` unless the phone
    /// owns it or we already own it. Fire-and-forget; the authoritative state comes back as an event.
    func acquireDesktopTerminal(_ cardId: UUID) {
        let o = agentOwners[cardId]
        guard shouldAcquireDesktopOwnership(ownerKind: o?.ownerKind, ownerClientId: o?.clientId,
                                            desktopClientId: client.clientId) else { return }
        guard let ref = tasks.first(where: { $0.id == cardId })?.ref() else { return }
        _Concurrency.Task { [weak self] in _ = try? await self?.client.takeOverAgentTerminal(ref: ref) }
    }

    /// Explicit **Retake Terminal** from the placeholder: CAS the lease to this desktop even though the
    /// phone currently owns it. The resulting owner event flips `desktopTerminalDecision` back to `.mount`
    /// and the inspector remounts `AgentTerminalView` automatically. Works for a fresh OR stale phone owner
    /// (compare-and-set on epoch is D4's job).
    func retakeAgentTerminal(_ cardId: UUID) {
        guard let ref = tasks.first(where: { $0.id == cardId })?.ref() else { return }
        _Concurrency.Task { [weak self] in _ = try? await self?.client.takeOverAgentTerminal(ref: ref) }
    }
```

> `acquireDesktopTerminal` and `retakeAgentTerminal` both call the same `takeOverAgentTerminal` RPC — the difference is only the guard: acquire is gated by the policy (silent, on select), retake is unconditional (explicit, from the button). Keeping them as two named methods keeps the call sites self-documenting.

- [ ] **Step 4: Verify the app builds**

Run: `scripts/build-app.sh`
Expected: builds clean (compiles against D4's `Event` case + `ControlClient` methods).
> If it fails with "no member `agentTerminalOwnerChanged`" / "no member `takeOverAgentTerminal`", D4 is not merged into this branch — stop and reconcile per Prerequisites.

- [ ] **Step 5: Commit**

```bash
git add App/BoardModel.swift
git commit -m "feat(d5): BoardModel mirrors D4 owner events + desktop acquire/retake actions"
```

---

## Task 3: "Taken over by phone" placeholder view + Retake button

**Files:**
- Create: `App/Views/AgentTerminalPlaceholder.swift`

**Interfaces:**
- Consumes: `BoardModel` (`@EnvironmentObject`), `Theme` (`@Environment(\.theme)`), `Task` (`Model.swift`), `BoardModel.retakeAgentTerminal(_:)` + `agentOwner(for:)` (Task 2).
- Produces (used by Task 4): `struct AgentTerminalPlaceholder: View { let task: Task }`.

**Design (design doc §"Live takeover display" + transition 4 "shows 'Taken over by phone'"):** a centered, terminal-dark panel that visually reads as "not your terminal right now": phone glyph, the headline, a one-line subtitle, and a prominent **Retake Terminal** button. When the phone owner is **stale** (`isStale`), the copy shifts to signal the phone is unreachable and the button reads **Force Retake** (still the same action). Fills the same frame the terminal occupied so the region geometry (focus ring, rounded corners) is unchanged.

- [ ] **Step 1: Create the placeholder view**

Create `App/Views/AgentTerminalPlaceholder.swift`:

```swift
import SwiftUI
import OrchestraCore

/// Shown in place of `AgentTerminalView` when a phone owns this card's agent terminal (PR D5). The
/// desktop deliberately does NOT attach to the tmux `agent` window while the phone owns it — a tmux
/// window has one size, so two attached clients at different sizes would resize-fight. Retake flips the
/// daemon lease back to this desktop; the resulting owner event remounts the live terminal automatically.
struct AgentTerminalPlaceholder: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: Task

    private var stale: Bool { model.agentOwner(for: task.id)?.isStale ?? false }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: stale ? "iphone.slash" : "iphone.gen3")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(theme.text2)
            VStack(spacing: 4) {
                Text("Taken over by phone")
                    .font(F.ui(14, .semibold)).foregroundStyle(theme.text)
                Text(stale
                     ? "The phone that took over is unreachable. You can force the terminal back."
                     : "This agent terminal is being controlled from your phone.")
                    .font(F.ui(11.5)).foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
            }
            Button {
                model.retakeAgentTerminal(task.id)
            } label: {
                Text(stale ? "Force Retake" : "Retake Terminal")
                    .font(F.ui(12, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.accent))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])   // ⏎ retakes when the placeholder is the focus
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.termBg)
    }
}
```

> Verify the exact spelling of the theme/font helpers against `App/Theme.swift` (`theme.text`, `theme.text2`, `theme.termBg`, `theme.accent`) and the font helper `F.ui(_:_:)` (used throughout `InspectorView.swift`, e.g. `:435`, `OfflineBanner` in `OrchestraApp.swift`). Pick SF Symbols that exist in the deployment target; `iphone.gen3` / `iphone.slash` are safe on macOS 14+ — if unavailable, fall back to `iphone` / `iphone.slash`.

- [ ] **Step 2: Verify the app builds**

Run: `scripts/build-app.sh`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add App/Views/AgentTerminalPlaceholder.swift
git commit -m "feat(d5): 'Taken over by phone' placeholder view with Retake/Force Retake"
```

---

## Task 4: Swap terminal ↔ placeholder + acquire on select

**Files:**
- Modify: `App/Views/InspectorView.swift` (the `AgentChrome` AGENT region — the `AgentTerminalView(...)` host at `:349-367`)

**Interfaces:**
- Consumes: `BoardModel.desktopTerminalDecision(for:)`, `BoardModel.acquireDesktopTerminal(_:)` (Task 2); `AgentTerminalPlaceholder` (Task 3); `DesktopTerminalDecision` (Task 1); the existing `AgentTerminalView` (`AgentTerminalView.swift:10`).

**Mechanics of "unmount":** replacing `AgentTerminalView` with `AgentTerminalPlaceholder` in the SwiftUI tree tears down the `NSViewRepresentable`, which deinits the `LocalProcessTerminalView` and ends its `/bin/sh -c "…tmux attach…"` process — i.e. the desktop's tmux client on the `agent` grouped view session detaches. That detach (not `resize-window`) is the unmount; on Retake the branch flips back and `AgentTerminalView` re-mounts and re-attaches. No `embedded.conf` change; relies on `window-size latest` naturally following the sole remaining client.

- [ ] **Step 1: Wrap the terminal host in the decision branch**

In `App/Views/InspectorView.swift`, replace the `AgentTerminalView(...)` host block (currently `:349-367`, i.e. from `AgentTerminalView(socket:` through its trailing `.background(theme.termBg)`) with a decision branch. Keep the **exact same modifiers** (`.id(...)`, `.frame(...)`, `.background(...)`) on the terminal path so nothing else about its lifecycle changes:

```swift
                switch model.desktopTerminalDecision(for: task.id) {
                case .placeholder:
                    AgentTerminalPlaceholder(task: task)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(theme.termBg)
                case .mount:
                    AgentTerminalView(socket: model.terminalTmuxSocket, session: task.tmuxSession, window: "agent",
                                      host: model.terminalHost,
                                      background: theme.termBg, foreground: theme.term,
                                      autofocus: model.focusZone == .terminal,
                                      terminalImagePaste: model.capabilities(for: task.agentId).terminalImagePaste,
                                      onFocused: { if model.focusZone != .terminal { model.focusZone = .terminal } })
                        .id("\(model.connections.activeId)-\(task.tmuxSession)")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(theme.termBg)
                        // Desktop select/mount claims `desktopOwned` unless the phone owns it or we already
                        // do (the policy short-circuits both). Idempotent: repeat selects of a card we own
                        // send no RPC.
                        .onAppear { model.acquireDesktopTerminal(task.id) }
                }
```

> Preserve the original comments on `autofocus` and `.id(...)` from `:353-364` — they explain why focus is conditional and why the id keys on connection+session. Do not drop them.

- [ ] **Step 2: Verify the app builds**

Run: `scripts/build-app.sh`
Expected: builds clean.

- [ ] **Step 3: Sanity-check the un-owned path is unchanged**

Run: `scripts/orch-ui-shot.sh` (the existing `ORCH_SHOW=shells` shots)
Expected: the normal agent terminal region still renders exactly as before (no owner event ⇒ `agentOwners` empty ⇒ decision `.mount`). This confirms zero desktop regression for the common (no-phone) case.

- [ ] **Step 4: Commit**

```bash
git add App/Views/InspectorView.swift
git commit -m "feat(d5): inspector swaps agent terminal for placeholder on phoneOwned; acquire on select"
```

---

## Task 5: `ORCH_SHOW=takeover` debug hook + placeholder screenshot

**Files:**
- Modify: `App/OrchestraApp.swift` (`DebugLaunchHook` + the `ORCH_SHOW` switch at `:559`)
- Modify: `scripts/orch-ui-shot.sh` (add a `takeover` shot; extend, don't rewrite)

**Interfaces:**
- Consumes: `BoardModel.agentOwners`, `AgentTerminalOwner` (Task 2), the existing `DebugLaunchHook.showShells` seeding pattern (`OrchestraApp.swift`).

**Purpose:** `orch-ui-shot.sh` runs the app **with no daemon** (a mock card seeded in `#if DEBUG`). To screenshot the placeholder we seed a mock card **and** a mock phone owner in `agentOwners`, mirroring how `showShells` seeds a mock card + shell state.

- [ ] **Step 1: Add the `showTakeover` seeding hook**

In `App/OrchestraApp.swift`, add a static method to `DebugLaunchHook` next to `showShells` (copy its mock-card scaffold; the only addition is the owner entry):

```swift
    /// `ORCH_SHOW=takeover`: a mock running card whose agent terminal is owned by a phone, so the
    /// inspector renders the "Taken over by phone" placeholder headlessly (no daemon). `ORCH_STALE=1`
    /// seeds a STALE phone owner to screenshot the Force Retake variant.
    static func showTakeover(model: BoardModel) {
        let mock = Task(title: "Taken over by phone — placeholder demo",
                        repo: "/Users/allen/code/orchestra", branch: "mobile/d5-desktop-unmount",
                        cwd: "/Users/allen/code/orchestra/.worktrees/d5",
                        model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                        order: 0, status: .running, ctxPct: 40, initialPrompt: "demo")
        model.tasks = [mock]
        model.selectedId = mock.id
        model.onboarded = true
        model.showOnboarding = false
        let stale = ProcessInfo.processInfo.environment["ORCH_STALE"] == "1"
        model.agentOwners[mock.id] = AgentTerminalOwner(
            cardId: mock.id, window: "agent", ownerKind: .phone,
            clientId: "phone-demo", epoch: 1, updatedAt: Date(), isStale: stale)
    }
```

> Match the `AgentTerminalOwner` initializer to D4's actual member order/labels. If D4 makes some members computed or private, seed via whatever public initializer D4 exposes (D4 is the owner of that type).

- [ ] **Step 2: Wire it into the `ORCH_SHOW` switch**

In `App/OrchestraApp.swift`, in the `switch ProcessInfo.processInfo.environment["ORCH_SHOW"]` (`:559`), add before `default`:

```swift
            case "takeover": DebugLaunchHook.showTakeover(model: model)
```

- [ ] **Step 3: Add the screenshot to the harness**

In `scripts/orch-ui-shot.sh`, after the existing shell shots, add a takeover shot (follow the file's existing `launch → window_id → screencapture → kill` pattern; reuse its `shot`/launch helper rather than duplicating the CoreGraphics window-id block):

```bash
# 5. phoneOwned → "Taken over by phone" placeholder (fresh)
ORCH_SHOW=takeover shot "takeover-placeholder"
# 6. stale phone owner → Force Retake variant
ORCH_SHOW=takeover ORCH_STALE=1 shot "takeover-placeholder-stale"
```

> If `orch-ui-shot.sh` does not already factor launching into a reusable `shot <name>` function, add one that wraps its existing launch/window_id/screencapture/kill sequence taking the `ORCH_SHOW` value from the environment — do not copy-paste the block per shot.

- [ ] **Step 4: Run the harness and inspect the placeholder**

Run: `scripts/orch-ui-shot.sh`
Expected: `./.scratch/ui-shots/takeover-placeholder.png` shows the phone glyph + "Taken over by phone" + **Retake Terminal**; `…-stale.png` shows the `iphone.slash` glyph + **Force Retake**. Paste both PNGs back for visual confirmation.

- [ ] **Step 5: Commit**

```bash
git add App/OrchestraApp.swift scripts/orch-ui-shot.sh
git commit -m "test(d5): ORCH_SHOW=takeover debug hook + placeholder screenshots (fresh + stale)"
```

---

## Task 6: End-to-end owner-event acceptance via `orch-test.sh`

**Files:** none (harness-driven acceptance; no code change). If a reusable driver script helps, add `scripts/d5-takeover-e2e.sh` under the same conventions.

**Interfaces:**
- Consumes: `scripts/orch-test.sh` (isolated daemon: own `HOME` + `tmux -L orch-test`), the D4 RPCs `takeOverAgentTerminal` / `agentTerminalOwner`, and a running Debug app pointed at the isolated daemon.

**Goal (the PR's acceptance criteria):** against an isolated daemon, a `phoneOwned` event unmounts the desktop terminal → placeholder; **Retake** flips ownership and reattaches. The pure decision is already unit-tested (Task 1) and the placeholder is screenshotted (Task 5); this task proves the **live event round-trip** end to end.

- [ ] **Step 1: Bring up an isolated daemon + card**

Run:
```bash
scripts/orch-test.sh init && scripts/orch-test.sh up
scripts/orch-test.sh rpc inspect '{"ref":"aaaaaa"}'
```
Expected: the seeded card `aaaaaa` (session `orchestra-aaaaaaaa-…`) exists on the isolated daemon.

- [ ] **Step 2: Launch the Debug app against the isolated daemon**

Build/point a Debug app instance at the isolated `HOME`/socket + tmux socket (same env overrides `orch-test.sh` uses: `HOME=/tmp/orch-test/home`, `ORCHESTRA_TMUX_SOCKET=orch-test`), running unsandboxed and screenshotted by window id (never foreground). Reuse the launch+window-id+screencapture helper from `orch-ui-shot.sh`.
Expected: the app connects (owner map starts empty ⇒ card `aaaaaa` shows the live agent terminal, `.mount`).

- [ ] **Step 3: Simulate a phone takeover on the daemon**

From a *second, phone-identity* client, take the lease:
```bash
scripts/orch-test.sh rpc takeOverAgentTerminal '{"ref":"aaaaaa","ownerKind":"phone","clientId":"phone-e2e"}'
scripts/orch-test.sh rpc agentTerminalOwner '{"ref":"aaaaaa"}'
```
Expected: `agentTerminalOwner` reports `ownerKind: phone`, `clientId: phone-e2e`. The daemon broadcasts `agentTerminalOwnerChanged` on the subscribe stream.
> Adjust the RPC param shape to D4's actual schema. If the CLI/`orch-rpc.py` path can't assert a *phone* identity, drive a phone-identity `ControlClient` directly (a tiny Swift/py helper) — the point is a non-desktop `clientId` owns the lease.

- [ ] **Step 4: Verify the desktop unmounts → placeholder**

Screenshot the app window by id.
Expected: the card's agent region now shows **"Taken over by phone" + Retake Terminal**; the desktop's tmux client has detached — confirm with:
```bash
scripts/orch-test.sh tmux list-clients 2>/dev/null   # the desktop agent view-session client is gone
```
Expected: no desktop client attached to `orchestra-aaaa…__agent`.

- [ ] **Step 5: Retake from the desktop → reattach**

Drive the Retake action (either click via the screenshot harness's input path, or invoke `takeOverAgentTerminal` as the *desktop* client to mirror the button):
```bash
scripts/orch-test.sh rpc takeOverAgentTerminal '{"ref":"aaaaaa","ownerKind":"desktop","clientId":"desktop-e2e"}'
scripts/orch-test.sh rpc agentTerminalOwner '{"ref":"aaaaaa"}'
```
Expected: owner flips to `ownerKind: desktop`; the app's owner event flips the decision to `.mount`; screenshot shows the live agent terminal re-rendered and a desktop client re-attached (`list-clients` shows the desktop `__agent` client back).

- [ ] **Step 6: Tear down**

Run: `scripts/orch-test.sh down`
Expected: isolated daemon + `tmux -L orch-test` server killed; `/tmp/orch-test` cleaned by the harness (do not hand-`rm` it — see project cleanup rules).

- [ ] **Step 7: Commit (only if a driver script was added)**

```bash
git add scripts/d5-takeover-e2e.sh
git commit -m "test(d5): e2e takeover/retake acceptance driver over isolated daemon"
```

---

## Self-Review

**Spec coverage** (against the D5 forest entry + design transitions 1/4/6 + failure mode):
- "Desktop subscribes to owner events" → Task 2 (`apply(.agentTerminalOwnerChanged)`). ✓
- "On `phoneOwned`, tear down `AgentTerminalView` + 'Taken over by phone' placeholder + **Retake**" → Tasks 3 (view) + 4 (swap = teardown). ✓
- "Retake → `takeOverAgentTerminal` as desktop → reattach" → Task 2 (`retakeAgentTerminal`) + Task 4 (auto-remount on event) + Task 6 step 5. ✓
- "On desktop select, acquire `desktopOwned` unless phone owns it" → Task 1 (`shouldAcquireDesktopOwnership`) + Task 2/4 (`acquireDesktopTerminal` on `.onAppear`). ✓ (transition 1)
- Failure mode "Desktop reattaches during phone ownership" → the render decision is daemon-driven (`agentOwners`), not a local flag; `.mount` is impossible while `ownerKind == .phone`. ✓
- "Stale phone owner → Force Retake" (transition 7) → `isStale` → placeholder + Force Retake copy (Task 3), never auto-acquired (Task 1). ✓
- Global: no new wire verbs (consumes D4 only) ✓; `embedded.conf` untouched ✓ (unmount via SwiftUI teardown, not `resize-window`); provider-neutral ✓ (no `agentId` branch anywhere); acceptance via `orch-test.sh` + `orch-ui-shot.sh` ✓ (Tasks 5–6).

**Placeholder scan:** every code step shows complete code; the only deferred items are explicit "reconcile with D4's actual signature" notes, which are unavoidable because D4 is a sibling PR — each names the exact symbol to check. No "TODO"/"add error handling"/"similar to Task N".

**Type consistency:** `DesktopTerminalDecision` (`.mount`/`.placeholder`), `desktopTerminalDecision(ownerKind:isStale:)`, `shouldAcquireDesktopOwnership(ownerKind:ownerClientId:desktopClientId:)`, `agentOwners: [UUID: AgentTerminalOwner]`, `agentOwner(for:)`, `acquireDesktopTerminal(_:)`, `retakeAgentTerminal(_:)`, `AgentTerminalPlaceholder(task:)` — used identically across Tasks 1→2→3→4→5. `AgentTerminalOwner`, `AgentTerminalOwner.Kind` (`.desktop`/`.phone`), `Event.agentTerminalOwnerChanged`, `ControlClient.clientId`, `ControlClient.takeOverAgentTerminal(ref:)` are all D4-owned and referenced verbatim from the Prerequisites contract.

**Open coupling to D4 (call out at execution):** if D4's owner event distinguishes "released → available" as its own payload, Task 2 step 2 clears the map key instead of assigning; if D4 computes staleness client-side from `updatedAt`, feed that boolean into the Task 1 policy (which already takes the boolean, not the struct). Neither changes the shape of D5 — only the one line that populates `agentOwners`.

---

## Execution Handoff

Plan complete and saved to `notes/plans/pr-d5-desktop-unmount.md`. Two execution options:

1. **Subagent-Driven (recommended)** — a fresh subagent per task with review between tasks. Best here because Task 1 is a clean TDD unit and Tasks 5–6 need screenshot review.
2. **Inline Execution** — execute in one session with checkpoints after Tasks 1, 4, and 6.

Note for whoever executes: **D4 must be merged into `mobile/d5-desktop-unmount` first** (see Prerequisites) — nothing in this plan compiles without it.
