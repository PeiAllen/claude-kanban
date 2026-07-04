---
project: claude-kanban
feature: codex-wake-delivery
layer: 2
title: Implementation Plan
status: draft
created: 2026-07-03
updated: 2026-07-03
links: ["[[index]]", "[[01-design]]"]
---

# Layer 2 — Implementation Plan (folded contract + impl + tests)

> Single tight plan. The change is a **net subtraction**: delete the TUI pane-scraper, converge Claude &
> Codex onto one resume-seed wake handler, wire the Codex Stop hook (drain path already exists), flip two
> capability values, delete two now-dead enum variants. See [[01-design]] for the *why*.

## Final shape

| Concern | Before | After |
|---------|--------|-------|
| Idle wake | Codex: `sendKeys` nudge (scrape + blind keystroke) | **resume-seed** (`resumeInCard`), shared with Claude |
| Busy drain | Codex: none (`.sessionSeed`, no Stop hook) | **Stop hook** → `handleHook(.stop)` (already built) |
| Idle detection | pane-scrape (`isWorking`) | authoritative `task.status == .waiting` |
| Wake dispatch | 3 handlers (`sendKeysWake`/`resumeSeedWake`/break) | **1 handler** (`resumeSeedWake`) + a `watcherWillReinvoke` bool |
| `WakeTransport` | `nativeReinvoke·controlChannel·sendKeys·relaunch` | `nativeReinvoke·relaunch·controlChannel` (**`.sendKeys` removed**) |
| `InboxDrain` | `stopHook·sessionSeed·none` | `stopHook·none` (**`.sessionSeed` removed**) |

## Edits — by file

### Delete (dead after the converge)

| Target | File:anchor | Why dead |
|--------|-------------|----------|
| `CodexComposer` (whole file) | `Agents/CodexComposer.swift` | no wake reads the pane anymore |
| `Adapter.canNudge` — protocol req + default + doc | `Agents/Adapter.swift:56-59, 76` | only `sendKeysWake` called it |
| `CodexAdapter.canNudge` | `Agents/CodexAdapter.swift:107-110` | ″ |
| `sendKeysWake` + `sendKeysWakeNudge` | `OrchestraService+Wake.swift:100-117` | replaced by resume-seed |
| `SessionManaging.capture` + impl | `Protocols.swift:22`, `SessionManager.swift:145` | only caller was `sendKeysWake` (orch-test.sh uses tmux `capture-pane` via CLI — unaffected) |
| `WakeTransport.sendKeys` | `Agents/AgentCapabilities.swift:34` | no shipped adapter; caps aren't persisted (never in `Task`) so removal is safe |
| `InboxDrain.sessionSeed` | `Agents/AgentCapabilities.swift:40` | ″ (both agents now `.stopHook`) |

### Converge the wake (the merge)

`OrchestraService+Wake.swift` — one handler, gate the watchRegistry defer on a bool:

```swift
func wake(_ id: UUID) async {
    guard let t = await store.get(id), let adapter = try? registry.get(t.agentId),
          !t.archived, !recovering.contains(id) else { return }
    switch adapter.capabilities.wakeTransport {
    case .nativeReinvoke: await resumeSeedWake(t, watcherWillReinvoke: true)   // Claude: harness re-invokes on wait-exit
    case .relaunch:       await resumeSeedWake(t, watcherWillReinvoke: false)  // Codex: no reinvoke — resume even when watching
    case .controlChannel: break                                               // future: turn/start RPC (no relaunch)
    }
}

// generalized: Claude no-wait + Codex idle. The ONLY per-agent difference is `watcherWillReinvoke`.
func resumeSeedWake(_ t: Task, watcherWillReinvoke: Bool) async {
    guard t.status == .waiting, isResumable(t) else { return }
    if watcherWillReinvoke, watchRegistry[t.id] != nil { return }   // Claude: the wait-exit re-invokes; don't kill the wait
    recovering.insert(t.id)
    _Concurrency.Task { [weak self] in _ = try? await self?.resumeInCard(t.id, source: .daemon) }
}
```

