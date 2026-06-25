# Orchestra.app (SwiftUI)

The native macOS front end for Orchestra. It is a thin `ControlClient` over the daemon: the board,
inspector, Spawn sheet, Done/Activity popovers, and Settings render daemon state and send commands;
the embedded terminals (SwiftTerm) attach to tmux **directly**.

## Why it's not a SwiftPM target

The backend (`OrchestraCore`, `orchestrad`, `orchestra`, `orchestra-mcp`) is dependency-free and builds
offline with `swift build`. The app needs **SwiftTerm** (a network SPM dependency) and a real
**`.app` bundle**, so it lives here and is built with Xcode instead — keeping `swift test` green and
offline.

## Build

Requires **full Xcode** (not just Command Line Tools) for the macOS app/bundle + SwiftUI previews.

```sh
brew install xcodegen        # one-time
cd App
xcodegen generate            # writes Orchestra.xcodeproj (links ../  OrchestraCore + SwiftTerm)
open Orchestra.xcodeproj      # ⌘R to run
```

XcodeGen wires two packages (see `project.yml`): the local `OrchestraCore` library (`path: ..`) and
`SwiftTerm` (fetched from GitHub on first resolve). On first launch the app ensures the `orchestrad`
LaunchAgent is installed/running, then connects over the user unix socket.

> First app build under Xcode 26+ fails on SwiftTerm's Metal shader until you fetch the now-separate
> Metal toolchain once: `xcodebuild -downloadComponent MetalToolchain` (~688 MB).

## Scripts

One-shot helpers (regenerate the project, set `DEVELOPER_DIR` to Xcode.app if `xcode-select` still
points at the Command Line Tools):

```sh
scripts/build-app.sh             # build Release → install into /Applications
scripts/build-app.sh --run       # build, install, and launch
scripts/build-app.sh --debug     # Debug configuration instead of Release
scripts/reset-state.sh           # stop daemon, remove LaunchAgent + data store, kill tmux (keeps worktrees)
scripts/reset-state.sh --worktrees   # also delete ~/.orchestra worktrees (DESTRUCTIVE)
```

State lives under `~/Library/Application Support/Orchestra/` (daemon: `config.json`, `tasks.json`,
socket, log), `~/Library/LaunchAgents/com.orchestra.daemon.plist`, the app's UI prefs in
`com.orchestra.app`, and git worktrees under `~/.orchestra/worktrees/` — all keyed off `$HOME`, not
the bundle location. `reset-state.sh` clears the first three; `--worktrees` adds the last.

## Verifying without Xcode

The app sources **type-check** against the Command Line Tools SDK (SwiftUI is present there) plus the
built core module — handy for CI/quick checks. SwiftTerm is guarded by `#if canImport(SwiftTerm)` so
the terminal view falls back to a copy-the-attach-line placeholder when it isn't linked:

```sh
swift build                  # build OrchestraCore first
swiftc -typecheck \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
  -target arm64-apple-macosx14.0 \
  -I .build/arm64-apple-macosx/debug/Modules \
  App/Theme.swift App/BoardModel.swift App/OrchestraApp.swift App/Views/*.swift
```

## Files

| File | Role |
|------|------|
| `OrchestraApp.swift` | `@main`, window + Settings scene, daemon ensure-running, ContentView composition, toasts, `orchestra://` URL handling |
| `BoardModel.swift` | `@MainActor ObservableObject` — ControlClient + subscribe → `@Published` state; all actions |
| `Theme.swift` | Light/Dark + accent/density tokens (exact prototype values), fonts, semantic palette |
| `Views/ToolbarView.swift` | MCP chip · Done · Activity · Light/Dark · New agent |
| `Views/BoardView.swift` | 3 columns (Plan/Implementation/Review) + drag-and-drop |
| `Views/CardView.swift` | status pill (+ running shimmer / pulse) · title · desc · repo·branch · meta |
| `Views/InspectorView.swift` | header · context bar · terminal header · breadcrumb · agent terminal · prompt · shell strip |
| `Views/RecoveryView.swift` | the `dead`-card panel: why-line · Originally asked · Start new / Archive / Try resume |
| `Views/AgentTerminalView.swift` | SwiftTerm `LocalProcessTerminalView` running `tmux attach` (with a no-SwiftTerm fallback) |
| `Views/ShellTabsView.swift` | shell-window tab ribbon + resizable panel |
| `Views/SpawnSheet.swift` | prompt-only Spawn sheet + repo/branch/model/start-in + CLI-equivalent preview |
| `Views/DonePopover.swift` · `ActivityPopover.swift` | archive list · Live/CLI activity feed |
| `Views/SettingsView.swift` | daemon Config (roots/model/allowlist/statusLine) + appearance prefs |
