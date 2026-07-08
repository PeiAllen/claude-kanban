# PR F2 — Platform protocols + move `BoardModel`/`Theme` into shared code

> **Impl branch:** `mobile/f2-platform-protocols` · **Stacks on:** F1 (`mobile/f1-core-split`) · **Wave:** 1
> **Deliverable of this card:** this plan. Do **not** implement here.
> **Roadmap:** `notes/plans/2026-07-04-mobile-orchestra-implementation-forest.md` §PR F2 ·
> `…-PR-TREE.md` · Design: `notes/designs/phone-client/02-contract.md` §Platform protocols.

---

## 0. TL;DR / what this PR actually is

Establish the **platform seam** so the board's view-model + design tokens can be shared by the
future iOS target, while the macOS app stays byte-for-byte behavior-identical.

Three moving parts:

1. **New shared SwiftUI target `OrchestraUI`** (macOS 14 + iOS 17), depending on F1's `OrchestraKit`.
   *Not* `OrchestraKit` itself — see §2, this is forced by the Linux daemon build.
2. **Move `Theme.swift` (pure SwiftUI) unchanged** and **`BoardModel.swift`** into `OrchestraUI`.
3. **Define the four platform protocols** (`Clipboard`, `SystemOpener`, `WindowConfig`,
   `TerminalHost`), provide **AppKit-backed macOS impls** in `App/`, and route `BoardModel`'s
   AppKit call sites through injected protocols so `BoardModel` compiles for iOS with **zero AppKit**.

### ⚠️ Scope reconciliation — the audit found more than "4 AppKit call sites"

The forest/BUILD-VS-NEW facts say *"replace `BoardModel`'s 4 AppKit couplings with protocol calls."*
Those 4 **direct-AppKit** sites are real and exact (`:619-620`, `:633`, `:656`). **But a file
*move* into an iOS-buildable target requires every symbol in the file to resolve there**, and
`BoardModel` also owns **host/daemon machinery that lives in the macOS `App/` target or in
daemon-only `OrchestraCore`** and is *not* AppKit-API but is *just as unportable*:

| # | Site (line) | Symbol | Home | Portable via |
|---|---|---|---|---|
| 1 | `:619-620` | `NSPasteboard.general` (copy) | AppKit | **`Clipboard` protocol** |
| 2 | `:633` | `NSApp.sendAction(showSettingsWindow:)` | AppKit | **`SystemOpener` protocol** |
| 3 | `:656` | `NSApp.keyWindow?.makeFirstResponder(nil)` | AppKit | **`WindowConfig` protocol** |
| 4 | `:97` + `:126` `:183-214` | `ConnectionController` (SSHMaster/tunnel/socket resolve) | `App/` | **`#if os(macOS)` fence** (iOS connect = F3) |
| 5 | `:103` + `:108` `:175` `:343` `:346` | `AgentNotifier` (NSApp / UserNotifications) | `App/` | **`#if os(macOS)` fence** (iOS notify = N1) |
| 6 | `:194` `:234` `:243-244` | `DaemonLifecycle` + `bundledDaemonBinary()`/`Bundle.main` | OrchestraCore (daemon-only) + `App/` | **`#if os(macOS)` fence** (iOS has no local daemon) |
| 7 | `:126` `:128` | `terminalHost`/`terminalTmuxSocket` → `AgentTerminalView.TerminalHost` enum | `App/` | **move to App-side `extension BoardModel`** |
| 8 | enums used by 1/2 signatures | `CopyTarget`, `GoTarget`, `InspectorMode` | `App/Views/InspectorView.swift` | **move to `OrchestraUI`** (pure enums) |

**Consequence:** F2's real work is *"move `BoardModel`, protocol-inject the 3 cross-platform UI ops,
`#if os(macOS)`-fence the host/daemon machinery that F3/T1/N1 will re-implement for iOS, and relocate
the terminal accessors + helper enums."* This is still small and desktop-identical, but it is **not**
a three-line swap. The plan below is written to that reality; every fenced block is behavior that a
*later* PR (F3 connection, T1 terminal, N1 notifications) fills on the iOS side.

