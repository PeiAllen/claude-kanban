# Agent buttons simplification + inbox editor

**Date:** 2026-07-01
**Status:** Design — approved for implementation planning
**Branch:** `fix-agent-buttons`

## Problem

The per-card and board action buttons are more than the user wants:

- **Fan-out** is not needed as a button.
- **Handoff** and **Fork** buttons duplicate what natural-language → MCP delegation
  already does. The user's real uses — *reset the context* (handoff) and *explore a
  slice / discuss component A, B, C separately without clogging context, then get data
  back* (fork) — are better served by just talking to the agent and letting it call the
  MCP tools.
- **Send** is a one-shot composer. The user wants to manage the whole durable inbox:
  see queued messages, reorder them, append, edit, and remove.

## Goals

1. Remove the **Fan-out**, **Handoff**, and **Fork** buttons and their sheets/popovers.
2. Replace the **Send** button with an **Inbox editor**: list / reorder / append / edit
   text / remove queued messages.
3. Make sure the natural-language → MCP path covers the removed buttons' use cases —
   specifically, update the delegation skill doc so an exploratory/planning fork lands on
   a lightweight **freeform read-only card in the same cwd**, not a new worktree.
4. Expose the inbox operations on the MCP surface too (they come for free as registry
   commands; no reason to special-case them out).

## Non-goals

- No dedicated `fork` MCP tool. The agent composes `spawn` with `cwd` + `access: readOnly`
  + `seed`; the skill-doc default makes that reliable.
- No change to the handoff mechanic (still session-`--resume`, so it carries the
  conversation) or the fork mechanic (still a fresh, seed-only session).
- No new "carry the conversation into a fork" feature.

---

## Part 1 — Button removals (mechanical)

All three are pure deletions; the underlying MCP tools stay.

| Button | UI to delete | Model wrapper to delete |
|--------|--------------|-------------------------|
| Fan-out | `ToolbarView.swift` fanout button (~99–117); `FanoutSheet.swift` (whole file); `showFanout` overlay in `OrchestraApp.swift` (~104–108) and the `showFanout` flag | `BoardModel.fanout` (~270–283) |
| Handoff | `InspectorView.swift` `handoffAction` + popover (~118–127) | `BoardModel.handoff` (~246–253) |
| Fork | `InspectorView.swift` `forkAction` + 3-input popover (~130–151) and its branch-prefill `.onAppear` | `BoardModel.fork` (~256–267) |

The MCP tools `handoff`, `batch-spawn`, and `spawn` are **not** touched — the
natural-language path keeps working. After removal, the per-card header shows only the
**Inbox** button (plus whatever non-action controls already live there).

---

## Part 2 — Send → Inbox editor

### 2.1 Backend — `Inbox.swift`

The inbox is a durable actor over a single append-ordered `[InboxMessage]` JSON array
(`InboxMessage = { id, cardId, text, createdAt }`), with FIFO-per-card via a stable
`cardId` filter. It already has `peek`, `enqueue`, `drain`. Add three methods:

- `remove(_ id: UUID) throws` — drop the message with that id; persist.
- `update(_ id: UUID, text: String) throws` — replace that message's `text`; persist.
  (Only `text` is mutable; `id`/`cardId`/`createdAt` are preserved.)
- `reorder(_ cardId: UUID, orderedIds: [UUID]) throws` — reposition that card's messages.
  Because all cards share one array, this preserves interleaving: collect the array
  indices whose `cardId` matches, then refill exactly those index positions with the
  card's messages in `orderedIds` order. `orderedIds` must be a permutation of the card's
  current message ids; ids not belonging to the card are ignored, missing ids are an
  error (reject rather than silently drop). Persist.

`enqueue` (append) is reused for the editor's "append" action.

**Concurrency note:** the Stop-hook drain calls `drain(cardId)` at the agent's next
turn-end and removes all pending messages. If a drain races an in-flight edit, the edit is
moot (the message was delivered). The editor reloads via `peek` after each op and on open,
so the UI reflects reality; no locking beyond the actor is needed.

### 2.2 Control / MCP surface — new registry commands

The MCP tool list is generated verbatim from `CommandRegistry.build()`
(`Sources/OrchestraCore/Commands.swift`), and the app talks to the daemon over the same
control socket. So the inbox ops are added as ordinary registry commands — the app gets
them over the socket and they surface as MCP tools automatically. Proposed commands
(names follow existing hyphenated convention, e.g. `batch-spawn`):

