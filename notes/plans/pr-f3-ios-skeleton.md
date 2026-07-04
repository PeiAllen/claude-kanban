# PR F3 — iOS App Skeleton + Build Path — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a buildable iOS Orchestra app target (min iOS 17) that links the shared client core, shows a bottom tab bar **Board · Needs You · Settings**, and renders a *live* board of real cards from a local daemon over a dev transport — proving the shared core + reconnect run on-device.

**Architecture:** A new XcodeGen app spec (`App-iOS/project.yml`, mirroring `App/project.yml`) produces an iOS `.app` that links the SwiftPM products `OrchestraKit` (F1) + `OrchestraUI` (F2) + SwiftTerm-iOS. A minimal SwiftUI `@main` App hosts a `TabView`; the Board tab is driven by a **thin iOS board connector** that reuses `ConnectionStore` → resolves a socket path → builds a `ControlClient` (F1) → `connect()`/`subscribe()` → publishes `[Task]` + `ConnectionState`. iOS conformers for F2's platform protocols (`Clipboard`/`SystemOpener`/`WindowConfig`/`TerminalHost`) are provided; the terminal one is a placeholder until T1. Two scripts (`build-ios-app.sh`, `typecheck-ios.sh`) mirror the macOS pair.

**Tech Stack:** Swift 6 / SwiftUI, SwiftPM (OrchestraKit/OrchestraUI from F1/F2), XcodeGen, SwiftTerm (iOS), `xcodebuild -destination 'generic/platform=iOS Simulator'`, `xcrun simctl` for the headless smoke check.

## Global Constraints

- **Design for every agent (Claude AND Codex).** No `if agent == "claude"` branches. (F3 is UI-shell only — it renders board state generically; nothing agent-specific.)
- **Daemon wire protocol changes stay minimal.** F3 makes **zero** daemon/wire changes — it is a pure client consumer of shipped RPCs (`list`, `subscribe`).
- **Do not regress the desktop or the Linux daemon build.** `swift build` / `swift test` stay offline-green; `scripts/build-app.sh` (macOS) and `scripts/build-linux-daemon.sh` keep working. F3 must not edit `App/project.yml`, `App/*`, or any daemon/CLI source.
- **`embedded.conf` is unchanged.** (F3 does not touch tmux/config.)
- **Small stacked PRs over big ones.** Branch `mobile/f3-ios-skeleton` stacks on `mobile/f2-platform-protocols`. Commit per task.
- **Min deployment target iOS 17.0**, matching F1's `.iOS(.v17)` package floor.
- **Reuse shipped primitives:** `Connection`/`ConnectionStore`, `ControlClient` reconnect, `subscribe` event ring, `Theme`. Rebuild nothing that F1/F2 already moved into shared code.

---

## Dependency contract (what F1/F2 hand F3)

F3 **consumes** the following. Each is a *precondition* — if a name below differs in the merged F1/F2, adjust the conformer/import to the real API (these are the only coupling points):

**From F1 (`OrchestraKit`, `platforms: [.macOS(.v14), .iOS(.v17)]`):**
- `Model.swift` → `Task`, `Column`, `AgentStatus`, `CardOrigin`, `DiffStat`, `Event`, `ActivityItem`.
- `Control/{Transport, ControlClient, RPC, RPCCodec, UDSSocket, LineReader}.swift` → `ControlClient(socketPath:source:)`, `.connect()`, `.subscribe() -> AsyncStream<Event>`, `.call(...)`, `ConnectionState`, `onState`.
- `Connection.swift`, `ConnectionStore.swift` → `ConnectionStore()`, `.active`, `.all`.
- `Config.swift` → path resolvers (`Config.socketPath`, `Config.dataDir`, `Config.home`).
- `ActivitySource` (has `.app`).

