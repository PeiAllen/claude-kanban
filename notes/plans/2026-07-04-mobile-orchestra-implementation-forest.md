# Mobile Orchestra — Implementation PR Forest

> **For agentic workers:** this is the **overarching roadmap** for building the Orchestra iOS app
> + the daemon/desktop changes it requires. It decomposes the effort into a **dependency-ordered
> forest of small, single-purpose PRs**. Each PR entry below gets its **own detailed layered plan**
> (produced by a per-PR planning card using `superpowers:writing-plans` / `layered-plan`), then its
> own implementation card. Do **not** implement from this file directly — it is the map, not the
> turn-by-turn.

**Goal:** Ship an iOS Orchestra app with full control parity to the desktop (board, spawn+trust,
Needs-You, diffs, notes, recovery, settings) plus a phone-native Agent/Terminal model, backed by a
daemon-authoritative agent-terminal **takeover ownership lease** — designed for **both Claude and
Codex** through the existing adapter/capability seam.

**Architecture:** The daemon wire protocol stays UDS + NDJSON JSON-RPC. Reachability is the
already-shipped SSH-forwarded-UDS transport. New daemon work is **coordination + read primitives**
(ownership lease, `capture`, constrained `send-keys`, per-client identity), *not* a semantic
transcript renderer. The iOS app reuses `OrchestraCore` + a newly-extracted shared `BoardModel` +
`Theme` behind platform protocols; the terminal is SwiftTerm-iOS over an SSH PTY. Everything the
2026-07-02 connections work shipped is reused, not rebuilt.

**Tech Stack:** Swift 6 / SwiftUI, SwiftPM (multi-target), XcodeGen for the app targets, SwiftTerm
(macOS + iOS), tmux (`-L orchestra`, grouped view sessions), SSH multiplexed master, APNs.

## Global Constraints

- **Design for every agent (Claude AND Codex).** No `if agent == "claude"` branches; route provider
  differences through the existing adapter / capability seam (`Sources/OrchestraCore/Agents/`).
- **Daemon wire protocol changes stay minimal:** ownership coordination + `capture` + constrained
  `send-keys` + per-client identity. No TCP/WebSocket listener; no daemon PTY byte-proxy. Terminals
  ride tmux/SSH exactly as today.
- **Do not regress the desktop or the Linux daemon build.** `swift build` / `swift test` must stay
  offline-green; `scripts/build-app.sh` (macOS) and `scripts/build-linux-daemon.sh` must keep working.
- **`embedded.conf` (`window-size latest` + `aggressive-resize on`) is unchanged** for the primary
  path — it serves the desktop SwiftTerm↔CLI interop and gives per-window isolation for free.
- **Small stacked PRs over big ones.** Each PR is independently reviewable with its own acceptance
  criteria; stack only where a hard dependency exists.
- **Verify each change against both Claude and Codex** where the surface touches agent behavior
  (gates, capture, send-keys, Sixel).
- **Reuse the shipped primitives:** `exec` (block REPL), `shell`/`closeShell` (phone-owned window),
  `sessions`→`TmuxTarget` (attach recipe), `diffText`/`diffStat`, `trustState`/`trust`, `subscribe`
  event ring, `Connection`/`ConnectionStore`, `ControlClient` reconnect.

---

## Build-vs-new baseline (from the 2026-07-04 code audit)

