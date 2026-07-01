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

```sh
scripts/build.sh        # swift build
scripts/test.sh         # swift test (adds swift-testing search paths — see below)
```

This repo builds the package against the **Command Line Tools** (CLT) SDK — no full Xcode required. CLT
ships `swift-testing` as a framework but not on the default search path, so `scripts/test.sh` adds the
needed `-F`/`-rpath` flags for `Testing.framework` + `lib_TestingInterop.dylib`. The test
suite is substantial — `OrchestraCoreTests` (service, task store/migration, adapters, read-only launch,
recovery, report, scratch, control round-trip, UDS SIGPIPE regression) and `IntegrationTests` (E2E
binary, launcher diff, worktree/session managers against real git/tmux).

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
| `scripts/test.sh` | `swift test` with the CLT swift-testing flags. |
| `scripts/build-app.sh` | Build & install `Orchestra.app` (`--run`, `--debug`). |
| `scripts/typecheck-app.sh` | Type-check the app sources without Xcode (pins the CLT toolchain via `toolchain.sh`). |
| `scripts/reset-state.sh` | Boot out the daemon, kill the tmux server, delete the data dir + app prefs. `--worktrees` also wipes `~/.orchestra` (opt-in — worktrees may hold uncommitted work). |
| `scripts/make-dev-cert.sh` | Create the "Orchestra Dev" self-signed signing cert. |
| `scripts/orch-test.sh` | Run a disposable **isolated** daemon (own `HOME` + tmux socket) to verify daemon/command changes without touching the live app. |
| `scripts/orch-ui-shot.sh` | Build the app isolated and screenshot it by window id (for UI work). |
| `scripts/orch-ux-e2e.sh` | Full **app + daemon** UX e2e on a disposable, isolated instance — combines the two half-harnesses above (the demo app is launched against a *real* isolated daemon, so board actions and workflows drive through the actual UI). Isolates via `$HOME` alone; spawns `orchestrad` directly (never `launchctl` — the fixed `com.orchestra.daemon` label would collide with live) + an isolated `ORCHESTRA_TMUX_SOCKET`. **Concurrency-safe** so many PR cards can run it at once overnight (see below): flags `--run-id ID` (namespace all per-run state; also `RUN_ID` env, default this PID), `--build-only` (prebuild the shared bundle then exit), `--rebuild` (force), `--no-build` (reuse). |
| `scripts/orch-ux-e2e-concurrency-test.sh` | Proof harness: launches N (default 3) `orch-ux-e2e.sh` runs concurrently and asserts they stay isolated (distinct `$HOME`/socket/tmux/screenshot), all complete (none reaped by a sibling's teardown), and the live daemon is untouched. |
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

## Runtime configuration

Configuration lives in `~/Library/Application Support/Orchestra/config.json` (editable in the app's
Settings, or via `setConfig` over RPC). The keys and defaults are in
[Data model](03-data-model.md#configuration-and-paths). The most commonly tuned ones:

- **`reposRoot` / `allowlist`** — which directories worktree cards may touch.
- **`defaultModel` / `defaultAgentId`** — the default agent and model for new cards.
- **`statusLineMode`** — passthrough your global Claude status line, a custom command, or the minimal
  Orchestra default.

All daemon/app state is keyed off `$HOME`, not the bundle location, so it follows the user. To wipe it,
use `scripts/reset-state.sh`.

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
