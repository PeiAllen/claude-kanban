# 8. Building & operations

This chapter covers building and testing the package, building the macOS app bundle, the development
scripts, runtime configuration, the macOS permissions agents need, and troubleshooting the
known operational gotchas.

## Building the package

The package (`Package.swift`, swift-tools 6.0, macOS 14+) defines four products:

- `OrchestraCore` (library), `orchestrad`, `orchestra`, `orchestra-mcp`.

The core, daemon, and CLI are **dependency-free**. Only `orchestra-mcp` depends on the official MCP
`swift-sdk`, scoped to that target — so the **first** `swift build` needs network to resolve
`Package.resolved`; after that, builds are offline.

`OrchestraCore`, `orchestrad`, `orchestra`, and `orchestra-mcp` also compile and run on **Linux** (the
`.macOS(.v14)` platform floor gates only the macOS deployment target, not the Linux build). Darwin-only
symbols sit behind `#if canImport(Darwin)` with a Glibc/Musl path — see `Platform.swift`'s file-scope
POSIX shims — so a musl static cross-build works from the Mac (see [Deploying `orchestrad` to a remote
Linux box](#deploying-orchestrad-to-a-remote-linux-box)). Only the `App/` bundle stays macOS-only.

```sh
scripts/build.sh        # swift build, under the build mutex
scripts/test.sh         # UNIT tier (default, seconds) — the per-task loop
scripts/test.sh --contract   # + real git/tmux/fd contract tests
scripts/test.sh --e2e        # + built-binary / slow-repo e2e
scripts/test.sh --all        # everything + scripts/lint-tests.sh — run ONCE at the merge gate
```

> **The suite is tiered** (`Tests/UnitTests` mirrors `Sources/`; `Tests/ContractTests` pins the
> fakes' fidelity against real git/tmux; `Tests/E2ETests` runs the binaries). Run the unit tier
> per task and `--all` once per PR — never mandate full-suite runs per task in plans. Selection
> is additive: scoped runs add slow tiers on top of the unit floor, never skip below it.
> Guards against re-clumping (no sleeps / ambient paths / real forks in the unit tier) are
> enforced by `scripts/lint-tests.sh`. Design: `notes/designs/2026-07-13-test-suite-redesign.md`.

> **Always build through `scripts/` — never a bare `swift build`.** Builds here are
> **contention-bound, not CPU-bound**. Measured: one cold `swift build --build-tests` takes
> **165s**, but **three concurrent ones take 520s *each*** — degradation is super-linear, so
> concurrent building is pure loss (three serialized finish sooner than three in parallel) and it
> drags the app and daemon down with it (daemon RPC p95: 6.5ms → 22ms). The reported "8m36s cold
> build" *was* three cards building at once.
>
> So every heavy build takes a **machine-wide mutex** (`scripts/lib/with-lock.sh`). A bare
> `swift build` bypasses it and re-creates the problem for every other card; to wrap a raw
> invocation use `scripts/lib/with-lock.sh build -- swift build …`. When another card holds the
> lock you'll see `[build-lock] waiting for slot…` on stderr — the wait is bounded
> (`ORCH_BUILD_LOCK_TIMEOUT`, default 1200s) and **fails open**, so it can never fail your build.
> (The bound must exceed the queue it absorbs: at 300s, three contending cards each timed out, ran
> unlocked, and re-created the very concurrency the mutex prevents.)
> `scripts/test.sh` holds the lock for the **compile only** and runs the suite unlocked.
> `scripts/build-app.sh` additionally takes a **`--strict` ship mutex** (it rewrites the shared
> `App/Orchestra.xcodeproj` and replaces `/Applications/Orchestra.app`); that one never fails open —
> it fails closed rather than risk a half-written bundle. Rationale and numbers:
> `notes/designs/build-contention.md`.

This repo builds the package against the **Command Line Tools** (CLT) SDK — no full Xcode required. CLT
ships `swift-testing` as a framework but not on the default search path, so `scripts/test.sh` adds the
needed `-F`/`-rpath` flags for `Testing.framework` + `lib_TestingInterop.dylib`. The test
suite is substantial — `OrchestraCoreTests` (service, task store/migration, adapters, read-only launch,
recovery, report, scratch, control round-trip, UDS SIGPIPE regression, the `Transport` reconnect/backoff +
re-subscribe, the `Connection`/`ConnectionStore` round-trip, the pure SSH command builders, and the XDG
data-dir resolver) and `IntegrationTests` (E2E
binary, launcher diff, worktree/session managers against real git/tmux, `_report` broken-pipe/self-close
regression).

**Two toolchains, kept SDK-consistent.** The machine's *ambient* toolchain is typically Xcode
(`xcode-select -p` → `Xcode.app`), and the CLT and Xcode SDKs produce incompatible `OrchestraCore`
modules in `.build`. The scripts keep each self-consistent rather than sharing one module:

- `scripts/test.sh` runs `swift test` under the **ambient (Xcode)** toolchain — some suites `import
  XCTest`, which CLT does not expose on its search path (it still adds the CLT swift-testing flags for
  `Testing.framework`).
- `scripts/typecheck-app.sh` sources `scripts/toolchain.sh` to pin `DEVELOPER_DIR` to **CLT**, then
  rebuilds the module with `swift build --target OrchestraCore` so it matches the CLT SDK its `swiftc
  -sdk .../CommandLineTools/...` typecheck targets.

Without the CLT pin the two disagree and the app typecheck fails to import the module ("module compiled
with a different SDK") — see [Troubleshooting](#troubleshooting).

> **Sandbox note (for Claude Code / sandboxed shells).** `swift build`/`swift test` run their own
> nested `sandbox-exec`, which can't nest inside another sandbox and whose `~/Library` caches aren't
> writable there — run those commands unsandboxed.

## Building the app bundle

The SwiftUI app is intentionally **not** a SwiftPM target (so the package stays light and
offline-green). It needs full Xcode + SwiftTerm and is built from a generated xcodeproj:

```sh
scripts/build-app.sh            # regenerate xcodeproj (xcodegen), build Release, install to /Applications/Orchestra.app
scripts/build-app.sh --run      # …and launch it
scripts/build-app.sh --debug    # Debug config
scripts/typecheck-app.sh        # type-check App/*.swift against the CLT SDK without Xcode
```

`App/project.yml` drives `xcodegen`; the app uses Hardened Runtime, automatic signing, and a
single-binary debug build (so ad-hoc signing works in the script). SwiftTerm pulls a Metal toolchain
(its shader needs it) — the first app build fails without it; install with
`xcodebuild -downloadComponent MetalToolchain`. See `App/README.md` for details.

## Development scripts

| Script | Purpose |
|--------|---------|
| `scripts/build.sh` | `swift build` the package. |
| `scripts/test.sh` | Tiered `swift test` (unit by default; `--contract` / `--e2e` / `--all`) with the CLT swift-testing flags. |
| `scripts/lint-tests.sh` | Re-clumping guards: no sleeps / ambient paths / real forks / `makeReal` in the unit tier. Runs on `--all`. |
| `scripts/build-app.sh` | Build & install `Orchestra.app` (`--run`, `--debug`). |
| `scripts/build-and-launch-app.sh` | Build & install the bundle, then **refresh the live instance**: quit + relaunch the app and restart the daemon on the new binary. Needed because `build-app.sh` only replaces the bundle on disk — the running app and the KeepAlive daemon keep executing the old code until they restart. Agent tmux sessions are left running (a code refresh, not a state reset — use `reset-state.sh` for a full teardown). `--debug` passes through; `--run` is dropped (it manages the relaunch itself). |
| `scripts/typecheck-app.sh` | Type-check the app sources without Xcode (pins the CLT toolchain via `toolchain.sh`). |
| `scripts/reset-state.sh` | Boot out the daemon, kill the tmux server, delete the data dir + app prefs. `--worktrees` also wipes `~/.orchestra` (opt-in — worktrees may hold uncommitted work). |
| `scripts/make-dev-cert.sh` | Create the "Orchestra Dev" self-signed signing cert. |
| `scripts/orch-test.sh` | Run a disposable **isolated** daemon (own `HOME` + tmux socket) to verify daemon/command changes without touching the live app. |
| `scripts/orch-ui-shot.sh` | Build the app isolated and screenshot it by window id (for UI work). |
| `scripts/orch-key-demo.sh` | Background **keyboard-navigation** harness: launch an isolated instance seeded with a mock multi-card board (`ORCH_SHOW=demo`, no daemon), then **drive it with synthetic key events posted straight to its PID** (`CGEvent.postToPid` — never foregrounds it, so the live app is untouched) and screenshot the window after each step (`hjkl` select, `g`-go-to, `f` hints, `:` palette, `/` search, `?` help). Proves the [keyboard scheme](07-app-ui.md#keyboard-navigation) fires from real keystrokes. |
| `scripts/keydrive.swift` | Helper for the above — `windowid <pid>` prints a pid's CoreGraphics window id (to `screencapture -l`); `keys <pid> …` posts a sequence of chords (`j`, `S-l`, `g r`, `S-';'`, `esc`, …) to that pid without activating it. |
| `scripts/orch-ux-e2e.sh` | Full **app + daemon** UX e2e on a disposable, isolated instance — combines the two half-harnesses above (the demo app is launched against a *real* isolated daemon, so board actions and workflows drive through the actual UI). Isolates via `$HOME` alone; spawns `orchestrad` directly (never `launchctl` — the fixed `com.orchestra.daemon` label would collide with live) + an isolated `ORCHESTRA_TMUX_SOCKET`. **Concurrency-safe** so many PR cards can run it at once overnight (see below): flags `--run-id ID` (namespace all per-run state; also `RUN_ID` env, default this PID), `--build-only` (prebuild the shared bundle then exit), `--rebuild` (force), `--no-build` (reuse). |
| `scripts/orch-ux-e2e-concurrency-test.sh` | Proof harness: launches N (default 3) `orch-ux-e2e.sh` runs concurrently and asserts they stay isolated (distinct `$HOME`/socket/tmux/screenshot), all complete (none reaped by a sibling's teardown), and the live daemon is untouched. |
| `scripts/docs-shots.sh` | Regenerate **every image in `docs/images/`** — the README hero GIF (an orchestrator agent fanning work out over MCP), the keyboard-nav GIF, the board/inspector/diff/spawn stills, and the iPhone shot — from a real isolated stack running **real agents** on throwaway repos (`scripts/fixtures/demo-board.json`). Isolated by the same `$HOME`-is-the-lever contract as `iso-stack.sh`, with the demo orchestrator's `orchestra` MCP server pinned by `ORCHESTRA_SOCK` to the *isolated* daemon, so its `spawn` calls physically cannot reach your live board. Captures by window id; never foregrounds your screen. **These agents run for real and they bill.** Run it after a UI change: `scripts/docs-shots.sh` (add `--keep` to leave the stack up, then `scripts/docs-shots.sh down`). |
| `scripts/gifify.swift` | Assemble PNG frames into an animated GIF with macOS **ImageIO** (`CGImageDestination`) — so the doc images need no `ffmpeg`/ImageMagick/`gifski`. Used by `docs-shots.sh`. |
| `scripts/agent-auth.sh` | `status` — can an agent in an **isolated `$HOME`** actually authenticate? Every isolated harness overrides `$HOME`, which on macOS hides the login **Keychain** where Claude Code keeps its credentials (see [Real agents in isolated harnesses](#real-agents-in-isolated-harnesses)). `scripts/lib/agent-auth.sh` fixes that for all of them; this verifies it. |
| `scripts/orch-rpc.py` | Speak raw JSON-RPC to a socket (debugging the control plane). |
| `scripts/swift-testing-flags.sh` | The shared `-F`/`-rpath` flags used by `test.sh`. |
| `scripts/toolchain.sh` | Sourced by `typecheck-app.sh` to pin `DEVELOPER_DIR` to CLT (when present) so the rebuilt `OrchestraCore` module matches the CLT SDK the typecheck targets. Not sourced by `test.sh` — tests need XCTest, which only the Xcode toolchain provides. |

### Concurrency-safe UX e2e (overnight PR fan-out)

`orch-ux-e2e.sh` is designed so a whole board of PR cards can each screenshot the built UI at once,
unattended, without stepping on each other or on the live app:

- **Per-run namespacing.** Every mutable resource is keyed off `RUN_ID` (default the PID; a card passes
  its shortId via `--run-id`): the isolated `$HOME`/socket root (`/tmp/orch-ux-e2e-<RUN_ID>`), the tmux
  server, and the screenshot dir. Two runs with different `RUN_ID`s share nothing mutable.
- **PID-scoped teardown.** Cleanup kills only the `APP_PID`/`DAEMON_PID` *this* run spawned and removes
  only its own tmux socket + root. There is no global `pkill`/`kill-server` — so a run can never reap a
  sibling's daemon (the earlier cross-run-kill regression).
- **Build once, share read-only.** The app binary is immutable at launch, so N runs reuse one prebuilt
  bundle in a shared DerivedData dir, guarded by an `mkdir`-based build mutex (`flock` is absent on
  macOS). `--build-only` warms it up first; runs then pass `--no-build`.
- **GUI concurrency cap.** An `mkdir`-based counting semaphore (`UX_E2E_GUI_SLOTS`, default 2) bounds how
  many app windows fight the single macOS window server at once, reclaiming a slot whose holder PID has
  died. `scripts/orch-ux-e2e-concurrency-test.sh` verifies all of the above.
- **Floats the demo window under a tiling WM.** If AeroSpace (or another tiling WM with a CLI) is running,
  the harness matches the demo window by its app-pid and marks it floating, so it isn't folded into the
  user's live tiling layout — which would squish both the live app and the capture into a narrow
  1/2- or 1/3-width slice. A no-op when aerospace isn't installed or its server is down.

This makes the harness a building block for the overnight staged-PR fan-out pattern, where each PR runs
as its own Orchestra agent card.

## Deploying `orchestrad` to a remote Linux box

Two committed scripts set up the daemon on a remote Linux machine, so the Mac can run only the board UI
while `orchestrad` — and therefore every agent, tmux session, git worktree, and repo — runs on the work
box, reached over SSH. This is the **Mac app ↔ remote Linux daemon** topology of the
[remote-daemon connections design](superpowers/specs/2026-07-02-remote-daemon-connections-design.md) (a
generalization of the [phone-client axis](10-roadmap.md#the-nine-axes) onto one shared connection spine):
the wire protocol is **unchanged** (UDS + newline-delimited JSON-RPC), reachability is pure SSH
forwarding, and the daemon grows **no** network listener.

- **`scripts/build-linux-daemon.sh [--arch x86_64|aarch64] [--out DIR]`** — cross-compiles
  `orchestrad`/`orchestra`/`orchestra-mcp` as **zero-dependency static musl** binaries *from the Mac*
  (via the Swift Static Linux SDK, so the box needs no Swift toolchain), alongside the
  `Orchestra_OrchestraCore` resource bundle the daemon loads at runtime beside the binary. Output lands
  in `dist/linux-<arch>/`. Requires the musl static SDK installed once (`swift sdk install …`); the
  script checks for it and links the matching download if it's absent.
- **`scripts/deploy-linux-daemon.sh <user@host> [--remote-dir ~/orchestra] [--arch x86_64]`** — rsyncs
  the build to the box, installs a **systemd user unit** (`Restart=always`), enables **linger** (so the
  daemon survives logout on a headless work box), starts the service, and prints the daemon's XDG socket
  path (`~/.local/share/orchestra/orchestrad.sock`) to paste into the app's Connections settings. SSH
  key auth (a Tailscale hostname works) plus `git`, `tmux`, and the agent CLIs (`claude`, `codex`) must
  already be on the box — the daemon shells out to them and the agents run there.

> **Shipped.** Both halves have now landed (merge `63bece4`; plan
> [`2026-07-02-remote-daemon-connections`](../notes/plans/2026-07-02-remote-daemon-connections.md)). The
> **Linux port** (workstream **A**) makes `swift build` for Linux green: `UDSSocket` is Glibc/musl-ported
> with a `MSG_NOSIGNAL` send-flag (the Darwin `SO_NOSIGPIPE` path stays under `#if os(macOS)` — see the
> file-scope POSIX shims in `Platform.swift`), the launchd lifecycle in `DaemonLifecycle` is gated to
> macOS (Linux uses the systemd unit above), the Zed/Obsidian launchers become guarded no-ops, and
> `Config.dataDir` resolves to `$XDG_DATA_HOME/orchestra` (→ `~/.local/share/orchestra`) on Linux — so
> the deploy scripts now produce a working static binary. The **client half** shipped alongside it: a
> [`Transport` seam + reconnect/backoff](02-architecture.md#the-control-plane) in the shared core, a
> persisted [`Connection` model + a Connections settings pane](07-app-ui.md#onboarding-settings-recovery-and-popovers),
> and the app-managed SSH master tunnel that forwards the socket and rides the same multiplexed connection
> for [remote terminals](07-app-ui.md#terminals-and-shell-tabs). See
> [chapter 9's shipped history](09-design-decisions.md#shipped-feature-history) and
> [chapter 10](10-roadmap.md#the-nine-axes) for where this sits on the roadmap (the planned phone client
> reuses the same spine).

## Runtime configuration

Configuration lives in `~/Library/Application Support/Orchestra/config.json` (editable in the app's
Settings, or via `setConfig` over RPC). The keys and defaults are in
[Data model](03-data-model.md#configuration-and-paths). The most commonly tuned ones:

- **`reposRoot` / `allowlist`** — which directories worktree cards may touch.
- **`defaultModel` / `defaultAgentId`** — the default agent and model for new cards.
- **`statusLineMode`** — passthrough your global Claude status line, a custom command, or the minimal
  Orchestra default.

All daemon/app state is keyed off `$HOME`, not the bundle location, so it follows the user. To wipe it,
use `scripts/reset-state.sh`. (On a Linux daemon the data dir is instead `$XDG_DATA_HOME/orchestra` →
`~/.local/share/orchestra`; `reposRoot`/`worktreesRoot`/`scratchRoot` stay `$HOME`-relative on both
platforms.)

## Real agents in isolated harnesses

Every isolated harness (`docs-shots.sh`, `iso-stack.sh`, `orch-test.sh`, the e2e scripts) steers by an
isolated `$HOME` — that *is* the isolation contract, since the daemon's socket, its data dir, and the
app's client path all derive from it. But two things break when you move `$HOME`, and **both fail
silently in a way that looks like success**:

- **Claude can't find its credentials.** On macOS, Claude Code stores OAuth credentials in the login
  **Keychain**, which macOS resolves through `$HOME/Library/Keychains`
  ([docs](https://code.claude.com/docs/en/authentication.md)). Under an isolated `$HOME` it is simply
  "Not logged in" — so the agent sits at a login prompt forever *while the board reports the card
  `running`*. Every `USE_REAL_CLAUDE=1` run was affected by this before it was fixed.
  (`~/.claude/.credentials.json` is a red herring: that's the Linux/Windows store. Copying it does not
  work — the OAuth refresh token rotates, so a copy authenticates once and then 401s for *everyone*,
  including the original home.)
- **macOS pops a modal dialog.** With no keychain at that path, the OS shows
  *"Keychain Not Found — a keychain cannot be found to store &lt;user&gt;"* — once **per agent launch**.

`scripts/lib/agent-auth.sh` fixes both by symlinking the real `~/Library/Keychains` into the run's
throwaway home, so isolated agents authenticate with your **ordinary login** — nothing is minted,
nothing expires, and the Keychain dialogs stop. Codex authenticates from `~/.codex/auth.json`, which is
copied in the same way. Harnesses call `agent_auth_require` (a hard gate — better to refuse than to
produce a silent, empty run) and `agent_auth_seed "$ISO_HOME"`. Check it with `scripts/agent-auth.sh status`.

Two more traps worth knowing when you run real agents in a harness:

- **A missing permission parks a card forever.** An agent that reaches for an ungranted tool (e.g.
  `git rev-parse` when only `git diff` was allowed) sits on an approval prompt, and the board shows only
  "waiting" — indistinguishable from a slow agent. Scope grants by *tool*, not by guessing verbs.
- **PTY exhaustion kills every session.** macOS caps PTYs (`kern.tty.ptmx_max`, 511 by default). Leaked
  tmux servers from earlier runs eat them, and once the cap is hit **every** new card dies instantly
  (`fork failed: Device not configured`) — including on your live board. Check with
  `tmux -L probe new-session -d 'true'`; reclaim by killing stale test servers (never the live
  `orchestra` one).

## macOS permissions (TCC) for agents

Orchestra's tmux-hosted agents can screenshot and control other apps, attributed to **Orchestra** (not
Terminal). The two relevant permissions attribute to **different processes**, so grant both in System
Settings → Privacy & Security:

| Permission | Grant to |
|------------|----------|
| **Screen Recording** | `Orchestra.app` |
| **Accessibility** | `orchestrad` (the daemon binary inside the bundle: `Orchestra.app/Contents/Resources/bin/orchestrad`; add it with `+` if absent) |

Granting Accessibility to the daemon takes effect **live** — a long-running agent flips from untrusted
to trusted with no restart. Note that these preflights return `false` inside an agent's bash sandbox and
`true` unsandboxed, so screenshot/control commands must run unsandboxed.

## Troubleshooting

- **"orchestrad crashed" popup.** Almost never a real crash. `com.orchestra.daemon` is a `KeepAlive`
  LaunchAgent; when the daemon exits, launchd *immediately* re-execs it, and the kernel kills that first
  re-exec on the first validation of a **new code-signing hash** (a development artifact — every `swift
  build` changes the hash). It relaunches successfully ~10 s later. The historical *cause* of the
  daemon exiting was the SIGPIPE-on-self-close bug below; with that fixed, the daemon stops exiting and
  the popup stops. The only full cross-rebuild fix is Developer ID + notarization. Crash reports:
  `~/Library/Logs/DiagnosticReports/orchestrad-*.ips`.
- **Daemon dies when an agent closes its own card (fixed).** When an agent ran `archive` on its own
  card, killing the tmux session also killed the MCP client whose socket the request arrived on; the
  daemon's reply write hit a closed peer and raised `SIGPIPE`, terminating it. The fix sets
  `SO_NOSIGPIPE` on every control socket (per-socket, not a global `SIG_IGN`, so child git/tmux
  processes are unaffected); the write now returns `EPIPE` and the dead connection is dropped cleanly.
  Regression test: `Tests/OrchestraCoreTests/UDSSigPipeTests.swift`.
- **"orchestra quit unexpectedly" popup when an agent closes its own card (fixed).** The client-side twin
  of the daemon bug above, but a distinct process and crash. The agent's statusLine + hooks pipe their
  output to `orchestra _report`, whose stdout Claude captures; a self-close (`archive`) kills the card's
  tmux session — and that pipe — the instant the helper runs. `FileHandle.write` raised an uncatchable
  ObjC `NSFileHandleOperationException` on the `EPIPE` → `SIGABRT` (a raw `write(2)` would instead die
  with signal 13). The fix ignores `SIGPIPE` process-wide in `main.swift` and gives `ReportHelper` its own
  POSIX `read`/`write` that swallow `EPIPE`, so the best-effort helper always exits 0. Regression test:
  `Tests/IntegrationTests/ReportHelperPipeTests.swift`. (See [the report channel](06-clients-cli-mcp.md#the-hooks--_report-channel).)
- **"module compiled with a different SDK" during the app typecheck.** The ambient toolchain (Xcode)
  and the CLT SDK that `typecheck-app.sh` targets produce incompatible `OrchestraCore` modules; if
  `.build` holds an Xcode-SDK module, the CLT `swiftc -sdk .../CommandLineTools/...` refuses to import
  it. `scripts/typecheck-app.sh` sources `scripts/toolchain.sh`, which pins `DEVELOPER_DIR` to CLT and
  rebuilds the module under the matching SDK, so the mismatch can't arise. (Before the pin, the only
  recovery was clearing a global SwiftPM module cache under `~/Library` — outside the sandbox-writable
  set, so it triggered a human-approval prompt that broke unattended runs.)
- **Black rectangles / garbled glyphs in the terminal.** Caused by a missing UTF-8 locale (tmux and
  Claude Code's renderer downconvert multibyte glyphs without it). `Proc` fills in `LC_CTYPE`/`LANG`
  when unset; see `notes/designs/terminal-black-rectangles.md` for the full analysis.
- **Tools not found by the daemon/app.** launchd/Finder give a minimal `PATH`; `Proc.augmentedPATH`
  appends the common locations (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, …). If a tool
  still isn't found, ensure it's in one of those or on the inherited `PATH`.
- **Resetting everything.** `scripts/reset-state.sh` (add `--worktrees` to also wipe `~/.orchestra`,
  which may contain uncommitted agent work).
