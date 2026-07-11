---
project: claude-kanban (Orchestra)
feature: live-wake-delivery
layer: 1
title: Initial Design — No-restart live wake + reliable send delivery
status: draft
created: 2026-07-10
updated: 2026-07-10
links: ["[[index]]", "[[../codex-wake-delivery/01-design|codex-wake-delivery]]", "[[../agent-provider-interface|agent-provider-interface]]", "[[../first-class-hooks/01-design|first-class-hooks]]", "[[../lifecycle-convergence-design|lifecycle-convergence]]"]
---

# Layer 1 — Initial Design: No-restart live wake + reliable send delivery

> The **what**, not the how. Today, waking an idle card **kills and relaunches its agent session**
> (`resumeSeedWake` → `resumeInCard` → `kill + claude --resume` / `codex resume`). That relaunch is
> the jank the user reports: the UI blanks, sends get dropped, and Codex "often doesn't get woken."
> This redesign replaces restart-based wake with **in-place delivery** — a per-session control channel
> the daemon pushes into — and fixes the three independent defects hiding behind "janky send/wake."
> Supersedes the deferred `controlChannel` seam named in [[../agent-provider-interface|agent-provider-interface]] §8
> and the `codex-wake-delivery` relaunch cost.

## Purpose & problem

`send` to a card enqueues to a durable inbox (`Inbox.swift`) and calls `wake` (`OrchestraService.send`,
`OrchestraService.swift:516`). If the agent is **busy**, the **Stop hook** drains the inbox at turn-end as
a `decision:block` continuation — clean, in-session, no restart (F3, works). The pain is entirely in the
other two cases, which decompose into **three independent defects**:

### The three defects behind "janky send/wake"

**Defect 1 — waking an idle agent requires killing its session.** For *both* agents, `wake` →
`resumeSeedWake` → `resumeInCard` → `resume` **kills the tmux session and relaunches** the agent with
`--resume` / `codex resume`, folding the inbox into the opening turn (`OrchestraService+Wake.swift:98-131`,
`OrchestraService+Recovery.swift:55-141`). This is the "restart a card" the user hates: seconds of
relaunch, full replay, and the flakiness of resume (timeout, session-vanished, trust races).

**Defect 2 — the wake path drops sends (data loss + silent no-ops).** Three distinct ways a `send` is lost:
- **Drain-before-confirm data loss.** `resumeInCard` **drains the durable inbox** (`+Recovery.swift:138`)
  and folds it into a resume seed *before* the resume is confirmed live. If the resume then fails (Claude
  confirm timeout `+Recovery.swift:103`; Codex process dies right after `ensure`, whose success is treated
  as confirmation via `.relaunchLiveness`), the drained messages are **gone** — folded into a turn that
  never ran. This is a literal "send disappeared."
- **Provisional / never-prompted strand.** A `send` to a freshly-spawned or just-restarted card that has
  never run a turn has no transcript → `isResumable` is false → `resumeSeedWake` returns at its
  `.waiting && isResumable` gate (`+Wake.swift:124`) → the message sits until a human types.
- **Codex idle-lag no-op.** Codex idle is detected from the 2 s rollout-tail poll, so a `send` arriving in
  the lag window sees a still-`.running` card and `wake` no-ops; delivery depends on a later turn that may
  never come.

**Defect 3 — the macOS terminal can't survive its session being killed.** `AgentTerminalView`'s
`processTerminated` is a **no-op** (`AgentTerminalView.swift:173`), the SwiftUI view `.id` is keyed on the
tmux session *name* (stable across a kill+recreate, `InspectorView.swift:372`), and there is no re-attach
path. So when any lifecycle op recreates the session, the pane goes **black until the user reselects the
card**. iOS auto-reconnects (`IOSTerminalView.swift:302-351`); macOS does not. Because *every* wake
recreates the session (Defect 1), the live terminal dies on **every** send to an idle card — this is the
"UI temporarily breaks."

### Plus a Codex-specific reason the busy path is dead too

