# Card Navigation History Design

**Date:** 2026-07-11
**Status:** approved and implemented
**Scope:** macOS Vim keyboard navigation

## Goal

Add browser-style card navigation history to Vim mode:

- `Ctrl-O` selects the previous card in visit history.
- `Ctrl-I` selects the next card after navigating backward.
- Both shortcuts work while the board or a terminal owns the keyboard.
- Navigation preserves the active mode: board stays on the board; terminal moves into the destination
  card's agent terminal.

## History semantics

History records every non-nil card-selection transition, regardless of its source. This includes mouse
clicks, `hjkl`, column jumps, search results, link hints, notification clicks, activity items, and other
UI affordances that assign `selectedId`.

The history behaves like a browser:

- Consecutive selections of the same card do not add duplicate entries.
- `Ctrl-O` moves toward older entries; `Ctrl-I` moves toward newer entries.
- Selecting a different card after moving backward drops the abandoned forward entries.
- Closing the inspector (`selectedId = nil`) does not create a history entry.
- Entries whose cards no longer exist in the current board or archive are skipped.
- History is session-local and is not persisted across app launches.

## Architecture

### Pure history state

Add a small pure card-history value type that owns an ordered list of card UUIDs and a cursor. Its public
operations are:

- record a newly visited card;
- move backward to the nearest still-valid card;
- move forward to the nearest still-valid card.

Back/forward traversal must not record the destination as a new visit. The pure type is independently
unit-tested for duplicate suppression, forward truncation, bounds, and stale-entry skipping.

### One selection-observation seam

Extend `BoardStore.selectedId`'s existing property observer so every non-nil transition reaches an
overridable selection-change hook. `BoardStore` keeps a no-op base implementation; desktop `BoardUX`
overrides the hook and records the selection in its history state. This mirrors the existing
`onSelectionCleared()` seam and avoids modifying every selection call site.

When history traversal assigns `selectedId`, `BoardUX` temporarily suppresses recording so moving the
cursor does not create a new branch. It validates destinations against the cards currently present in
`tasks + archived`, allowing archived cards that still exist to remain navigable while skipping removed
cards.

### Vim key routing

Add backward and forward history intents to the pure keyboard layer. `VimKeybindings` maps:

- `Ctrl-O` to history-back;
- `Ctrl-I` to history-forward.

The bindings apply only in `.board` and `.terminal` contexts. They are absent from `CommandKeybindings`,
so disabling Vim keyboard mode restores normal handling. Fields and overlays do not consume the chords.
The mapping is evaluated before the generic terminal passthrough, because these two chords are deliberate
global Vim-mode navigation commands.

### Mode preservation

`KeyboardController` passes the derived key context to the history executor:

- From `.board`, select the history destination with `focusZone = .board`. The new inspector may mount,
  but it must not autofocus its terminal.
- From `.terminal`, select the history destination with `focusZone = .terminal`. The destination card's
  agent terminal uses its existing autofocus-on-mount path; a short deferred focus assertion reuses the
  existing platform focus seam as a fallback after the inspector remounts.

Terminal history navigation always lands in the destination card's agent terminal. It does not attempt to
match a shell tab from the source card because shell-window sets are card-specific and may have no
corresponding destination.

## User-facing discoverability

Add `Ctrl-O` and `Ctrl-I` to the keyboard help overlay and the keyboard-navigation documentation. No
command-palette entries are needed: these are traversal operations whose availability depends on cursor
position, not card actions.

## Testing

Follow test-first development:

1. Pure history tests prove recording, back/forward bounds, forward truncation, and stale-card skipping.
2. Keybinding tests prove both chords resolve in board and terminal contexts, pass through fields and
   overlays, and remain unmapped when Vim mode is disabled.
3. `BoardUX` tests prove all `selectedId` changes are recorded, traversal does not self-record, and board
   versus terminal focus is preserved.
4. Run the targeted Swift tests, the app typecheck, and the keyboard demo/harness where its existing
   coverage can exercise the new shortcuts.

## Out of scope

- Persisting history between launches.
- Sharing history between desktop and phone clients.
- Navigating between non-card surfaces such as Settings, Activity, or Done.
- Preserving a source card's exact shell tab on the destination card.
- Adding non-Vim command-key equivalents.
