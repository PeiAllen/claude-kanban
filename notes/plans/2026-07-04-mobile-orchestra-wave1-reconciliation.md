# Wave-1 Plan Reconciliation (F1·F2·F3·D1·D2·D3·D4·D5)

> The 8 Wave-1 plan cards planned in parallel, so a few interfaces were named/scoped before their
> siblings finalized. This note is the **authoritative reconciliation** — every Phase C implementation
> card for a Wave-1 PR MUST apply the decision for its PR here, on top of its own `pr-*.md` plan.
> Recorded after all 8 plans landed (F1 3b… /F2 19b8118 /F3 58d3402 /D1 72b7e4d /D2 de54c90 /D3 /D4
> 3b61b90 /D5 85d8419).

## Module layering — SETTLED and consistent

```
OrchestraKit  (Foundation-only, macOS14 + iOS17, Linux-safe — orchestrad links it)
   ├─ Model + shared enums, JSONValue/Coders/Errors/Config/Version/Platform
   ├─ Control/{Transport, RPC(+RPCCodec), UDSSocket(+LineReader), ControlClient}
   ├─ Connection / ConnectionStore / RemoteCommands
   ├─ CommandCatalog (name/arg schema)
   └─ BoardNavigator + TaskRef            ← RECONCILE #1 (moved here, see below)
        ▲
OrchestraUI  (SwiftUI, macOS14 + iOS17 — NEVER linked by orchestrad/Linux)
   ├─ Theme
   ├─ BoardModel(platform: PlatformUI)     (macOS-only machinery #if os(macOS)-fenced)
   └─ Clipboard / SystemOpener / WindowConfig / TerminalHost protocols + Environment keys
        ▲
App (macOS)   /   App-iOS
        ▲
OrchestraCore (daemon: Proc, SessionManager, OrchestraService*, ControlServer, CommandRegistry
               handlers, Launcher, Agents/Diff; `@_exported import OrchestraKit`)
```

F1 and F2 independently agreed on this split (F1 recommended a separate SwiftUI target; F2 created
`OrchestraUI`). **Hard invariant:** `OrchestraKit` stays SwiftUI-free because `orchestrad` links it and
cross-compiles on Linux.

## Reconciliation decisions (apply in Phase C)

**#1 — `BoardNavigator` + `TaskRef` live in `OrchestraKit`, not `OrchestraCore`.**
F1's draft left `Keyboard/` (incl. these) in `OrchestraCore`; F2's shared `BoardModel` (in `OrchestraUI`,
which depends only on `OrchestraKit`) needs them. → **The F1 impl card moves `BoardNavigator`/`TaskRef`
into `OrchestraKit`** (Foundation-only nav types). This makes F1 the single boundary-definer and deletes
F2's contingency move. (The rest of `Keyboard/`, if daemon-coupled, stays in Core.)

**#2 — New Wave-1 shared types land in `OrchestraKit`; F1 merges FIRST.**
D1 (`CaptureResult`), D2 (`KeyName`), D3 (`clientId`/`ClientIdentity`), D4 (`AgentTerminalOwner*`,
`TakeOverResult`) each added their type to `Model.swift`/a Core file "to be re-filed to OrchestraKit
post-F1." → **Implement F1 first, then rebase D1–D4 onto it and put those types directly in
`OrchestraKit`.** No add-to-Core-then-relocate churn.

**#3 — F3 consumes F2's shared `BoardModel`, not a throwaway `IOSBoardModel`.**
F3 planned (before F2 finalized) a separate `IOSBoardModel`, deferring the shared model to M1. F2 instead
keeps `BoardModel` shared with macOS machinery `#if os(macOS)`-fenced and leaves an `#if os(iOS)
activate()` **stub for F3 to fill**. → **F3 uses `OrchestraUI.BoardModel(platform:)` + fills the iOS
`activate()` connection stub** (dev transport via `ConnectionSocketResolver` / `ORCH_DEV_SOCKET`). Keep
F3's thin-model design ONLY as a fallback if F2's fencing proves insufficient at iOS build time — decide
at F3 build, not now. (This also removes M1's "swap to shared model" step.)

**#4 — D5 uses D4's real event name `Event.agentTerminalOwner`.**
D5's draft referenced `Event.agentTerminalOwnerChanged`; D4 defines `Event.agentTerminalOwner(AgentTerminalOwnerState)`.
→ **D5 adopts `Event.agentTerminalOwner`.** All other D4↔D5 contract names match (`AgentTerminalOwner`,
`takeOverAgentTerminal(ref, clientId, kind:.desktop)`, `agentTerminalOwner(ref)` reconcile-on-connect).

**#5 — D3 is a SOFT dependency of D4 (relaxed from the tree's hard edge).**
D4 passes `clientId` as an explicit `String` RPC param, so the lease + all its acceptance tests work
**without D3**. D3 only unlocks an optional server-side disconnect fast-path (D4 Task 6). → Still
implement **D3 before D4** for the fast-path, but D4 does not block on D3; if D3 slips, D4 ships with the
`updatedAt`+30s staleness path alone.

**#6 — The 4 ownership RPCs are app-only `ControlServer` dispatch cases, NOT `CommandRegistry`/MCP tools.**
D4 (correctly) placed `agentTerminalOwner`/`takeOverAgentTerminal`/`releaseAgentTerminal`/
`heartbeatAgentTerminal` as `ControlServer` dispatch cases (the `diffText` precedent), **not** MCP/CLI
verbs — because agents must never seize a terminal and the calls need `clientId` attribution. This
overrides the forest doc's "add to `Commands.swift`" wording for D4. `ControlClient` gets typed
convenience methods; the phone/desktop call them, agents cannot.

## Confirmed-coherent (no action)

- **D1/D2 verbs** (`capture`, `send-keys`) DO go through `CommandRegistry` (they're safe read/steer
  primitives) — distinct from D4's app-only dispatch. Intentional and consistent.
- **D2's `KeyName` chord has no implicit Enter** — the exact thing separating it from the line-only
  `SessionManager.sendKeys` and the inbox `send`. Good.
- **D3's `clientId` is one additive optional `RPCRequest` field** — CLI/MCP frames byte-identical;
  anonymous connections tolerated. Matches D4's expectation.
- **No `embedded.conf` change, no `resize-window`, no attach/resize** in D1/D4/D5 — the sizing invariant
  holds; desktop stays byte-identical (macOS machinery fenced verbatim).

## Phase C implementation order (all merges → `mobile-impl-orchestration`, never `main`)

1. **F1** (defines `OrchestraKit`, incl. reconcile #1). — merge first.
2. Off F1, the **daemon spine, serial** (they touch `ControlServer`/`Model`/`CommandCatalog`): **D1 →
   D2 → D3 → D4**. (D5 waits for D4.)
3. In parallel off F1: **F2** (`OrchestraUI` + BoardModel split) → **F3** (iOS skeleton, reconcile #3).
4. **D5** off D4 (desktop unmount, reconcile #4).
5. Gate: green desktop build + Linux cross-build + iOS-sim build + `swift test` on the integration
   branch → then start **Wave 2** (M1, M5, T1 → M2, M3, M4).
