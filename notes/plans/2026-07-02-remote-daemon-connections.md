# Remote-daemon connections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the macOS Orchestra board UI locally against a remote Linux `orchestrad` over an app-managed SSH tunnel, building the reusable client spine (Connection + Transport + reconnect) once in the shared core so the planned phone client inherits it.

**Architecture:** Four workstreams on one spine. **A** ports the daemon/CLI/core off Darwin-only APIs so `orchestrad`/`orchestra`/`orchestra-mcp` compile and run on Linux (this unblocks the already-merged `scripts/build-linux-daemon.sh` / `deploy-linux-daemon.sh`). **B** extracts a `Transport` protocol under `ControlClient` and adds reconnect + re-subscribe with backoff and an observable `ConnectionState`. **C** adds a shared `Connection` value + a `ConnectionStore` + a macOS Settings "Connections" pane, and rewires `BoardModel` to target the active connection. **D** spawns/supervises a multiplexed master `ssh` and points the transport + SwiftTerm terminals at the forwarded socket / remote tmux.

**Tech Stack:** Swift 6 / SwiftPM (`OrchestraCore` library + `orchestrad`/`orchestra`/`orchestra-mcp` executables), Swift Testing (`import Testing`), AppKit/SwiftUI + SwiftTerm for the app (built separately via `App/project.yml` + `scripts/build-app.sh`), AF_UNIX sockets + NDJSON JSON-RPC, OpenSSH connection multiplexing.

## Global Constraints

- **The wire protocol is unchanged.** No new daemon network surface (no TCP/WebSocket listener). Reachability is SSH forwarding only. Every change is either the Linux *build* of the daemon or the *client* side.
- **The macOS app must build the whole way through.** `App/` stays macOS-only (AppKit/SwiftTerm). Verify with `scripts/build-app.sh` at the end of every workstream that touches `App/`.
- **`OrchestraCore` and the three executables (`orchestrad`, `orchestra`, `orchestra-mcp`) must compile on BOTH macOS and Linux.** Any Darwin-only symbol must be behind `#if canImport(Darwin)` / `#if os(macOS)` with a Glibc/Linux path.
- **Cross-platform idiom:** `#if canImport(Glibc) import Glibc #elseif canImport(Darwin) import Darwin #endif`. Prefer module-qualified POSIX shims (see Task A1) over bare calls where the enclosing type shadows a C symbol.
- **UDS socket path cap ~104 bytes** (`sun_path`). Every socket/control path the app creates for a tunnel must be validated under that cap.
- **Tests run unsandboxed and use `/tmp/orch-<uuid8>.sock`** short paths (see `ControlRoundTripTests.sock()`); follow that convention for any new socket test.
- **No new third-party dependencies.** Core/daemon/CLI stay dependency-free; only `orchestra-mcp` pulls the MCP SDK (unchanged).
- **SSH is key-auth only** (`BatchMode=yes`); no password/interactive auth inside the app. Documented prerequisite.

---

## File Structure

**Workstream A — Linux port (modify):**
- `Sources/OrchestraCore/Control/UDSSocket.swift` — Glibc fallback + POSIX shims; `MSG_NOSIGNAL` on Linux, `SO_NOSIGPIPE` gated to Darwin.
- `Sources/OrchestraCore/Config.swift` — `dataDir` XDG on Linux; extract a pure `dataDir(os:home:env:)` helper for tests.
- `Sources/OrchestraCore/Control/DaemonLifecycle.swift` — launchd lifecycle gated `#if os(macOS)`; fd close ported.
- `Sources/OrchestraCore/Control/ControlClient.swift`, `Sources/OrchestraCore/Control/ControlServer.swift` — Glibc import + `close` ported (further rewritten in B).
- `Sources/OrchestraCore/PathResolver.swift` — Glibc import + `realpath` ported.
- `Sources/orchestra/ReportHelper.swift` — Glibc import + stdin/stdout `read`/`write` ported.
- `Sources/OrchestraCore/Launcher.swift` — `open -a Zed` / Obsidian guarded to macOS.
- `Package.swift` — verify Linux build; adjust only if SwiftPM rejects the platform.

**Workstream B — Transport seam + reconnect (create/modify):**
- `Sources/OrchestraCore/Control/Transport.swift` (create) — `Transport` protocol, `ConnectionState` enum, `UDSTransport`.
- `Sources/OrchestraCore/Control/ControlClient.swift` (modify) — own a `Transport`; reconnect loop + backoff + re-subscribe + `onState`.
- `Tests/OrchestraCoreTests/TransportReconnectTests.swift` (create).

**Workstream C — Connection model + settings UI (create/modify):**
- `Sources/OrchestraCore/Connection.swift` (create) — `Connection` value + built-in `.local`.
- `Sources/OrchestraCore/ConnectionStore.swift` (create) — persisted list + active id (UserDefaults-backed, injectable).
- `Tests/OrchestraCoreTests/ConnectionStoreTests.swift` (create).
- `App/ConnectionController.swift` (create) — app-side activation → local socket path + state, `@MainActor ObservableObject`.
- `App/Views/ConnectionsSettingsView.swift` (create) — the Connections pane.
- `App/Views/SettingsView.swift` (modify) — rename existing body to a "General" tab helper if needed.
- `App/OrchestraApp.swift` (modify) — Settings scene becomes a `TabView` (General + Connections).
- `App/BoardModel.swift` (modify) — hold a `ConnectionStore` + `ConnectionController`; build the client from the active connection; bind status.

**Workstream D — SSH tunnel + remote terminals (create/modify):**
- `Sources/OrchestraCore/RemoteCommands.swift` (create) — pure argv builders (`sshMasterArgs`, `sshExitArgs`, `remoteTmuxAttachCommand`) + short-path helper; unit-tested.
- `Tests/OrchestraCoreTests/RemoteCommandsTests.swift` (create).
- `App/SSHMaster.swift` (create) — spawn/supervise the master ssh Process; pre-spawn cleanup; bounded wait for the local socket; teardown.
- `App/ConnectionController.swift` (modify) — `.remote` branch spins the master, returns the forwarded local socket path, wires unexpected-exit → reconnect.
- `App/Views/AgentTerminalView.swift` (modify) — accept a `TerminalHost` (local vs remote-over-control-socket); build the child command accordingly.
- `App/Views/InspectorView.swift`, `App/Views/ShellTabsView.swift` (modify) — pass the active connection's terminal host into `AgentTerminalView`.

---

# WORKSTREAM A — Linux daemon port

**Definition of done:** `swift build --swift-sdk x86_64-swift-linux-musl` (or a native Linux `swift build`) succeeds for `orchestrad`, `orchestra`, `orchestra-mcp`; the macOS build + full test suite stay green. This makes the merged deploy scripts produce a working binary.

> **Verification setup (once, before Task A7):** no musl SDK is installed in this environment (`swift sdk list` errors / empty) and there is no Docker or Linux box. Task A7 installs the Static Linux SDK matching the host toolchain (`swift --version` → Apple Swift 6.3.x) and cross-compiles. If a matching static SDK is unavailable for the exact toolchain, fall back to a native `swift build` on any Linux box (or container) with Swift installed — the code changes are identical; only the verification vehicle differs. Surface this choice to the user if the SDK install fails.

---

### Task A1: Port `UDSSocket.swift` off Darwin-only socket APIs

**Files:**
- Modify: `Sources/OrchestraCore/Control/UDSSocket.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: unchanged public surface (`UDS.listen/connect/accept/writeAll/read`, `LineReader`). Only the platform implementation changes.

The enum `UDS` defines static methods named `listen`, `connect`, `accept`, `read` — these shadow the C globals inside the type, which is why the current code writes `Darwin.listen` etc. At **file scope** (outside the enum) the C globals are NOT shadowed, so define module-neutral POSIX shims at file scope and call them from inside `UDS`. `SO_NOSIGPIPE` is BSD-only; Linux has no per-socket SIGPIPE suppression, so the guard moves to a per-`send` `MSG_NOSIGNAL` flag.

- [ ] **Step 1: Replace the import + add file-scope POSIX shims**

Replace the top of the file (lines 1–4, the `import Foundation` + `#if canImport(Darwin) import Darwin #endif`) with:

```swift
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Module-neutral POSIX shims. Defined at file scope, where the `UDS` enum's own static
// `listen`/`connect`/`accept`/`read` methods do NOT shadow the C globals, so one set of calls works on
// Darwin and Glibc alike. `posixSend` carries the SIGPIPE guard: Darwin suppresses it per-socket via
// SO_NOSIGPIPE (set in `suppressSIGPIPE`), while Linux passes MSG_NOSIGNAL on every send.
@inline(__always) private func posixListen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
@inline(__always) private func posixConnect(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 { connect(fd, a, l) }
@inline(__always) private func posixAccept(_ fd: Int32) -> Int32 { accept(fd, nil, nil) }
@inline(__always) private func posixRead(_ fd: Int32, _ b: UnsafeMutableRawPointer, _ n: Int) -> Int { read(fd, b, n) }
@inline(__always) private func posixClose(_ fd: Int32) -> Int32 { close(fd) }
#if canImport(Glibc)
@inline(__always) private func posixSend(_ fd: Int32, _ b: UnsafeRawPointer, _ n: Int) -> Int { send(fd, b, n, Int32(MSG_NOSIGNAL)) }
#else
@inline(__always) private func posixSend(_ fd: Int32, _ b: UnsafeRawPointer, _ n: Int) -> Int { write(fd, b, n) }
#endif
```

- [ ] **Step 2: Route the socket calls through the shims**