| Capability | State | Evidence |
|---|---|---|
| `Transport` protocol + `UDSTransport` | **shipped** | `Control/Transport.swift:13,25` |
| `ControlClient` reconnect/backoff/re-subscribe + `connectionState` | **shipped** | `Control/ControlClient.swift:117,134,174` |
| `Connection` + `ConnectionStore` (in shared core) | **shipped** | `Connection.swift:6`, `ConnectionStore.swift:6` |
| SSH tunnel argv + master + activation | **shipped** | `RemoteCommands.swift:7`, `App/SSHMaster.swift:8`, `App/ConnectionController.swift` |
| Remote terminals + Connections settings UI | **shipped (App, AppKit)** | `App/Views/AgentTerminalView.swift:13`, `App/Views/ConnectionsSettingsView.swift:7` |
| Linux socket port (Glibc/Musl, `MSG_NOSIGNAL`) | **shipped** | `Control/UDSSocket.swift` |
| `exec` (block-REPL primitive) | **shipped, unused by app** | `Commands.swift:246`, `OrchestraService.swift:567` |
| `shell`/`closeShell` (phone-owned window lifecycle) | **shipped, leak-safe** | `SessionManager.swift:78,90` |
| `sessions`→`TmuxTarget` (attach-recipe discovery) | **shipped** | `Commands.swift:257`, `Model.swift:418` |
| `subscribe`/Event/200-item ring; `diffText`/`diffStat`; `trustState`/`trust`; `waitReason` | **shipped** | `ControlServer.swift`, `Commands.swift` |
| `BoardModel` + `Theme` in a **shared** target | **NOT built** (in `App/`) | `App/BoardModel.swift`, `App/Theme.swift` |
| Platform protocols (`Clipboard`/`TerminalHost`/`SystemOpener`/`WindowConfig`) | **NOT built** | — |
| `Foundation.Process` out of the client-safe lib (iOS blocker) | **NOT built** | `Proc.swift:25,132,159` |
| iOS SwiftPM/XcodeGen target + `os(iOS)` gates + iOS build path | **NOT built** | `Package.swift:17` macOS-only |
| `capture` (capture-pane) RPC | **NOT built** (design assumed it exists) | — |
| constrained `send-keys` RPC (key schema) | **NOT built** (`sendKeys` internal, line-only) | `SessionManager.swift:145` |
| per-client identity on the wire (`clientId`) | **NOT built** (`source` = app/cli/mcp only) | `RPC.swift:9` |
| agent-terminal ownership lease + `agentTerminalOwner`/`takeOverAgentTerminal`/`releaseAgentTerminal`/`heartbeatAgentTerminal` | **NOT built (greenfield)** | — |
| desktop unmount + "Taken over by phone" placeholder + Retake | **NOT built** | — |
| notes-content-over-RPC (phone Notes page) | **NOT built** (`openNotes` opens Obsidian on host) | `ControlServer.swift openNotes` |
| iOS SwiftTerm SSH-PTY terminal; all iOS UI; APNs; Codex gate/Sixel | **NOT built** | — |

---

## The PR forest (dependency graph)

```
FOUNDATION (unblocks all iOS UI)
  F1 core-split ─┬─ F2 platform-protocols+shared-boardmodel ─── F3 ios-skeleton ─┐
                 │                                                                │
DAEMON PRIMITIVES (parallel; unblock terminal/agent + takeover)                  │
  D1 capture-rpc          (independent)                                          │
  D2 send-keys-rpc        (independent)                                          │
  D3 client-identity ──── D4 ownership-lease ──── D5 desktop-unmount             │
                                                                                 │
IOS READ SURFACES (stack on F3)                                                  │
  F3 ─┬─ M1 board-pager ─┬─ M2 card-detail(Info+Diff) ─┬─ M6a notes-rpc ─ M6 notes-page
      │                  ├─ M3 needs-you               ├─ M7 recovery
      │                  └─ M4 spawn+trust             │
      └─ M5 settings                                   │
IOS TERMINAL + AGENT (stack on F3 + daemon)            │
  F3 ─ T1 ios-ssh-pty-terminal ─┬─ T2 terminal-tab(block-REPL + live shell)
                                └─ T4 takeover  (also needs D4+D5)
  M2 + D1 + D2 ─ T3 agent-tab (capture render + steer + gates)
CODEX PARITY + DELIVERY
  C1 codex-permission-gate  (needs M3)
  C2 codex-sixel            (needs T3)
  N1 apns-delivery          (needs M3)
```

