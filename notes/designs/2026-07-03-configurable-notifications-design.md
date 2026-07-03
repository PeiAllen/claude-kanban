# Notifications, rethought

**Date:** 2026-07-03
**Status:** Design — awaiting user review
**Branch:** `update-notification-time`

## Problem

Notifications are hardcoded, coarse, and — worst — **noisy in the wrong moments**.
`App/AgentNotifier.swift` fires on one condition, a card flipping to `.waiting`, with two
global toggles: a background-only banner (`orch_notify_waiting`) and an always-playing
custom "Submarine" sound (`orch_notify_sound`).

Two things are wrong with that:

1. **No focus control.** Whether an alert fires when Orchestra is foregrounded vs
   backgrounded is baked in (banner=bg-only, sound=always), not user-settable.
2. **The "waiting" signal is polluted.** The card flips to `.waiting` — and thus alerts —
   *every* time the agent ends a turn, including when it merely yielded to await a
   **background task** (a `run_in_background` shell, a background subagent, a `/loop` wake)
   that will **auto-resume** it. The user isn't needed there; the alert is pure noise.

## What the signals actually support (research)

The `.waiting` transition is driven by two Claude Code hooks that Orchestra collapses into
one `notify` event (`claude-hooks.json` lines 20–25 both call `_report --event notify`).
Confirmed against the official Claude Code hooks docs:

- The **`Notification`** hook carries a **`notification_type`** field — `permission_prompt`
  when the agent needs tool approval, `idle_prompt` when it's done and waiting on you. Clean
  discrimination, no message-text matching.
- The **`Stop`** hook (agent turn ended) carries, since **Claude Code v2.1.145**, a
  **`background_tasks`** array (`{id, type, status, description, …}` — type ∈ shell /
  subagent / monitor / workflow / teammate / cloud session / MCP task) and a
  **`session_crons`** array (scheduled `/loop` / `ScheduleWakeup` / `CronCreate` wakes).
  **Non-empty ⇒ the agent paused on background work and will auto-resume — it is *not*
  waiting on the human.** This is the authoritative fix for problem #2. Orchestra already
  receives this payload (Stop pipes stdin to `_report`), so no new plumbing is needed.
- A session death (`SessionEnd` exit/logout, or a liveness-poll vanish) sets `status =
  .dead` — a distinct transition that today raises **no** alert.