**From F2 (`OrchestraUI` shared SwiftUI target, or `OrchestraKit` if F2 kept it there — import whichever F2 chose):**
- `Theme` (pure SwiftUI) + the `\.theme` environment key.
- Platform protocols, injected via SwiftUI `Environment`. **Assumed shapes** (confirm against F2's `PlatformProtocols.swift`):
  ```swift
  public protocol Clipboard     { func copy(_ string: String); var string: String? { get } }
  public protocol SystemOpener  { func open(_ url: URL) }
  public protocol WindowConfig  { func minSize() -> CGSize /* or a no-op marker on iOS */ }
  public protocol TerminalHost  { /* opaque terminal factory; macOS = local PTY, iOS = SSH (T1) */ }
  ```
  and their `EnvironmentValues` accessors (assumed `\.clipboard`, `\.systemOpener`, `\.windowConfig`, `\.terminalHost`).

**Deliberate non-dependency (key design call):** F3 does **not** reuse the macOS `BoardModel`'s connect machinery (`ConnectionController` SSH tunnel, `DaemonLifecycle`, `AgentNotifier`, `bundledDaemonBinary()`, `terminalHost` wiring) — those are macOS-only and only become portable across the M-series. The skeleton uses a **thin `IOSBoardModel` connector** (Task 4) that owns a `ControlClient` directly, so F3 builds and ships independent of when F2's `BoardModel` becomes fully iOS-drivable. `ConnectionStore`, `ControlClient`, `Model`, and `Theme` are all still reused — this is "reuse the shared core," minus the macOS-entangled orchestration `BoardModel` layers on top. M1 (board pager) swaps to the shared `BoardModel` once it's confirmed iOS-drivable.

---

## The connection-wiring path (the "dev transport")

Acceptance requires the app, "launched against a local daemon (over the dev transport)," to show real cards. Concretely:

- The **iOS Simulator shares the Mac filesystem**, so the app can `connect()` a Unix-domain socket at an **absolute Mac path** — the running daemon's `~/Library/Application Support/Orchestra/orchestrad.sock`.
- **Problem:** on iOS, `Config.socketPath` resolves via `NSHomeDirectory()` = the app's *sandbox container*, not the Mac user's home — so it points at a non-existent socket.
- **Fix (dev transport):** `ConnectionSocketResolver` (Task 3) returns an **override absolute path** from the env var `ORCH_DEV_SOCKET` (settable in the Xcode scheme, visible to the Simulator process) when the active connection is `.local`; it falls back to `Config.socketPath` otherwise. `IOSBoardModel` builds `ControlClient(socketPath: resolved)`.
- **Scope boundary:** this direct-UDS path works **only in the Simulator**. A real device needs the SSH-forwarded-UDS transport, which is **not built until T1/remote work** — out of scope for F3. The plan and the final report flag this explicitly.
- **Risk to validate first (Task 5):** the Simulator's sandbox must permit connecting to a UDS outside the app container. This is the single reachability unknown; the fallback if it is blocked is documented in Open Questions (O-3).

---

## File structure

**Create (all new, no existing files modified except the two guards noted):**

| File | Responsibility |
|---|---|
| `App-iOS/project.yml` | XcodeGen spec: iOS app target `OrchestraiOS` + unit-test target, min iOS 17, links OrchestraKit/OrchestraUI/SwiftTerm. |
| `App-iOS/Info.plist` | iOS app Info.plist (bundle name, min version, no URL scheme yet). |
| `App-iOS/OrchestraApp.swift` | `@main` App; `TabView` shell Board·Needs You·Settings; injects platform env + theme; owns `IOSBoardModel`. |
| `App-iOS/IOSBoardModel.swift` | Thin `@MainActor ObservableObject`: `ConnectionStore` → `ControlClient` → connect/subscribe → `@Published tasks`, `@Published connectionState`. |
| `App-iOS/Platform/IOSPlatform.swift` | iOS conformers: `IOSClipboard` (UIPasteboard), `IOSSystemOpener` (UIApplication/no-op), `IOSWindowConfig` (no-op), `IOSTerminalHost` (placeholder until T1). |
| `App-iOS/Views/BoardTab.swift` | Board tab: connection banner + `List` of `Task` rows (title, `repo/branch` mono, status pill). |
| `App-iOS/Views/NeedsYouTab.swift` | Stub "Needs You" tab (empty-state placeholder; real queue = M3). |
| `App-iOS/Views/SettingsTab.swift` | Stub Settings tab (connection status line + version; real settings = M5). |
| `App-iOS/Tests/IOSAppTests.swift` | iOS XCTest target: platform-conformer + `IOSBoardModel` event-apply tests (run via `xcodebuild test`). |
| `App-iOS/README.md` | How to build/run the iOS app + the `ORCH_DEV_SOCKET` dev transport. |
| `Sources/OrchestraKit/ConnectionSocketResolver.swift` | Pure socket-path resolver (dev override vs `Config.socketPath`); unit-tested in `swift test`. |
| `scripts/build-ios-app.sh` | `xcodegen` + `xcodebuild ... build`; `--run` boots a Simulator, installs, launches, screenshots. |
| `scripts/typecheck-ios.sh` | Fast compile-only gate: `xcodebuild build` for the generic iOS Simulator with signing off. |

**Modify (guards only, both additive):**
- `Tests/OrchestraKitTests/…` — add one test file for the resolver (F1 created this target; confirm its name — see O-1).
- No change to `Package.swift` expected (F1/F2 set the iOS platforms). Task 1 verifies this and only edits `Package.swift` if a linked product lacks `.iOS`.

---

## Task 1: iOS build path — XcodeGen spec + build/typecheck scripts (empty app compiles for the Simulator)

**Goal:** Prove the SwiftPM package (OrchestraKit + OrchestraUI) and SwiftTerm all resolve and compile for iOS behind a real `.app`. This is the biggest de-risk in the PR; everything else builds on a green iOS compile.

**Files:**
- Create: `App-iOS/project.yml`, `App-iOS/Info.plist`, `App-iOS/OrchestraApp.swift` (temporary empty body), `scripts/build-ios-app.sh`, `scripts/typecheck-ios.sh`
- Verify (edit only if needed): `Package.swift`

**Interfaces:**
- Consumes: SwiftPM package at repo root (products `OrchestraKit`, `OrchestraUI` from F1/F2); SwiftTerm 1.2.0+.
- Produces: `App-iOS/OrchestraiOS.xcodeproj` (generated), a Simulator-buildable `OrchestraiOS.app`, and the two scripts later tasks re-run as their build gate.

- [ ] **Step 1: Confirm the package exposes iOS platforms (read-only check).**

Run:
```bash
grep -n "iOS" Package.swift
swift package dump-package | python3 -c "import sys,json; d=json.load(sys.stdin); print([ (p.get('platformName'), p.get('version')) for p in d.get('platforms',[]) ])"
```
Expected: `platforms` includes `ios 17.0`. If iOS is **absent** (F1 not yet merged into this branch), stop — F3 cannot proceed without F1/F2 (see O-1); do not add iOS platforms here (that is F1's job).

- [ ] **Step 2: Write the XcodeGen spec `App-iOS/project.yml`.**

```yaml
# XcodeGen spec for the Orchestra iOS app (mirrors App/project.yml for macOS).
#   brew install xcodegen
#   xcodegen generate --spec App-iOS/project.yml --project App-iOS
# Links the local SwiftPM package (OrchestraKit + OrchestraUI) and SwiftTerm (iOS).
name: OrchestraiOS
options:
  bundleIdPrefix: com.orchestra
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true

packages:
  Orchestra:
    path: ..                       # the SwiftPM package at the repo root
  SwiftTerm:
    url: https://github.com/migueldeicaza/SwiftTerm
    from: 1.2.0

targets:
  OrchestraiOS:
    type: application
    platform: iOS
    sources:
      - path: .
        excludes: ["project.yml", "README.md", "Tests"]
    info:
      path: Info.plist
      properties:
        CFBundleName: OrchestraiOS
        CFBundleDisplayName: Orchestra
        UILaunchScreen: {}
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: false
    dependencies:
      - package: Orchestra
        product: OrchestraKit
      - package: Orchestra
        product: OrchestraUI
      - package: SwiftTerm
        product: SwiftTerm
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.orchestra.ios
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        SWIFT_VERSION: "6.0"
        TARGETED_DEVICE_FAMILY: "1,2"   # iPhone + iPad
        GENERATE_INFOPLIST_FILE: NO
      configs:
        Debug:
          SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG
        Release:
          SWIFT_ACTIVE_COMPILATION_CONDITIONS: ""

  OrchestraiOSTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: Tests
    dependencies:
      - target: OrchestraiOS
      - package: Orchestra
        product: OrchestraKit
    settings:
      base:
        SWIFT_VERSION: "6.0"
        GENERATE_INFOPLIST_FILE: YES
```

> Note: if F2 kept `Theme` + protocols inside `OrchestraKit` (not a separate `OrchestraUI`), drop the `OrchestraUI` dependency line. Task 2/4 imports match whichever module F2 shipped.

- [ ] **Step 3: Write a minimal iOS Info.plist `App-iOS/Info.plist`.**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
  <key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UILaunchScreen</key><dict/>
  <key>UISupportedInterfaceOrientations</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
</dict>
</plist>
```

- [ ] **Step 4: Write a temporary empty `@main` app `App-iOS/OrchestraApp.swift`.**

This exists only to make the target compile+link this task. It is replaced in Task 4.

```swift
import SwiftUI

@main
struct OrchestraiOSApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Orchestra iOS — skeleton")
        }
    }
}
```

- [ ] **Step 5: Write `scripts/build-ios-app.sh`.**

```bash
#!/bin/bash
# Build (and optionally boot+launch) the Orchestra iOS app for the Simulator.
# Mirrors scripts/build-app.sh; the iOS app needs full Xcode + xcodegen + SwiftTerm.
#
# Usage: scripts/build-ios-app.sh [--run] [--debug] [-- <extra xcodebuild args>]
#   --run     boot a Simulator, install, launch with ORCH_DEV_SOCKET, screenshot to .scratch/
#   --debug   build Debug instead of Release
set -euo pipefail
cd "$(dirname "$0")/.."