---

## 1. Context established by the code audit (2026-07-04, this worktree)

- `App/Theme.swift` — **pure SwiftUI** (`import SwiftUI` only). Contains `Color` helpers, `Accent`,
  `Density`, `SemColor`, `Theme` (color tokens + `statusColor`/`statusLabel`), `F` (fonts),
  `.surface`/`.hairline` view modifiers, **and the `ThemeKey`/`\.theme` Environment plumbing**
  (`:150-160`). Clean move; nothing to change.
- `App/BoardModel.swift` — `@MainActor final class BoardModel: ObservableObject`, `imports SwiftUI +
  AppKit + OrchestraCore`. 821 lines. Its client-safe collaborators (`ControlClient`, `Config`,
  `Connection`, `ConnectionStore`, `Task`/`Column`/`AgentModel`/`AgentInfo`, `BoardNavigator`,
  `TaskRef`) become **`OrchestraKit`** symbols after F1. Its unportable collaborators are the 8 rows
  above.
- `openInZed`/`openNotes` are **daemon RPCs** (`client.call("openInZed" / "openNotes")`, `:513`
  `:522`) — *not* local `NSWorkspace` — so `SystemOpener.open(path:)` is **not** needed by
  `BoardModel` in F2 (kept in the protocol for the contract + future M-cards, macOS impl trivial).
- `App/project.yml` globs `sources: [{ path: ., excludes: […] }]` — moving a file **out** of `App/`
  removes it from the target automatically; we only add the `OrchestraUI` product dependency.
- `App/OrchestraApp.swift`: `@StateObject private var model = BoardModel()` (`:7`); Environment is
  already used for `\.theme` (`:21`) and there is an existing `WindowConfigurator: NSViewRepresentable`
  (`:698`) — the natural home for the macOS `WindowConfig` impl's window-chrome half.
- Existing scripts to lean on: `scripts/build-app.sh`, `scripts/typecheck-app.sh`,
  `scripts/orch-ui-shot.sh` (isolated screenshot), `scripts/orch-test.sh` (isolated daemon),
  `scripts/build-linux-daemon.sh`.

---

## 2. Target decision — **new `OrchestraUI` target, NOT `OrchestraKit`**

