---
project: claude-kanban
feature: mobile-orchestra
type: review
created: 2026-07-06
---

# Deep review — `mobile-impl-orchestration` (the iPhone app branch)

> **ADDENDUM (2026-07-06, after `feat/ios-real-device-transport` landed) — see the "Addendum" section
> at the end.** Card a52b9e implemented the real-device transport (P1–P3-core, 9 commits, ~2,565
> insertions). Net: it lands the exact seam this review asked for and closes the biggest Lens-5 gaps,
> but three of this report's warnings ship unaddressed (main-thread SSH dial, reconnect-reconcile,
> pin-store deletion) and the delta adds two new MEDIUM bugs + a likely-broken device-build path. The
> body below is the review of the base branch as originally written; the addendum re-scores Lens 5.


> Ultrareview-caliber pass over everything this branch adds vs `main` (~22.5k insertions, 206 files:
> `App-iOS/` in full, the OrchestraCore→Kit/UI module split, terminals/takeover, push, spawn, shell
> sync). Method: 7 subsystem review agents + 10 independent finder angles + adversarial verification
> of singleton claims + a gap sweep; every finding below was verified against the code before
> inclusion. **Trust model applied throughout**: single owner, own tailnet, root on the target Mac,
> all app data reset at merge — so adversary-defense code and old-data tolerance are treated as
> deletable. **Constraint applied throughout**: no paid Apple Developer membership (free personal
> team; real APNs push out of scope; `aps-environment` must be stripped for device signing).
>
> This is a review report only — no source was modified. Each finding carries a concrete
> recommendation so it can be cut into implementation cards.

## Executive summary — the eight highest-leverage findings, ranked

1. **Re-baseline on `main` before anything else — every substantive main-side commit since
   divergence (5 of 5) is absent, and the branch deleted or renamed exactly the files main patched
   (merge landmine, CONFIRMED by inventory).** The three that break behavior silently: the
   **non-blocking MCP `wait`** fix (`a356a9b` — the branch's `CommandRegistry` `wait` handler is the
   old blocking body; the natural delete/modify conflict resolution reverts the fix while
   `OrchestraService.watch` merges in as dead code, so it *compiles* and passes tests — orchestrator
   agents' `wait` calls block their whole turn again); the **`ResumeConfirmation` capability**
   (`69bd722` — the preset moved to Kit *without* it, losing both the Codex false-markDead-on-resume
   fix *and* the Claude-side `awaitResume` continuation-leak fix); and
   **`turnCompleted`/`taskCompleted`** (`af8cade`, delegated-card wait completion — the branch
   inserted its `permission` case at the *same line* of `HookChannel.swift:13`, so the conflict
   invites taking one case and losing the other). Also absent: main's `orch-test.sh` hardening
   (`4cb6805`) and the CLAUDE.md multi-agent section (`48c76f1`). Merge `main` into this branch now
   and hand-port all of it; no test catches any of these. *(Effort: S–M, urgency: highest.)*

2. **The app cannot connect from a real iPhone, and there is no device build lane — the branch's
   stated goal is unmet by construction.** Verified: iOS `activate()` resolves a *local filesystem
   UDS path* (`ConnectionSocketResolver` → `Config.socketPath`, which on device points inside the app
   sandbox); the Simulator works only via the shared-filesystem `ORCH_DEV_SOCKET` cheat. On device
   the board is silently Disconnected forever (the 25×200ms connect loop exhausts; the reconnect loop
   only starts after a first *successful* connect), and since every feature is reached through the
   board, ~11k lines of iOS work currently deliver zero on-device value. There is also no signed
   device build: `project.yml` has no `DEVELOPMENT_TEAM`, `build-ios-app.sh` is Simulator-only with
   `CODE_SIGNING_ALLOWED=NO`. The in-flight real-device spec
   ([[ios-real-device-onboarding-and-transport]]) is **accurate and its architecture is right**;
   build its P1 (shared swift-nio-ssh session + `nc -U` exec-bridge `Transport`) plus a `--device`
   signing lane that **strips `aps-environment`** (free-team constraint). Two corrections to the
   spec's "no ControlClient change" claim: `connect()`'s first `open()` is synchronous on the
   caller's (main) thread — make it async before building the SSH transport — and
   `ConnectionSocketResolver` should become a `Connection → Transport` factory rather than a
   path-only resolver. *(Effort: L, the one big chunk left.)*

3. **Reconnect never reconciles — the sync layer's central promise is a comment, not a behavior.**
   `ControlClient` deliberately auto-reconnects without ending the event stream, so
   `BoardModel.refresh()` (its ONE call site is `start()`) never re-runs; the doc comments claiming
   "reconciles on every (re)connect" are false. Consequences, all confirmed: stale board after any
   daemon restart or link drop; a dead daemon shows **"connected" forever** (`.retrying` is treated
   as transient and `.down` is only published by explicit `close()`); the activity feed **duplicates
   up to 200 items on every re-subscribe** (server ring replays on each `subscribe`, client never
   dedups → duplicate `Identifiable` IDs in `ForEach`); and there's a snapshot-then-subscribe gap that
   loses events at startup. On a phone whose socket dies on every backgrounding (no `scenePhase`
   handling exists), this family is the **daily-driver bug**. Fix shape: one "re-assert on (re)connect"
   hook on the `.live` edge doing `refresh()` + push re-register + owner/shell reconcile, dedup
   activity by id, publish offline after N retries, make `connect()` idempotent (second call today
   leaks the transport and spawns a duplicate runLoop → every event delivered twice). *(S–M total.)*

4. **The takeover lease core is excellent; every feedback loop around it is buggy.** The
   `TerminalOwnershipStore` (pure CAS state machine, monotonic epochs) generalizes to N clients
   unchanged — but: (a) `takeOverAgentTerminal` commits the CAS + detaches clients + **emits the
   desktop-unmount event before `agentTarget()` can throw**, so a takeover of a dead-window card
   steals a lease nobody holds and strands the desktop on the placeholder; (b) dismissing the
   takeover cover while the acquire RPC is in flight **orphans a just-granted lease** (teardown ran
   first, `begin()` never re-checks `released`); (c) heartbeat **denial is swallowed** (`try?` → nil
   → stale mirror keeps saying `.holding`) — the phone can sit on "You have control" while the
   desktop owns the window, recreating the resize-fight the lease exists to prevent; (d) the
   desktop's staleness indicator is **structurally always-wrong ~30s into every takeover**
   (heartbeats don't emit; nothing else ever updates `updatedAt` desktop-side) → false "phone
   unreachable — force it back" copy; (e) the terminal reconnect path is lease-blind and re-runs
   `detach-client`, kicking the rightful owner. All are small fixes (commit-order swap, a `released`
   re-check, denial→snapshot, emit-on-heartbeat, `shouldReconnect` guard). *(All S.)*

5. **Delete the adversary-defense stack — ~900+ lines defend a deployment with no adversary.**
   Ranked by payoff: **(a) the TOFU host-key-pinning stack, ~420 lines** (`SSHHostKeyPinStore` 172 +
   pinning delegate/gate + `.hostKeyChanged` plumbing + Settings ▸ Security section + DEBUG reset
   hook + 8 tests). Its own neighbor comment documents the intended design as accept-any-over-
   Tailscale; the pin's only real-world delivery is a re-key footgun ("possible MITM" after a Mac
   reinstall). 3 of 4 reviewing agents independently said delete it; keep the ~100-line tailnet-shape
   guard (cheap, good errors, its loopback escape is load-bearing for the harnesses) and fix its
   now-false comment. **(b) the `listDir` browse confinement, ~50 lines + 3 tests** — pure theater:
   the same socket exposes `exec` (arbitrary `sh -c` as the daemon user), so confining *enumeration*
   defends nothing, while actively blocking the owner from browsing to paths freeform spawn happily
   accepts (dot-dirs like `~/.claude`, `/Volumes/...`). Keep `browseRoots` as UX starting points and
   dotfile *hiding* as declutter. **(c) ~80 lines of decode-tolerance migration shims** in
   `Model.swift` (legacyWorktree + hand-written `encode(to:)` that exists only for it, AgentModel
   bare-string decoder, a dozen `decodeIfPresent ?? default` fields) — owner resets data at merge;
   deleting restores synthesized Codable. **Keep**: the trust ledger/grant flow (it gates the *agent*,
   not the client — genuine accident prevention), the ownership lease, UDS 0700/0600 hygiene,
   `isValidShellWindowName` (tmux-injection *and* collision protection), the Sixel loop clamp
   (main-thread-hang fix, not security). **And one place the branch is UNDER-gated by its own
   agent-vs-owner model**: `send-keys` + `capture` live in `CommandCatalog` (`CommandCatalog.swift:134,142`),
   which `orchestra-mcp` auto-exposes as MCP tools to every card's agent (`orchestra-mcp/main.swift:29`)
   — so an agent can Enter-approve any card's permission prompt programmatically, defeating the
   human-only gate the trust design reserves (the branch carefully kept `listDir`/takeover app-only
   for exactly this reason; `send-keys` looks like an oversight). Move both to the app-only surface
   (or add the `exposure` flag from Lens 1 and mark them app-only). *(Deletion effort: M total, pure
   removal; the send-keys fix is S.)*

6. **Push: good core, wrong target — demote it to a deferred paid-tier phase.** The shared
   transition→intent→gate→payload core is the best-tested code on the branch and provider-neutral.
   But (a) real APNs is **out of scope on a free Apple account** (no `.p8`, no push capability, and
   `aps-environment` breaks free-team signing), (b) the daemon can't even be *given* credentials (the
   LaunchAgent plist has no `EnvironmentVariables`; `ORCH_APNS_*` is read from env nothing sets), and
   (c) two real defects: **pref changes never re-register** (three comments promise it; nothing calls
   it — the daemon keeps a stale scope snapshot and delivers pushes the user turned off while
   backgrounded) and the **payload sound names are macOS system sounds** (`Hero.aiff` etc.) that
   don't exist in an iOS bundle, so sound prefs have no effect. Recommendation: fix the re-register
   one-liner, keep the core + `DisabledPushSender` wiring as the honest paid-tier seam, **stop
   polishing delivery** (the 410-eviction race, JWT nits, and store-side token regex can be deleted
   or left frozen), and route needs-you alerts through the Claude/Codex mobile apps as the memory
   already decided. *(S to settle.)*