RUN=0
CONFIG="Release"
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --run)   RUN=1; shift ;;
    --debug) CONFIG="Debug"; shift ;;
    --)      shift; break ;;
    *)       echo "error: unknown option '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: full Xcode not found. Install Xcode.app or set DEVELOPER_DIR." >&2; exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install with: brew install xcodegen" >&2; exit 1
fi

xcodegen generate --spec App-iOS/project.yml --project App-iOS

xcodebuild \
  -project App-iOS/OrchestraiOS.xcodeproj \
  -scheme OrchestraiOS \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build "$@"

echo "iOS build OK ($CONFIG)."

if [[ "$RUN" == 1 ]]; then
  # Boot a headless Simulator, install, launch against the local daemon socket, screenshot.
  # Never touches the user's screen (the Simulator runs headless; simctl drives it).
  DEV_SOCKET="${ORCH_DEV_SOCKET:-$HOME/Library/Application Support/Orchestra/orchestrad.sock}"
  DEVICE="${ORCH_SIM_DEVICE:-iPhone 15}"
  UDID="$(xcrun simctl list devices available | awk -v d="$DEVICE" 'index($0,d){match($0,/\(([0-9A-F-]+)\)/,m); if(m[1]){print m[1]; exit}}')"
  [[ -n "$UDID" ]] || { echo "error: no available Simulator '$DEVICE'"; exit 1; }
  xcrun simctl boot "$UDID" 2>/dev/null || true
  APP="$(xcodebuild -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS -configuration "$CONFIG" \
    -destination 'generic/platform=iOS Simulator' -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR / {d=$2} / FULL_PRODUCT_NAME / {n=$2} END {print d "/" n}')"
  xcrun simctl install "$UDID" "$APP"
  xcrun simctl launch --console-pty "$UDID" com.orchestra.ios ORCH_DEV_SOCKET="$DEV_SOCKET" &
  sleep 4
  mkdir -p .scratch
  xcrun simctl io "$UDID" screenshot .scratch/ios-board.png
  echo "Screenshot: .scratch/ios-board.png"