**Caveats, carried not solved:** exact notification `message` strings and the idle timeout
are undocumented (we don't need them — `notification_type` and the arrays are the keys);
`background_tasks`/`session_crons` need CC ≥ v2.1.145 (older ⇒ graceful fallback below);
**Codex** emits only `turncomplete → .waiting` (no permission hook, no background-task
introspection), so Codex cards can only ever reach *Needs you* / *Died*.

## The model

**A notification is a macOS notification, raised only when the agent needs *your*
attention.** Three attention events, each independently configurable with a single dial.

| Trigger | Raised on | Default scope |
|---|---|---|
| 🔐 **Permission** | `Notification` / `permission_prompt` | **Always** — you're blocking the agent |
| 🙋 **Needs you** | `Stop` with **empty** `background_tasks` **and** `session_crons` (agent genuinely done), or `Notification`/`idle_prompt` | **Background only** — most frequent; don't nag when you're watching |
| 💀 **Died** | `status → .dead` | **Always** — rare + important |

**Scope dial** (per trigger): `Off` · `Background only` · `Always (foreground + background)`.
Firing rule, given the trigger's `scope` and `NSApp.isActive`:

```
fire = (scope == .always) || (scope == .background && !isActive)   // .off → never
```

**No sound configuration.** A notification is posted with the system default sound
(`UNNotificationSound.default`); *whether* and *how* it chimes is governed by the user's
macOS Notification / Focus settings — not by Orchestra. This deletes the entire former
sound axis (picker, `NSSound` cache, silent-banner coupling question). To make foreground
`Always` alerts both show and chime, the notifier implements
`userNotificationCenter(_:willPresent:)` returning `[.banner, .sound]` (today, with no
`willPresent`, macOS suppresses foreground banners — which is why the old design needed a
separate always-on `NSSound`).

## Design

### Signal classification (daemon side)

Introduce a typed reason for a waiting transition.

- **New enum** (`Model.swift`):
  ```swift
  public enum WaitReason: String, Codable, Sendable { case permission, humanTurn }
  ```
- **New `Task` field:** `public var waitReason: WaitReason?` — set on the report that moves
  the card to `.waiting`, carried to clients on the normal `taskUpserted` event, cleared
  when the card leaves `.waiting`. `nil` for any card in an initial snapshot.
- **`ClaudeCodeAdapter.parse`, `notify` case** — branch on the payload:
  - `hook_event_name == "Notification"`:
    - `notification_type == "permission_prompt"` → `.waiting`, reason `.permission`
    - otherwise (`idle_prompt`, …) → `.waiting`, reason `.humanTurn`
  - `hook_event_name == "Stop"`:
    - `background_tasks` non-empty **or** `session_crons` non-empty → **return `nil`**
      (no status change → the card **stays `.running`**; option **A**, see below). No alert.
    - both empty (or absent) → `.waiting`, reason `.humanTurn`
  - `desc` still carries the human `message` for the card, unchanged.
- **`StatusReport` / `SnapshotReport`** gain a `waitReason` passthrough (snapshot half).
- **`OrchestraService+Report.report`** sets `task.waitReason` when a snapshot moves the card
  to `.waiting`; clears it when status leaves `.waiting` (→ running/dead/done).
- **`CodexAdapter.parse`**: `turncomplete → .waiting`, reason `.humanTurn` (no permission
  signal, no background-task introspection available).

`Died` needs no reason — it's the existing `→ .dead` transition (`deadReason` already on the
task).

**Background-wait handling is option A:** a Stop with pending background work returns `nil`,
so the card **remains `.running`** for the duration of the wait — accurate (work is genuinely
ongoing, and it will auto-resume) and it never falsely advertises "needs you." When the
background work completes, the agent auto-resumes (running) and its next genuine Stop (empty
arrays) flips it to `.waiting` + *Needs you*. Accepted edge: if the agent truly finishes but
left a lingering never-ending background monitor (e.g. `tail -f`), the card can sit at
`.running` rather than `.waiting`; rare, and preferred over a false alert. The F3 Stop-drain
(`ReportHelper`, keyed on `hook_event_name == "Stop"`) is independent of parse and keeps
working for every Stop.

### Notifier (app side)

`AgentNotifier` reworked from two global booleans to a three-row scope table.

- `enum NotifyTrigger { case permission, needsYou, died }`,
  `enum NotifyScope: String { case off, background, always }`.
- One pref per trigger: `orch_notify_<trigger>_scope`. Defaults: permission `.always`,
  needsYou `.background`, died `.always` (applied via `object(forKey:) ?? default`, as today).
- **Pure decision helper** (unit-tested, no AppKit):
  `func shouldFire(_ scope: NotifyScope, isActive: Bool) -> Bool`.
- `notify(_ trigger:, task:)` → look up scope, apply `shouldFire`, and on fire post a
  `UNNotificationRequest` (`content.sound = .default`, `userInfo["taskId"]`, body from the
  trigger). Click handling (activate + select card) is unchanged.
- Add `willPresent` → `[.banner, .sound]` so `Always` alerts surface in the foreground.
- Delete the `NSSound` member, `soundKey`, `bannerKey`, and `playSound()`.

### Wiring (`BoardModel.apply`, taskUpserted branch, ~284)

```
if prev != .waiting, t.status == .waiting {
    notifier.notify(t.waitReason == .permission ? .permission : .needsYou, task: t)
}
if prev != .dead, t.status == .dead {
    notifier.notify(.died, task: t)
}
```