In `UDS.listen`: change `Darwin.listen(fd, backlog)` → `posixListen(fd, backlog)`; both `close(fd)` error paths → `posixClose(fd)`.
In `UDS.connect`: change `Darwin.connect(fd, $0, len)` → `posixConnect(fd, $0, len)`; `close(fd)` → `posixClose(fd)`.
In `UDS.accept`: change `Darwin.accept(serverFd, nil, nil)` → `posixAccept(serverFd)`.
In `UDS.writeAll`: change `Darwin.write(fd, base + off, total - off)` → `posixSend(fd, base + off, total - off)`.
In `UDS.read`: change `Darwin.read($0.baseAddress, $0.count)` call `Darwin.read(fd, ...)` → `posixRead(fd, $0.baseAddress!, $0.count)` (guard the base address; `[UInt8]` buffer is non-empty so it is non-nil).

- [ ] **Step 3: Gate `SO_NOSIGPIPE` to Darwin**

Replace `suppressSIGPIPE` so the BSD socket option is macOS-only and the function is a documented no-op on Linux (the guard lives in `posixSend`'s `MSG_NOSIGNAL`):

```swift
    private static func suppressSIGPIPE(_ fd: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        // Linux has no per-socket SIGPIPE suppression; UDS.writeAll passes MSG_NOSIGNAL per send instead.
    }
```

- [ ] **Step 4: Verify macOS build + socket round-trip still pass**

Run: `swift build 2>&1 | tail -5 && swift test --filter ControlRoundTrip 2>&1 | tail -15`
Expected: build succeeds; `ControlRoundTripTests` all pass (the socket layer behaves identically on macOS).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Control/UDSSocket.swift
git commit -m "feat(core): port UDSSocket off Darwin-only APIs (Glibc + MSG_NOSIGNAL)"
```

---

### Task A2: XDG data dir on Linux (`Config.swift`)

**Files:**
- Modify: `Sources/OrchestraCore/Config.swift`
- Test: `Tests/OrchestraCoreTests/ConfigDataDirTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Config.dataDir` unchanged signature (`static var dataDir: String`); new pure helper `static func dataDir(isLinux: Bool, home: String, env: [String: String]) -> String` for testing both branches on either platform.

- [ ] **Step 1: Write the failing test**

Create `Tests/OrchestraCoreTests/ConfigDataDirTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Config.dataDir — platform-specific data directory")
struct ConfigDataDirTests {
    @Test("macOS uses ~/Library/Application Support/Orchestra")
    func macOS() {
        let d = Config.dataDir(isLinux: false, home: "/Users/x", env: [:])
        #expect(d == "/Users/x/Library/Application Support/Orchestra")
    }

    @Test("Linux uses $XDG_DATA_HOME/orchestra when set")
    func linuxXDG() {
        let d = Config.dataDir(isLinux: true, home: "/home/x", env: ["XDG_DATA_HOME": "/home/x/.xdg"])
        #expect(d == "/home/x/.xdg/orchestra")
    }

    @Test("Linux falls back to ~/.local/share/orchestra when XDG unset")
    func linuxDefault() {
        let d = Config.dataDir(isLinux: true, home: "/home/x", env: [:])
        #expect(d == "/home/x/.local/share/orchestra")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConfigDataDir 2>&1 | tail -15`
Expected: FAIL — `dataDir(isLinux:home:env:)` does not exist (compile error).

- [ ] **Step 3: Implement the pure helper + rewire `dataDir`**

In `Config.swift`, replace the single-line `public static var dataDir: String { "\(home)/Library/Application Support/Orchestra" }` with:

```swift
    public static var dataDir: String {
        #if os(Linux)
        return dataDir(isLinux: true, home: home, env: ProcessInfo.processInfo.environment)
        #else
        return dataDir(isLinux: false, home: home, env: ProcessInfo.processInfo.environment)
        #endif
    }

    /// Pure resolver for the data dir so both platform branches are unit-testable on either host.
    /// macOS: `~/Library/Application Support/Orchestra` (unchanged). Linux: `$XDG_DATA_HOME/orchestra`
    /// → `~/.local/share/orchestra`. `reposRoot`/`worktreesRoot`/`scratchRoot` stay $HOME-relative.
    static func dataDir(isLinux: Bool, home: String, env: [String: String]) -> String {
        if isLinux {
            let xdg = env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.local/share"
            return "\(xdg)/orchestra"
        }
        return "\(home)/Library/Application Support/Orchestra"
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ConfigDataDir 2>&1 | tail -15`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Config.swift Tests/OrchestraCoreTests/ConfigDataDirTests.swift
git commit -m "feat(core): XDG data dir on Linux; pure dataDir resolver + tests"
```

---

### Task A3: Gate launchd lifecycle to macOS (`DaemonLifecycle.swift`)

**Files:**
- Modify: `Sources/OrchestraCore/Control/DaemonLifecycle.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: unchanged public API (`install`, `load`, `isRunning`, `ensureRunning`, `uninstall`). On Linux `install`/`load`/`uninstall` become clean no-ops (daemon is systemd-managed); `isRunning`/`ensureRunning` still work (ping the socket).

- [ ] **Step 1: Fix the import + fd close**

Replace the bottom-of-file `#if canImport(Darwin) import Darwin #endif` and the `closeFd` helper. Change the import block at the bottom to:

```swift
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
```

Change `closeFd` so it never leaks the fd on Linux (the current `#if canImport(Darwin)` body is empty on Linux):

```swift
    private func closeFd(_ fd: Int32) { _ = close(fd) }
```

(`close` is not shadowed inside this struct, so the bare call resolves from Glibc/Darwin on each platform.)

- [ ] **Step 2: Gate the launchctl lifecycle to macOS**

Wrap the three launchd-touching methods so Linux gets an honest no-op (systemd owns lifecycle there). Replace `load()`, `install(...)`, and `uninstall()` bodies with `#if os(macOS)` guards:

```swift
    public func install(orchestradBin: String, logPath: String = Config.logPath) throws {
        #if os(macOS)
        let template: String
        if let p = Self.templatePath, let s = try? String(contentsOfFile: p, encoding: .utf8) {
            template = s
        } else {
            template = fallbackPlist
        }
        let rendered = template
            .replacingOccurrences(of: "__ORCHESTRAD_BIN__", with: orchestradBin)
            .replacingOccurrences(of: "__LOG__", with: logPath)
        let dir = (plistPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try rendered.write(toFile: plistPath, atomically: true, encoding: .utf8)
        load()
        #else
        // Linux: the daemon is started by systemd (see scripts/deploy-linux-daemon.sh). No launchd.
        throw OrchestraError.io("daemon auto-install is macOS-only; on Linux use systemctl --user")
        #endif
    }

    public func load() {
        #if os(macOS)
        let uid = getuid()
        _ = try? launchctl.run(["bootstrap", "gui/\(uid)", plistPath])
        _ = try? launchctl.run(["enable", "gui/\(uid)/\(Self.label)"])
        #endif
    }

    public func uninstall() {
        #if os(macOS)
        let uid = getuid()
        _ = try? launchctl.run(["bootout", "gui/\(uid)/\(Self.label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
        #endif
    }
```

Leave `isRunning()` and `ensureRunning()` unchanged — they only ping/act on the socket and are useful on both platforms (`ensureRunning` on Linux will simply throw from `install` if the socket isn't already up, which is correct: the app never auto-starts a remote daemon).

- [ ] **Step 3: Verify macOS build + lifecycle tests pass**

Run: `swift build 2>&1 | tail -5 && swift test --filter DaemonLifecycle 2>&1 | tail -15`
Expected: build succeeds; `DaemonLifecycleTests` pass unchanged (they run on macOS with the mocked launchctl).

- [ ] **Step 4: Commit**

```bash
git add Sources/OrchestraCore/Control/DaemonLifecycle.swift
git commit -m "feat(core): gate launchd lifecycle to macOS; port fd close for Linux"
```

---

### Task A4: Port `ControlClient` + `ControlServer` imports/close for Linux

**Files:**
- Modify: `Sources/OrchestraCore/Control/ControlClient.swift`
- Modify: `Sources/OrchestraCore/Control/ControlServer.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: unchanged public API. (ControlClient is refactored further in Workstream B; this task only makes it compile on Linux.)

- [ ] **Step 1: `ControlClient.swift` — import + close**

Replace the top `#if canImport(Darwin) import Darwin #endif` with the standard Glibc-first block:

```swift
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
```

Change `Darwin.close(fd)` (in `close()`) → `_ = close(fd)`.

- [ ] **Step 2: `ControlServer.swift` — import + close**

The file has a bottom-of-file `#if canImport(Darwin) import Darwin #endif`. Replace it with:

```swift
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
```

In `Connection.close()` change `Darwin.close(fd)` → `_ = close(fd)`. (`ControlServer.stop()` already uses bare `close(fd)` + `unlink(socketPath)` — both resolve on Linux via Glibc; leave them.)

- [ ] **Step 3: Verify macOS build + round-trip tests pass**

Run: `swift build 2>&1 | tail -5 && swift test --filter ControlRoundTrip 2>&1 | tail -15`
Expected: build succeeds; tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/OrchestraCore/Control/ControlClient.swift Sources/OrchestraCore/Control/ControlServer.swift
git commit -m "feat(core): Glibc import + portable fd close in Control client/server"
```

---

### Task A5: Port `PathResolver` + `ReportHelper` for Linux

**Files:**
- Modify: `Sources/OrchestraCore/PathResolver.swift`
- Modify: `Sources/orchestra/ReportHelper.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: unchanged public API.

- [ ] **Step 1: `PathResolver.swift` — import + realpath**

Replace the top `#if canImport(Darwin) import Darwin #endif` with the Glibc-first block (as in A4 Step 1). Change `Darwin.realpath(path, &buf)` → `realpath(path, &buf)` (bare; resolves from Glibc on Linux, Darwin on macOS — `PathResolver` has no static `realpath` to shadow it).

- [ ] **Step 2: `ReportHelper.swift` — import + stdio read/write**

Replace the top `#if canImport(Darwin) import Darwin #endif` with the Glibc-first block. Change `Darwin.write(1, base + off, buf.count - off)` → `write(1, base + off, buf.count - off)` and `Darwin.read(0, $0.baseAddress, $0.count)` → `read(0, $0.baseAddress, $0.count)` (bare; no shadowing in these free functions/enums). Note `ConfigStore.swift`'s `currentExecutablePath()` already gates `_NSGetExecutablePath` under `#if canImport(Darwin)`; on Linux it falls through to the `CommandLine.arguments` path — no change needed there. **Verify** by reading `ConfigStore.swift` that nothing outside a `canImport(Darwin)` gate references a Darwin-only symbol; if the executable-path helper needs a Linux path, use `/proc/self/exe` via `readlink` under `#if os(Linux)` (only if the Linux build flags it).

- [ ] **Step 3: Verify macOS build + path tests pass**

Run: `swift build 2>&1 | tail -5 && swift test --filter 'PathResolver|Report' 2>&1 | tail -20`
Expected: build succeeds; `PathResolverTests` + `ReportTests` pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/OrchestraCore/PathResolver.swift Sources/orchestra/ReportHelper.swift
git commit -m "feat(core): port PathResolver realpath + ReportHelper stdio for Linux"
```

---

### Task A6: Guard macOS-only launchers (`Launcher.swift`)

**Files:**
- Modify: `Sources/OrchestraCore/Launcher.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `openInZed`/`openNotes` throw a clear "macOS-only" error on Linux instead of shelling out to a nonexistent `open`.

These compile on Linux already (they are `Proc.run` string calls), so this is a correctness guard, not a build blocker — but it keeps the daemon honest when a remote Linux `orchestrad` receives an `openInZed`/`openNotes` RPC.

- [ ] **Step 1: Guard the two entry points**

At the start of `openInZed(_:)` and `openNotes(_:)`, add:

```swift
        #if !os(macOS)
        throw OrchestraError.io("opening in Zed/Obsidian is a macOS-only convenience")
        #endif
```

(Place after the existing `try resolver.assertAllowed(...)` line so the allowlist check still runs, or before it — either is fine; put it first to fail fast.)

- [ ] **Step 2: Verify macOS build + tests unaffected**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -20`
Expected: build succeeds; full suite green (these paths are macOS in tests, so the guard is inert).

- [ ] **Step 3: Commit**

```bash
git add Sources/OrchestraCore/Launcher.swift
git commit -m "feat(core): guard Zed/Obsidian launchers to macOS"
```

---

### Task A7: Linux cross-build green (DoD gate for A)

**Files:**
- Modify (only if required): `Package.swift`

**Interfaces:**
- Consumes: all A1–A6 changes.
- Produces: static Linux binaries via `scripts/build-linux-daemon.sh`.

- [ ] **Step 1: Install the Static Linux (musl) SDK matching the toolchain**

Determine the toolchain: `swift --version` (Apple Swift 6.3.x here). Install the matching swift.org Static Linux SDK. Fetch the exact URL + checksum for your version from <https://www.swift.org/download/> → "Static Linux SDK", then:

```bash
swift sdk install <static-linux-sdk-url> --checksum <sha256>
swift sdk list   # confirm a musl SDK id is listed
```

If no static SDK exists for the exact host toolchain, use the fallback: run a native `swift build -c release --product orchestrad` (+ `orchestra`, `orchestra-mcp`) on any Linux box/container with Swift installed. The source changes are identical; only report which vehicle was used.

- [ ] **Step 2: Cross-compile the three products**

Run: `scripts/build-linux-daemon.sh --arch x86_64 2>&1 | tail -30`
Expected: `orchestrad`, `orchestra`, `orchestra-mcp` all build; `dist/linux-x86_64/` populated with the binaries + `Orchestra_OrchestraCore.resources` (or `.bundle`).

If SwiftPM errors that the package/platform is unsupported (it should not — `platforms: [.macOS(.v14)]` constrains only the macOS deployment floor and does not block Linux), then and only then relax `Package.swift`: no removal of `.macOS(.v14)` is expected. Document the actual outcome in the commit message.

- [ ] **Step 3: Confirm the macOS build + full suite are still green**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -20`
Expected: macOS build succeeds; entire test suite passes.

- [ ] **Step 4: (Optional, if a Linux box is available) end-to-end smoke**

Deploy to a box and confirm the daemon answers: `scripts/deploy-linux-daemon.sh <user@host>` then `ssh <user@host> 'ORCHESTRA … ' orchestra daemon status` → `running`, and the printed socket path is `~/.local/share/orchestra/orchestrad.sock`. If no box is available, note that the deploy scripts are now unblocked and defer the live smoke to Workstream D testing.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: verify Linux cross-build of orchestrad/orchestra/orchestra-mcp (workstream A done)"
```

**⇢ At this point move the card to `impl` if not already, and A's DoD is met: the merged deploy scripts produce a working binary.**

---

# WORKSTREAM B — Transport seam + reconnect

**Definition of done:** `ControlClient` owns a `Transport` (default `UDSTransport` = current behavior); a dropped connection triggers backoff → reconnect → re-subscribe rather than dying; an observable `ConnectionState` (`connecting | live | retrying | down`) is exposed. Unit-tested with a fake `Transport` that drops mid-stream **and** an end-to-end server-restart test.

---

### Task B1: Extract the `Transport` protocol + `UDSTransport`

**Files:**
- Create: `Sources/OrchestraCore/Control/Transport.swift`
- Test: `Tests/OrchestraCoreTests/TransportReconnectTests.swift` (create; first test here)

**Interfaces:**
- Produces:
  - `public enum ConnectionState: String, Sendable, Equatable { case connecting, live, retrying, down }`
  - `public protocol Transport: AnyObject, Sendable { func open() throws; func write(_ data: Data) -> Bool; func readLine() -> Data?; func close() }`
  - `public final class UDSTransport: Transport, @unchecked Sendable { public init(socketPath: String) }`

- [ ] **Step 1: Write the failing test (UDSTransport round-trips against a ControlServer)**

Create `Tests/OrchestraCoreTests/TransportReconnectTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Transport + reconnect", .serialized)
struct TransportReconnectTests {
    static func sock() -> String { "/tmp/orch-\(UUID().uuidString.prefix(8)).sock" }

    @Test("UDSTransport open/write/readLine round-trips a ping against ControlServer")
    func udsRoundTrip() async throws {
        let env = TestEnv.make()
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }

        let t = UDSTransport(socketPath: path)
        try t.open()
        defer { t.close() }
        let line = try RPCCodec.line(RPCRequest(id: 1, method: "ping"))
        #expect(t.write(line))
        let reply = try #require(t.readLine())
        let msg = try RPCCodec.decoder.decode(WireMessage.self, from: reply)
        #expect(msg.result?["ok"]?.boolValue == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TransportReconnect 2>&1 | tail -15`
Expected: FAIL — `UDSTransport` / `Transport` do not exist.

- [ ] **Step 3: Implement `Transport.swift`**

```swift
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Observable link state the UI binds to. `connecting` = first attempt; `live` = connected + (re)subscribed;
/// `retrying` = dropped, backing off; `down` = intentionally closed.
public enum ConnectionState: String, Sendable, Equatable {
    case connecting, live, retrying, down
}

/// The swap point between the client and its byte transport. `UDSTransport` is the only concrete impl
/// today (current UDS behavior); a future WebSocket/tailnet transport plugs in here without touching
/// `ControlClient`. One instance == one live connection: after `close()` (or EOF), the client makes a
/// FRESH transport to reconnect.
public protocol Transport: AnyObject, Sendable {
    /// Establish the connection. Throws on failure.
    func open() throws
    /// Write one already-newline-terminated frame. `false` if the link is broken.
    func write(_ data: Data) -> Bool
    /// Block for the next inbound NDJSON line (without trailing '\n'); `nil` on EOF/close.
    func readLine() -> Data?
    /// Tear down the connection.
    func close()
}

/// AF_UNIX transport — the current behavior, extracted behind `Transport`.
public final class UDSTransport: Transport, @unchecked Sendable {
    private let socketPath: String
    private var fd: Int32 = -1
    private var reader: LineReader?
    private let writeLock = NSLock()

    public init(socketPath: String) { self.socketPath = socketPath }

    public func open() throws {
        let f = try UDS.connect(path: socketPath)
        writeLock.withLock { fd = f; reader = LineReader(fd: f) }
    }

    public func write(_ data: Data) -> Bool {
        writeLock.withLock {
            guard fd >= 0 else { return false }
            return UDS.writeAll(fd, data)
        }
    }

    public func readLine() -> Data? { reader?.next() }

    public func close() {
        writeLock.withLock {
            if fd >= 0 { _ = close(fd); fd = -1 }
            reader = nil
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TransportReconnect 2>&1 | tail -15`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Control/Transport.swift Tests/OrchestraCoreTests/TransportReconnectTests.swift
git commit -m "feat(core): extract Transport protocol + UDSTransport + ConnectionState"
```

---

### Task B2: Rewire `ControlClient` onto `Transport` (behavior-preserving)

**Files:**
- Modify: `Sources/OrchestraCore/Control/ControlClient.swift`

**Interfaces:**
- Consumes: `Transport`, `UDSTransport` (B1).
- Produces:
  - New designated init `public init(transport: @escaping @Sendable () -> Transport, source: ActivitySource = .app)`.
  - Preserved convenience init `public convenience init(socketPath: String = Config.socketPath, source: ActivitySource = .app)` → `{ UDSTransport(socketPath: socketPath) }`.
  - `public private(set) var state: ConnectionState` + `public var onState: (@Sendable (ConnectionState) -> Void)?`.
  - Unchanged: `call`, `call<T>`, `subscribe`, `close`.

This task keeps the **single-shot** behavior (no reconnect yet) but routes all I/O through a `Transport`, so it stays green against every existing test. Reconnect is added in B3.

- [ ] **Step 1: Replace fd ownership with a Transport factory**

Rewrite the stored properties + inits. Replace:

```swift
    public let source: ActivitySource
    private let socketPath: String
    private var fd: Int32 = -1
    private let writeLock = NSLock()
    ...
    public init(socketPath: String = Config.socketPath, source: ActivitySource = .app) {
        self.socketPath = socketPath
        self.source = source
    }
```

with:

```swift
    public let source: ActivitySource
    private let makeTransport: @Sendable () -> Transport
    private var transport: Transport?
    private let writeLock = NSLock()

    public private(set) var state: ConnectionState = .down
    public var onState: (@Sendable (ConnectionState) -> Void)?

    public convenience init(socketPath: String = Config.socketPath, source: ActivitySource = .app) {
        self.init(transport: { UDSTransport(socketPath: socketPath) }, source: source)
    }

    public init(transport: @escaping @Sendable () -> Transport, source: ActivitySource = .app) {
        self.makeTransport = transport
        self.source = source
    }

    private func setState(_ s: ConnectionState) {
        stateLock.withLock { state = s }
        onState?(s)
    }
```

- [ ] **Step 2: Route connect/close/write/read through the transport**

Rewrite `connect()`, `close()`, `call`, and `readLoop` to use `transport` instead of `fd`:

```swift
    public func connect() throws {
        let t = makeTransport()
        setState(.connecting)
        try t.open()
        writeLock.withLock { transport = t }
        setState(.live)
        DispatchQueue.global().async { [weak self] in self?.readLoop() }
    }

    public func close() {
        let t: Transport? = writeLock.withLock { let x = transport; transport = nil; return x }
        t?.close()
        stateLock.withLock {
            for (_, c) in pending { c.resume(throwing: OrchestraError.io("connection closed")) }
            pending.removeAll()
            eventContinuation?.finish()
        }
        setState(.down)
    }
```

In `call`, replace the raw `writeLock.lock(); let ok = UDS.writeAll(fd, line); writeLock.unlock()` with:

```swift
            let ok = writeLock.withLock { transport?.write(line) ?? false }
```

In `readLoop`, replace `let reader = LineReader(fd: fd)` + `while let line = reader.next()` with reads off the transport:

```swift
    private func readLoop() {
        let t = writeLock.withLock { transport }
        while let line = t?.readLine() {
            guard !line.isEmpty,
                  let msg = try? RPCCodec.decoder.decode(WireMessage.self, from: line) else { continue }
            if msg.method == "event" {
                if let event = try? msg.params?.decode(Event.self) {
                    stateLock.withLock { eventContinuation }?.yield(event)
                }
            } else if let id = msg.id {
                if let cont = stateLock.withLock({ pending.removeValue(forKey: id) }) {
                    if let err = msg.error { cont.resume(throwing: err) }
                    else { cont.resume(returning: msg.result ?? .null) }
                }
            }
        }
        close()
    }
```

- [ ] **Step 3: Verify the whole suite still passes (behavior preserved)**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -20`
Expected: build succeeds; full suite green (ControlRoundTrip, Recovery, Reopen, etc. all still pass — the client behaves identically, just via a Transport).

- [ ] **Step 4: Commit**

```bash
git add Sources/OrchestraCore/Control/ControlClient.swift
git commit -m "refactor(core): ControlClient owns a Transport + exposes ConnectionState"
```

---

### Task B3: Reconnect + re-subscribe with backoff

**Files:**
- Modify: `Sources/OrchestraCore/Control/ControlClient.swift`
- Test: `Tests/OrchestraCoreTests/TransportReconnectTests.swift` (add tests)

**Interfaces:**
- Consumes: B2's Transport-backed client.
- Produces: internal reconnect loop; a `subscribed` flag; behavior — a transient EOF transitions `live → retrying → live` and re-issues `subscribe`; `close()` sets `stopping` so it does not reconnect.

- [ ] **Step 1: Write the failing tests**

Add to `TransportReconnectTests.swift`:

```swift
    /// A controllable fake transport: records written frames; `dropNow()` forces the current readLine to
    /// return nil (EOF); reconnect makes a fresh instance via the factory.
    final class FakeTransport: Transport, @unchecked Sendable {
        let box: FakeBox
        init(_ box: FakeBox) { self.box = box }
        func open() throws { box.opened() }
        func write(_ data: Data) -> Bool { box.record(data); return true }
        func readLine() -> Data? { box.blockForLine() }
        func close() { box.eof() }
    }

    final class FakeBox: @unchecked Sendable {
        private let lock = NSLock()
        private let sema = DispatchSemaphore(value: 0)
        private var lines: [Data] = []
        private var eofFlag = false
        private(set) var writes: [Data] = []
        private(set) var opens = 0
        func opened() { lock.withLock { opens += 1; eofFlag = false } }
        func record(_ d: Data) { lock.withLock { writes.append(d) }; }
        func push(_ d: Data) { lock.withLock { lines.append(d) }; sema.signal() }
        func eof() { lock.withLock { eofFlag = true }; sema.signal() }
        func blockForLine() -> Data? {
            while true {
                sema.wait()
                let r: Data?? = lock.withLock {
                    if eofFlag { return .some(nil) }
                    if !lines.isEmpty { return .some(lines.removeFirst()) }
                    return nil
                }
                if let r { return r }
            }
        }
        var subscribeCount: Int {
            lock.withLock { writes.filter { (try? RPCCodec.decoder.decode(RPCRequest.self, from: $0))?.method == "subscribe" }.count }
        }
    }

    @Test("dropped transport → state goes live → retrying → live and re-subscribes")
    func reconnectResubscribes() async throws {
        let box = FakeBox()
        let states = StateBox()
        let client = ControlClient(transport: { FakeTransport(box) }, source: .app)
        client.onState = { s in _Concurrency.Task { await states.add(s) } }
        try client.connect()
        _ = client.subscribe()                                   // sends subscribe #1
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        #expect(box.subscribeCount == 1)

        box.eof()                                                // drop mid-stream
        try await _Concurrency.Task.sleep(for: .milliseconds: 400)  // let backoff + reconnect run
        #expect(box.opens >= 2)                                  // reconnected with a fresh transport
        #expect(box.subscribeCount == 2)                         // re-subscribed
        let seen = await states.values
        #expect(seen.contains(.retrying))
        #expect(seen.last == .live)
        client.close()
    }
```

Add the small actor:

```swift
actor StateBox { private(set) var values: [ConnectionState] = []; func add(_ s: ConnectionState) { values.append(s) } }
```

(Fix the obvious `.milliseconds: 400` typo to `.milliseconds(400)` when typing.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TransportReconnect 2>&1 | tail -20`
Expected: FAIL — no reconnect: `box.opens == 1`, `subscribeCount == 1`, no `.retrying` state.

- [ ] **Step 3: Implement the reconnect loop**

Add state to `ControlClient`:

```swift
    private var subscribed = false
    private var stopping = false
```

In `subscribe()`, set `subscribed = true` under `stateLock` alongside storing the continuation (so reconnect knows to re-issue it). In `close()`, set `stopping = true` first thing (under `stateLock`).

Replace the single-shot `connect()` + `readLoop()` with a reconnecting loop. `connect()` does the first synchronous open (so callers still get an immediate throw on a hard first failure), then starts the loop:

```swift
    public func connect() throws {
        stateLock.withLock { stopping = false }
        try openOnce()                       // throws on first hard failure (preserves old API)
        DispatchQueue.global().async { [weak self] in self?.runLoop() }
    }

    private func openOnce() throws {
        let t = makeTransport()
        setState(.connecting)
        try t.open()
        writeLock.withLock { transport = t }
        setState(.live)
    }

    private func runLoop() {
        var attempt = 0
        while true {
            if stateLock.withLock({ stopping }) { return }
            readUntilEOF()                                   // returns when the current transport hits EOF
            failPending()
            if stateLock.withLock({ stopping }) { setState(.down); return }
            setState(.retrying)
            // Backoff-reconnect until success or stop.
            while true {
                if stateLock.withLock({ stopping }) { setState(.down); return }
                let ms = Self.backoffMillis(attempt); attempt += 1
                Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
                if stateLock.withLock({ stopping }) { setState(.down); return }
                do {
                    try openOnce()
                    attempt = 0
                    if stateLock.withLock({ subscribed }) { _Concurrency.Task { try? await self.call("subscribe") } }
                    break
                } catch { setState(.retrying); continue }
            }
        }
    }

    /// The read pump for the CURRENT transport; returns on EOF (does NOT close the client).
    private func readUntilEOF() {
        let t = writeLock.withLock { transport }
        while let line = t?.readLine() {
            guard !line.isEmpty,
                  let msg = try? RPCCodec.decoder.decode(WireMessage.self, from: line) else { continue }
            if msg.method == "event" {
                if let event = try? msg.params?.decode(Event.self) {
                    stateLock.withLock { eventContinuation }?.yield(event)
                }
            } else if let id = msg.id {
                if let cont = stateLock.withLock({ pending.removeValue(forKey: id) }) {
                    if let err = msg.error { cont.resume(throwing: err) }
                    else { cont.resume(returning: msg.result ?? .null) }
                }
            }
        }
        // EOF: drop the dead transport so the next openOnce() replaces it cleanly.
        let dead: Transport? = writeLock.withLock { let x = transport; transport = nil; return x }
        dead?.close()
    }

    /// Fail every in-flight call so awaiters don't hang across a reconnect.
    private func failPending() {
        let conts = stateLock.withLock { () -> [CheckedContinuation<JSONValue, Error>] in
            let cs = Array(pending.values); pending.removeAll(); return cs
        }
        for c in conts { c.resume(throwing: OrchestraError.io("connection dropped")) }
    }

    /// Exponential backoff with a 5s cap and ±20% jitter, in milliseconds.
    static func backoffMillis(_ attempt: Int) -> Int {
        let base = min(5000, 250 * (1 << min(attempt, 5)))       // 250,500,1000,2000,4000,5000…
        let jitter = base / 5
        // Deterministic-enough jitter without Date/random (unavailable in some sandboxes): derive from attempt.
        let sign = attempt % 2 == 0 ? 1 : -1
        return max(50, base + sign * (jitter * (attempt % 3)) / 3)
    }
```

Remove the old `readLoop()` (superseded by `readUntilEOF`/`runLoop`). Keep `close()` as in B2 but ensure it sets `stopping = true` and calls `transport?.close()` (which unblocks `readUntilEOF`). The AsyncStream from `subscribe()` must NOT finish on a transient drop — only `close()` finishes it. Confirm `readUntilEOF` never calls `eventContinuation?.finish()`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TransportReconnect 2>&1 | tail -20`
Expected: PASS — `opens >= 2`, `subscribeCount == 2`, states include `.retrying` and end `.live`.

- [ ] **Step 5: Add + run an end-to-end server-restart reconnect test**

Add to `TransportReconnectTests.swift`:

```swift
    @Test("client reconnects + resumes events when the server restarts on the same socket")
    func serverRestartReconnect() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let path = Self.sock()
        var server = ControlServer(service: env.svc, socketPath: path)
        try server.start()

        let client = ControlClient(socketPath: path, source: .app)
        try client.connect(); defer { client.close() }
        let box = EventBox()
        let stream = client.subscribe()
        _Concurrency.Task { for await e in stream { await box.add(e) } }
        try await _Concurrency.Task.sleep(for: .milliseconds(80))

        server.stop()                                        // drop the link
        try await _Concurrency.Task.sleep(for: .milliseconds(200))
        server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }          // fresh server, same socket path

        // After reconnect + re-subscribe, a new spawn's event must reach the same stream.
        try await _Concurrency.Task.sleep(for: .milliseconds(600))
        _ = try await client.call("spawn", .object([
            "prompt": .string("after restart"), "repo": .string(repo), "branch": .string("b2")]))
        try await _Concurrency.Task.sleep(for: .milliseconds(200))
        let acts = await box.events.compactMap { if case .activity(let a) = $0 { return a } else { return nil } }
        #expect(acts.contains { $0.text.contains("after restart") })
    }
```

Run: `swift test --filter TransportReconnect 2>&1 | tail -20`
Expected: PASS (all 3 reconnect tests).

- [ ] **Step 6: Full suite + commit**

Run: `swift test 2>&1 | tail -20` (expected: all green).

```bash
git add Sources/OrchestraCore/Control/ControlClient.swift Tests/OrchestraCoreTests/TransportReconnectTests.swift
git commit -m "feat(core): reconnect + re-subscribe with backoff + observable state"
```

---

# WORKSTREAM C — Connection model + settings UI

**Definition of done:** a shared `Connection` value round-trips through a persisted `ConnectionStore`; the macOS Settings has a Connections pane (list / add-edit-delete remote / pick active / Connect-Disconnect / live status chip); `BoardModel` reads the active connection instead of the hard-wired `Config.socketPath`. Remote connections are wired through a `ConnectionController` seam whose `.remote` branch is completed in Workstream D.

---

### Task C1: `Connection` value + built-in local

**Files:**
- Create: `Sources/OrchestraCore/Connection.swift`
- Test: `Tests/OrchestraCoreTests/ConnectionStoreTests.swift` (create; first test here)

**Interfaces:**
- Produces:

```swift
public struct Connection: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public enum Kind: String, Codable, Sendable { case local, remote }
    public var kind: Kind
    public var sshTarget: String?          // user@host, remote only
    public var identityFile: String?       // -i path, optional
    public var remoteSocketPath: String?   // daemon socket ON the box, remote only
    public var remoteTmuxSocket: String    // tmux -L name (default "orchestra")
    public init(id: UUID = UUID(), name: String, kind: Kind, sshTarget: String? = nil,
                identityFile: String? = nil, remoteSocketPath: String? = nil,
                remoteTmuxSocket: String = "orchestra")
    public static let localId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static var local: Connection    // the always-present built-in
    public var isLocal: Bool { kind == .local }
}
```

- [ ] **Step 1: Write the failing test**

Create `Tests/OrchestraCoreTests/ConnectionStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Connection + ConnectionStore")
struct ConnectionStoreTests {
    @Test("built-in local connection is stable + local kind")
    func builtInLocal() {
        let l = Connection.local
        #expect(l.kind == .local)
        #expect(l.id == Connection.localId)
        #expect(l.remoteTmuxSocket == "orchestra")
    }

    @Test("a remote Connection round-trips through Codable")
    func codableRoundTrip() throws {
        let c = Connection(name: "work box", kind: .remote, sshTarget: "me@box",
                           identityFile: "~/.ssh/id_ed25519",
                           remoteSocketPath: "/home/me/.local/share/orchestra/orchestrad.sock",
                           remoteTmuxSocket: "orchestra")
        let data = try OrchestraJSON.encoder.encode(c)
        let back = try OrchestraJSON.decoder.decode(Connection.self, from: data)
        #expect(back == c)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConnectionStore 2>&1 | tail -15`
Expected: FAIL — `Connection` does not exist.

- [ ] **Step 3: Implement `Connection.swift`**

```swift
import Foundation

/// A client-side target the app/phone can talk to: the built-in local daemon, or a remote Linux box
/// reached over SSH. Lives in the shared core so iOS reuses it. The wire protocol is identical for all
/// kinds; only *reachability* differs (direct UDS vs SSH-forwarded socket).
public struct Connection: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public enum Kind: String, Codable, Sendable { case local, remote }
    public var kind: Kind
    public var sshTarget: String?
    public var identityFile: String?
    public var remoteSocketPath: String?
    public var remoteTmuxSocket: String

    public init(id: UUID = UUID(), name: String, kind: Kind, sshTarget: String? = nil,
                identityFile: String? = nil, remoteSocketPath: String? = nil,
                remoteTmuxSocket: String = "orchestra") {
        self.id = id; self.name = name; self.kind = kind
        self.sshTarget = sshTarget; self.identityFile = identityFile
        self.remoteSocketPath = remoteSocketPath; self.remoteTmuxSocket = remoteTmuxSocket
    }

    /// Stable id for the built-in local connection (never persisted; synthesized).
    public static let localId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static var local: Connection {
        Connection(id: localId, name: "This Mac", kind: .local, remoteTmuxSocket: Config.tmuxSocket)
    }
    public var isLocal: Bool { kind == .local }
}
```

(If `OrchestraJSON.encoder` is not public, use the existing public encoder/decoder the codebase exposes — check `OrchestraJSON` in core; the test uses whatever `ConfigStore` uses.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ConnectionStore 2>&1 | tail -15`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Connection.swift Tests/OrchestraCoreTests/ConnectionStoreTests.swift
git commit -m "feat(core): Connection value + built-in local connection"
```

---

### Task C2: `ConnectionStore` (persisted list + active id)

**Files:**
- Create: `Sources/OrchestraCore/ConnectionStore.swift`
- Test: `Tests/OrchestraCoreTests/ConnectionStoreTests.swift` (add tests)

**Interfaces:**
- Produces:

```swift
public final class ConnectionStore {
    public init(defaults: UserDefaults = .standard, key: String = "orch_connections", activeKey: String = "orch_active_connection")
    public var remotes: [Connection] { get }                 // persisted remotes (excludes built-in local)
    public var all: [Connection] { get }                     // [.local] + remotes
    public var activeId: UUID { get set }                    // persisted; defaults to Connection.localId
    public var active: Connection { get }                    // resolves activeId → all, falling back to .local
    public func upsert(_ c: Connection)
    public func delete(_ id: UUID)
}
```

- [ ] **Step 1: Write the failing tests**

Add to `ConnectionStoreTests.swift`:

```swift
    private func freshStore() -> ConnectionStore {
        let suite = "orch-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        return ConnectionStore(defaults: d)
    }

    @Test("store starts with only the built-in local, active = local")
    func startsLocal() {
        let s = freshStore()
        #expect(s.all.count == 1)
        #expect(s.all.first?.isLocal == true)
        #expect(s.active.id == Connection.localId)
    }

    @Test("upsert adds a remote, persists it, and it becomes selectable")
    func upsertRemote() {
        let s = freshStore()
        let c = Connection(name: "box", kind: .remote, sshTarget: "me@box",
                           remoteSocketPath: "/x/orchestrad.sock")
        s.upsert(c)
        #expect(s.remotes.count == 1)
        #expect(s.all.count == 2)
        s.activeId = c.id
        #expect(s.active.sshTarget == "me@box")
    }

    @Test("delete removes a remote; deleting the active one falls back to local")
    func deleteFallsBack() {
        let s = freshStore()
        let c = Connection(name: "box", kind: .remote, sshTarget: "me@box")
        s.upsert(c); s.activeId = c.id
        s.delete(c.id)
        #expect(s.remotes.isEmpty)
        #expect(s.active.id == Connection.localId)
    }

    @Test("edits persist across a fresh store on the same suite")
    func persistsAcrossInstances() {
        let suite = "orch-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        let s1 = ConnectionStore(defaults: d)
        let c = Connection(name: "box", kind: .remote, sshTarget: "me@box")
        s1.upsert(c); s1.activeId = c.id
        let s2 = ConnectionStore(defaults: d)
        #expect(s2.remotes.first?.sshTarget == "me@box")
        #expect(s2.active.id == c.id)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConnectionStore 2>&1 | tail -15`
Expected: FAIL — `ConnectionStore` does not exist.

- [ ] **Step 3: Implement `ConnectionStore.swift`**

```swift
import Foundation

/// Client-local persistence for the connection list + which one is active. Stored in UserDefaults so it
/// is per-Mac (choosing WHICH daemon is a client concern, never the daemon's config). The built-in local
/// connection is synthesized, never stored, and always first.
public final class ConnectionStore {
    private let defaults: UserDefaults
    private let key: String
    private let activeKey: String

    public init(defaults: UserDefaults = .standard,
                key: String = "orch_connections",
                activeKey: String = "orch_active_connection") {
        self.defaults = defaults; self.key = key; self.activeKey = activeKey
    }

    public var remotes: [Connection] {
        guard let data = defaults.data(forKey: key),
              let list = try? OrchestraJSON.decoder.decode([Connection].self, from: data) else { return [] }
        return list.filter { !$0.isLocal }
    }
    public var all: [Connection] { [.local] + remotes }

    public var activeId: UUID {
        get {
            guard let s = defaults.string(forKey: activeKey), let id = UUID(uuidString: s) else { return Connection.localId }
            return id
        }
        set { defaults.set(newValue.uuidString, forKey: activeKey) }
    }
    public var active: Connection { all.first { $0.id == activeId } ?? .local }

    public func upsert(_ c: Connection) {
        guard !c.isLocal else { return }
        var list = remotes
        if let i = list.firstIndex(where: { $0.id == c.id }) { list[i] = c } else { list.append(c) }
        persist(list)
    }
    public func delete(_ id: UUID) {
        persist(remotes.filter { $0.id != id })
        if activeId == id { activeId = Connection.localId }
    }

    private func persist(_ list: [Connection]) {
        if let data = try? OrchestraJSON.encoder.encode(list) { defaults.set(data, forKey: key) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConnectionStore 2>&1 | tail -15`
Expected: PASS (all ConnectionStore tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/ConnectionStore.swift Tests/OrchestraCoreTests/ConnectionStoreTests.swift
git commit -m "feat(core): ConnectionStore — persisted connection list + active id"
```

---

### Task C3: `ConnectionController` (app-side activation seam)

**Files:**
- Create: `App/ConnectionController.swift`

**Interfaces:**
- Produces:

```swift
@MainActor final class ConnectionController: ObservableObject {
    @Published private(set) var state: ConnectionState = .down
    /// Activate a connection and return the LOCAL socket path the transport should target.
    /// `.local` → Config.socketPath immediately. `.remote` → completed in Workstream D (throws until then).
    func localSocketPath(for conn: Connection) async throws -> String
    func deactivate()
    /// Set by Workstream D so a dropped tunnel trips the client's reconnect.
    var onTunnelExit: (() -> Void)?
}
```

This is App-only (no SwiftPM test target); it is verified by the app build + the manual/isolated run. Keep the `.remote` branch a clear `throw` so C compiles and runs with local fully working, and D fills it in.

- [ ] **Step 1: Implement the controller (local working, remote stubbed)**

```swift
import Foundation
import OrchestraCore

@MainActor
final class ConnectionController: ObservableObject {
    @Published private(set) var state: ConnectionState = .down
    var onTunnelExit: (() -> Void)?

    // Workstream D populates this with a live SSHMaster for remote connections.
    private var master: AnyObject?

    func localSocketPath(for conn: Connection) async throws -> String {
        switch conn.kind {
        case .local:
            state = .live
            return Config.socketPath
        case .remote:
            // Filled in by Workstream D (SSHMaster). Until then remote is not connectable.
            throw OrchestraError.io("remote connections require the SSH tunnel (workstream D)")
        }
    }

    func deactivate() {
        master = nil
        state = .down
    }
}
```

- [ ] **Step 2: Verify the app still builds**

Run: `scripts/build-app.sh 2>&1 | tail -15`
Expected: app builds (the new file compiles; nothing wired yet).

- [ ] **Step 3: Commit**

```bash
git add App/ConnectionController.swift
git commit -m "feat(app): ConnectionController seam (local activation; remote stubbed for D)"
```

---

### Task C4: Rewire `BoardModel` onto the active connection

**Files:**
- Modify: `App/BoardModel.swift`

**Interfaces:**
- Consumes: `ConnectionStore`, `ConnectionController`, `ControlClient(transport:)`, `ConnectionState`.
- Produces: `BoardModel` holds a `ConnectionStore` + `ConnectionController`; `connectionState: ConnectionState` published; `switchConnection(_ id: UUID)` async; the client is (re)built from the active connection's socket. `client` becomes `var` (rebuilt on switch).

- [ ] **Step 1: Add the store/controller + connection-state binding**

Replace the `let client: ControlClient` + `init(socketPath:)` with:

```swift
    let connections = ConnectionStore()
    let connectionController = ConnectionController()
    @Published var connectionState: ConnectionState = .down
    private(set) var client: ControlClient

    init() {
        client = ControlClient(socketPath: Config.socketPath, source: .app)
        wireState()
    }

    private func wireState() {
        client.onState = { [weak self] s in
            _Concurrency.Task { @MainActor in
                self?.connectionState = s
                self?.connected = (s == .live)
            }
        }
    }
```

- [ ] **Step 2: Build the client from the active connection on bootstrap/switch**

Replace `bootstrap()`'s local-only path and add `switchConnection`:

```swift
    func bootstrap() async {
        await activate(connections.active)
    }

    /// Point the board at a connection: resolve its local socket, (re)build the client, connect + stream.
    func activate(_ conn: Connection) async {
        // Tear down any existing client first.
        client.close()
        connectionController.deactivate()
        do {
            let sockPath = try await connectionController.localSocketPath(for: conn)
            client = ControlClient(socketPath: sockPath, source: .app)
            wireState()
            connectionController.onTunnelExit = { [weak self] in
                // A dropped tunnel: the client's own reconnect handles the socket; nothing else needed here.
                _ = self
            }
            if conn.isLocal {
                // Preserve the existing local onboarding/daemon-install flow.
                if DaemonLifecycle().isRunning() { onboarded = true; await start() }
                else if !onboarded { showOnboarding = true } else { connected = false }
            } else {
                await start()
            }
        } catch {
            connected = false
            toast("Couldn't connect", sub: "\(error)", color: .red)
        }
    }

    func switchConnection(_ id: UUID) async {
        connections.activeId = id
        await activate(connections.active)
    }
```

Keep `start()` as-is (it already retries connect + wires the stream). Note the stream no longer ends on transient drops (B), so `handleStreamEnded` now only fires on real `close()` — leave it; it is harmless and correct.

- [ ] **Step 3: Verify the app builds + local connection still works via the isolated harness**

Run: `scripts/build-app.sh 2>&1 | tail -15`
Then drive an isolated instance to confirm the board still attaches to a local daemon (per the project's isolated-testing recipe): `scripts/orch-test.sh` (or `orch-ui-shot.sh` for a visual check). Expected: app builds; local board connects + shows cards exactly as before.

- [ ] **Step 4: Commit**

```bash
git add App/BoardModel.swift
git commit -m "feat(app): BoardModel targets the active Connection; publishes connection state"
```

---

### Task C5: Connections settings pane

**Files:**
- Create: `App/Views/ConnectionsSettingsView.swift`
- Modify: `App/Views/SettingsView.swift` (extract existing body into a `GeneralSettingsView` if a rename is cleaner; otherwise leave as-is and reference it as the General tab)
- Modify: `App/OrchestraApp.swift` (Settings scene → TabView)

**Interfaces:**
- Consumes: `BoardModel.connections`, `BoardModel.connectionState`, `BoardModel.switchConnection`, `BoardModel.activate`.
- Produces: a themed Connections pane: list `connections.all`, add/edit/delete a remote (name, ssh target, identity file, remote socket path, remote tmux socket), select active (radio), Connect/Disconnect button, and a status chip driven by `connectionState`.

- [ ] **Step 1: Build the Connections pane**

Create `App/Views/ConnectionsSettingsView.swift` following the existing `SettingsView` styling (themed `section`/`row`/`field`/`menu` helpers — reuse the same visual language; you may copy the small helper set or factor it into a shared file). Core structure:

```swift
import SwiftUI
import OrchestraCore

struct ConnectionsSettingsView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    @State private var editing: Connection?      // non-nil → show the editor sheet
    @State private var refresh = false           // toggled to re-read the store after mutations

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusChip
                connectionList
                addButton
            }
            .padding(20)
        }
        .background(theme.winBg)
        .frame(width: 480, height: 470)
        .sheet(item: $editing) { conn in
            ConnectionEditor(connection: conn) { saved in
                model.connections.upsert(saved); refresh.toggle(); editing = nil
            } onCancel: { editing = nil }
            .environmentObject(model)
        }
    }

    private var statusChip: some View {
        let (label, color): (String, Color) = {
            switch model.connectionState {
            case .live:       return ("Connected", .green)
            case .connecting: return ("Connecting…", .blue)
            case .retrying:   return ("Reconnecting…", .orange)
            case .down:       return ("Disconnected", theme.text3)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(F.ui(12, .medium)).foregroundStyle(theme.text2)
        }
    }

    private var connectionList: some View {
        // one row per model.connections.all: radio (active), name + subtitle, edit/delete for remotes.
        // Tapping a radio → _Concurrency.Task { await model.switchConnection(conn.id) }.
        // (Build with the same `section`/`row` helpers as SettingsView.)
        EmptyView()   // replace with the real list per the styling notes above
    }
    // header, addButton, ConnectionEditor (a small form sheet) omitted here for brevity — implement them
    // using the SettingsView helper set; the editor collects name/sshTarget/identityFile/remoteSocketPath/
    // remoteTmuxSocket and calls the onSave closure with a Connection(kind: .remote, …).
}
```

Implement `connectionList`, `header`, `addButton`, and a `ConnectionEditor` sheet fully (no placeholders in the final code — the `EmptyView()` / `// omitted` markers above are a sketch; the executor writes the concrete SwiftUI matching `SettingsView`'s helpers). The Connect/Disconnect action calls `model.activate(model.connections.active)` / `model.client.close()`.

- [ ] **Step 2: Make Settings a TabView (General + Connections)**

In `App/OrchestraApp.swift`, change the `Settings { SettingsView() }` scene to:

```swift
        Settings {
            TabView {
                SettingsView()
                    .tabItem { Label("General", systemImage: "gearshape") }
                ConnectionsSettingsView()
                    .tabItem { Label("Connections", systemImage: "network") }
            }
            .environmentObject(model)
            .frame(width: 480, height: 512)
        }
```

(Keep `.environmentObject(model)` reachable to both tabs — it is already injected on the window; add it here too so the Settings scene has it.)

- [ ] **Step 3: Verify the app builds + the pane renders**

Run: `scripts/build-app.sh 2>&1 | tail -15`
Then `scripts/orch-ui-shot.sh` (visual check) or launch the isolated instance and open Settings → Connections. Expected: app builds; the Connections pane lists "This Mac" (active), and Add opens the remote editor. Paste the screenshot back for review.

- [ ] **Step 4: Commit**

```bash
git add App/Views/ConnectionsSettingsView.swift App/OrchestraApp.swift App/Views/SettingsView.swift
git commit -m "feat(app): Connections settings pane + tabbed Settings"
```

---

# WORKSTREAM D — SSH tunnel + remote terminals

**Definition of done:** on Connect to a remote connection the app spawns + supervises a multiplexed master `ssh`, points the transport at the forwarded local socket, and SwiftTerm terminals attach over the same control socket to the remote tmux. Tunnel death trips B's reconnect (respawn master → reconnect client). Pre-spawn cleanup avoids stale-control-socket failures.

---

### Task D1: Pure SSH/remote command builders (testable)

**Files:**
- Create: `Sources/OrchestraCore/RemoteCommands.swift`
- Test: `Tests/OrchestraCoreTests/RemoteCommandsTests.swift` (create)

**Interfaces:**
- Produces (pure, no process spawning — unit-tested):

```swift
public enum RemoteCommands {
    /// Master ssh argv: multiplexed control master forwarding the remote daemon socket to a local socket.
    /// Foreground (`-N`, no `-f`) so the app owns the Process and gets exit callbacks.
    public static func sshMasterArgs(target: String, identityFile: String?, controlPath: String,
                                     localSocketPath: String, remoteSocketPath: String) -> [String]
    /// Tear down the master's control socket.
    public static func sshExitArgs(target: String, controlPath: String) -> [String]
    /// A terminal child command that attaches to the REMOTE tmux over the shared control socket.
    /// Returns (executable, args) for SwiftTerm's startProcess.
    public static func remoteTmuxAttach(target: String, controlPath: String, tmuxSocket: String,
                                        script: String) -> (executable: String, args: [String])
    /// True if a UDS path fits under the sun_path cap (~104). Guards tunnel socket paths.
    public static func socketPathFits(_ path: String) -> Bool
}
```

- [ ] **Step 1: Write the failing tests**

Create `Tests/OrchestraCoreTests/RemoteCommandsTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("RemoteCommands — ssh multiplexing argv")
struct RemoteCommandsTests {
    @Test("master args set up -M/-S/-N/-L and batch-mode, with identity when given")
    func master() {
        let a = RemoteCommands.sshMasterArgs(
            target: "me@box", identityFile: "~/.ssh/id", controlPath: "/tmp/o/c",
            localSocketPath: "/tmp/o/s", remoteSocketPath: "/home/me/.local/share/orchestra/orchestrad.sock")
        #expect(a.first == "ssh")
        #expect(a.contains("-M"))
        #expect(a.contains("-N"))
        #expect(!a.contains("-f"))                                     // app-owned, not detached
        #expect(a.contains("-S")); #expect(a.contains("/tmp/o/c"))
        // -L local:remote forward
        #expect(a.contains("-L"))
        #expect(a.contains("/tmp/o/s:/home/me/.local/share/orchestra/orchestrad.sock"))
        #expect(a.contains("-i")); #expect(a.contains("~/.ssh/id"))
        #expect(a.contains("me@box"))
        // key-only, fail-fast on forward errors
        #expect(a.contains("BatchMode=yes"))
        #expect(a.contains("ExitOnForwardFailure=yes"))
    }

    @Test("no -i when identity omitted")
    func noIdentity() {
        let a = RemoteCommands.sshMasterArgs(target: "me@box", identityFile: nil, controlPath: "/tmp/c",
                                             localSocketPath: "/tmp/s", remoteSocketPath: "/r.sock")
        #expect(!a.contains("-i"))
    }

    @Test("exit args target the same control socket")
    func exit() {
        let a = RemoteCommands.sshExitArgs(target: "me@box", controlPath: "/tmp/c")
        #expect(a.contains("-S")); #expect(a.contains("/tmp/c"))
        #expect(a.contains("-O")); #expect(a.contains("exit"))
        #expect(a.last == "me@box")
    }

    @Test("remote tmux attach rides the control socket with a tty and runs the script")
    func remoteAttach() {
        let (exe, args) = RemoteCommands.remoteTmuxAttach(
            target: "me@box", controlPath: "/tmp/c", tmuxSocket: "orchestra", script: "tmux -L orchestra attach")
        #expect(exe.hasSuffix("ssh"))
        #expect(args.contains("-S")); #expect(args.contains("/tmp/c"))
        #expect(args.contains("-tt"))                                  // force a pty for tmux
        #expect(args.contains("me@box"))
        #expect(args.contains { $0.contains("tmux -L orchestra attach") })
    }

    @Test("socketPathFits rejects paths at/over the sun_path cap")
    func fits() {
        #expect(RemoteCommands.socketPathFits("/tmp/orch-abcd1234/s"))
        #expect(!RemoteCommands.socketPathFits(String(repeating: "x", count: 120)))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RemoteCommands 2>&1 | tail -15`
Expected: FAIL — `RemoteCommands` does not exist.

- [ ] **Step 3: Implement `RemoteCommands.swift`**

```swift
import Foundation

/// Pure argv builders for SSH connection multiplexing. No process spawning here (that lives in the app's
/// SSHMaster) so the command shape is unit-tested. One master `ssh -M` owns the control socket; the
/// forwarded local UDS carries the JSON-RPC, and terminals attach over the SAME control socket (`-S`),
/// so auth happens once on the master and everything else multiplexes over it.
public enum RemoteCommands {
    private static let commonOpts = [
        "-o", "BatchMode=yes",              // key-only; never prompt for a password inside the app
        "-o", "ServerAliveInterval=15",     // detect a dead link within ~45s
        "-o", "ServerAliveCountMax=3",
        "-o", "ExitOnForwardFailure=yes",   // fail fast if the -L forward can't be set up
    ]

    public static func sshMasterArgs(target: String, identityFile: String?, controlPath: String,
                                     localSocketPath: String, remoteSocketPath: String) -> [String] {
        var a = ["ssh", "-M", "-S", controlPath, "-N",
                 "-L", "\(localSocketPath):\(remoteSocketPath)"]
        a += commonOpts
        if let id = identityFile, !id.isEmpty { a += ["-i", id] }
        a.append(target)
        return a
    }

    public static func sshExitArgs(target: String, controlPath: String) -> [String] {
        ["ssh", "-S", controlPath, "-O", "exit", target]
    }

    public static func remoteTmuxAttach(target: String, controlPath: String, tmuxSocket: String,
                                        script: String) -> (executable: String, args: [String]) {
        // Ride the existing master (-S) — no new auth, no new forward. -tt forces a pty so tmux attaches.
        let args = ["-S", controlPath, "-tt"] + commonOpts + [target, "/bin/sh", "-c", script]
        return ("/usr/bin/ssh", args)
    }

    /// sun_path is ~104 bytes incl. NUL; keep a margin.
    public static func socketPathFits(_ path: String) -> Bool { path.utf8.count < 100 }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RemoteCommands 2>&1 | tail -15`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/RemoteCommands.swift Tests/OrchestraCoreTests/RemoteCommandsTests.swift
git commit -m "feat(core): pure SSH multiplexing command builders + tests"
```

---

### Task D2: `SSHMaster` — spawn + supervise the master ssh (app)

**Files:**
- Create: `App/SSHMaster.swift`

**Interfaces:**
- Consumes: `RemoteCommands` (D1).
- Produces:

```swift
final class SSHMaster {
    init(connection: Connection)                         // requires .remote
    var controlPath: String { get }
    var localSocketPath: String { get }
    var onUnexpectedExit: (() -> Void)?
    func start() async throws                            // cleanup → spawn -M -N -L → wait for local socket
    func stop()                                          // -O exit → terminate → unlink temp files
}
```

App-only; verified by build + live run. Uses `Foundation.Process` (macOS) for the child; no `-f` so the Process handle is retained and `terminationHandler` fires on death.

- [ ] **Step 1: Implement `SSHMaster.swift`**

```swift
import Foundation
import OrchestraCore

/// Owns one multiplexed master ssh for a remote connection. Foreground child (no -f) so we get exit
/// callbacks and can kill it cleanly. Pre-spawn cleanup removes a stale control socket / forwarded
/// socket left by a crash, then waits (bounded) for the forwarded local socket to appear.
final class SSHMaster {
    private let connection: Connection
    private let dir: URL
    let controlPath: String
    let localSocketPath: String
    private var process: Process?
    var onUnexpectedExit: (() -> Void)?
    private var stopping = false

    init(connection: Connection) {
        self.connection = connection
        // Short unique dir under the system temp so both UDS paths stay well under sun_path (~104).
        let short = String(UUID().uuidString.prefix(8)).lowercased()
        self.dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orch-\(short)", isDirectory: true)
        self.controlPath = dir.appendingPathComponent("c").path
        self.localSocketPath = dir.appendingPathComponent("s").path
    }

    func start() async throws {
        guard let target = connection.sshTarget, let remoteSock = connection.remoteSocketPath else {
            throw OrchestraError.io("remote connection missing sshTarget/remoteSocketPath")
        }
        guard RemoteCommands.socketPathFits(localSocketPath), RemoteCommands.socketPathFits(controlPath) else {
            throw OrchestraError.io("tunnel socket path too long for AF_UNIX")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Pre-spawn cleanup: best-effort close any stale master, unlink stale sockets.
        _ = try? Proc.run(RemoteCommands.sshExitArgs(target: target, controlPath: controlPath))
        try? FileManager.default.removeItem(atPath: controlPath)
        try? FileManager.default.removeItem(atPath: localSocketPath)

        let argv = RemoteCommands.sshMasterArgs(
            target: target, identityFile: connection.identityFile, controlPath: controlPath,
            localSocketPath: localSocketPath, remoteSocketPath: remoteSock)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = Array(argv.dropFirst())            // drop "ssh"; executableURL is ssh
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Proc.augmentedPATH(env["PATH"])    // find ssh under a GUI-launched minimal PATH
        p.environment = env
        p.terminationHandler = { [weak self] _ in
            guard let self, !self.stopping else { return }
            self.onUnexpectedExit?()
        }
        try p.run()
        process = p

        // Wait (bounded) for the forwarded local socket to appear.
        for _ in 0..<100 {                               // ~10s
            if FileManager.default.fileExists(atPath: localSocketPath) { return }
            if !p.isRunning { throw OrchestraError.io("ssh master exited before forwarding the socket") }
            try? await _Concurrency.Task.sleep(for: .milliseconds(100))
        }
        throw OrchestraError.io("timed out waiting for the forwarded socket")
    }

    func stop() {
        stopping = true
        if let target = connection.sshTarget {
            _ = try? Proc.run(RemoteCommands.sshExitArgs(target: target, controlPath: controlPath))
        }
        process?.terminate()
        process = nil
        try? FileManager.default.removeItem(at: dir)
    }
}
```

- [ ] **Step 2: Verify the app builds**

Run: `scripts/build-app.sh 2>&1 | tail -15`
Expected: app builds.

- [ ] **Step 3: Commit**

```bash
git add App/SSHMaster.swift
git commit -m "feat(app): SSHMaster — spawn/supervise multiplexed master ssh with cleanup"
```

---

### Task D3: Wire `ConnectionController.remote` through `SSHMaster`

**Files:**
- Modify: `App/ConnectionController.swift`

**Interfaces:**
- Consumes: `SSHMaster`.
- Produces: the `.remote` branch of `localSocketPath(for:)` now starts a master and returns its `localSocketPath`; unexpected master exit calls `onTunnelExit`; `deactivate()` stops the master.

- [ ] **Step 1: Implement the remote branch**

Replace the `.remote` case + `deactivate` in `ConnectionController`:

```swift
    private var sshMaster: SSHMaster?

    func localSocketPath(for conn: Connection) async throws -> String {
        switch conn.kind {
        case .local:
            state = .live
            return Config.socketPath
        case .remote:
            state = .connecting
            let m = SSHMaster(connection: conn)
            m.onUnexpectedExit = { [weak self] in
                _Concurrency.Task { @MainActor in
                    self?.state = .retrying
                    self?.onTunnelExit?()            // triggers a client-side reconnect; controller-level respawn below
                }
            }
            try await m.start()
            sshMaster = m
            state = .live
            return m.localSocketPath
        }
    }

    func deactivate() {
        sshMaster?.stop(); sshMaster = nil
        state = .down
    }

    /// Current control socket + tmux socket for the active remote (nil for local) — used by terminals.
    var terminalHost: (controlPath: String, target: String)? {
        guard let m = sshMaster, let t = m.connectionTarget else { return nil }
        return (m.controlPath, t)
    }
```

Add a `var connectionTarget: String?` to `SSHMaster` returning `connection.sshTarget` (so the controller can expose the terminal host without re-reading the store).

For master respawn on death: in `BoardModel.activate`, set `connectionController.onTunnelExit` to re-run `activate(conn)` for the current remote (which stops the dead master and starts a fresh one, then the client reconnects to the new forwarded socket). Guard against reentrancy with a simple in-flight flag.

- [ ] **Step 2: Verify the app builds**

Run: `scripts/build-app.sh 2>&1 | tail -15`
Expected: app builds.

- [ ] **Step 3: Commit**

```bash
git add App/ConnectionController.swift App/SSHMaster.swift
git commit -m "feat(app): remote activation spins the SSH master + exposes terminal host"
```

---

### Task D4: Remote terminals in `AgentTerminalView`

**Files:**
- Modify: `App/Views/AgentTerminalView.swift`
- Modify: `App/Views/InspectorView.swift`, `App/Views/ShellTabsView.swift`
- Modify: `App/BoardModel.swift` (expose the active terminal host)

**Interfaces:**
- Consumes: `RemoteCommands.remoteTmuxAttach`, `ConnectionController.terminalHost`.
- Produces: `AgentTerminalView` gains `var host: TerminalHost` (`enum TerminalHost { case local; case remote(controlPath: String, sshTarget: String) }`); the child command is local `/bin/sh -c <script>` or remote `ssh -S ctrl -tt target /bin/sh -c <script>`. The grouped-view-session `attachScript()` is unchanged (it runs on the remote tmux socket for remote).

- [ ] **Step 1: Add `TerminalHost` + branch the child command**

In `AgentTerminalView.swift`, add the enum and a `host` property (default `.local` so existing call sites keep compiling). In `attach(_:)`, replace the fixed `startProcess(executable: "/bin/sh", args: ["-c", attachScript()], …)` with a host branch:

```swift
        switch host {
        case .local:
            term.startProcess(executable: "/bin/sh", args: ["-c", attachScript()], environment: envArray)
        case let .remote(controlPath, sshTarget):
            let (exe, args) = RemoteCommands.remoteTmuxAttach(
                target: sshTarget, controlPath: controlPath, tmuxSocket: socket, script: attachScript())
            term.startProcess(executable: exe, args: args, environment: envArray)
        }
```

`attachScript()` already uses `socket` (the tmux `-L` name) — for remote, pass the connection's `remoteTmuxSocket` as `socket` when constructing the view, so the grouped-view-session commands target the remote tmux server. No change to the script body.

- [ ] **Step 2: Expose the active terminal host on BoardModel + thread it through**

In `BoardModel`, add:

```swift
    /// Terminal host for the active connection: local for the built-in, else the live SSH control socket.
    var terminalHost: AgentTerminalView.TerminalHost {
        if let h = connectionController.terminalHost { return .remote(controlPath: h.controlPath, sshTarget: h.target) }
        return .local
    }
    var terminalTmuxSocket: String { connections.active.remoteTmuxSocket }
```

In `InspectorView.swift` (line ~318) and `ShellTabsView.swift` (line ~33), pass `host: model.terminalHost` and `socket: model.terminalTmuxSocket` into `AgentTerminalView(...)`. Keep the `.id(...)` keys but include the connection id so switching connections tears down + re-attaches the terminal against the new host (e.g. `.id("\(model.connections.activeId)-\(task.tmuxSession)")`).

- [ ] **Step 3: Verify the app builds**

Run: `scripts/build-app.sh 2>&1 | tail -15`
Expected: app builds; local terminals behave exactly as before (default `.local`).

- [ ] **Step 4: Commit**

```bash
git add App/Views/AgentTerminalView.swift App/Views/InspectorView.swift App/Views/ShellTabsView.swift App/BoardModel.swift
git commit -m "feat(app): remote SwiftTerm terminals over the multiplexed SSH control socket"
```

---

### Task D5: End-to-end remote verification

**Files:** none (verification only).

- [ ] **Step 1: Deploy a daemon to a Linux box (or a local Linux container/VM)**

Using A7's build: `scripts/build-linux-daemon.sh && scripts/deploy-linux-daemon.sh <user@host>`. Note the printed remote socket path.

- [ ] **Step 2: Add a remote connection in the app + Connect**

Launch the app, Settings → Connections → Add: name, `<user@host>`, identity file (if any), the remote socket path, tmux socket `orchestra`. Select it active → Connect. Expected: status chip → Connecting → Connected; the board shows the remote daemon's cards (spawn one on the box and watch it appear).

- [ ] **Step 3: Terminal attach over the tunnel**

Open a card's inspector → the agent terminal attaches to the remote tmux via the shared control socket; type into it and confirm it drives the remote session. Open a shell tab → same.

- [ ] **Step 4: Tunnel-death → reconnect**

Kill the master ssh (or drop the network briefly). Expected: chip → Reconnecting → Connected; the master respawns, the client re-subscribes, and events resume. Verify no stale-control-socket error on respawn (pre-spawn cleanup handles it).

- [ ] **Step 5: Disconnect + switch back to local**

Settings → select "This Mac" → the remote master is torn down (`ssh -O exit`, temp dir removed) and the board reattaches to the local daemon.

- [ ] **Step 6: Commit any fixes found during E2E, then finalize**

```bash
git add -A && git commit -m "test: end-to-end remote-daemon connection verification + fixes"
```

**⇢ Move the card to `review` once D5 passes (or once A–C are solid and D is verified as far as the available Linux target allows).**

---

## Self-Review notes (spec coverage)

- **A (Linux port):** UDSSocket (A1), Package.swift verify (A7), Config XDG (A2), launchd gate (A3), plus the compile-blockers the spec implies (ControlClient/Server A4, PathResolver/ReportHelper A5, Launcher A6). DoD = A7 cross-build green + macOS green. ✅
- **B (Transport seam + reconnect):** Transport + UDSTransport (B1), client rewire (B2), reconnect/backoff/re-subscribe/observable state (B3) with fake-transport + server-restart tests. ✅
- **C (Connection + settings UI):** Connection (C1), ConnectionStore round-trip (C2), ConnectionController seam (C3), BoardModel rewire targeting the active connection (C4), Connections pane + status chip (C5). ✅
- **D (SSH tunnel + terminals):** pure builders (D1), SSHMaster spawn/supervise/cleanup (D2), remote activation + respawn (D3), remote terminals over the control socket (D4), E2E incl. tunnel-death → reconnect (D5). The spec's optional ensure-daemon-up is intentionally omitted from the baseline (open question resolved: not built now). ✅

## Execution Handoff

The plan is saved to `notes/plans/2026-07-02-remote-daemon-connections.md`. Per the task's process, this card executes the plan **inline** in this session using superpowers:test-driven-development (moving itself plan→impl before starting, impl→review when ready), starting with Workstream A.