Empirically (Codex `0.142.5`), the clean **busy-path Stop drain never even runs** on the live machine, for
two independent reasons — so Codex has *neither* a working busy path nor a clean idle path:
- **Hook-trust modal.** This Codex build trust-gates hooks; the interactive TUI blocks on a *"Hooks need
  review"* modal that Orchestra never answers, so hooks run **disabled** (or the session stalls).
- **Stale `hooks.json` never replaced.** `CodexHooks.installIfSafe` (`CodexHooks.swift:21`) only overwrites
  a file containing the newer `session` sentinel; a pre-change file (with the retired `orient` hook) is
  treated as a foreign user file and left in place, so the current 3-hook file (with `Stop`) is **never
  installed**.

### The reframe

The single reliable "wake a live process without a restart" primitive is a **per-session control channel
the daemon pushes into**. Both agents now have one (via different transports), so we can retire
restart-for-wake instead of hardening it:

| Job | Replaced by | Empirically verified |
|-----|-------------|---------------------|
| Wake an idle **Claude** card (kill + `--resume`) | **Channel push** — the `orchestra-mcp` stdio bridge advertises `claude/channel` and emits `notifications/claude/channel`; the daemon pushes the inbox item over the existing control socket → injects a new turn in-place | **Yes** — real `claude` 2.1.206, idle→turn, **PID unchanged**, ~2 s |
| Wake an idle **Codex** card (kill + `codex resume`) | **blocking Stop-hook park** (near-term, TUI-preserving) *or* **App Server `turn/start`** (long-horizon control channel) | both **verified** — park keeps the TUI free; `turn/start` costs the attached TUI |
| Drain the inbox safely | Drain **after** delivery is confirmed, not before the resume | design change |
| Survive a session recreate in the UI | Per-launch **epoch** in the terminal `.id` + a `processTerminated` re-attach (port the iOS reconnect to macOS) | design change |

## Empirical evidence (every mechanism tested against the real binaries)

Per the "empirically test every feature" mandate. Versions: **Claude Code 2.1.206**, **Codex 0.142.5**.

