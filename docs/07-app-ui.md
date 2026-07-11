# 7. App UI

The SwiftUI app (under `App/`) is one of the three clients onto the daemon — the visual one. It renders
the board reactively from the daemon's event stream and embeds live terminals via SwiftTerm. This
chapter tours its surfaces. The app's visual language matches the **Orchestra** prototype on Claude
Design (light/linear: radial wallpaper, hairline borders, mono accents).

> The app is built separately from the package (it needs full Xcode + SwiftTerm); see
> [Building & operations](08-building-operations.md). The backend builds and tests without it.

## The board

`BoardView` lays out **three equal-width columns** — Plan · Implementation · Review — each scrolling its
own cards (the board itself doesn't scroll), with a minimum column width of ~210 pt. Each column header
shows its label, a count chip, and a **+** button to spawn a card directly into that column; an empty
column shows a "No agents here" placeholder.

**Drag-and-drop** moves cards between columns: a card is `.draggable` by its UUID, columns are
`.dropDestination`s that highlight when targeted, and a drop calls `move(id, to:)`.

Batch fan-out — spawning **many** cards at once (one card per prompt line, each on a suffixed
`<branch>-<n>`) — is reachable from the CLI and MCP over the
[`batch-spawn`](05-command-reference.md#registry-commands) command. There is **no board Fan-out button**:
it was removed (along with the per-card Handoff and Fork buttons) so batch-spawn stays an agent/CLI move
and the board chrome stays minimal (see
[chapter 9](09-design-decisions.md#shipped-feature-history)).

### The freeform region

Below the columns sits the **Freeform region** — a full-width, collapsible, resizable **dock** for
non-worktree cards (`.borrowed` / `.scratch`), which live outside the Plan/Impl/Review workflow. Cards
wrap in an adaptive grid (270–360 pt columns) that reflows with the window. Its ribbon header doubles as
a drag handle (drag up to grow), and its height persists across launches. It lives *inside* the board
view so the inspector overlay renders on top of it.

## Cards

`CardView` shows, top to bottom: a **status pill**, the **title** (up to 2 lines), an optional
**description** (the live agent blurb), and a footer.

- The **status pill** shows the status and a live age for `running`/`waiting` cards (a `TimelineView`
  ticking every second, e.g. "Running · 3m"), with a **breathing dot** for active statuses. Running
  cards also get a 2 px **shimmer bar** sweeping across the top.
- The **footer** carries the repo · branch (worktree cards) or borrowed dir name (freeform), a
  read-only **eye badge** for `.readOnly` cards, and — for a git card the daemon has diffed — a **branch
  diffstat** (`Nf +N −M`, green insertions / red deletions; axis 7), falling back to the model name when
  there is no stat (non-git / zero-change / not-yet-computed).
- **Selection** draws an accent border + green shadow; waiting cards get an amber hairline; dead cards
  dim to 72% opacity. Tapping a card selects it and opens the inspector. During a `/` search, cards that
  don't match dim to 32%; during `f` [link-hint mode](#keyboard-navigation) each card wears a home-row
  label badge.

Colors come from the theme's **semantic palette** — green (running), amber (waiting), gray (done), red
(dead) — used consistently for dots, text, and tints.

## The spawn sheet

`SpawnSheet` is the modal that creates a card. It has **three modes** (a chip toggle): **Worktree**,
**Freeform**, **Scratch**.

- **Initial prompt** — an optional multiline field; if non-empty it becomes the card title, otherwise
  the card spawns nameless and the first prompt names it.
- **Worktree mode** — a **repository** combo box (fuzzy-searchable, populated by scanning `reposRoot`
  for `.git` dirs), a **branch** combo box (existing branches sorted by recency, or type a new name to
  create one), a read-only **worktree path preview**, and a **Start-in** segmented control (Plan /
  Implementation).
- **Freeform mode** — an `NSOpenPanel` directory picker plus a **read-only** toggle. On every directory
  change the sheet queries the [`trustState`](05-command-reference.md#registry-commands) command (PR D3);
  when the chosen dir is **untrusted** it **forces the read-only toggle on and shows an amber notice**
  (trust · read-only · cancel) — so an agent can't be spawned with write access into a dir no human has
  granted. Granting stays the human-only [`trust`](05-command-reference.md#registry-commands) act.
- **Scratch mode** — just informational text (Orchestra makes and later `rm -rf`s the dir).
- **Agent selector** — a segmented control (**Claude Code** / **Codex**, each an adapter's icon + name)
  that appears only when the daemon's [`agents`](05-command-reference.md#server-only-built-in-methods) RPC
  returns more than one wired-up adapter. Picking an agent **re-scopes the Model selector** below it to
  that agent's catalog and resets the model to the agent's default (the configured default when it belongs
  to this agent, else its first model). Defaults to `config.defaultAgentId`. This is what makes Codex
  startable from the app — see [Agent adapters](04-cards-worktrees-sessions.md#agent-adapters).
- **Model selector** — a button row of the *selected agent's* `AgentModel`s, brand-colored (claude → burnt
  orange, gpt → teal, gemini → blue).
- **CLI preview** — a live display of the equivalent `orchestra spawn …` command, reinforcing that the
  GUI and CLI are the same surface. It gains `--agent <id>` only when a **non-default** agent is picked,
  keeping the common Claude preview clean.

Spawning shows a toast on success or failure and closes the sheet on success.

## The inspector

Selecting a card opens the **inspector**, a resizable right-hand sidebar (default 392 pt, width
persisted; drag the left edge to resize). A **live** card shows the agent chrome; a **dead** card shows
the [Recovery panel](#recovery-panel) instead.

The **header bar** leads with an **Agent | Diff** segmented toggle (axis 7) that swaps the inspector body
between the agent terminal and the read-only in-app [Diff view](#the-in-app-diff-view), then has
**View changes** (opens the worktree in Zed with a branch-vs-base diff), **Open notes**
(`note.text`), an **Inbox** editor, **Archive** (non-dead cards only), and a **close** (X).
**Open notes** opens the project's `notes/` folder as an **Obsidian vault** — the same
`~/.claude/open-obsidian-vault.sh` recipe as the `/open-notes` command, wired through the
[`openNotes` verb](05-command-reference.md#server-only-built-in-methods) on the existing `openInZed`
plumbing. It deliberately targets the *canonical* project vault (`Task.repo/notes`), not the per-card
worktree copy, so notes don't fragment across worktrees. It is also bound to the bare
[`o` keyboard shortcut](#keyboard-navigation) on the selected card. The per-card **Inbox** button
(`tray.full`, hidden for a `dead` card) is now the sole live-delivery card action — the earlier
Send/Handoff/Fork buttons were removed in favor of it plus the natural-language → MCP delegation path
(see [chapter 9](09-design-decisions.md#shipped-feature-history)):

- **Inbox** — opens a popover editor over the card's durable [inbox](03-data-model.md#the-inbox-store-f3)
  (F3). It lists the queued messages (header `Inbox — N queued`), and per row lets you **reorder** (up/down
  chevrons → `inbox-reorder`), **edit** the text inline (tap → commit → `inbox-edit`), and **delete**
  (→ `inbox-remove`), with an **append** field at the bottom (→ `send`). Every op round-trips to the daemon
  over the [`inbox*` commands](05-command-reference.md#registry-commands) and reloads; the list loads fresh
  each time the popover opens. Messages are delivered at the agent's next turn-end.

**Handoff**, **Fork**, and board **Fan-out** are no longer buttons — those moves are driven by talking to
the agent (which calls the `handoff` / `spawn` / `batch-spawn` MCP tools), where an exploratory fork now
defaults to a lightweight read-only freeform card in the same directory
(`Sources/OrchestraCore/Resources/delegation-{skill,agents}.md`). This is the *agent-buttons
simplification* — see [chapter 9](09-design-decisions.md#shipped-feature-history) and its
[design note](../notes/designs/2026-07-01-agent-buttons-simplification-design.md).

### The in-app diff view

With the header's **Diff** mode selected, the body switches from the agent terminal to `DiffInspectorView`
(axis 7 — code review on the board): a **read-only**, colored, monospaced render of the card's changes, so
a quick review doesn't need "View changes → Zed". It has a **baseline toggle** — **Working** (vs `HEAD`) ·
**Branch** (vs the default-branch merge-base, the default) · **Parent** (shown only once the card carries a
`parentBranch`, for stacked cards) — and reloads on card selection and on baseline change. The diff text is
fetched from the daemon's app-only [`diffText`](05-command-reference.md#server-only-built-in-methods)
endpoint (difftastic-rendered when `difft` is installed, git's colored diff otherwise) and drawn by a small
SGR→`AttributedString` parser (`ANSIText`) in a selectable scroll view; an **Open in Zed** button opens the
full changes, and a huge diff is capped daemon-side. A non-git (`.scratch`/`.borrowed`) or zero-change card
shows an empty state rather than a fabricated diff. Editing stays Zed's job (an explicit non-goal).

The **agent chrome** stacks, top to bottom:

1. a **context bar** — a 2 px fill showing `ctxPct`, green→amber→red;
2. a **terminal header** of chips — model (colored dot), repo/borrowed dir, the read-only eye badge, the
   status pill, and an **Inspect** button (opens a read-only shell agent in the worktree);
3. a **breadcrumb strip** — "Copy chat link" (the `orchestra://` URI), "Copy tmux target", and a
   clickable path breadcrumb;
4. the **agent terminal** (SwiftTerm);
5. a **shell panel** — either the shell tabs, or a "New terminal" button when none are open.

## Terminals and shell tabs

`AgentTerminalView` is an `NSViewRepresentable` wrapping SwiftTerm that **attaches to tmux directly**
(no daemon byte-proxying). It prefers a Nerd Font (for powerline/git glyphs), applies the app theme to
SwiftTerm's colors (including OSC 10/11 so TUIs like Claude Code detect the theme), forces a UTF-8
locale and `TERM=xterm-256color`, and attaches via the grouped **view session** so opening a shell
never yanks the agent terminal. Mouse-wheel scrolling is forwarded to tmux on the alternate screen and
falls back to SwiftTerm's native scrollback otherwise.

The terminal's child process is chosen by a **`TerminalHost`**: `.local` runs `tmux -L <socket> attach`
directly, while `.remote(controlPath, sshTarget)` — used when the active connection is a remote box —
`ssh`es into the box's tmux over the *shared* SSH control socket (`ssh -S <ctrl> -tt … tmux -L <remote
socket> attach`), so it rides the same multiplexed master the JSON-RPC transport uses and re-authenticates
nowhere.

`ShellTabsView` is the ribbon of `shell-N` tabs (each re-keyed to its own tmux window), with **+** to
open a new shell and a chevron to collapse. The shell panel height is drag-resizable (the ribbon is the
handle) and persisted.

**Cross-surface shell set.** A card's shell windows live in one shared tmux session, so the desktop and
the phone show the **same set** of shells. The daemon broadcasts the window set (`Event.shellsChanged`,
emitted by `openShell`/`closeShell`/`inspect`), and `BoardModel` reconciles it live into `shellWindows`
— a shell opened on one surface appears on the other. Windows stay **per-owner** (the desktop's
anonymous `shell-N` vs a phone's deterministic `phone-<client>`): each surface attaches its own grouped
view session, so PTY sizes stay independent and the two never fight one shell's stdin. Owner is derived
from the window name (`ShellOwner`); a surface live-attaches only the shells it owns and shows a
foreign shell (the other surface's) as a listed, owner-tagged tab it can see and close but not drive.

## Keyboard navigation

The board is **fully keyboard-navigable** with a vim-flavored scheme built for a vim user — bare-key
selection, spatial pane focus, `g`-go-to sequences, single-key verbs, `/` search, `f` link-hints, a `:`
command palette, and standard `⌘` accelerators — designed so it never fights the live agent terminals the
inspector embeds. The full rationale (the
precedent survey and the "focus *is* the mode" model that resolves the terminal-vs-navigation key
collision) is in the
[design note](../notes/designs/2026-07-02-keyboard-shortcuts-vim-navigation-design.md); the build is the
[implementation plan](../notes/plans/2026-07-02-keyboard-shortcuts.md).

**Focus is the mode.** There is no global NORMAL/INSERT toggle to track — the active **context** is
derived on every keystroke from the window's first responder + model state, one of four: **Board** (a card
has focus — bare keys navigate and act), **Terminal** (a SwiftTerm view has focus — everything reaches the
agent/shell untouched), **Field** (a text input has focus — you type; only `⌃j`/`⌃k` move a form/dropdown),
and **Overlay** (a sheet/popover is up — `Esc` closes it). A small **context chip** in the toolbar
(`ContextChip`: `BOARD` / `INSPECTOR` / `TERMINAL` / `SHELL`, with an amber dot when a terminal owns the
keyboard) answers "am I about to type into the agent?" at a glance.

**Architecture.** The decision logic is **pure and unit-tested** in `OrchestraCore/Keyboard/`:
`KeyChord` / `KeyContext` / `KeyIntent` value types, `KeyMap.intent(for:in:awaitingGoTo:)` (the chord →
intent dispatch table), and `BoardNavigator` (selection movement over `[Task]`, e.g. `left`/`right` to the
same-row card in the adjacent column). The app installs **one** `NSEvent` keyDown local monitor —
`KeyboardController` (mirroring the shared scroll monitor in `AgentTerminalView`) — which derives the
context, builds a `KeyChord`, asks `KeyMap`, and executes the resulting `KeyIntent` against `BoardModel`
(the model gains `focusZone`, `inspectorMode`, `searchQuery`, `showHelp`, `requestInboxOpen`,
`showPalette`/`paletteQuery`/`paletteIndex`, and `hintActive`/`hintLabels` state plus
`selectMove`/`carrySelected`/`goTo`/`closeFrontmost`, the `searchMatchIds` filter, `resizeFocusedPane`,
`toggleCollapseFocused`, and the palette/hint helpers). A consumed key is swallowed (the monitor
returns `nil`); everything else passes through to SwiftTerm / fields / SwiftUI untouched. `FocusBridge`
performs the AppKit first-responder moves (including agent↔shell and shell-tab hops, keyed off each
terminal's `termWindow` tag), and the `g`-go-to and `y`-yank prefixes are small pending-state
machines in the controller (kept out of the pure `KeyMap`).

The pure logic is unit-tested (`swift test`), but the App-side wiring — the `NSEvent` monitor, focus
moves, and overlays — isn't a SwiftPM target, so it's verified **end-to-end** by
[`scripts/orch-key-demo.sh`](08-building-operations.md#development-scripts): it launches an isolated
instance seeded with a mock multi-card board (`ORCH_SHOW=demo`, no daemon) and posts **real synthetic
keystrokes** straight to its PID (`CGEvent.postToPid`, never foregrounding it), screenshotting each step —
so `hjkl` selection, `g`-go-to, `f` link-hints, the `:` palette, `/` search, and `?` help are all proven
to fire from actual key events, not just from the unit tests.

The shipped bindings:

| Keys | Action |
|---|---|
| `h` `j` `k` `l` | Move the **selection** within the focused pane (columns ↔, cards ↕) — which opens the inspector for that card and auto-scrolls the column to keep it centered (a `ScrollViewReader` in `BoardView`) |
| `g g` / `G` | First / last card in the column |
| `⌃o` / `⌃i` | Previous / next visited card (browser-style history); works from the board or a terminal and preserves that mode |
| `Enter` | Move keyboard focus **into** the inspector (the selection already opened it) |
| `i` | **Insert** — jump focus straight into the agent terminal to type |
| `Esc` | Close / clear the frontmost thing |
| `⌃h` `⌃j` `⌃k` `⌃l` | Move **focus between panes**, spatially and **edge-aware** — `⌃l` board → agent terminal, `⌃h` terminal → board (the eject), `⌃j` columns → freeform dock; a direction with **no neighbor passes straight through** to the pty (so `⌃l` in a terminal stays clear-screen, and `⌃h` is the only control key a focused terminal gives up) |
| `⌃j` `⌃k` / `⌃h` `⌃l` *(in the inspector)* | **Inside the inspector:** `⌃j`/`⌃k` swap the **agent terminal ↔ shell panel**; on a focused shell, `⌃h`/`⌃l` **switch shell tabs** (edge-aware — `⌃h` on the first tab ejects to the board) |
| `g` then `p`/`i`/`r`/`f`/`a`/`d`/`s` | Go to Plan / Implementation / Review / Freeform / Activity / Done / Settings |
| `c` | New card (opens the spawn sheet) |
| `H` / `L` | **Carry** the selected card one column left / right (shift = grab the card) |
| `a` · `o` · `O` · `d` · `I` · `t` | Archive · open the card's **notes** (Obsidian vault) · View changes in Zed · toggle Agent/Diff view · open the inbox editor · new shell tab |
| `y c` / `y t` / `y p` | Copy chat link / tmux target / cwd path |
| `/` · `n` / `N` | **Search / filter cards** — opens the `SearchBar` (matches title / branch / repo); typing dims non-matches and jumps to the first hit, `Enter` commits back to the board where `n`/`N` cycle matches, `Esc` clears |
| `f` | **Link-hints** — overlay a short home-row label on every visible card; type the label to jump to it (`Esc` aborts) |
| `:` | **Command palette** (`CommandPalette`) — a fuzzy list of every board action with its shortcut shown inline (so it teaches the keymap); `⌃j`/`⌃k` move the highlight, `Enter` runs, `Esc` closes |
| `⌃⇧h` `⌃⇧j` `⌃⇧k` `⌃⇧l` | **Resize the focused pane's edge** — inspector width (`⌃⇧h`/`⌃⇧l`), freeform-dock / shell-panel height (`⌃⇧k`/`⌃⇧j`); writes the same `@AppStorage` the drag handles use |
| `z` | **Collapse / expand** the focused collapsible region (shell panel when a terminal is focused, else the freeform dock) |
| `?` | Help overlay — `KeyboardHelpView`, a reference card grouped by surface (Navigate / Go to & find / Act / Panes & layout / Standard) |
| `⌘N` / `⌘T` / `⌘W` | New card / new shell / close-frontmost — the standard macOS accelerators (also on the menu bar via the scene's `.commands`). Because terminals ignore `⌘` these work **even while a terminal is focused**; `⌘W` peels the most-transient thing first (open modal → focused shell tab → inspector → otherwise **archive the selected card**), mirroring the progressive `Esc` |

The verbs act on the **selected** card, so `a`/`o`/`O`/`d`/`I` archive, open its notes, view its changes,
toggle, or edit the inbox of the card you've navigated to. (`o` → notes and `O` → Zed were swapped from the
first cut once `n`/`N` were claimed by search — see [design note](../notes/designs/2026-07-02-keyboard-shortcuts-vim-navigation-design.md).) Beyond `?`, the search bar, command palette, and help overlay all count as an
`Overlay` context (so `Esc` / click-away closes them through `BoardModel.closeFrontmost()`); the `f` hint
overlay is a transient capture handled directly by the controller.

The follow-up batch (merge `d16e3dc`) filled in everything the first core-nav slice deferred: `/` search
+ `n`/`N`, shell-tab switching + agent↔shell focus, combo-box `⌃j`/`⌃k` in the spawn sheet, `⌃⇧hjkl`
resize + `z` collapse, `f` link-hints, and the `:` command palette.

**Still deferred (intentionally** — see the plan's *Deferred* list and the design's Phase 2): `x`
multi-select (extend the selection with `⇧J`/`⇧K`, then a verb acts on the whole set) and the which-key
popup after a paused `g` / `:`. User-remappable bindings remain an open question for a later pass.

## Onboarding, settings, recovery, and popovers

- **Onboarding** (`OnboardingView`) — shown on first run when the daemon isn't installed: a welcome
  screen with an "Install & Start" button (which installs the LaunchAgent and connects) and "Quit".
  Once installed, the app marks itself onboarded and never shows it again; a returning user whose daemon
  is down sees an offline banner offering a one-click restart instead.
- **Settings** — a two-tab `TabView`: **General** (`SettingsView`) and **Connections**
  (`ConnectionsSettingsView`). **General** has three sections, auto-saved (debounced 500 ms): **Paths**
  (repos root, worktrees root), **Agent** (default model, an allowlist text area for extra directories),
  and **Status line** (mode: passthrough / Orchestra default / custom, with a command field for custom).
- **Connections** (`ConnectionsSettingsView`) — pick which daemon the board runs against: the built-in
  **This Mac** (local) connection plus any saved **remote** Linux boxes. Each row has a radio to make it
  active (`switchConnection`), and remotes an edit/delete pair; **Add remote…** opens a `ConnectionEditor`
  form (name, `user@host` SSH target, optional identity file, remote socket path, remote tmux socket). A
  live **status chip** (Connected / Connecting… / Reconnecting… / Disconnected, driven by
  `BoardModel.connectionState`) sits above a Connect/Disconnect toggle. Switching to a remote spins the
  app-managed [SSH tunnel](#connection-persistence-and-sandboxing) and re-points the board at its
  forwarded socket; key-based SSH auth to the host is a prerequisite (a Tailscale hostname works). The
  connection list is the client-side `ConnectionStore`, persisted per-Mac in `UserDefaults` (choosing
  *which* daemon is a client concern, never the daemon's own config) — the `Connection` model lives in the
  shared core so the planned [phone client](10-roadmap.md#the-nine-axes) reuses it.
- **Recovery panel** (`RecoveryView`) — fills the inspector for a `dead` card. It explains *why* (per
  `DeadReason`), surfaces the **preserved work** (repo/branch/path with View-changes / Reveal-in-Finder
  / Copy-path), shows the **original prompt** under an "Originally asked:" heading — with a **Copy prompt**
  affordance that grabs `task.initialPrompt` verbatim (always persisted, so it survives even a dead card)
  and flashes a "Copied" checkmark for ~1.2 s, mirroring the sibling Copy-path chrome and the
  `BreadcrumbStrip`'s copied feedback — and offers **Start new session** (`restart`), **Archive**,
  and — when a session id exists — **Try resume** (`resume`).
- **Activity popover** (`ActivityPopover`) — a **Live** tab (the streamed activity feed, each row
  colored by source and clickable to select its card) and a **CLI** tab (a quick reference of the
  `orchestra` verbs).
- **Done popover** (`DonePopover`) — the archived cards, each with copy-chat-link / copy-branch chips;
  clicking a row selects that archived card. Each row also carries an accent-pill **Reopen** button
  (`arrow.uturn.left`): it calls `BoardModel.reopen(_:)` → the [`reopen` RPC](05-command-reference.md#registry-commands),
  which recreates the card's worktree and resumes its agent; the card then jumps back onto the board, is
  selected (opening the live inspector), and the popover closes. (There is no "Zed" action on an archived
  row — archiving removed the worktree, so there are no changes to open until it is reopened.)

## Theme

`Theme.swift` holds the design tokens: three **accent** choices (blue/purple/graphite), two
**densities** (comfortable/compact), light/dark palettes for every surface (window, toolbar, card,
terminal, fields, chips, columns), and the **semantic** status colors. A toolbar toggle switches
light/dark and the whole theme recomputes. Fonts are system UI + monospaced; a `.surface(...)` modifier
reproduces the prototype's hairline-bordered, rounded-fill rendering exactly.

## Connection, persistence, and sandboxing

`BoardModel` is the app's view-model. It connects a `ControlClient(source:.app)` to the **active
connection's** socket, subscribes once per connection to the event stream (re-subscribing on reconnect,
since the stream ends when the daemon restarts), and applies `taskUpserted`/`taskRemoved`/`activity`
events to its published state. `refresh()` pulls `list` + `archivedList` + `getConfig` + `models`. UI
preferences (accent, density, dark mode, inspector width, shell/freeform panel heights, onboarded flag)
persist via `@AppStorage`.

**Connections and the SSH tunnel.** The active target is resolved through a `ConnectionController`:
`.local` returns `Config.socketPath` with no SSH, while `.remote` hands off to an `SSHMaster` that spawns
one **multiplexed master `ssh`** (`ssh -M -S <ctrl> -N -L <local.sock>:<remoteSocketPath> …`, key-only
`BatchMode=yes`), forwarding the box's daemon socket to a short local socket the transport then opens.
The argv itself is built by the pure, unit-tested `RemoteCommands` in the shared core; the app owns only
the process. `SSHMaster` cleans up any stale control/forwarded sockets before spawning, waits (bounded)
for the local socket to appear, keeps every path under the ~104-byte `sun_path` cap, and — because it
holds the `Process` in the foreground — gets an exit callback: an unexpected master death trips the
client's reconnect (respawn master → re-point the client at the new socket). `activate(_:)` rebuilds the
`ControlClient` per connection (a fresh transport each time) and preserves the local onboarding /
daemon-install flow; `switchConnection(_:)` persists the choice and re-points the board.

The app runs under the **default macOS App Sandbox** with an empty entitlements file and **Hardened
Runtime** on. It registers the `orchestra://` URL scheme so deep links (and Raycast/CLI-printed refs)
select the matching card. The embedded `orchestrad` binary ships at
`Orchestra.app/Contents/Resources/bin/orchestrad`.
