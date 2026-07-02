# Keyboard shortcuts — full keyboard navigability for a vim user

**Status:** design (approved in brainstorm 2026-07-02) · **Scope:** the SwiftUI app under `App/`

## Goal

Make the Orchestra board **completely navigable by keyboard**, with a shortcut scheme designed
for a **vim user** — bare-key motion, spatial pane movement, `g`-go-to sequences, `:`/`/`
command-line, and a discoverability layer — while never fighting the live agent terminals the
inspector embeds.

## The central tension

The inspector embeds live terminals (SwiftTerm — the agent terminal + shell tabs). Vim navigation
keys (`hjkl`) collide head-on with terminal input: when a terminal is focused, every keystroke must
reach the agent/shell untouched, not move the board selection. Every design decision below flows
from resolving this.

## Precedent (why this shape)

Researched across three app families:

- **Terminal multiplexers / TUIs** (tmux, Zellij, k9s, lazygit) — the two viable mechanisms are
  *prefix* (tmux `C-b` — terminal keeps ~100% of keys, but every nav costs a chord) and *modal*
  (Zellij — bare keys navigate, a self-rewriting bar shows the mode). Prefix taxes navigation;
  a global mode adds a vigilance tax.
- **Modal editors that embed terminals** (Neovim, VS Code, Zed) — the key precedent. Neovim's
  terminal-mode forwards all keys to the pty and escapes via `<C-\><C-n>` (a sequence *no* TUI uses).
  Universal lesson: **never use bare `Esc` to eject** — the agent (vim/fzf/Claude Code) needs `Esc`.
  VS Code/Zed instead move focus with out-of-band commands guarded by a "terminal focused" predicate,
  and Neovim users *fuse* escape+move into one directional chord (`<C-w>h`).
- **Keyboard-first GUIs** (Linear, Superhuman, GitHub, Vimium) — standardized conventions a vim user
  expects: `j/k` move, `g`+letter go-to, `/` search, `?` help, `x` select, and Vimium's `f`
  link-hints as the scalable "reach any target" primitive.

**The insight that makes this reliable for Orchestra:** tmux's seamless-nav plugin
(vim-tmux-navigator) is fragile because it *guesses* what's running in a pane via `ps`. Orchestra
**owns the focus state** — it knows exactly when SwiftTerm holds focus — so "focus *is* the mode"
can be made rock-solid here in a way tmux never could.

## Core model: focus *is* the mode

No global NORMAL/INSERT mode to track blind. The active **context** is derived purely from what is
focused — the same focus ring the user already tracks in any GUI:

| Context | When | Keys do |
|---|---|---|
| **Board** | a card / column / dock has focus | navigate + act (bare keys) |
| **Terminal** | a SwiftTerm view has focus | everything → agent/shell, untouched |
| **Field** | a text input has focus (spawn, inbox, search) | you type; `Ctrl-j`/`Ctrl-k` move a dropdown; `Esc` steps out |
| **Overlay** | a modal / popover is up (spawn, done, activity, settings, help, palette) | navigate that overlay (`Tab`/`j`/`k`, `h`/`l` on selectors) |

A small **context chip** in the inspector chrome / toolbar always shows the current context
(`BOARD` · `● TERMINAL` · `HINT`), so "am I about to type into the agent?" is answered at a glance.

## Layer 1 — Selection within a pane (bare `hjkl`)

Bare keys move the **selection** inside whichever pane has focus; they never cross a pane boundary.