The existing startup/reconnect guards are reused verbatim: a freshly-appended card has
`prev == nil` (no alert), and the post-reconnect wholesale `tasks` set bypasses `apply`. So a
reboot sweep that marks cards `.dead` before the app connects does **not** spam death alerts —
those arrive in the initial snapshot, not through `apply`. A `dead → waiting` auto-resume
will legitimately raise *Died* then later *Needs you*; accepted (death is real and rare).

### Settings UI (`SettingsView.swift`)

Replace the two-toggle "Notifications" section with three rows — Permission needed, Needs
you, Card died — each a label + one-line description + a scope menu (`Off` / `Background
only` / `Always`), reusing the existing themed `menu(...)` control. No sound controls. A
short helper line notes that the alert sound follows macOS Notification settings.

### Graceful degradation

- **Claude Code < v2.1.145** (no `background_tasks`/`session_crons`): a Stop can't be
  classified as a background-wait, so it falls back to *Needs you* — i.e. today's behavior
  (the pollution returns, but nothing breaks).
- **Codex cards**: only *Needs you* / *Died* ever fire, and *Needs you* is **correct** with no
  suppression — Codex's background shell commands and subagents both resolve *within* a single
  turn (subagents run synchronously; background shells are polled in-turn), and the local CLI
  has no self-scheduler, so a Codex `task_complete` reliably means the human is waited on
  (verified against the OpenAI Codex docs, June 2026). The only auto-resume analog is the
  Codex **desktop app's "Automations"** (heartbeat/cron thread re-wakes) — an external
  scheduler that routes to Codex's own Triage inbox; it's undocumented whether those runs even
  reach the local `~/.codex/sessions` rollout Orchestra tails, and Orchestra doesn't support
  Codex-app automations today, so they're out of scope.

## Testing

- **`ReportTests` (adapter):** `Notification`+`permission_prompt` → `.waiting`/`.permission`;
  `idle_prompt` → `.waiting`/`.humanTurn`; `Stop` empty arrays → `.waiting`/`.humanTurn`;
  `Stop` with a `background_tasks` entry → `nil`; `Stop` with a `session_crons` entry →
  `nil`; Codex `turncomplete` → `.waiting`/`.humanTurn`.
- **`report()`:** a waiting-causing patch sets `task.waitReason`; a following
  running/dead/done patch clears it.
- **`shouldFire`** truth table: `{off, background, always} × {active, inactive}` (6 cases).
- **AppKit paths** (`UNUserNotificationCenter`, `willPresent`) stay thin over the pure
  helpers; verified manually — Settings layout via `scripts/orch-ui-shot.sh`, and a live
  smoke of each trigger (incl. a background-wait producing no alert and no `waiting` flip).

## Files touched

| File | Change |
|---|---|
| `Sources/OrchestraCore/Model.swift` | `WaitReason` enum; `Task.waitReason` (+ Codable); `waitReason` on `StatusReport`/`SnapshotReport` |
| `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift` | classify `notify` via `hook_event_name` / `notification_type` / `background_tasks` / `session_crons` |
| `Sources/OrchestraCore/Agents/CodexAdapter.swift` | `turncomplete` → reason `.humanTurn` |
| `Sources/OrchestraCore/OrchestraService+Report.swift` | set / clear `task.waitReason` on status change |
| `App/AgentNotifier.swift` | per-trigger scope table, `shouldFire`, macOS default sound, `willPresent`, *Died* path; drop `NSSound` |
| `App/BoardModel.swift` | route waiting(reason) / dead transitions to `notify(...)` |
| `App/Views/SettingsView.swift` | three per-trigger scope rows; remove sound toggle |
| `Tests/OrchestraCoreTests/ReportTests.swift` | classification + `waitReason` set/clear tests |

## Settled decisions (from the design dialogue)

1. **No custom sound** — a notification is a macOS notification; its sound is the user's
   macOS/Focus setting.
2. **Background-wait = option A** — the card stays `.running` (no `waiting` flip, no alert)
   while awaiting background work, keyed off `background_tasks` / `session_crons`.
3. **Three triggers, one scope dial each**; defaults Always / Background / Always.