fi
```

- [ ] **Step 6: Write `scripts/typecheck-ios.sh`.**

The macOS `typecheck-app.sh` shortcuts via `swiftc -typecheck` against the CLT SDK + a prebuilt module. That shortcut does **not** work for iOS (no CLT iOS SDK path that also carries SwiftTerm/OrchestraUI iOS modules), so the iOS typecheck is a signing-free `xcodebuild build` — the cheapest reliable "does it compile for iOS" gate.

```bash
#!/bin/bash
# Type-check (compile-only, no signing, no install) the Orchestra iOS app for the Simulator.
# The iOS equivalent of scripts/typecheck-app.sh — but iOS has no CLT-SDK swiftc shortcut that
# also resolves SwiftTerm/OrchestraUI iOS modules, so it drives xcodebuild build instead.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v xcodegen >/dev/null 2>&1 || { echo "error: xcodegen not found (brew install xcodegen)"; exit 1; }
xcodegen generate --spec App-iOS/project.yml --project App-iOS
exec xcodebuild \
  -project App-iOS/OrchestraiOS.xcodeproj \
  -scheme OrchestraiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

- [ ] **Step 7: Make scripts executable and run the build (verify it compiles for iOS).**

Run:
```bash
chmod +x scripts/build-ios-app.sh scripts/typecheck-ios.sh
scripts/build-ios-app.sh --debug
```
Expected: `** BUILD SUCCEEDED **` then `iOS build OK (Debug).` — this proves OrchestraKit, OrchestraUI, and SwiftTerm all compile+link for iOS. If SwiftTerm-iOS fails to build, that is the exact early-surfaced risk this task exists to catch (see O-2).

- [ ] **Step 8: Commit.**

```bash
git add App-iOS/project.yml App-iOS/Info.plist App-iOS/OrchestraApp.swift scripts/build-ios-app.sh scripts/typecheck-ios.sh
git commit -m "build(ios): XcodeGen iOS app target + build/typecheck scripts (empty @main compiles)"
```

---

## Task 2: iOS platform-protocol conformers + iOS unit-test target

**Goal:** Supply the iOS implementations of F2's platform protocols so the shared UI has its per-OS bits, and stand up the `xcodebuild test` cycle that later tasks reuse.

**Files:**
- Create: `App-iOS/Platform/IOSPlatform.swift`, `App-iOS/Tests/IOSAppTests.swift`
- Modify: `App-iOS/project.yml` already declares the test target (Task 1) — no change.

**Interfaces:**
- Consumes: F2 protocols `Clipboard`, `SystemOpener`, `WindowConfig`, `TerminalHost` (from `OrchestraUI`/`OrchestraKit`).
- Produces: `IOSClipboard`, `IOSSystemOpener`, `IOSWindowConfig`, `IOSTerminalHost` — the values Task 4 injects into the SwiftUI environment.

- [ ] **Step 1: Write the failing clipboard test `App-iOS/Tests/IOSAppTests.swift`.**

```swift
import XCTest
@testable import OrchestraiOS   // internal access to the app target's conformers

final class IOSAppTests: XCTestCase {
    func testClipboardRoundTrip() {
        let clip = IOSClipboard()
        clip.copy("orchestra-ios")
        XCTAssertEqual(clip.string, "orchestra-ios")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails (types not defined).**

Run:
```bash
xcodegen generate --spec App-iOS/project.yml --project App-iOS
xcodebuild test -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -30
```
Expected: FAIL — compile error `cannot find 'IOSClipboard' in scope`.

- [ ] **Step 3: Write the conformers `App-iOS/Platform/IOSPlatform.swift`.**

> Match method names to F2's finalized protocols. The bodies below assume the shapes in the Dependency Contract; if F2 named a method differently (e.g. `func writeToPasteboard`), rename to match — the *logic* is what matters.

```swift
import UIKit
import OrchestraUI   // or OrchestraKit, whichever module F2 put the protocols in
import SwiftUI

/// iOS clipboard via UIPasteboard.
struct IOSClipboard: Clipboard {
    func copy(_ string: String) { UIPasteboard.general.string = string }
    var string: String? { UIPasteboard.general.string }
}

/// iOS "open" — routes URLs to the system; local-file reveal has no phone analogue, so those are no-ops.
struct IOSSystemOpener: SystemOpener {
    func open(_ url: URL) {
        guard url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" else { return }
        UIApplication.shared.open(url)
    }
}

/// iOS has no resizable window chrome — the shared WindowConfig is a no-op here.
struct IOSWindowConfig: WindowConfig {
    func minSize() -> CGSize { .zero }
}