- `h` / `l` — move selection across the columns (Plan ↔ Impl ↔ Review)
- `j` / `k` — move selection down / up within the current column (or through the freeform grid)
- `gg` / `G` — first / last card in the current column
- `Enter` — open the inspector for the selected card (focus stays on the board — keep navigating)
- `i` — **insert**: jump focus straight into the agent terminal to type (vim's `i`)
- `Esc` — close the inspector / clear the selection

## Layer 2 — Focus between panes (bare `Ctrl-hjkl`, spatial + edge-aware)

No `Ctrl-w` prefix. Bare `Ctrl-hjkl` moves keyboard **focus between panes, by the real on-screen
geometry**:

```
        ┌─────────┬─────────┬─────────┐   ┌──────────────┐
        │  Plan   │  Impl   │ Review  │   │  agent term  │  ← Ctrl-l from board
        │  cards  │  cards  │  cards  │   ├──────────────┤    reaches inspector
        └─────────┴─────────┴─────────┘   │    shell     │
   Ctrl-j ↓                      ↑ Ctrl-k └──────────────┘
        ┌───────────────────────────────┐   Ctrl-j / Ctrl-k
        │        Freeform dock          │   swaps term ↔ shell
        └───────────────────────────────┘
```

- `Ctrl-j` columns → freeform dock; `Ctrl-k` freeform → columns
- `Ctrl-l` board → inspector (agent terminal); `Ctrl-h` inspector → board
- Inside the inspector: `Ctrl-j` / `Ctrl-k` swap the agent terminal ↔ shell panel
- **`Ctrl-h` from a focused terminal doubles as the eject** — it's just "the board is to the left,"
  so there is no separate eject key to learn.

**`Ctrl-hjkl` is the one universal "move" chord, rescoped by context.** On the board it moves focus
between panes (above). While a text field or modal owns the keyboard, bare `j`/`k` are busy typing, so
the *same* `Ctrl-hjkl` moves *within* the modal instead — down/up a form or a dropdown, left/right
across a selector (see Layer 7). Its meaning always follows the active context; the muscle memory is
constant.

**Edge-aware interception (the key rule).** `Ctrl-hjkl` is intercepted for pane movement **only when
a pane actually exists in that direction**; otherwise the keystroke **passes straight through to the
terminal** as its literal control code. Consequences:

- The inspector is the rightmost pane → `Ctrl-l` in the agent terminal or shell has nothing to its
  right → falls through as a literal **clear-screen**. (The shells keep `Ctrl-l`.)
- Agent terminal is the topmost sub-pane → `Ctrl-k` there falls through (kill-line).
- Shell is the bottom-most sub-pane → `Ctrl-j` there falls through (newline).
- The **only** control key a focused terminal genuinely gives up is `Ctrl-h` (the board is always to
  the left). This is cheap: shells/agents receive the real Backspace key as `0x7f`, not `Ctrl-h`.

## Layer 2.5 — Resizing / collapsing panes, and scrolling

**Resize the focused pane** — `Ctrl-Shift-hjkl` grows / shrinks the focused pane's movable edge, the
natural extension of `Ctrl-hjkl` (move focus) → `Ctrl-Shift-hjkl` (move the *border*). It drives the
three drag handles the mouse uses: inspector width (`Ctrl-Shift-h`/`l`), freeform-dock height and
shell-panel height (`Ctrl-Shift-k`/`j`). `:` carries a **"reset layout"** command.

**Collapse / expand** — `z` toggles the focused collapsible region (freeform dock, shell panel) — the
vim fold metaphor. (These persist across launches today, so the toggle just flips the stored state.)

**Scrolling — three kinds of region, three rules:**

- **Selection lists (columns, freeform grid):** there is no separate scroll — moving the selection
  with `j`/`k`/`hjkl` **auto-scrolls the container to keep the selected card visible** (vim's
  cursor-follows-view model). `Ctrl-d` / `Ctrl-u` half-page, `Ctrl-f` / `Ctrl-b` full-page,
  `gg` / `G` to the ends — all moving selection *and* view together. (Safe here: not a pty.)
- **Read-only content (the Diff view):** pure vim scrolling over a read-only buffer — `j`/`k` by
  line, `Ctrl-d`/`Ctrl-u` half-page, `Ctrl-f`/`Ctrl-b` full-page, `gg`/`G`, and `/` `n` `N` to search
  within the diff.
- **Terminals (agent + shell):** scrollback is the **pty's own job**, not Orchestra's — the terminal
  attaches to tmux, and Orchestra passes all keys through, so the user's **tmux copy-mode** (their
  prefix + `[`, then vim keys / `/` search) scrolls it natively, alongside the mouse wheel (already
  forwarded) and `Shift-PageUp`/`PageDown`. Orchestra deliberately binds **no** `Ctrl-d`/`Ctrl-u`
  here — those are the pty's (EOF / clear-line) — which is why scroll keys are safe everywhere else
  but hands-off inside a terminal.

## Layer 3 — Go-to a region (`g` + letter)

A timed two-key sequence (GitHub-`hotkey` style; which-key popup on pause):

`gp` Plan · `gi` Implementation · `gr` Review · `gf` Freeform dock · `ga` Activity · `gd` Done ·
`gs` Settings

## Layer 4 — Verbs on the selected card (single keys)

**Selecting ≠ opening.** Bare `hjkl` only *highlights* a card; only `Enter` opens the inspector.
(This differs from a mouse click, which selects *and* opens.) So every verb below acts on the
**highlighted card without opening it** — e.g. `a` archives ("closes") the card you've navigated to
without entering it; multi-select (`x`, phase 2) then `a` closes several at once.