- `inbox <ref>` — list pending messages for a card (returns `[InboxMessage]` via `peek`).
- `inbox-edit <ref> <id> <text>` — edit a message (`update`).
- `inbox-remove <ref> <id>` — remove a message.
- `inbox-reorder <ref> <ids…>` — reorder a card's messages (`reorder`); `ids` is the full
  new order.
- **Append** reuses the existing `send <ref> <message>`.

Each handler resolves `ref` → card (same as existing commands) and calls the matching
`Inbox` method on `OrchestraService`. `OrchestraService` gains thin pass-throughs
mirroring its existing `send`.

### 2.3 UI — `InspectorView.swift` + `BoardModel.swift`

Replace `sendAction` with an **`inboxAction`** button: icon `tray.full`, label "Inbox",
with a count badge when messages are queued. It opens a popover (consistent with today's
send popover) containing:

- A scrollable list of queued messages in FIFO order. Each row: the message text as an
  inline-editable field (commit on blur/enter → `inbox-edit`), a drag handle for reorder
  (drop → `inbox-reorder` with the new id order), and a delete control (→ `inbox-remove`).
- An append field at the bottom (→ `send`), matching today's composer.
- Loads via `inbox` (peek) on open and refreshes after every op.

`BoardModel` gains `inboxPeek / inboxEdit / inboxRemove / inboxReorder` wrappers (RPC to
the new commands); append reuses the existing `send`.

---

## Part 3 — Delegation skill-doc update

Update **both** bundled docs — `Sources/OrchestraCore/Resources/delegation-skill.md` and
`delegation-agents.md` — so the natural-language path covers the removed buttons' use
cases. Two changes:

1. **Tool-surface list:** surface `spawn`'s currently-invisible options — `cwd` (freeform,
   no worktree), `access: readOnly`, and `seed` — so the agent knows a spawn can be a
   lightweight read-only card in an existing directory.

2. **Rewrite the Fork bullet** to make the *default* exploratory/planning fork a
   **freeform, read-only card in the same cwd** (no worktree/branch), seeded with the
   slice, that reports back via `wait` + inbox drain. Include a concrete example: *"while
   planning, fork read-only cards to go over components A, B, and C separately without
   clogging this context, then drain their conclusions."* Keep worktree-fork
   (`spawn` with `repo` + `branch`) documented as the option for when you actually want a
   branch/PR.

The Handoff bullet already covers "reset the context" (`handoff <thisCard> <summary>`);
leave its guidance, just confirm it reads clearly as the context-reset move.

---

## Affected files (summary)

- `App/Views/ToolbarView.swift` — remove fanout button.
- `App/Views/FanoutSheet.swift` — delete.
- `App/OrchestraApp.swift` — remove fanout overlay + `showFanout`.
- `App/Views/InspectorView.swift` — remove handoff/fork actions; replace send with inbox editor.
- `App/BoardModel.swift` — remove `handoff`/`fork`/`fanout`; add inbox wrappers.
- `Sources/OrchestraCore/Inbox.swift` — add `remove`/`update`/`reorder`.
- `Sources/OrchestraCore/OrchestraService.swift` (+ maybe a `+Inbox` extension) — pass-throughs.
- `Sources/OrchestraCore/Commands.swift` — register `inbox` / `inbox-edit` / `inbox-remove` / `inbox-reorder`.
- `Sources/OrchestraCore/Resources/delegation-skill.md` + `delegation-agents.md` — fork/tool-surface rewrite.

## Testing

- **Inbox actor:** unit tests for `remove` (by id, incl. wrong id), `update` (text only,
  other fields preserved), `reorder` (permutation correctness + interleaving of a second
  card's messages preserved + rejects a non-permutation).
- **Commands:** round-trip each new command through the control server against a temp
  inbox path; assert the on-disk JSON matches.
- **Skill docs:** no automated test; verify the rendered guidance reads correctly and the
  freeform-readonly recipe is unambiguous.
- **Manual UI:** isolated app instance (per project memory) — queue a few messages, then
  reorder / edit / delete / append and confirm persistence + drain behavior; confirm the
  fanout/handoff/fork buttons are gone.