7. **Delete the Sixel decoder (~350 lines incl. tests) — it is production-unreachable by its own
   header.** tmux `capture-pane -p` never serializes Sixel back into pane text, so every real frame
   takes the fast path; the decoder fires only on synthetic test input. It's *correct* (the clamp
   holds) but it's speculation waiting on a capture path that doesn't exist — and it would run
   two-pass on the main actor with up to ~67MB allocations if it ever did fire. Reintroduce it in
   the PR that actually forwards image bytes. While in that file's neighborhood: the **capture poll**
   ships up to 256KB every 1.5s with no change detection, no `scenePhase` gate, and a
   parse→re-encode→re-decode `JSONValue` round-trip per tick — add a content hash and a typed decode.
   *(S, mostly deletion.)*

8. **Shell sync: make the broadcast the single writer.** The new `shellsChanged` broadcast is the
   right design, but three things fight it: `newShell()`/`inspect()` still **optimistically append**
   (response-vs-event ordering race → duplicate window entries → duplicate `ForEach` IDs; the iOS
   path already does broadcast-only, correctly); `refreshShellPanels`'s serial per-card loop can
   **clobber a fresher broadcast with an older snapshot**; and `emitShells` broadcasts
   `(try? windows()) ?? []` so a transient tmux hiccup **wipes every client's shell panel**. Delete
   the optimistic mutations, version or re-order the reconcile, and treat a failed `windows()` as
   "don't emit" rather than "emit empty". *(All S.)*