**Wave ordering for Phase B/C:**
- **Wave 0 (plan+build first, mostly serial):** F1 → F2 → F3. D1, D2, D3 can plan/build in parallel with F1–F3 (they touch daemon, not iOS).
- **Wave 1:** D4 (after D3); M1, M5 (after F3); T1 (after F3).
- **Wave 2:** D5 (after D4); M2, M3, M4 (after M1); T2 (after T1+M2); T3 (after M2+D1+D2).
- **Wave 3:** M6a→M6, M7 (after M2); T4 (after T1+D4+D5); C1 (after M3); C2 (after T3); N1 (after M3).

---

## FOUNDATION

### PR F1 — Split a client-safe core out of `OrchestraCore`

**Branch:** `mobile/f1-core-split` · **Stacks on:** none (base = `main`/`mobile-impl-orchestration`)

**Problem:** `OrchestraCore` compiles daemon-side code (`Proc`, `SessionManager`, `OrchestraService`,
`Launcher`, `DaemonLifecycle`) that uses `Foundation.Process` / `posix_spawn`, unavailable on iOS.
An iOS client only needs models + the Control **client** + `Connection`/`ConnectionStore` + the RPC
codec + command *schema*.

**Scope:**
- Introduce a client-safe SwiftPM library target (proposed name **`OrchestraKit`**) containing:
  `Model.swift`, `Control/{Transport,ControlClient,RPC,RPCCodec,UDSSocket,LineReader}.swift`,
  `Connection.swift`, `ConnectionStore.swift`, `RemoteCommands.swift`, `Config` (path resolvers),
  the `Command` *name/arg schema* (not the daemon execution), and shared enums (`CardOrigin`,
  `CardAccess`, `DeadReason`, `waitReason`, `TmuxTarget`, `ExecResult`, etc.).
- Keep daemon-only code (`SessionManager`, `Proc`, `OrchestraService*`, `Launcher`, `DaemonLifecycle`,
  `ControlServer`, `CommandRegistry` execution) in `OrchestraCore`, which now **depends on**
  `OrchestraKit`.
- `Package.swift`: `OrchestraKit` gets `platforms: [.macOS(.v14), .iOS(.v17)]`; `OrchestraCore`/
  `orchestrad`/`orchestra`/`orchestra-mcp` stay macOS/Linux and depend on `OrchestraKit`.
- No behavior change; pure module re-partition + import fixups.

**Files:** `Package.swift`; move files under `Sources/OrchestraKit/`; update imports across
`Sources/OrchestraCore/`, `orchestra`, `orchestra-mcp`, `orchestrad`, and the test targets.

**Design pointers:** phone-client `01-design.md` (shared-core split), `02-contract.md` (§major
classes). Audit: `Proc.swift:25,132,159`; `Package.swift:17-58`.

**Acceptance criteria:**
- `swift build` and `swift test` green on macOS (offline).
- `scripts/build-linux-daemon.sh` still cross-compiles.
- `OrchestraKit` compiles for iOS in isolation: `swift build --sdk $(xcrun --sdk iphoneos
  --show-sdk-path) -Xswiftc -target -Xswiftc arm64-apple-ios17.0` (or an equivalent typecheck) has
  **zero** `Foundation.Process`/AppKit references.
- `scripts/build-app.sh` (macOS app) still builds after the import re-point.

---

### PR F2 — Platform protocols + move `BoardModel`/`Theme` into shared code

**Branch:** `mobile/f2-platform-protocols` · **Stacks on:** F1

**Problem:** `BoardModel` (the board view model) and `Theme` live in the macOS `App/` target, and
`BoardModel` has 4 unguarded AppKit call sites. iOS can't reuse them as-is.

**Scope:**
- Define platform protocols in `OrchestraKit` (or a new `OrchestraUI` shared SwiftUI target if
  `BoardModel` needs SwiftUI — decide in the per-PR plan): `Clipboard`, `TerminalHost`,
  `SystemOpener`, `WindowConfig`, injected via SwiftUI `Environment`.
- Move `Theme.swift` (pure SwiftUI, zero AppKit) into the shared target unchanged.
- Move `BoardModel.swift` into the shared target; replace its 4 AppKit couplings
  (`App/BoardModel.swift:619-620` `NSPasteboard`, `:633` `NSApp.sendAction`, `:656`
  `makeFirstResponder`) with protocol calls.