The forest leaves this open (*"or a new `OrchestraUI` shared SwiftUI target if `BoardModel` needs
SwiftUI — decide in the per-PR plan"*). **Decision: create `OrchestraUI`.** Rationale is a hard
constraint, not a preference:

- `BoardModel` (`ObservableObject`/`@Published`) and `Theme` (`Color`, `EnvironmentKey`) require
  `import SwiftUI`.
- Per F1, **`orchestrad` depends on `OrchestraKit`**, and `scripts/build-linux-daemon.sh`
  cross-compiles `orchestrad` for Linux. SwiftPM compiles `OrchestraKit`'s sources on Linux → **it
  must stay SwiftUI-free.** Putting SwiftUI code in `OrchestraKit` would break the Linux daemon build
  (a global constraint + F1 acceptance).
- Therefore SwiftUI-dependent shared code goes in a **separate target linked only by the macOS app +
  the future iOS app**, never by `orchestrad`/CLI/MCP → never compiled on Linux.

**`OrchestraUI` shape:**
```
.target(
  name: "OrchestraUI",
  dependencies: ["OrchestraKit"]           // client-safe core only
)                                          // no platforms{} exclusion needed — it's simply
                                           // never a dependency of a Linux target
// product: .library(name: "OrchestraUI", targets: ["OrchestraUI"])
```
Add `platforms: [.macOS(.v14), .iOS(.v17)]` at the package level already exists via F1's bump;
`OrchestraUI` inherits it. `OrchestraCore`, `orchestrad`, `orchestra`, `orchestra-mcp` **do not**
depend on `OrchestraUI`.

**F1 cross-checks (assumptions this plan depends on — verify at impl-time against merged F1):**
- `OrchestraKit` exists, is `.macOS(.v14) + .iOS(.v17)`, SwiftUI-free, and exports: `ControlClient`,
  `Config`, `Connection`, `ConnectionStore`, `RemoteCommands`, model types (`Task`, `Column`,
  `AgentModel`, `AgentInfo`, `CardOrigin`, `DeadReason`, `TmuxTarget`, `ExecResult`, `waitReason`).
- **`BoardNavigator` (`Sources/OrchestraCore/Keyboard/BoardNavigator.swift`) and `TaskRef`
  (`…/Keyboard/KeyChord.swift`) are in `OrchestraKit`.** They are pure, client-safe, and
  `BoardModel` calls them heavily (`:545` `:553` `:556` `:561` `:627-629` `:668-670`). If F1 left
  them in `OrchestraCore`, **F2 Layer 0 must move them to `OrchestraKit`** (contingency step
  included below).

---

## 3. The four platform protocols (final signatures)

Defined in `Sources/OrchestraUI/PlatformProtocols.swift`. All are tiny; each gets an
`EnvironmentKey` (contract: *"injected via SwiftUI Environment"*) **and** a no-op default so
previews/tests/iOS-before-F3 compile.

```swift
import SwiftUI
import OrchestraKit          // for TmuxTarget

/// Pasteboard. macOS = NSPasteboard, iOS = UIPasteboard.
public protocol Clipboard {
    func copy(_ text: String)
}

/// Open a host affordance. macOS = NSApp/NSWorkspace, iOS = no-op / in-app navigation.
public protocol SystemOpener {
    func openSettings()                 // BoardModel.goTo(.settings)  [F2-required]
    func open(path: String)             // reserved for later (Zed/Finder is a daemon RPC today) — macOS: NSWorkspace; iOS: no-op
}

/// Window / input-focus chrome. macOS = keyWindow first-responder + titlebar config, iOS = no-op.
public protocol WindowConfig {
    func resignInputFocus()             // BoardModel.closeFrontmost() step-out-of-terminal  [F2-required]
    // window-chrome configuration (the existing WindowConfigurator) stays macOS-only; not needed by shared BoardModel.
}

/// Terminal attach seam. macOS = local/remote tmux via SwiftTerm (AppKit); iOS = SSH-PTY (SwiftTerm-iOS, T1).
/// Returns a type-erased view so the existential is storable in Environment.
public protocol TerminalHost {
    func attach(target: TmuxTarget) -> AnyView
}
```

**Injection nuance (important — spell this out for the impl card):** `@Environment` is readable only
inside `View`s. **`BoardModel` is an `ObservableObject`, not a `View`, so it cannot read
`@Environment`.** The three UI-op protocols that `BoardModel` itself calls are therefore **injected
into the model** (constructor), while the Environment keys exist for *views* (and for `TerminalHost`,
which is produced by a view). Concretely:

```swift
// OrchestraUI
public struct PlatformUI {                     // the UI ops BoardModel calls directly
    public let clipboard: Clipboard
    public let opener: SystemOpener
    public let window: WindowConfig
    public init(clipboard: Clipboard, opener: SystemOpener, window: WindowConfig) { … }
    public static let noop = PlatformUI(clipboard: NoopClipboard(), opener: NoopOpener(), window: NoopWindow())
}

// BoardModel
public let platform: PlatformUI
public init(platform: PlatformUI = .noop) { self.platform = platform; … }
```

- `App/OrchestraApp.swift`: `@StateObject private var model = BoardModel(platform: MacPlatform.ui)`
  and also `.environment(\.clipboard, …).environment(\.systemOpener, …).environment(\.windowConfig,
  …).environment(\.terminalHost, MacTerminalHost(...))` so views (now and in F3) can read them too.
- Tests: `BoardModel(platform: PlatformUI(clipboard: SpyClipboard(), …))`.

macOS impls (`App/MacPlatform.swift`):
```swift
struct AppKitClipboard: Clipboard { func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) } }
struct AppKitSystemOpener: SystemOpener {
    func openSettings() { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
    func open(path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
}
struct AppKitWindowConfig: WindowConfig { func resignInputFocus() { NSApp.keyWindow?.makeFirstResponder(nil) } }
struct MacTerminalHost: TerminalHost { func attach(target: TmuxTarget) -> AnyView { AnyView(AgentTerminalView(...)) } }
enum MacPlatform { static let ui = PlatformUI(clipboard: AppKitClipboard(), opener: AppKitSystemOpener(), window: AppKitWindowConfig()) }
```
> `MacTerminalHost` is **defined and injected** so F3's iOS placeholder + T1 have the seam, but the
> existing desktop terminal call sites (`InspectorView:349`, `ShellTabsView:33`) are **left unchanged
> in F2** — rewiring them through the protocol is T1's job and would be desktop-regression surface
> here. See §5 Layer 2.

---

## 4. Handling the fenced host/daemon machinery (rows 4–7)

These are macOS/daemon-host concerns whose iOS counterparts are built in **later** PRs. F2's job is
only to let the shared file compile on iOS without them; it does **not** build the iOS versions.

- **Row 7 — terminal accessors → App-side extension.** `terminalHost`/`terminalTmuxSocket` are
  *computed* → move them out of the shared file into `App/BoardModelPlatform.swift`:
  `#if os(macOS) extension BoardModel { var terminalHost: AgentTerminalView.TerminalHost {…}; var
  terminalTmuxSocket: String {…} } #endif`. Cleanest: shared file then has **zero** terminal
  references, desktop views keep calling `model.terminalHost` unchanged.
- **Rows 4/5/6 — stored collaborators + lifecycle → `#if os(macOS)` inside the shared file.**
  `connectionController`, `notifier` are stored `let`s (can't be added by an extension) and are woven
  through `init`, `bootstrap`, `activate`, `deactivate`, `ensureDaemonAndStart`, and the
  event-processing notify sites. Fence them:
  - `#if os(macOS)` around: the two stored props; `notifier.onSelect`/`requestAuthorization`/`notify`
    calls; the `ConnectionController` calls in `activate`/`deactivate`; the `DaemonLifecycle` +
    `bundledDaemonBinary()` blocks.
  - Provide a minimal `#if os(iOS)` sibling: an `activate(_:)` that resolves the transport socket
    **without** SSHMaster/DaemonLifecycle (a stub that F3 fleshes out — F2 only needs it to *compile*;
    F3 supplies the real iOS connection path). Document with `// F3: iOS connection path`.
  - Rationale over introducing more protocols: keeps F2 to the **named four** protocols (contract),
    keeps desktop code **literally unchanged** inside the fences (zero regression), and the iOS side
    is genuinely a *different* PR's deliverable (F3/N1/T1), not something to design speculatively now.
  - *Alternative considered & rejected for F2:* extracting a full `PlatformHost` protocol bundle
    (connection-activator + notifier + daemon-host) with macOS+iOS impls. Cleaner long-term, but it
    (a) exceeds F2's named-4 scope, (b) forces designing the iOS connection contract before F3, and
    (c) adds desktop-refactor regression surface. Deferred; noted as a possible F3 refactor.
- **Row 8 — helper enums.** Move `CopyTarget`, `GoTarget`, `InspectorMode` from
  `App/Views/InspectorView.swift` into `OrchestraUI` (they're pure enums in `BoardModel`'s public
  API; `InspectorView` keeps using them via `import OrchestraUI`).

---

## 5. Layered TDD implementation plan

Each layer is an independently-buildable, independently-committable step (**small commits** global
constraint). "Green" = `swift build` + `swift test` offline-green **and** the desktop app builds
(`scripts/build-app.sh`) unless noted. TDD ordering: for behavior-bearing layers we write the failing
test (fake-platform spy) **before** the production edit.

### Layer 0 — `OrchestraUI` target scaffold + F1 cross-check (no behavior)
**Changes**
- `Package.swift`: add `OrchestraUI` target (`dependencies: ["OrchestraKit"]`) + its
  `.library` product. Add an `OrchestraUITests` test target (`dependencies: ["OrchestraUI"]`).
- `App/project.yml`: add `- package: OrchestraCore` `product: OrchestraUI` to the app target's deps
  (the SwiftPM package at `..` already vends all products).
- **Contingency (only if F1 didn't):** move `BoardNavigator.swift` + `KeyChord.swift`
  (`TaskRef`) from `OrchestraCore/Keyboard/` to `OrchestraKit/Keyboard/`, fix imports.
- Add one trivial placeholder file so the target compiles (removed in Layer 1).

**Tests / gate**
- `swift build` (new empty-ish target links), `swift test` unchanged-green,
  `scripts/build-linux-daemon.sh` still cross-compiles (proves `OrchestraUI` isn't pulled into the
  Linux graph), `scripts/build-app.sh` builds with the new product dep.

**Commit:** `build(f2): add OrchestraUI shared SwiftUI target (deps OrchestraKit)`

### Layer 1 — Move `Theme.swift` unchanged
**Changes**
- Move `App/Theme.swift` → `Sources/OrchestraUI/Theme.swift`, **content byte-identical** (mark
  `Theme`, `Accent`, `Density`, `SemColor`, `F`, the `\.theme` Environment, and the `Color`/`View`
  helpers `public` as needed for cross-module use).
- `App/*` that referenced these now `import OrchestraUI` (they already `import`ed nothing extra —
  same module before; add the import where the compiler flags it).

**Tests / gate**
- `OrchestraUITests`: a token-stability test (e.g. `Theme(scheme:.dark, accent:.blue).winBg` equals
  the known value; `statusColor("running") == green`) so the move is provably lossless.
- Desktop: `scripts/build-app.sh` green; `scripts/orch-ui-shot.sh` screenshot shows unchanged theme.

**Commit:** `refactor(f2): move Theme into OrchestraUI (pure SwiftUI, unchanged)`

### Layer 2 — Define the four protocols + macOS impls + Environment wiring (no `BoardModel` change yet)
**Changes**
- `Sources/OrchestraUI/PlatformProtocols.swift`: the 4 protocols (§3) + `PlatformUI` struct +
  `Noop*` defaults + `EnvironmentKey`s + `EnvironmentValues` accessors (`\.clipboard`,
  `\.systemOpener`, `\.windowConfig`, `\.terminalHost`).
- `App/MacPlatform.swift`: `AppKitClipboard`, `AppKitSystemOpener`, `AppKitWindowConfig`,
  `MacTerminalHost`, `MacPlatform.ui`.
- `App/OrchestraApp.swift`: inject the four impls into the Environment at the two Scene roots
  (`Window` + `Settings`), mirroring the existing `.environment(\.theme, …)` lines. **`BoardModel`
  init unchanged this layer** (still `BoardModel()` with `.noop`) so this layer is pure addition.

**Tests / gate (TDD spies)**
- `OrchestraUITests`: `SpyClipboard`/`SpyOpener`/`SpyWindow` conforming to the protocols; assert the
  no-op defaults are inert and that a `PlatformUI` round-trips its members. (Consumer wiring is
  Layer 3, so this layer tests the seam in isolation.)
- Desktop build green; no behavior change (nothing consumes the injected impls yet).

**Commit:** `feat(f2): platform protocols (Clipboard/SystemOpener/WindowConfig/TerminalHost) + macOS impls`

### Layer 3 — Move `BoardModel`, route the 3 UI ops through `PlatformUI`, fence host machinery
**Changes**
- Move `App/BoardModel.swift` → `Sources/OrchestraUI/BoardModel.swift`; change `import OrchestraCore`
  → `import OrchestraKit`; **remove `import AppKit`**.
- Move `CopyTarget`/`GoTarget`/`InspectorMode` enums into `OrchestraUI` (new
  `Sources/OrchestraUI/BoardModelTypes.swift` or inline).
- Add `let platform: PlatformUI` + `init(platform: PlatformUI = .noop)`.
- Rewrite the 3 UI-op sites:
  - `copySelected` `:619-620` → `platform.clipboard.copy(s)`.
  - `goTo(.settings)` `:633` → `platform.opener.openSettings()`.
  - `closeFrontmost` `:656` → `platform.window.resignInputFocus()`.
- Move `terminalHost`/`terminalTmuxSocket` → `App/BoardModelPlatform.swift` (`#if os(macOS)`
  `extension BoardModel`).
- `#if os(macOS)`-fence `connectionController`, `notifier`, their lifecycle uses, and the
  `DaemonLifecycle`/`bundledDaemonBinary` blocks; add the minimal `#if os(iOS)` `activate` stub
  (§4). Keep every fenced macOS line **verbatim** (behavior-identical).
- `App/OrchestraApp.swift`: `BoardModel(platform: MacPlatform.ui)`.
- Any `App/` view referencing `CopyTarget`/`GoTarget`/`InspectorMode`/`BoardModel` adds
  `import OrchestraUI`.

**Tests / gate (TDD — write first)**
- `OrchestraUITests` with **`FakePlatform`** (the acceptance's "fake-platform test double"):
  - `copySelected(.path)` → spy clipboard received `selected.cwd`; `.chatLink` → `ref()`; `.tmux` →
    `"<session>:agent"`.
  - `goTo(.settings)` → spy opener `openSettings()` called exactly once (and no navigation side
    effects); the other `goTo` cases still mutate `selectedId` with no platform call.
  - `closeFrontmost` in a terminal focus zone → spy window `resignInputFocus()` called; peel-order
    precedence (confirm dialog → hint → help → … → resignInputFocus) preserved.
  - These construct `BoardModel(platform: FakePlatform(...))` with a seeded `tasks`/`selectedId`; no
    daemon needed (the fenced connection machinery is macOS-only and untouched by these paths).
- `swift test` green; `scripts/build-app.sh` green.

**Commit:** `refactor(f2): move BoardModel into OrchestraUI; AppKit sites via injected platform protocols`

### Layer 4 — iOS-compile proof + desktop parity verification
**Changes**
- `scripts/typecheck-ios-ui.sh` (mirror F1's iOS typecheck): compile `OrchestraUI` for
  `arm64-apple-ios17.0` against the iOS SDK and assert **zero** `AppKit`/`NSApp`/`NSPasteboard`
  references reach the compiler (the `#if os(macOS)` fences drop out). Command shape:
  `swift build --target OrchestraUI -Xswiftc -sdk -Xswiftc "$(xcrun --sdk iphoneos --show-sdk-path)"
  -Xswiftc -target -Xswiftc arm64-apple-ios17.0` (or `xcodebuild`-based if SwiftPM cross-typecheck is
  flaky — match whatever F1 shipped).

**Verification (evidence before "done")**
- **iOS compile:** `scripts/typecheck-ios-ui.sh` exits 0.
- **Desktop parity (the 3 behaviors):** build via `scripts/build-app.sh`, launch an **isolated**
  instance (`scripts/orch-test.sh` daemon + `scripts/orch-ui-shot.sh`), and confirm behavior-identical:
  1. **Clipboard copy** — `y c`/`y p`/`y t` copy the same strings (assert pasteboard contents in the
     isolated run).
  2. **Open-settings** — `g s` opens the Settings window.
  3. **Focus-clear** — `⌘W`/Esc from a focused terminal steps back to the board (first responder
     cleared). Do **not** drive the user's live app (memory: isolated instance only).
- **No regressions:** `swift test`, `scripts/build-linux-daemon.sh`, `scripts/build-app.sh` all green.

**Commit:** `test(f2): iOS-compile check for OrchestraUI + desktop parity verification`

### Layer 5 — Cross-layer review/refine pass
Per the layered-plan two-pass habit: re-read the diff top-to-bottom for (a) any lingering AppKit in
the shared target, (b) fence correctness (no macOS-only symbol leaking outside `#if os(macOS)`),
(c) `public` surface minimalism, (d) that no fenced block silently changed desktop behavior. Squash
fixups into the relevant commit.

---

## 6. Acceptance criteria → where satisfied

| Forest acceptance | Satisfied by |
|---|---|
| Desktop builds + behaves identically (clipboard copy, open-settings, focus-clear) | Layer 3 (verbatim AppKit inside impls) + Layer 4 parity verification |
| Shared `BoardModel` + `Theme` compile for iOS (no AppKit) | Layer 1 (Theme) + Layer 3 (fences) + Layer 4 `typecheck-ios-ui.sh` |
| `swift test` green with a fake-platform test double | Layer 3 `FakePlatform` tests |
| No desktop / Linux regression; both Claude+Codex; minimal wire changes; small commits | Layer 0 Linux gate + per-layer builds; `BoardModel` is agent-agnostic (no `if agent==` touched); 5 small commits |

---

## 7. Risks & mitigations
- **F1 boundary drift** (BoardNavigator/TaskRef not in OrchestraKit, or a client-safe symbol left in
  OrchestraCore) → Layer 0 cross-check + contingency move; coordinate with F1 card before impl.
- **`#if os(macOS)` fences balloon** → keep fenced blocks contiguous; if they sprawl, that's a signal
  the `PlatformHost` extraction (§4 rejected-alternative) is worth pulling forward — flag to
  orchestrator rather than fencing line-by-line in hot code.
- **`TerminalHost` existential + `AnyView`** minor perf/typing cost → acceptable for F2; T1 may
  refine to a generic if needed.
- **`Settings` scene + `Window` scene** both need the Environment injection → inject at both roots
  (Layer 2) or desktop settings-window views lose the impls.

---

## 8. Interface F3 (and later) consumes — the handoff
- **Shared target `OrchestraUI`** (macOS+iOS) exporting `BoardModel`, `Theme`, `CopyTarget`/
  `GoTarget`/`InspectorMode`, and the 4 protocols + `PlatformUI` + Environment keys.
- **`BoardModel(platform: PlatformUI)`** — F3's iOS app passes `PlatformUI(clipboard:
  UIKitClipboard(), opener: NoopOpener(), window: NoopWindow())` and injects an iOS `TerminalHost`
  placeholder into the Environment.
- **The `#if os(iOS)` seams** in `BoardModel` (`activate` connection stub) + the absent
  `connectionController`/`notifier`/`DaemonLifecycle` — F3 supplies the iOS connection path (reuse
  `ConnectionStore` + a `ControlClient` over the dev transport), N1 supplies notifications.
- **`TerminalHost.attach(target:) -> AnyView`** — T1's iOS SSH-PTY impl; F3 ships a placeholder.

---

## 9. Commit sequence (small, stacked)
1. `build(f2): add OrchestraUI shared SwiftUI target (deps OrchestraKit)` — Layer 0
2. `refactor(f2): move Theme into OrchestraUI (pure SwiftUI, unchanged)` — Layer 1
3. `feat(f2): platform protocols + macOS impls` — Layer 2
4. `refactor(f2): move BoardModel into OrchestraUI; AppKit sites via injected protocols` — Layer 3
5. `test(f2): iOS-compile check + desktop parity verification` — Layer 4 (+ Layer 5 fixups squashed)