| Mechanism | Result | Status |
|-----------|--------|--------|
| **Channel wakes idle Claude, no restart** | Idle pane + external POST → new turn answered, **PID 26236 unchanged**, ~2 s | ✅ EMPIRICAL |
| **Channel coalesces while busy** | 2 msgs 71 ms apart delivered into the running turn, both reached context | ✅ EMPIRICAL |
| **Orchestra Swift MCP can advertise `claude/channel` + wake idle claude** | Minimal Swift server on the vendored swift-sdk (0.12.1) advertised `claude/channel`, accepted by real claude 2.1.206 (`/mcp` connected), woke an idle agent from a separate process, **PID unchanged**. SDK patch = **3 lines** (one optional `experimental: [String:Value]?` on `Server.Capabilities`; synthesized Codable carries it; omitted when nil). `orchestra-mcp` then passes the capability + defines the notification + triggers `server.notify` over the existing control socket. | ✅ EMPIRICAL |
| **Claude parked Stop-hook holds session, typing OK** | Composer stays live, typed text uncorrupted, Enter **queues** + auto-submits on release; same `session_id` | ✅ EMPIRICAL |
| **Claude Stop-hook default timeout** | ≥400 s (a 400 s hook completed, not killed); `timeout` field shortens; no override needed for a multi-minute park | ✅ EMPIRICAL |
| **Claude `decision:block` continuation** | Continues in-session, new turn on the `reason`; renders as a red "Stop hook error" (cosmetic); model injection-defense can refuse spoofed-"SYSTEM" text → use neutral wording | ✅ EMPIRICAL |
| **Claude `nativeReinvoke` from idle prompt** | Background task completes (any exit code) → harness auto-reinvokes into a new turn from a genuinely idle prompt, **PID unchanged** | ✅ EMPIRICAL |
| **Reinvoke preserves a human draft** | Unsubmitted draft stayed intact across the reinvoke turn, submitted cleanly after | ✅ EMPIRICAL |
| **`background_tasks`/`session_crons` in Stop payload** | Present natively in the Stop-hook stdin JSON | ✅ EMPIRICAL |
| **Wake-only latches at turn-end** | No Stop/reinvoke during permission prompt, plan-mode, compaction, fresh session, post-`/clear` | ✅ EMPIRICAL |
| **Codex Stop hook `decision:block` + park** | TUI + `exec`: `decision:block` starts a fresh turn; an 8 s hook parked the turn 8.1 s; `stop_hook_active` flips true on the continuation | ✅ EMPIRICAL |
| **Codex has NO auto-reinvoke** | No harness re-invoke concept; only no-restart in-process wake is a blocking hook | ✅ EMPIRICAL |
| **Codex "won't wake" root cause** | Hook-trust modal + stale-`hooks.json` install bug → Stop hook never runs → inbox never drains | ✅ EMPIRICAL |
| **Codex idle detection markers** | `task_complete`/`turn_complete` → `.waiting` (rollout tail, 2 s poll) | ✅ EMPIRICAL |
| **Codex App Server `turn/start` no-restart wake** | `turn/start` on an idle loaded thread → new turn, **same PID** (5 turns); `turn/steer` ~3 ms coalesce, `turn/interrupt` ~86 ms. A real control channel — no park needed | ✅ EMPIRICAL |
| **Codex app-server + attachable TUI** | Plain `app-server` (stdio/unix) is **single-client** (can't co-host JSON-RPC + a `--remote` TUI). Multi-client co-drive needs the `remote-control` **broker**, whose socket is **Noise-encrypted, not plain JSON-RPC** (only Codex's own `--remote` completes it). So: Option A (Orchestra owns app-server, renders UX from the event stream, no attached TUI) or Option B (broker + `--remote` SwiftTerm TUI, but implement the Noise handshake) | ✅ EMPIRICAL |
| **TUI + automation co-presence is a known upstream gap** | Transport-specific: **stdio/unix are single-client**; **WS is multi-client but "experimental/unsupported"**, and even there stock co-presence event fanout is incomplete — open **RFC [#21551]** (3-file fanout patch, unmerged, no maintainer reply) + issues [#24398]/[#25914]/[#11166]. The TUI is *already* an app-server client (in-process), so the ecosystem is converging on "everything is an app-server client." **Option A sidesteps co-presence entirely** (sole client, render from the event stream); only Option B depends on the unmerged fanout. | ✅ WEB (openai/codex) |
| **`nativeReinvoke` general idle wake + re-arm friction** | Auto-reinvoke reliable (5 cycles, PID stable, ~4–5 s) **but the agent must re-arm a background wait every turn** or it goes permanently dormant. → model-cooperation burden; channels preferred as the *primary* Claude path, nativeReinvoke reserved for the watcher/orchestrator pattern | ✅ EMPIRICAL |
| **Channel-consent auto-accept at spawn** | 3/4 startup dialogs config-skippable (`hasTrustDialogAccepted`, `bypassPermissionsModeAccepted`, `enableAllProjectMcpServers`); the dev-channels warning has no config flag → one `Enter`/launch via the existing `tmux send-keys` choreography (content-match — bypass-warning default is *exit*) | ✅ EMPIRICAL |

## Goals / non-goals

**Goals**
- **Retire restart-for-wake.** An idle `send` delivers in-place — no `kill + resume` — for both agents.
- **Never drop a send.** Remove from the durable inbox **only after** the agent has provably received it.
- **Fix the macOS terminal** so a session recreate (from any lifecycle op) re-attaches instead of going black.
- **Restore Codex's busy-path drain** (hook-trust + stale-file install) — a cheap, high-impact quick win.
- **Stay agent-agnostic behind the `wakeTransport` capability seam** — Claude and Codex both work; no
  `if agentId` in core (project rule: design for every agent).
- **Keep the native TUI.** No headless/app-server viewer that drops the SwiftTerm terminal, unless the
  Codex app-server probe proves a TUI can attach.

**Non-goals**
- **Not** the lifecycle-convergence state-machine rewrite (single `Phase` + `transition()` + epoch) — that
  is [[../lifecycle-convergence-design|its own approved design]] and is the structural backstop for the
  variable races underneath; this design layers on top and can land before or after it.
- **Not** removing resume-seed — it stays as the **cold fallback** (session dead, not resumable, channel
  unavailable, park expired).
- **Not** changing the durable inbox / Stop-drain payload semantics or caps.
- **Not** adopting the Claude Agent SDK streaming mode (drops the interactive TUI — empirically confirmed
  no in-session injection for interactive sessions).

## Scope (layered so quick wins ship first)

| Layer | Item | Status vs lifecycle-convergence |
|-------|------|---------------------------------|
| **A — Codex quick wins** | (1) Launch/resume Codex with `--dangerously-bypass-hook-trust` (Orchestra authors the hooks, so they're trusted by construction); (2) fix `CodexHooks.installIfSafe` to recognize + overwrite any retired-sentinel Orchestra file (incl. `orient`). Restores the clean busy-path Stop drain immediately. | ✅ **Independent — ship now.** `CodexHooks.swift` is unchanged on `orch/lifecycle-convergence`; only a minor textual overlap possible in `CodexAdapter` argv (~L232/262). *Synergy:* convergence uses the Codex `SessionStart` hook as its launch Ready-signal, which the same trust bug disables — so this likely **unblocks** the convergence Codex path. |
| **C — macOS terminal reconnect** | Port the iOS reconnect to `AgentTerminalView` + per-launch **epoch** in the terminal `.id`. | ⛔ **SUBSUMED — do NOT build here.** Already in flight: PR6b (`lc/6b-ui-displaystate`) Task 6.5 created `Sources/OrchestraUI/DesktopTerminalPolicy.swift` (+ tests) and wires `processTerminated`; the per-launch epoch is core to the convergence phase model. Depend on convergence for the UI-break fix. |
| **B — Reliable at-least-once delivery** | **(1) Drain-after-confirm:** remove from the inbox only once delivery is *confirmed* (not before resume — today's drain-before-resume loses messages on a failed relaunch). **(2) Delivery reconciler:** a periodic level-triggered sweep re-drives delivery for any idle card with a non-empty inbox + no delivery in flight, with **backoff** and a "delivery-stuck" surfaced state — so a raced/no-op'd wake (recovering-guard, provisional strand, Codex idle-lag, restart-didn't-fire) is retried, not stranded forever. `send` becomes a **ConvergenceVerb** (enqueue intent → reconcile to empty). | 🔁 **Stack on top of convergence** — this IS the convergence reconciler model (persisted intent + idempotent re-drive). `+Recovery.swift`/`+Wake.swift` rewritten there; build B on the new `Phase`/epoch/reconciler + verb contract. |
| **D — Claude no-restart wake** | `orchestra-mcp` bridge advertises `claude/channel`; daemon→bridge push over the control socket emits `notifications/claude/channel`. New `wakeTransport` case; resume-seed becomes the cold fallback. `nativeReinvoke` (wait-inbox) as the non-preview alternative. | 🔁 **Stack on top of convergence.** Model it as a fast **MutationVerb** in the new verb contract (not a ConvergenceVerb relaunch); phase+epoch gate "is there a live session to push into?". |
| **E — Codex no-restart wake** | **Near-term:** blocking **Stop-hook park** (TUI-preserving, reuses the SwiftTerm-on-tmux model, needs only Layer A's hook-trust fix) — no-restart for sends within the hook window, resume-seed cold fallback. **Long-horizon:** **App Server `turn/start`** control channel (Option A: Orchestra owns app-server + renders UX from the event stream; unlocks `steer`/`interrupt`) — the real Codex `controlChannel`, but it costs the attached codex TUI. (Option B — broker + Noise handshake to keep the TUI — deprioritized: fragile, auto-updating binary.) | 🔁 **Stack on top of convergence** (same as D). |

### Relationship to lifecycle-convergence (card `345675`)

The in-flight **card-lifecycle-convergence** redesign (`orch/`/`impl/lifecycle-convergence`, orchestrator card
`345675`) is the structural foundation this work sits on:
- It **already delivers Layer C** (mac terminal reconnect via `DesktopTerminalPolicy` + the per-launch epoch)
  — so this design **drops Layer C**.
- It **rewrites the wake/recovery core** (`+Wake`/`+Recovery`, deletes `recovering`, adds `Phase` + funnel +
  epoch + reconciler + the QueryVerb/MutationVerb/ConvergenceVerb contract). Layers **B/D/E must be designed
  against that merged model**, where the no-restart wake becomes a clean fast MutationVerb (in-place channel
  push / `turn/start`) with resume-seed as a ConvergenceVerb cold fallback — rather than a rework of today's
  `resumeSeedWake`.
- **Layer A is independent** of all of the above and can ship as a small standalone fix immediately (and
  helps convergence's Codex Ready-signal).

**Revised sequencing:** ship **A** now → let **lifecycle-convergence land** (delivers C + the Phase/epoch/verb
foundation) → then **B/D/E** as the next layer on top.

## Expected behaviour

One durable inbox; delivery is **in-place** for a live session and **fallback-relaunch** only when there is
no live session to push into:

| Card state at `send` | Claude path | Codex path |
|----------------------|-------------|------------|
| **Busy** (`.running`) | Stop hook drains at turn-end (unchanged) | Stop hook drains at turn-end (once Layer A restores it) |
| **Idle, live session** (`.waiting`) | **Channel push** injects a turn in-place (no restart) | **App Server `turn/start`** or **parked Stop hook** (no restart) |
| **Idle, no live session** (dead / not resumable / channel not attached) | resume-seed relaunch (cold fallback) | resume-seed relaunch (cold fallback) |
| **Never-prompted / provisional** | delivered on its first turn's Stop; guaranteed (Layer B) | same |

The inbox item is removed **only** after the channel/turn-start/drain confirms receipt (Layer B) — a failed
push leaves it durable for the next attempt, so no send is ever lost.

## Parked Stop-hook — verified properties & design requirements (the Codex near-term wake)

Empirically settled (Claude 2.1.206 decisive; Codex 0.142.5 tracking the same, final 18-min hold pending):

| Property | Finding | Design requirement |
|----------|---------|--------------------|
| **Max block / day-long idle** | **No hard cap** — a hook blocked **19m32s** with `timeout:86400`, past the 600s doc ceiling; limit = the configured `timeout` only. **Default (no timeout) caps at exactly 600s then SILENTLY drops to idle.** | **Always set a large explicit `timeout`** (e.g. a week). Never rely on the default. |
| **Daemon-restart survival** | A **reconnect loop inside the hook** survived the daemon bouncing — reconnected and kept parking. | The `_report --event stop` long-poll must **reconnect** to the daemon UDS on disconnect (retry loop), so a park survives orchestrad restarts (satisfies "agents outlive daemon restart"). |
| **Passive viewing** | Select/attach/capture-pane do **NOT** disturb the park; only real stdin touches the composer, and even a keystroke doesn't release it (release is external). | Release keys on **genuine input/attention**, never on selection/glance — a glance is always safe. |
| **User input during park** | Typing queues uncorrupted; Enter queues (doesn't interrupt); auto-submits on release (~0.6 s). **Both agents queue** (Codex is *not* composer-blocked — earlier suspicion refuted). | Deliver the user's queued turn by **releasing on real input** (sub-second); no input is lost. |
| **Spurious release** | Releasing an empty park → **~0.1–0.3 s to genuine idle, no turn runs, state untouched.** | An accidental release is free and stateless — worst case the next send takes the cold path; the card **auto-re-parks at its next turn-end**. |
| **Visibility** | A parked card shows a busy spinner (*"running stop hook · 19m"*) — **indistinguishable from real work by pane text.** | Orchestra **must track park-state out-of-band** (it owns the hook) and render a parked card as **idle**, not infer from the spinner. |
| **Loop guard** | `decision:block` re-fires Stop with `stop_hook_active:true` (both agents) — a flag, not a hard cap. | Keep the existing `maxConsecutiveInjects` discipline for *content* injects; the park hold itself is one block, not a re-inject loop. |

## Restart kills in-flight background work — a further cost of resume-wake + a hard guard

A kill+resume wake destroys the agent's **background work** — `run_in_background` Bash tasks (children of the
pane) and Claude **background subagents** (in the `claude` process). None of it is in the transcript, so
`--resume` does NOT restore it. This is a *further* argument for no-restart in-place delivery (channels /
parked-hook / Stop-drain never kill the process, so background work always survives).

**Claude — SAFE (empirically verified).** resume-seed only fires on `.waiting`, and `ClaudeCodeAdapter.parse`
(`ClaudeCodeAdapter.swift:79-87`) keeps a card **`.running`** when `background_tasks`/`session_crons` is
non-empty. A background subagent **does** populate `background_tasks` — as `{"type":"subagent","status":
"running","agent_type":…}` (verified, claude 2.1.207) — and Orchestra's check is a **type-agnostic non-empty
test**, so it covers `"shell"` *and* `"subagent"`. A synchronous subagent also holds the turn `.running`. So
no Claude subagent (background or sync) is ever killed by a resume-wake. *(Lock it in with a one-line test
asserting the check stays type-agnostic — a future `type=="shell"` filter would silently regress it.)*

**Codex — the residual gap.** Its rollout-tail telemetry has **no "background work in flight" signal** —
`turn_complete` → `.waiting` regardless — so (a) a Codex card with background work is exposed to a resume-kill,
and (b) we can't even *detect* the background work to apply the guard below. One more reason Codex should lean
on **in-place delivery** (busy-drain / parked-hook), not the restart.

**Hard guard (design requirement):** the delivery reconciler / clean-restart fallback must **never restart a
card that has live background work** — respect `hasBg`/`.running`; defer and deliver **in-place** (or wait for
genuine idle). A restart is only safe once there's nothing background to lose. (Enforceable for Claude via
`background_tasks`; for Codex, absent a signal, prefer in-place and treat restart as last-resort.)

## Delivery-stuck state — who gets told (and how)

When the delivery reconciler (Layer B) can't deliver after backoff (X dead / won't resume), surface it via
**targeted existing seams — never a board-wide broadcast** (pushing "X is stuck" into every inbox wakes
uninvolved cards and burns turns). Note: cards coordinate two ways (both first-class per `delegation-skill.md`
— pick one per child): **`wait`** (you're woken on the child's conclusion — orchestrator fan-out, still
actively used) vs. **`send`-back** (the child sends a result message; no wait). This split shapes who can be
auto-notified:

| Audience | Channel | Why |
|----------|---------|-----|
| **The human — PRIMARY / universal** | A **card-level "delivery-stuck" state** on X (badge + configurable-notification) + the pending inbox **inspectable with retry/clear** | The only catch-all that works regardless of coordination pattern: whoever is blocked on X gets unblocked when the human intervenes. Reuses `deadReason`/status + notifications. |
| **Cards `wait`-ing on X — bonus** | **Conclude-as-failed to X's watchers** via `concludeCard`/`watchRegistry` | Nearly free (channel exists); unblocks a `wait`-ing orchestrator and fixes the known *"dead(spawnFailed) never concludes → parent wait hangs forever"* bug. But only reaches `wait`-users, so it's a bonus, NOT the main mechanism. |
| **`send`-back / request-response counterparties** | *nothing automatic* → rely on the human state above | They aren't registered as waiting on X (just sent + expect a reply), and attribution can't tell a blocked-requester from a fire-and-forget sender. The human-visible stuck state is the backstop. |

**Discipline:** retry **quietly** through transient races (recovering guard, idle-lag) with backoff; only flip
the visible stuck state + notify + conclude-waiters once it's clearly **not self-healing** (N failures /
dead-and-unresumable). Don't cry wolf on a 2 s race.

**Net:** the parked hook meets the "idle a day · never a timeout drop · never a restart · survives daemon
restart · glance-safe" bar, with two must-dos: **(1) set a large explicit timeout**, and **(2) track
park-state out-of-band and render parked-as-idle**. Release is keyed on **real input**, so viewing never
disturbs it and an accidental release is free.

## App Server Option A — costs vs the tmux+CLI baseline (a deliberate long-horizon bet, NOT taken now)

**Decision (2026-07-10): we are NOT taking the app-server bet.** Codex's no-restart wake is the **parked
Stop-hook**; app-server Option A stays documented as a future option only. This section records *why* — the
concrete features the current tmux+CLI model gives for free that Option A would trade away. (Note: this
asymmetry is **Option-A-only** — the Claude channel path and the Codex parked-hook path both keep the
tmux+CLI model fully intact.)

| Property (tmux+CLI today) | How tmux gives it | What Option A costs |
|---------------------------|-------------------|---------------------|
| **Agents outlive daemon restart** | `tmux -L orchestra` is an independent server; agent processes live in it; orchestrad reconciles via `tmux list-sessions` | Regresses if the app-server is an orchestrad **stdio child** (dies with the daemon). Only preserved by running a **separate durable `codex app-server daemon`** + reconnect/`thread/resume` logic — new supervised-process machinery. History survives either way (rollout-`.jsonl`-backed), but the **live in-flight turn** is more fragile. |
| **Agents outlive app restart** | The Mac app is just a viewer of the daemon | Comparable *if* orchestrad relays the event stream + re-hydrates via `thread/read` — but that's new relay/render plumbing. |
| **Native interactive UI for free** | SwiftTerm attaches to the pane → the agent's real TUI (approvals, plan mode, slash commands, input editor, scrollback, colors, sixel) | Orchestra must **reimplement the whole interactive agent UI** from `item/*`/`turn/*`/approval events and chase every new CLI feature. Richer/structured, but a large permanent surface. |
| **Immunity to agent-UI changes** | tmux proxies bytes; never breaks when the CLI UI changes | Couples Orchestra to the **v2/experimental JSON-RPC protocol** (`experimentalApi`-gated), whose managed daemon **auto-updates its binary** — a moving target. (Counter-force: the app-server is Codex's strategic surface; the TUI is already an in-process app-server client.) |
| **One uniform model** | Every card = a tmux pane you attach to (mac terminal, iOS SSH `nc -U`, takeover lease, shell tabs, `send-keys` approvals, `capture-pane`) | A **second UI model** for Codex only → every one of those surfaces needs a Codex-specific path. The hidden bulk of the cost. |
| **TUI + automation co-presence** | N/A (tmux is the UI; automation is `send-keys`) | A **known upstream gap** — RFC openai/codex#21551 (unmerged fanout patch); multi-client only over the "experimental/unsupported" WS transport. Option A *sidesteps* it (sole client) but Option B depends on it. |

**Verdict:** Option A buys a structured protocol (steer/interrupt/inject, richer rendering, alignment with
Codex's direction) at the price of survivability-for-free, the native TUI, agent-UI-change immunity, and one
uniform model. Worth funding only when those protocol upsides are wanted enough to build a Codex-specific UI
stack — hence long-horizon, not now.

## Diagrams

### Today (the jank)

```mermaid
flowchart LR
  Send([send]) --> Enq[(durable inbox)]
  Send --> Wake{wake · idle?}
  Wake -->|idle| RS[resumeSeedWake]
  RS --> Drain[drain inbox → seed]
  Drain --> Kill[kill tmux session]
  Kill --> Relaunch[claude --resume / codex resume]
  Relaunch -.resume fails.-> Lost[[messages LOST]]
  Kill -.macOS.-> Black[[terminal goes black]]
```

### Target (in-place delivery)

```mermaid
flowchart LR
  Send([send]) --> Enq[(durable inbox)]
  Send --> Wake{wake · transport?}
  Wake -->|Claude: channel| Bridge[orchestra-mcp bridge]
  Bridge -->|notifications/claude/channel| CS[live Claude session · same PID]
  Wake -->|Codex: turn/start or parked hook| CX[live Codex session · same PID]
  Wake -->|no live session| RS[resume-seed · cold fallback]
  CS -->|ack| Deq[remove from inbox AFTER receipt]
  CX -->|ack| Deq
  Enq -.stays durable until ack.-> Deq
```

## Decisions made (so far)

| Decision | Why | Rejected |
|----------|-----|----------|
| In-place **control-channel** wake per agent, not a hardened relaunch | The only reliable no-restart wake; empirically proven for Claude channels (PID-stable) | Harden resume-seed; keystroke/send-keys nudge (already retired as flaky) |
| **Channels** for Claude, hosted **inside `orchestra-mcp`** | Reuses the existing per-session stdio bridge + its control-socket link; no Node process | A separate Node channel server per session (extra dependency/process) |
| Keep resume-seed as the **cold fallback** | A dead/unresumable/unattached session has nothing to push into | Remove it (no fallback for cold sessions) |
| **Drain-after-confirm** | The current drain-before-resume is a real data-loss path | Keep folding into an unconfirmed seed |
| **Fix macOS terminal reconnect** as its own layer | The UI break is independent of the wake transport and helps every lifecycle op | Only address it via "fewer restarts" |
| **Codex hook-trust + stale-file** fixed first | Cheap, high-impact; restores the clean busy path independent of everything else | Bundle into the big wake rewrite |
| Behind the `wakeTransport` capability seam | Project rule: agent-agnostic; channels are Claude-only, app-server is Codex-only | `if agentId` branching in core |

## Open questions — need your call / pending probes

- [x] **Codex clean path — RESOLVED (with a UX cost Claude doesn't have).** App-server `turn/start` is a real
  no-restart control channel (proven), but plain app-server is single-client and the multi-client broker is
  Noise-encrypted — so a `turn/start` wake **costs the attached codex TUI** (Option A: Orchestra renders from
  the event stream) or a **Noise-handshake impl** (Option B). Recommendation: **parked Stop-hook near-term**
  (keeps the SwiftTerm-on-tmux TUI, needs only Layer A), **app-server Option A as the long-horizon upgrade**
  (unlocks steer/interrupt, when Orchestra is ready to render Codex from structured events). *Asymmetry to
  accept:* Claude channels keep the TUI for free; Codex's control channel does not.
  **Web research (2026-07-10) reinforces A over B:** TUI+automation co-presence (Option B) is a *known,
  unmerged* upstream gap — RFC [openai/codex#21551] (multi-subscriber fanout patch, no maintainer reply),
  and multi-client only works over the "experimental/unsupported" WS transport (stdio/unix are single-client).
  Option A needs none of that (sole client), and the TUI is already an in-process app-server client, so
  owning the app-server is with the grain of where Codex is heading.
- [ ] **Channels research-preview risk.** Channels are a Claude research preview (flag/protocol "may
  change"), needing `--dangerously-load-development-channels` + consent auto-accept. Acceptable behind the
  capability seam with `nativeReinvoke`/resume-seed fallbacks? Or prefer `nativeReinvoke` (no preview
  dependency) as the *primary* Claude path and channels as the upgrade? *(Consent-accept probe running.)*
- [x] **`nativeReinvoke` re-arm friction — RESOLVED.** Empirically, staying wakeable **requires the agent to
  re-arm a background wait every turn** (no re-arm → permanently dormant). That model-cooperation burden
  settles the Claude primary as **channels** (external push, no re-arm); `nativeReinvoke` stays for the
  watcher/orchestrator pattern where a wait is naturally live; resume-seed is the cold fallback.
- [x] **Sequencing / relationship to lifecycle-convergence — RESOLVED (2026-07-10).** Verified against the
  live branches: **Layer A is independent** (`CodexHooks.swift` unchanged on convergence) → ship now.
  **Layer C is subsumed** by convergence PR6b (`DesktopTerminalPolicy` + epoch) → drop it. **Layers B/D/E
  overlap the convergence wake/recovery rewrite** (`+Wake`/`+Recovery`, `recovering` deleted) → build them on
  top of the merged `Phase`/epoch/verb model, not today's `resumeSeedWake`. Order: A → convergence → B/D/E.