- Provide **macOS** implementations of the protocols in `App/` (AppKit-backed) and wire them into the
  existing app so the desktop is behavior-identical.

**Files:** new `Sources/OrchestraUI/` (or into `OrchestraKit`): `PlatformProtocols.swift`,
`BoardModel.swift`, `Theme.swift`; `App/` gets `MacPlatform.swift` (impls) + env wiring in
`OrchestraApp.swift`.

**Design pointers:** phone-client `02-contract.md` §platform protocols. Audit: `App/BoardModel.swift`
AppKit sites; `App/Theme.swift` is portable.

**Acceptance criteria:**
- Desktop app builds and behaves identically (clipboard copy, open-settings, focus-clear all work).
- Shared `BoardModel` + `Theme` compile for iOS (no AppKit).
- `swift test` green (add a fake-platform test double for the protocols).

---

### PR F3 — iOS app skeleton + build path

**Branch:** `mobile/f3-ios-skeleton` · **Stacks on:** F2

**Scope:**
- New iOS app target (XcodeGen `App-iOS/project.yml` or a shared spec with an iOS target), min iOS 17,
  linking `OrchestraKit`/`OrchestraUI` + SwiftTerm (iOS).
- Minimal SwiftUI `@main` App: bottom tab bar **Board · Needs You · Settings** (stub contents),
  builds a `ControlClient` from the active `Connection` (reuse `ConnectionStore`), and renders a live
  `BoardModel` list (proves the shared core + reconnect work on-device).
- iOS platform-protocol impls (`UIPasteboard` clipboard, no-op `SystemOpener`/`WindowConfig`, a
  placeholder `TerminalHost` until T1).
- `scripts/build-ios-app.sh` (xcodegen + `xcodebuild -destination 'generic/platform=iOS Simulator'
  build`) + a typecheck script mirroring `typecheck-app.sh`.

**Design pointers:** mobile spec §1 (global structure), phone-client `01-design.md`.

**Acceptance criteria:**
- iOS app builds for the Simulator via the new script.
- Launched against a local daemon (over the dev transport), it shows real cards from `BoardModel`
  and reflects `connectionState`.
- Desktop + Linux builds still green.

---

## DAEMON PRIMITIVES

### PR D1 — `capture` RPC (read-only pane capture)

**Branch:** `mobile/d1-capture-rpc` · **Stacks on:** none (parallel with Foundation)

**Scope:** Add `SessionManager.capture(session:window:)` (runs `tmux -L … capture-pane -p -t …`,
bounded output) + a `capture` verb in `CommandRegistry` + a `ControlClient.capture(...)` convenience.
This is the non-attaching read the phone Agent tab uses in v1.

**Files:** `SessionManager.swift`, `Commands.swift`, `OrchestraService.swift`, `Control/ControlClient.swift`.

**Design pointers:** phone-terminal UX §"Reading" (capture fallback). Audit: capture is **missing**
despite the design assuming `SessionManager.capture` exists.

**Acceptance criteria:** unit/integration test captures a known scratch tmux pane and returns its
text; output is size-capped; works for both `agent` and `shell` windows; no attach / no resize.

---

### PR D2 — constrained `send-keys` RPC (key schema)

**Branch:** `mobile/d2-send-keys-rpc` · **Stacks on:** none

**Scope:** Add a typed key-send API distinct from the inbox `send`: a `KeyChord`/named-key schema
(`Esc`, `Up`/`Down`/`Left`/`Right`, `Tab`, `Enter`, `C-c`, `PgUp`/`PgDn`, `Home`/`End`, literal
text) → `SessionManager` `tmux send-keys` → a `send-keys` verb + `ControlClient` method. Explicit
schema; do **not** overload the existing message `send`.

**Files:** `SessionManager.swift` (extend `sendKeys`/add `sendChord`), `Commands.swift`,
`OrchestraService.swift`, `Control/ControlClient.swift`, a `KeyName` enum in `OrchestraKit`.