- `c` — create / spawn a card (opens the spawn sheet)
- `H` / `L` — **carry** the selected card one column left / right (shift = grab the card; mirrors `h`/`l`)
- `a` — archive · `r` — reopen (on a Done card) · `o` — open worktree in Zed (View changes)
- `Enter` — open inspector · `i` — focus agent terminal to type

### Inspector chrome controls

The inspector has ~10 chrome controls (Agent⇄Diff toggle, View-changes, Inbox, Archive, close, Copy
chat link, Copy tmux target, Copy path, New terminal, Open read-only "Inspect" terminal). They are
reachable three ways — the same three-tier pattern used across the app (dedicated verb → `f` hint →
`:` palette / `Tab` ring):

**Dedicated verbs** — active in Board context whenever a card is selected (no need to focus the
inspector; if focus is inside the agent terminal, `Ctrl-h` out first). The three copies use a vim
**`y` (yank) prefix**:

| Control | Key |
|---|---|
| Agent ⇄ Diff toggle | `d` |
| View changes → Zed | `o` |
| Inbox editor | `I` (capital — `i` = type to agent) |
| Archive | `a` |
| Close inspector | `q` (or `Esc`) |
| New terminal (shell tab) | `t` |
| Open read-only Inspect terminal | `T` |
| Copy chat link | `yc` |
| Copy tmux target | `yt` |
| Copy cwd / path | `yp` |

**`f` link-hints (phase 2)** — label every visible chrome button; type the label to hit it. The
catch-all so the low-frequency buttons need no dedicated key.

**`:` palette · `Tab` ring · `?` help** — every button is a named command in the `:` palette (which
shows its shortcut); with the inspector focused (`Ctrl-l`), `Tab` / `Ctrl-j` / `Ctrl-k` cycle the
chrome as a plain focus ring and `Enter` activates; `?` lists this table when the inspector is open.

### Shell tabs

The shell panel is a ribbon of `shell-N` tabs (each an `xmark` to close, `+` to add). Treated as
horizontal sub-panes of the inspector:

- **Switch tabs:** `Ctrl-h` / `Ctrl-l` move between tabs (edge-aware — `Ctrl-h` on the first tab
  ejects to the board; `Ctrl-l` past the last falls through to the pty as clear-screen)
- **New tab:** `t`
- **Close the current tab:** naturally, `Ctrl-d` / `exit` in the shell ends it (the tmux window
  closes, the tab drops); explicitly, `x` closes the focused tab when the **ribbon** (not the pty) has
  focus — mirrors the `xmark`, and is also reachable via an `f` hint or `:` "close shell tab".

## Layer 5 — Command-line & search (vim keys, no `Cmd`)

- `:` — command palette (fuzzy over every board action; each row shows its shortcut, so the palette
  teaches the keymap)
- `/` — search / filter cards; `n` / `N` next / prev match; `Esc` clears
- The vim *command* layer uses no `Cmd` (hence `:` / `/`, not `Cmd-K`); standard macOS `Cmd`
  accelerators live in their own complementary layer — see Layer 8.

## Layer 6 — Discoverability

- `?` — help overlay **scoped to the current context** (only the keys valid right now)
- **which-key popup** after `g` or `:` if the user pauses (never slows an expert; rescues a beginner)

## Phase 2 (deferred — ship core nav first)

- `f` — **link-hints**: overlay a short home-row label on every visible card & button; type the label
  to jump/activate. The scalable "reach *anything*" primitive (Vimium `f`).
- `x` — toggle multi-select; `Shift-J` / `Shift-K` extend the range; a verb (or `:`) then acts on the
  whole set (e.g. move several cards to Review at once).

## Layer 7 — Fields, selectors, and modals (settings, spawn sheet, inbox)

Modals must be as keyboard-driven as the board. The rule set, by control type:

**Modal-level flow (Overlay context)**
- `Tab` / `Shift-Tab` — next / previous control (and `Ctrl-j` / `Ctrl-k` as vim-friendly synonyms,
  the same move chord used everywhere else)
- `Enter` — trigger the modal's **primary action** (Spawn / Save) from anywhere it's unambiguous;
  a visible default button shows what `Enter` will do
- **Progressive `Esc`** (layered, vim-style): `Esc` first closes an open dropdown → then steps out
  of the focused field to modal-nav → then closes the modal. One key, peels one layer at a time.
