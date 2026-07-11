# Fix: terminal (re)attach on the `→ live` edge (F1–F4) Implementation Plan

> **For agentic workers:** strict TDD for the pure gating logic; the SwiftUI hosting wiring is not
> unit-testable, so it is verified on an isolated built app. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make non-blocking spawn (PR4b) compose with terminal attach/takeover — a healthy running
agent must never show a blank pane (desktop) or a permanent "Could not take over" (iOS) just because
the tmux `agent` window didn't exist at the instant of the first attach.

**Architecture:** Extract the pure "(re)attach on the `→ live` edge" decision into `OrchestraKit`
(shared, table-tested — mirrors `TerminalReconnectPolicy`), then wire it into the desktop
`AgentTerminalView.updateNSView` and the iOS `TakeoverController`. Plus three small polish fixes
(F2 gating, F3 stale comment, F4 landing derivation).

**Tech Stack:** Swift, SwiftUI/SwiftTerm (App + App-iOS), Swift Testing (`swift test`).

## Global Constraints
- **Agent-agnostic:** no `if agentId ==`; the reattach is phase-driven (works for Claude + Codex).
- **Idempotent:** never double-attach a live pane; never re-fire on a non-edge update.
- **Don't weaken existing tests;** don't regress the clean daemon machinery (client/UI-side fix +
  tiny daemon comment/landing tweaks only).
- `swift test --no-parallel` green; mac App build + iOS typecheck green.

---

### Task 1: Pure `→ live` edge decisions in OrchestraKit (F1 core) — TDD

**Files:**
- Create: `Sources/OrchestraKit/TerminalReattachDecision.swift`
- Create test: `Tests/OrchestraUITests/TerminalReattachDecisionTests.swift`

**Interfaces — Produces:**
- `enum TerminalReattachDecision { static func shouldReattachOnLiveEdge(paneAlive:Bool, wasLive:Bool, isLive:Bool) -> Bool }`
- `enum TakeoverRetryDecision {`
  - `static func shouldRetry(beingBorn:Bool, attemptsSoFar:Int, maxAttempts:Int) -> Bool`
  - `static func isPermanentFailure(beingBorn:Bool) -> Bool`
  - `static func shouldRearmOnLive(wasLive:Bool, isLive:Bool) -> Bool }`

- [ ] **Step 1: failing tests** — desktop edge (dead pane × false→true ⇒ reattach; live pane / no-edge
  / not-live ⇒ no); iOS retry (being-born within budget ⇒ retry; budget spent / live-or-dead ⇒ no);
  permanent-failure only when NOT being born; re-arm only on false→true live edge.
- [ ] **Step 2: run** `swift test --filter TerminalReattachDecisionTests` → FAIL (type not defined).
- [ ] **Step 3: implement** the two enums (pure booleans, doc comments explaining each bug).
- [ ] **Step 4: run** `swift test --filter TerminalReattachDecisionTests` → PASS.
- [ ] **Step 5: commit.**

### Task 2: Desktop reattach-on-live wiring (F1 desktop)

**Files:** Modify `App/Views/AgentTerminalView.swift` (Coordinator + `makeNSView`/`updateNSView`).

- [ ] Track `paneAlive` (true after each attach, false in `processTerminated`) and `wasLive` (last
  gate value) on the `Coordinator`.
- [ ] In `updateNSView`, after the existing target-change branch, add an `else if
  TerminalReattachDecision.shouldReattachOnLiveEdge(...)` branch that re-arms the reconnect budget
  and re-attaches once; set `coord.wasLive = isLive` at the end of every update.
- [ ] Initialize `wasLive`/`paneAlive` at `makeNSView` attach.
- [ ] Verified on the isolated built app (Task 7), not a unit test (SwiftUI hosting).

### Task 3: iOS takeover retry + re-arm (F1 iOS)

**Files:** Modify `App-iOS/Terminal/TakeoverController.swift`; `App-iOS/Views/AgentTakeoverView.swift`
(phase `onChange`); fix the false comment in `App-iOS/Views/SpawnSheet.swift:499-500`.

- [ ] `begin()` drives a bounded acquire *loop*: on a failed grant, if the card is being born and
  within budget (`TakeoverRetryDecision.shouldRetry`) sleep the shared `TerminalReconnectPolicy`
  backoff and retry; a non-being-born failure is permanent (`.failed`); a being-born budget
  exhaustion stays `.acquiring` (keeps showing "Taking over…") until the `→ live` edge re-arms.
- [ ] `cardPhaseChanged(to:)` uses `TakeoverRetryDecision.shouldRearmOnLive` to reset the budget and
  restart a paused/failed loop; `AgentTakeoverView` calls it from `.onChange(of: card?.phase)`.
- [ ] Rewrite `SpawnSheet.swift:499-500` comment: PR4b made spawn non-blocking (no synchronous
  `agent` window); the takeover now retries until the card is live.

### Task 4: F2 — `openNotes` inside the connected gate — TDD

**Files:** Modify `Sources/OrchestraKit/DisplayState.swift`; update
`Tests/OrchestraUITests/DisplayStateTests.swift` (correct the offline assertion — this is fixing a
test that encodes the buggy contract, not weakening it).

- [ ] **Step 1:** change the offline test to `#expect(offline.validActions.isEmpty)` → run → FAIL.
- [ ] **Step 2:** move the `.openNotes` insert inside `if live { … }`; fix the misleading "local file
  op" comment to "daemon RPC, gated by the live link". Run → PASS.
- [ ] **Step 3: commit.**

### Task 5: F3 — stale `reconcileLiveness` comments

**Files:** `Sources/OrchestraCore/OrchestraService.swift:323`;
`Sources/OrchestraCore/OrchestraService+Recovery.swift:166`;
`Sources/OrchestraKit/AgentCapabilities.swift:50`.

- [ ] Fix `:323` "alongside reconcileLiveness" → "alongside the `reconcile()` tick"; mark
  `reconcileLiveness` **test-only** in its doc (production folds it into `reconcile()`); reconcile the
  `AgentCapabilities.swift:50` reference. Comment-only — no behavior change.

### Task 6: F4 — derive the adopt landing state

**Files:** `Sources/OrchestraCore/OrchestraService+Reconcile.swift:98`; make
`PhaseStepper.landing(of:)` internal (drop `private`).

- [ ] Replace the hardcoded `.live(.waiting(.humanTurn))` with
  `landing(of: deriveLaunchFlavor(t, adapter))` (mirror the LaunchStepper), falling back to
  `.waiting(.humanTurn)` if the adapter is unavailable; add a one-line comment (adopt skips the
  LaunchStepper, so it must derive the landing itself).

### Task 7: Verify + fold the contract

- [ ] `swift test --no-parallel` green; `scripts/build-app.sh` (mac) + iOS typecheck green.
- [ ] Isolated built-app F1 verify (project UI recipe): spawn a card, confirm the agent terminal
  auto-attaches when the agent comes up (no blank pane, no manual remount).
- [ ] Fold the F1 reattach-on-live requirement + F2 openNotes gating into
  `notes/designs/lifecycle-convergence/02-contract.md` Decisions.
- [ ] Dual review (Opus + GPT-5.5 codex) until clean; then `merge-request`.
