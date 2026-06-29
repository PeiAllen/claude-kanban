# PR1 — Read-only Inspect Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an "Inspect" button to a card's inspector that opens a shell tab and launches a read-only `claude` in the card's worktree — an agent that can read/search/git but physically cannot modify files.

**Architecture:** A pure, testable `ReadOnlyLaunch` helper in `OrchestraCore` builds the read-only settings JSON (deny edit tools + sandbox `denyWrite`) and the launch argv. `OrchestraService.inspect(_:)` opens a shell window in the card's worktree and sends the command. A SwiftUI button in `TerminalHeader` calls it. The launched session is intentionally **untracked** (no `--session-id` reporting hooks) so it never pollutes the owner card's status.

**Tech Stack:** Swift 6 / SwiftPM (`OrchestraCore`), SwiftUI (`App`), tmux, Claude Code CLI.

## Global Constraints

- Throwaway/scratch work goes in `./.scratch/`. (CLAUDE.md)
- (Agent housekeeping only — **not** a code constraint) The implementing agent's own git/commit shell commands avoid `git -C` to keep the Bash allowlist matching; Orchestra's *source* may use any git invocation (`git -C`, `git worktree`, …) freely.
- Core logic is unit-tested via `swift build && swift test`; UI is verified by building the app (`scripts/build-app.sh`) and driving it. (spec §verification)
- This PR touches **no** `Task` schema — it is a shell launcher only.
- Read-only recipe is **default permission mode** (NOT `plan` mode), two locks: `--disallowedTools "Edit" "Write" "MultiEdit" "NotebookEdit"` + sandbox `denyWrite` on the worktree and its git dir, and **no** Orchestra hooks `--settings`.

---

## File Structure

- `Sources/OrchestraCore/Agents/ReadOnlyLaunch.swift` (Create) — pure builder for settings JSON + argv.
- `Tests/OrchestraCoreTests/ReadOnlyLaunchTests.swift` (Create) — unit tests for the builder.
- `Sources/OrchestraCore/OrchestraService.swift` (Modify, near `openShell` ~`:176-187`) — add `inspect(_:)`.
- `Sources/OrchestraCore/Commands.swift` (Modify, near the `shell` command ~`:102`) — register an `inspect` command so CLI/MCP can trigger it too.
- `App/BoardModel.swift` (Modify, near `shell`/`closeShell` ~`:237-253`) — add `inspect(_:)` client call.
- `App/Views/InspectorView.swift` (Modify, `TerminalHeader` ~`:142-189`) — add the Inspect button.

---

### Task 1: `ReadOnlyLaunch` settings JSON

**Files:**
- Create: `Sources/OrchestraCore/Agents/ReadOnlyLaunch.swift`
- Test: `Tests/OrchestraCoreTests/ReadOnlyLaunchTests.swift`

**Interfaces:**
- Produces: `enum ReadOnlyLaunch { static func settingsJSON(cwd: String, gitDir: String?) -> String }` — returns JSON string with `permissions.deny` of the four edit tools and `sandbox.filesystem.denyWrite` covering `cwd` (+ `gitDir` when non-nil).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import OrchestraCore

final class ReadOnlyLaunchTests: XCTestCase {
    func test_settingsJSON_denies_edit_tools_and_denies_writes() throws {
        let json = ReadOnlyLaunch.settingsJSON(cwd: "/wt/foo", gitDir: "/repo/.git/worktrees/foo")
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let perms = obj["permissions"] as! [String: Any]
        XCTAssertEqual(perms["deny"] as! [String], ["Edit", "Write", "MultiEdit", "NotebookEdit"])
        let fs = (obj["sandbox"] as! [String: Any])["filesystem"] as! [String: Any]
        XCTAssertEqual(Set(fs["denyWrite"] as! [String]), ["/wt/foo", "/repo/.git/worktrees/foo"])
    }