/// Placeholder terminal host until T1 lands the SwiftTerm-iOS SSH-PTY implementation.
/// Renders an explanatory stub instead of a live terminal, and never attaches anything.
struct IOSTerminalHost: TerminalHost {
    // Conform to F2's TerminalHost surface. Every "make a terminal" entry point returns this stub view.
    func makeView() -> AnyView {
        AnyView(
            Text("Terminal coming soon")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }
}
```

- [ ] **Step 4: Run the test to verify it passes.**

Run:
```bash
xcodebuild test -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
git add App-iOS/Platform/IOSPlatform.swift App-iOS/Tests/IOSAppTests.swift
git commit -m "feat(ios): iOS platform-protocol conformers (clipboard/opener/windowconfig/placeholder terminal) + test target"
```

---

## Task 3: `ConnectionSocketResolver` (pure dev-transport resolver) + unit test

**Goal:** A pure, host-testable resolver that decides which socket path the iOS client opens: the `ORCH_DEV_SOCKET` override (Simulator dev transport) for a local connection, else `Config.socketPath`. Lives in `OrchestraKit` so it is covered by `swift test`.

**Files:**
- Create: `Sources/OrchestraKit/ConnectionSocketResolver.swift`
- Test: `Tests/OrchestraKitTests/ConnectionSocketResolverTests.swift` (confirm the F1 test-target name — see O-1)

**Interfaces:**
- Consumes: `Connection` (`.isLocal`), `Config.socketPath`.
- Produces: `ConnectionSocketResolver.socketPath(for:env:) -> String` — used by `IOSBoardModel` (Task 4).

- [ ] **Step 1: Write the failing test `Tests/OrchestraKitTests/ConnectionSocketResolverTests.swift`.**

```swift
import XCTest
@testable import OrchestraKit

final class ConnectionSocketResolverTests: XCTestCase {
    func testLocalUsesDevOverrideWhenSet() {
        let env = ["ORCH_DEV_SOCKET": "/Users/dev/Library/Application Support/Orchestra/orchestrad.sock"]
        let path = ConnectionSocketResolver.socketPath(for: .local, env: env)
        XCTAssertEqual(path, "/Users/dev/Library/Application Support/Orchestra/orchestrad.sock")
    }

    func testLocalFallsBackToConfigWhenNoOverride() {
        let path = ConnectionSocketResolver.socketPath(for: .local, env: [:])
        XCTAssertEqual(path, Config.socketPath)
    }

    func testEmptyOverrideIsIgnored() {
        let path = ConnectionSocketResolver.socketPath(for: .local, env: ["ORCH_DEV_SOCKET": ""])
        XCTAssertEqual(path, Config.socketPath)
    }