- On open, focus lands on the **most useful control** (e.g. the prompt field in the spawn sheet),
  not nothing — so the keyboard is immediately live.

**Text fields — single-line** (repos root, worktrees root, status-line command, inbox append)
- Type normally; `Ctrl-a` / `Ctrl-e` start/end, `Ctrl-w` delete-word (readline muscle memory)
- `Enter` commits and advances / fires the primary action; `Esc` steps out to modal-nav

**Text fields — multiline** (initial prompt, allowlist textarea)
- `Enter` inserts a newline; **`Ctrl-Enter`** submits the modal (existing convention); `Esc` steps out

**Combo boxes — fuzzy** (repo, branch) — *the `Ctrl-j`/`Ctrl-k` crux*
- Type to filter; **`Ctrl-j` / `Ctrl-k`** move the highlighted candidate down / up the open dropdown
  (bare `j`/`k` can't be used — they'd type into the field), exactly like vim's completion popup
- `Enter` accepts the highlight; `Tab` accepts-and-advances (readline style)
- `Esc` closes the dropdown but keeps the field (progressive escape)

**Segmented / button-row selectors** (Start-in, agent, model, status-line mode) — *not text, so bare
keys are safe*
- When focused: `h` / `l` (and `←` / `→`) cycle options; `Enter` / `Space` confirm

**Toggles** (read-only checkbox): `Space` toggles when focused.

**Inbox editor popover** (list + append field)
- Browsing the rows is Overlay context (no text field owns the keys), so bare **`j` / `k` move the row
  selection**; `Enter` edits the row inline (→ `inbox-edit`), in-edit `Enter` commits and `Esc` cancels;
  `dd` (or `x`) deletes a row (→ `inbox-remove`); **`K` / `J` carry the selected row up / down**
  (→ `inbox-reorder`) — shift = "grab it," mirroring the board's `H`/`L` carry;
  the append field at the bottom is a single-line Field (`Enter` → `send`).

The unifying idea: **`Ctrl-j`/`Ctrl-k` are the "move a list while a text field owns the keyboard"
primitive** — the same universal move chord, applied inside a modal — mirroring vim's completion popup,
so a fuzzy combo box never forces the hand to the arrow keys or the mouse.

## Layer 8 — Standard macOS accelerators (`Cmd`)

A complementary layer of familiar `Cmd` shortcuts, parallel to the vim keys. Because terminals ignore
`Cmd`, these work **even while a terminal is focused** (no eject required), and they populate the
**menu bar** for native discoverability. They're accelerators, not the primary scheme — every one has a
vim-key twin.

| Accelerator | Action | vim twin |
|---|---|---|
| `Cmd-N` | New card (opens the spawn sheet) | `c` |
| `Cmd-T` | New shell tab in the selected card's inspector | `t` |
| `Cmd-W` | Close the frontmost thing (see ordering below) | `Esc` / `q` / `a` |

**`Cmd-W` peels the most-transient thing first** (a macOS-style close that mirrors the progressive
`Esc`), so it's never surprisingly destructive:

1. an open modal / popover → close it
2. a focused shell tab → close that tab
3. an open inspector → close the inspector
4. otherwise, a selected card on the board → **archive it**

So `Cmd-W` archives a card only when there's nothing lighter to close. A `File`/`Card` menu-bar menu
should surface these (`New Card ⌘N`, `New Shell ⌘T`, `Close ⌘W`) so they're visible without reading
this doc.

## Design principles / non-goals

- **`Esc` is sacred to the terminal.** It is never the ejector; it always reaches the agent when a
  terminal is focused. Ejection is spatial (`Ctrl-h`).
- **No global mode.** The context is always derived from focus, never a toggle the user must remember.
- **Intercept the minimum.** When a terminal is focused, Orchestra intercepts only the `Ctrl-hjkl`
  directions that lead to a real neighbor; everything else reaches the pty.
- **Conventions over novelty.** `j/k`, `g`+letter, `/`, `?`, `x` follow Linear/GitHub/Vimium so a vim
  user's existing muscle memory transfers.

## Open questions for the implementation plan

- Exact SwiftUI mechanism for global key capture ahead of SwiftTerm (`NSEvent` local monitor vs.
  `.onKeyPress` / a first-responder key view) and how it reads/writes `BoardModel.selectedId` &
  focus state.
- How the freeform grid's 2-D selection maps to `hjkl` (row/column geometry of the adaptive grid).
- Whether the context chip lives in the toolbar, the inspector chrome, or both.
- Whether any of these bindings should be user-remappable (later).
