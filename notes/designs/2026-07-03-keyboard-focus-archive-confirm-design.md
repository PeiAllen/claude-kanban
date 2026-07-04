# Design: honest click-focus + accidental-archive guard

**Date:** 2026-07-03
**Branch:** `improve-key-use`
**Status:** approved, ready for implementation

## Problem

Two keyboard/mouse footguns on the board:

1. **Mouse clicks desync the focus state.** The app tracks two independent focus
   concepts — `selectedId` (drives the board **card glow**) and `focusZone`
   (`.board`/`.terminal`/`.shell`, drives the **inspector focus ring**). Clicking the
   already-selected card runs `selectedId = id; focusZone = .board`
   (`CardView.swift:54`) — it flips the app's *belief* to "board" and darkens the ring,
   but never ejects the terminal's first responder, so **keystrokes still go to the
   terminal**. The visual state lies about where the keyboard is. Desired behaviour: a
   card click should *descend into* that card's terminal.

2. **Archive is a one-keystroke, effectively-permanent action.** The only destructive
   card verb is **archive** (`a`), which fires immediately with no confirmation and a
   slow-to-reverse recovery (the user treats it as permanent). Because `a` is a bare
   letter, any moment the app's focus belief disagrees with the real first responder,
   ordinary typing can land an `a` on the board and archive a card.

## Fix 1 — card click descends into the terminal

Replace `CardView`'s tap handler (`CardView.swift:54`):

```swift
.onTapGesture { model.selectAndEnterTerminal(task.id) }
```

New `BoardModel` method — selects the card and moves the *real* first responder into
its agent terminal, keeping `focusZone` honest (falls back to `.board` when the card has
no mounted terminal, e.g. a dead agent showing RecoveryView):

```swift
/// A mouse click selects the card AND descends into its agent terminal, so the glow,
/// the ring, and the real first responder all agree after a click.
func selectAndEnterTerminal(_ id: UUID) {
    let sameCard = selectedId == id
    selectedId = id
    focusZone = .terminal
    if sameCard {
        if !FocusBridge.enterTerminal() { focusZone = .board }   // already mounted → claim now
    } else {
        // Inspector remounts on the new card; its autofocus (focusZone == .terminal) claims
        // focus. Re-assert once the new terminal view has mounted, as a fallback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            if !FocusBridge.enterTerminal() { self?.focusZone = .board }
        }
    }
}
```

`FocusBridge.enterTerminal()` and `focusTerminal(window:)` gain a
`@discardableResult Bool` return — `true` when a terminal actually took first responder,
`false` when none is mounted. This is what lets `selectAndEnterTerminal` reconcile
`focusZone` to reality instead of asserting a terminal zone that doesn't exist.

**Scope note — intentional asymmetry:** keyboard nav (`h/j/k/l`) and the `f` hint keep
selecting *on the board* (`focusZone = .board`); only `Enter`/`i` and now a **mouse
click** descend. "Keyboard = browse, mouse = commit." Terminal-click already sets
`focusZone = .terminal` (`AgentTerminalView` → `onFocused`) and the inspector only shows
the selected card, so `selectedId` already matches there — no change needed.

## Fix 2 — confirm dialog on the keyboard archive shortcut only

Add pending-archive state to `BoardModel`:

```swift
/// Card id awaiting archive confirmation (keyboard `a` path only). Non-nil → confirm dialog.
@Published var archiveConfirm: UUID?
```

- **Keyboard `a`** (`.archive` intent, `KeyboardController.swift:118`) → new
  `requestArchiveSelected()` which sets `archiveConfirm = selectedId` (does *not*
  archive). Guarded on a non-nil selection.
- `confirmArchive()` performs the real `archive(id)` and clears the state;
  `cancelArchive()` just clears it.
- **`KeyboardController.handle()`** gains an early block (mirroring the palette block),
  placed right after the palette handling and before `context()`:

  ```swift
  if model.archiveConfirm != nil {
      if ch.key == "\r" || ch.key == "\n" { model.confirmArchive(); return true }
      // esc / ⌘W peel the dialog via closeFrontmost; swallow every other key.
      let isClose = ch.key == "\u{1B}" || (ch.mods.contains(.command) && ch.key == "w")
      if !isClose { return true }
  }
  ```

- **`BoardModel.closeFrontmost()`** gains the dialog as its *first* peel, so both `esc`
  and `⌘W` cancel it (and only it — the inspector/card underneath is untouched),
  consistent with how `⌘W` unwinds every other overlay:

  ```swift
  func closeFrontmost() {
      if archiveConfirm != nil { archiveConfirm = nil; return }
      if hintActive { endHint(); return }
      ...
  }
  ```

- **`ArchiveConfirmView`** — a small centered overlay in `OrchestraApp.swift`, styled
  like `KeyboardHelpView`: the card title + "Archive this card? ⏎ / esc", with an
  `.onTapGesture` backdrop that calls `cancelArchive()`. Add
  `.animation(.easeOut(duration: 0.15), value: model.archiveConfirm)`.

- **`context()`** adds `|| model.archiveConfirm != nil` to the `.overlay` check for
  semantic consistency (the early handler already short-circuits keys).

- **Auto-cancel on external removal:** in the task-removal ingest path
  (`BoardModel.swift:280`), clear `archiveConfirm` if the removed id matches, so the
  dialog can't linger on a card that was archived elsewhere (CLI/MCP/another client).

### Archive entry points — what confirms and what stays direct

| Entry point | Location | Behaviour |
| --- | --- | --- |
| Keyboard `a` | `KeyboardController.swift:118` | **Confirm dialog** (the footgun) |
| Command palette "Archive card" | `BoardModel.swift:668` | Direct (deliberate `:` → select → ⏎) |
| Inspector "Archive" button | `InspectorView.swift:96` | Direct (deliberate click) |
| Recovery "Archive" button | `RecoveryView.swift:99` | Direct (deliberate click) |

While the confirm dialog is up: `⏎` archives, `esc`/`⌘W` cancel, every other key is inert.

## Behaviour after both fixes

Even in the reverse desync — ring says `.terminal` but the real first responder is the
board — typing `a` derives `KeyContext == .board` from the *real* first responder, so it
routes to `requestArchiveSelected()` and raises the **confirm dialog** rather than
archiving instantly. Fix 1 removes the common way to end up desynced; Fix 2 makes the
one destructive verb non-instant regardless.

## Files touched

- `App/Views/CardView.swift` — tap handler
- `App/BoardModel.swift` — `selectAndEnterTerminal`, `archiveConfirm`,
  `requestArchiveSelected`/`confirmArchive`/`cancelArchive`, `closeFrontmost` peel,
  ingest auto-cancel
- `App/KeyboardController.swift` — `FocusBridge` `Bool` returns, `context()` overlay
  check, `handle()` early block, `.archive` intent → `requestArchiveSelected`
- `App/OrchestraApp.swift` — `ArchiveConfirmView` overlay + animation
- new `ArchiveConfirmView` (in `OrchestraApp.swift` or its own file, matching
  `KeyboardHelpView`'s home)

## Out of scope

- Making `f` hint / arrow nav descend into the terminal (kept as board-level browse).
- Undo-for-archive / faster recovery (the chosen guard is prevention, not reversal).
- Any change to shell-tab close (`⌘W` in `.shell`) or the terminal-click path.