**Design pointers:** phone-terminal UX failure mode "Special-key input" + §"Steering"/menu prompts.
Audit: `SessionManager.sendKeys:145` is line-only; no RPC verb.

**Acceptance criteria:** sends each named key to a scratch session and asserts the pane reacts
(e.g. `C-c` interrupts, arrows move a menu); literal text path preserved; used by captured-prompt
buttons later.

---

### PR D3 — Per-client identity on the wire

**Branch:** `mobile/d3-client-identity` · **Stacks on:** none (prereq for D4)

**Scope:** Add a stable `clientId` to the client↔server session (handshake on `subscribe`/connect;
carried on `RPCRequest` alongside the existing `source`). `ControlServer` tracks connection→clientId
so ownership can be attributed and stale owners detected on disconnect.

**Files:** `Control/RPC.swift` (add `clientId`), `Control/ControlClient.swift` (generate/persist a
per-install id), `Control/ControlServer.swift` (register clientId per `PeerConnection`).

**Design pointers:** phone-terminal UX ownership state model (`clientId` field). Audit: `RPC.swift:9`
`source` = app/cli/mcp only; anonymous `PeerConnection`.

**Acceptance criteria:** server can name which client sent a call and detect that client's
disconnect; backward-compatible (missing `clientId` tolerated for CLI/MCP).

---

### PR D4 — Agent-terminal ownership lease (daemon-authoritative)

**Branch:** `mobile/d4-ownership-lease` · **Stacks on:** D3

**Scope:** Ephemeral owner record keyed by `cardId` + `window=agent`:
`{ ownerKind: desktop|phone, clientId, epoch, cardId, window, updatedAt }`, state machine
`available → desktopOwned → phoneOwned → desktopOwned`. RPCs:
- `agentTerminalOwner(ref)` → current owner + epoch + stale/fresh.
- `takeOverAgentTerminal(ref, clientId)` → compare-and-set, `epoch++`, emit owner event, return attach
  target (reuse `sessions`/`TmuxTarget`).
- `releaseAgentTerminal(ref, clientId, epoch)` → clear only if caller holds the current epoch.
- `heartbeatAgentTerminal(ref, clientId, epoch)` → refresh across reconnects; stale after a timeout.
Broadcast owner-state changes over the existing `subscribe` event stream. Compare-and-set on `epoch`
guards multi-phone / stale-release races.

**Files:** new `Sources/OrchestraCore/TerminalOwnership.swift` (state), `Commands.swift` (4 verbs),
`OrchestraService.swift` (wiring + event emit), `Control/ControlClient.swift` (client methods),
`Model.swift` (owner event payload in `OrchestraKit`).

**Design pointers:** phone-terminal UX §"State model"/"Transitions"/"Control surface"; failure modes
(stale owner, multiple phones, bypass attaches). Ownership is **ephemeral UI coordination, not
durable card state.**

**Acceptance criteria:** integration test drives available→desktop→phone→desktop; a stale-epoch
release is rejected; a phone disconnect marks the owner stale after the heartbeat window; owner
events reach subscribers.

---

### PR D5 — Desktop unmount + "Taken over by phone" placeholder + Retake

**Branch:** `mobile/d5-desktop-unmount` · **Stacks on:** D4

**Scope:** Desktop app subscribes to owner events. On `phoneOwned` for a card, tear down that card's
`AgentTerminalView` and show a **"Taken over by phone"** placeholder with **Retake Terminal**
(→ `takeOverAgentTerminal` as desktop). On desktop select, acquire `desktopOwned` unless phone owns.
Prevents the desktop auto-reattach resize-fight.

**Files:** `App/Views/AgentTerminalView.swift` / `InspectorView.swift` (placeholder + teardown),
`App/BoardModel.swift` (consume owner events), a small owner-state observable.

**Design pointers:** phone-terminal UX transitions 1,4,6; failure mode "Desktop reattaches during
phone ownership."

**Acceptance criteria:** with an isolated daemon, simulating a `phoneOwned` event unmounts the
desktop terminal and shows the placeholder; Retake flips ownership and reattaches; verified via the
`orch-test.sh`/`orch-ui-shot.sh` harness.

