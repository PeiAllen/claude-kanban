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
| Global nav       | **Board · Needs You · Settings** (Needs You is a badged tab; Activity + Done are buttons on the Board nav) | Attention queue earns a permanent tab; Activity/Done are pushed screens within the Board tab |
| Freeform         | **4th page in the Board pager** (Plan · Impl · Review · Freeform)                | Freeform cards are *active* agents (Borrowed/Scratch/Read-only), so they belong in the active work surface, shown distinctly (folder path, mode chip, read-only lock) |
| Done             | **Archive button on the Board nav → pushed screen** (not a pager column)         | Mirrors the desktop's own call that Done is an archive, not a column                       |
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
- **Bottom tab bar:** Board · **Needs You** (badged with the attention count) · Settings.
- **Board nav bar:** title *Orchestra*; an **Activity** button (waveform), a **Done** button
  (archive), and a **+** (spawn). Activity and Done open pushed screens *within* the Board tab, so
  the tab bar stays put and each gets a `‹ Board` back button.
- **Dynamic Island** doubles as a live agent-status surface (e.g. *● 3 running · 2 done*).

### 2. Board tab (home)
- **Swipeable full-width pager:** Plan · Impl · Review · **Freeform**; segmented indicator with
  per-page counts up top.
- **Card** contents: title, `repo/branch` (mono), status pill, model, context-window mini-gauge,
  live diffstat `+N −M / k files`, current activity line.
- **Move a card:** tap-and-hold → swipe to an adjacent column, *and* a "Move to…" context-menu
  action (both, because a pure drag across a pager is fiddly).

### 2a. Freeform page (1st pager page — leftmost)
Agents running in an **existing directory**, outside the Plan → Review worktree flow. Cards show a
**mode chip** for the `CardOrigin` (**Borrowed · Scratch**), the **directory path** (mono) instead
of a `repo/branch → worktree` breadcrumb, and — where the card is read-only — a **separate
Read-only badge** (the `CardAccess` dimension, orthogonal to mode) with a "no writes" note. Scratch
cards note "auto-deletes." The pager order is **Freeform · Plan · Impl · Review**; Freeform is a peer
page but visually distinct so it doesn't read as part of the linear flow.

### 2b. Done (archive, via the Board nav Done button)
A pushed screen listing finished agents, each with **Reopen** (recreates the worktree + resumes).
Deliberately *not* a pager column — matching the desktop's decision that Done is an archive.

### 3. Card detail — tabbed full-screen
- Pushed from a card tap. **Pinned header:** title, status pill, model selector, context-window
  gauge, worktree breadcrumb (`repo/branch → path`), chat link.
- **Tabs:** **Agent · Terminal · Diff · Inbox · Info** — the desktop separates the agent session
  from the worktree shells, so these are two distinct views:
  - **Agent** — the live **agent session** (Claude/Codex conversation + tool calls), with a
    "Message the agent" steer bar. SSH PTY per phone-client.
  - **Terminal** — the worktree **shell(s)**: shell tabs + "＋", a raw command input, and a
    **key-accessory bar** (esc / ctrl / arrows / tab). Distinct from the agent's own session.
  - **Diff** — read-only; working/branch baseline toggle; file list → per-file diff.
  - **Inbox** — durable inbox editor: list / reorder / edit / append / remove (matches desktop).
  - **Info** — metadata; **Mode** (`CardOrigin`: worktree / borrowed / scratch) + **Access**
    (`CardAccess`: read-write / read-only); session id; **real app actions only** — Restart session,
    View changes in Zed, Reveal in Finder, Archive. (Hand off / Fork / Fan-out are *not* here —
    they were removed as app buttons; they're agent/CLI moves.)

### 4. Spawn (+) sheet
Modal: prompt field, backend (Claude Code / Codex), model, repo picker, branch (new/existing) →
**computed worktree path preview**, then **Card mode** (`CardOrigin`: **Worktree · Borrowed ·
Scratch** — three kinds) and a **separate Read-only toggle** (`CardAccess`, orthogonal to mode —
not a 4th mode). "Spawn agent" CTA. Mirrors desktop spawn.

### 5. Activity (via the Board nav Activity button)
The Live/CLI feed as a chronological list with a Live/CLI filter; tap an entry → its card. A pushed
screen within the Board tab (`‹ Board` back), not a tab of its own.

### 6. Needs You — attention queue (tab)
A **bottom-tab** destination listing **the cards that need human intervention**, badged with the
count. Card-centric, not a stream of toasts: each row is a card that is blocked on *you*, sorted
most-urgent-first.

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

1. Board — 4-page pager (Freeform · Plan · Impl · Review)
2. Freeform page — Borrowed / Scratch cards (+ Read-only badge) with folder paths + mode chips
3. Card detail — all 5 tabs (Agent, Terminal, Diff, Inbox, Info)
4. Spawn sheet
5. Needs You — attention queue (blocked / waiting / awaiting review / context-full), with inline reply, approve-&-move, snooze
6. Activity — Live/CLI feed (pushed from Board)
7. Settings
8. Done archive (pushed from Board)

## Risks / open points

- **Terminal on a phone** is the heaviest UX: the key-accessory bar and landscape are the mitigations
  in the prototype; real fidelity depends on SwiftTerm-iOS (phone-client L1).
- **Move-by-drag across a pager** — prototype shows both the swipe affordance and the menu fallback;
  validate which feels right when built.
- Prototype fidelity is visual/navigational, not a running client — data is representative mock state.