    func testRemoteConnectionIgnoresDevOverride() {
        // Remote reachability (SSH-forward) is T1+; F3 resolves remotes to their own path, never the
        // dev override. The override is a LOCAL-only Simulator shortcut.
        let remote = Connection(name: "linux-box", kind: .remote,
                                sshTarget: "box", remoteSocketPath: "/run/orchestrad.sock")
        let path = ConnectionSocketResolver.socketPath(
            for: remote, env: ["ORCH_DEV_SOCKET": "/should/not/be/used"])
        XCTAssertNotEqual(path, "/should/not/be/used")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `swift test --filter ConnectionSocketResolverTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'ConnectionSocketResolver' in scope`.

- [ ] **Step 3: Write the resolver `Sources/OrchestraKit/ConnectionSocketResolver.swift`.**

```swift
import Foundation

/// Decides which Unix-domain socket path a client should open for a given `Connection`.
///
/// F3 / iOS-Simulator dev transport: for the built-in **local** connection, an `ORCH_DEV_SOCKET`
/// override (set in the Xcode scheme) points the Simulator app at the Mac's real daemon socket —
/// because `Config.socketPath` on iOS resolves into the app's sandbox container, not the user's home.
/// Without the override (e.g. on macOS, or a device build) it falls back to `Config.socketPath`.
/// Remote connections resolve to their own remote socket path and never consult the dev override.
public enum ConnectionSocketResolver {
    public static let devSocketEnvKey = "ORCH_DEV_SOCKET"

    public static func socketPath(
        for connection: Connection,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if connection.isLocal {
            if let override = env[devSocketEnvKey], !override.isEmpty { return override }
            return Config.socketPath
        }
        // Remote: use its configured remote socket path (reachability is handled by the SSH transport
        // in T1+; F3 does not open remote connections, but the resolver stays total).
        return connection.remoteSocketPath ?? Config.socketPath
    }
}
```

- [ ] **Step 4: Run the test to verify it passes.**

Run: `swift test --filter ConnectionSocketResolverTests 2>&1 | tail -20`
Expected: `Test Suite 'ConnectionSocketResolverTests' passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/OrchestraKit/ConnectionSocketResolver.swift Tests/OrchestraKitTests/ConnectionSocketResolverTests.swift
git commit -m "feat(kit): ConnectionSocketResolver — dev-transport socket resolution for the iOS client"
```

---

## Task 4: `IOSBoardModel` connector + `@main` TabView shell (renders a live board)

**Goal:** Replace the placeholder app with the real skeleton: a thin connector that reuses `ConnectionStore` + `ControlClient` to connect, subscribe, and publish `[Task]` + `ConnectionState`; and a `TabView` whose Board tab renders that live list with a connection banner. Needs You + Settings are stubs.

**Files:**
- Modify: `App-iOS/OrchestraApp.swift` (replace the Task-1 placeholder)
- Create: `App-iOS/IOSBoardModel.swift`, `App-iOS/Views/BoardTab.swift`, `App-iOS/Views/NeedsYouTab.swift`, `App-iOS/Views/SettingsTab.swift`
- Modify: `App-iOS/Tests/IOSAppTests.swift` (add an event-apply test)

**Interfaces:**
- Consumes: `ConnectionStore`, `ControlClient`, `ConnectionSocketResolver` (Task 3), `Task`/`Event`/`ConnectionState` (OrchestraKit), `Theme` + platform conformers (Task 2).
- Produces: `IOSBoardModel` (`@Published tasks`, `@Published connectionState`, `func bootstrap()`, `func apply(_:)`) — the M-series board pager (M1) later swaps this for the shared `BoardModel`.

- [ ] **Step 1: Write the failing event-apply test (extend `App-iOS/Tests/IOSAppTests.swift`).**

`IOSBoardModel.apply(_:)` must be pure enough to test without a live socket. Add:

```swift
import OrchestraKit

extension IOSAppTests {
    @MainActor
    func testApplyUpsertAddsAndReplacesTask() {
        let model = IOSBoardModel()
        let t = Task(title: "Wire the board", repo: "/r", branch: "feat/x",
                     cwd: "/r/.worktrees/x", model: AgentModel(id: "claude-opus-4-8"),
                     startIn: .impl, column: .impl, order: 0, status: .running, initialPrompt: "x")
        model.apply(.upsert(t))                 // Event case shape per OrchestraKit's Event enum
        XCTAssertEqual(model.tasks.count, 1)

        var updated = t; updated.status = .waiting
        model.apply(.upsert(updated))
        XCTAssertEqual(model.tasks.count, 1)
        XCTAssertEqual(model.tasks.first?.status, .waiting)

        model.apply(.remove(t.id))
        XCTAssertTrue(model.tasks.isEmpty)
    }
}
```

> The exact `Event` case names (`.upsert`/`.remove`/associated payloads) come from OrchestraKit's `Event`. If they differ (e.g. `.taskUpserted(Task)`), adjust both the test and `apply(_:)` to match the real enum — read `Sources/OrchestraKit/Model.swift` `Event` before writing.

- [ ] **Step 2: Run the test to verify it fails.**

Run:
```bash
xcodegen generate --spec App-iOS/project.yml --project App-iOS
xcodebuild test -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -20
```
Expected: FAIL — `cannot find 'IOSBoardModel' in scope`.

- [ ] **Step 3: Write `App-iOS/IOSBoardModel.swift`.**

First read the real `Event` shape:
Run: `grep -n "enum Event" -A 20 Sources/OrchestraKit/Model.swift`
Then implement (adjusting the `apply` switch to the real cases):

```swift
import Foundation
import Combine
import OrchestraKit

/// Thin iOS board connector — the F3 skeleton's stand-in for the macOS `BoardModel`, reusing the
/// shared client core (ConnectionStore + ControlClient + reconnect) without the macOS-only
/// orchestration (SSH tunnel / daemon lifecycle / notifier). M1 swaps this for the shared BoardModel.
@MainActor
final class IOSBoardModel: ObservableObject {
    @Published private(set) var tasks: [Task] = []
    @Published private(set) var connectionState: ConnectionState = .down

    private let connections = ConnectionStore()
    private var client: ControlClient?
    private var streamTask: _Concurrency.Task<Void, Never>?

    /// Connect to the active connection's daemon over the resolved (dev) socket, then stream events.
    func bootstrap() {
        let conn = connections.active
        let sock = ConnectionSocketResolver.socketPath(for: conn)
        let c = ControlClient(socketPath: sock, source: .app)
        c.onState = { [weak self] s in
            _Concurrency.Task { @MainActor in self?.connectionState = s }
        }
        client = c
        do {
            try c.connect()
        } catch {
            connectionState = .down
            return
        }
        streamTask?.cancel()
        streamTask = _Concurrency.Task { [weak self] in
            await self?.refresh()
            guard let stream = self?.client?.subscribe() else { return }
            for await event in stream { self?.apply(event) }
        }
    }

    /// Initial snapshot via `list` (the stream only carries deltas afterwards).
    func refresh() async {
        guard let client else { return }
        if let list = try? await client.call("list", .object([:])).decode([Task].self) {
            tasks = list
        }
    }

    /// Apply one event to `tasks`. Adjust the cases to OrchestraKit's real `Event` enum.
    func apply(_ event: Event) {
        switch event {
        case .upsert(let task):
            if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i] = task }
            else { tasks.append(task) }
        case .remove(let id):
            tasks.removeAll { $0.id == id }
        default:
            break   // activity/other events are not surfaced by the skeleton board
        }
    }
}
```

- [ ] **Step 4: Write the stub tabs.**

`App-iOS/Views/NeedsYouTab.swift`:
```swift
import SwiftUI

/// Stub until M3 (the real attention queue).
struct NeedsYouTab: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Nothing needs you",
                                   systemImage: "bell.slash",
                                   description: Text("Cards waiting on you will appear here."))
                .navigationTitle("Needs You")
        }
    }
}
```

`App-iOS/Views/SettingsTab.swift`:
```swift
import SwiftUI
import OrchestraKit

/// Stub until M5 (Connection · Notifications · Appearance · About). Shows just the live link state.
struct SettingsTab: View {
    @EnvironmentObject var model: IOSBoardModel
    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("Status", value: model.connectionState.rawValue)
                    LabeledContent("Daemon", value: ConnectionSocketResolver.socketPath(for: .local))
                }
                Section("About") {
                    LabeledContent("App", value: "Orchestra iOS 0.1.0")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
```

- [ ] **Step 5: Write the Board tab `App-iOS/Views/BoardTab.swift`.**

```swift
import SwiftUI
import OrchestraKit

/// Skeleton board: a connection banner + a flat list of live cards. The swipeable column pager is M1.
struct BoardTab: View {
    @EnvironmentObject var model: IOSBoardModel

    var body: some View {
        NavigationStack {
            Group {
                if model.tasks.isEmpty {
                    ContentUnavailableView("No cards",
                                           systemImage: "square.stack.3d.up.slash",
                                           description: Text("Spawn agents on the desktop to see them here."))
                } else {
                    List(model.tasks) { task in CardRow(task: task) }
                        .listStyle(.plain)
                }
            }
            .navigationTitle("Board")
            .safeAreaInset(edge: .top) { ConnectionBanner(state: model.connectionState) }
        }
    }
}

private struct CardRow: View {
    let task: Task
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.title).font(.headline).lineLimit(1)
                Spacer()
                StatusPill(status: task.status)
            }
            Text("\(URL(fileURLWithPath: task.repo).lastPathComponent)/\(task.branch)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

private struct StatusPill: View {
    let status: AgentStatus
    var body: some View {
        Text(status.rawValue.uppercased())
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
    private var color: Color {
        switch status {
        case .running: return .green
        case .waiting: return .orange
        case .dead:    return .red
        default:       return .secondary
        }
    }
}

/// Thin bar that reflects `ConnectionState`; hidden while live.
private struct ConnectionBanner: View {
    let state: ConnectionState
    var body: some View {
        if state != .live {
            HStack(spacing: 8) {
                Image(systemName: state == .retrying || state == .connecting
                      ? "arrow.triangle.2.circlepath" : "bolt.slash.fill")
                Text(label).font(.footnote.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.orange.opacity(0.15))
        }
    }
    private var label: String {
        switch state {
        case .connecting: return "Connecting…"
        case .retrying:   return "Reconnecting…"
        case .down:       return "Offline"
        case .live:       return ""
        }
    }
}
```

> `AgentStatus` case names (`.running/.waiting/.dead/…`) and `Task.repo`/`.branch`/`.title`/`.status` are confirmed against `Sources/OrchestraCore/Model.swift` (moved to `OrchestraKit` by F1). If F1 renamed anything, match it.

- [ ] **Step 6: Replace `App-iOS/OrchestraApp.swift` with the real shell.**

```swift
import SwiftUI
import OrchestraUI   // Theme + platform-protocol environment keys (or OrchestraKit if F2 kept them there)

@main
struct OrchestraiOSApp: App {
    @StateObject private var model = IOSBoardModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                BoardTab()
                    .tabItem { Label("Board", systemImage: "square.stack.3d.up") }
                NeedsYouTab()
                    .tabItem { Label("Needs You", systemImage: "bell") }
                SettingsTab()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .environmentObject(model)
            // Inject iOS platform conformers so the shared UI resolves its per-OS bits.
            // (Environment-key names per F2; adjust if F2 chose different keys.)
            .environment(\.clipboard, IOSClipboard())
            .environment(\.systemOpener, IOSSystemOpener())
            .environment(\.windowConfig, IOSWindowConfig())
            .environment(\.terminalHost, IOSTerminalHost())
            .task { model.bootstrap() }
        }
    }
}
```

- [ ] **Step 7: Run the event-apply test to verify it passes + the app builds.**

Run:
```bash
xcodebuild test -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -25
```
Expected: `** TEST SUCCEEDED **` (both `testClipboardRoundTrip` and `testApplyUpsertAddsAndReplacesTask`), and the full app target compiles.

- [ ] **Step 8: Commit.**

```bash
git add App-iOS/OrchestraApp.swift App-iOS/IOSBoardModel.swift App-iOS/Views App-iOS/Tests/IOSAppTests.swift
git commit -m "feat(ios): TabView shell (Board/Needs You/Settings) + IOSBoardModel live board connector"
```

---

## Task 5: Dev-transport smoke verification + docs + no-regression guard

**Goal:** Prove the acceptance end-to-end (real cards + `connectionState` against a local daemon), document the dev transport, and confirm desktop + Linux builds are untouched.

**Files:**
- Create: `App-iOS/README.md`
- Verify (no edits): `scripts/build-app.sh`, `scripts/build-linux-daemon.sh`

- [ ] **Step 1: Ensure a local daemon is running with at least one card.**

Run:
```bash
ls "$HOME/Library/Application Support/Orchestra/orchestrad.sock" && echo "socket present"
```
Expected: the socket exists (the user's live daemon). If absent, start the desktop app or `orchestrad` once. (Spawning a demo card is optional — an empty board still proves connection + `connectionState`.)

- [ ] **Step 2: Build, install, and launch on a headless Simulator against the live socket.**

Run:
```bash
scripts/build-ios-app.sh --run
```
Expected: `iOS build OK`, then a screenshot at `.scratch/ios-board.png`. Open it (or `SendUserFile`): the Board tab shows the real cards (or the "No cards" empty state if the board is empty) and the connection banner is **absent** (state `.live`). This is the acceptance evidence.

- [ ] **Step 3: Validate reconnect reflects in `connectionState` (optional but recommended).**

With the app running, stop the daemon, confirm the banner flips to "Reconnecting…/Offline", restart the daemon, confirm it returns to live and the board repopulates. Re-screenshot for the report. (This exercises `ControlClient` reconnect on-device — the core thing F3 proves.)

- [ ] **Step 4: Write `App-iOS/README.md`.**

```markdown
# Orchestra iOS app (skeleton — PR F3)

A minimal SwiftUI iOS app that reuses the shared client core (`OrchestraKit`) + shared UI
(`OrchestraUI`) and renders a live board from a local daemon.

## Build
    scripts/build-ios-app.sh            # Release build for the iOS Simulator
    scripts/build-ios-app.sh --debug    # Debug
    scripts/typecheck-ios.sh            # compile-only gate (no signing/install)

Requires full Xcode + `brew install xcodegen`. The `.xcodeproj` is generated from
`App-iOS/project.yml` (never checked in).

## Dev transport (Simulator only)
On iOS `Config.socketPath` resolves into the app's sandbox container, so the Simulator app can't find
the Mac daemon socket by default. Set `ORCH_DEV_SOCKET` (Xcode scheme → Run → Arguments → Environment,
or via `simctl launch`) to the Mac's absolute socket path:

    ~/Library/Application Support/Orchestra/orchestrad.sock

`scripts/build-ios-app.sh --run` wires this automatically and screenshots to `.scratch/ios-board.png`.

Device builds need the SSH-forwarded-UDS transport (PR T1) — not wired here.

## Scope
Board · Needs You · Settings tabs. Board is a flat live list (the swipeable column pager is M1); Needs
You + Settings are stubs (M3 / M5). The terminal host is a placeholder until T1.
```

- [ ] **Step 5: Confirm desktop + Linux builds still green (no regression).**

Run:
```bash
swift build 2>&1 | tail -5
swift test 2>&1 | tail -15
scripts/build-app.sh --debug 2>&1 | tail -5
scripts/build-linux-daemon.sh 2>&1 | tail -5   # if the toolchain is installed
```
Expected: all succeed. F3 added only new files (`App-iOS/*`, one `OrchestraKit` source + test, two scripts) and touched nothing on the desktop/daemon path, so these must remain green.

- [ ] **Step 6: Commit.**

```bash
git add App-iOS/README.md
git commit -m "docs(ios): App-iOS README (build + dev transport); F3 skeleton complete"
```

---

## Self-review

**1. Spec coverage (F3 scope from the forest):**
- New iOS app target via XcodeGen, min iOS 17, links OrchestraKit/OrchestraUI + SwiftTerm-iOS → **Task 1**.
- Minimal `@main` App with bottom tab bar Board · Needs You · Settings (stub contents) → **Task 4**.
- Builds a `ControlClient` from the active `Connection` (reuse `ConnectionStore`), renders a live board + reflects `connectionState` → **Tasks 3 + 4** (`ConnectionSocketResolver` + `IOSBoardModel`).
- iOS platform-protocol impls (UIPasteboard clipboard, no-op opener/windowconfig, placeholder TerminalHost) → **Task 2**.
- `scripts/build-ios-app.sh` (xcodegen + `xcodebuild -destination 'generic/platform=iOS Simulator' build`) + iOS typecheck script mirroring `typecheck-app.sh` → **Tasks 1 + 5**.
- Acceptance (builds for Simulator; live cards + `connectionState` against a local daemon; desktop + Linux green) → **Task 5**.

**2. Placeholder scan:** No TBD/TODO. Every code step shows full content. The only intentional "adjust to the real API" notes are the F1/F2 coupling points (Event enum cases, protocol method/env-key names) — unavoidable while F1/F2 are planned in parallel, and each names the exact file to read (`Model.swift` Event, F2 `PlatformProtocols.swift`) before writing.

**3. Type consistency:** `IOSBoardModel` (`tasks`, `connectionState`, `bootstrap()`, `apply(_:)`, `refresh()`) is used identically in Task 4's tests, tabs, and app shell. `ConnectionSocketResolver.socketPath(for:env:)` is defined in Task 3 and called in Task 4/`SettingsTab` with the same signature. Platform conformer names (`IOSClipboard`/`IOSSystemOpener`/`IOSWindowConfig`/`IOSTerminalHost`) match between Task 2 and Task 4's environment injection.

---

## Open questions / blockers (for the implementer + orchestrator)

- **O-1 (hard precondition):** F3's branch must be stacked on merged/available **F1 + F2**. Confirm the real names: the `OrchestraKit` test-target directory (assumed `Tests/OrchestraKitTests`), whether `Theme`+protocols live in `OrchestraUI` or `OrchestraKit`, and the exact protocol method + `EnvironmentValues` key names. All conformer/import lines adjust to these. **F3 cannot start until F1/F2 land.**
- **O-2 (SwiftTerm-iOS build):** Task 1 is the early canary — it must prove SwiftTerm 1.2.0 compiles+links for iOS behind the app target. If it fails, that's a real blocker to surface immediately (pin a version / file upstream), independent of the rest of F3.
- **O-3 (Simulator UDS reachability — the one runtime unknown):** the dev transport assumes the iOS Simulator sandbox permits connecting to a UDS outside the app container (the Mac daemon socket). If Task 5 finds it blocked, fallbacks in order: (a) run the daemon with `ORCHESTRA_*`-relocated socket inside a Simulator-readable shared dir; (b) stand up a tiny localhost TCP dev shim behind the `Transport` protocol; (c) bring T1's SSH-forward transport forward. Validate this early in Task 5 before polishing.
- **O-4 (`Event` enum shape):** `IOSBoardModel.apply(_:)` and its test assume `.upsert(Task)`/`.remove(UUID)`. Read `OrchestraKit`'s `Event` first and match the real cases.
- **O-5 (BoardModel reuse deferral):** F3 deliberately renders a thin `IOSBoardModel` rather than the shared macOS `BoardModel` (whose connect path is macOS-entangled and only becomes portable across the M-series). If F2 in fact ships a fully iOS-drivable `BoardModel` with injectable connection resolution, M1 should swap `IOSBoardModel` out for it — flagged here so the M1 planner picks it up.
