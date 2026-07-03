# Configurable notifications & sound

**Date:** 2026-07-03
**Status:** Design — awaiting user review
**Branch:** `update-notification-time`

## Problem

Notifications are hardcoded and coarse. `App/AgentNotifier.swift` fires on exactly one
condition — a card flipping to `.waiting` — with two global, default-on toggles:

- **banner** (`orch_notify_waiting`) — Notification Center banner, hardcoded to
  background-only (`!NSApp.isActive`).
- **sound** (`orch_notify_sound`) — the hardcoded "Submarine" sound, hardcoded to play
  *always* (even foregrounded).

The user wants two axes of control the current design doesn't expose:

1. **Focus scope** — per situation, choose whether a notification fires only when Orchestra
   is backgrounded, also when it's foregrounded, or never. Today this is baked in
   (banner=bg-only, sound=always) and not user-settable.
2. **Trigger** — choose *what* raises a notification, not just "any waiting." And customize
   the sound per trigger.

## Why the trigger set is what it is (signal research)

The `.waiting` transition is driven by two Claude Code hooks that Orchestra currently
collapses into one `notify` event (`claude-hooks.json` lines 20–25 both call
`_report --event notify`; `ClaudeCodeAdapter.parse` maps both to `status: .waiting`).

The `Notification` hook carries a **`notification_type`** field (confirmed against the
official Claude Code hooks docs) that cleanly discriminates the cases — no fragile
message-text matching required:

| Real event | Hook / `notification_type` | Chosen trigger |
|---|---|---|
| Needs tool approval | `Notification` / `permission_prompt` | **Permission needed** |
| Finished, waiting for next prompt | `Notification` / `idle_prompt` | **Turn ended** |
| Agent's turn ended | `Stop` hook (no message) | **Turn ended** |
| Session died (exit / crash / vanished) | `SessionEnd` / liveness poll → `status = .dead` | **Card died** |

**Decisions folded in from the design dialogue:**

- **Three triggers only:** *Permission needed*, *Turn ended*, *Card died*. We do **not**
  split "asked a question" from "finished" — a plain-text question at end of turn is an
  indistinguishable `Stop`/`idle_prompt`, and MCP-elicitation splitting was deemed out of
  scope. `idle_prompt` and `Stop` both fold into *Turn ended*.
- **Card died** is a **new** notification — today a death produces no alert at all.

**Caveats (carried, not solved here):**

- Exact `message` strings and the idle timing are undocumented — irrelevant, since
  `notification_type` is the reliable key.
- **Codex** emits only `turncomplete → .waiting` (no permission/notification hooks). So on
  Codex cards, only **Turn ended** and **Card died** can ever fire; **Permission needed**
  simply never triggers. The design degrades gracefully — it does not assume Claude's hooks.

## Goals

1. Classify the *reason* a card enters `.waiting` (permission vs turn-ended) as a
   first-class, typed signal — not by parsing display text.
2. Notify on **Card died** transitions (new).
3. Per-trigger settings: each of the three triggers has
   - a **scope**: `Off` / `Background only` / `Always (foreground + background)`, and
   - a **sound**: one of the macOS system sounds, or `None` (silent banner).
4. Rework the Settings "Notifications" section into three trigger rows exposing the above.

## Non-goals

- No "asked a question" trigger, no MCP-elicitation handling.
- No custom/imported sound files — macOS system sounds only (the 14 in
  `/System/Library/Sounds` + `None`).
- No daemon-side notification config — notifications stay **client-local** (per-Mac
  `@AppStorage`), as today.
- No change to *when* a card actually goes waiting/dead; we only classify and surface it.

---

## Design

### Coupling model (explicit, up for veto)

**Scope governs whether a trigger fires and in what focus state — applied to the banner and
its sound as a unit. The sound picker chooses the noise (or silence).** Firing rule per
trigger, given `scope` and `NSApp.isActive`:

```
fire = (scope == .always) || (scope == .background && !isActive)   // .off → never
if fire:
    post banner (silent)               // presented in foreground too, when scope == .always
    if sound != .none: play sound      // NSSound, independent of the banner's own audio
```

This yields exactly the two requested axes: **when** (focus state, via scope) and **what
noise** (via the sound picker). "Only sound, no banner" is intentionally *not* a
combination — a firing trigger always shows a banner; silence it with `sound = None` if you
only want the visible cue, or set `Background only` to avoid foreground banners.

### Signal classification (daemon side)

Introduce a typed reason for the waiting transition.

- **New enum** (`Model.swift`):
  ```swift
  public enum WaitReason: String, Codable, Sendable { case permission, turnEnded }
  ```
- **New field** on `Task`: `public var waitReason: WaitReason?` — set on the report that
  transitions the card to `.waiting`; carried to clients on the normal `taskUpserted` event
  (the channel the app already consumes). Cleared when the card leaves `.waiting`. `nil` for
  any pre-existing card in an initial snapshot.
- **Adapter** (`ClaudeCodeAdapter.parse`, `notify` case): read `hook_event_name` +
  `notification_type` from the payload:
  - `Notification` + `permission_prompt` → waiting, reason `.permission`
  - `Notification` + `idle_prompt` (or any other type) → waiting, reason `.turnEnded`
  - `Stop` (no `notification_type`) → waiting, reason `.turnEnded`

  `StatusReport` gains a `waitReason` passthrough (snapshot half); `desc` still carries the
  human message for the card display, unchanged.
- **`OrchestraService+Report.report`**: when the snapshot sets `status = .waiting`, also set
  `task.waitReason`. When status leaves `.waiting` (`.running`/`.dead`/`.done`), clear it.
