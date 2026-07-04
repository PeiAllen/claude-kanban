---
project: claude-kanban
feature: mobile-orchestra
type: design-spec
status: approved
created: 2026-07-01
updated: 2026-07-03
links: ["[[../../../notes/designs/phone-client/index|phone-client]]", "[[2026-07-02-remote-daemon-connections-design|remote-daemon-connections]]", "[[../../../notes/designs/2026-07-03-configurable-notifications-design|configurable-notifications]]"]
---

# Mobile Orchestra — Design Spec

> **Sync with `main` (2026-07-03).** Several parts of this design that were speculative on 2026-07-01
> are now shipped on the desktop, so the mobile screens were updated to match the real thing:
> - **Connections are real.** The [remote-daemon connections](2026-07-02-remote-daemon-connections-design.md)
>   work landed a shared-core `Connection` model (`local` "This Mac" + remote Linux boxes over SSH),
>   a persisted `ConnectionStore` (list + active id), reconnect with an observable
>   `connectionState` (`connecting | live | retrying | down`), and an SSH-tunnel. The mobile
>   **Settings → Connection** pane is now that model, not a hand-wavy "Tailscale status" — the `Connection`
>   value was built in shared core *specifically* so the phone reuses it.
> - **Notifications, rethought.** Three attention triggers — **🔐 Permission · 🙋 Needs you · 💀 Died** —
>   each with a **scope dial** (Off / Background only / Always) and a **sound dial**. The daemon now
>   classifies the waiting reason (`permission` vs `humanTurn`) and **suppresses background-waits** (a card
>   awaiting a `run_in_background` / subagent / `/loop` stays *running*, not *waiting*). This reshapes both
>   the **Needs You** queue and a new **Settings → Notifications** section.
> - **Grant trust from Spawn.** Freeform spawn on an untrusted directory forces read-only and shows a
>   Trust / Keep-read-only notice (the `trustState` check). Spawn modes are labeled **Worktree · Freeform ·
>   Scratch** (matching the app).
> - **Diff baseline** is **Working · Branch · Parent** (Parent only for stacked cards); dead cards get a
>   **Recovery** view (why it died · preserved work · original prompt + Copy prompt · Start new / Resume /
>   Archive). **Moving a card** on the board now notifies its agent of the new column.
> - **Phone-native cleanups:** the "borrowed" `CardOrigin` is surfaced as **Freeform** everywhere (never
>   "borrowed"); host-only actions **View changes in Zed** and **Reveal in Finder** are dropped (a remote
>   phone isn't at the daemon host); and **Open Notes** becomes a new in-app **Notes page** that renders
>   the branch's changed/new `.md` files (no Obsidian on the phone).

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
  action (both, because a pure drag across a pager is fiddly). A user-initiated move **notifies the
  agent** — the daemon queues an inbox message telling the card which column it landed in (a self-move
  via CLI/MCP, or a no-op drop back into the same column, does not).

### 2a. Freeform page (1st pager page — leftmost)
Agents running in an **existing directory**, outside the Plan → Review worktree flow. Cards show a
**mode chip** labeled **Freeform** or **Scratch** (the user-facing labels the app's spawn sheet uses;
the underlying `CardOrigin` is `borrowed` / `scratch` — "borrowed" is never surfaced in the UI), the
**directory path** (mono) instead of a `repo/branch → worktree` breadcrumb, and — where the card is
read-only — a **separate Read-only badge** (the `CardAccess` dimension, orthogonal to mode) with a "no
writes" note. The pager order is **Freeform · Plan · Impl · Review**;
Freeform is a peer page but visually distinct so it doesn't read as part of the linear flow.

### 2b. Done (archive, via the Board nav Done button)
A pushed screen listing finished agents, each with **Reopen** (recreates the worktree + resumes).
Deliberately *not* a pager column — matching the desktop's decision that Done is an archive.

### 3. Card detail — tabbed full-screen
- Pushed from a card tap. **Pinned header:** title, status pill, model selector, context-window
  gauge, worktree breadcrumb (`repo/branch → path`), chat link.
- **Tabs:** **Agent · Terminal · Diff · Inbox · Info** — the desktop separates the agent session
  from the worktree shells, so these are two distinct views. Their phone behavior follows the
  [phone agent & terminal UX design](../../../notes/designs/2026-07-03-phone-agent-terminal-ux-design.md),
  which resolves two problems the earlier spec left open — *a raw tmux isn't phone-native*, and
  *desktop + phone attaching the same tmux window fights over its one size*. The answer is a
  three-tier model (**Agent is primary; Terminal is a secondary escape hatch**):
  - **Agent** (primary, ~90% of phone use) — a **non-attaching** read/steer surface, **not** a live
    PTY: a capture/structured render of the session (capture text in v1 → conversation/tool-call
    timeline later) + a "Message the agent" steer bar (discrete `send`/`send-keys`, no attach).
    Gates surface as **Needs You** (Approve/Deny), never TUI keystrokes. An explicit
    **Take Over Agent Terminal** button is the *only* path that attaches the real TUI — see Takeover.
  - **Terminal** (secondary escape hatch) — a **block REPL** by default: a "Run a command…" field →
    one-shot `exec` in the worktree → a **copyable output block** (no PTY, no tmux, no sizing
    concern). An opt-in **Attach live shell** enters a live PTY in a **phone-owned** `shell` window
    (per-window sizes are independent, so the desktop's windows are untouched). No shell tabs / full
    key bar in the default view.
  - **Takeover** (live, full-screen) — the reinterpreted live terminal, reached from Agent's
    *Take Over* (or Terminal's *Attach live shell*). It's the sole surface that attaches a real TUI,
    under a **daemon-authoritative ownership lease**: the phone attaches only after the desktop
    unmounts its terminal (a "Taken over by phone" placeholder with *Retake*), so the one shared
    window's reflow is intentional, not accidental. UI: a compact owner bar (title/status,
    connection, *You have control*, **Return to Desktop**), **armed input** ("Start typing" — nothing
    sends until tapped), a **minimal key-accessory bar** (Esc · sticky Ctrl · Tab · ↵ · ↑ · ↓ · ⋯),
    an explicit **Select** mode, font A−/A+, and landscape as the "real terminal" posture.
  - **Diff** — read-only; a three-way baseline toggle **Working · Branch · Parent** (Working vs
    `HEAD`, Branch vs the default-branch merge-base = default, Parent only shown for **stacked cards**
    that carry a `parentBranch`); file list → per-file diff; difftastic-rendered.
  - **Inbox** — durable inbox editor: list / reorder / edit / append / remove (matches desktop).
  - **Info** — metadata; **Mode** (`CardOrigin`: worktree / borrowed / scratch) + **Access**
    (`CardAccess`: read-write / read-only); session id; **phone-native actions only** — Restart
    session, **Open notes** (→ the Notes page below), Copy branch name, Archive (with a confirm).
    **No "View changes in Zed" or "Reveal in Finder"** — those act on the daemon *host's* local
    filesystem, which a remote phone client isn't sitting at, so they're dropped; viewing changes is
    the in-app **Diff** tab instead. (Hand off / Fork / Fan-out are also not here — they're agent/CLI
    moves.)

- **Notes page.** A pushed, full-screen page (from the card's **Open notes** action / `•••` menu)
  that **renders the markdown notes this branch changed** — the phone-native equivalent of the
  desktop's Open Notes (which opens the worktree's changed/new `notes/*.md` as Obsidian tabs; there's
  no Obsidian on the phone, so it renders in-app). A **file switcher** lists the changed/new `.md`
  files with an `M`/`A` (modified/added) badge each; the selected file renders as styled markdown
  (headings, lists, inline code, fenced code blocks, blockquotes). Sourced from the same "notes this
  branch touched" set the desktop's [changed-notes feature](../../11-doc-automation.md) computes.

- **Dead card → Recovery view.** A `dead` card replaces the agent chrome with a recovery panel
  (mirrors the desktop `RecoveryView`): **why it ended** (per `DeadReason`), the **preserved work**
  (repo/branch/path with View changes · Reveal in Finder · Copy path), the **original prompt** under
  "Originally asked" with a **Copy prompt** affordance (grabs `task.initialPrompt` verbatim — survives
  a dead card), and the actions **Start new session** · **Try resume** (when a session id exists) ·
  **Archive**.

### 4. Spawn (+) sheet
Modal: prompt field, backend (Claude Code / Codex), model, then **Card mode** — a three-way chip
**Worktree · Freeform · Scratch** (the app's labels; `CardOrigin` = worktree / borrowed / scratch)
plus a **separate Read-only toggle** (`CardAccess`, orthogonal to mode — not a 4th mode).

- **Worktree** — repo picker, branch (new/existing) → **computed worktree path preview**.
- **Freeform** — a **directory picker**. On every directory change the sheet checks `trustState`;
  when the chosen dir is **untrusted** it shows an amber **"Directory not trusted"** notice
  (**Trust & allow writes** / **Keep read-only**) and **forces the Read-only toggle on** — so an
  agent can't get write access to a dir no human has granted. Granting trust is a human-only act,
  now doable **right from the sheet** (mirrors the desktop `SpawnSheet` PR D3). The CTA reads
  **"Spawn read-only agent"** while forced read-only.
- **Scratch** — informational (Orchestra makes and later `rm -rf`s the dir).

"Spawn agent" CTA. Mirrors desktop spawn.

### 5. Activity (via the Board nav Activity button)
The Live/CLI feed as a chronological list with a Live/CLI filter; tap an entry → its card. A pushed
screen within the Board tab (`‹ Board` back), not a tab of its own.

### 6. Needs You — attention queue (tab)
A **bottom-tab** destination listing **the cards that need human intervention**, badged with the
count. Card-centric, not a stream of toasts: each row is a card that is blocked on *you*, sorted
most-urgent-first.

- **Reasons surfaced per row**, aligned to the daemon's real attention events (the same signals that
  drive notifications): **🔐 Permission** (`waitReason == .permission` — blocked on tool approval),
  **🙋 Needs you** (`waitReason == .humanTurn` — genuinely done and waiting), **💀 Died**
  (`status → .dead`), and the derived **◔ Context near-full** (`ctxPct`). No fabricated "blocked/error"
  bucket — the row reason is whatever the card's `waitReason` / status actually is.
- **Background-waits are excluded.** A card paused on a background task (`run_in_background` shell,
  subagent, `/loop` wake — non-empty `background_tasks` / `session_crons`) stays **running**, not
  waiting, so it never appears here — it auto-resumes and isn't waiting on you. The queue notes this so
  its emptiness reads as "genuinely nothing," not "the signal is broken."
- **Row content:** card title, `repo/branch` (mono), the reason chip, status pill, how long it's
  been waiting, and the last activity line.
- **Inline actions** matched to the reason: a **Permission** row gets **Approve / Deny**; a
  **Needs you** row gets a quick **reply/steer** field; a **Died** row deep-links to the **Recovery**
  view; plus **open card** and **snooze/dismiss** throughout.
- **Empty state:** "All caught up — no agents need you." Grouped by reason when the list is long.
- Backed by the same attention events that drive **push** (APNs delivery is a backend follow-on);
  this in-app queue is what push notifications deep-link into.

### 7. Settings tab
Grouped inset lists, now grounded in the shipped `Connection` model and notification system:

- **Connection status banner** — reflects `BoardModel.connectionState` verbatim
  (`connecting | live | retrying | down` → *Connecting… / Connected / Reconnecting… / Disconnected*),
  with a Disconnect action; never fabricate data when offline.
- **Connection** — the `ConnectionStore` list: which daemon the board talks to. A built-in
  **This Mac** (local UDS + local tmux) plus saved **remote Linux boxes** (`sshTarget`, remote socket
  path, remote tmux socket). Each row has an **active radio** (switch the active connection), and
  remotes get **Edit**; an **Add remote…** row opens the connection editor. This is the *same* model
  the phone reuses — the phone is just another client picking a daemon over the SSH-forwarded socket.
- **Notifications** — three rows, one per attention trigger: **🔐 Permission needed** · **🙋 Needs
  you** · **💀 Card died**. Each carries a **scope dial** (Off / Background only / Always) and a
  **sound dial**. A helper line notes background-only alerts stay quiet while the app is open, and that
  agents on background tasks never alert.
- **Appearance** (theme light/dark/system, accent) and **About** (app + daemon version).

## Prototype build scope

Screens to build in the Claude Design project, light + dark, interactive where the medium allows
(tab switches, pager, sheet present/dismiss):

1. Board — 4-page pager (Freeform · Plan · Impl · Review)
2. Freeform page — Borrowed / Scratch cards (+ Read-only badge) with folder paths + mode chips
3. Card detail — all 5 tabs (Agent [non-attaching read/steer + Take Over], Terminal [block REPL + Attach live shell], Diff [Working · Branch · Parent], Inbox, Info)
3a. Notes — pushed page rendering the branch's changed/new `.md` files (file switcher + rendered markdown)
3b. Takeover — full-screen live terminal (owner bar, armed input, minimal key bar, Select mode, landscape)
4. Recovery — dead-card panel (why · preserved work · Copy prompt · Start new / Resume / Archive)
5. Spawn sheet — Worktree mode, **and** a Freeform-mode variant showing the untrusted-directory trust flow
6. Needs You — attention queue (🔐 Permission / 🙋 Needs you / 💀 Died / ◔ Context-full), with Approve-Deny, inline reply, snooze
7. Activity — Live/CLI feed (pushed from Board)
8. Settings — Connection (ConnectionStore list + status) · Notifications (3 triggers) · Appearance · About
9. Done archive (pushed from Board)

## Risks / open points

- **Terminal on a phone** is the heaviest UX: the key-accessory bar and landscape are the mitigations
  in the prototype; real fidelity depends on SwiftTerm-iOS (phone-client L1).
- **Move-by-drag across a pager** — prototype shows both the swipe affordance and the menu fallback;
  validate which feels right when built.
- Prototype fidelity is visual/navigational, not a running client — data is representative mock state.
