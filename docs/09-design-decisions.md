# 9. Design decisions

This chapter records the *why* behind Orchestra — the cross-cutting principles that shape the system,
and the history of the shipped feature PRs. It is the durable record of those decisions; the mechanisms
they produced are detailed across [chapter 2](02-architecture.md) through [chapter 7](07-app-ui.md).

## Cross-cutting principles

### Thin clients, single coordinator

The daemon runs the one `CommandRegistry` and the `OrchestraService` actor; the app, CLI, and MCP
bridge each serialize calls independently and converge at the server. Commands go in, events come out.
There are no distributed state machines and no per-client truth — a spawn from the CLI updates the app's
board because both subscribe to the same event stream (see the [control-plane data flow](02-architecture.md)).

### Federated ground truth, not in-memory state

The daemon does not treat its memory as authoritative. **`tasks.json`** holds metadata, **tmux** is the
authority on liveness, and **git** is the authority on the worktree. This is what makes recovery robust:
the daemon (or the whole machine) can restart and reconstruct reality from disk + `tmux ls` + git,
rather than losing track of running agents.

### The phase funnel: one writer, epochs, and capability-gated readiness

A card's lifecycle is **one persisted variable** — `Task.phase` — with **one writer**, the
`transition()` funnel. This is the *lifecycle-convergence* redesign (Stage 2 of a multi-stage build; the
funnel and phase model are detailed in [the Convergence model](02-architecture.md#the-convergence-model)),
and it replaces the ad-hoc `status`/`waitReason`/`dead` triple that three code paths used to write independently.
The decisions that shape it:

- **One writer, one concluder.** Every mover routes its phase change through `transition()`
  (`OrchestraService+Lifecycle.swift`), which validates the edge against a pure `isLegalEdge` machine
  (spec §P1), stamps `phaseChangedAt`, bumps the epoch, and fires conclusions — all in one place, so the
  legal-edge invariant, staleness fencing, and `wait`-resolution can't drift across call sites. A
  companion `mutate:` closure lets a caller land companion field-writes (a fresh session id, cleared dead
  metadata) **atomically in the same store patch** as the phase change. `report()`'s former direct
  conclude is deleted — the funnel is the sole concluder, so a card never double-concludes; `Conclusion`
  gained a **`deadReason`** so a suspended `wait` resolves on *every* terminal death (crash/reboot/
  resume-fail → `.exited(reason)`), not only a clean exit (the bug-#2 fix), while `isConcluded` is exactly
  "phase is terminal."
- **Epochs make staleness deterministic.** `sessionEpoch` is a monotonic per-card generation the funnel
  bumps once on every (re)launch-bound entry, stamped into the session env as `ORCH_EPOCH` (agent-agnostic)
  and echoed back by the agent's hooks / readable via `tmux show-environment`. A signal (late hook, liveness
  poll) carries the epoch it observed; a superseded epoch is dropped by the funnel's fence — a late signal
  is *provably* harmless rather than heuristically ignored. A pre-upgrade **nil-epoch** kill signal can't be
  fenced, so it must pass a fresh liveness probe before it may kill a card. Epochs also absorb the old
  `recovering` set's grace-window role (its narrow atomic-claim role became the `relaunchClaimed` set).
- **Being-born readiness is a capability, not an identity branch (the D1 resolution).** How a `launching`
  **or** `relaunching` card is confirmed alive is one adapter axis — `AgentCapabilities.readinessConfirmation`
  ∈ `{sessionStartHook, rolloutMeta, relaunchLiveness}` — covering *both* being-born phases (generalizing
  the spec's launch-only `resumeConfirmation`). Claude confirms via its SessionStart hook (startup for a
  launch, resume for a relaunch); Codex confirms a fresh launch via its rollout `session_meta` line
  (time-scoped to the launch), and a `codex resume` — which writes no rollout — is caught by a **universal
  N=3 liveness-tick fallback** that keeps the relaunch on the readiness gate rather than landing it live
  immediately. `relaunchLiveness` treats a successful `ensure` as the confirmation for an agent that emits
  no marker at all. No `if agentId ==` anywhere. This generalizes the spec's launch-only
  `resumeConfirmation` as a deliberate **spec amendment**.

**Stage 2 kept spawn/resume/restart/reopen synchronous** (they walked the phases inline) so the phase
enum + funnel + epochs landed correctly first; the reconciler, the four phase-steppers, and non-blocking
spawn shipped in PR4b (Stage 4) — built once against the settled Stage-2 model rather than twice. Every
`Convergence`-kind verb is intent-only now: see [the Convergence model](02-architecture.md#the-convergence-model).

### `report()` vs the launch intent: `pendingModel` and the epoch fence

The [`--model` re-seat](05-command-reference.md#the---model-re-seat) exposed a structural collision between
the two writers of a card's `model`. The telemetry path (`report()`) **owns** `model` — it mirrors whatever
model the agent's own statusline names — and that write is *not* epoch-fenced. But `restart`/`resume`/
`handoff` are **intent-only** verbs: they persist the intent and return, so the *outgoing* session stays
alive and reporting for a reconcile tick or two before the stepper kills it. Written naively, the re-seat
would set `task.model` and the dying session's last statusline would revert it — and the relaunch would
come up on precisely the model it was trying to leave.

The fix is to keep the **launch intent in a field the report path does not own**: `pendingModel`
(mirroring `pendingSeed`), which is absent from `applyReportFields` and is what `finishLaunch` builds the
argv from. `model` is still written eagerly so the board reflects the re-seat at once, but nothing depends
on it surviving; the `.live` landing re-asserts it from the intent. A stale report can no longer erase the
override, rather than merely being unlikely to.

The same asymmetry needed a second guard on the *other* side. `.relaunching → .live` is a legal edge, and
report()'s phase write is only epoch-fenced when the report is **stamped** (Codex's file-tail reports carry
no epoch). An unstamped report from the still-dying session could therefore land the card `.live` **before
the stepper ever claimed it** — no stepper visits a live card, so the relaunch would never run and the
staged `pendingSeed`/`pendingModel` would strand on a card quietly still running its old session. So a
report may only land a card that **still owes a launch** if it is stamped with the current generation, and
only such a report may **consume** the intent. The daemon happened to be safe already, but only because
`reconcile()` runs before `pollTelemetry()` in the same tick — an ordering coincidence, not a guarantee.
The fence makes the invariant explicit and fails safe: when in doubt, don't land, and don't consume.

### Card naming: the title is the SSOT

The **card title leads and the agent session's name follows.** A card is named at spawn from its own
identity, by a strict ordered chain: a **worktree** card takes its **branch** (that branch *is* the card's
identity, so it wins even when a human typed a prompt); a **read-only branchless** card takes
`👁 <the title of the worktree card whose directory it borrowed>` — a glyph rather than the word "review",
because the primitive is read-only *access*, not a role; otherwise the **prompt's** first line; and failing
all of those, the **directory** the card runs in. A **seed is never a title source**, which is the point of
the change: delegated cards used to be named after the first 60 characters of whatever context their parent
handed them, which is exactly when a good name matters most.

The last arm exists because a seeded card is never `awaitingFirstPrompt` — the seed *is* its first turn — so
a placeholder there could never be replaced by a later prompt. Its directory is the one identity it has.

Three **explicit** sources outrank every default and **pin** the title against re-derivation: `spawn`'s
`title` parameter, the `set-title` verb, and a human's in-session `/rename` mirrored back. `set-title` is an
Orchestra verb rather than an agent command because **neither Claude nor Codex can rename its own live
session** — the naming primitive has to live where the board is.

Two mechanisms make the round trip safe:

- **Push** — every launch and resume passes the card's *current* title as `claude --name`, including the
  startup-abort retry, which re-launches from a stored context and so must have its name refreshed from the
  live card rather than reusing whatever the aborted launch captured.
- **Mirror** — the `session_name` a statusline reports is adopted only when it is a **delta** against the
  last name we saw, and only from the **current generation**. Both halves are load-bearing. Nothing can
  rename a *live* Claude session from outside (the SDK's rename touches disk only), so a session keeps
  echoing the name it launched with forever: a mirror keyed on "differs from the title" re-applied that
  stale name on the next statusline tick and silently undid every `set-title`. And because `restart` bumps
  the epoch while the outgoing session is still alive and still reporting its old name, the predecessor
  would otherwise look like a rename of the incoming generation. The baseline is armed at launch, before
  the session can report, so even a card renamed *during* a bring-up survives its new session's first tick.
  A session launched by a pre-epoch daemon reports no epoch and so keeps its mirror inert until it next
  relaunches — the fail-safe direction, and self-healing.

Drift between a live session's name and its card is therefore accepted and heals at the next relaunch.

**Codex push is deferred.** The app-server `thread/name/set` call that would push a title into a live Codex
thread is not built, because app-server integration has not merged; Codex cards are named on the board and
gain session-name push when that lands. Nothing here is Claude-specific by design — the mirror is inert for
Codex simply because Codex reports no session name.

Splitting `titleProvisional` was the precondition for all of it. That one flag meant both "the title is a
default" and "this card has never had its first genuine prompt", and only the second meaning is
load-bearing: `deriveLaunchFlavor` reads it to blank-launch a card with no positional, and the wake ladder
and delivery-stuck gates read it as "there is still a route to revive this card." Naming moved to
`titleSource`, the lifecycle flag was renamed to `awaitingFirstPrompt`, and both are now generation-fenced
where they are mutated — a stale prompt hook from a superseded session could otherwise clear the flag on the
incoming generation and strand the card `.resumeFailed`.

### `desc` vs `note`: volatile status vs durable narrative

A card carries two one-liners because they answer different questions and have different lifetimes.
`desc` is what the agent is doing **this second** — the report pipeline overwrites it on every snapshot,
and `restart`/`/clear` blank it. `note` is what the card **is**: "Wave 2/4 — lease/claim delivery". It is
written only by an explicit source (`spawn(note:)` / `set-note`), telemetry never touches it, and it
survives restart, clear, and handoff.

Overloading `desc` with both was the obvious shortcut and the wrong one — it is the same two-meanings
trap `titleProvisional` fell into, where one field meant both "a default title" and "never prompted", and
only untangling them made either meaning safe to reason about. Narrative in `desc` would be erased by the
next tool call, which is precisely when a human scanning the board most wants it.

Clients render `note ?? desc` on the card's second line (`Task.cardLine`, defined on the model so the Mac
and iOS boards cannot drift). The authored line wins: `desc` is blank between turns and after a restart
anyway, so falling back to it only when there is no note costs nothing and gains a board that still says
what each card is for when every agent is idle.

### The Stage-2 wire break: `status` → `phase`

Stage 2 is a **deliberate clean break** in the wire and on-disk model, not a compatibility layer.
`status`/`waitReason` are removed from `Task`, and **`AgentStatus` is deleted from the wire entirely**:
`SnapshotReport` now carries `run: RunState?` (the agent's observed `.running`/`.waiting(reason)`) instead
of a `status`/`waitReason` pair, and clients render from a new **non-wire, non-Codable `PhaseDisplayKey`**
derived from `phase` on demand (so the display vocabulary can evolve without touching the durable model).
The **only** backward-compat kept is the **one-time on-disk migration** that reads a pre-Stage-2
`tasks.json`: it lives inside `Task.init(from:)` (the card's own tolerant decoder, superseding the plan's
separate `LegacyStoredBoard`), maps the legacy triple to `phase` fail-safe (nil/unknown status →
`.dead(.rebootUnrevived)`, an idle card's absent wait reason → `.humanTurn`, preserving `deadReason`), and
drops a record only when its `id` is absent or its `phase` value no longer decodes (the sole current such
value is a legacy `.dead(.completed)`, after that case's clean-break removal — see the
[note below](#done-is-not-observable--success-is-agent-signalled-not-inferred)) — with the store's
element-wise `FailableTask` load so a single undecodable record self-drops rather than stranding the whole
board to `.bak`. The full mapping table and
fail-safe rules are in [chapter 3](03-data-model.md#schema-migration--the-one-time-statuswaitreason--phase-mapping).
This follows the project's *prefer breaking changes over compatibility shims* stance: break the wire, but
never nuke on-disk state.

### "Done" is not observable — success is agent-signalled, not inferred

The daemon's only completion signal is `turnCompleted` ("a turn ended, idle"), identical for "finished the
assignment" and "paused between turns" — so "done" is not observable, and the old inference that set a
finished read-only reviewer to `.dead(.completed)` retired live cards merely waiting for instruction. It is
gone: a finished reviewer idles `.live(.waiting(.humanTurn))` like any card, and **success is
agent-signalled** — the delegate `send`s its result and the orchestrator `archive`s the card. Death stays
observable (any `.dead` reason concludes `.exited`); archive is the only `.done`; `orchestra wait` resolves
only on a real conclusion (merge/archive/death), never on a delegate finishing its work.

`DeadReason.completed` is removed outright — a clean on-disk break, no migration: a stored
`{"phase":{"name":"dead","detail":"completed"}}` record no longer decodes and self-drops (accepted — none
existed). The `wait`/`watch` subsystem stays but dormant; excising it is deferred.

### Done is DECLARED: `merge-request` and `needs-input`

Because done is not observable (above), the states that matter are **declared** by the agent and recorded
by the daemon. Two verbs carry that, and both are shaped by the same rule: a declaration an agent could
retract is one it will forget to retract, so the agent only ever *asserts*, and the daemon owns retirement.

**`merge-request` is the singular ship verb.** One instruction, for every parent kind — *when your work is
ready, `merge-request` and stop* — and the daemon routes it. A live card owning the parent branch is
nudged, and re-nudged on a backoff, to squash-merge and run `shipped`; approval is delegated by
construction inside a launched tree. An **unowned** target — `main`, a bare local branch, a remote parent,
or no parent link at all — is *recorded and nothing else*: no inbox message, no re-nudge loop, no
`mergeStalled` escalation, because there is no agent to consume any of it. The human reads the badge and
integrates however they choose, and **how approval is executed stays outside Orchestra's design** — which
is why guidance teaches no second path. `borrow` and publishing a stacked PR remain primitives a human can
direct; taught as ship steps they were a four-way fork the agent had to resolve from `tree` output before
it could say it was finished, which is exactly the routing decision that is not its business.

Ownership is **derived, never stored** — the oldest live non-archived card on the parent branch — because
it *changes underneath a pending request*. So one function re-derives it at every edge that can move it:
the verb, the daemon-boot rebuild, each re-nudge tick, and the treeStat funnel. That last one is
load-bearing in the unowned → owned direction: without it a request recorded while unowned goes silent the
moment a card takes the parent branch, because the human's "no owner" predicate stops matching while the
new owner was never told. In the other direction, an owner archived mid-request does **not** retract the
declaration — the badge stays and only the loop stops, since the work is still ready and is now a human's
to land.

**`needs-input` declares a block.** An agent that ends its turn waiting on a decision only the card's
owner can make is, from the board's side, indistinguishable from an idle card — so it says so, in one
line, and the card can surface it. The verb is set/replace with **no clear form**; it is scoped to the
*end* of a turn, so an agent whose harness offers an in-session choices prompt still uses that mid-turn —
`needs-input` is the complement (the question that outlives the turn, and the only option for a backend
with no such prompt), never a replacement.

Retirement is keyed to **proof that the question is moot**, never to an intent, and there are exactly two
proofs. The first is the next turn starting: a landing into `live(.running)` from anywhere that is not
already running and is not a permission wait — an approval resumes the *same* turn, so a question declared
earlier in it must survive. The second is a queued inbox batch being **handed back as a Stop
continuation**, which is not redundant with the first: a Claude card given an injected answer that way
resumes the same session with no `UserPromptSubmit`, and if it replies in prose it calls no tool either,
so it reports `.running` never and crosses no phase edge.

That second seam is keyed to the **claim** — the moment the payload is handed over — and the distinction
is load-bearing in both directions. Keying it to the delivery *receipt* instead is wrong, because a
stop-drain batch is confirmed on the Stop that **ends** the continuation turn, which is precisely when an
agent that has run out of road declares its question: the receipt would erase the declaration a beat after
it was made, on both backends. And the opposite rule — clear on any dispatch — is wrong for the relaunch
path, where the seed is leased *before* the launch runs, so a failed launch would erase a question no
agent ever saw. The relaunch path needs no seam of its own: its `.live` landing out of `.relaunching` is a
completed session replacement, which is a third clear (alongside an id rollover and `/clear`), and those
are generation-fenced so a dying session's late signal cannot erase what the incoming one declared.
Nothing else clears it; selection cannot, because glancing at a question is not answering it.

The turn-start proof carries one **transport fence**, because how a turn-start reaches the daemon differs
by backend. Claude pushes it synchronously through a hook, so it is applied in order and clears
unconditionally. Codex's turn-start is a line in a rollout file the daemon **polls**, so a line *written*
before a declaration can be *applied* after it — a stale poll that would erase a question it predates. The
declaration therefore carries its own `declaredAt`, and a turn-start retires it only when the turn-start
evidence is newer. The comparison is a genuine cross-source one — the rollout line's own write time (its
`seq`, stamped in epoch µs) against the daemon's clock at the declaration — sound because both are one
host's wall clock and the line-write causally precedes the tool call that declares. That comparison lives
in `report()`, where the evidence timestamp is in scope; the phase funnel, the sole phase writer, is left
reasoning about phases, not clocks, and handles only the unconditional session-replacement clear. The two
fields travel as one `PendingQuestion` value so a clear can never drop the text while keeping the stamp —
and `declaredAt` is persisted as **fractional Unix seconds**, never through the store's `.iso8601` date
strategy, which rounds to the whole second. That rounding would be a correctness bug across a restart: the
rollout tailer replays from offset 0, so a reloaded declaration whose sub-second part was lost could be
beaten by a pre-declaration line and wrongly cleared. A malformed persisted value drops only the question,
never the card (a `try?` decode) — the field is new on this branch and only ever lands on `main` as this
struct, so there is no cross-version migration, just card-preservation against a dev daemon's interim
state.

### Terminal bytes bypass the daemon

The control plane carries commands, state, and events — never PTY bytes. SwiftTerm and the CLI's
`shell`/`inspect` attach to **tmux directly**. This keeps the daemon simple and the terminals fully
interactive and real-time.

### Transcript images are published, opaque, and session-scoped

Images are the deliberate exception to the rule above: an agent's screenshot or plot has to reach a human
looking at a phone, and PTY bytes can't carry it. The shape of that exception is the decision.

**Publishing is an explicit agent action, never a parser.** The tempting design is to watch terminal output
for anything path-shaped and offer to preview it. That would make every string an agent prints a
potential read primitive against the agent's filesystem, aimed at whatever the *agent* chose — so the
feature is an [explicit verb](05-command-reference.md#registry-commands), `publish-image`, and the daemon
re-reads and re-validates the bytes itself (magic-number sniff, regular files only, bounded per-image and
per-session). The agent's path is consumed at publish time and never crosses back to a client.

**The caption is constrained at the boundary, so nothing downstream has to sanitize.** The caption doubles
as the filename each client stages, which makes agent-authored text into a path — the classic place to
grow three subtly-different sanitizers (daemon, macOS, iOS) and audit them forever. Instead
`TranscriptImageCaption` makes the bad input unrepresentable: letters, digits and dashes, alphanumeric
ends, 80 bytes. Everything downstream then uses `reference.caption` verbatim. The specific choices are
each load-bearing: **dashes only inside**, because a leading dash yields `-foo.png`, which every Unix tool
reads as flags; **ASCII only**, which bans `/`, `:` and leading dots, and — the subtle one — Unicode
*format* characters like `U+202E RIGHT-TO-LEFT OVERRIDE`, which are category `Cf`, not `Cc`, so a
control-stripping filter passes them through to spoof a filename's visible extension; and ASCII also makes
the length cap **byte-exact**, closing the gap where a Character-counted cap (120 emoji ≈ 480 bytes)
overruns `NAME_MAX`. A malformed caption is **rejected, not rewritten**, because a silently-cleaned
caption would desync the label the agent believes it published from the filename the human saves. The rule
is advertised as `pattern`/`maxLength` on the MCP tool schema *and* enforced in the handler, from one
shared definition — the registry dispatches on `phaseGate` and validates params against no schema, so the
advertised contract would otherwise be unenforced.

**The reference is opaque.** What lands in the transcript is an OSC 8 hyperlink carrying a bare UUID; the
client resolves it through the app-only [`media`](05-command-reference.md#server-only-built-in-methods)
call. No filesystem location crosses the boundary in either direction, so activating a link can't open an
arbitrary path and a leaked reference is worthless off-box. `media` is app-only for the same reason
`diffText` is — an agent that wants an image already has it on disk.

**Lifetime follows the session, not the file.** Published media is scoped to the card's current
[session epoch](04-cards-worktrees-sessions.md#recovery-resume-and-restart) and dropped by the phase
funnel: a new epoch clears prior epochs, an archive intent clears the card. Media therefore can't outlive
the transcript that references it, and a stale reference degrades to "expired" rather than to someone
else's image.

**Guidance rides the shared bundle, not the adapters.** The instructions that teach an agent to publish are
one `AgentGuidance` section, so Claude receives them as a project skill and Codex as launch-scoped
developer instructions from the same source, with no `if claude` branch (see
[the adapter capability descriptor](04-cards-worktrees-sessions.md#agent-adapters)).

### The OS previews images, on both clients

Both clients hand a published image to QuickLook — `QLPreviewPanel` on the Mac, `QLPreviewController` on
the phone — rather than rendering it themselves. Zoom, pan, share, Open-with, full screen and
Esc-to-dismiss all come free, and a published image behaves like every other image on the device. The only
thing a hand-built viewer buys is *anchoring* — a preview tethered to the reference's coordinate, which a
shared floating panel can't be — and that isn't worth its weight, nor even desirable: a preview that dies
when you scroll is one you can't read the transcript beside. So the Mac panel stays up until Esc or a card
switch. Its placement is QuickLook's: a preview panel exposes no resting-position API
(`sourceFrameOnScreenFor` is the zoom-animation origin, not a placement) and overwrites `setFrame` during
its own open layout, so the app doesn't fight it — QuickLook remembers where the user drags it.

The asymmetry that remains is storage lifetime, and it is about who else holds the file. QuickLook
previews a *file*, so both clients stage bytes on disk. iOS deletes on dismiss: QuickLook is in-process
and hands off to no one, and iOS purging tmp when the app isn't running covers the crash case. macOS
cannot, because `Open with` gives the file to *another application* that may still be reading it — so the
Mac keeps a write-only spool in its temporary directory, swept at two coarse boundaries (the whole spool
at launch, a card's subdirectory on archive) rather than by an eviction policy. Nothing is ever read back
from it, so it is not a cache and has no hit rate to protect; and deleting a file another app already
holds open is safe regardless, since unlink keeps the inode alive for its open descriptors.

### iOS in-process SSH rides Network.framework (NIOTransportServices), not POSIX sockets

The iPhone can't fork/exec the system `ssh`, so its SSH client is in-process (swift-nio-ssh). The
connection is dialed by a single chokepoint — `IOSSSHSession.connect()`, which both the board's control
channel and every terminal PTY multiplex over — so the socket layer is chosen in exactly one place. That
place uses **NIOTransportServices** (`NIOTSEventLoopGroup` + `NIOTSConnectionBootstrap`, backed by
`NWConnection`), **not** NIO's POSIX/BSD-socket stack (`MultiThreadedEventLoopGroup` + `ClientBootstrap`).

The reason is cellular. On iOS a raw BSD socket does not bring up or select the **cellular** data
interface — Apple routes cellular (and is VPN/Tailscale-aware) only through Network.framework. A POSIX
dial therefore goes **dead-silent on cellular** (it emits zero SYNs and hangs on "Connecting…") while
working instantly on WiFi; the symptom looked like flakiness but was WiFi-vs-cellular all along. NIOTS's
default `NWParameters` allow cellular, and we deliberately impose no interface restriction, so the same
session now dials over whatever path is up. NIOSSH runs identically over either channel, so **only the
socket layer changed** — the tailnet-shape guard (blind host-key acceptance is safe only because the
target must be a `100.64.0.0/10`/`*.ts.net` tailnet address), the pubkey/accept-any-host-key delegates,
the error-close tail handler, and the connect-once/dedup (`connectGen`) logic are all untouched.

The whole iOS app target uses NIOTS **unconditionally** — no `#if canImport(Network)` fallback and no
universal-bootstrap indirection — because App-iOS is iOS/iPadOS-only (no Catalyst) and both device and
Simulator always have Network.framework, so a POSIX branch would be permanently dead code. The macOS
desktop is unaffected: it shells out to `/usr/bin/ssh` via `SSHMaster`, a separate path.

### State is pushed through a two-way hook channel

Live card fields (`ctxPct`, `desc`, run-state, session id, title) are **pushed by the agent** via a
managed Claude Code `--settings` file (statusLine + hooks → `orchestra _report`), not scraped from the
pane. The channel is bounded (a stalled daemon can't freeze the agent's status bar) and seq-guarded (a
stale `ctxPct` can't overwrite a fresh one); pane capture is a fallback only. The same channel is the
backbone for the planned Orchestra → agent context injection.

### Ownership: Orchestra deletes only what it made

Cleanup is decided by `origin`:

- **`worktree`** — Orchestra created it; archive removes the dir (kept if it holds unsaved work, and only when no other
  live worktree card shares it — see [the WorktreeRegistry](#the-worktreeregistry-materialized-markers-on-demand-siblings-persisted-borrows)
  below for the exact removal policy, including that a `dead`-but-not-yet-`archived` sibling still counts
  as "shares it").
- **`scratch`** — Orchestra created it; archive **unconditionally** `rm -rf`s it (double-gated by the
  `origin == .scratch` check *and* a runtime prefix check under the scratch root).
- **`borrowed`** — *you* created it; archive never touches it.

This clean rule removes any ambiguity about which cleanup is safe.

### Garbage-collecting derived per-card files

Both adapters — and `inspect` — write a small **derived per-card file outside the worktree**, in a
directory Orchestra owns, regenerated on every launch: Claude's managed `--settings`
(`$dataDir/card-settings-<djb2(cwd)>.json`), Codex's launch profile
(`$CODEX_HOME/orch-<djb2(cwd)>.config.toml`, which carries ~16KB of developer instructions off the tmux
argv — see [one seed, four topologies](#one-seed-four-topologies) for why it can't be inlined), and the
read-only inspect settings (`$runtimeStateDir/readonly-<shortId>.json`). None was reaped, so they
accumulated one-per-card forever — and because the name is a hash of a **reused** worktree path, a stale
file could be silently inherited by a later card at the same path.

They're reaped by **one fail-safe sweep** (`sweepCardFiles`) that runs at daemon boot (the backlog and
any crash residue) and after a card's teardown-kill (steady state). The sweep never inverts a filename
back to a card; instead it **forward-computes the keep-set** — every live (non-archived) card's token —
and reclaims only files outside it. This makes the shared-cwd case safe for free (two cards on one cwd
share one file; it survives while either is live) where a per-card delete would have needed its own
live-sibling check.

Guards keep it from ever deleting something it shouldn't:
- **Scope.** Non-recursive and prefix+suffix matched, so a directory neighbour like `media/`, the user's
  own `~/.codex/config.toml`, `borrows.json`, or the socket is out of range by construction.
- **Ownership, proved two ways by where the file lives.** For a file in a directory Orchestra owns
  *exclusively* (its Application Support data dir — Claude's `card-settings-*`, the `readonly-*` settings)
  the directory itself is the proof, and a token-shape check (`hasWellFormedToken`: the exact canonical
  lowercase hex a cwd hash produces, or a 6-char UUID prefix) rejects anything malformed. For a file in a
  directory the user *also* writes to — Codex's real `~/.codex` — shape isn't enough: a user could
  hand-author `orch-<16-hex-digits>.config.toml` for their own `codex -p`. So Orchestra stamps a first-line
  **ownership marker** into every profile it writes, and the sweep reaps such a file only if it carries
  that marker (`CardFileSpec.ownershipMarker`). A user's file — same name shape, no marker — is never a
  candidate. (Consequence: Codex profiles written *before* this marker existed are not auto-reaped; that
  one-time residue is harmless and steady-state operation adds none, since every live card re-stamps its
  profile on next launch.)
- **Trustworthy evidence only.** The keep-set is meaningful only if the loaded board is *complete*. An
  empty store (indistinguishable from a failed load) reaps nothing; and because `TaskStore` drops
  individually-undecodable records element-wise (an id-less row, or a phase this binary can't decode), a
  *partial* load looks non-empty yet may be missing the very live card a file belongs to — so the sweep
  also gates on `TaskStore.loadWasComplete()` and prunes nothing when a record was dropped. This is the
  borrow sweep's "prune nothing when the registry can't be trusted as complete" (FIX E), one tier finer.
- **A fresh keep-set, captured just before deletion.** The sweep runs in two phases: enumerate candidates
  off-actor (the slow stat-per-file pass), then re-read the live set on-actor immediately before deleting.
  Because a spawn *persists* its card before that card's launch writes any file, any card that could have
  written a candidate path is in the store by delete time — including a *different* card that came live on
  a shared cwd after the first snapshot. The forward keep-set alone (captured once, up front) couldn't see
  that card; the fresh re-read does.

Beyond those, a file modified within a grace window is kept as a possibly-in-flight launch, and the
delete re-stats each file immediately before unlinking so a card launched onto the same path since
enumeration never loses its freshly-written file to a stale candidate. Every ambiguous case leaks a file
the next boot heals; none can delete a live card's file (which would silently drop that card's managed
statusLine + telemetry hooks). Each adapter names its own file through one
`Adapter.cardFile: CardFileSpec?` (default `nil`), so a new agent opts in by returning a spec — no
`if agent ==` branching — and `CardFileSpec` owns the **single** djb2 the two adapters used to duplicate.
The decision itself is the pure `OrphanSweep.reclaimable`, now shared with `sweepOrphanScratch` so the
contract the scratch/borrow/session sweeps each learned the hard way lives in exactly one place.

### Trust boundaries: allowlist for worktrees, sandbox for the rest

Worktree cards validate their repo path against the allowlist (`PathResolver`, symlink- and
`..`-escape-safe, component-wise prefix). Borrowed and scratch cards skip the allowlist and rely on the
OS sandbox confining writes to their directory — so freeform cards stay friction-light while the
boundary still holds.

Layered under that boundary is the **trust ledger** — the durable, human-owned record of which
directories agents may *write* in (see [the trust ledger](03-data-model.md#the-trust-ledger-t1)). Core
resolves trust from a card's `origin` in **`OrchestraService.resolveTrust`** → a `TrustDecision` of
`.trusted` or `.needsGrant`, carried onto the launch as `AdapterContext.trustCwd` — and **adapters only
*apply* that flag; they never read the ledger** (so the same "trusted once" fact carries across Claude,
Codex, and every later agent through one core seam). The three origins resolve distinctly: a
**worktree** trusts its source repo (registering a repo to run agents *is* the trust act — recorded
`repoRegistration`), a **scratch** dir Orchestra made empty is auto-trusted (`orchestra`) but
**demotes to `needsGrant` if a foreign repo is later cloned into it** (a `.git` appears — external code
is no longer Orchestra's to auto-trust), and a **borrowed** dir is `.needsGrant` until a human grants it.
Filling a `needsGrant` is a **human decision, never the agent's**: an untrusted card still spawns — but
**sandboxed** (writes blocked), with an actionable activity telling the human how to grant — and the
grant flows through a `TrustGrantResolver` seam whose production `SurfaceGrantResolver` approves only
*interactive* surfaces (a CLI tty prompt, the MCP elicitation dialog) and **denies `.agent`/`.daemon`**.
That single rule is both the **autonomy-exemption** and the "an agent can't self-grant" guarantee. (Trust
ledger + resolver by **PR T1**; the grant surfaces — `trust` Command, `orchestra trust` verb, MCP
elicitation — by **PR T2**, both in the [shipped history](#shipped-feature-history) below.)

### Read-only is defense in depth

A read-only agent is constrained by three independent layers — edit tools removed, a kernel-level
sandbox write-block, and a semantic auto-mode "deny any mutation" classifier — chosen over a brittle
command deny-list precisely because deny-lists rot and are trivially evaded. On a tracked card the
sandbox layer's settings are **deep-merged onto the managed hooks base into one `--settings` file**
(`SettingsComposer`), never handed as a second `--settings`: Claude Code applies multiple `--settings`
last-file-wins (full replacement, not deep-merge), so a second file would silently strip the statusLine +
telemetry hooks — which is exactly the regression befad61 fixed for agent-created (MCP/CLI-spawned)
read-only cards. `settingsOverlays(_:)` is the single seam any future per-card setting appends to, keeping
the one-file invariant automatic. (See [the read-only barrier](04-cards-worktrees-sessions.md#the-read-only-barrier).)

### authMode: advise on fan-out, never cap

Fanning out many concurrent agents onto a **single subscription seat** (a Claude or Codex plan login,
rather than a metered API key) is the "heavy parallel automation" pattern both providers' anti-automation
terms target — so Orchestra notices it, but it **advises and never blocks**. When a card is brought up on
an adapter whose `capabilities.authMode` is `.subscription`, `AuthRateMonitor` tallies the *live*
subscription-auth cards for that same adapter and, past a threshold (default 3 → the 4th warns), emits an
advisory `ActivityKind.warning` into the feed suggesting API-key mode for large fan-outs. The spawn always
proceeds; there is **no concurrency cap, no queue, no rejection**. Three properties make this a decision
rather than a knob:

- **Warn-only, resolved deliberately.** Capping was considered and rejected — a hard limit on parallelism
  would break the very fan-out topology Orchestra exists to enable. The monitor never throws or blocks.
- **Rate state is per-adapter and derived, not held.** Each subscription is its own seat, so a Claude
  fan-out never pushes a Codex adapter over, and vice versa; and the tally is computed from the current
  card set (the SSOT) on every spawn rather than kept in a counter — so it can't drift and survives a
  daemon restart with no reconciliation.
- **It gates on the capability, never on identity.** The monitor reads `adapter.capabilities.authMode`,
  so an API-key adapter (or a future subscription agent) is classified by its descriptor, never by an
  `if agentId == "claude-code"` branch.

(Agent-provider forest PR **E2**.)

### 1:1 worktree ↔ card ownership

Main runs **N:1** — several cards may co-locate in one worktree, and cleanup is refcount-gated on live
siblings (see [the WorktreeRegistry](#the-worktreeregistry-materialized-markers-on-demand-siblings-persisted-borrows)
removal policy). An **enforced-1:1** model was explored — one card owns one branch's worktree, retiring
the refcount guard + shared-worktree badge — and then **reverted**: git already forbids the same *branch*
in two worktrees, so the genuinely dangerous N:1 case (two writers on one branch) can't arise regardless,
while the safe co-location patterns (read-only inspect, freeform cards, a stacked child reading its
parent's tree) actually want sharing. So the refcount + badge machinery stays, scoped to worktree cards.

### The WorktreeRegistry: materialized markers, on-demand siblings, persisted borrows

The `WorktreeRegistry` actor (PR3b) is the sole owner of
worktree + borrow lifecycle — the concrete `WorktreeManager` git-shell struct is `fileprivate` inside the
same file, a compile-time guarantee that nothing else can call a git worktree op (see
[Worktrees](04-cards-worktrees-sessions.md#worktrees) for the mechanics). Its decisions:

- **The marker lives OUTSIDE the worktree.** A sentinel file in a registry-owned metadata dir
  (`Config.worktreeMarkersDir`), one per canonical worktree path, is the sole adoption signal. An in-tree
  marker would (a) show as untracked in `git status --porcelain` — every tree would read "dirty," breaking
  the dirty-detection arms — and (b) mutate a dirty pre-upgrade tree the first time it was touched,
  violating the "survives byte-intact" guarantee.
- **`created` ≡ marker present.** The registry writes a marker only after a *complete* checkout (or an
  explicit migration stamp), so "did the registry create/verify-adopt this tree" is exactly "does its
  marker exist" — no separate stored bit, and `release`'s ownership guard reads the same signal `ensure`
  writes.
- **Serialization is the actor mailbox alone — no per-branch lock.** `ensure` performs no `await` between
  the marker check and the checkout, so the mailbox alone makes two concurrent same-branch calls run
  one-at-a-time and `git worktree add` fire once. This globally serializes worktree git ops — a
  conservative superset of "per branch" — acceptable for a single-user tool.
- **Owned roots = under `config.worktreesRoot`.** This single prefix covers ordinary card worktrees and
  `orch-borrow-*` dirs alike. Both `release` and `sweepOrphanBorrows` gate every removal on
  `isUnderOwnedRoots`, a stricter check than `PathResolver.assertAllowed` (which also admits
  `reposRoot`) — so neither path can ever remove outside `worktreesRoot`, even though `manager.remove`'s
  own `assertAllowed` call alone would permit it. Borrow paths are additionally borrow-derived by
  construction (`borrowPath` always returns a `worktreesRoot`-rooted path), so the guard is normally a
  no-op for them; it exists to keep the pledge true by construction, not by convention.
- **Persisted borrows survive a daemon-only crash.** `[borrowerCardId: path]` is written as atomic JSON
  beside the inbox (`Config.borrowsPath`); a fresh registry instance re-reads it on restart, so a live
  borrower's dir can't be mistaken for a stray `orch-borrow-*` dir by the orphan sweep.
- **Marker stamping is one-time, sentinel-gated.** Stamping on every boot (rather than once) would, under
  a future non-blocking spawn, risk marking a half-created (mid-materialization) dir adoptable; the
  persisted sentinel makes the migration run exactly once, at the first post-upgrade boot when every
  persisted tree is at-rest and complete.
- **Conservative mode is wired (PR4b).** `setConservativeMode(_:)` gates `release` to a hard no-op when
  set, and `TeardownStepper` gates the scratch-origin `rm -rf` reclaim on the same flag. Boot's
  `reconcilePhasesAtBoot()` sets it the moment a corrupt `tasks.json` forces `TaskStore` to side-line the
  file and boot an empty board (`WorktreeRegistry.swift:407`; `OrchestraService+Reconcile.swift`) — ownership
  can't be positively re-established against an empty board, so nothing is removed. Nothing in-process
  clears it: conservative mode holds for that corrupt-boot daemon's entire run, and only a fresh daemon
  start against a clean store comes up un-conservative.
- **Release keeps trees for *unsaved work*, not for any `git status` output.** The keep-gate in
  `release` is `hasUnsavedWork`, a config-pinned porcelain probe (`--porcelain=v1 -z
  --untracked-files=all --ignore-submodules=none`, two-status-byte classification): a tree whose only
  entries are ` D` worktree-deletions of index-clean files has nothing left on disk to lose — that is
  exactly the residue a killed `git worktree remove` leaves — so it is removed, with `--force`, since
  git's own clean-check would refuse that state forever. Anything else (staged, modified, untracked,
  unmerged, renames), or an unqueryable probe, keeps the tree and emits a warning. `isDirty` (any
  output ⇒ dirty) remains the gate on the *ensure*-path's marker-less-dir handling, which never
  auto-removes.
- **Worktree removal runs under the bulk-IO timeout (`worktreeAddTimeout`).** Removal deletes the same
  bytes a checkout writes — plus a shipped card's multi-GB ignored `.build` — so bounding it at
  `controlTimeout` (15s) guaranteed mid-delete SIGKILLs on real trees. That killed removal was the
  worktree-orphan leak's root cause: the partial state read as dirty, the old any-output gate then
  blocked every retry, and nothing retried anyway.
- **Interrupted removals are re-driven at boot.** `redriveArchivedWorktreeReleases()` re-runs
  `release(force: false)` — the same policy, every guard intact — for each `origin == .worktree` card
  whose phase is `archivedComplete` (never `archivedPending`: the `archived` flag is written before
  teardown kills the session, so only the completed teardown proves the agent is gone), then prunes
  dangling registrations per repo (`git worktree prune` from the repo root — metadata-only, and
  registrations are what the sandbox profile scans). Deletion progress is monotonic, so re-drives
  converge; `release` returns a `ReleaseOutcome` so kept/failed trees surface as warnings instead of
  `try?` silence.
- **An in-flight holder set closes the concurrent-spawn rollback race.** Between `ensure` returning and
  the card's persistence to the store, a second same-branch spawn can interleave at the service actor's
  `await` and adopt the first spawn's tree while still unpersisted. A store-only sibling scan in `release`
  would then see no sibling and let the first spawn's rollback remove the tree the second, not-yet-stored
  card just adopted. The registry's in-memory `inflight: [path: Set<cardId>]` — populated by every
  `ensure` call and drained by `release`'s `defer` — is the reference a store snapshot can't see.
  `release` for a card **absent from the store** still surrenders that card's own holds (a scan, since
  the keyed `defer` needs the card's cwd): a rollback so hard the card never persisted must not leave a
  phantom holder that blocks every future sibling release of the path.

Fail-safe arms: a marker-less **clean** dir is pruned and re-created; a marker-less **dirty** dir is never
auto-removed (`ensure` throws `worktreeNeedsManualCleanup`); `release` never removes a dirty tree without
`force`, never removes a tree any non-archived sibling (or in-flight holder) still references, and treats
a missing tree as an idempotent success rather than an error.

### CardRuntime: card-lifetime actor state in one detachable entry

All of a card's in-memory, card-lifetime state on the `OrchestraService` actor lives in **one
`CardRuntime` struct** in a single `runtime: [UUID: CardRuntime]` map — timers, debounce tasks,
delivery accounting, readiness waiters, funnel bookkeeping. Teardown detaches the whole entry, so
a new per-card field is torn down by construction: the previous design (one `[UUID: X]` dict per
concern plus a hand-maintained duty list in `teardownActorDuties`) leaked whatever the list didn't
name, and the list gained three hand-added entries in its final two weeks.

The mechanisms that make the wholesale drop safe:

- **The armed-task bag.** The five per-card timer/loop slots (remote watch, merge-request nudge,
  the three debounces) live in one `tasks: [ArmedSlot: Armed]` bag; the detach iterates and
  cancels — discarding a struct containing a running `Task` would orphan it, strictly worse than a
  leak. Every arming carries a **token minted from a process-monotonic counter** (never reused,
  never reset). Delayed callbacks — a loop's mid-tick ghost gates, every debounce's terminal
  self-clear — compare their captured token against the slot's current one and no-op when
  superseded. This replaces the two per-card `?? 0 + 1` generation counters (whose teardown-reset
  allowed a post-reopen re-seed a pre-archive ghost could match) and extends the same fence to the
  debounces, whose self-clears were previously unfenced and could nil a newer task's slot.
- **`ensureRuntime` is the only creator**, gated on the card's `archived` bit — set at archive
  intent, cleared by reopen. Every other write is update-if-present. The report funnel (which has
  no archived gate of its own) ensures at entry for live cards, and the ensure gate is what makes
  a late report for an archived card a no-op instead of a resurrection. The reconcile tick ensures
  entries for every non-archived card, which is also the boot reconstruction — transitional and
  `.dead` cards get their entries on the first tick after a daemon restart.
- **Teardown runs under a persisted lease** — the card's `.archivedPending` phase + the
  `sessionEpoch` its step was dispatched with, re-verified (`stillOwns`) before mutations and
  after every suspension. A reopen bumps the epoch, so a stale teardown stands down without
  touching the reopened card's state; a crash-redrive re-dispatches at the current epoch and
  proceeds (the lease is persisted, so it authorizes redrives that no in-memory fence could).
  Durable duties — the card-file sweep, the **watcher-side watch-registry removal** (previously
  never removed: an archived watcher's key persisted to disk forever), and the dedup-keyed child
  nudge — run on every redrive, gated on the lease and never on runtime presence.
- **Deliberately outside the struct**: `inFlightSteps` and `stepAttempts` are reconciler driving
  state, not card state — the teardown step's own claim is live during teardown, and a failed
  teardown writes its backoff after step 4 (the re-drive gate needs it; its `.dead`-path residue is
  cleared in the reconcile terminal arm instead). `watchRegistry` is persisted relational state
  whose watcher-side removal is a durable duty, not a struct field.
- **Collaborators are notified, not absorbed.** `TerminalOwnershipStore` gains a non-CAS
  `clearOwner(cardId:)` used only by the detach: it clears the owner of every window while keeping
  each slot's epoch (epoch monotonicity is the store's stale-CAS safety; removing a slot would let
  a reopened card restart at epoch 1 and ABA-match a stale client). The `RolloutTailer` cursor is
  dropped at teardown, and bring-up seeds a fresh cursor at the rollout's post-kill EOF watermark —
  a resumed/reopened card never replays rollout history into the seq-gated status funnel, whose
  `lastSeq` the detach also reset.
- **`diffStatDebounce` is cancelled at teardown** like its twins (previously its only cleanup was
  its own self-clear, so an in-flight diffstat survived archive and recomputed against a dead card).

### One seed, four topologies

Handoff, fork, fan-out, and (Claude) subagents are **one primitive** — a fresh session seeded with
authored context — at four topologies. The keystone is an `additionalContext` seed on the spawn/restart
path. The decision rule an agent applies to pick among them:

| You want to… | Reach for |
|---|---|
| **return to the thread**, and rejoin interactively | **fork** (a board card) or a **native subagent** |
| **return a summary you fold back immediately** | a **native subagent** (Claude's `Task` tool) — ephemeral, in-context |
| durable · parallel · cross-agent · isolated · its own PR branch | a **card** (fork/fan-out) — reach for it *in addition to*, never *instead of*, subagents |
| **replace the thread** | **handoff** (same-card resume) |
| **split into many** | **fan-out** |

Cards and native subagents are complementary, not alternatives: a card for work that outlives your turn
and can land a PR, a subagent for read/search fan-out you fold back at once. Merge-back must be a
**durable persisted inbox keyed on card lineage**, not
a `send`-to-tmux (which throws if the session died), and orphaned forks are promoted to standalone cards
rather than cascade-killed. The guiding maxim: **handoff carries intent, artifacts carry facts** — the
seed is for navigation and next steps, while committed code, plan files, and the card description carry
the durable record, so successive handoffs don't degrade into a telephone game. The **live-delivery
substrate** these topologies compose from is three functions — **F1** resume-in-card,
**F2** wake an idle card, **F3** the durable per-card **inbox** (merge-back drains at the next turn-end).
**F3 has
now landed** (PR C1, below): `send` routes through a durable [inbox store](03-data-model.md#the-inbox-store-f3),
and the Claude Stop hook drains it into the agent at its turn-end. `send`-to-tmux is retired exactly as the
maxim demanded — a queued conclusion no longer throws if the session died, and coalesces with other returns
until the next turn. **F2 wake + the conclusion-watch have now landed too** (PR C2, below): the
[`wait` command / `MergeWatch`](05-command-reference.md#notes-on-key-commands) let an orchestrator card
block until a watched child concludes, with each conclusion coalescing into the parent's inbox and waking
it — the reactive fan-out. **F1 resume-in-card has now landed too** (PR C3, below): a card resumes into a
fresh process with clean context, seeded with an authored handoff/fork context folded together with its
pending inbox — so **all three live-delivery functions the topologies compose from are now shipped**. The
Codex **send-keys wake (C4)** has since landed too (below), the **`handoff` Command (D1)** that *calls*
the F1 seam shipped the first of the topology surfaces (below), and the new-card **fork / fan-out
start-actions + the Handoff/Send card actions** have now landed as well (**D3**, below) — folding an
authored `SpawnInput.seed` ahead of a new card's prompt — so **all four topologies are driveable from the
CLI, MCP, and (at the time) the board**. The board surface was subsequently pared back: the
Handoff/Fork/Fan-out buttons were removed in favor of the natural-language → MCP path, and the per-card
Send button became a full **inbox editor** (the *agent-buttons simplification*, in the
[shipped history](#shipped-feature-history) below). The **guidance** an agent reads to *choose* among these topologies — delegate vs.
continue, and card vs. native subagent (keep both) — has been authored and vendored too (**D2**, below);
and that wire now uses a shared `AgentGuidance` bundle: Claude materializes project skills, while Codex
passes the same selected sections as launch-scoped `developer_instructions`. Codex keeps its native home
and global `AGENTS.md`, and the required launch argv is the provider-specific adapter seam.

### The durable inbox is the delivery SSOT: claim, then confirm

Delivery used to mean removal: `drain` took messages out of `inbox.json` and *then* handed them to a
session. Every path removed before receipt, so a crash, a lost hook reply, or a dead session between
those two steps lost the message silently — the queue was already empty and nothing retried.

B1 lands the primitive for a new delivery model; the routes that carry it — the Stop-hook drain, the idle channel push, the relaunch seed — convert from remove-before-receipt to it across the PRs that follow, so this section describes the model, not yet the wired-through behavior. Under it, the inbox stays the source of truth until receipt is proven: a delivery path **claims** a FIFO batch —
select + whole-message fit + lease + a fresh token, in ONE `Inbox.claim` actor call — and messages leave
only through `confirm(token:)` on a route-specific receipt proof. One call, because a select/lease split
races: two routes could claim the same message, and a render truncated after the select could confirm
messages it never delivered. The route's `render` runs *inside* the claim and reports what it consumed, so
exactly the rendered prefix is leased.

Confirms are token-scoped, not id-scoped: re-leasing mints a fresh token, so a late ack from a superseded
attempt is an idempotent no-op instead of removing a re-claimed message. A batch becomes re-claimable when
its lease ages past `deliveryLeaseTimeout` (60s, config) or when its epoch falls below the claiming epoch —
the funnel's epoch bump *proves* the leased session is gone, so a restart re-claims immediately rather than
waiting out the timeout. A `relaunchSeed` claim additionally re-owns its own prior `relaunchSeed` lease, so
a retried relaunch never comes up seedless. Once a route delivers through the primitive, the result is at-least-once: duplicates over loss, and every
failure ends in re-delivery or durable retention, never silence.

Leases live on `InboxMessage` inside `inbox.json` rather than in a sidecar file — two files can't be
written atomically, which is the class of bug this design removes. For the same reason `confirm` writes the
removal and the confirmed-ids ring in a single persist: a crash leaves both or neither.

`inbox.json` moved from a bare `[InboxMessage]` array to a `{messages, confirmedIds}` envelope, and the
loader decodes **tolerantly** — a legacy array becomes `messages` with an empty ring. An envelope-only
decoder would have `.bak`'d every existing inbox on upgrade and dropped every pending send; only
top-level-unparseable JSON still `.bak`s. The ring is a bounded (256) FIFO tombstone of delivered ids:
`confirm` removes the row, so `send`'s idempotency needs it to no-op a retry whose response was lost after
delivery.

Editor verbs win over a live lease: `inbox-remove`/`inbox-edit` force-release the in-flight batch, which
returns to pending and re-delivers. An already-rendered payload may still arrive once — benign, and
preferable to letting a stale token confirm text the human has rewritten. `inbox-reorder` permutes the full
set including leased rows; order is metadata for future renders and never disturbs a live claim.

### The Stop-hook drain is the first route wired to claim-then-confirm

B2 converts the busy path — a live agent's turn-end Stop hook — from `drainForStop` (remove-then-inject)
to `payloadForStop` (claim-then-confirm), the first route to carry B1's primitive. The order is
load-bearing. **The epoch fence runs first:** a confirm or claim requires the Stop's `observedEpoch` to
equal the card's current `sessionEpoch`, and a mismatched *or nil* epoch (a pre-upgrade session with no
`ORCH_EPOCH`, or a superseded one) returns nil with no confirm and no claim — so a dead session's Stop can
never lease fresh messages into a pane nobody is reading, and the messages stay durable for the arm's idle
routes. Because the fence reads `sessionEpoch`, `payloadForStop` now needs the card in the store, dropping
`drainForStop`'s "safe without a task" property; that's sound because a real Stop hook always fires for a
live card.

**The hook dispatch claims the stopDrain *before* applying the Stop's own report.** A real Claude Stop
carries a `waiting(.humanTurn)` report, and applying it first lands the card `.live(.waiting)` — whose
wake-on-live would cold-relaunch a `nativeReinvoke` card with no active CLI wait, bumping the epoch out from
under this Stop's own claim so the fence above then rejects it and a healthy session is needlessly restarted
on every send. The Stop hook *is* the reinvoke, so its same-epoch claim must win over a cold relaunch:
`handleHook(.stop)` runs `payloadForStop` first — minting a live same-epoch lease — and only then applies
the report, so the waiting-landing wake now defers on that live lease instead of relaunching. The fence's
real purpose is untouched: a genuinely stale Stop (a superseded generation's) still fails the epoch check
and no-ops.

**The receipt proof is `stop_hook_active`, and it rides as a sibling hook-RPC field, not through
`Adapter.parse`.** Both agents set that top-level boolean on a `decision:block` continuation Stop (their own
loop guard), so the *next* same-epoch Stop with `stop_hook_active == true` proves the prior continuation
actually ran — and only then does its batch confirm. Nothing else confirms: not a human turn (Opus emits a
plain Stop), not a lagged rollout line. It has to be a sibling field because `parse` can't carry it —
Codex's Stop reports nothing to parse, and Claude drops the hook during a background-work hold — so it is
read straight off the raw payload at the `_report` edge and rides even when the typed report is nil, which
is exactly what lets a background-yielding continuation still confirm. `HookRPC` holds the extractor, the
params builder, and one shared key referenced by both the builder and the `ControlServer` decode, so a key
typo fails a unit test instead of silently breaking every continuation. B2 trusts the contract's claim that
both agents emit the flag; D2 re-probes it empirically before the channels path depends on it.

**The confirm's safety rests on a recorded assumption: an at-most-once hook transport and exactly one Stop
per continuation.** The stopDrain confirm (a `stop_hook_active==true` Stop confirms the prior injected batch)
is safe because the hook transport is at-most-once (`_report`/`boundedCall` fire the hook RPC once, no retry)
and Claude fires exactly one Stop per continuation, with `active=true` strictly following a *delivered*
`decision:block` (empirically verified, Claude 2.1.217). A lost block produces no `active=true` successor, so
the confirm never runs and the delivery arm re-drives the message — at-least-once holds. **Any future
transport that adds Stop-hook retries, or a Claude that re-fires/duplicates a Stop with `active=true`, MUST
add Stop-RPC idempotency (per-continuation nonce binding) before this confirm is safe.**

**A live-lease guard keeps at most one stopDrain batch in flight, atomically.** The claim refuses to lease
while an unexpired same-epoch lease is already outstanding — and that check lives *inside* `Inbox.claim`
(its `blockIfLiveLease` flag), in the same atomic actor call as the lease, not as a separate
`hasLiveLease` await before it. That matters under concurrency: two same-epoch Stop RPCs reenter
`payloadForStop` on the service actor, and a separate check-then-claim would let both pass the check and
then lease *different* overflow batches — two same-epoch leases. A later `stop_hook_active` Stop finds the
lease by scanning, so it would confirm the older (lost-reply) batch and silently drop it. Folding the check
into the claim makes a second live lease impossible to *create*, not merely detectable after the fact; one
outstanding lease makes the scan unambiguous. (`hasLiveLease` remains as the standalone predicate the wake
path reuses.)

**The epoch fence is re-checked *after* the claim, not only at entry** (wave-1 T3 review). The entry fence
proves the Stop belongs to the current generation, but it is stale across `payloadForStop`'s later awaits —
the service actor is reentrant, so a concurrent `restart`/`resume` can persist epoch `e+1` during the
peek/confirm/claim hops, and `blockIfLiveLease` will not catch it (that check is `e`-scoped; the new lease
is a different generation). Left unguarded, the `e`-claim would hand fresh continuation payload to the
superseded pane the relaunch is about to kill *and* lease messages the `e+1` relaunch then re-owns and
re-delivers — the stale-pane injection and duplicate the fence exists to forbid. So the claim is followed by
the same post-await re-guard the wake ladder applies after its own suspensions: re-read the card, and if it
raced away, archived, or lost `e`, release the batch and return nil. Fail-safe — the message stays durable
and the `e+1` relaunch's `claimSeed` delivers it. This is a *duplicate*-not-loss window (the batch is re-owned,
never dropped), but the fence is a locked invariant, so it is closed rather than tolerated.

The delivery-tracking state the confirm touches is **declared here even though the reconciler arm reads it
later**, by the first-reference rule: `Task.deliveryStuckSince` (persisted, UI-less), the service's
`deliveryAttempts` and `outstandingTokens`, and the single `confirmDelivery` funnel every route confirms
through — so the archive guard and the attempt/stuck resets can't be forgotten at one call site. The funnel
resets that state *only* on a genuine confirmation: `Inbox.confirm` returns whether it actually removed a
batch, so a stale-token no-op or an archive release prunes the outstanding token but never re-arms the retry
budget or clears the stuck flag. Archive-versus-confirm is deliberately a two-part design — the funnel's
fresh archived-read plus teardown's lease release — because the actor model can't linearize a cross-actor
store-read and inbox-write into one atomic step.

### The cold path flips to claim-then-confirm, fenced by a persisted tail watermark

B3 converts the **cold** routes — idle-wake, send-to-a-dead-card, and handoff — from the destructive
drain to the claim. The pivot is removing `resumeInCard`'s `inbox.drain`: it now carries only the
handoff context (it *is* `resume(seed:)`), and the pending inbox stays durable, delivered by the
RelaunchStepper's `relaunchSeed` claim, which composes the handoff and the inbox under one budget with
`HandoffSeed.compose`. Removing the drain is what closes the L1 crash window — there is no drained-then-
folded-then-lost seed to lose, because nothing is removed until a receipt is proven. The prior post-drain
fold retires with its last caller; `compose` runs *inside* the claim, so the claim's consumed-prefix guarantee
covers the final argv bytes and a truncating fold can never leave a leased-but-unrendered message to be
confirmed.

**Readiness now carries provenance, because the confirm depends on it.** `ReadinessOutcome.confirmed`
gains a `via: {.signal, .ticks}`. A `.signal` is a positive session signal proving the new generation
booted with the seed — a current-epoch SessionStart hook, or a fresh launch's rollout `session_meta` — so
the stepper confirms the batch immediately. A `.ticks` is the N=3 liveness fallback (a `codex resume`
emits no rollout) or a signal that can't be attributed to the current generation; it proves only that
something is alive, so the stepper **holds** the lease and lets `report()` confirm it later. That the
signal is *current-generation* is load-bearing and enforced two ways. The readiness waiter records the
epoch it was armed for, and `resolveReadiness` yields `.signal` only when the delivering signal's
`observedEpoch` matches — a stale predecessor resume hook that lands in the relaunch's readiness window is
ignored (a nil-epoch signal degrades to `.ticks`, never a premature confirm). This matters because
`resolveReadiness` is not otherwise epoch-fenced the way the phase write is; without it a delayed
predecessor hook would confirm the new batch with no proof the new session ever received it. There are two
tick resolvers — a test-only one and the production `tickLaunchReadyPublic` in the reconciler — and *both*
must mark `.ticks`; the production one is easy to miss (it compiles either way) and missing it would make
Codex idle-wake confirm every seed unfenced, turning the whole watermark machinery into dead code.

**A held lease is confirmed by a provenance-fenced line, so a crash or a replay can't false-confirm.** A
`report()` for a card holding a `relaunchSeed` lease confirms it only on a signal proven to post-date the
relaunch: a fileTail line qualifies only when it is on the same rollout path *and* at or past a **persisted
tail watermark**, and a hook qualifies only when its epoch matches the lease's. The watermark is the
rollout's EOF byte offset captured inside `finishLaunch`'s one off-actor hop — after the predecessor is
killed (so it cannot append past the fence) and before the new session launches (so the new session has
not written yet) — and stored on the lease together with the path. `RolloutTailer.eofOffset` is a
stateless stat precisely so it can run in that hop without a third suspension between kill and launch, and
`RolloutTailer.newLines` now returns each line's byte offset and path (`TailedLine`) so `pollTelemetry` can
thread the provenance through. Because the watermark and path are persisted on the lease, a daemon restart
that re-reads the rollout from offset zero replays only pre-watermark lines, which fail the offset test and
never confirm — the fence is crash-proof by construction, not by arrival-order luck. The confirm itself
routes through B2's `confirmDelivery` (not a self-confirming inbox helper, which is why B1's
`confirmHeldRelaunch` is retired), so the archive guard is never bypassed.

One route is deliberately left at **lease-expiry** rather than a proven confirm: a *provisional* (never-
prompted, transcript-less) fileTail card blank-launches rather than resuming, and a blank launch mints a
fresh session whose rollout does not exist yet — so there is no EOF to capture before launch and no path to
fence on. Its held lease therefore carries no watermark and `report()` can never confirm it (a fileTail
agent has no epoch-stamped hook to take the other branch either). The payload is still delivered — it rides
the launch as the opening positional — so nothing is lost; the lease simply lingers until it expires and is
re-claimed, which re-delivers once. That is the contract's at-least-once posture (duplicates over loss)
applied to the one case where post-kill provenance is unobtainable, and it is narrow in practice: it needs a
send to a dead, never-prompted Codex card. Read the cold path as exactly-once *only* where a watermark or an
epoch-matched hook exists; this case is at-least-once by construction.

A second, narrower residual has the same shape. The watermark is *captured* inside the kill→ensure hop but
*stamped* on the lease a few actor hops later, and `pollTelemetry` keeps tailing a card while it is
`.relaunching` — so a rollout line emitted by the new session in that gap is consumed (the tailer cursor
advances) at a moment when the lease carries no watermark yet and the card has not landed `.live`, and it
therefore cannot confirm. If that were the session's *only* line, the lease would sit held until it expired
and re-delivered. It is left as a residual rather than restructured: closing it means splitting the hop so
the stamp precedes the launch, which trades a verified-atomic post-kill capture for a window where the card
has no session at all, to convert a within-contract duplicate into a slightly earlier confirm. Codex emits
many lines per turn, so "the only line lands in that gap" is vanishingly rare, and the outcome is a
duplicate, never a loss.

Both residuals share one root: a confirm needs *proof* the current generation received the seed, and where
that proof is unobtainable the design holds the message rather than guessing. The delivery arm (B4) is what
turns an expired held lease back into a prompt re-delivery; until it lands, an expired lease waits for the
next wake rather than being re-driven on a timer — the message stays durable throughout, which is why the
B-spine deliberately sequences the arm after both confirm paths exist.

Four fences make the flip **independently correct**, not merely correct once B4 lands, and each is here
rather than deferred because B3 is where the held lease is *born*. `wakeIfPending` now gates on
`hasClaimable`, not a non-empty peek: the funnel fires wake-on-live on every `.live` landing, and a held
same-epoch lease still shows in `peek`, so the old gate would re-wake the just-live card into an infinite
relaunch loop — a held lease is deliberately not claimable, so `hasClaimable` leaves it alone. The
`report()` being-born landing fence drops its `owesLaunch` term (`!(beingBorn && observedEpoch !=
sessionEpoch)`): the de-drain means a cold relaunch carries neither `pendingSeed` nor `pendingModel`, so
the old gate no longer covered it, and an unstamped file-tail snapshot from the dying predecessor could
land the card `.live` before the stepper ever claimed its seed. The RelaunchStepper re-reads the card after
the worktree ensure and claims at the *current* epoch, so a relaunch that supersedes it during the ensure
can't let a stale step re-own the lease at the wrong generation. And `TeardownStepper` releases the card's
leases before the terminal flip, so the narrow archive-versus-confirm window B2 left to B4 is backstopped
in-PR for B3's new held leases. A handoff-only claim — non-empty
payload, zero consumed messages — leases nothing, so it is neither dispatch-tracked nor signal-confirmed;
tracking its token would leak a phantom outstanding token and mischarge the arm, and per the contract a
handoff's context is a fire-and-forget re-seat with no durable receipt.

Finally, the cold path suppresses Claude's **resume modal**. A machine-driven `claude --resume` on an old,
large session opens a "Resume from summary/full" dialog instead of running the seed, and with no human to
answer it the resume deadlocks and swallows the seed (two live cards were observed parked at it).
`ClaudeCodeAdapter.env` sets `CLAUDE_CODE_RESUME_THRESHOLD_MINUTES` and `CLAUDE_CODE_RESUME_TOKEN_THRESHOLD`
impossibly high through the same `Adapter.env` seam Codex uses for `CODEX_HOME`. It is fail-soft — a build
that doesn't know the vars ignores them, and a modal that still appears degrades to a readiness timeout, so
the lease survives and the arm retries rather than the seed being silently lost — and agent-agnostic, since
other adapters return nothing.

### The delivery arm and the wake route ladder (B4)

`send` was a one-shot: enqueue, try once, hope. Every receipt that never came back — a lost
`decision:block` reply, a dead bridge, a relaunch that crashed before its confirm, and B3's two documented
residuals — left a durable message with nothing to re-drive it. Delivery is now **level-triggered**: an arm
in the reconcile tick re-drives any deliverable card that still has claimable messages, so the durable inbox
converges to empty the same way a phase converges to its target. This is why the B-spine sequences the arm
strictly after both confirm paths (B2 busy, B3 cold) exist — a level-triggered retry over a still-pre-draining
path would multiply the very loss being fixed.

**`wake` is the single delivery chokepoint.** Every starter — `send`'s fast path, the arm, `wakeIfPending`'s
live edge, `concludeCard`'s watcher nudges — goes through it, so there is one in-flight guard
(`deliveriesInFlight`, acquired synchronously before any suspension) and one place route selection happens.
The ladder is CLI-wait defer → outstanding-lease defer → cold resume intent, selected purely from
`AgentCapabilities.wakeTransport`; there is no `if agentId` anywhere on it.
`resumeSeedWake` and `relaunchClaimed` are retired: the wake-claim role is `deliveriesInFlight`, and the
relaunch single-winner role is the funnel's epoch bump. The card is re-read after **every** suspension —
archived, left the deliverable set, or epoch-bumped by a concurrent relaunch — and this is not
belt-and-braces: `isResumable` hops off-actor for a filesystem stat, so the cold path re-guards after it, and
a relaunch that landed during the stat must not get a second, redundant resume on top of the generation it
just created.

Two rungs are *defers*, not failures, and deliberately charge nothing: a `.nativeReinvoke` card with a live
`orchestra wait` will be re-invoked by its own harness, and an unexpired same-epoch lease means a delivery is
mid-confirm — a held relaunch seed awaiting its first-signal confirm must never be superseded by a cold
restart of the session that just took the delivery.

**Attempt accounting is per-token, and the ledger is what makes it exact.** `outstandingTokens` records what
was dispatched; `confirmDelivery` removes a token on confirm *or* release. So a token still in the set whose
lease is no longer live was dispatched and died — the arm charges it once and removes it, via a new
`Inbox.isLeaseLive(token:now:)` that is token-scoped and expiry-aware but deliberately epoch-**agnostic**
where `hasLiveLease` is epoch-exact: since the wave-1 held-confirm fence, a stale-generation held lease can
never confirm, so a mere presence test would strand it outstanding forever with no other reaper — a
permanently stuck card, not a slow one. The charge re-reads the ledger after its awaits, so a confirm landing
mid-scan is neither resurrected by a stale write-back nor charged after it reset the budget. Attempts reset
only on a genuine confirm, so a bridge that acks without notifying cannot suppress the stuck flip.

The stuck flip is evaluated **both before and after the wake dispatch** (wave-1 T3 review), and the
before-check is what makes the flip rule hold for the *cold relaunch* route. The rule — attempts ≥ 5 ∧
oldest age > `deliveryStuckAfter` — is unconditional on route, but a resumable card's only route is a cold
relaunch, and `resumeInCard` bumps the epoch the *post*-wake flip is fenced to, so that flip can never fire
for it. Left with only the post-wake flip, a card whose relaunch boots but never emits a proven current-gen
confirming signal (the seed-drop residuals — a provisional card with no watermark, or a resume that never
confirms) would relaunch-churn on the lease-expiry period forever, re-charging and re-driving without ever
setting `deliveryStuckSince` — a state B5b cannot surface because B5b is surfacing-only and reads a
B4-stable flag. So the arm evaluates the flip against the card's *current* generation **before** dispatching
the next relaunch: once the budget is spent and the age gate holds, it flips and skips the wake, so the
churn terminates in the human-visible stuck state the contract requires. The flip matches the card's
*current* phase — and that phase can be `.dead`, not only `.live(.waiting)`: a `.dead(.resumeFailed)` card
is still resumable (`isResumable` keys on capability + session id + transcript, with no dead-reason check),
so it skips the unresumable-dead shortcut and would churn identically. So the flip's expected ownership phase
is decoupled from the attempt-budget bypass — the pre-wake flip expects `.dead` when its snapshot is dead
while still requiring the full budget, and only the unresumable-dead shortcut both bypasses the budget and
expects `.dead`. The post-wake flip is untouched and still covers the in-place / no-relaunch routes;
`flipStuckIfExhausted`'s own pre/post-write revalidation keeps a just-re-armed (send/confirm) or
not-yet-exhausted card from being falsely flagged.

**Stuck is stable and double-conditioned.** A card flips `deliveryStuckSince` only when the retry budget is
spent *and* the oldest pending message has outlived `deliveryStuckAfter` — either alone lies. Once stuck the
arm goes quiet, so the queue stays editable and the human's clear/retry window is never raced by a re-lease;
it still runs `clearStuckIfDrained`, so an emptied inbox clears the flag. The flip re-validates its guard on
the actor immediately before the `store.update` write **and compensates after it**, because the update itself
suspends: it re-reads the queue first and the actor-local budget last, and emits only the final state, so no
subscriber ever observes a transient flip — which matters because B5b's tracker fires once on false→true and
would send an irreversible push for a stuck state that never really existed.

**The channel-push wake is built in the D increment, not on this ladder.** The Claude no-restart wake is a
simple MCP server *push*: the wake empirics showed a correctly-configured `notifications/claude/channel`
push autonomously wakes an idle interactive Claude at turn-end, so no daemon-side parked long-poll registry
is needed. B's wake ladder therefore carries only the agent-agnostic rungs — CLI-wait defer,
outstanding-lease defer, cold resume intent — and the channel route rides on top in D. `wakeTransport`'s
`.controlChannel` case, the `claudeChannels` config switch, and the `DeliveryRoute.channelPush` lease flavor
are the capability seam D routes on; they are inert here (no adapter reports `.controlChannel` yet), so the
ladder never selects the channel rung.

Two smaller decisions ride along. The funnel's wake-on-live moves **below** the state broadcast rather than
being detached: `wake` now records the cold resume intent inline (holding `deliveriesInFlight` across the
ladder), so the nested `.relaunching` upsert must not precede the `.live` one it supersedes — reordering fixes
that while keeping the funnel wake awaited (deterministic) and spawning no task per `.live → .live` telemetry
churn. And `Inbox.drain`/`drainFirst` are deleted outright: after B3's de-drain they had zero production
callers, and a public remove-without-receipt primitive is exactly the trap the whole at-least-once design
exists to eliminate — the four PRs basing on B4 could otherwise reach for one and silently reintroduce
remove-before-receipt.

### `send` is a convergence verb with an idempotent message id (B5a)

`send` is no longer a `.mutation` — it is a `.convergence` verb, because the persisted intent it records is
the non-empty inbox row itself, and the delivery arm drives that intent to empty. The gate stays
non-archived: a send to a dead card persists intent the arm revives. The handler carries a **client-minted
message id**, advertised *optional* in the catalog but required at the daemon boundary and stamped by every
client seam (CLI `--id`, the MCP bridge, the board store) exactly as `spawn`'s card id is — so an agent can
omit it and still get a stamped, retry-safe id, while a seam that forgets one fails loudly instead of
silently re-delivering. The CLI mints only when `--id` is *absent*: a present-but-unparseable value is
rejected with an error, never quietly replaced by a fresh UUID — a mistyped id whose first reply was lost
would otherwise re-run into a *different* UUID and double-deliver, defeating the very idempotency the id
exists for (the same guard covers `spawn --id`).

The id makes `send` idempotent, and the dedup is **one atomic Inbox operation** —
`enqueueIfUnknown(cardId, text, id)` checks pending messages *and* the confirmed-ids ring and appends in a
single actor call. Atomicity is not incidental: `OrchestraService` is reentrant, so a split
check-then-append across two awaits would let two concurrent same-id sends both observe "unknown" and both
append — the exact race B2's atomic `claim` closed. The append is also **transactional**: the in-memory row
is published only after the disk commit succeeds, and a `persist()` throw rolls the append back before
rethrowing. Otherwise a failed first send would leave the id in memory, the contracted retry would dedup to
"already pending" and `send` would report success, yet the message never reached disk — lost on the next
daemon death. Rolling back means the retry genuinely re-enqueues and the acknowledged send survives a
restart (the same discipline guards `enqueue`'s dedupKey path). This is the at-least-once floor the whole B
increment exists to hold: duplicates over loss, never silent loss. Because `confirm` tombstones the id in the ring, a retry
whose response was lost is a true no-op *even after* the message was delivered and removed. A replay returns
the id and a card snapshot having mutated no delivery state and fired no wake; only a genuinely new message
re-arms the retry budget (resets attempts, clears any `deliveryStuckSince`) before its opportunistic wake, so
a stuck cold card gets its whole budget back rather than a single doomed retry. Inbox mutations bump no board
`rev` and emit no task event — clients inspect the queue through the `inbox` verb, as before — so on a
running, non-stuck card `send` is observably event-silent.

The inbox editor is the third owner of the stuck-clear (beside a confirmed delivery and an emptied inbox). A
stuck card whose message a human **edits or removes** force-releases the lease (B1) but would otherwise stay
wedged with `deliveryStuckSince` set and its budget spent — the arm short-circuits a stuck card, so the
edited message would never be re-driven. So the editor re-arms it. The re-arm is scoped to the edited
message's **true owner**, not the caller's ref: `inbox-remove`/`inbox-edit` mutate globally by message id, so
`Inbox.remove`/`update` return the affected message's `cardId` and the service re-arms *that* card — a
cross-card or nonexistent id therefore leaves the caller's card untouched. The re-arm is gated on the stuck
flag (a healthy card's accruing budget is never reset by an edit, which would mask a genuinely failing
delivery), and `inbox-reorder` is excluded because it preserves leases and disturbs no live claim. The
re-arm also **fences the stuck flip across both pieces of state it touches**: clearing `deliveryStuckSince`
is a suspending `TaskStore` hop, and zeroing the service-local attempt budget is a separate write, so
between them the durable flag is nil while the budget is still spent — a concurrent `flipStuckIfExhausted`
landing there would re-stamp stuck and wedge the card with a spent budget the arm never re-drives. So the
service holds the card in a **reference-counted** `reArmingCards` fence from before the clear until after
the reset, and the flip reads a fenced card as "budget not spent" — no flip can re-stamp in the gap, and
once the fence lifts the budget is already zero so none fires anyway. The count (not a bare set) is what
keeps two overlapping editor ops on the same card safe: the second op's exit decrements rather than
clearing the shared membership, so the fence stays up until the *last* in-flight re-arm returns.

**Surfacing a stuck card is a pure edge-detector over the flag the arm already sets.** Once a card carries
`deliveryStuckSince`, two more surfaces make it visible to the human without any new daemon state: the Needs
You queue's reason chip and a one-shot notification. The chip is derived, not stored — `NeedsYouQueue.reason(for:)`
returns `.deliveryStuck` (📪) whenever `deliveryStuckSince != nil`, ranked *above* `humanTurn` (the stuck card
is the one specifically needing a human) but below `permission`/`died` (a crash still wins recovery); no
`DisplayState` field is widened for it. The notification is the subtler half: a stuck flag going true is **not**
a phase transition, so the existing `lastPhase`-keyed one-shot can't fire on it. So `AttentionTracker` gains a
per-card "was stuck" memory (`stuckCards`) and the transition core gains two pure helpers — `currentStuckTrigger`
(which stuck cause a card warrants) and `stuckRise` (the false→true edge). The one-shot fires on the *boolean*
rise, not the cause: a card that stays stuck while its cause changes (a delivery confirm clears
`deliveryStuckSince` in the same tick a merge stalls) never left "stuck", so it never re-fires — the fix for a
double-banner the naive per-cause edge would send. This matters because the arm already emits only the final
stuck state (it re-validates its flip pre/post-write), so the tracker sees a clean false→true and can push an
irreversible notification safely. The daemon push path **seeds a boot baseline** before it consumes live
events: `subscribe()` replays no snapshot and the tracker suppresses every first sighting, so without a
baseline a card that was alive at a daemon restart and *then* dies (or goes stuck) would have that
transition consumed as its first observation and never notified. So `PushNotifier.run` subscribes first
(so nothing landing in the window is lost), then takes an **atomic `(tasks, rev)` baseline** and primes the
tracker from `tasks` via `observe` — first-sighting-suppressed, so seeding fires nothing — so a card
already dead/stuck at boot is the baseline and never re-notified, while a genuinely new post-boot
transition still fires. The **revision boundary is load-bearing**: every event buffered between the
subscribe and the snapshot is dropped when its `rev <= baseline.rev`, because it is causally *older* than
the seed yet already reflected in it, and replaying it against the newer seed would misfire — a windowed
death would no-op (`dead→dead`) while a superseded `waiting` would fire a *stale* needs-you against a
`running` seed. Phase idempotency alone cannot tell a stale replay from a real transition; the rev
boundary is what distinguishes them, and only `rev > baseline.rev` events (genuinely post-snapshot) fire. The mac banner path (`BoardStore.apply`) and the daemon push path
(`PushNotifier` → `AttentionTracker`) both resolve their one notification through the *same*
`AttentionTransition.notifyTrigger` authority, so the two surfaces can't drift — and that authority reconciles
the phase edge and the stuck rise into a single trigger with the *same* precedence the queue uses:
`died`/`permission` (recovery- and block-critical) outrank a stuck rise, which outranks `needsYou`. So a card
that (in some future path) both died and went stuck in one event still pushes the recovery-critical `died`, not
the stuck one — the banner can never disagree with the queue.

**Merge-stall rides the identical seam.** `TreeStat.mergeStalled` — the merge-request loop's sticky give-up
flag (its own rationale is [below](#branch-tree)) — means the same thing to a human as a delivery stuck ("this
card is wedged, come look") from a different cause, so it surfaces through one stack, not a parallel one:
`reason(for:)` returns `.mergeStalled` (🚧, below `.deliveryStuck`), and `currentStuckTrigger` treats it as the
second stuck cause. It is read independent of the underlying `TreeState`, so a card that is both `.stale` and
`mergeStalled` surfaces the stall — the flag stays a flag precisely so the tracking state keeps computing
underneath. This is a *second* Needs-You / push surface, not the first: the flag already renders as a card-face
warning badge (`CardView`/`BoardCardCell`), which stays; B5b adds the queue row and the notification on top.

### Tree counters: daemon-observed child progress

The card face draws a wave-progress bar — how many of an orchestrator's children have merged (`n`) out of
how many it planned (`m`). Both live on `treeStat` as a second, child-facing dimension alongside the
parent-facing `state`/`behind`, and both are **daemon-observed**, for one reason: the lineage store is
**current-state-only**. When a child merges, its lineage entry is *erased* — that is how a merged branch
leaves the tree — so a client scanning the live card list at any later moment sees only the survivors and
**cannot reconstruct** how many already landed. The count has to be recorded at the instant of the merge,
by the only party present then: the daemon.

**The counter increments on a merge-classified lineage-entry removal, and only then.** The rule is exact
because its whole job is to never double-count. There is one funnel — `BranchLineage.recordMergedChild` —
through which every merge-classified removal passes: the `shipped` verb today, and any future merge-watch
detector. It runs under the lineage actor's existing serialization and does two writes as one step: remove
the child's link, then increment `branch.<parent>.orchestra-merged-count`. **The child link's existence is
the idempotency guard.** A second observer of the same merge, or a post-restart re-detection (an "is
ancestor" test is a *level*, not an edge, so it re-fires forever), finds no link and no-ops — the count
moves exactly once. Merge *classification* stays with the caller: `shipped`'s advanced-past-base gate (and
a detector's zero-commit-ancestor guard) decide whether a removal is a merge before calling the funnel;
a non-merge removal (re-parenting, abandoned-branch cleanup) calls plain `clear` and never counts.

The two writes are separate `git config` invocations, so a crash can land between them. The removal is
done **first**, and the increment only after a strict re-read confirms the link is gone: a crash between
them therefore leaves the entry removed but the count un-bumped — a bounded **undercount**, which
re-detection cannot turn into a double-count because the guard already trips. Increment-first would
double-count on replay; a durable transaction would remove even the undercount but is not worth the
machinery for a cosmetic bar, so the undercount is the accepted failure mode.

**`plannedChildren`** (`m`) is the orchestrator's declared intent, not an observation: `set-planned` writes
it to `branch.<b>.orchestra-planned`, and the bar draws a dashed remainder toward it. **`drained`** marks a
wave finished *by merges* — it is set **only** inside the merge-removal funnel, when that removal leaves the
parent with zero lineage children, and cleared whenever a new child link appears. It is provenance-bound on
purpose: were it derived from "zero children remain," re-parenting the last child away (a non-merge removal)
would falsely raise it. It rides the persisted `treeStat` (so it survives restart) and is nudge **input**
only — a later client slice reads it to suggest "wave done — move to Review?"; the daemon takes no action.

Because both counter fields ride the same `treeStat` that many parent-facing writers rebuild from scratch
(`set-parent`, `merge-request`, the remote redirect, the recompute funnel), every such writer carries the
child dimension forward — the same discipline that carries the merge-request `nudges` — while a dedicated
`recomputeChildProgress` is their sole authoritative setter. This also lets a **parentless root** broadcast
its wave counters: it has no parent link, so the parent-facing recompute yields nothing, but the
child-facing recompute still emits a stat on a neutral `inSync` base.

**`hasPendingDelivery`** is an unrelated broadcast bit sharing the same "daemon knows, client can't" shape:
true iff the card has a claimable inbox message or a live delivery lease. It is maintained in the per-tick
delivery reconciler — *before* the deliverability guard — so it arms even for a running card (whose `wake`
returns before delivering) and disarms when the queue drains, neither of which a wake- or confirm-only hook
would catch. Stall detection reads it so a card with work still in flight is never mistaken for idle.

### The attention system

**The contract:** a card emits an attention reason **iff a human action is required** for work to
proceed, or to stop waste. Not "interesting", not "in progress". Every row has to pass that test, and
that is the only thing keeping amber trustworthy enough to scan for — the moment amber also means
"busy", the board goes back to being a wall of colour you read card by card.

**Done is declared; only stall is detected.** Done-ness is never inferred: the declarations are
`merge-request` ("integrate me"), a move to Review ("review me"), and an attached agent concluding its
turn (see [Done is DECLARED](#done-is-declared-merge-request-and-needs-input)). The stall row is the one
detector, and it doubles as the **safety net** — a card that finishes but forgets to declare goes
quiescent and ambers within `T`, so no completion is ever silently lost. That is why the net is a
generic quiescence test rather than a list of known failure modes: it subsumes unarchived reviewer
pairs, findings nobody consumed, silently-stopped agents, and forgotten declarations without naming any
of them.

**The registry** (priority order — how hard-blocked the work is; the L1 chip shows the first and folds
the rest into a `+N`):

| # | Reason | Predicate | Label |
|---|--------|-----------|-------|
| 1 | dead | `phase == .dead` | "dead" |
| 2 | permission | `.live(.waiting(.permission))` | "permission" |
| 3 | awaiting your merge | `treeStat.state == .mergeRequested` **and no live card owns the target branch** | "merge-requested" |
| 4 | needs input | `pendingQuestion != nil` | "question" |
| 5 | stalled | quiescent past `T`, or a pre-computed merge give-up | "stalled &lt;age&gt;" (the board's `45m`/`2h`/`1d` ladder) / "merge stalled" / "wave done — move to Review?" |
| 6 | context critical | `ctxPct ≥ 85` | "ctx N%" |

Row 3 is the root→main case in practice: a child's parent branch always has an owning card, whose agent
merges it (a grey ⏱, quiet — the owning agent's business, not yours), so only an **unowned** target
routes to the human. It never degrades into a stall, because a declared state explains the quiet.

**Stall is a conjunction of ways the quiet can be *explained*,** and each conjunct is a separate guard:
the card must be idle; its attached agents settled; nothing in the card, its reviewers, *or* its subtree
holding queued work (a descendant with a pending delivery is imminently active, and must not let an
ancestor announce "wave done"); no descendant active; no declared state covering it; and nothing in the
**constellation** — the card plus its attached agents — changed for longer than `T`. Descendants gate by
*activity* only and never move that clock, because "is my subtree busy" and "how long have I been quiet"
are different questions.

Two rules keep one silence from producing several ambers. **Attached agents never own a stall** — a
parked reviewer surfaces through its target's constellation, so an active target defeats the conjunction
indefinitely and the leak lands on the target once the whole pass goes quiet. And **leaf attachment**:
when a tree goes quiet the amber attaches at the cards that actually *stopped*, while ancestors report
them through the L4 rollup instead of ambering for the same silence. One fact, one amber, aggregated
once. A drained root has no children left, so it still owns its own "wave done" nudge — and a nudge is a
reason plus a proposal, never an action: nothing here ever moves a card for you.

`mergeStalled` folds into row 5 as a **pre-computed daemon input** with a sharper label, ahead of the
declared-state suppression, because it rides alongside the very `mergeRequested` state that would
otherwise exempt it. The idle gate still applies, so a card that resumed running carrying a stale flag
does not amber.

**Two folds, one registry, all client-side** (`Attention` + `BoardStore+Attention`): **own** (a card's
own reasons) and **subtree** (how many *descendants* hold at least one reason, self excluded). Mind the
near-homonyms in `OrchestraUI` until the phone adopts this: **`Attention.Reason` / `AttentionSignal`**
are this registry; **`AttentionReason` / `AttentionItem`** are the phone's older, separate queue in
`NeedsYouQueue`. The eye
tint is derived from the same fold rather than from phase, so an amber eye and an amber chip are the
same fact — which also means a reviewer that asked a question or is nearly out of context now ambers the
eye, where a phase-only mapping saw only "blocked or dead". Rendering is in
[App UI § Attention](07-app-ui.md#attention-the-scan-rule).

**Adding a row:** check it passes the contract; check it is derivable from broadcast state (if not, the
*field* is a daemon change first — the reason stays client-side); then add a predicate, a label, and a
priority slot. It flows into both folds and every desktop surface automatically. The phone's Needs You
queue is NOT yet fed by this registry — it still derives its own older reason set in `NeedsYouQueue`, and
adopting the fold is part of the iOS slice; until then a new row reaches the desktop only.

**Two rungs are deliberately deferred, and both are one edit away.** The *detected* sibling of row 4 —
an in-terminal choices box (Claude's `AskUserQuestion`), which blocks mid-turn exactly like a permission
wait and self-clears by state — funnels to the same "question" amber. It is deferred because the daemon
can't yet *detect* an open box, not because none exists: `AskUserQuestion` is real and bridged Claude
sessions have it, but a probe couldn't confirm the daemon sees it — whether an open box fires a hook the
control plane receives, and whether it renders in the tmux pane or on the claude.ai surface, are both
unverified (a freshly-launched non-bridged CLI didn't even expose the tool, so there was nothing to
observe). Codex has no equivalent — its approval prompt is already row 2. So row 4 ships on the declared
verb alone until a detectable producer is confirmed; the natural place that lands is the agent-channels
work (`orchestra://task/897d75` — "Redesign agent status and inbox delivery"), which reworks exactly the
status/hook surface a box signal would ride. Likewise the stall row's **human-paced exemption** — quiet that is a human's
deliberate pacing rather than a stuck agent — needs a human-vs-injected turn signal that does not exist
in broadcast state; the predicate takes the flag as a parameter so it threads in when one does. The
accepted cost is that a card a human set down can amber after `T`; the alternative was synthesising a
turn-source bit through the fenced report/delivery path for an edge case.

## Shipped feature history

The v1 architecture (daemon + control plane + two-way hook protocol + per-card worktree + session
recovery + activity feed + sessions debug handles) is documented in
[chapters 2–7](02-architecture.md). On top of it, four feature PRs shipped:

| PR | Delivered | Key decision |
|----|-----------|--------------|
| **PR1** — read-only inspect | An inspector button that opens a read-only `claude` in a card's worktree (read/search/git, no writes). | Two independent locks (tool denial + sandbox `denyWrite`); a normal conversational agent that just can't write (not "plan mode"); throwaway and untracked. |
| **PR2** — task schema `cwd`/`origin` | Migrated `Task` from a single `worktree: String` to `cwd: String` + `origin: CardOrigin`. | A *total* `cwd` (no `effectiveCwd` helper); a 3-way `origin` enum instead of two bools (which would have an impossible 4th combo); behavior-neutral (only `.worktree` cards existed after it). |
| **PR3** — freeform & borrowed cards | Cards that run in an existing directory the user doesn't own (`.borrowed`), in a standalone freeform region, plus the `.readOnly` access mode for tracked read-only cards. | Sandbox-as-boundary (no allowlist gate); rescoped the shared-worktree badge/refcount to worktree cards only. |
| **PR4** — scratch cards | A scratch spawn mode (board, CLI `--scratch`, MCP) that makes a fresh `~/.orchestra/scratch/<id>` dir and `rm -rf`s it on archive; startup sweep of orphaned scratch dirs; auto-trusts the dir so the autonomous agent never blocks on Claude's trust dialog. | Double-gated delete (origin check + path-under-scratch-root check); no dirty-guard (the user moves out anything worth keeping first). Trust is *granted* (not mirrored) because Orchestra owns the dir — there's no source repo to mirror from — while borrowed dirs are left to Claude's own prompt. |

Beyond those four feature PRs, the first **foundational** PR of the agent-provider forest has also landed —
**A1, the seam-contract freeze**. It froze the
complete **`AgentCapabilities`** descriptor (seven enum-typed flags, *every* variant spelling — including
cases no adapter exercises yet — locked now so later PRs can't drift the shape) and the defaulted
**`AdapterContext.seed`** carrier, and moved core to gate session-seeding and resumability on the
capability rather than on adapter identity or a nil-return implication. It ships **no** user-visible
change — Claude behavior is byte-for-byte unchanged — because it is deliberately just the drift-proof
shape the Codex adapter, telemetry seam, and live-delivery PRs will build behind (see
[the adapter capability descriptor](04-cards-worktrees-sessions.md#agent-adapters)). Unlike a full axis
shipping, this is plumbing, not a feature — so it stays here as history rather than migrating a roadmap
row.

A second forest PR has since landed on top of A1 — **E2, the authMode soft-warn**.
It adds a pure `AuthRateMonitor` value type and an `AuthWarning`
result that watch for heavy parallel fan-out on a single subscription seat and emit an advisory
`ActivityKind.warning` past a threshold — **advising, never capping** (see
[authMode: advise on fan-out, never cap](#authmode-advise-on-fan-out-never-cap) above for the decision and
its rationale). Like A1 it is a single forest PR rather than a whole axis, so it too stays here as history
and leaves the roadmap row for the model-providers/agent-integration axes in place until the full seam
ships.

A third forest PR has landed on top of A1 — **A2, the telemetry-source seam**.
It draws the **transport/parse boundary** the
agent-provider design (D3) calls for: the daemon-side **transport** obtains only *raw* bytes, while the
raw→`StatusReport` **parse** is the **adapter's** own, because that conversion is agent-dependent. A2
relocated the parse out of the `orchestra` CLI target (the former `ReportHelper.map`/`toolDesc`) into a new
defaulted protocol method `Adapter.parse(_ raw: RawTelemetry) -> StatusReport?` (added with a `nil`-returning
default in `extension Adapter`, so no conformer breaks) plus a `RawTelemetry` envelope
(`hooksPush(kind:payload:)` for pushed hook events, `fileTail(line:)` reserved for a future rollout tailer;
`ptyScrape` deferred — no v1 consumer). `ClaudeCodeAdapter.parse` now owns the `hooksPush` conversion,
carrying the former CLI logic **verbatim**; the hidden `orchestra _report` helper — which *is* the Claude
push transport — calls `ClaudeCodeAdapter().parse(.hooksPush(...))` instead of a local `map`. The daemon's
`report` endpoint and the `OrchestraService.report` seq-gate merge are **untouched**, so Claude telemetry
is byte-identical (the pre-existing `ReportTests` stayed green unchanged). The `fileTail` parse and the
daemon-side rollout tailer that feeds it — the same `adapter.parse` seam from a different transport — have
since landed with the Codex adapter (PRs B1/B2, below). Like A1 and E2, this is a single forest PR of plumbing, not a whole axis,
so it stays here as history rather than migrating a roadmap row.

A fourth landed PR is **C1 — the durable inbox + F3 Stop-drain**.
It builds the first of the design's three live-delivery
functions (see [One seed, four topologies](#one-seed-four-topologies)): a durable per-card **`Inbox`**
store (sibling to `TaskStore`, actor-over-JSON, FIFO-per-card, restart-durable — see
[the inbox store](03-data-model.md#the-inbox-store-f3)), with `send` **rerouted through it** instead of
typing into tmux, and a `StopDrain` helper that composes the pending messages into a 10 000-char-bounded
payload. The delivery rides the Claude Stop hook: on the `stop` event the daemon's `handleHook` drains the inbox
and returns a `HookResponse.continuation`, which the edge encodes as a `{"decision":"block","reason":…}`
continuation so the model reads the queued messages and keeps working. Two decisions shape it: the
merge-back is **turn-end, never mid-turn** — a queued `send` waits for the agent's natural stop rather than
interrupting it — and because `stop_hook_active` is only a *loop-guard* signal on the agent, Orchestra
enforces its **own consecutive-inject loop guard** (`payloadForStop`, cap 25, reset by a genuine
`UserPromptSubmit`) to break a runaway Stop→inject→Stop cycle, leaving messages durable when it trips. (As originally shipped,
C1 reused the shared `notify` command distinguished by `hook_event_name` and a standalone `drain` RPC;
the [first-class-hooks](06-clients-cli-mcp.md#the-hooks--_report-channel) refactor later split `Stop` into its own `--event stop` and folded drain into
the unified `hook` channel, but the turn-end/loop-guard behaviour is byte-preserved.) Waking an *idle* card so it takes a turn to
drain (F2) landed next (C2/C4, below), and `send` was subsequently wired to call that same `wake` right
after it enqueues — so a message to an idle card now triggers a turn immediately (content still rides the
inbox; the wake no-ops when the card is busy/drafting, mid-relaunch, or already watching children — a
genuinely idle `nativeReinvoke` card with no live wait is instead woken via resume-seed, see the
[`send-wakes-idle-card` entry](#shipped-feature-history) below) instead of sitting durable
until the agent's next unprompted turn. Like the forest PRs above, C1 is one live-delivery function, not a whole
axis, so it stays here as history while the roadmap's context-continuity row remains open.

A fifth landed PR is **C2 — F2 wake + the merge-watch conclusion-watch**.
It builds the second of the three live-delivery functions
and the reactive fan-out on top of C1's inbox: an orchestrator card can watch its spawned children and be
woken as each concludes. Two symbols carry it — a `MergeWatch` actor and a `Conclusion` value
(`{cardId, ref, kind ∈ {done, exited}}`), surfaced as the [`wait` command](05-command-reference.md#notes-on-key-commands)
(auto-exposed as an MCP tool; registry↔MCP parity stays green) plus an `orchestra wait <ref…>` CLI verb.
Three decisions shape it:

- **Conclusion is read from real card state, never git.** The prior fan-out bug was calling `git merge-base`
  to decide "merged" — which false-positives a branch with **zero commits ahead of main** as already merged.
  C2 keys conclusion on `OrchestraService`'s own derived card state (`isConcluded`: archived/Done, or dead
  with `deadReason == .agentExited`), the state it already adjudicates. A dedicated regression test pins the
  0-commit case as *not* concluded.
- **The service is the single authority; `MergeWatch` only subscribes.** `MergeWatch` owns **no** detection —
  no git poll, no file stat, no per-card watcher. It parks a `CheckedContinuation` keyed on the watch set (the
  existing `awaitResume`/`resolveResume` pattern) and is resolved when the service — the one writer that marks
  terminal state — calls `concludeCard`. That call fires from exactly two places: `archive` (→ `.done`) and
  the `report` clean-exit branch (agent-exited, guarded so a *recovering* card never counts → `.exited`). A
  transient crash (`sessionVanished`) that may still be revived is deliberately **not** a conclusion —
  "process ended" ≠ "card concluded."
- **Fan-out coalesces; wake is only a trigger.** Watching N children yields **one conclusion per child, as
  each concludes** — not a barrier on all N. `concludeCard` routes each into every registered watcher's
  durable inbox (F3 coalesce) and calls `wake`; several children concluding while the parent is mid-turn all
  enqueue and drain together at its next turn-end, so no return is lost or needs its own wake. `wake` dispatches
  on the adapter's `wakeTransport`: at C2, Claude's `nativeReinvoke` was a no-op *push* — the wake rode the
  background `orchestra wait` process exiting (which the harness re-invokes on) — and Codex's `sendKeys` wake
  landed later (C4, below). (That no-op case was later narrowed: a genuinely *idle* Claude card with **no**
  live wait is now woken by resume-seed; see the [`send-wakes-idle-card` entry](#shipped-feature-history)
  below.) `wait` also short-circuits on an already-concluded child so the re-issue race can't
  lose a conclusion.

Like the forest PRs above, C2 is one live-delivery function, not a whole axis, so it stays here as history;
the remaining live-delivery function — **F1** resume-in-card — has since landed too (**C3**, below), and the
Codex send-keys wake landed after it (**C4**, below), so only the handoff/fork Commands + UI keep the
roadmap's model-providers / context-continuity rows open.

The sixth and seventh landed PRs are **B1 and B2 — the Codex adapter and its rollout-tail telemetry**.
Together they add the **second `Adapter` conformer**
— the first proof the provider seam is agent-agnostic — registered in the default `AgentRegistry`
alongside Claude (`[ClaudeCodeAdapter(), CodexAdapter()]`). **B1** builds the launch/session/trust half:
`CodexAdapter` (`id = "codex"`) launches **access-gated** like Claude — a default card uses Codex's own
default permissioning, a read-only card gets the `-s read-only -a never` preset (`accessFlags`) — uses a
**discovered** session id (it can't be seeded, so `sessionInfo` reads the newest native Codex
`~/.codex/sessions/**/rollout-*.jsonl` back). B1 originally isolated its home with `env["CODEX_HOME"]` and
wrote trust into `config.toml`; that global-file approach was later superseded by a per-launch profile file
(`-p`), which preserves Codex's native home and explicitly applies both trusted and untrusted states without
reading the `TrustLedger`. **B2** makes its
telemetry live end-to-end, and its two decisions are the interesting part:

- **The daemon owns the transport; the adapter owns the parse.** Codex's TUI pushes no hook events but
  appends a JSONL **rollout** file, so telemetry is `fileTail`: a daemon-side `RolloutTailer` actor (a
  per-card byte offset that returns only complete, newline-terminated lines and holds a trailing partial)
  hands each line to `CodexAdapter.parse(.fileTail(line:))`, driven by `OrchestraService.pollTelemetry()`
  in the existing 2-second poll loop. This reuses A2's `adapter.parse` seam from a *different* transport
  and stays strictly split — the tailer never inspects JSON, the parse never touches files. Claude
  (`hooksPush`) is never tailed, so its push path is byte-identical.
- **`ctxPct` is derived from a vendored offline model table, and the parse is rename-tolerant.** Because
  Codex reports no context percentage, the parse computes it as tokens ÷ the context window from a
  **vendored** `Resources/codex-models.json` (`gpt-5.5` = 272 000), never the rollout's own reported
  window — keeping the app fully offline. That per-adapter **offline model table** on `Adapter.models()`
  (context window + flags from an in-repo, PR-updated JSON, no fetch at build or runtime) is its own forest
  PR — **E1**, a root off `main` — which B2 consumes here; it is the
  same offline-model-table decision the [roadmap](10-roadmap.md) records for the model-providers axis. And because the rollout schema drifts, the parse
  normalizes the line's `type` fields (lower-cased, `_`-stripped, substring-matched) so `TaskComplete` /
  `TurnComplete` both mean idle and nested/flat token fields both parse; `seq` is the line timestamp (µs)
  so the [report seq-gate](06-clients-cli-mcp.md#the-hooks--_report-channel) keeps the freshest snapshot.

Like the forest PRs above, B1/B2 are a single provider conformer, not the whole model-providers axis — the
Codex **send-keys wake** has since landed (C4, below) and its launch is now **access-gated** like Claude
(default permissioning, or the read-only preset per card) — but **board-routed approval telemetry** remains
deferred, so the row stays in the roadmap as history is recorded here.

The eighth landed PR is **C3 — F1 resume-in-card with a seed**.
It builds the **third and last** of the design's three
live-delivery functions (see [One seed, four topologies](#one-seed-four-topologies)) on top of C1's inbox:
**resume-in-card**, which reloads a card into a fresh process with clean context while **keeping its session
id** — a *resume, not a blank restart*, so the vendor transcript carries forward and the seed only adds the
new instruction. Three symbols carry it:

- **`HandoffSeed.compose(handoff:messages:)`** — the pure claim renderer that combines an authored
  handoff/fork context (first, trimmed, dropped if empty) and the pending inbox (FIFO) into **one** seed
  payload, bounded to `StopDrain.maxPayloadChars`; it returns the exact count of whole messages rendered, so
  `Inbox.claim` leases only that prefix and leaves the overflow durable.
- **`OrchestraService.resumeInCard(_:seed:…)`** — the F1 entry point. It persists the authored seed and
  delegates to `resume` without draining; the RelaunchStepper's `relaunchSeed` claim calls `compose` at
  launch time. This is the load-bearing ordering decision: a crash before launch leaves every message
  durable, while a receipt confirms only the batch that actually reached the resumed agent.
- A defaulted **`seed:` parameter on the service `resume`**, threaded onto the frozen `AdapterContext.seed`
  (A1). Each adapter then **reads** `ctx.seed` and appends it as the resumed session's **trailing positional
  turn** (Claude after `--resume`, Codex after `resume <sid>`, and `StubAdapter` mirrors it); with no seed the
  argv is byte-identical, so every existing recovery/`Commands`/test caller is unchanged.

Two invariants make it safe: the **`Adapter.resume(ctx) -> [String]?` protocol signature is unchanged** (the
seed rides the already-frozen context field, resolving the roadmap's
[open injection question](10-roadmap.md#open-design-questions) in favor of an opening-turn positional over
`--append-system-prompt` / `AGENTS.md`), and the change is fully additive/defaulted. `resumeInCard` is the
seam D1's `handoff` Command *calls* (shipped below) and the Handoff/Fork UI (D3, below) now calls too — C3 only
wires the seed *through* resume, adding no Command or UI itself. Like the forest PRs above it is one
live-delivery function, not a whole axis, so it stays here as history while the model-providers /
context-continuity roadmap rows stay open for their non-forest remainders.

The ninth landed PR is **C4 — the Codex send-keys wake**.
It fills the `.sendKeys` `wakeTransport` case that C2
left as a no-op, so an idle **non-native** card (Codex, whose TUI has no `nativeReinvoke` push and no Stop
hook) is actually woken by [F2 wake / merge-watch](#shipped-feature-history) — completing the reactive
fan-out across *both* providers. Two decisions shape it, and both keep the fragile part contained:

- **Nudge-only — content never rides the keystroke.** The wake sends a *fixed, content-free* nudge
  (`OrchestraService.sendKeysWakeNudge`, `"Please continue."`) whose only job is to start a turn on an idle
  composer. The inbox payload is **never** delivered by keystroke — it rides F3 (the durable inbox drained
  by the [session seed on resume](#one-seed-four-topologies), the `.sessionSeed` `inboxDrain` Codex
  advertises), so the nudge stays a constant. This mirrors the same content/transport split as B2 (the
  daemon owns the transport, the adapter owns the payload).
- **Detect-and-defer — wake only when idle *and* the composer is empty.** `sendKeysWake` reads the agent
  pane *just-in-time* via `capture-pane` (this single capture **is** the re-check right before the nudge)
  and asks a pure heuristic — `CodexComposer` — whether the TUI is idle-and-composer-empty. Only then does
  it fire. A user draft in the composer, an in-flight turn, an unparseable pane, or a dead session all
  **defer**: the nudge is dropped and the inbox stays durable for a later event-driven wake (a subsequent
  conclusion or turn-end). There is **no retry timer** — a poll loop would risk the F3 inject cap
  (`maxConsecutiveInjects`), which is Orchestra's to enforce (C1), not C4's to duplicate. **Focus is not a
  gate.**

`CodexComposer` is a **pure** heuristic (`String` in, no I/O, no service deps) deliberately isolated so its
fragility is contained and unit-testable: it scans the pane bottom-up for the composer's prompt marker
(`› ❯ ▌ ▶`), treats known greyed placeholders (`"Send a message"`, …) as empty rather than a draft, and reads
`workingCues` (`"esc to interrupt"`, `"thinking"`, …) to tell a streaming turn from an idle one — the only
Codex-specific knobs, and the documented place to tune when the TUI drifts. It is keyed on the `.sendKeys`
`wakeTransport`, **never** on `agentId` (send-keys is Codex's transport in v1, not its identity). This TUI
scrape is explicitly a stopgap: v1 stays on send-keys while watching upstream Codex app-server work to
eventually replace it with a real `controlChannel` `wakeTransport` (the already-frozen enum variant), so the
fragile pane read is a contained, swappable seam. Like the forest PRs
above, C4 is one live-delivery function, not a whole axis, so it stays here as history while the
model-providers / context-continuity rows keep their non-forest remainders open. (The `handoff`
Command — D1 — and the fork/fan-out surfaces — D3 — have since landed too; see the entries below.)

The tenth landed PR is **D1 — the handoff delegation tool (MCP Command + CLI verb)**.
It is the **first agent-facing surface that
*calls*** the three shipped live-delivery functions rather than adding another — a thin `handoff` Command
on the [`CommandRegistry`](05-command-reference.md#registry-commands) that resolves a card ref and
delegates to C3's `OrchestraService.resumeInCard(seed:)`, wiring the F1 *same-card* (replace-the-thread)
[handoff topology](#one-seed-four-topologies) into a callable tool. Three properties keep it thin:

- **No new mechanism — pure delegation.** The Command adds only a schema (`ref` + `context`) and a
  two-line handler (`resolveRef` → `resumeInCard(seed:)`); all the load-bearing logic (persisting the
  handoff, claim-time `HandoffSeed.compose`, kill + `--resume` the same session id, the claimed seed as the
  opening positional turn) already shipped in C3/B3. `SpawnInput`/`spawn` are untouched — stacked (`repo`/`branch`) and
  cross-agent (`agentId`) delegation were already covered by existing spawn params, and the *new-card*
  handoff/fork/fan-out start-actions are D3, not D1.
- **MCP is auto; the CLI is the one manual surface.** Because `orchestra-mcp` maps `registry.commands`,
  adding the Command auto-surfaces it as an MCP tool and keeps the E2E registry↔MCP parity assertion
  (`tools/list == CommandRegistry().names`) green with **no** test edit. The CLI is a hand-written
  `CLIRunner` switch (not auto-derived), so the verb is added by hand — one `case "handoff"` plus a
  `CLIHelp` line — the same one-Command-plus-one-CLI-case shape the [foundational registry-single-source
  refactor](10-roadmap.md) will eventually collapse.
- **The C2 full-set guard is honored.** Every `Command` added to the registry must also be registered in
  `CommandsTests`'s `expected` set or `main` reddens (the lesson C2 paid for); D1 adds `"handoff"` there,
  plus a round-trip test proving the Command dispatches to `resumeInCard`, carries the seed, and keeps the
  session id, and a CLI-surface smoke proving `orchestra handoff` *routes* (not "unknown command").

Like the forest PRs above, D1 is a single Command surface, not a whole axis, so it stays here as history
while the context-continuity row keeps its remainder open; the new-card handoff/fork/fan-out **UI +
start-actions** it left for D3 have since landed too (below).

The eleventh landed PR is **D2 — the delegation guidance skill + AGENTS.md**.
Where D1 shipped a delegation *tool*, D2 ships the
**guidance an agent reads to decide when to reach for it** — a **prose/resource PR** with no new `Command`
and no launch-behavior change. It vendors two markdown resources under `Sources/OrchestraCore/Resources/`,
`.copy`-bundled into `Bundle.module` exactly like the offline Codex model table: `delegation-skill.md`
(a Claude **skill** — `name:`/`description:` frontmatter + body) and `delegation-agents.md` (a Codex
**AGENTS.md** — plain markdown, no frontmatter, read from the cwd). The heuristics are **identical** across
both variants; only the packaging and a couple of per-agent tool-surface notes differ (the Codex file notes
its send-keys nudge may take a beat to surface a conclusion). A minimal `enum DelegationDocs` (mirroring
`ModelCatalog`) loads a variant by name — `load(_:)` returns the raw text or `nil`, never throwing into a
launch path — and `forAgent(_:)` maps an agent id to its variant (`codex` → AGENTS.md, every other id incl.
Claude → the skill, so an unknown future agent still gets correct guidance). The guidance itself teaches
four things: **delegate vs. just continue** (pay the card + worktree + wake round-trip only for isolation /
parallelism / durability / a different agent / its own PR-branch; otherwise do it inline); **the four moves**
— handoff (same-card resume vs. new-card), fork, fan-out, wait — mapped to when each fits; **cards vs.
native subagents** — keep *both*, they are complementary: a **card** for durable · parallel · cross-agent ·
isolated work that outlives your turn and can land a PR, a **native subagent** (Claude's `Task` tool) for
ephemeral in-context read/search fan-out you fold back immediately — reach for a card *in addition to*,
never *instead of*, subagents; and the **reactive orchestration loop** (spawn stack head → background
`wait` → woken on conclusion → drain inbox → spawn next-in-stack). Two properties keep it contained:

- **Unwired *in D2* — since bound by skill-injection (below).** The `DelegationDocs` loader is additive
  resource plumbing — the `ModelCatalog` precedent — and is called from **no** launch path *in D2 itself*,
  which touches no `prepareToLaunch`/seed behavior, so its own launches are byte-for-byte unchanged. The
  binding turned out **not** to ride the D3 `SpawnInput.seed` (a per-*task* carrier) but each adapter's
  `prepareToLaunch` — a standing, seed-independent materialization added in the **skill-injection** PR
  (below), which keeps `start`/`resume` argv byte-identical.
- **Content is the test contract.** Because the heuristics are the deliverable, `DelegationDocsTests`
  asserts both variants load offline from a local file URL, that the skill carries YAML frontmatter
  (`name: orchestra-delegation`) while the AGENTS.md does not, that `forAgent` selects the right variant,
  and that the required anchors (`handoff`/`fork`/`fan-out`/`wait`/`spawn`/`card`/`in-context`/`durable`,
  the "*in addition to* … never *instead of*" keep-both line, and the Claude skill naming the `Task` tool)
  are present in each.

Like the forest PRs above, D2 is content + a loader, not a whole axis — it deepens axis 3's *richer
Orchestra→agent context injection* — so it stays here as history while the context-continuity row keeps its
remainder open; the new-card handoff/fork/fan-out **UI + start-actions** (D3) have since landed (below),
and auto-injecting this vendored guidance on launch — the one wire D2 left open — has since landed too
(**skill-injection**, below).

The twelfth and thirteenth landed PRs are **T1 and T2 — the trust ledger and its human-grant surfaces**,
the agent-provider forest's **permissioning**
track (design Area 3). Together they make "which directories may agents *write* in" a durable,
provider-agnostic, **human-owned** decision — see the [Trust boundaries](#trust-boundaries-allowlist-for-worktrees-sandbox-for-the-rest)
principle above. **T1** built the foundation: a `TrustLedger` (actor-over-JSON, sibling to `TaskStore` —
see [the trust ledger](03-data-model.md#the-trust-ledger-t1)) and `OrchestraService.resolveTrust(origin:cwd:repo:)`,
which maps a card's origin to a `TrustDecision` (`.trusted`/`.needsGrant`) and rides it onto the launch as
`AdapterContext.trustCwd` — moving trust resolution into the **core** so each adapter merely *applies* the
bool (Claude's `hasTrustDialogAccepted`, Codex's `config.toml` `trust_level`) and never reads the ledger.
**T2** then filled the `needsGrant` gap with the **grant surfaces**, and its decisions are the interesting
part:

- **The agent triggers; a human answers — core never self-grants.** The grant seam is a small
  `TrustGrantResolver` protocol whose production `SurfaceGrantResolver` approves `.cli`/`.mcp`/`.app`
  sources — where a human has *already* been gated at the surface — and **denies `.agent`/`.daemon`**.
  That one rule is simultaneously the **autonomy-exemption** (an autonomy card never blocks on trust) and
  the **no-self-grant** guarantee. `OrchestraService.grantTrust(_:source:)` (behind the new `trust`
  Command) is idempotent on an already-trusted path, records `grantedBy: .human` on approval, and
  **fail-closed throws `OrchestraError.trustDenied` (code 1011) on denial — recording nothing**.
- **No `--trust` flag anywhere — the grant is a surface, not a switch.** The human gate lives at each
  *surface* before the daemon `trust` command is ever relayed: the **CLI** `orchestra trust <path>` gates
  on `isatty` (a `[y/N]` confirm; refuses non-interactively with actionable help), and the **MCP** bridge
  special-cases the `trust` tool to `requestElicitation` back over its persistent session to the agent's
  own client, relaying only on `.accept` (no fallback — both v1 targets advertise `elicitation`). The
  `trust` Command auto-surfaces as an MCP tool (registry↔MCP parity stays green; `"trust"` was added to
  `CommandsTests.expected`, the C2 full-set guard), and the CLI verb is the one hand-wired surface.
- **Untrusted spawn is actionable, never blocking.** A `needsGrant` card still spawns — **sandboxed**
  (`trustCwd == false`) — and emits a `.warning` activity naming the cwd and the exact `orchestra trust`
  command to grant it. And `resolveTrust` **demotes a scratch dir that a foreign repo was cloned into**
  (a `.git` present) to borrowed semantics, so external code is never silently auto-trusted.

Automated coverage uses a **`StubGrantResolver`** only (approve/deny fixtures) — the live
`requestElicitation` dialog is a manual, out-of-scope acceptance (design rule O7), and **T2 adds no app
UI**: the `SpawnSheet` trust·read-only·cancel control is **D3** (which has since shipped it — below). Like
the forest PRs above, T1/T2 are the permissioning track, not a whole axis, so they stay here as history.

The final landed PR is **D3 — the delegation UI + new-card start-actions**.
It is the **first surface set that *drives*** the three
shipped live-delivery seams from the board and CLI rather than adding another, closing out the
agent-provider forest — **all 15 PRs merged**. It maps the
four [handoff/fork/fan-out topologies](#one-seed-four-topologies) to concrete actions:

- **Card actions** (act on the selected card, in the [inspector](07-app-ui.md#the-inspector) header):
  **Send** (the existing `send`, F3), **Handoff** (the existing `handoff`, F1 same-card resume), and
  **Fork** — a *new-card* `spawn` carrying a **seed** (the parent's authored slice).
- **Board action** (no card selected, board toolbar → `FanoutSheet`): **Fan-out** — a `batch-spawn` of one
  card per prompt line, each on a suffixed `<branch>-<n>`.

(The **Handoff / Fork / Fan-out buttons here were later removed** and **Send became an inbox editor** — see
the *agent-buttons simplification* at the end of this history; the tools they called are unchanged.)

Two small backend primitives carry it:

- **`SpawnInput.seed`** — a defaulted seed on the **`spawn`** and **`batch-spawn`** Commands (and the CLI's
  `spawn --seed`) that `OrchestraService.spawn` folds **ahead of the prompt** into the single launch
  positional, bounded by the same `StopDrain.maxPayloadChars` live-delivery cap. This is the *new-card*
  seed the Fork / Fan-out start-actions needed, and it is **distinct** from F1's resume-only `ctx.seed` —
  the adapters' `start`/`resume` argv are byte-identical, so Claude and Codex launches are unchanged.
- **`trustState`** — one new **read-only** Command (`{path}` → `{trusted}`) backed by
  `OrchestraService.isPathTrusted`, a pure `TrustLedger.isTrusted` query that **records nothing** (granting
  stays a human act, T2). The [`SpawnSheet`](07-app-ui.md#the-spawn-sheet) freeform mode queries it on every
  cwd change and, when the dir is untrusted, **forces read-only and shows the amber trust · read-only ·
  cancel notice** — the app trust control T2 deferred to D3. `BoardModel` gains
  `handoff`/`fork`/`fanout`/`trustState` wrappers.

Command discipline holds: only `trustState` is new, so it is added to `CommandsTests`'s `expected` set (the
C2 full-set guard) plus a hand-wired `CLIRunner` case, while MCP parity auto-derives; `SpawnSeedTrustTests`
pins the seed-fold order and the query's no-side-effect. D3 also lands the **app+daemon UX-e2e** harness
(`scripts/orch-ux-e2e.sh` with a `fixtures/fake-agent` symlink on `PATH` — no real vendor agent,
`USE_REAL_CLAUDE` unset — and an RPC-driven UC1–UC8 replay; the `screencapture` step is advisory per design
rule O6 and expected to fail on a headless window server). With D3 merged the **whole agent-provider forest
is shipped**; but as with every entry above it is a set of surfaces, not a whole axis — the model-providers
axis still owes Codex board-routed approval telemetry (its launch is now access-gated like Claude, so write
access is no longer clamped off), and agent-integration its richer sub-status — so those rows
stay in [chapter 10](10-roadmap.md).

Landing after the forest closed is **enable-codex — making Codex startable** (commit `cf83921`, branch
`enable-codex`). The whole Codex backend — `CodexAdapter`, its models, rollout-tail telemetry, trust, and
resume/wake — had shipped (B1/B2/C4) but was **unreachable from any client**: the model list surfaced only
the default agent's catalog and `spawn` never received an agent (`SpawnInput.agentId` was never parsed).
This change is pure **reachability wiring**, no new launch behavior:

- **Model→adapter routing — Codex startable from a model-only pick.** `spawn` now resolves its adapter in
  three steps: an explicit **`agentId`** wins → else the adapter that **owns the chosen model**
  (new `AgentRegistry.adapter(forModel:)`, catalog-driven) → else the **configured default**. So the app's
  flat model picker, which sends only a model id, lands a `gpt-5.5` selection on the Codex adapter.
- **Two surfaces for the picker.** `OrchestraService.models(nil)` now returns the **union** across every
  enabled adapter (default agent first), keeping the flat/default-model surfaces (e.g. Settings) working;
  a new `agents()` + `AgentInfo` + [`agents` RPC](05-command-reference.md#server-only-built-in-methods)
  expose the **per-agent grouping** (`id`/`name`/`icon` + each one's catalog) the
  [Spawn sheet's agent picker](07-app-ui.md#the-spawn-sheet) needs. The `spawn` Command gains an explicit
  **`agent`** param; the app's `SpawnSheet` gains an Agent segmented control that scopes the Model picker,
  and `BoardModel` fetches `agents` and threads `agent` through spawn (`ORCH_SHOW=spawn` seeds a mock agent
  catalog for the headless screenshot).
- **Access-gated permissioning.** Codex now honors the card's `access` like Claude: a default card launches
  with Codex's own default permissioning, and only a read-only card gets the `-s read-only -a never` preset
  (`accessFlags`). Board-routed approval telemetry remains the model-providers axis's live remainder
  ([chapter 10](10-roadmap.md)). New tests (`CodexAdapterTests`) pin `adapter(forModel:)`,
  the union `models()`, `agents()`, a model-only spawn landing on Codex, the default preserved, and an
  explicit `agentId` winning. (As-built: see [Agent adapters](04-cards-worktrees-sessions.md#agent-adapters).)

Landing after Codex became startable was **skill-injection — wiring `DelegationDocs` into the launch path**
(commit `7490e5e`, branch `deleg/04-skill-injection`). The original Codex implementation wrote an
Orchestra-owned `AGENTS.md` under an isolated `CODEX_HOME`; it was later superseded by **launch-scoped
Codex configuration**, which keeps the same standing guidance but no longer changes Codex's native home or
global files. The current design keeps the provider boundary explicit:

- **Shared content, provider-owned packaging.** `AgentGuidance` assembles the named delegation and tree
  sections, in a stable order, through the existing per-agent resource loaders. Claude materializes each
  section as a project skill under `.claude/skills/orchestra-<section>/SKILL.md`; Codex joins those same
  sections into one `developer_instructions` value. Core never branches on a provider, and adapters
  choose only their native packaging surface.
- **Codex is launch scoped through a per-launch profile FILE, not inline `-c`.** The first cut passed the
  hooks, the trusted/untrusted project value, and the shared developer instructions as repeated `-c`
  overrides on the launch argv. That regressed every Codex card to a **`.spawnFailed` — "command too long"**
  death before it reached waiting: the developer instructions alone are ~16KB, and a session is created via
  `tmux new-session … -- codex …`, which packs the whole argv into a fixed ~16KB client→server buffer and
  aborts anything larger. So the same content is now written to a per-launch profile file
  (`$CODEX_HOME/<name>.config.toml`, selected with `-p <name>`) by the adapter's `prepareToLaunch` — the
  Codex analogue of Claude's per-card `--settings` file — and both `start` and `resume` carry only the tiny
  `-p <name>`. Codex layers that profile **on top of** the user's native config, so authentication,
  `config.toml`, MCP servers, and session state stay untouched; the profile is `orch-…`-namespaced (hashed
  per cwd) so it never collides with a user profile. The default state path is still used for rollout
  discovery; its injectable resolver exists only for tests. Verified end-to-end on a real isolated Codex
  launch: the card reaches `live/waiting`, directory trust is honored with no prompt, the SessionStart hook
  fires (bypassing hook-trust), the delegation guidance reaches the session, and a resume-seed `send` is
  delivered into the resumed turn.
With this the context-continuity / agent-integration delegation stack remains fully wired end-to-end: the
tools (D1), the surfaces that drive them (D3), and the guidance that says *when* to reach for them (D2) now
reach every launch through a provider-native configuration surface. It deepens axis 3's richer
Orchestra→agent context injection rather than closing that row's structured-sub-status remainder
([chapter 10](10-roadmap.md)).

Landing after the forest is the **agent-buttons simplification + inbox editor**.
D3 had shipped a board
**Fan-out** button and per-card **Send / Handoff / Fork** buttons; this change prunes that surface back to
what the user actually reaches for, on the principle that the natural-language → MCP path already covers
the delegation moves and the board chrome should stay minimal. Three moves:

- **The Handoff, Fork, and board Fan-out buttons are removed** (`FanoutSheet.swift` deleted; the
  `BoardModel.handoff`/`fork`/`fanout` wrappers and `showFanout` state dropped). The underlying tools are
  **untouched** — `handoff`, `spawn`, and `batch-spawn` still work over MCP/CLI — so *reset the context*
  (handoff) and *explore a slice, then get data back* (fork) are served by just talking to the agent. The
  per-card header now shows only **Inbox** + **Archive** (plus View-changes / close).
- **Send → a durable [inbox](03-data-model.md#the-inbox-store-f3) editor.** The one-shot Send composer
  becomes an **Inbox** popover that manages the whole queue: list, **reorder** (up/down chevrons), inline
  **edit**, **delete**, and **append**. The `Inbox` actor gains `remove`/`update`/`reorder`, exposed as
  four registry commands — [`inbox` / `inbox-edit` / `inbox-remove` / `inbox-reorder`](05-command-reference.md#registry-commands)
  — which therefore surface as MCP tools and CLI verbs for free (the same registry-single-source property
  every command has). `reorder` refills only the target card's slots in the shared append-ordered array,
  so other cards' interleaving is preserved; a non-permutation of the card's ids is rejected, not silently
  dropped.
- **The delegation docs steer the removed Fork's use case.** Both bundled guidance files
  (`delegation-skill.md` / `delegation-agents.md`) now surface `spawn`'s `cwd` + `access: readOnly` + `seed`
  options and default an **exploratory/planning fork to a lightweight read-only freeform card in the same
  directory** (no worktree, nothing to clean up) that reports back via `wait` + inbox drain — so the
  natural-language path reliably reproduces what the Fork button did. Worktree-fork (`spawn` with
  `repo` + `branch`) stays documented for when the fork will change files and wants its own branch/PR.

Deliberate scope cuts: **no live count badge** on the Inbox button (the count shows inside the popover
header, `Inbox — N queued` — a live badge would need a new per-card subscription), and reorder uses
up/down **chevrons**, not drag-and-drop (more robust inside a themed popover; the `inbox-reorder` backend
is gesture-agnostic, so drag can be added later with no server change). Like the entries above this is a
UI/surface change, not a whole axis, so it stays here as history.

Landing after the forest is **axis 7 — code review on the board** (commit `bf1c7c1`),
the **first whole extensibility axis built end to end** rather
than a forest sub-PR — so its [roadmap row](10-roadmap.md) migrates here. It surfaces an agent's changes
*inside* Orchestra — a diffstat in the board card's L1 quiet cluster and a read-only rendered diff in the inspector — so a
glance or quick review no longer requires "View changes → Zed". The build is deliberately **lean** (refined
at the 2026-07-01 L3 gate): there is **no** structured/machine-readable diff payload and **no** MCP `diff`
verb — an agent already has a shell in its cwd and runs `git diff` itself, so re-serving it would be dead
weight. Its decisions:

- **Generic `DiffProvider` seam — difftastic default, git fallback.** A `DiffProvider` protocol
  (`Sources/OrchestraCore/Diff/`) has two read-only jobs, both from git: a cheap `DiffStat`
  (`git diff --numstat`) for the board card, and a rendered **ANSI** diff string for the inspector — produced by
  **difftastic** (`difft`, structural/syntax-aware, `DFT_DISPLAY=inline`) when it is on `PATH`, else git's
  own colored diff (`-c color.ui=always`). Both emit ANSI, so one app-side SGR→`AttributedString` parser
  (`ANSIText`) renders either; `difft` is **never a hard dependency** (`Proc.toolExists` gate). Both jobs key
  off the same `git diff <range>`, so the board stat and the inspector render never disagree (untracked,
  never-added files show in neither until staged/committed — a documented limitation).
- **App-only endpoints, not registry commands.** `diffText`/`diffStat` are **server-only built-in
  `ControlServer` methods** (the `openInZed` shape) — the inspector is the only consumer, so they are
  deliberately **not** `CommandRegistry` commands and therefore never surface as MCP or CLI tools (see
  [server-only methods](05-command-reference.md#server-only-built-in-methods)). The same app-only
  `ControlServer` dispatch — never a registry command, so never an MCP/CLI tool — is what carries the
  terminal ownership/takeover RPCs, precisely because an agent must never be able to seize a terminal.
  Everything guards on the
  shipped `Task.origin`: a non-`.worktree` card (`.scratch`/`.borrowed`, which may have no git baseline)
  degrades cleanly to no stat and an empty Diff view — never a fabricated stat. `diffText` caps a huge
  render (256 KB) with an "open in Zed" sentinel so the pane stays responsive.
- **Baseline toggle; parent-relative diffs.** The diff is taken against one of `DiffBase` —
  `.working` (vs `HEAD`), `.branch` (vs the default-branch merge-base — the PR diff, and the default), or
  `.parent` (vs the card's parent branch, for a stacked card). Axis 7 shipped `Task.parentBranch` as a
  nil-default field; the **branch tree** (below) now populates it, so `.parent` shows a stacked child's own
  delta against its parent and falls back to `.branch` only for a card with no parent — and the inspector
  only offers the **Parent** segment once a card carries one. This makes axis 7 the seam
  [axis 5](10-roadmap.md) (the automated PR-review phase) reviews through.
- **Event-driven refresh off the normalized funnel — adapter-agnostic.** The board diffstat recomputes on
  real per-card activity, not a timer: `OrchestraService.report()` — the one normalized funnel every adapter
  feeds (it sees a `StatusReport`, never a `tool_name`) — calls a per-card `scheduleDiffStat` debounce
  (~750 ms) after it persists a delta, plus on card selection. `recomputeDiffStat` persists + emits
  `taskUpserted` **only when the stat changed**, so the funnel → schedule → recompute → emit chain
  self-terminates (no feedback loop). Because the trigger keys off *activity*, not which tool ran, Claude and
  Codex refresh identically with **no adapter code touched** — the same adapter-agnostic principle A2's
  telemetry seam established.

The app side adds the **Agent | Diff** toggle to the [inspector header](07-app-ui.md#the-inspector), the
`DiffInspectorView` ([in-app diff view](07-app-ui.md#the-in-app-diff-view): baseline toggle + ANSI-rendered
read-only diff + "Open in Zed"), and the diffstat (`Nf +N −M`, green/red) in two places: the
[board card's L1 quiet cluster](07-app-ui.md#cards), beside the lineage glyph and model, and the
[inspector header](07-app-ui.md#the-inspector) beside the Agent|Diff toggle, where it costs no vertical
space. The branch tree's compact lineage badge stays beside the branch in the terminal header. That shared
header has no horizontal slack at the default 392pt width, so it degrades in stages (captions → icons →
diffstat) instead of clipping. Editing stays Zed's job (an explicit non-goal), and **inline review
comments/approvals remain [axis 5](10-roadmap.md)**. The two new `Task` fields are recorded in
[chapter 3](03-data-model.md#the-task-card).

Landing after the forest is **reopen — un-finishing a Done card**
(commit `c13e718`, branch `reopen-done-cards`). Archived cards were **terminal and read-only** — the only
actions on a Done row were copy-the-chat-link / copy-the-branch. This change makes archive reversible: a
**Reopen** action recreates the run dir the archive reclaimed and brings the agent back live. Its
decisions keep it small and provider-neutral:

- **Record the reopen intent, then let the reconciler recreate the run dir + revive — no new revival path.**
  `OrchestraService.reopen(_:source:)` transitions the card `→ .creatingWorktree` through the funnel
  (`archived=false`, `deadReason`/`deadDetail` cleared, **keeping its stored column**; the non-resumable
  path additionally rolls prior session ids so the relaunch is blank) and returns. The reconciler's
  steppers then give the card its cwd back per `origin` (the archive removed it):
  `worktrees.ensure(repo:branch:)` for a `.worktree` card — trivially possible because
  [archive keeps the branch](#ownership-orchestra-deletes-only-what-it-made) — a `mkdir` for `.scratch`,
  and nothing for `.borrowed` (never removed) — then relaunch, walking `creatingWorktree → launching → live`,
  with `deriveLaunchFlavor` choosing a resume when `isResumable` (the transcript survived) else a blank
  launch. So reopen adds *zero* revival mechanism; it is a thin composition over the phase steppers +
  crash-recovery code the daemon already runs.
- **Agent-agnostic and idempotent.** Because it rides `resume`/`restart` — which every adapter already
  implements — there is **no** Claude/Codex branch in `reopen`; a Codex card reopens through the same
  call. A non-archived card is returned unchanged, so a double-fire is a no-op.
- **One Command, surfaced everywhere; the app closes the loop.** A single `reopen` `Command`
  (`{ref}` → the updated `Task`) is added to the [registry](05-command-reference.md#registry-commands),
  so it auto-surfaces as an MCP tool and a CLI verb (the C2 full-set guard: `"reopen"` is added to
  `CommandsTests.expected`, plus a dispatch test). In the app, `BoardModel.reopen(_:)` calls the RPC,
  applies the returned card to move it **off the Done list onto the board**, selects it (opening the live
  inspector), and closes the [Done popover](07-app-ui.md#onboarding-settings-recovery-and-popovers); the
  popover row gains an accent **Reopen** pill. `ReopenTests` pins the resumable / non-resumable /
  idempotent branches. Like the entries above, this is a lifecycle/surface change, not a whole axis, so it
  stays here as history.

Also landing after the forest is **`send-wakes-idle-card` — waking an idle native (Claude) card via
resume-seed** (commit `7d8037c`, branch `send-wakes-idle-card`). **Superseded by B4** (see "The delivery arm
and the wake route ladder" above): the `resumeSeedWake` and `recovering`/`relaunchClaimed` mechanisms this
entry describes were retired when `wake` became the single capability-selected chokepoint — the idle-no-wait
case is now the ladder's cold `.relaunching` intent, and the concurrency claim is `deliveriesInFlight`. The
record below is kept for the history of *why* idle-wake exists; the *how* is the B4 ladder. C1/C2 wired
`send` to `wake` a card right after enqueuing, but the `nativeReinvoke` (Claude) transport treated *every*
idle case as a no-op push: it
assumed a background `orchestra wait` whose exit the harness re-invokes on. That holds for the **reactive
fan-out** (a watcher card always has a live wait), but **not** for a plain `send`/queue onto a genuinely idle
`.waiting` Claude card — with no in-flight turn and no live wait, the message sat inbox-durable until some
unrelated future turn. This closes that gap without adding a fourth mechanism:

- **The idle-no-wait case wakes via resume-seed — reusing F1, not a new path.** `wake`'s `nativeReinvoke`
  branch now calls `resumeSeedWake`, which relaunches the card through the shipped
  [`resumeInCard`](#one-seed-four-topologies) primitive (the same engine `handoff` uses): `claude --resume`
  with the drained inbox folded into the opening turn. Delivery still rides the durable inbox (F3) — the
  relaunch only *starts the turn*, so no content is ever typed into the TUI. It is gated to fire **only** when
  the card is `.waiting`, resumable, not archived, not mid-relaunch (`recovering`), and **not** already
  watching children — because a watcher's background `orchestra wait` will re-invoke it on exit, and
  relaunching would kill that live wait and break the fan-out. So Claude now has **two** `nativeReinvoke`
  mechanisms, keyed on wait-state: harness-reinvoke (a live wait) vs resume-seed relaunch (no wait).
- **One `wake`, no per-caller special-casing.** `send` (a just-queued message) and the fan-out `concludeCard`
  (a child's conclusion) now funnel through the **single** `wake(id)` primitive. To keep the watcher no-op
  correct, `concludeCard` now wakes the watcher **before** clearing its registry entry, so `wake` sees the
  still-live wait and defers to the wait-exit re-invoke rather than racing it with a resume that would kill
  the wait. `wake` is idempotent and non-intrusive by construction — it acts only on a card that is idle with
  no turn already coming (`recovering` is claimed synchronously so a concurrent wake defers) — so it can be
  called freely.
- **The send-keys pane-gate is now adapter-owned.** So core's generic wake never names a Codex type, the
  detect-and-defer pane check moved behind a new defaulted `Adapter.canNudge(pane:)` (default `false` — a
  non-send-keys agent never reads its pane); `CodexAdapter` delegates to `CodexComposer`, which moved under
  `Sources/OrchestraCore/Agents/`, and `sendKeysWake` now asks the adapter rather than `CodexComposer`
  directly.

`SendWakeTests` pins the resume-seed happy path plus the running / live-watcher / unresumable defers. This
remains a **stopgap on both transports** — Codex's `sendKeys` leans on a fragile TUI pane-scraper and
Claude's no-wait wake on a heavy relaunch; the agent-agnostic target is a real `controlChannel` `turn/start`
RPC (the already-frozen enum variant) that would retire both — delivering a turn without tearing the
session down. Like the entries above, this
is one live-delivery refinement, not a whole axis, so it stays here as history.

Also landing after the forest is the **column-aware SessionStart orientation + self-move guidance**
(commit `dad7451`, branch `automatic-column`). Until now an agent had to be *told* which phase it was in;
this makes the board tell it. At session start each agent is handed a one-line **orientation** naming its
board **column** (Plan/Implementation/Review), its **access mode** (read-write vs read-only), and its own
**card id** — so a card opened in any lane starts on the right footing without instruction, and can `move`
itself as the work changes phase. It deepens axis 3's *richer Orchestra→agent context injection* on the
existing hook channel, and its decisions keep it agent-agnostic and non-coercive:

- **The brief is pure, live, and agent-agnostic.** `SessionBrief.sentence(column:access:shortId:)` composes
  the orientation as a pure, synchronous value — trivially testable and callable from the `_report` hook
  process — and the daemon serves it live from the adapter-free `handleHook` dispatch (the
  [`hook` RPC](05-command-reference.md#server-only-built-in-methods)'s `session` event; later unified with
  drain by the first-class-hooks refactor) that reads the card's column **live** from the store. So a **reopened or dragged card reflects its
  *current* lane**, not the launch-time `startIn` — the whole point is that the board is the source of truth
  the agent reads at open time.
- **It rides the SessionStart hook's `additionalContext`, not a positional turn.** The brief is *not* folded
  into the launch prompt — a hook covers both a launched-with-prompt card and an idle provisional one
  **without submitting an unsolicited turn**. Claude's existing SessionStart hook (`_report --event session`)
  additionally prints the brief as `hookSpecificOutput.additionalContext`, additively — the session→waiting
  report is byte-for-byte unchanged. A mid-turn `compact` is skipped (the agent already has its bearings).
  This is the open-time counterpart to the F3 Stop-drain's turn-end inbox inject.
- **Codex reaches it through a Claude-parity hook, orientation-only.** Each Codex launch renders the
  bundled `codex-hooks.json` in memory and passes SessionStart (alongside PermissionRequest and Stop) as
  a launch-scoped `-c hooks.<event>` override. Codex's `parse` returns `nil` for SessionStart, so the event
  yields the brief and sends **no** telemetry; Codex telemetry stays the
  [daemon-side rollout tail](#shipped-feature-history) (B2) rather than gaining a second, conflicting
  source. Same brief, byte-identical envelope, both agents.
- **A nudge, not a leash.** The sentence tells the agent to begin on its column's footing and to **keep its
  column honest** by moving itself (`move <thisCard> --col plan|impl|review`) as work crosses a real phase
  boundary — a *suggestion*, since a stale column misleads whoever is supervising, but never a constraint.
  The shared delegation/tree guidance gains a matching "your column is your phase — start on it, and keep it
  honest" section, so the provider-packaged instructions and the SessionStart orientation reinforce the
  same behavior.

`SessionBriefTests` pin the brief's column/mode wording and the Claude `additionalContext` envelope, and a
control round-trip test pins the `hook` RPC's `session` event. Verified end-to-end against an isolated daemon. Like the
entries above, this is one context-injection increment, not a whole axis, so it stays here as history while
axis 3's structured sub-status + more agent commands stay open ([chapter 10](10-roadmap.md)). (It also
foreshadows [axis 1's configurable columns](10-roadmap.md) and [axis 5's automated review phase](10-roadmap.md):
once agents route on their own column, a phase-driven column becomes actionable.)

Also landing after the forest is **vim-style keyboard navigation — a fully keyboard-driven board**
(commit `1c9daed`, branch `shortcuts`). It makes the app
[completely navigable by keyboard](07-app-ui.md#keyboard-navigation) with a scheme built for a vim user —
bare `hjkl` selection, `⌃hjkl` spatial pane focus, `g`-go-to, single-key verbs, `?` help, and the standard
`⌘N`/`⌘T`/`⌘W` accelerators. The central tension it resolves is that the inspector embeds **live agent
terminals**, where every keystroke must reach the pty untouched, so vim's `hjkl` collides head-on with
terminal input. Its decisions:

- **Focus *is* the mode — no global toggle.** Rather than a stored NORMAL/INSERT flag (a vigilance tax) or
  a tmux-style prefix (a per-navigation tax), the active **context** is derived every keystroke from the
  first responder + model state — `board` / `terminal` / `field` / `overlay`. The insight is that Orchestra
  **owns the focus state** (it knows exactly when SwiftTerm holds focus), so "focus is the mode" is
  rock-solid here in a way tmux's `ps`-guessing seamless-nav never could be. `Esc` stays **sacred to the
  terminal** — ejection is spatial (`⌃h`), never `Esc`.
- **Intercept the minimum; edge-aware passthrough.** In terminal context Orchestra intercepts only the
  `⌃hjkl` directions that lead to a **real neighboring pane** (plus `⌘` accelerators, which terminals
  ignore); every other key — and every edge direction with no neighbor — passes straight through to the
  pty. So `⌃h` (board is always to the left) is the *only* control key a focused terminal gives up, while
  `⌃l`/`⌃j`/`⌃k` keep their clear-screen / newline / kill-line meanings.
- **Pure, tested decision logic; one monitor to execute it.** The chord→intent table (`KeyMap`), the
  selection movement (`BoardNavigator`), and the `KeyChord`/`KeyContext`/`KeyIntent` value types live in
  **`OrchestraCore/Keyboard/`** — AppKit-free and unit-tested (`KeyMapTests`, `BoardNavigatorTests`) — while
  the app installs a **single** `NSEvent` local monitor (`KeyboardController`, mirroring the existing shared
  scroll monitor) that derives the context and executes the intent against `BoardModel`. This is the same
  pure-core-plus-thin-app split the rest of the system uses, and it puts the keymap on the shared core the
  [phone client (axis 9)](10-roadmap.md) will reuse. A `ContextChip` in the toolbar surfaces the live
  context.

It shipped in two passes. The first was a **core-nav-first** slice (commit `1c9daed`); a **follow-up batch**
(merge `d16e3dc`) then filled in nearly everything it had deferred — `/` **search** + `n`/`N` match cycling
(a floating `SearchBar` that dims non-matches), **shell-tab `⌃h`/`⌃l` switching** and agent↔shell `⌃j`/`⌃k`
focus (each terminal tagged by its `termWindow`), **combo-box `⌃j`/`⌃k`** candidate movement in the spawn
sheet, **`⌃⇧hjkl` resize + `z` collapse** (driving the same `@AppStorage` the drag handles use), **`f`
link-hints** (home-row labels over every card), and the **`:` command palette** (a fuzzy `CommandPalette`
listing every action with its shortcut inline, so it teaches the keymap). The new intents stayed on the pure
`KeyMap`; the App-side `hintActive`/`showPalette`/`searchMatchIds` state and the shell-tab focus hops in
`FocusBridge` carry the wiring. Only **`x` multi-select** and the **which-key popup** remain deferred (design
Phase 2 / plan *Deferred*), and whether any bindings become user-remappable is an open question left to a
later pass. Like the entries above, this is an app-UX feature, not a whole extensibility axis, so it stays
here as history rather than migrating a [roadmap](10-roadmap.md) row.

Also landing after the forest is the **inbox delivery framing + batching + send cap** (commit `4264575`,
branch `inbox-stop-hook`), on the C1 inbox. It hardens how
the durable [inbox](03-data-model.md#the-inbox-store-f3) *reads to the model* on the live-delivery channels
the two agents distrust. The problem was verified empirically: a queued `send` reaches Claude as the
Stop-hook `reason` framed "Stop hook feedback:" and Codex as a resume seed — framing an agent can mistake for
automated hook noise and refuse to act on, treating a real instruction as an untrusted injection. Four
decisions:

- **A channel-neutral operator-relayed header, shared byte-for-byte across both delivery paths.**
  `StopDrain.inboxHeader` says `Message from the user (relayed to you via Orchestra):` (plural when needed).
  It deliberately says nothing about *how* messages arrive ("turn-end", "hook", "seed") and does not render
  card-to-card provenance in model-facing text, so the Claude Stop-drain (`compose`) and the Codex resume seed
  (`HandoffSeed.compose`, the [C3](#shipped-feature-history) claim render) frame the inbox identically — agent-agnostic.
  This is operator-authorized delivery language, not a claim that the human authored every body. In the
  busy-agent conflict probe, this user-relayed framing was acted on in 6/6 trials, versus 1–3/6 for the old
  inbox framing; the header rides only the inbox portion of a seed, so a pure handoff/fork seed is unchanged.
- **`[k/N]` numbering for multi-message batches.** `StopDrain.renderMessages` numbers a pile-up (`[2/3] …`) so
  the agent treats several queued messages as distinct actionable items rather than one run-on blob — the
  documented mitigation for the "curse of instructions" compliance drop when instructions share a turn. A lone
  message gets no index.
- **Whole-messages-to-fit drain.** `StopDrain.fit` packs as many *whole* messages (FIFO) as fit the
  10 000-char budget and reports how many it consumed; `payloadForStop` then `claim`s exactly that many via
  [`Inbox.claim`](03-data-model.md#the-inbox-store-f3), leasing the fitted prefix and leaving the overflow durable
  for the next turn-end — a message is **never** sliced mid-text. (A lone first message larger than the whole budget is still
  delivered truncated rather than stranded forever.)
- **A shared send cap enforced at enqueue.** [`send`](05-command-reference.md#registry-commands) uses
  `StopDrain.maxMessageChars`, reserving the common operator-relayed header and separator, then validates the
  body before enqueueing. Source metadata never changes that budget because it is deliberately absent from
  the model delivery string. Put large content in a file in the worktree and reference it instead: the inbox
  is a nudge channel, not a document transfer.

Like the entries above, this refines the already-shipped [C1](#shipped-feature-history) /
[C3](#shipped-feature-history) live-delivery path rather than opening a new axis, so it stays here as history.

The same inbox later gained **stored source metadata**. `InboxMessage.source` records **Human** for direct service
and external CLI/MCP sends without a card context, **Card** as a durable title/id snapshot from a card bridge, or
**Orchestra** for daemon-generated/internal nudges (the direct `Inbox.enqueue` default), while remaining optional
so legacy records still decode. This is structured
metadata rather than a `From …` text prefix or render-time inference: an edit changes only the body,
persistence carries provenance through daemon restarts, and the snapshot remains stable when a source card
is renamed or archived. The desktop and iOS inbox editors render that source as `From …`; the Stop-drain and
resume seed deliberately do not, so the delivery text remains trusted operator-relayed context and no source
title can reduce the delivery cap. No human-facing surface needs an edit-author history or a live card lookup.
Source is display provenance, **not authentication**: a local process can set the ambient card id, which is
acceptable in the single-user local orchestration threat model where every sender is operator-authorized.
If that threat model becomes adversarial, future work is session-credential-based non-spoofable attribution.

Also landing after the forest is **remote-daemon connections — running the Mac board against a remote
Linux `orchestrad`** (merge `63bece4`, branch `remote-daemon-impl`). This builds the **reusable
client connection spine** the [phone client (axis 9)](10-roadmap.md#the-nine-axes) needs, proven on its
own driving case: the Mac renders the board while the daemon — and therefore every agent, tmux session,
git worktree, and repo — runs on a remote Linux box reached over SSH. The load-bearing constraint is that
the **wire protocol is unchanged**: the daemon grows *no* network listener (no TCP/WebSocket), reachability
is pure SSH forwarding, and every change is either the Linux *build* of the daemon or the *client* side.
It landed as four workstreams on one spine:

- **A — the Linux daemon port.** `OrchestraCore`/`orchestrad`/`orchestra`/`orchestra-mcp` now compile and
  run on Linux (musl static or native), so the already-committed
  [deploy scripts](08-building-operations.md#deploying-orchestrad-to-a-remote-linux-box) produce a working
  binary. The Darwin-only seams moved behind portable shims: `UDSSocket` gained file-scope POSIX shims (in
  `Platform.swift`) so `listen`/`connect`/`accept`/`read`/`close` resolve on Glibc/Musl/Darwin alike, and
  the BSD `SO_NOSIGPIPE` per-socket guard (kept under `#if os(macOS)`) is replaced on Linux by a per-`send`
  **`MSG_NOSIGNAL`** flag — the same self-close SIGPIPE protection, a different mechanism. `Config.dataDir`
  became a **pure, unit-tested resolver** (`dataDir(isLinux:home:env:)`) that keeps macOS on
  `~/Library/Application Support/Orchestra` but resolves Linux to `$XDG_DATA_HOME/orchestra`
  (→ `~/.local/share/orchestra`), so the socket lands at an XDG-correct path; `reposRoot`/`worktreesRoot`/
  `scratchRoot` stay `$HOME`-relative on both. `DaemonLifecycle`'s launchd bootstrap is gated to macOS (on
  Linux the daemon is systemd-managed — `Restart=always` + `enable-linger` play launchd's keep-alive role,
  while `isRunning`/`ensureRunning` stay cross-platform because they only ping the socket), and the
  Zed/Obsidian launchers became guarded "macOS-only" no-ops so a remote Linux daemon answers those RPCs
  honestly.
- **B — the `Transport` seam + reconnect.** `ControlClient` no longer holds a raw fd; it owns a
  **`Transport`** (`open`/`write`/`readLine`/`close`), with `UDSTransport` the one concrete impl (the
  current AF_UNIX behavior, extracted behind the seam) and a future WebSocket/tailnet transport the swap
  target. The refactor was deliberately behavior-preserving first (route all I/O through the transport,
  full suite green), *then* added the new behavior: a dropped link now transitions **`live → retrying →
  live`**, reconnecting with a **fresh** transport on exponential backoff (~250 ms → 5 s cap, jittered
  without `Date`/random so it stays reproducible in the sandbox) and **re-issuing the subscription** rather
  than dying — with in-flight calls failed so no awaiter hangs across the gap, and the event `AsyncStream`
  finished only by an intentional `close()`, never a transient drop. An observable **`ConnectionState`**
  (`connecting | live | retrying | down`) + an `onState` callback are the UI binding point. Two tests pin
  it: a fake `Transport` that drops mid-stream (asserting the re-subscribe fires and the state cycles) and
  an end-to-end server-restart-on-the-same-socket test. This is the same hardening the desktop app wanted
  regardless of remoting — it was pulled ahead as the roadmap's near-term standalone fix.
- **C — the `Connection` model + Connections settings pane.** A shared-core **`Connection`** value
  (`{ id, name, kind: local | remote, sshTarget?, identityFile?, remoteSocketPath?, remoteTmuxSocket }`)
  with a synthesized, always-present built-in **local** ("This Mac", stable id, never persisted), plus a
  **`ConnectionStore`** that persists the *remote* list + the active id in **`UserDefaults`** — chosen
  deliberately because *which* daemon to talk to is a **client** concern, never the daemon's own config
  (the store resolves a stale/unknown active id back to local). The macOS Settings scene became a
  `TabView` (**General** + **Connections**); the [Connections pane](07-app-ui.md#onboarding-settings-recovery-and-popovers)
  lists/add-edit-deletes remotes, picks the active one, Connect/Disconnects, and shows a live status chip
  driven by B's `ConnectionState`. `BoardModel` stopped hard-wiring `Config.socketPath` — it reads the
  active connection at launch and on switch and rebuilds the `ControlClient` (a fresh transport per
  connection) accordingly. The `Connection` value and store live in the core so iOS reuses them verbatim.
- **D — the app-managed SSH master tunnel + remote terminals.** The argv is **pure and unit-tested** in
  the core (`RemoteCommands.sshMasterArgs`/`sshExitArgs`/`remoteTmuxAttach` + a `socketPathFits` guard);
  the app's `SSHMaster` owns only the `Process`. On Connect to a remote it spawns **one multiplexed master
  `ssh`** (`ssh -M -S <ctrl> -N -L <local.sock>:<remoteSocketPath> …`, key-only `BatchMode=yes` with
  keepalives and `ExitOnForwardFailure`), forwarding the box's daemon socket to a **short** local socket
  (both paths kept under the ~104-byte `sun_path` cap) that the transport then opens. Auth happens **once**
  on the master; embedded terminals `ssh` into the box's tmux over the *same* control socket
  (`-S <ctrl> -tt … tmux -L <remoteTmuxSocket> attach`) via an `AgentTerminalView.TerminalHost` that is
  `.remote(controlPath, sshTarget)` while a master is live — no extra forward, no re-auth. Because the app
  holds the foreground master `Process`, an unexpected master death is an **exit callback** that trips B's
  reconnect (respawn master → re-point the client). Pre-spawn cleanup unlinks a stale control/forwarded
  socket left by a crash — the primary SSH-multiplexing risk the design flagged — and a bounded wait
  guards against a master that forwards nothing.

Two properties keep the whole thing honest. First, it is **client-only + a build port** — the daemon and
its wire protocol are untouched, so a local board is byte-identical and the remote case is "just another
socket path the `UDSTransport` opens." Second, SSH is **key-auth only** (no password/interactive auth
inside the app; a Tailscale hostname works) — a documented prerequisite, not app-handled. Like the entries
above, this ships the *connection spine* — a `Transport` seam, reconnect, a `Connection` model, and the
Linux port — not the whole [phone-client axis](10-roadmap.md#the-nine-axes), which still owes the iOS app
itself (it inherits this spine); so axis 9's row stays in [chapter 10](10-roadmap.md) as history is
recorded here.

**The `--model` re-seat** adds an optional `model` to `restart`,
`handoff`, and `resume` — declared in the [command catalog](05-command-reference.md#registry-commands), so
it reaches both the CLI and MCP. It **re-seats a card onto another model in place** (same card, same
worktree, same session lineage): `handoff --model` carries the context across, which is how an agent that
finds its task needs a stronger model **escalates itself** instead of spawning a successor; `restart
--model` deliberately drops it. Both vendors were probed for real — `claude --resume <sid> --model X` and
`codex resume <sid> -m X` genuinely re-bind — so the mechanism is a flag, not a workaround. Three decisions
shape it. The id resolves against the card's **own** adapter catalog only (`agentId` is pinned by the vendor
transcript being resumed), and an unknown id is rejected *before* the first mutation, so a refused re-seat
cannot eat the card's durable inbox. The request is staged in
[`Task.pendingModel`](03-data-model.md#the-task-card) rather than applied to `model`, because `report()`
owns `model` and would otherwise revert it from the dying session's statusline — with the epoch fence that
stops an unstamped report landing a card that still owes a launch (see
[report() vs the launch intent](#report-vs-the-launch-intent-pendingmodel-and-the-epoch-fence) above).
And a non-persisted **tripwire** warns once, on the board, if a vendor ever accepts `--model` and ignores
it — an honest check for the mechanism, not part of it. It only accuses the vendor when the agent reports
the model the card was *leaving*, which makes it reliable on a `resume` (an ignored flag leaves the session
on its transcript's model) and best-effort on a blank `restart` (an ignored flag would land on the vendor's
configured default, which reads as a deliberate in-session switch and goes unreported) — a missed warning
being much the lesser evil against falsely accusing an agent that legitimately changed its own model.
Three bugs it surfaced were fixed alongside: a
read-only card came back **writable** when resumed (the shared `.resume` context dropped the card's
`access`, and *both* adapters emit their lockdown flags from it — so Codex read-only cards were equally
affected, and are equally fixed) and a plan card lost `--permission-mode auto` (Claude-only: it is the
`startIn` flag the `.resume` context dropped and `ClaudeCodeAdapter.resume` never re-emitted; Codex emits no
`startIn` flags at all). The third: a **dated** vendor model id (`claude-haiku-4-5-20251001`) fell out of the
catalog into a bare `AgentModel`, dropping the model's catalog metadata — display name, `contextWindow`,
flags — and pinning every later launch to the dated id.

Landing after all of the above is the **branch tree — parent card / branch linking** (shipped to `main`).
A card's branch no longer has to sit on `main`: it can be **based on any other branch** — another card's,
a bare local branch, or a remote GitHub PR — and the card's whole lifecycle (diff, sync, ship, redirect,
notify) runs relative to that **parent** instead of `main`. Cards form a family tree; each card sees, syncs
with, and ships into its parent, and the tree self-repairs when any parent lands. It surfaces as a set of
commands (`spawn --base`, `set-parent`, `tree`, `synced`, `shipped`, `merge-request`, `borrow`, `release`)
plus two decode-with-default `Task` fields (`parentBranch`, `treeStat`) and the board affordances (base
picker, `⤴ parent` chip, `↓N`/restack/merge-requested badges, same-column tree indentation, parent-relative
diffs by default). The load-bearing choices, and what each discarded:

| Decision | Why | Discarded alternative |
|---|---|---|
| Parent = a **branch ref**; the parent *card* is always **derived by lookup** | no stale pointers; covers main / bare branch / remote PR uniformly; survives card churn | a stored `parentCardId` (lifecycle-repair burden); an enforced parent card (board clutter, inverts the remote case) |
| Lineage lives in **repo git config** (`branch.<child>.orchestra-parent` + anchor OID) | survives card/daemon churn; migrates on `git branch -m`, deletes on `-D`; plain-git debuggable; git-town/Graphite precedent | a Task-only field (dies with the card); a `refs/notes` metadata blob (overkill, opaque) |
| **Tree, not DAG** (single parent, many children) | merge-base diffs, `rebase --onto` redirect, and ship semantics all stay well-defined; unanimous prior art | a true multi-parent DAG (needs jj-class conflict machinery git lacks); a one-shot "merge sibling in" covers the real need without lineage change |
| **Merge-down sync; `rebase --onto` only at re-parent; squash at ship** | no rewrites, no force-push, no cascades between concurrent agents; the recorded **base OID** makes squash-redirects phantom-conflict-free | routine rebase-restack (Graphite's human-attended default); merge-commit ship (criss-cross merge-bases); ff-only (too restrictive) |
| **The owning agent performs all branch mutations; the daemon only records + nudges** | git forbids cross-worktree branch updates, and this avoids Graphite's 1.8.4-era data loss — the daemon provably never touches a ref | a daemon-side central restacker / first-class daemon merges |
| A **trust-but-verify choreography** | agent prose compliance is the weakest hop, so one-line git checks (`merge-base`, tip-advanced) put an integrity floor under `synced`/`shipped` | trusting the agent's reports verbatim (review found silent corruption paths) |
| One **canonical→resolvable seam** on the link (`ParentLink.resolvableRef`) | every git verb resolves the parent the same way (`refs/heads/` for local, a private `refs/orch/parents/…` ref for remote), so no consumer can get it wrong individually | per-consumer resolution helpers (the original shape — half the consumers missed a case) |

Because the daemon never touches a ref, the whole flow rides the shipped F3 durable inbox: a parent tip
moving past a child's recorded base fires **one** stale nudge (edge-triggered, `inSync → stale`); a child
shipping under a live parent enqueues a **merge-request** into the parent card (an unowned target records
the request instead — see [done is declared](#done-is-declared-merge-request-and-needs-input)); a `shipped` notifies the
child and the parent card, retargets grandchildren onto the grandparent, and clears the request. The
owning agent then does the actual `git merge` / `rebase --onto` / squash in its own worktree and reports
back with `synced` / `shipped`, which the daemon **verifies** (records the real `merge-base`, gates on the
parent tip having actually advanced) rather than trusting.

The **remote-parent** tier is the one place the daemon observes rather than being told, and squash merges
are invisible to pure git, so merge detection is a **ladder that stops at the first hit**: `gh pr view`
state (authoritative, squash-proof) → a branch-gone heuristic (the remote ref vanished) →
`merge-base --is-ancestor` (proof-positive only). **Only the authoritative `gh` MERGED tier auto-redirects**
(new base = the PR's `baseRefName`); the gone and ancestry tiers are **warn-only** — they raise an activity
for the human to confirm with `set-parent`, never auto-redirecting on a guess. `gh` sits behind a
capability probe (like Zed): absent, the whole feature degrades one tier to pure git rather than becoming a
hard dependency. The design's chief residual risk is that the choreography rides agent compliance — the
verification gates bound the damage but can't force action, so a non-compliant agent stalls its subtree
visibly rather than silently.

Two follow-on fixes hardened the **merge-request re-nudge** machinery, and both carry an invariant worth
keeping. The first — **merge-request nudge backoff** — replaced the flat "re-prod the parent every 300s
forever" loop with a geometric backoff (doubling from a 300s base, ceilinged at 12× it) and an 8-reminder
give-up cap, after which the child lands in a visible, persisted terminal state. Two decisions outlive the
diff. The give-up counter is persisted in `TreeStat.nudges`, **not** held in memory, because the daemon
restarts often and re-arms every `mergeRequested` card on boot — so any in-memory cap is a cap that never
fires; a persisted counter lets a re-armed loop resume at the right point in the backoff. And the give-up
marker is a **boolean `mergeStalled` flag on `TreeStat`, not a fifth `TreeState` enum case** — a broadly
applicable rule for any persisted, forward-compatible record: an older decoder **ignores** an unknown JSON
*key* but treats an unknown enum *rawValue* as **fatal** (the record throws, and `FailableTask` drops the
whole card). A new enum case would therefore have been the first producer of a rawValue that any revert,
app relaunch off main, or lagging phone build couldn't decode — silently losing the card, worktree
orphaned, no `.corrupt` backup because the top-level JSON parsed fine. A flag can't fail that way; it also
keeps the underlying `state` tracking the parent (so a stalled child still gets "parent moved ahead"
updates) while merely outranking it on the card face.

The second — **the nudge-leak + cooperative-pool-starvation fix** — carries two non-obvious lessons the
shipped code doesn't self-explain. The bug pattern: a timer task written `Task { [weak self] in guard let
self else { return }; while … }` hoists the `guard let self` **above** the `while` loop, so the closure
holds a **strong** reference for the loop's entire life and `[weak self]` buys nothing — the actor can
never deallocate, and its `deinit` is unreachable. The fix re-acquires `self?.` per iteration, so the long
sleep holds nothing and the next hop after deallocation yields `nil` and exits. The measured decision: the
three git-forking actors (`BranchLineage`, `RemoteParents`, `WorktreeRegistry`) were **deliberately not**
given custom serial executors to keep their `git` forks off the cooperative pool. Because each is a serial
actor and production holds exactly one `OrchestraService`, at most **three** pool threads can ever be
parked on a fork — measured peak was **1 of ~18 cores** — so starvation is two orders of magnitude away by
construction, and the executor would defend a number that can't grow (while breaking the Linux build,
since `DispatchSerialQueue`'s `SerialExecutor` conformance is Darwin-only). What would flip it: a ≤3-core
deployment (a small VM or a cpuset-pinned container), or anything that creates these actors per request
rather than one-per-daemon. `scripts/pool-probe.sh` is the reusable artifact that measures peak
cooperative-pool starvation in any `swift test --parallel` run and stays in the repo for the day either
trigger arrives.

The roadmap of what comes next — the extensibility axes the system is being designed toward — is
[chapter 10](10-roadmap.md).