---

## IOS READ SURFACES

### PR M1 — Board pager + card read surfaces
**Branch:** `mobile/m1-board-pager` · **Stacks on:** F3
**Scope:** Swipeable full-width pager **Freeform · Plan · Impl · Review** with per-page counts;
card cells (title, `repo/branch` mono, status pill, model, ctx mini-gauge, diffstat, activity line);
Freeform page distinct (mode chip Freeform/Scratch, dir path, Read-only badge). Move-a-card
(hold-swipe + "Move to…" menu → `move`, which notifies the agent). Reuses shared `BoardModel`.
**Design pointers:** mobile spec §2, §2a. **Acceptance:** renders live board, all 4 pages, move works
and the daemon queues the column-change inbox message.

### PR M2 — Card detail shell + Info + Diff tabs
**Branch:** `mobile/m2-card-detail` · **Stacks on:** M1
**Scope:** Tabbed full-screen card detail (pinned header: title, status, model selector, ctx gauge,
worktree breadcrumb); **Info** tab (Mode/Access, session id, Restart, Copy branch, Archive w/ confirm,
Open notes entry — no Zed/Finder actions); **Diff** tab (Working·Branch·Parent toggle via
`diffText`/`diffStat`, Parent only for stacked cards). Agent/Terminal tabs are stubs until T2/T3.
**Design pointers:** mobile spec §3 (Info, Diff). **Acceptance:** diff renders all baselines; Info
actions call the right RPCs; Parent hidden for non-stacked cards.

### PR M3 — Needs-You attention queue
**Branch:** `mobile/m3-needs-you` · **Stacks on:** M1
**Scope:** Badged tab listing cards blocked on the human, sorted most-urgent-first; reason chips
🔐 Permission (`waitReason==.permission`) / 🙋 Needs you (`.humanTurn`) / 💀 Died / ◔ Context-full;
**exclude background-waits**; inline actions per reason (Approve/Deny, reply/steer, deep-link to
Recovery), open-card, snooze. Backed by the shipped `waitReason`/status events.
**Design pointers:** mobile spec §6. **Acceptance:** each reason renders with correct actions;
background-waiting cards never appear; Approve/Deny drive the gate.

### PR M4 — Spawn sheet + trust flow
**Branch:** `mobile/m4-spawn-trust` · **Stacks on:** M1
**Scope:** Spawn modal (prompt, backend Claude/Codex, model, **Worktree·Freeform·Scratch** chip +
separate **Read-only** toggle). Worktree: repo/branch → computed path preview. Freeform: dir picker →
on change check `trustState`; untrusted → amber notice (Trust & allow writes / Keep read-only) that
**forces read-only** + CTA "Spawn read-only agent"; granting trust via `trust` from the sheet.
**Design pointers:** mobile spec §4. **Acceptance:** spawn works in all 3 modes; untrusted dir forces
read-only until trusted; mirrors desktop spawn semantics for Claude and Codex.

### PR M5 — Settings (Connection · Notifications · Appearance · About)
**Branch:** `mobile/m5-settings` · **Stacks on:** F3
**Scope:** Connection status banner (bind `connectionState`); Connection list (reuse
`ConnectionStore`: This Mac + remotes, active radio, Add/Edit remote); Notifications (3 triggers ×
scope dial Off/Background/Always × sound dial, with the background-wait helper line); Appearance
(theme/accent); About (app + daemon version). **Design pointers:** mobile spec §7. **Acceptance:**
round-trips a remote `Connection`; switching active connection re-targets the transport; notification
prefs persist.

### PR M6a — Notes-content RPC
**Branch:** `mobile/m6a-notes-rpc` · **Stacks on:** M2 (daemon change; can plan early)
**Scope:** RPC returning the set of `.md` files this branch changed/added (path + M/A badge + content),
reusing the same changed-notes computation the desktop Open Notes uses — because the phone can't open
Obsidian on the host. **Acceptance:** returns changed/new markdown with content for a worktree card.

