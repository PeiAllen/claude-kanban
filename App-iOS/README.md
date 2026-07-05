# Orchestra iOS app (skeleton — PR F3)

A minimal SwiftUI iOS app that reuses the shared client core (`OrchestraKit`) + the shared SwiftUI
layer (`OrchestraUI`, incl. the **shared `BoardModel`**) and renders a live board from a local daemon.

## Build
    scripts/build-ios-app.sh            # Release build for the iOS Simulator
    scripts/build-ios-app.sh --debug    # Debug
    scripts/build-ios-app.sh --run      # build + boot a Simulator + launch + screenshot to .scratch/
    scripts/typecheck-ios.sh            # compile-only gate (no signing/install) for the whole App-iOS

Requires full Xcode + `brew install xcodegen`. The `.xcodeproj` is generated from
`App-iOS/project.yml` (never checked in). `--run` auto-picks the first available iPhone Simulator
(override with `ORCH_SIM_DEVICE="iPhone 17"`).

## Architecture (reconcile #3)
The app builds the **shared `OrchestraUI.BoardModel(platform: .ios)`** — not a throwaway iOS model.
`BoardModel`'s macOS machinery (SSH tunnel / daemon lifecycle / notifier) is `#if os(macOS)`-fenced;
F3 fills its `#if os(iOS) activate()` connect path. iOS conformers for the four platform protocols
(`Clipboard`/`SystemOpener`/`WindowConfig`/`TerminalHost`) live in `Platform/IOSPlatform.swift`; the
terminal host is a placeholder until T1.

## Dev transport (Simulator only)
On iOS `Config.socketPath` resolves into the app's sandbox container, so the Simulator app can't find
the Mac daemon socket by default. `ConnectionSocketResolver` returns an `ORCH_DEV_SOCKET` override for
the local connection; set it to the Mac's absolute socket path:

    ~/Library/Application Support/Orchestra/orchestrad.sock

Set it in the Xcode scheme (Run → Arguments → Environment) or, via `simctl`, as
`SIMCTL_CHILD_ORCH_DEV_SOCKET` (simctl passes trailing args as argv, not env). `scripts/build-ios-app.sh
--run` wires this automatically and screenshots to `.scratch/ios-board.png`.

**Verified:** the iOS Simulator connects to the Mac daemon's Unix-domain socket directly (the Simulator
shares the Mac filesystem) — the app renders live cards and reflects `connectionState`. A real **device**
needs the SSH-forwarded-UDS transport (PR T1) — not wired here.

## Terminal over SSH PTY (PR T1)
`IOSTerminalHost` (the iOS `TerminalHost` conformer, injected via F2's Environment key) mounts a live
UIKit **SwiftTerm `TerminalView`** driven over an **in-process SSH PTY** — the design's "iOS terminals
over SSH PTY … the daemon proxies no bytes" (phone-client `01-design.md`). iOS apps can't fork/exec the
system `ssh`, so the SSH client is Apple's first-party **swift-nio-ssh** (provider-neutral — a terminal
is not Claude/Codex-specific). Layers:

- `Terminal/TmuxAttach.swift` (in `OrchestraKit`, shared + unit-tested) — the grouped **view-session**
  attach recipe, byte-for-byte the desktop's `AgentTerminalView.attachScript()` (`<base>__<window>`,
  `new-session … 2>/dev/null` so a reconnect reuses the live view session). `sshExecCommand()` wraps it
  with a PATH/locale prelude for a non-interactive SSH exec. A `takeover` variant adds `detach-client`
  for T4.
- `Terminal/SSHPTYChannel.swift` — a `TerminalByteChannel` backed by swift-nio-ssh: connect → session
  child channel → `pty-req` (`xterm-256color`, cols×rows) → `exec` the attach command → pipe bytes both
  ways, `window-change` on resize. All NIO I/O is confined behind Sendable boxes; output is delivered to
  the main actor in order.
- `Terminal/SSHKeyStore.swift` — per-device **Ed25519 key in the Keychain** (`AfterFirstUnlock`,
  non-syncing). `authorizedKeyLine()` is the one line to add to the Mac's `~/.ssh/authorized_keys`.
- `Terminal/IOSTerminalView.swift` — the SwiftTerm view + a `Coordinator` that owns the channel across
  SwiftUI re-renders (client half of reconnect idempotency) and reconnects with bounded backoff.

The seam (`TerminalByteChannel`) is what lets **T2** (phone-owned shell), **T3** (Agent), and **T4**
(takeover) reuse the same view with a differently-parameterised channel.

### Configuring the endpoint
`ORCH_SSH_TARGET=<user>@<host>[:port]` selects the Mac to SSH to (env / Simulator launch arg; a real
Settings surface is M5). Unset → the terminal renders a live SwiftTerm view with a setup banner that
includes this device's `authorized_keys` line.

- **Simulator**: shares the Mac's network, so `<you>@localhost` works once the Mac trusts the device key
  (either Remote Login on + the key in `authorized_keys`, or a throwaway sshd — see verification below).