Cross-cutting architectural verdicts worth stating up front: the **module split is correct and
well-policed** (Kit = client vocabulary, UI = shared view-model, boundaries enforced by executable
typecheck gates, not comments); the **adapter boundary passes the third-agent test** (no
`if agentId ==` anywhere in Kit/UI/App-iOS; C1's Codex permission wiring is the model to copy); the
**Transport seam + machine-readable CommandCatalog is exactly the artifact a future web client
needs**. The two structural debts: **BoardModel is a 1,159-line grab-bag** fusing the future
web-client sync core with desktop-only keyboard/palette/pane-resize UX (split `BoardStore` /
`BoardUX` before a third client exists), and the **macOS `AgentNotifier` was never rewired onto the
shared push core built to replace it** (duplicate enums/gate/body over the same UserDefaults keys,
kept in sync only by comments).

---

## Lens 1 — Extensibility & future design

**What's right (keep building on it):**

- **Module split** (`Package.swift`): Kit = Foundation+POSIX client vocabulary; UI = SwiftUI shared
  view-model with a macOS-*conditional* Core dependency; Core keeps everything that forks processes.
  Enforced by `scripts/typecheck-kit-ios.sh` / `typecheck-ios-ui.sh` (grep + isolated-SDK builds) —
  mechanical, not conventional. Keep all three typecheck scripts.
- **Adapter boundary**: adding agent #3 = one `Adapter` conformer + registry entry + capability
  preset + hooks resource. Verified: zero `if agentId ==` branches in shared/iOS code; consumers
  degrade on capability flags. `CodexAdapter`'s C1 `PermissionRequest` → neutral
  `waitReason == .permission` is the pattern to repeat.
- **Transport protocol** (`OrchestraKit/Control/Transport.swift`): minimal and honest
  (open/write/readLine/close), factory-injected, reconnect proven by fake-transport tests. A
  WebSocket transport for a web client fits (one WS message = one NDJSON line). `ClientIdentity` is
  clean and minimal.
- **CommandCatalog/CommandRegistry split**: real improvement, not indirection — `orchestra-mcp` now
  links Kit only; a web client can build/validate requests from the catalog without the daemon.
  Handler bodies are byte-identical to the deleted `Commands.swift` except deliberate additions (and
  the orphaned `wait` fix, exec-summary #1).
- **TerminalOwnershipStore**: pure value-type CAS lease, per-`(card,window)` slots, monotonic epochs
  — N-client-ready unchanged, deterministically tested.
- **Push core** (`OrchestraKit/Push.swift`): pure, provider-neutral, mirrors the macOS notifier's
  semantics by construction.

**Findings:**

- **HIGH · `Sources/OrchestraUI/BoardModel.swift` (whole file) — split `BoardStore` / `BoardUX`.**
  1,159 lines fuse daemon sync (connection, refresh, event application — the future web-client core)
  with desktop-only keyboard nav, command palette, link hints, and `UserDefaults` pane-resize
  (~lines 884–1149), all dead weight on the phone. The branch also added platform divergence as
  `#if os(...)` blocks and inert-on-one-platform members (`phoneTakeoverRequest`,
  `phoneShellWindow`, `pushToken`) *beside* the F2 `PlatformProtocols` seam instead of through it —
  including two parallel `activate()` bodies, the iOS one of which P1 must rewrite again anyway.
  Do the split before (or as part of) P1. *(Effort: L.)*
- **HIGH · `Sources/OrchestraUI/AgentNotifier.swift:17` — rewire the macOS notifier onto the shared
  push core.** It keeps duplicate `NotifyTrigger`/`NotifyScope` enums, duplicate
  `defaultScope`/`defaultSound` tables over the *same* `orch_notify_*` UserDefaults keys Kit's
  `NotificationPrefs` owns, a `shouldFire` duplicating `PushGate`, and a `body(for:)` duplicating
  `APNsPayload.body`; `BoardModel.apply` hand-rolls the same transition conditions
  `AttentionTransition.trigger` encodes. The compiler enforces nothing across the copies — add one
  trigger and Mac banners silently diverge from phone pushes. *(M.)*
- **MED · `Sources/OrchestraKit/Model.swift:412` — shell ownership is a stringly naming convention.**
  `ShellOwner` derives from a `phone-` window-name prefix; everything else is one anonymous
  `.desktop`, so two desktops both classify every `shell-N` as their own (the resize-fight returns),
  a third surface means a new prefix + every parser, and ownership can never transfer — while
  `openShell` *receives* the caller's `clientId` and throws it away. Fine for v1; generalize the
  name scheme to `<kind>-<client8>-N` (or reuse the ownership store) when a third surface appears.
- **MED · `Sources/OrchestraUI/NeedsYouQueue.swift:93–96` — Claude's TUI prompt layout
  (`approveChord=[.enter]`, `denyChord=[.esc]`) is hardcoded in the provider-neutral layer.** Move
  the chords onto `AgentCapabilities` so Codex's structured approval replaces them per-adapter. Also
  `capabilities(for:)`'s silent `?? .claudeCode` fallback (`BoardModel.swift:89`).
- **MED · `Sources/OrchestraCore/Control/ControlServer.swift:187` — 10 new app-only RPCs as inline
  switch cases (13→23 in one branch)** with hand-parsed params, invisible to the catalog's schema
  tests and CLI help. The "don't expose to MCP" motivation is one `exposure` flag on `Command`.
  Defensible at today's size; add the flag before the switch grows again. Related:
  `CommandRegistry.build()`'s `fatalError` only catches schema-without-handler; a handler with no
  catalog entry is silently dropped and the 1:1 test is tautological in that direction — add the
  orphan check. *(S.)*
- **LOW** · `AgentTerminalOwnerKind` is a closed two-case enum on the wire (a `web` client is a
  coordinated migration — consider tolerant decoding before then) · `takeoverAttach` bypasses the
  `TerminalHost` environment injection (`AgentTakeoverView` constructs `IOSTerminalHost()`
  concretely) · `CommandCatalog.swift:38` hardcodes `'claude-code' (default) or 'codex'` in the spawn
  schema string (generate from the registry) · `SpawnSheet.swift:65–74`'s `claudeFallback` bakes a
  frozen Claude model list into the phone UI (show an empty/disabled picker until the daemon's
  `agents` answer arrives; the ids *will* rot) · Kit's `Config` carries daemon-only vocabulary
  (`codexHooksPath`, `scratchRoot`) — harmless, note it.

## Lens 2 — Verbosity / unnecessary code (the DELETE list)

Everything here is a concrete deletion the owner can green-light; "→" names the replacement if any.

| # | What | Where | Lines | Why |
|---|------|-------|------:|-----|
| D1 | TOFU host-key pinning stack | `App-iOS/Terminal/SSHHostKeyPinStore.swift` (all), `SSHPTYChannel.swift:76–118, 224–225, 267–271`, `TerminalByteChannel.swift:9–11` + `IOSTerminalView.swift:127–131` (`.hostKeyChanged`), `SettingsSecurity.swift:43–86`, `DebugSupport.swift:23–31`, `ORCH_RESET_HOSTKEY_PINS` in 2 scripts, `IOSAppTests.swift:268–302` | ~420 | Redundant with the tailnet guard whose own comment documents accept-any as the design; only real-world effect is the re-key footgun. → accept-any delegate; fix stale comments `SSHEndpoint.swift:66–84, 128–134`. |
| D2 | Sixel decoder + capture-run plumbing | `App-iOS/Views/CardDetail/SixelDecode.swift` (all), `AgentTab.swift:197–219`, 6 tests in `IOSAppTests.swift:171–257` | ~350 | Production-unreachable (tmux `capture-pane -p` never emits Sixel — the file's own header says so). Reintroduce with the image-forwarding PR. |
| D3 | `listDir` browse confinement | `OrchestraService.swift:798–800, 821–825` (`assertAllowed`, bounded parent), `isSubpath` (:773–779), top-most collapse (:764–769), 3 escape tests in `ListDirTests.swift:61–89`, the "browse boundary" section of [[ios-remote-dir-browser]] | ~55 | Theater: the same socket exposes `exec`; the boundary only blocks the owner (dot-dirs, `/Volumes`). Keep `browseRoots` as root-listing UX + dotfile hiding as declutter. |
| D4 | Migration/decode shims | `OrchestraKit/Model.swift:295–297, 323–352` (legacyWorktree + hand-written `encode(to:)`), `:86–91` (AgentModel bare-string), `:287–320` (`decodeIfPresent ?? default` dozen) | ~80 | Owner resets all data at merge; deleting restores synthesized Codable. **Keep** `SpawnInput.init(from:)` (wire tolerance for CLI/MCP, not migration). |
| D5 | Dead platform seams | `App/MacPlatform.swift:46–59` (`MacTerminalHost` — injected, read by nobody, and *wrong*: hardcoded light theme + `.local` host), `PlatformProtocols.swift:24` (`SystemOpener.open(path:)`, zero callers, 3 conformers), `IOSPlatform.swift:14` (test-only clipboard read) | ~50 | YAGNI; the terminal host would ship a light-themed local-socket terminal to a dark-mode remote user the day it's first consumed. |
| D6 | Deliberately-unwired daemon seam | `orchestrad/main.swift:20–23` note, `ControlServer.swift:13, 294–305` (`onClientDisconnect`, `connectedClientIds()`), 2 tests | ~60 | Speculative "future eager-reap"; leases already reap by heartbeat timeout. |
| D7 | Stub残骸 + DEBUG growth | `AgentTerminalStubs.swift` (inline `RecoveryView` at `AgentTab.swift:31`), `DebugTerminalTab.swift:56–77` (manual UUID-entry takeover Form; keep the env-driven auto path — it's harness-load-bearing), `isStub` machinery (`CardDetailModel.swift:41`, `CardDetailView.swift:91–98`, `testNoTabIsStub`) | ~120 | Product surfaces shipped; the scaffolding remained. |
| D8 | Dead API / dead fields | `CommandRegistry.swift:10–11` accessors + `.names` + `CommandCatalog.schema(_:)`/`byName` (zero consumers) · `OrchestraKit/Push.swift:130` `platform` field (written, read by nobody) · `ControlClient.swift:189–191` `unregisterDevice()` client wrapper (zero call sites) · `ControlServer` `PeerConnection.isSubscriber` (write-only) · `ConnectionStore.swift:21` decode filter (defends impossible persisted state) · `InfoTab.swift:185` unused `chevron:` param · `DesktopTerminalPolicy.swift:25` ignored `isStale` param (its caller computes staleness purely to feed it) | ~60 | Each implies consumers/behavior that don't exist. |
| D9 | Duplication cluster (consolidate, not delete) | `relativeAge` ×5 (4 iOS + desktop `CardView.swift:204`) → one OrchestraUI func · status-label switches ×3 vs `Theme.statusLabel` · `ModeChip`≈`ModeAccessChips`, `CtxMiniGauge`≈`CtxGauge`, `filePath`/`centered` copy-paste, `String.trimmed` ×2 with *different* charsets · `sendAgentKeys` ≡ `sendKeysToAgent` (same RPC, same module — delete one) · `diffBaselines`/`diffBaselineLabel` duplicate `DiffInspectorView.swift:37–39, 343–349` (move to shared, migrate desktop) · iOS SpawnSheet re-implements desktop trust/spawn logic verbatim (`refreshTrust`/`grantTrust`/`canSpawn`/seeding — hoist a shared spawn view-model into OrchestraUI; the trust flow is the one that must not drift) · `TmuxAttach` declared "single source of truth" while `AgentTerminalView.swift:159–168` and `SessionManager.viewSession` still carry byte-identical copies (the "Core not linked on iOS" excuse is wrong — Core→Kit is the declared direction; migrate both) · `TerminalKeyBytes` re-declares `KeyName`'s vocabulary + SwiftTerm's escape table (make bytes a projection on `KeyName`) | ~300 | Every pair is a drift bug waiting (the two `trimmed`s already disagree). |
| D10 | Script/plumbing | fold `t4-takeover-shot.sh` + `t4-phone-spawn-takeover-shot.sh` (~80% shared, signing flags already forked) into one `--spawn` flag script, extract the shared sim-harness block the 4 scripts copy · `CommandsTests.fullSet` duplicate command list · `SpawnTargets` `dirs ≡ repos.map(\.path)` + never-read `RepoCandidate.name` + twin `@Published` arrays → one `[String]` · SpawnSheet's second card-derived suggestion pipeline (keep only `knownDirs`; worktree repos/branches are already in the daemon answers) · `BoardModelTypes.swift` 6-line file | ~250 | Copy-rot: the harness scripts' signing flags have already diverged. |

**Keep (explicitly evaluated, earns its bytes):** `Exports.swift`'s one-line `@_exported import`
(boundary is enforced independently by the typecheck gates; spares ~100-file import churn) · the
three typecheck scripts · `DisabledPushSender` (honest no-op boundary) · `TrustLedger`/`TrustGrant`
(gates the agent, fail-safe default, agent-can't-self-grant) · UDS socket permissions · SSHMaster's
~104-char `sun_path` checks (has bitten this project) · the tailnet-shape guard (~100 lines, see
Lens 4) · `SpawnInput` wire tolerance.

## Lens 3 — Bugs

Grouped by blast radius; every item has a concrete failure scenario in the agents' traces; the ones
marked ✅ were independently confirmed by ≥2 reviewers or by direct code reads.

### Sync / connection (hits both apps today, hits the phone constantly post-P1)

- **CRITICAL ✅ · reconnect doesn't reconcile · `BoardModel.swift:348–376` + `ControlClient.swift:211–256`.**
  See exec #3. Fix: `refresh()` on the `.retrying→.live` edge (generalize as the one "re-assert on
  reconnect" hook alongside push re-register), publish offline after N retries / grace period,
  delete the false comments (`BoardModel.swift:357–360, 409, 427–430, 488–490`).
- **HIGH ✅ · activity feed duplicates on every re-subscribe · `ControlServer.swift:120–125` +
  `BoardModel.swift:484–486`.** Ring replays to *every* `subscribe`; client never dedups by id.
- **HIGH ✅ · `ControlClient.connect()` not idempotent · `ControlClient.swift:49–62`.** Second call
  leaks the live transport and spawns a second runLoop → double event delivery forever. 2-line guard.
- **MED ✅ · snapshot-then-subscribe gap · `BoardModel.swift:356–363`.** Events between the `list`
  response and the subscribe landing are lost (only `.activity` replays). Subscribe first (apply is
  idempotent), or add a seq/replay contract (also the right web-client shape).
- **MED · `activate()` stale-teardown race · `BoardModel.swift:248–289, 361–376`.** Old consumer's
  `handleStreamEnded` can clobber the new connection's state; generation-counter fix.
- **MED ✅ · N+1 serial reconcile · `BoardModel.swift:390–404, 431–441`.** One `sessions` + one
  `agentTerminalOwner` RPC per card, serially (each `sessions` shells out to tmux): 25 cards ≈ 50
  round trips gating live events on every (re)connect — seconds of stale UI on a phone. Bulk
  `boardSnapshot` RPC (also closes the M1 gap atomically).
- **MED · fd close-while-blocked-read · `ControlClient.swift:66–69`, `ControlServer.swift:301–307`,
  `UDSSocket.swift:47–52`.** `close(2)` doesn't unblock a blocked `read(2)` on Linux (this branch
  cross-compiles the daemon to Linux) → leaked thread per drop; on Darwin the onBroken write path
  can close an fd the reader still holds → recycled-fd cross-wiring (zombie reader eats a new
  client's bytes). `shutdown()` + reader-owns-close.
- **LOW · `onState` fires unordered Tasks per transition** (chip can stick on "retrying") ·
  `stop()` never closes accepted connections · per-connection request ordering is unguaranteed
  (latent until a pipelining client).

### Takeover / terminal (T3/T4)

- **HIGH ✅ · lease stolen on failed takeover · `OrchestraService.swift:636–649`.** CAS + detach +
  emit precede the throwing `agentTarget()`. Resolve the target first; commit last.
- **HIGH ✅ · dismissal-during-acquire orphans the lease · `TakeoverController.swift:42–63`.**
  `begin()` never re-checks `released`/cancellation after its await; `returnToDesktop()` at
  `.acquiring` releases nothing. Desktop stays on the placeholder until manual Force Retake (stale
  only changes copy, never remounts). Fix: after the await, if released → release at the returned
  epoch instead of entering `.holding`.
- **HIGH ✅ · heartbeat denial swallowed · `BoardModel.swift:854–864` + `TerminalOwnership.swift:75–88`.**
  Denial throws; `try?` maps to nil; mirror stays `.holding`. Daemon-side fix (denial returns the
  current snapshot — matching the comment's claimed behavior) is cleanest.
- **HIGH ✅ · desktop staleness is fiction · `DesktopTerminalPolicy.swift:47–53` +
  `OrchestraService.swift:662–669`.** Heartbeats deliberately don't emit ("staleness is derived from
  `updatedAt` by consumers") but nothing desktop-side ever refreshes `updatedAt` after takeover
  (verified exhaustively: owner events fire only on takeOver/release; `refreshAgentOwners`'s one
  caller is connect-time `refresh()`; no timer exists) → "The phone that took over is unreachable.
  You can force the terminal back." ~30s into *every* healthy takeover. Scope nuance: the
  mount-vs-placeholder decision ignores staleness, so this is the placeholder's copy + Force-Retake
  affordance lying, not a wrong mount. Fix: emit the owner state on heartbeat (one event/10s) and
  delete the client-side staleness derivation (whose `isStale` parameter the mount decision already
  ignores — see D8).
- **MED ✅ · SSH pipeline has no error handler · `SSHPTYChannel.swift:227–236, 259–277`.** Handshake
  failure (unauthorized key — the common first-run case; non-sshd endpoint) → `errorCaught` into the
  void → stuck `[connecting…]` forever, Retry/Detach dead, one leaked TCP connection per attempt;
  the child-failure branch also never closes an *established* parent. Add a tail error handler +
  close parent on child failure.
- **MED ✅ · double/perpetual reconnect · `IOSTerminalView.swift:124–160` + `SSHPTYChannel.swift:152–160`.**
  One error emits `.failed` then `.closed`, each scheduling a timer; a stray timer's `close()` on a
  by-then-healthy channel emits another non-intentional `.closed`; `.connected` resets the budget →
  a single blip can flap indefinitely (and in takeover mode each flap's `detach-client` kicks the
  other attach). Suppress `channelInactive` after `errorCaught` + a reconnect-pending flag +
  generation-stamp attempts.
- **MED · takeover reconnect is lease-blind · `IOSTerminalView.swift:142–160`.** Re-runs the
  exclusive recipe (incl. `detach-client`) without re-verifying the lease → phone can kick the
  desktop after a desktop retake whose event arrived late. `shouldReconnect: () -> Bool` wired to
  `isHolding`.
- **MED · acquire-on-select self-kick · `InspectorView.swift:382` + `SessionManager.swift:126–130`.**
  `detachAgentViewClients` (self-described belt-and-suspenders, and redundant — the phone recipe
  detaches for itself) can kick the desktop's *own* just-connected client on first select;
  `processTerminated` is a no-op → dead pane. Delete the detach call.
- **MED · `PubkeyAuthDelegate` re-offers the same key unboundedly · `SSHPTYChannel.swift:64`.**
  Track `hasOffered`, fail fast with a clear "key not accepted" error.
- **LOW** · "pull to retry" copy with no gesture (`IOSTerminalView.swift:145`; reset on
  `scenePhase == .active`) · `PhoneTakeoverPolicy.swift:36` `epoch >=` tolerates a self-retake the
  exact-match heartbeat CAS can't survive (latent) · phone's `LiveShellView` keeps a dead attach
  when the desktop closes its phone-owned window (`TerminalTab.swift:407` — reconcile `target`
  against the broadcast) · verify harnesses: `t1-live-attach.sh:117` *echoes* its idempotence
  expectation without asserting; both t4 shot scripts print owner state without checking
  `ownerKind == phone` — add assertions so they gate regressions.

### Shell sync

- **HIGH ✅ · duplicate-tab race · `BoardModel.swift:671–701`.** Optimistic append/remove vs
  broadcast (see exec #8). Broadcast becomes the single writer; also collapses the `shellOpen`
  derived-state triple (`BoardModel.swift:108`) that made four mutation sites possible.
- **MED · stale-write clobber · `BoardModel.swift:390`.** Serial `sessions()` snapshots overwrite
  fresher `shellsChanged` events mid-refresh.
- **LOW-MED · empty-set wipe · `OrchestraService.swift:560–568` + `SessionManager.swift:70–74, 148–151`.**
  `emitShells` broadcasts `(try? windows()) ?? []`, and `windows()` itself masks *any* tmux non-zero
  (including a hiccuping server, via `isAlive`) as `[]` — so a transient failure at open/close time
  broadcasts "no shells" and every client wholesale-wipes that card's tabs/selection/panel until the
  next reconnect. Nuance: the code *documents* this as intended ("empty set is the correct 'no
  shells' state") and the window is narrow — so this is a design decision to revisit (distinguish
  "session gone" from "listing failed"; don't emit on the latter), not an unnoticed bug.

### Push / notifications

- **HIGH ✅ · pref changes never re-register · `SettingsNotifications.swift:86–93`.** Daemon keeps a
  stale scope snapshot; backgrounded delivery ignores "Off" (the foreground gate can't save you —
  `willPresent` doesn't run in background). One-liner: re-register on pref write.
- **MED · sound names are macOS files · `OrchestraKit/Push.swift:152–154`.** `Hero.aiff` etc. don't
  exist in the iOS bundle; APNs falls back to the default sound — sound prefs silently have no
  effect. Map to `default`/bundled sounds.
- **MED · 410-eviction can delete a fresh registration · `PushNotifier.swift:78–84`.** Unregisters
  by clientId only; an in-flight old-token failure evicts the new token. Token-match it — or, per
  the trust model, reduce eviction to log-only (re-register on reconnect self-heals).
- **LOW** · locally-detected `badToken` treated as transient (retry+log forever) — moot if the store
  pins `count == 64` · JWT not invalidated on 403 `ExpiredProviderToken` (note-only) · deep-link to a
  vanished card opens an empty detail (`NeedsYouTab.swift:90–94`) · `notifier` became a lazy var
  first touched in `bootstrap()` — the `UNUserNotificationCenter` delegate installs after first
  frame, so a banner-click during launch can be dropped (eager-install in init, as main did).

### Spawn / Needs-You / views

- **MED (PLAUSIBLE) · rollout tail can clobber C1's permission state · `OrchestraService+Report.swift:~70–80` +
  `CodexAdapter.swift:68–128`.** The `PermissionRequest` hook report applies with `seq == 0`
  ("always apply"), but rollout lines Codex wrote just *before* blocking (the tool-call line →
  `.running`, seq = timestamp-µs) are delivered later by the polling tailer and pass the
  `seq > lastSeq` gate — the gate orders tail lines against each other but cannot order hook-push
  against tail for the same status. If the timing holds, `.waiting/.permission` flips back to
  `.running` ~a poll-tick after the hook fires: no Needs-You row, no push, card silently blocked.
  Needs a runtime trace to confirm; if real, stamp hook reports with a synthetic max-seq or gate
  status transitions separately.
- **MED ✅ · approve/deny without a state guard + wrong-layer chords · `NeedsYouQueue.swift:93–118`.**
  `approvePermission` sends Enter without checking the card is still `.waiting/.permission` — a
  just-answered prompt means Enter lands in the live REPL and submits whatever's in the composer.
  Guard on `waitReason`, move chords to `AgentCapabilities`.
- **MED ✅ · `sendChord` ignores tmux failure · `SessionManager.swift:189–200`.** `_ = try tmux(...)`
  discards `r.ok` — Approve can return success while the agent stays blocked. Check and throw.
- **MED ✅ · worktree-mode switch never loads branches · `SpawnSheet.swift:193, 386`.**
  `loadBranches()` bails in freeform mode and `.onChange(of: mode)` only refreshes trust — enter via
  the Freeform page, flip to Worktree, and `branchOptions` stays empty forever.
- **MED · trust-grant race · `SpawnSheet.swift:394–417`.** A slow pre-grant `trustState` reply can
  overwrite a successful grant (guards only on `path == cwd`). Generation counter, or re-run
  `refreshTrust()` after grant.
- **MED · bare repo names rejected · `SpawnSheet.swift:247, 509–515` vs `OrchestraService` `resolveRepo`.**
  The placeholder invites "repo name"; the daemon canonicalizes relative to its cwd and throws
  `pathNotAllowed`. Resolve bare names against `Config.reposRoot` daemon-side.
- **MED · auto-own-on-spawn UX/transport coupling · commit `b3ae948`.** Every phone spawn now
  force-fullscreens into a takeover that rides the SSH transport spawn doesn't need — an unset
  target = a cover that can't attach, with no failure-dismiss. Better altitude: an `own: true` spawn
  param assigning the lease atomically daemon-side (the daemon already has the clientId and creates
  the window synchronously), plus an attach-failure fallback.
- **MED ✅ · CLI `send-keys` reorders the chord · `CLIRunner.swift:135–142`.** `--text` is appended
  before positional keys regardless of position: `send-keys <ref> Enter --text 'y'` types `y` then
  Enter... inverted from what was written. Preserve argv order.
- **LOW / polish** · snooze expiry never wakes the UI (+ "Until tomorrow" is literally 8h,
  `NeedsYouSnooze.swift:16`) · `StatusDot` pulse misses live transitions (`BoardCardCell.swift:155`)
  · `DiffTab` re-parses rows per body eval in a non-lazy VStack (`DiffTab.swift:97–103`; parse in
  `load()` like `MarkdownView` already does) · MarkdownRender: paragraph lines joined with `\n` +
  `.inlineOnlyPreservingWhitespace` → the repo's ~100-col hard-wrapped notes render as ragged
  fragments and list continuations fall out of lists (`MarkdownRender.swift:34–96`; join with
  spaces) — this is the Notes page's actual corpus · ActivityFeed tap-to-card promised but never
  wired (`ActivityFeedView.swift:7,30`) · unreadable dir shows "Empty folder" (`try?` swallow) ·
  untrimmed repo/branch/cwd from the phone keyboard · setup banner does a synchronous Keychain IPC
  per render (`IOSTerminalHost.swift:42`; cache) · heartbeat mirrors unchanged owner state every 10s
  → whole-hierarchy re-render (`BoardModel.swift:862`; skip if identical) · capture-poll issues in
  exec #7 · `Launcher.swift:125` caps notes by `utf8.count` but truncates by `Character` (up to ~4×
  overshoot) · `NoopWindowConfig.enterTerminalFocus()` returns true where `IOSWindowConfig` returns
  false — tests/previews validate the opposite focus behavior from the device · dev env hooks
  inconsistently `#if DEBUG`-gated (`ORCH_DEV_OPEN_CARD` & co. compile into Release — harmless,
  make uniform) · `iso-stack.sh` records PIDs into `$STATE` only as its last step, but can fail-exit
  after the daemon/app are already spawned — orphans survive `down`, and the next `up`'s
  `rm -rf "$ROOT"` deletes the live daemon's HOME out from under it (record PIDs immediately after
  each spawn).

## Lens 4 — Security/exploit over-engineering (keep/delete verdicts)

Applying the stated trust model — the only client is the owner, on the owner's tailnet, who already
has root on the target Mac. The test: does this code prevent the owner *accidentally* hurting their
own data (keep), or defend against an adversary who doesn't exist (delete)?

| Mechanism | Verdict | Reasoning |
|---|---|---|
| TOFU host-key pinning (`SSHHostKeyPinStore` + delegate + Settings + tests, ~420 lines) | **DELETE** (exec #5a) | Tailscale's WireGuard layer already authenticates the peer; the branch's *own comments* document accept-any as the design decision. The pin's one real-world firing is a false "possible MITM" after the owner re-keys their own Mac. It also required a DEBUG env hook whose sole job is defeating it. 3 of 4 agents concur. |
| Tailnet-shape guard (`SSHEndpoint.isTailnetHost` & co., ~100 lines) | **KEEP** (barely) | Cheap, stateless accident-prevention with good error copy for the one real misconfig (LAN/public target while accepting any host key). Its loopback escape is load-bearing for all four verify harnesses. Fix the stale comment block; hoist enforcement to session establishment when P1 lands (as the spec already plans). If further simplification is wanted later, demote to settings-time validation (no connect-time refusal → the escape hatch deletes too). |
| `listDir` confinement (`assertAllowed`, bounded parent, root collapse) | **DELETE** (exec #5b) | The same socket exposes `exec` (arbitrary shell as the daemon user) — confining *enumeration* is theater. It actively blocks real owner use (dot-dirs like `~/.claude`, paths freeform spawn accepts). Keep `browseRoots` as UX starting points and dotfile hiding as declutter, not defense. |
| Freeform trust ledger / cwd-trust prompts (`TrustLedger`, `TrustGrant`, grant flow) | **KEEP** | Not client-defense: `trustCwd` gates whether the *agent* runs sandboxed in a borrowed dir, and "the agent can't self-grant" is genuine accident prevention. Fail-safe default (untrusted → sandboxed spawn still succeeds) matches the owner's stated preference. |
| Ownership lease (epoch/CAS/heartbeat) | **KEEP** | Not security at all — multi-device coordination against a physical constraint (one tmux window, one size). The best-engineered code on the branch. |
| `isValidShellWindowName` | **KEEP** | tmux `:`-target injection *and* accidental-collision protection — correctness, not paranoia. |
| DeviceTokenStore 0600 chmod dance (`DeviceTokenStore.swift:84–93`) | **DELETE** | A device token is not a credential (useless without the owner's own APNs key); `TaskStore`, the cited idiom, does no chmod. |
| Store-side token format window 32–200 (`DeviceTokenStore.swift:58–67`) | **DELETE / pin to `count == 64`** | The only registrant is the owner's phone sending 64 hex chars; the real fix (the URL-construction guard in `APNsSender.swift:100–103`, which prevents a daemon trap) stays. |
| Sixel run-length clamp | **KEEP** (if decoder survives D2) | Main-thread-hang fix, not security. |
| UDS socket perms, SSHMaster `sun_path` checks, `ClientIdentity` read-only-FS fallback | **KEEP** | Cheap local hygiene / real constraint that has bitten before. |
| Sandbox clamps on read-only cards | **KEEP** | Pre-existing agent-facing mechanism; untouched by this branch. |
| `send-keys` + `capture` as registry commands (MCP-exposed to agents) | **ADD GATING** (the inverse finding) | ✅ Verified: `orchestra-mcp` builds its tool list from `CommandCatalog.all`, so every agent can inject keystrokes into any card's agent pane — including Enter on a `waitReason == .permission` card, i.e. programmatic approval of the human-only gate. The agent-vs-owner boundary is the one this project's trust design *does* defend. Make both app-only (like `listDir`/takeover), or add a catalog `exposure` flag. Related: `sendChord`/`capture` interpolate the raw `window` param into the tmux `-t` target without `isValidShellWindowName` — `window="agent.1"` retargets a pane; validate like `ensureShellWindow` does. |

Net deletable under this lens: **~600 lines of code + ~15 tests + one Settings section + two DEBUG
env hooks**, with `SettingsSecurity.swift` shrinking to just the (P2-doomed) SSH-target section.

## Lens 5 — Deployability: the true path to "install it on my iPhone and use it"

**Ground truth (all verified in code):** the Simulator runs the full product over a filesystem cheat
(`ORCH_DEV_SOCKET`); a physical device has **no board transport** (`Config.socketPath` resolves
inside the app sandbox → silent permanent Disconnected — there isn't even an error state), **no
build lane** (Simulator-only, signing disabled), and push is triple-blocked (no paid team → no APNs
key & `aps-environment` breaks free signing; LaunchAgent can't carry `ORCH_APNS_*`; registration
rides the control channel that doesn't exist on device). Terminals/takeover *would* work over the
tailnet (their SSH transport exists) but are unreachable because every surface is entered through
the board. The iOS Settings "Add remote…" editor is a guaranteed-failure surface on the phone
(opens a Mac-side path as a local socket) — hide it or repurpose it as the Mac-connection editor.

**The ordered path (minimum viable phone = steps 1–3):**

1. **Device signing lane** *(S — hours)*. `project.yml`: `DEVELOPMENT_TEAM` + automatic signing;
   `build-ios-app.sh --device` (`-destination generic/platform=iOS`, `devicectl` install). **Free
   personal team**: strip `aps-environment` in a no-push entitlements variant (signing fails
   otherwise), accept 7-day resign cadence. Do this first so every later step can be tested on
   metal.
2. **P1 — board over SSH** *(L — the one big chunk; everything lights up behind it)*. Exactly per
   the spec: `IOSSSHSession` (one shared authenticated swift-nio-ssh connection) + `SSHControlTransport`
   exec-bridging `nc -U <daemon sock>`, wired into `ControlClient`'s existing factory. **Plus the two
   corrections this review adds**: make `ControlClient.connect()` async first (today's synchronous
   first `open()` would block the main thread for seconds per attempt on a cell network), and
   replace `ConnectionSocketResolver` with a `Connection → Transport` factory. **And land the
   reconnect-reconcile fix (exec #3) in the same phase** — on a phone the link drops on every
   backgrounding, so without it the board is stale after every unlock. Verify with the spec's
   loopback e2e (extend `t4-takeover-verify.sh`'s throwaway sshd to serve the control bridge; give
   the harness real assertions while there).
3. **One-time Mac setup + key surfacing** *(S)*. Enable Remote Login; add a Settings row that shows
   and copies `SSHKeyStore.authorizedKeyLine()` (today the pubkey only appears in a failure banner
   that is itself unreachable pre-P1) with the `echo '<key>' >> ~/.ssh/authorized_keys` one-liner.
4. **P2 — one config to rule them all** *(M)*. Terminals/takeover take child channels from the
   shared session; `SSHEndpoint.resolve()` derives from the active Connection; **delete
   `orch_ssh_target` + `TerminalTargetSettingsSection`** (the branch's own spec orders it — the
   shipped standalone key is a self-acknowledged bandaid that lets board and terminals point at
   different Macs); repurpose/retire the "Add remote…" trap.
5. **P3 — onboarding flow** *(M, optional)*. For a single owner, steps 1–3 + one typed target is
   acceptable; build the guided checklist last or never.
6. **P4 — real push: explicitly deferred (paid-tier)**. Out of scope on a free account. When/if a
   paid membership happens: mint the `.p8`, inject `ORCH_APNS_*` via the LaunchAgent plist's
   `EnvironmentVariables` (must be added — shell env doesn't reach launchd), restore
   `aps-environment`, fix the iOS sound names. Until then needs-you alerts ride the Claude/Codex
   mobile apps' own notifications, and the push stack stays as the tested, disabled seam it already
   honestly is.

**Freeze rule while P1 is built:** don't invest further in the per-terminal dialing path
(`SSHPTYChannel.start`'s bootstrap half, per-view `SSHEndpoint.resolve()`, `TerminalRuntime`,
`orch_ssh_target`) — ~120 lines of it are scheduled demolition under the spec, and the SSH-stack
bug fixes above (error handler, reconnect dedup, auth fail-fast) should be written against the
shared-session design where possible.

## Suggested card cuts (in order)

1. **Merge-main re-baseline + hand-port the three orphaned fixes** (exec #1) — do first, everything
   else rebases onto it.
2. **Reconnect-reconcile + connection-state truth** (exec #3 family: refresh-on-live, activity
   dedup, idempotent connect, offline-after-N, subscribe-then-refresh).
3. **Takeover feedback loops** (exec #4: commit-order, released re-check, denial→snapshot,
   emit-on-heartbeat, lease-aware reconnect, delete `detachAgentViewClients`) + SSH stack trio
   (error handler, reconnect dedup, auth fail-fast).
4. **The big delete** (Lens 2 D1–D8 + Lens 4 deletions; ~1,300 lines with tests). Cheap, high-clarity.
5. **Device lane + P1 transport + key surfacing** (Lens 5 steps 1–3; the corrections in step 2).
6. **Shell-sync single-writer + spawn-form fixes + Needs-You guard/chords + push re-register.**
7. **Consolidation pass** (D9/D10) and the **BoardStore/BoardUX split + AgentNotifier rewire**
   (Lens 1) — best scheduled with or right after P1, which touches the same files.

---

## Addendum (2026-07-06, post-review) — `feat/ios-real-device-transport` landed; delta assessed

Card a52b9e finished implementation (9 commits, ~2,565 insertions on top of this branch). Every claim
below is verified against `git diff HEAD...feat/ios-real-device-transport`. Verdict: **architecturally
the right build — the transport seam, config unification, and onboarding land as specified — but
"install and just use it" is not yet credible**: three of this report's warnings ship unfixed (one
made materially worse), and the delta adds two MEDIUM bugs plus a likely-broken device-build path.

### What the delta resolves from this report

- **Transport factory seam — DONE, clean.** `RemoteControlTransportProvider`
  (`OrchestraKit/Control/RemoteControlTransportProvider.swift`, a `@MainActor`
  `Connection → (@Sendable () -> Transport)?` protocol) is exactly the shape Lens-3 asked for;
  `BoardModel.activate` builds `ControlClient(transport: factory)` from it and nil-falls-back to the
  old path resolver for Simulator/dev/macOS. `ControlClient`'s per-reconnect factory is reused
  unchanged.
- **P2 config unification — DONE, real.** `orch_ssh_target` + `TerminalTargetSettingsSection`
  **deleted** (closes F5 / the orch_ssh_target-bandaid finding); `SSHEndpoint.resolve` derives from
  the active `Connection`; terminals + takeover ride the **shared** `IOSSSHSession`
  (`SSHPTYChannel` lost its own bootstrap → `sharedSessionIfMatching`); the iOS "Add remote…" trap
  (F3) is repurposed into a prefilled "Set up your Mac" entry.
- **Onboarding + key surfacing (Lens-5 step 3) — DONE.** `MacSetupView` shows/copies
  `SSHKeyStore.authorizedKeyLine()`, one field, gated on genuine first launch, re-enterable from
  Settings; "Test" requires an observed `.live` (no fabricated success).
- **Free-team device lane exists** (`build-ios-device.sh` + `OrchestraiOS-nopush.entitlements` that
  correctly drops `aps-environment`) — the right shape for the no-paid-membership constraint.
- **Trust moved to session establishment** (tailnet guard + pin enforced once per shared session) —
  architecturally the right spot.
- **Honest tests**: `BoardOverSSHE2ETests` genuinely asserts `.live`, version match, drop→reconnect,
  and two-channel multiplexing; the verify script gates on real xcodebuild success.

### This report's warnings that still ship unaddressed

- **HIGH — the main-thread SSH-dial warning was right and is now worse.** `ControlClient.connect()`
  is still synchronous, and `SSHControlTransport.open()` does **two NIO `.wait()`s** (TCP+SSH
  handshake, then channel open) on `BoardModel.start()`'s `@MainActor` 25×200ms loop. An unreachable
  Mac freezes the UI up to ~10s/attempt; onboarding "Test" polls `connectionState` on the *same*
  blocked thread, so its ProgressView freezes and the 12s timeout can fire a false failure. Make the
  first `open()` async before this is shippable.
- **HIGH/known — reconnect-reconcile gap ships (exec-summary #3).** The delta adds session
  re-establish on foreground but still never re-runs `refresh()` on a transport reconnect, and
  `connected` stays `true` through `.retrying` — so after every backgrounding the phone shows stale
  tasks *as live*. On a cell link this is the daily bug; land `refresh()`-on-`.live` in the P1 phase.
- **MED — pin store was ENTRENCHED, not deleted** (against Lens-4 D1): now threaded through
  `SSHClientPrimitives`, two harness scripts, e2e resets, and the Settings UI, while
  `SSHEndpoint.swift`'s comment still claims accept-any/"intentionally NOT pinning." Delete
  recommendation stands; at minimum fix the false comment.

### New bugs the delta introduced (verified)

- **MED — `IOSSSHSession.connect()` in-flight race → permanent livelock.** `inFlight = f` is assigned
  *after* the future chain is built (`IOSSSHSession.swift:124`), but the callbacks that clear
  `inFlight` can run on the event loop *before* that line (sub-ms "connection refused" makes it
  realistic) → a stale failed future sits cached in `inFlight`; every later `connect()` returns it
  without re-dialing, so ControlClient retries forever against a cached failure until app restart.
  Assign `inFlight` before wiring callbacks (or guard by generation).
- **MED — exec-bridge failure is invisible at open.** `ExecRequest` uses `wantReply: false`
  (`SSHControlTransport.swift:86`) and ignores exit status/stderr, so "SSH up, daemon down" (or `nc`
  *and* `socat` missing) opens successfully → `.live` → bridge EOFs → `.retrying`, flapping forever
  with no diagnosable reason (`nc` stderr is `2>/dev/null`'d), and "Test" can transiently see `.live`
  against a dead daemon. Gate `.live` on a `version` RPC round-trip (the spec's own step-4 intent).
- **MED — device-build entitlements path likely broken.** `build-ios-device.sh:65` sets
  `CODE_SIGN_ENTITLEMENTS=App-iOS/OrchestraiOS-nopush.entitlements`, but that resolves against
  `$(SRCROOT)` = `App-iOS/` → likely `App-iOS/App-iOS/…`, failing signing (consistent with no
  evidence the lane was ever run). The `--install` device-id `awk '{print $(NF-1)}'` is also fragile
  vs multi-word devicectl columns. Fix + actually execute on a real device before calling it done.
- **LOW** — `ControlLineBuffer` is correct/well-tested but unbounded (no max-line cap/backpressure) ·
  writes are fire-and-forget over SSH (an RPC into a dying channel hangs until `failPending`).

### Re-scored Lens-5 path to a working phone install

| Step | Status after a52b9e |
|---|---|
| 1. Device signing lane (strip `aps-environment`) | **Shipped but likely broken + unexecuted** — fix the entitlements path, run on-device. |
| 2. P1 board over SSH | **Shipped, correct seam** — but apply async first-connect (now HIGH: freezes launch + Test) and gate `.live` on daemon liveness. |
| 2b. Reconnect-reconcile (fold into P1) | **Not done** — stale-board-shown-as-live still ships. |
| 3. Mac setup + copy-my-pubkey | **Shipped** (`MacSetupView`). |
| 4. P2 unify config (delete `orch_ssh_target`) | **Shipped.** |
| 5. P3 onboarding | **Core shipped.** |
| 6. P4 real push | **Correctly deferred** (paid-tier, out of scope). |

**Bottom line:** the hard architectural work is done and done well; before "install and just use it"
is credible, fix the async first-connect (HIGH), the two new MEDIUM bugs (session-connect livelock +
undiagnosable daemon-down flap), and the device-build entitlements path — then land the
reconnect-reconcile fix so the board isn't stale after every backgrounding. Nothing was regressed.

— end of report —