### PR M6 — Notes page (rendered markdown)
**Branch:** `mobile/m6-notes-page` · **Stacks on:** M6a
**Scope:** Pushed page: file switcher (M/A badges) + in-app markdown render (headings, lists, inline +
fenced code, blockquotes). **Design pointers:** mobile spec §3 Notes page. **Acceptance:** lists
changed `.md`, renders selected file styled.

### PR M7 — Recovery view (dead card)
**Branch:** `mobile/m7-recovery` · **Stacks on:** M2
**Scope:** Dead card replaces agent chrome with Recovery: why it ended (`DeadReason`), preserved work
(repo/branch/path + Copy path), original prompt (`task.initialPrompt`) + Copy prompt, actions Start
new / Try resume (when session id) / Archive. **Design pointers:** mobile spec §3 Recovery.
**Acceptance:** mirrors desktop `RecoveryView`; Copy prompt grabs verbatim initial prompt; resume
only when a session id exists.

---

## IOS TERMINAL + AGENT

### PR T1 — iOS SwiftTerm SSH-PTY terminal (`TerminalHost` iOS impl)
**Branch:** `mobile/t1-ios-terminal` · **Stacks on:** F3
**Scope:** The heaviest integration: a UIKit SwiftTerm `TerminalView` driven over an SSH PTY
(`ssh -tt … tmux -L … attach -t …`), implementing the `TerminalHost` protocol for iOS, with SSH-key
handling (Keychain). Reuses the grouped-view-session attach recipe. No daemon byte-proxy.
**Design pointers:** phone-client `01-design.md` (iOS terminal over SSH PTY); phone-terminal UX
research notes (SwiftTerm iOS). **Acceptance:** attaches to a live tmux window over SSH and renders;
reconnect is idempotent (reuses the same view session).

### PR T2 — Terminal tab: block REPL + attach live shell
**Branch:** `mobile/t2-terminal-tab` · **Stacks on:** T1, M2 (uses shipped `exec`, `shell`/`closeShell`)
**Scope:** Default **block REPL**: "Run a command…" → `exec` in the worktree → copyable output block
(notebook of blocks, no PTY). Opt-in **Attach live shell**: live PTY in a **phone-owned** `shell`
window (`shell`/`closeShell`, `phone-`-prefixed identity, idempotent reconnect, TTL reap). Minimal
key-accessory bar + Select mode only in live mode. **Design pointers:** phone-terminal UX §"Terminal
tab". **Acceptance:** block REPL runs common commands with copyable output; live shell attaches to a
phone-owned window without touching desktop window sizes (verify per-window independence).

### PR T3 — Agent tab: non-attaching capture render + steer + gates
**Branch:** `mobile/t3-agent-tab` · **Stacks on:** M2, D1 (capture), D2 (send-keys)
**Scope:** Non-attaching Agent surface: v1 `capture`-backed scroll render + status/ctx/`waitReason`
from board events; "Message the agent" bar (`send`/constrained `send-keys`, no attach); gates surface
as Needs-You (Claude permission hook) or captured-prompt semantic buttons (Codex fallback via
`send-keys`); explicit **Take Over Agent Terminal** button → T4. **Design pointers:** phone-terminal
UX §"Agent tab". **Acceptance:** shows live capture + steer for Claude and Codex; no attach/no resize;
captured-prompt buttons send the right keys.

### PR T4 — Takeover: full-screen live terminal under the lease
**Branch:** `mobile/t4-takeover` · **Stacks on:** T1, D4, D5
**Scope:** Full-screen live terminal reached from Agent's Take Over: acquire `phoneOwned`
(daemon-authoritative), attach the real `agent` TUI only after desktop unmounts, heartbeat to keep
fresh. UI: compact owner bar (title/status, connection, *You have control*, **Return to Desktop**),
**armed input** ("Start Typing"), minimal key bar (Esc·sticky Ctrl·Tab·↵·↑·↓·⋯), **Select** mode,
A−/A+, landscape posture. Release on Return/disconnect (epoch-guarded). **Design pointers:**
phone-terminal UX §"Live takeover display" + Option-1 transitions. **Acceptance:** takeover attaches
the real TUI after desktop unmount; Return/Retake flips cleanly; stale phone owner offers Force
Retake; reflow is intentional (single owner).