    func test_settingsJSON_omits_nil_gitDir() throws {
        let json = ReadOnlyLaunch.settingsJSON(cwd: "/wt/foo", gitDir: nil)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let fs = (obj["sandbox"] as! [String: Any])["filesystem"] as! [String: Any]
        XCTAssertEqual(fs["denyWrite"] as! [String], ["/wt/foo"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReadOnlyLaunchTests`
Expected: FAIL — "cannot find 'ReadOnlyLaunch' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Builds the launch recipe for a read-only `claude`: two independent locks — the edit tools are
/// denied (removed from context) and the OS sandbox forbids writes to the inspected directory (the
/// Bash escape hatch). Default permission mode (no `plan` framing) and NO Orchestra hooks, so the
/// session stays untracked and can't pollute the owner card's status.
enum ReadOnlyLaunch {
    static func settingsJSON(cwd: String, gitDir: String?) -> String {
        let denyWrite = [cwd] + (gitDir.map { [$0] } ?? [])
        let obj: [String: Any] = [
            "permissions": ["deny": ["Edit", "Write", "MultiEdit", "NotebookEdit"]],
            "sandbox": ["filesystem": ["denyWrite": denyWrite]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ReadOnlyLaunchTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Agents/ReadOnlyLaunch.swift Tests/OrchestraCoreTests/ReadOnlyLaunchTests.swift
git commit -m "feat(core): ReadOnlyLaunch.settingsJSON — deny edit tools + sandbox denyWrite"
```

---

### Task 2: `ReadOnlyLaunch` argv + git-dir derivation

**Files:**
- Modify: `Sources/OrchestraCore/Agents/ReadOnlyLaunch.swift`
- Test: `Tests/OrchestraCoreTests/ReadOnlyLaunchTests.swift`

**Interfaces:**
- Consumes: `settingsJSON(cwd:gitDir:)` from Task 1.
- Produces:
  - `static func gitDir(repo: String, worktreeName: String) -> String` → `"\(repo)/.git/worktrees/\(worktreeName)"`.
  - `static func argv(binary: String, settingsPath: String) -> [String]` → `[binary, "--disallowedTools", "Edit", "Write", "MultiEdit", "NotebookEdit", "--settings", settingsPath]`.

- [ ] **Step 1: Write the failing test**

```swift
func test_argv_disallows_edit_tools_and_passes_settings() {
    let argv = ReadOnlyLaunch.argv(binary: "claude", settingsPath: "/tmp/ro.json")
    XCTAssertEqual(argv, ["claude", "--disallowedTools", "Edit", "Write", "MultiEdit",
                          "NotebookEdit", "--settings", "/tmp/ro.json"])
}

func test_gitDir_points_into_repo_worktrees() {
    XCTAssertEqual(ReadOnlyLaunch.gitDir(repo: "/r/app", worktreeName: "feature"),
                   "/r/app/.git/worktrees/feature")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReadOnlyLaunchTests`
Expected: FAIL — "type 'ReadOnlyLaunch' has no member 'argv'".

- [ ] **Step 3: Write minimal implementation** (append to the enum)

```swift
extension ReadOnlyLaunch {
    static func gitDir(repo: String, worktreeName: String) -> String {
        "\(repo)/.git/worktrees/\(worktreeName)"
    }

    static func argv(binary: String, settingsPath: String) -> [String] {
        [binary, "--disallowedTools", "Edit", "Write", "MultiEdit", "NotebookEdit",
         "--settings", settingsPath]
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ReadOnlyLaunchTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Agents/ReadOnlyLaunch.swift Tests/OrchestraCoreTests/ReadOnlyLaunchTests.swift
git commit -m "feat(core): ReadOnlyLaunch.argv + gitDir derivation"
```

---

### Task 3: `OrchestraService.inspect(_:)` — open a shell + run read-only claude

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (after `openShell` ~`:176-182`)

**Interfaces:**
- Consumes: `ReadOnlyLaunch.settingsJSON/argv/gitDir`; existing `sessions.newShellWindow(_:cwd:)`, `require(_:)`, the binary from the card's adapter (`registry.get(t.agentId).bin`), and the tmux `send-keys` path used by the existing `send` command (find it via `grep -n "send-keys\|func send" Sources/OrchestraCore/SessionManager.swift`).
- Produces: `func inspect(_ id: UUID) async throws -> ShellTab` — opens a shell window in `t.worktree`, writes the per-card read-only settings to `"\(Config.dataDir)/readonly-\(t.shortId).json"`, and sends the read-only `claude` argv (joined, shell-quoted) + Enter into that window.

- [ ] **Step 1: Add the method** (no unit test — this is tmux I/O; verified manually in Task 6. Wire it carefully against the real `send`/`newShellWindow` signatures.)

```swift
/// Open a shell tab in the card's worktree and launch a READ-ONLY claude in it (default mode,
/// edit tools denied, sandbox denyWrite on the tree + its git dir, NO orchestra hooks → untracked).
/// For "look at this worktree without touching it" without spawning a sibling card.
public func inspect(_ id: UUID) async throws -> ShellTab {
    let t = try await require(id)
    let bin = (try? registry.get(t.agentId).bin) ?? "claude"
    let name = (t.worktree as NSString).lastPathComponent
    let settings = ReadOnlyLaunch.settingsJSON(
        cwd: t.worktree,
        gitDir: ReadOnlyLaunch.gitDir(repo: t.repo, worktreeName: name))
    let settingsPath = "\(Config.dataDir)/readonly-\(t.shortId).json"
    try settings.write(toFile: settingsPath, atomically: true, encoding: .utf8)

    let session = sessions.sessionName(t.id)
    let win = try sessions.newShellWindow(session, cwd: t.worktree)
    let argv = ReadOnlyLaunch.argv(binary: bin, settingsPath: settingsPath)
    let cmd = argv.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
    try sessions.sendKeys(session, window: win, text: cmd + "\n")   // match the real send-keys method
    await logCommand("inspect", ref: t, source: .daemon)
    return ShellTab(window: win, label: win, pwd: t.worktree)
}
```

> Implementation note: replace `sessions.sendKeys(_:window:text:)` with whatever the existing `send` command calls (e.g. the method behind `Command(name: "send", …)` in `Commands.swift`). Do NOT invent a new tmux path — reuse the one that already delivers keystrokes to a window.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: compiles. Fix the `sendKeys`/`newShellWindow` call to the real signatures if it doesn't.

- [ ] **Step 3: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift
git commit -m "feat(core): OrchestraService.inspect — read-only claude in a worktree shell"
```

---

### Task 4: Register the `inspect` command (CLI/MCP)

**Files:**
- Modify: `Sources/OrchestraCore/Commands.swift` (next to the `shell` command ~`:102-116`)

**Interfaces:**
- Consumes: `svc.inspect(_:)`. Mirror the exact shape of the neighbouring `shell` command (same `ref` param resolution `t`, same `logCommand` pattern — note `inspect` already logs inside the service, so don't double-log; follow whichever the `shell` command does and stay consistent).

- [ ] **Step 1: Add the command** (copy the `shell` command block; swap the call)

```swift
Command(name: "inspect", summary: "Open a read-only claude in the card's worktree shell.",
        args: [.ref]) { p, svc, src in
    let t = try await svc.requireRef(p)            // match how `shell` resolves its ref
    let tab = try await svc.inspect(t.id)
    return .shellTab(tab)                           // match `shell`'s return encoding
}
```

> Match the real `Command` initializer arity and the ref-resolution / return-encoding used by the adjacent `shell` command — read `:102-116` and copy its exact shape.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: compiles.

- [ ] **Step 3: Commit**

```bash
git add Sources/OrchestraCore/Commands.swift
git commit -m "feat(core): register `inspect` command for CLI/MCP"
```

---

### Task 5: `BoardModel.inspect(_:)` client call

**Files:**
- Modify: `App/BoardModel.swift` (next to `shell` ~`:237-253`)

**Interfaces:**
- Consumes: the `inspect` command via `client.call`. Mirror the existing `shell(_:)` client method exactly.
- Produces: `func inspect(_ id: UUID) async` — calls `client.call("inspect", .object(["ref": .string(id.uuidString)]))` and refreshes shell tabs the same way `shell` does.

- [ ] **Step 1: Add the method** (copy `shell(_:)`’s body, change the verb)

```swift
func inspect(_ id: UUID) async {
    _ = try? await client.call("inspect", .object(["ref": .string(id.uuidString)]))
    // then refresh the inspector's shell tabs exactly as `shell(_:)` does
}
```

- [ ] **Step 2: Build the app**

Run: `swift build` (and `scripts/build-app.sh` when wiring the view in Task 6)
Expected: compiles.

- [ ] **Step 3: Commit**

```bash
git add App/BoardModel.swift
git commit -m "feat(app): BoardModel.inspect client call"
```

---

### Task 6: Inspect button in `TerminalHeader`

**Files:**
- Modify: `App/Views/InspectorView.swift` (`TerminalHeader` ~`:142-189`, alongside `StatusPill`)

**Interfaces:**
- Consumes: `model.inspect(_:)`; `@EnvironmentObject var model: BoardModel`; `@Environment(\.theme)`. `TerminalHeader` is already in the inspector hierarchy.

- [ ] **Step 1: Add the button** (place before/after `StatusPill` in the header `HStack`)

```swift
Button {
    _Concurrency.Task { await model.inspect(task.id) }
} label: {
    Image(systemName: "eye")
        .font(F.mono(10.5))
        .foregroundColor(theme.text2)
}
.buttonStyle(.plain)
.help("Open a read-only agent in this worktree (can read/search/git, cannot edit)")
```

> If `TerminalHeader` doesn't yet hold `@EnvironmentObject var model: BoardModel`, add it (it's already in the environment via the inspector). Match the surrounding chip/button styling.

- [ ] **Step 2: Build + launch the app**

Run: `scripts/build-app.sh` then launch (background screenshot-by-window-id per project memory).
Expected: app builds and shows an eye button in the inspector header.

- [ ] **Step 3: Manual verification**

1. Open a card's inspector; click the eye button.
2. A new shell tab appears; a `claude` starts in it. Confirm it has **no** Edit/Write tools (ask it to edit a file → it reports it can't) and that `sed -i`/`>` into a tracked file is blocked by the sandbox.
3. Confirm the owner card's status/ctxPct is **unaffected** (the inspect session doesn't report).

- [ ] **Step 4: Commit**

```bash
git add App/Views/InspectorView.swift
git commit -m "feat(app): Inspect (read-only) button in the inspector header"
```

---

## Self-Review

- **Spec coverage:** §3 (Mechanism A) — settings recipe (Task 1), argv + git dir (Task 2), shell launch untracked (Task 3), CLI/MCP parity (Task 4), button (Tasks 5–6). ✓
- **Placeholders:** the only deferred details are the real `send-keys`/`newShellWindow`/`Command` signatures, explicitly flagged to copy from existing code (`shell` command + `SessionManager`). No vague "add error handling".
- **Reuse:** PR3's read-only borrowed card reuses `ReadOnlyLaunch` (Tasks 1–2) at the adapter level — keep these signatures stable.