Rationale for the bool (resolves L1 open-Q #1): the watchRegistry defer means *"something else will bring
this card back."* That "something else" is the harness re-invoke on a backgrounded `orchestra wait` exit —
**only Claude has it**. Codex has no reinvoke, so it must resume even when watching (killing a useless live
wait is correct — the wait would never have re-invoked it). This makes both `send` **and** reactive
delivery correct for Codex, and keeps `.nativeReinvoke`/`.relaunch` genuinely distinct (justifying two
values). `send`'s own targets aren't watching, so the two behave identically there.

### Flip capabilities

`Agents/CodexAdapter.swift:270-272` — `wakeTransport: .relaunch`, `inboxDrain: .stopHook`. Update the stale
comment at `:165` (Codex now *has* a Stop hook; the resume-seed fold stays as the F1/handoff + idle-wake
delivery, not "because there's no Stop hook").

### Wire the Codex Stop hook

`Resources/codex-hooks.json` **and** `Control/HooksRenderer.swift` `codexFallbackTemplate` — add:

```json
"Stop": [ { "hooks": [ { "type": "command",
  "command": "__ORCHESTRA_BIN__ _report --event stop --agent __AGENT_ID__" } ] } ]
```

Nothing else: `_report` (edge) already routes any `HookEvent` for the `--agent`; `handleHook(.stop)` →
`drainForStop` → `HookResponse(continuation:)` is adapter-free; `CodexAdapter.encode(.continuation)` →
`HookEnvelope.block` already emits `{"decision":"block","reason":…}`. Env (`ORCHESTRA_TASK_ID`/`SOCK`) is
already present (the `orient`/`session` hook uses it).

## Verbosity / merge audit (what the converge lets us collapse)

| Item | Action |
|------|--------|
| `sendKeysWake`, `sendKeysWakeNudge`, `CodexComposer`, `Adapter.canNudge`, `SessionManaging.capture` | **deleted** (above) |
| `resumeSeedWake` doc "nativeReinvoke wake (Claude)" | generalized to "resume-seed wake — Claude no-wait + Codex" |
| `wake()` switch | 3 arms → 2 arms + shared handler |
| `WakeTransport.sendKeys`, `InboxDrain.sessionSeed` | **removed** (dead variants) |
| `+Wake.swift` REVISIT note (`:62-66`) | rewrite: the `sendKeys` stopgap is gone; `controlChannel` remains the *no-relaunch* future (retires the resume-relaunch, not a scraper) |
| A1 freeze note (`AgentCapabilities.swift:6`) | record the two retirements (caps are computed from the adapter, never persisted → safe) |
| `inboxDrain` field | **kept but now purely descriptive** (both agents `.stopHook`, nothing branches). Flagged as a future removal candidate; out of scope to delete the field. |

## Loop-guard (resolves L1 open-Q #2 — no `UserPromptSubmit` for Codex)

`resetInjectCount` fires only on `ev.promptText` (`+Report.swift:51`), which **Codex never emits**
(`CodexAdapter.parse` produces no promptText; and it returns nil for `hooksPush`, so even wiring a Codex
`UserPromptSubmit` hook wouldn't reset it). It doesn't need to: the guard self-heals for Codex via —
1. `drainForStop` resets to 0 whenever the inbox drains empty (`OrchestraService.swift:399`);
2. a resume-seed wake drains the inbox unconditionally (`resumeInCard:113`), emptying it → next Stop resets.

So a stuck guard can't strand messages. **Decision: do not wire `UserPromptSubmit` for Codex.** Parity
option if ever wanted: an agent-neutral `case .userPrompt: resetInjectCount(...)` in `handleHook` + the
Codex hook — noted, not built.

## Tests

| File | Action |
|------|--------|
| `CodexComposerTests.swift` | **delete** (scraper gone) |
| `CodexWakeTests.swift` | **rewrite** to the resume-seed path: idle Codex `send` → `ensureArgv` has `resume` + folded inbox; `.relaunch` resumes **even when watching** while `.nativeReinvoke` defers; nudge assertions removed |
| `SendWakeTests.swift` | already covers resume-seed for `.nativeReinvoke`; add a `.relaunch` (watcherWillReinvoke:false) case, or parametrize by capability |
| Stop-hook drain (new) | `handleHook(ref, .stop, …)` for a `codex` card with a queued inbox → `HookResponse(continuation:)`; `CodexAdapter.encode` → block JSON (byte-identical to Claude) |
| Capability fixtures using `.sendKeys` | update → `.relaunch`/`.nativeReinvoke`: `AuthRateMonitorTests:14`, `AuthWarnSpawnTests:10`, `ParseTests:18`, `CapabilitiesTests:44,106`, `CodexAdapterTests:30` |
| `Stubs.swift` | remove `StubAdapter.canNudge` + `StubSessions.capture`/`setCapture` |
| `CapabilitiesTests` | assert Codex tuple is now `.relaunch` / `.stopHook`; assert `.sendKeys`/`.sessionSeed` no longer in `allCases` |

## Verification — isolated-daemon smoke (`scripts/orch-test.sh`)

Extend the harness with a **Codex-card variant** (seed `agentId: "codex"` + a fake `codex` bin that renders
an idle rollout and runs the installed `hooks.json`). Prove end-to-end against the real isolated daemon:
1. **Busy drain:** card `.running` → `send` → fake codex ends its turn → Stop hook fires `_report --event
   stop --agent codex` → daemon `drain` → pane/log shows the block-continuation with the inbox framing.
2. **Idle wake:** card `.waiting` → `send` → daemon resume-seeds → `ensure` argv shows `codex resume <sid>`
   with the folded inbox → delivered.
3. **No second-send needed:** a single `send` to an idle card delivers (the reported bug).

Unit/integration suites prove the logic; `orch-test.sh` proves the wiring (hook install, `--agent` bake,
socket round-trip, resume argv).

## Docs to update (in-sync convention)

- `notes/designs/agent-provider-interface.md` §8 — F3 table (Codex row = Stop hook, real) + rewrite the
  as-built REVISIT correction (sendKeys retired; wake = resume-seed; controlChannel = no-relaunch future);
  q10 note. Mirror into `agent-provider-interface/` layer docs where they name Codex `.sessionSeed`/`sendKeys`.
- `docs/` (auto-synced from main) — hook-channel + live-delivery sections.
- Code comments listed in the merge-audit table.

## Build order (one PR)

1. Wire Codex Stop hook + flip caps → **delivery works** (busy path testable immediately).
2. Converge wake (`resumeSeedWake` bool) + flip `wakeTransport` → **idle path works**.
3. Delete the scraper + dead variants + capture + fixtures → **cleanup**.
4. Tests + `orch-test.sh` Codex variant.
5. Docs.

## Decisions made

| Decision | Why | Rejected |
|----------|-----|----------|
| One `resumeSeedWake` + `watcherWillReinvoke` bool | The only Claude/Codex wake difference is defer-to-reinvoke | duplicate handlers; or a naïve single value that strands watching Codex cards |
| Remove `.sendKeys` **and** `.sessionSeed` | Both dead; caps aren't persisted → safe; user asked to cut cruft | keep as frozen forward-decls (they were *exercised*, now retired, not future) |
| Delete `SessionManaging.capture` | Only `sendKeysWake` used it | keep an unused protocol method |
| No `UserPromptSubmit` for Codex | Guard self-heals via empty-drain + resume-seed | wire a hook that (via nil `parse`) wouldn't even reset |
| Keep `inboxDrain` field (descriptive) | Just-merged design codified it; nothing branches | delete the field (out of scope) |
