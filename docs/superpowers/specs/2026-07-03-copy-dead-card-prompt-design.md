# Copy initial prompt from the dead-card inspector

**Date:** 2026-07-03
**Status:** Approved (approach A)

## Problem

When a card fails to open or dies (`task.status == .dead`), the inspector shows
`RecoveryView` instead of the terminal. That panel already displays the card's
seed prompt under an "Originally asked:" heading, but there is no way to copy it.
A user who wants to re-run or reuse the prompt (e.g. spawn a fresh card, paste it
elsewhere) has to retype it by hand.

## Solution

Add a "Copy prompt" affordance to the "Originally asked:" block in
`App/Views/RecoveryView.swift` (lines 63–71). Tapping it copies
`task.initialPrompt` verbatim to the pasteboard and gives brief in-place feedback.

`task.initialPrompt` is a non-optional, persisted `String` that is always present
regardless of session liveness, so it is reliably available for a dead card.

### Behaviour (approach A)

- A compact "Copy prompt" button sits on the "Originally asked:" header row,
  mirroring the existing "Copy path" `miniButton` (RecoveryView.swift:58) and
  reusing the shared `miniButton` / `miniLabel` chrome (lines 139–156).
- On tap it calls the existing `copy(_:)` helper (line 158) with
  `task.initialPrompt`, then transiently swaps its glyph + label to a checkmark +
  "Copied" for ~1s before reverting — mirroring the copied-checkmark feedback the
  `BreadcrumbStrip` already uses in `InspectorView.swift`.

## Scope

- One file: `App/Views/RecoveryView.swift`.
- No model, service, persistence, or data-flow changes.
- Purely presentational; the prompt data and copy helper already exist.

## Non-goals

- No copy affordance for live (non-dead) cards.
- No change to what the "Originally asked:" block displays.
- No new clipboard/toast infrastructure.