---

## CODEX PARITY + DELIVERY

### PR C1 — Codex permission-gate wiring
**Branch:** `mobile/c1-codex-gate` · **Stacks on:** M3
**Scope:** Wire Codex `PermissionRequest` hook → `waitReason == .permission` → Needs-You Approve/Deny,
matching Claude's gate, through the adapter seam (Orchestra currently installs only Codex
`SessionStart`). Captured-prompt `send-keys` remains the fallback for non-permission TUI prompts.
**Design pointers:** phone-terminal UX §"Gates"/Codex + Decisions table. **Acceptance:** a Codex
permission request appears as a Needs-You row and Approve/Deny resolves it; fallback path intact.

### PR C2 — Codex Sixel image rendering in Agent tab
**Branch:** `mobile/c2-codex-sixel` · **Stacks on:** T3
**Scope:** Render Codex Sixel images as native images at phone width in the capture/structured Agent
view. **Design pointers:** phone-terminal UX failure mode "Codex Sixel width." **Acceptance:** a Codex
Sixel image renders as a native image scaled to phone width.

### PR N1 — APNs / notifications delivery
**Branch:** `mobile/n1-apns` · **Stacks on:** M3
**Scope:** Backend APNs delivery for the three attention triggers (respecting scope/sound dials and
background-wait suppression) + iOS push registration + deep-link into the in-app Needs-You queue.
**Design pointers:** mobile spec §6 (push is a backend follow-on the in-app queue deep-links into).
**Acceptance:** a permission/needs-you/died event delivers a push per the user's dial settings and
deep-links to the right card; background-waits never alert.

---

## Self-review (spec coverage)

- Mobile spec §1 global structure → F3, M1, M3, M5. §2 board pager + move → M1. §2a Freeform → M1.
  §2b Done archive → **folded into M1** (pushed screen; call out in M1's per-PR plan). §3 tabs:
  Agent→T3, Terminal→T2, Diff→M2, Inbox→**M2 per-PR plan adds the Inbox tab** (durable inbox editor;
  `inbox`/`inbox-edit`/`inbox-remove`/`inbox-reorder` all shipped), Info→M2. Notes→M6/M6a. Takeover→T4.
  Recovery→M7. §4 spawn+trust→M4. §5 Activity→**M1 per-PR plan adds the pushed Activity feed**
  (Live/CLI filter). §6 Needs-You→M3, push→N1. §7 Settings→M5.
- Phone-terminal UX: Problem 2 sizing/ownership → D3/D4/D5/T4; Agent tab → T3 (+D1/D2); Terminal
  block-REPL + phone-owned shell → T2; live takeover display → T4; Codex gates/Sixel → C1/C2.
- Connections/phone-client seams: Transport/reconnect/Connection → **shipped**; shared-core split +
  platform protocols → F1/F2; iOS terminal over SSH PTY → T1.

**Two coverage notes folded into neighboring PRs (make explicit in their per-PR plans):** the **Inbox
tab** and **Activity feed** and **Done archive** are small pushed surfaces over already-shipped RPCs;
they ride M1/M2 rather than earning their own PRs. If a per-PR planning card finds either non-trivial,
it may split it out — flag back to the orchestrator.

## Open questions for per-PR plans to resolve
- F1/F2: one shared target (`OrchestraKit`) vs. a separate `OrchestraUI` SwiftUI target for
  `BoardModel`/views — decide by whether `BoardModel` imports SwiftUI.
- D4: exact owner-event payload shape on the `subscribe` stream; heartbeat/stale timeout values.
- T2: phone-owned shell identity (`phone-<client>-<n>`) + reap policy (reconnect vs TTL).
- M6a: reuse path for the desktop's changed-notes computation over RPC.
- C1: how far to wire Codex `PermissionRequest` now vs. leave captured-prompt fallback.