- **Codex**: `turncomplete → .waiting` sets reason `.turnEnded` (no permission signal).

`Card died` needs no new reason — it's the existing `→ .dead` transition (with `deadReason`
already on the task).

### Notifier (app side)

`AgentNotifier` is reworked from two global booleans to a per-trigger table.

- **Trigger enum** (app-side): `enum NotifyTrigger { case permission, turnEnded, died }`.
- **Prefs**, per trigger, in `UserDefaults`:
  - scope: `orch_notify_<trigger>_scope` → `off` | `background` | `always`
  - sound: `orch_notify_<trigger>_sound` → `none` | one of the 14 system sound names
- **Pure decision helper** (unit-testable, no AppKit):
  `func shouldFire(scope: NotifyScope, isActive: Bool) -> Bool`.
- **`notify(_ trigger:, task:)`**: look up scope+sound, apply `shouldFire`, post the banner
  and play the sound. Sounds are cached `NSSound` instances (retained so playback isn't cut
  off), rebuilt on change; `NSSound.beep()` fallback if a named sound fails to load.
- **Foreground banners:** implement
  `userNotificationCenter(_:willPresent:withCompletionHandler:)` to return `[.banner]` so a
  scope-`Always` trigger shows its banner even when Orchestra is frontmost. (Today, with no
  `willPresent`, macOS suppresses foreground banners — which is why sound had to be the
  "always audible" channel. This makes foreground visibility a real option.)

### Wiring (BoardModel)

`BoardModel.apply`, in the taskUpserted branch (currently ~284):

- `prev != .waiting && t.status == .waiting` →
  `notifier.notify(t.waitReason == .permission ? .permission : .turnEnded, task: t)`
- `prev != .dead && t.status == .dead` → `notifier.notify(.died, task: t)`

The existing startup/reconnect guards are reused verbatim: a freshly-appended card has
`prev == nil` (no notify), and the post-reconnect wholesale `tasks` set bypasses `apply`
(no notify). So a reboot sweep that marks cards `.dead` before the app connects does **not**
spam death banners — those arrive in the initial snapshot, not through `apply`.

Death → auto-resume (`dead → waiting`) will legitimately fire a **Card died** notification
then later a **Turn ended** one; acceptable (death is real and rare). Noted, not suppressed.

### Settings UI

Replace the two-toggle "Notifications" section in `SettingsView.swift` with three rows, one
per trigger, each: a **label + description**, a **scope menu** (`Off` / `Background only` /
`Always`), and a **sound menu** (`None` + the 14 system sounds), reusing the existing
themed `menu(...)` control. A small speaker affordance previews the selected sound on pick.

**Default scopes/sounds (fail-safe; roughly preserves today's feel):**

| Trigger | Default scope | Default sound | Rationale |
|---|---|---|---|
| Permission needed | Always | Submarine | Urgent — you're blocking the agent; hear it even when focused. |
| Turn ended | Background only | Submarine | Most frequent; a foreground chime every turn would nag. |
| Card died | Always | Sosumi | Rare + important; a distinct, attention-getting tone. |

Defaults apply only when the user has never touched a key (the existing
"`object(forKey:) ?? default`" pattern). No migration of the old
`orch_notify_waiting` / `orch_notify_sound` keys — they simply fall out of use.

---

## Testing

- **Adapter parse** (`ReportTests`): `Notification`+`permission_prompt` → `.waiting` /
  `.permission`; `idle_prompt` → `.waiting` / `.turnEnded`; `Stop` → `.waiting` /
  `.turnEnded`. Codex `turncomplete` → `.turnEnded`.
- **`report()`**: a waiting-causing patch sets `task.waitReason`; a subsequent
  running/dead/done patch clears it.
- **`shouldFire`** truth table: `{off, background, always} × {active, inactive}` → 6 cases.
- **UI/AppKit paths** (banner post, `NSSound`, `willPresent`) stay thin over the pure
  helpers and aren't unit-tested; verified manually via the isolated UI harness
  (`scripts/orch-ui-shot.sh`) for the Settings layout, and a live smoke test of each trigger.

## Files touched

| File | Change |
|---|---|
| `Sources/OrchestraCore/Model.swift` | `WaitReason` enum; `Task.waitReason` field (+ Codable) |
| `Sources/OrchestraCore/Model.swift` (`StatusReport`/`SnapshotReport`) | `waitReason` passthrough |
| `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift` | classify `notify` via `hook_event_name`/`notification_type` |
| `Sources/OrchestraCore/Agents/CodexAdapter.swift` | `turncomplete` → reason `.turnEnded` |
| `Sources/OrchestraCore/OrchestraService+Report.swift` | set/clear `task.waitReason` on status change |
| `App/AgentNotifier.swift` | per-trigger table, `shouldFire`, sound cache, `willPresent`, died path |
| `App/BoardModel.swift` | route waiting(reason)/dead transitions to `notify(...)` |
| `App/Views/SettingsView.swift` | three per-trigger rows (scope + sound menus) |
| `Tests/OrchestraCoreTests/ReportTests.swift` | classification + waitReason set/clear tests |

## Open questions for review

1. **Coupling model** — OK that a firing trigger always shows a banner, with `sound = None`
   as the way to get a silent visible cue? (Alternative: fully independent banner-scope and
   sound-scope per trigger — more matrix, more UI.)
2. **Default scopes/sounds** — the table above reasonable, or tune any?
3. **Death → auto-resume double-notify** — fine to let both fire, or suppress the death
   notification when an auto-resume is already pending?
