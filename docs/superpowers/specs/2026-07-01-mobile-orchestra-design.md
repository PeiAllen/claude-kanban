---
project: claude-kanban
feature: mobile-orchestra
type: design-spec
status: approved
created: 2026-07-01
links: ["[[../../../notes/designs/phone-client/index|phone-client]]"]
---

# Mobile Orchestra — Design Spec

> A high-fidelity iPhone app design for Orchestra, delivered as an interactive prototype on
> Claude Design. This is the **UI** the existing [[phone-client]] design deliberately deferred —
> that work landed the *plumbing* (Transport abstraction, `ControlClient` reconnect, SSH-PTY
> terminals) and explicitly scoped the app UI as a follow-on. This spec is that follow-on.

## Purpose & scope

**Purpose.** Give Allen **full control parity** with the desktop Orchestra app from his phone: view
the board, spawn agents with full options, watch live terminals, review diffs, edit the inbox, and
steer agents — reaching the unchanged daemon over the SSH-forwarded-UDS / Tailscale transport the
phone-client design already specced.

**This deliverable.** An interactive **iPhone prototype on Claude Design** (`.dc.html` Design
Component, sibling in spirit to the existing desktop Orchestra prototype), ~390×844 viewport, in
**light + dark**. Not production Swift code — a visual, navigable design.

**Non-goals.** The Swift/iOS build itself; APNs push plumbing (in-app notifications center is
designed, delivery is a backend follow-on); offline mode (thin remote client, per phone-client);
re-designing the daemon or control plane.

## Design decisions (resolved during brainstorming)

| Decision         | Choice                                                                          | Why                                                                                       |
| ---------------- | ------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| App ambition     | **Full control parity**                                                         | Everything desktop does, on a phone; terminal-on-phone is the hard, interesting part      |
| Board layout     | **Swipeable full-width column pager**                                           | Closest to the desktop board feel; preserves Plan·Impl·Review mental model                |
| Card detail      | **Tabbed full-screen**                                                          | Terminal gets the whole screen when selected; dense inspector splits cleanly into tabs    |
| Aesthetic        | **iOS-native reinterpretation**                                                 | Native nav/tab bars, materials/blur, haptics feel; keeps Orchestra palette + mono accents |
| Global nav       | **Board · Activity · Settings** (bell/badge for notifications on Board nav bar) | Three tabs; notifications prominent but not a full tab                                    |
| Prototype target | **New Claude Design project** ("Orchestra Mobile")                              | Keeps mobile separate from the desktop prototype project                                  |

## Visual language

iOS-native reinterpretation that stays unmistakably Orchestra:

- **Native chrome:** nav bar (large-title where it fits), bottom tab bar, materials/blur, safe-area
  insets, grouped inset lists for Settings/Info, iOS-style sheets and context menus.
- **Orchestra DNA:** mono type for `repo/branch`, worktree paths, and session ids; hairline card
  borders; the status-pill color language (waiting · running · done); a toned-down radial accent;
  full **light + dark**.
- Bigger tap targets and native gestures throughout; landscape support for the terminal.

## Screens

### 1. Global structure
- **Bottom tab bar:** Board · Activity · Settings.
- **Board nav bar:** title *Orchestra · Personal*; a **bell** (badged notifications center) and a
  **+** (spawn); a **Done/archive** entry point.

### 2. Board tab (home)
- **Swipeable full-width column pager:** Plan · Impl · Review; segmented indicator with per-column
  counts up top.
- **Card** contents: title, `repo/branch` (mono), status pill, model, context-window mini-gauge,
  live diffstat `+N −M / k files`, current activity line.
- **Move a card:** tap-and-hold → swipe to an adjacent column, *and* a "Move to…" context-menu
  action (both, because a pure drag across a pager is fiddly).
- **Done archive:** pushed screen listing Done cards, each with **Reopen**.

### 3. Card detail — tabbed full-screen
- Pushed from a card tap. **Pinned header:** title, status pill, model selector, context-window
  gauge, worktree breadcrumb (`repo/branch → path`), chat link.
- **Tabs:**
  - **Terminal** — full-width live terminal (SSH PTY per phone-client), a **key-accessory bar**
    above the keyboard (esc / arrows / ctrl / tab), landscape support.
  - **Diff** — read-only; working/branch baseline toggle; file list → per-file diff.
  - **Inbox** — durable inbox editor: list / reorder / edit / append / remove (matches desktop).
  - **Info** — full metadata; card mode (worktree / borrowed / scratch / read-only); session id;
    actions (archive, restart, reopen, handoff/fork).
- **Persistent steer bar** at the bottom: send a prompt into the agent without opening Terminal.

### 4. Spawn (+) sheet
Modal: prompt field, backend (Claude Code / Codex), model, repo picker, branch (new/existing) →
**computed worktree path preview**, card mode. "Spawn" CTA. Mirrors desktop spawn.

### 5. Activity tab
The Live/CLI feed as a chronological list with a Live/CLI filter; tap an entry → its card.

### 6. Needs You — attention queue (bell)
A dedicated screen listing **the cards that need human intervention**, opened from the Board nav
bar's **bell** (badged with the count). Card-centric, not a stream of toasts: each row is a card
that is blocked on *you*, sorted most-urgent-first.

- **Reasons surfaced per row** (the "why you're needed"): *waiting for input · blocked / error ·
  awaiting review approval · context near-full · needs a decision (permission/plan gate)*.
- **Row content:** card title, `repo/branch` (mono), the reason chip, status pill, how long it's
  been waiting, and the last activity line.
- **Inline actions** so you can clear the queue without leaving it: a quick **reply/steer** field,
  **approve & move** (e.g. Review → Done), **open card** (→ full detail), **snooze/dismiss**.
- **Empty state:** "All caught up — no agents need you." Grouped by reason when the list is long.
- Backed by the same attention events that drive **push** (APNs delivery is a backend follow-on);
  this in-app queue is what push notifications deep-link into.

### 7. Settings tab
Grouped inset lists: Connection (Tailscale/SSH status, add device/key, host), Theme
(light/dark/system), Devices, About. A **connecting / offline / online** banner reflects the
reconnect state; never fabricate data when offline.

## Prototype build scope

Screens to build in the Claude Design project, light + dark, interactive where the medium allows
(tab switches, pager, sheet present/dismiss):

1. Board — 3-column pager
2. Card detail — all 4 tabs (Terminal, Diff, Inbox, Info)
3. Spawn sheet
4. Activity
5. Needs You — attention queue (blocked / waiting / awaiting review / context-full), with inline reply, approve-&-move, snooze
6. Settings
7. Done archive

## Risks / open points

- **Terminal on a phone** is the heaviest UX: the key-accessory bar and landscape are the mitigations
  in the prototype; real fidelity depends on SwiftTerm-iOS (phone-client L1).
- **Move-by-drag across a pager** — prototype shows both the swipe affordance and the menu fallback;
  validate which feels right when built.
- Prototype fidelity is visual/navigational, not a running client — data is representative mock state.