- **Device**: the Mac's Tailscale name/IP (`<you>@my-mac.tailnet.ts.net`) — SSH-over-Tailscale, per
  phone-client `01-design.md`.

### Verifying (`scripts/t1-live-attach.sh`)
A fully isolated harness (no user system changes): builds the Debug app, boots a Simulator, exports the
device's Keychain pubkey from the app container, starts a **throwaway non-root sshd** on `:12222` that
trusts it, starts a throwaway tmux window, then launches the app (DEBUG `Terminal` tab, auto-attach via
`ORCH_T1_*` env) and screenshots the live attach — twice, asserting reconnect reuses the **same** grouped
view session. The DEBUG-only `Terminal` tab + `DebugSupport` exist only to drive this before T2/T3/T4
provide product surfaces; both compile out of Release.

Host-key policy is trust-on-first-use *accept* (a personal Mac over a trusted Tailscale link); strict
per-host pinning is a device-hardening follow-on (swift-nio-ssh doesn't expose the host key's raw bytes
for a stable fingerprint without private API).

## Live takeover (T4)

`Views/AgentTakeoverView.swift` is the full-screen **Take Over Agent Terminal** surface — the phone
attaching the REAL agent TUI (Claude *or* Codex, provider-neutrally) under D4's exclusive lease.

- **Lease lifecycle** — `Terminal/TakeoverController.swift`: on appear, `takeOverAgentTerminalAsPhone`
  (CAS to `.phone`, epoch++, returns the `agent` `TmuxTarget`); heartbeat ~10s (well inside D4's 30s
  stale window); **drop** the attach when ownership flips away (a desktop Retake → `phoneStillHolds…`
  reads `false` via the pure `PhoneTakeoverPolicy.phoneTakeoverStatus`), caught both on a heartbeat reply
  and on a live owner event; **Return to Desktop** releases (epoch-guarded). All RPCs route through
  `BoardModel`'s phone methods, so `clientId` stays private to the shared model.
- **Attach** — `IOSTerminalHost.takeoverAttach` runs `TmuxAttach.attachScript(takeover: true)`
  (`detach-client` first) so the phone is the *sole* client of the grouped `agent` view session (no
  resize-fight). Called only after the lease is held, so the desktop has already unmounted (D5).
- **Surface** — compact owner bar (title/status · connection · *You have control* · Return to Desktop);
  **armed input** (nothing sends until *Start Typing*); a minimal **accessory bar** (Esc · sticky Ctrl ·
  Tab · ↵ · ↑ · ↓ · ⋯ drawer for Left/Right/PgUp/PgDn/Home/End); explicit **Select** mode; **A− / A+**
  font; landscape-friendly. Key bytes are the canonical xterm sequences in `OrchestraKit/TerminalKeyBytes`
  (`applyControlModifier` folds sticky-Ctrl chords). `Terminal/TerminalControl.swift` is the reusable
  handle the chrome drives the mounted `IOSTerminalView` through (T2's live shell reuses it).
- **Entry point** — the real "Take Over Agent Terminal" button belongs on the **T3 Agent tab** (not built
  yet). Until then a temporary **DEBUG** entry lives in the `Terminal` harness tab (a card-id field + a
  Take Over button; `ORCH_T4_CARD` / `ORCH_T4_AUTOTAKEOVER=1` drive it headlessly).

### Verifying

- **Lease round-trip** (`scripts/t4-takeover-verify.sh`) — drives D4's ownership RPCs against an isolated
  daemon in the exact sequence the controller performs: `takeOver(.phone)` → owner `.phone` + epoch++ →
  heartbeat → a `takeOver(.desktop)` **retake** flips ownership (the drop signal) → a stale phone
  `release` is an epoch-guarded no-op → clean release. No app needed.
- **Full-stack screenshot** (`scripts/t4-takeover-shot.sh`) — isolated daemon + seeded stand-in `agent`
  window + throwaway sshd + the Debug app auto-taking over: the app connects, holds the `.phone` lease,
  SSH-attaches the agent window, and heartbeats, so the shot shows the real TUI under the T4 chrome. Prints
  the daemon owner state to prove the phone holds the lease.
- **Deferred (not faked)** — a **live desktop app and the phone taking over simultaneously** is not
  exercised end-to-end here (it needs both apps up at once). The desktop half is D5's (verified there); the
  seam between them — the daemon owner event — is exercised from both sides in isolation (D5's desktop
  tests + T4's `takeOver(.desktop)` retake in the lease harness), just not in one live both-apps run.

## Scope
Board · Needs You · Settings tabs (+ a DEBUG-only Terminal harness tab). Board is a flat live list off
the shared `BoardModel` (the swipeable column pager is M1); Needs You + Settings are stubs (M3 / M5).
The terminal host is **real** (T1) and the live **Takeover** surface is built (T4); the Terminal (T2)
and Agent (T3) product surfaces that also mount it are still to come.
