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

## Scope
Board · Needs You · Settings tabs. Board is a flat live list off the shared `BoardModel` (the swipeable
column pager is M1); Needs You + Settings are stubs (M3 / M5). The terminal host is a placeholder (T1).
