# Shell sync between phone and desktop

**Status:** decided → implementing · **Card:** `65a7f2` · **Branch:** `fix/ios-shell-sync-phone-desktop`

## Problem

Shells don't sync across the iPhone and Mac apps. Open a shell on the computer and the phone
doesn't show it, and vice versa. Each surface maintains its own disjoint set of open shells.

## Root cause — the split is entirely in the client layer

Both a desktop `shell-N` window and a phone `phone-<client>` window are created inside the **same**
`orchestra-<id>` tmux session on the same daemon; `SessionManager.windows()` already returns both to
whoever asks (`SessionManager.swift:148`). Three independent client-layer facts create the divergence:

1. **No broadcast.** Shell open/close is never an `Event`; `openShell`/`closeShell` never `emit`
   (`OrchestraService.swift:548,583`; `Event` enum `Model.swift:660`). Contrast the agent terminal,
   whose ownership *is* broadcast (`agentTerminalOwner`).
2. **Poll-only, connect-only discovery.** The only thing that turns tmux windows into client state is
   `refreshShellPanels` (`BoardModel.swift:390`), and it runs solely inside `refresh()` at
   (re)connect (`:381`). No live update, no periodic poll.
3. **The phone never uses the shared list.** `LiveShellView` (`TerminalTab.swift:276`) is a single-
   window view bound to its own `@State target` from `openPhoneShell` (`BoardModel.swift:705`). It
   never reads `shellWindows`, so it structurally cannot show the desktop's `shell-N`.

## Design question: shared PTY windows vs per-client windows

**Decision: per-client-owned windows, made mutually VISIBLE/listed via a broadcast shell registry.
Preserve the phone-owned-input model.** This is the task's explicitly-acceptable "per-client windows
that are at least mutually visible/listed" option, and it is *forced* by tmux mechanics:

- The grouped "view session" (`TmuxAttach.viewSession`, `TmuxAttach.swift:20`) is keyed by
  `(base, window)` **only** — not by client. Two clients attaching the **same** window share one view
  session; tmux then sizes that window to the **smallest** attached client. A phone (small) and a
  desktop (large) on one shell would **resize-fight**, and both would compete for the one PTY's stdin.
- The phone's `phone-<client>` naming exists **precisely** to give each surface its own view session,
  independent PTY size, and sole stdin ownership (`BoardModel.swift:697-701`,
  `TmuxAttach.swift:11-17`). That *is* the "phone-owned-input model" the task says to preserve, and it
  is the real reason the windows were separate.
- Therefore sharing one PTY across a phone and a desktop is fundamentally size-conflicted and is a
  non-goal. The agent terminal is the "continue on the other device" surface — it already has the
  ownership lease + takeover for exactly this. Shells are auxiliary per-surface scratch terminals.

The fix makes the **set** of shells consistent (both surfaces list every shell, open/close reconciles
live), without making the **PTY** shared.

## The fix

### 1. Broadcast (daemon)
- Add an ephemeral event `Event.shellsChanged(cardId: UUID, shells: [ShellTab])` — modelled on the
  existing `agentTerminalOwner` ephemeral event (NOT durable card state; `Task` is untouched). Reuses
  the existing `ShellTab { window, label, pwd }` payload.
- Emit it from `openShell`, `closeShell`, and `inspect` (`OrchestraService.swift`) *after* the tmux
  mutation, recomputing the list from `sessions.windows(name)` (tmux is authoritative — this also
  covers the idempotent phone-reconnect path and any drift).
- Owner is **derived, not stored**: a pure Kit helper `ShellOwner(window:)` → `.phone(clientId8)` for
  a `phone-*` name, else `.desktop`. No new daemon state, survives daemon restart.
- Connect-time reconcile keeps working via the existing `sessions` RPC in `refreshShellPanels` (events
  are live-only, so a mid-session connect still needs the one-shot pull) — no new reconcile RPC needed.

### 2. Consume (shared `OrchestraUI.BoardModel`)
- Handle `.shellsChanged` in `apply(_:)` (`BoardModel.swift:434`) → update `shellWindows` /
  `selectedShell` for that card via the existing `applyShellPanelState` path. This makes the set live
  for **every** surface (desktop↔desktop too, which is broken today).
- `refreshShellPanels` stays as the connect-time reconcile; it now agrees with the live event.

### 3. Render (both UIs) — list all, live-attach only your own
- **Desktop `ShellTabsView`** already renders `model.shellWindows`; it now live-updates and includes
  phone shells. Each tab is tagged with an owner glyph. The desktop live-attaches its own `shell-N`;
  a `phone-*` tab is **shown but not live-attached** (attaching would resize-fight the phone) —
  selecting it shows an "owned by phone" panel instead of an `AgentTerminalView`. This also fixes a
  latent bug: today a reconnect *can* pull a `phone-*` window into `shellWindows` and the desktop
  blindly attaches it, resize-fighting the phone.
- **Phone `TerminalTab` / `LiveShellView`** gains a shell ribbon (mirroring the desktop ribbon) that
  lists **all** shells. `+` opens a new phone-owned shell; tapping the phone's own shell attaches
  live; a desktop `shell-N` tab is listed with a badge but not live-attached (same reason). The block
  REPL stays the default mode.
- Either surface may **close** any shell (a legitimate reconcile action; `closeShell` already works by
  window name), and the `shellsChanged` emit propagates the close to the other surface.

## Non-goals (v1)
- Cross-surface **live** attach to another surface's PTY (needs a size/lease story like the agent
  terminal — deferred; visibility + reconcile is the task's minimum and directly fixes the report).
- Merging phone + desktop shells into one PTY.

## Testing
- **Kit unit tests:** `ShellOwner(window:)` derivation (`phone-abc123` → `.phone`, `shell-2` →
  `.desktop`, `agent` rejected); `shellsChanged` event Codable round-trip.
- **BoardModel test:** applying `.shellsChanged` mutates `shellWindows`/`selectedShell`; a close event
  drops the window and reselects a neighbour.
- **Isolated stack** (`scripts/iso-stack.sh up`): open a shell on the desktop → it appears in the
  phone's ribbon; open a shell on the phone → it appears in the desktop ribbon; close on one → gone on
  the other.
- **Typecheck:** `scripts/typecheck-ios.sh` + `swift test`.
