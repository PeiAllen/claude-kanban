# Configurable Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make macOS notifications configurable per attention-trigger (permission / needs-you / died), each with a focus scope and a sound, and stop the false "needs you" alert when the agent merely yielded to background work.

**Architecture:** The daemon classifies *why* a card entered `.waiting` into a typed `Task.waitReason` (permission vs humanTurn), and suppresses the waiting transition entirely when a Claude `Stop` carried pending `background_tasks`/`session_crons` (the card stays `.running`). The macOS app's `AgentNotifier` reads that reason plus `.dead` transitions and posts a `UNNotificationRequest` per a three-row, per-trigger settings table (scope + sound), with sound set on `content.sound` (no separate audio player).

**Tech Stack:** Swift 6, SwiftPM (`OrchestraCore`, `orchestra` CLI) + a macOS SwiftUI/AppKit app target (`App/`), Swift Testing (`import Testing`, `@Test`/`#expect`), `UserNotifications`.

## Global Constraints

- **Design source of truth:** `notes/designs/2026-07-03-configurable-notifications-design.md`.
- **Cross-platform core:** `OrchestraCore` also cross-compiles to Linux (musl). It **must not** import `AppKit`/`UserNotifications`. All notification/AppKit code stays in `App/`.
- **No `-C` flag on git** (user global rule): rely on cwd.
- **Three triggers:** `permission`, `needsYou`, `died`. Scope ∈ `off | background | always`. Sound ∈ `default | none | <one of 14 built-in macOS sound names>`.
- **Defaults:** permission → `always` / `Hero`; needsYou → `background` / `Submarine`; died → `always` / `Basso`. Applied via `object(forKey:) ?? default`.
- **UserDefaults keys:** `orch_notify_<trigger>_scope`, `orch_notify_<trigger>_sound` where `<trigger>` ∈ `permission | needsYou | died`.
- **Background-wait rule (option A):** a Claude `Stop` whose payload has a non-empty `background_tasks` **or** non-empty `session_crons` array → `parse` returns `nil` (no status change; card stays `.running`; no alert).
- **Build/test commands:** package tests `swift test`; app build `scripts/build-app.sh`; isolated UI screenshot `scripts/orch-ui-shot.sh`. Run `swift build` for a quick core compile check.
- **14 built-in sounds** (from `/System/Library/Sounds`): Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi, Submarine, Tink.

---

## Task 1: `WaitReason` enum + `Task.waitReason` field (core model)

**Files:**
- Modify: `Sources/OrchestraCore/Model.swift` (add enum near `AgentStatus` ~line 19; add field + Codable to `Task` ~lines 183–320)
- Test: `Tests/OrchestraCoreTests/ReportTests.swift` (add a Codable round-trip test)

**Interfaces:**
- Produces: `public enum WaitReason: String, Codable, Sendable { case permission, humanTurn }`; `Task.waitReason: WaitReason?` (defaults `nil`).

- [ ] **Step 1: Write the failing test** — append to the `ReportTests` struct in `Tests/OrchestraCoreTests/ReportTests.swift`:

```swift
    @Test("Task encodes/decodes waitReason round-trip; absent decodes to nil")
    func waitReasonCodable() async throws {
        let (_, t) = try await spawned()
        var card = t
        card.waitReason = .permission
        let data = try JSONEncoder().encode(card)
        let back = try JSONDecoder().decode(Task.self, from: data)
        #expect(back.waitReason == .permission)
        // Legacy JSON without the key decodes to nil (no crash).
        let legacy = try JSONEncoder().encode(t)          // t.waitReason is nil already
        #expect(try JSONDecoder().decode(Task.self, from: legacy).waitReason == nil)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ReportTests/waitReasonCodable`
Expected: FAIL to compile — `Task` has no member `waitReason`.

- [ ] **Step 3: Add the enum.** In `Sources/OrchestraCore/Model.swift`, immediately after the `AgentStatus` enum (~line 20) add:

```swift
/// Why a card is `.waiting` — set with `status = .waiting`, cleared when status leaves `.waiting`.
/// Drives which notification trigger the app fires. `.died` is a separate transition (see `deadReason`).
public enum WaitReason: String, Codable, Sendable {
    case permission   // agent blocked on tool approval (Claude Notification/permission_prompt)
    case humanTurn    // agent genuinely finished its turn / idle, waiting on the human
}
```

- [ ] **Step 4: Add the stored property + Codable.** In `Sources/OrchestraCore/Model.swift`:
  - Add the property after `deadDetail` (~line 185): `public var waitReason: WaitReason?  // set with status=.waiting; cleared when status leaves .waiting`
  - Add an init parameter after `deadDetail: String? = nil,` (~line 212): `waitReason: WaitReason? = nil,`
  - Add the assignment after `self.deadDetail = deadDetail` (~line 239): `self.waitReason = waitReason`
  - Add to `init(from:)` after the `deadDetail` decode (~line 271): `self.waitReason = try c.decodeIfPresent(WaitReason.self, forKey: .waitReason)`
  - Add to `encode(to:)` after the `deadDetail` encode (~line 304): `try c.encodeIfPresent(waitReason, forKey: .waitReason)`
  - Add `waitReason` to the `CodingKeys` list (~line 318, alongside `deadReason, deadDetail`).

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter ReportTests/waitReasonCodable`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/Model.swift Tests/OrchestraCoreTests/ReportTests.swift
git commit -m "feat(model): add WaitReason enum + Task.waitReason field"
```

---

## Task 2: `waitReason` passthrough on the status channel

**Files:**
- Modify: `Sources/OrchestraCore/Model.swift` — `SnapshotReport` (~lines 440–459) and the flat `StatusReport` init (~lines 496–511)
- Test: `Tests/OrchestraCoreTests/ReportTests.swift`

**Interfaces:**
- Consumes: `WaitReason` (Task 1).
- Produces: `SnapshotReport.waitReason: WaitReason?`; `StatusReport(... , waitReason: WaitReason? = nil)` routes it into the snapshot bucket.

- [ ] **Step 1: Write the failing test** — append to `ReportTests`:

```swift
    @Test("StatusReport routes waitReason into the snapshot bucket")
    func waitReasonRoutes() {
        let r = StatusReport(status: .waiting, waitReason: .permission)
        #expect(r.snapshot?.waitReason == .permission)
        #expect(r.snapshot?.status == .waiting)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ReportTests/waitReasonRoutes`
Expected: FAIL to compile — `SnapshotReport` has no `waitReason`; `StatusReport` init has no `waitReason:`.

- [ ] **Step 3: Add `waitReason` to `SnapshotReport`.** In `Sources/OrchestraCore/Model.swift`:
  - Property after `desc` (~line 449): `public var waitReason: WaitReason?`
  - Init param after `desc: String? = nil,` (~line 454): `waitReason: WaitReason? = nil,`
  - Assignment in the init body (~line 458): append `self.waitReason = waitReason`

- [ ] **Step 4: Thread it through the flat `StatusReport` init** (~lines 496–511):
  - Add param after `desc: String? = nil,`: `waitReason: WaitReason? = nil,`
  - Include it in the `hasSnapshot` predicate: add `|| waitReason != nil`
  - Pass it into the `SnapshotReport(...)` call: add `waitReason: waitReason,`

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter ReportTests/waitReasonRoutes`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/Model.swift Tests/OrchestraCoreTests/ReportTests.swift
git commit -m "feat(model): thread waitReason through StatusReport/SnapshotReport"
```

---

## Task 3: `report()` sets/clears `task.waitReason`

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Report.swift` (snapshot status-apply block ~lines 91–95; clear block ~lines 98–100)
- Test: `Tests/OrchestraCoreTests/ReportTests.swift`

**Interfaces:**
- Consumes: `SnapshotReport.waitReason` (Task 2).
- Produces: after `report(...)`, `task.waitReason` is set iff `task.status == .waiting`.

- [ ] **Step 1: Write the failing test** — append to `ReportTests`:

```swift
    @Test("report sets waitReason on a waiting snapshot and clears it when status leaves waiting")
    func waitReasonLifecycle() async throws {
        let (env, t) = try await spawned()
        try await env.svc.report(t.id, StatusReport(status: .waiting, waitReason: .permission))
        var after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.status == .waiting)
        #expect(after.waitReason == .permission)
        // Leaving waiting (→ running) clears it.
        try await env.svc.report(t.id, StatusReport(status: .running))
        after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.waitReason == nil)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ReportTests/waitReasonLifecycle`
Expected: FAIL — `after.waitReason` is `nil` after the first report (not yet applied).

- [ ] **Step 3: Set it in the status-apply block.** In `Sources/OrchestraCore/OrchestraService+Report.swift`, the block (~lines 91–95) currently reads:

```swift
                if let s = snap.status, task.status != .dead {
                    if s != task.status { statusTransition = statusTransition ?? (task.status, s) }
                    task.status = s
                }
```

Replace with:

```swift
                if let s = snap.status, task.status != .dead {
                    if s != task.status { statusTransition = statusTransition ?? (task.status, s) }
                    task.status = s
                    if s == .waiting { task.waitReason = snap.waitReason }
                }
```

- [ ] **Step 4: Clear it when not waiting.** After the "Clear dead metadata" block (~lines 98–100), add:

```swift
        // waitReason is meaningful only while waiting.
        if task.status != .waiting { task.waitReason = nil }
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter ReportTests/waitReasonLifecycle`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Report.swift Tests/OrchestraCoreTests/ReportTests.swift
git commit -m "feat(report): set/clear task.waitReason on status change"
```

---

## Task 4: Classify the Claude `notify` event (permission / humanTurn / background-suppress)

**Files:**
- Modify: `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift` — the `case "notify":` branch (~lines 71–72)
- Test: `Tests/OrchestraCoreTests/ReportTests.swift` (direct `parse` calls)

**Interfaces:**
- Consumes: `StatusReport(... waitReason:)` (Task 2).
- Produces: `ClaudeCodeAdapter().parse(.hooksPush(kind: "notify", payload:))` →
  - `Notification`+`permission_prompt` → `.waiting`/`.permission`
  - `Notification`+other (e.g. `idle_prompt`) → `.waiting`/`.humanTurn`
  - `Stop` with empty/absent `background_tasks` & `session_crons` → `.waiting`/`.humanTurn`
  - `Stop` with non-empty `background_tasks` **or** `session_crons` → `nil`

- [ ] **Step 1: Write the failing tests** — append to `ReportTests`:

```swift
    private func notify(_ json: String) -> StatusReport? {
        let p = (try? JSONValue.parse(Data(json.utf8))) ?? .object([:])
        return ClaudeCodeAdapter().parse(.hooksPush(kind: "notify", payload: p))
    }

    @Test("Notification permission_prompt → waiting/.permission")
    func classifyPermission() {
        let r = notify(#"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#)
        #expect(r?.snapshot?.status == .waiting)
        #expect(r?.snapshot?.waitReason == .permission)
        #expect(r?.snapshot?.desc == "Claude needs your permission to use Bash")
    }

    @Test("Notification idle_prompt → waiting/.humanTurn")
    func classifyIdle() {
        let r = notify(#"{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#)
        #expect(r?.snapshot?.status == .waiting)
        #expect(r?.snapshot?.waitReason == .humanTurn)
    }

    @Test("Stop with no background work → waiting/.humanTurn")
    func classifyStopIdle() {
        let r = notify(#"{"hook_event_name":"Stop","background_tasks":[],"session_crons":[]}"#)
        #expect(r?.snapshot?.status == .waiting)
        #expect(r?.snapshot?.waitReason == .humanTurn)
    }

    @Test("Stop with pending background_tasks → nil (no status change)")
    func classifyStopBackgroundTasks() {
        let r = notify(#"{"hook_event_name":"Stop","background_tasks":[{"id":"t1","type":"shell","status":"running"}],"session_crons":[]}"#)
        #expect(r == nil)
    }

    @Test("Stop with pending session_crons → nil (no status change)")
    func classifyStopCrons() {
        let r = notify(#"{"hook_event_name":"Stop","background_tasks":[],"session_crons":[{"id":"c1","schedule":"*/5 * * * *"}]}"#)
        #expect(r == nil)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ReportTests/classify`
Expected: FAIL — current parse ignores `hook_event_name`, always returns `.waiting` with no `waitReason` (and never `nil` for a Stop).

- [ ] **Step 3: Implement the classification.** In `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift`, replace the `case "notify":` branch (~lines 71–72):

```swift
        case "notify":
            return StatusReport(desc: p["message"]?.stringValue, status: .waiting)
```

with:

```swift
        case "notify":
            // Both the Notification and Stop hooks arrive here (claude-hooks.json wires both to
            // `--event notify`); `hook_event_name` distinguishes them.
            let event = p["hook_event_name"]?.stringValue
            if event == "Stop" {
                // A turn that yielded to await background work (a run_in_background shell, a background
                // subagent, a /loop or scheduled wake) will AUTO-RESUME — the human isn't needed. Leave
                // the card running (return nil) so it neither flips to waiting nor alerts. (background_tasks
                // / session_crons are Claude Code v2.1.145+; absent on older builds → treated as empty.)
                let hasBg = (p["background_tasks"]?.arrayValue?.isEmpty == false)
                    || (p["session_crons"]?.arrayValue?.isEmpty == false)
                if hasBg { return nil }
                return StatusReport(status: .waiting, waitReason: .humanTurn)
            }
            // Notification hook: permission_prompt is the only "you're blocking me" case; everything
            // else (idle_prompt, …) is a genuine human-turn wait.
            let reason: WaitReason = p["notification_type"]?.stringValue == "permission_prompt"
                ? .permission : .humanTurn
            return StatusReport(desc: p["message"]?.stringValue, status: .waiting, waitReason: reason)
```

**Note:** verify `JSONValue` exposes `arrayValue: [JSONValue]?` and `stringValue: String?` (used elsewhere in this file, e.g. `tool_input`). If the array accessor differs, use the project's equivalent (grep `arrayValue` / `.array` in `Sources/OrchestraCore`).

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter ReportTests/classify`
Expected: PASS (all five).

- [ ] **Step 5: Guard the existing suite** — the message/desc still flows for permission/idle.

Run: `swift test --filter ReportTests`
Expected: PASS (no regressions).

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift Tests/OrchestraCoreTests/ReportTests.swift
git commit -m "feat(adapter): classify notify into permission/humanTurn + suppress background-wait Stop"
```

---

## Task 5: Codex `turncomplete` → `.humanTurn`

**Files:**
- Modify: `Sources/OrchestraCore/Agents/CodexAdapter.swift` (~line 81–83)
- Test: `Tests/OrchestraCoreTests/CodexRolloutTests.swift`

**Interfaces:**
- Consumes: `StatusReport(... waitReason:)` (Task 2).
- Produces: Codex `turncomplete`/`taskcomplete` rollout line → `.waiting`/`.humanTurn`.

- [ ] **Step 1: Write the failing test** — append a test to `CodexRolloutTests` (it already has `private func tail(_ s: String) -> StatusReport? { a.parse(.fileTail(line: s)) }`):

```swift
    @Test("turn complete → waiting with humanTurn reason")
    func turnCompleteHumanTurn() {
        let r = tail(#"{"type":"turn_complete"}"#)
        #expect(r?.snapshot?.status == .waiting)
        #expect(r?.snapshot?.waitReason == .humanTurn)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter CodexRolloutTests/turnCompleteHumanTurn`
Expected: FAIL — `waitReason` is `nil` (not yet set).

- [ ] **Step 3: Set the reason.** In `Sources/OrchestraCore/Agents/CodexAdapter.swift`, the block (~lines 81–83):

```swift
        if any("turncomplete", "taskcomplete") {
            return StatusReport(seq: seq, status: .waiting)
        }
```

becomes:

```swift
        if any("turncomplete", "taskcomplete") {
            // Codex has no permission hook and no background-yield/auto-resume pattern (subagents run
            // synchronously; background shells poll in-turn), so a completed turn is a genuine human-wait.
            return StatusReport(seq: seq, status: .waiting, waitReason: .humanTurn)
        }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter CodexRolloutTests/turnCompleteHumanTurn`
Expected: PASS.

- [ ] **Step 5: Full core suite green**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/Agents/CodexAdapter.swift Tests/OrchestraCoreTests/CodexRolloutTests.swift
git commit -m "feat(codex): tag turn-complete waiting as humanTurn"
```

---

## Task 6: Rewrite `AgentNotifier` — per-trigger scope + sound table

**Files:**
- Modify (rewrite): `App/AgentNotifier.swift`

> App-target file: not covered by `swift test`. The firing logic is kept as trivial pure expressions (verified by inspection + the Task 9 live smoke). Build-verify each step.

**Interfaces:**
- Consumes: `Task.waitReason` (Task 1).
- Produces:
  - `enum NotifyTrigger: String { case permission, needsYou, died }`
  - `enum NotifyScope: String, CaseIterable { case off, background, always }`
  - `AgentNotifier.notify(_ trigger: NotifyTrigger, task: Task)`
  - static default tables + UserDefaults key helpers reused by `SettingsView` (Task 8):
    `AgentNotifier.scopeKey(_:) / soundKey(_:) / defaultScope(_:) / defaultSound(_:)`
    and `AgentNotifier.soundNames: [String]` (the 14 built-ins).

- [ ] **Step 1: Replace the file** `App/AgentNotifier.swift` with:

```swift
import AppKit
import UserNotifications
import OrchestraCore

/// macOS notifications for cards that need the human. Client-local, driven by `BoardModel.apply`
/// observing the daemon event stream. Three independently-configurable triggers, each with a focus
/// **scope** (off / background / always) and a **sound** (default / none / a named system sound). The
/// sound rides on the notification's own `content.sound` — no separate audio player.
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {

    enum NotifyTrigger: String { case permission, needsYou, died }
    enum NotifyScope: String, CaseIterable { case off, background, always }

    /// The 14 built-in macOS sounds (files in /System/Library/Sounds), resolvable by name.
    static let soundNames = ["Basso","Blow","Bottle","Frog","Funk","Glass","Hero","Morse",
                             "Ping","Pop","Purr","Sosumi","Submarine","Tink"]

    static func scopeKey(_ t: NotifyTrigger) -> String { "orch_notify_\(t.rawValue)_scope" }
    static func soundKey(_ t: NotifyTrigger) -> String { "orch_notify_\(t.rawValue)_sound" }

    static func defaultScope(_ t: NotifyTrigger) -> NotifyScope {
        switch t { case .permission: return .always; case .needsYou: return .background; case .died: return .always }
    }
    /// `"default"` (system) / `"none"` (silent) / a name from `soundNames`.
    static func defaultSound(_ t: NotifyTrigger) -> String {
        switch t { case .permission: return "Hero"; case .needsYou: return "Submarine"; case .died: return "Basso" }
    }

    /// Wired by `BoardModel`: select a card when its banner is clicked.
    var onSelect: ((UUID) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ask once for permission to post banners + play sound. Safe to call every launch.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - firing

    /// A trigger fired for `task`. Decide whether to surface it (per scope + app focus) and, if so,
    /// post a macOS notification with the trigger's configured sound.
    func notify(_ trigger: NotifyTrigger, task: Task) {
        guard Self.shouldFire(scope(for: trigger), isActive: NSApp.isActive) else { return }
        let content = UNMutableNotificationContent()
        content.title = task.title
        content.body = Self.body(for: trigger)
        content.sound = Self.sound(forPref: soundPref(for: trigger))
        content.userInfo = ["taskId": task.id.uuidString]
        let req = UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - pure decision helpers

    static func shouldFire(_ scope: NotifyScope, isActive: Bool) -> Bool {
        switch scope { case .off: return false; case .always: return true; case .background: return !isActive }
    }

    /// Map a stored sound pref to a notification sound. `default` → system; `none` → silent; else a
    /// named built-in (resolved from the Sounds search paths, which include /System/Library/Sounds).
    static func sound(forPref pref: String) -> UNNotificationSound? {
        switch pref {
        case "none": return nil
        case "default": return .default
        default: return UNNotificationSound(named: UNNotificationSoundName("\(pref).aiff"))
        }
    }

    static func body(for trigger: NotifyTrigger) -> String {
        switch trigger {
        case .permission: return "Agent needs your approval"
        case .needsYou:   return "Agent finished — waiting on you"
        case .died:       return "Agent session ended — needs recovery"
        }
    }

    // MARK: - prefs

    private func scope(for t: NotifyTrigger) -> NotifyScope {
        let raw = UserDefaults.standard.string(forKey: Self.scopeKey(t))
        return raw.flatMap(NotifyScope.init(rawValue:)) ?? Self.defaultScope(t)
    }
    private func soundPref(for t: NotifyTrigger) -> String {
        UserDefaults.standard.string(forKey: Self.soundKey(t)) ?? Self.defaultSound(t)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show (and chime) even when Orchestra is frontmost — needed for scope `.always`. A `nil`
    /// `content.sound` (pref `none`) yields a silent foreground banner via the same path.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Banner clicked → bring Orchestra forward and select the card.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let idStr = response.notification.request.content.userInfo["taskId"] as? String
        _Concurrency.Task { @MainActor [weak self] in
            if let idStr, let id = UUID(uuidString: idStr) {
                NSApp.activate(ignoringOtherApps: true)
                self?.onSelect?(id)
            }
        }
        completionHandler()
    }
}
```

- [ ] **Step 2: Build the app to verify it compiles**

Run: `scripts/build-app.sh`
Expected: build succeeds. (If the script is slow, `swift build` won't cover `App/`; the app build is required here.)

- [ ] **Step 3: Commit**

```bash
git add App/AgentNotifier.swift
git commit -m "feat(app): per-trigger scope+sound AgentNotifier, macOS-sound based"
```

---

## Task 7: Route waiting(reason) + dead transitions in `BoardModel`

**Files:**
- Modify: `App/BoardModel.swift` (the `.taskUpserted` transition block ~lines 283–286)

**Interfaces:**
- Consumes: `AgentNotifier.notify(_:task:)` (Task 6), `Task.waitReason` (Task 1).

- [ ] **Step 1: Replace the transition block.** In `App/BoardModel.swift`, the block (~lines 283–286):

```swift
                // A genuine non-waiting → waiting transition: the agent's turn ended, it needs you.
                if let prev, prev != .waiting, t.status == .waiting {
                    notifier.agentBecameWaiting(t)
                }
```

becomes:

```swift
                // Genuine transitions → the matching notification trigger. `prev == nil` (fresh card)
                // and the post-reconnect wholesale set (which bypasses `apply`) never fire.
                if let prev {
                    if prev != .waiting, t.status == .waiting {
                        notifier.notify(t.waitReason == .permission ? .permission : .needsYou, task: t)
                    }
                    if prev != .dead, t.status == .dead {
                        notifier.notify(.died, task: t)
                    }
                }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `scripts/build-app.sh`
Expected: build succeeds; no remaining references to `agentBecameWaiting` (removed in Task 6).

- [ ] **Step 3: Commit**

```bash
git add App/BoardModel.swift
git commit -m "feat(app): route waiting-reason + dead transitions to per-trigger notify"
```

---

## Task 8: Settings UI — three per-trigger rows (scope + sound)

**Files:**
- Modify: `App/Views/SettingsView.swift` — the `@AppStorage` prefs (~lines 17–19) and the `section("Notifications")` block (~lines 81–89)

**Interfaces:**
- Consumes: `AgentNotifier.NotifyTrigger/NotifyScope`, its key + default + `soundNames` helpers (Task 6); reuses the file's existing `menu(_:_:)`, `row(_:_:)`, `rowDivider`, `toggleRow` builders.

- [ ] **Step 1: Remove the old prefs.** In `App/Views/SettingsView.swift` delete (~lines 17–19):

```swift
    // Client-local notification prefs (per-Mac, not daemon config); default on.
    @AppStorage(AgentNotifier.bannerKey) private var notifyBanner = true
    @AppStorage(AgentNotifier.soundKey) private var notifySound = true
```

- [ ] **Step 2: Replace the section.** Replace the `section("Notifications") { … }` block (~lines 81–89) with a data-driven three-row section:

```swift
                section("Notifications") {
                    notifyRow(.permission, "Permission needed",
                              "Alert when an agent is blocked waiting for your approval.")
                    rowDivider
                    notifyRow(.needsYou, "Needs you",
                              "Alert when an agent finishes its turn and is waiting on you. Background waits (a task auto-resuming) don't count.")
                    rowDivider
                    notifyRow(.died, "Card died",
                              "Alert when an agent session crashes or exits and needs recovery.")
                }
```

- [ ] **Step 3: Add the row builder + backing state.** Add near the other `@State`/builders in `SettingsView`. Because `@AppStorage` keys must be literals, read/write `UserDefaults` directly via a `@State` refresh token:

```swift
    // Bump to force a re-read of the per-trigger UserDefaults after a menu pick.
    @State private var notifyTick = 0

    private func notifyRow(_ trigger: AgentNotifier.NotifyTrigger, _ label: String, _ desc: String) -> some View {
        let scope = currentScope(trigger)
        let sound = currentSound(trigger)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(F.ui(12.5, .medium)).foregroundStyle(theme.text)
                Text(desc).font(F.ui(11)).foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            menu(scopeLabel(scope)) {
                ForEach(AgentNotifier.NotifyScope.allCases, id: \.self) { s in
                    Button(scopeLabel(s)) { setScope(trigger, s) }
                }
            }
            menu(soundLabel(sound)) {
                Button("Default") { setSound(trigger, "default") }
                Button("None") { setSound(trigger, "none") }
                Divider()
                ForEach(AgentNotifier.soundNames, id: \.self) { name in
                    Button(name) { setSound(trigger, name); NSSound(named: name)?.play() }
                }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .id(notifyTick)   // re-render this row when a pick lands
    }

    private func currentScope(_ t: AgentNotifier.NotifyTrigger) -> AgentNotifier.NotifyScope {
        UserDefaults.standard.string(forKey: AgentNotifier.scopeKey(t))
            .flatMap(AgentNotifier.NotifyScope.init(rawValue:)) ?? AgentNotifier.defaultScope(t)
    }
    private func currentSound(_ t: AgentNotifier.NotifyTrigger) -> String {
        UserDefaults.standard.string(forKey: AgentNotifier.soundKey(t)) ?? AgentNotifier.defaultSound(t)
    }
    private func setScope(_ t: AgentNotifier.NotifyTrigger, _ s: AgentNotifier.NotifyScope) {
        UserDefaults.standard.set(s.rawValue, forKey: AgentNotifier.scopeKey(t)); notifyTick += 1
    }
    private func setSound(_ t: AgentNotifier.NotifyTrigger, _ name: String) {
        UserDefaults.standard.set(name, forKey: AgentNotifier.soundKey(t)); notifyTick += 1
    }
    private func scopeLabel(_ s: AgentNotifier.NotifyScope) -> String {
        switch s { case .off: return "Off"; case .background: return "Background only"; case .always: return "Always" }
    }
    private func soundLabel(_ s: String) -> String {
        switch s { case "default": return "Default"; case "none": return "None"; default: return s }
    }
```

- [ ] **Step 4: Build the app**

Run: `scripts/build-app.sh`
Expected: build succeeds; no references to `AgentNotifier.bannerKey` / `.soundKey(old)`.

- [ ] **Step 5: Screenshot the Settings panel** (isolated, per the project's UI-check recipe)

Run: `scripts/orch-ui-shot.sh` (open Settings in the isolated instance)
Expected: three notification rows, each with a scope menu + a sound menu. Paste the PNG back for review.

- [ ] **Step 6: Commit**

```bash
git add App/Views/SettingsView.swift
git commit -m "feat(settings): three per-trigger notification rows (scope + sound)"
```

---

## Task 9: End-to-end verification (isolated instance)

**Files:** none (verification only).

- [ ] **Step 1: Full core suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 2: App build clean**

Run: `scripts/build-app.sh`
Expected: build succeeds with no warnings introduced by this change.

- [ ] **Step 3: Live smoke via an isolated instance** (per `orchestra-isolated-testing` / `orchestra-app-dev-loop` memories — never touch the user's live app). Drive an isolated daemon+app and assert:
  - A card flips `running → waiting` (empty `Stop`) → **Needs you** notification with the Submarine sound; with the app **focused** it does **not** alert (default scope `background`).
  - A simulated permission notify (`notification_type=permission_prompt`) → **Permission** alert even when focused (scope `always`), Hero sound.
  - A simulated `Stop` carrying a `background_tasks` entry → the card **stays running**, **no** notification.
  - A card `→ dead` → **Died** alert (Basso).
  - Toggle a trigger to `Off` in Settings → that trigger no longer alerts.

- [ ] **Step 4: Update the design doc status** to `Implemented` and commit.

```bash
git add notes/designs/2026-07-03-configurable-notifications-design.md
git commit -m "docs: mark configurable-notifications design implemented"
```

---

## Self-review notes

- **Spec coverage:** WaitReason/field (T1) · status-channel passthrough (T2) · report lifecycle (T3) · Claude classify incl. option-A background suppression (T4) · Codex humanTurn (T5) · notifier scope+sound+willPresent+died (T6) · BoardModel routing incl. dead + startup guards (T7) · Settings three rows (T8) · graceful degradation is implicit (absent `background_tasks` → empty → humanTurn, T4; Codex has only humanTurn/died, T5). All spec sections map to a task.
- **Type consistency:** `NotifyTrigger`/`NotifyScope`, `scopeKey/soundKey/defaultScope/defaultSound/soundNames`, `shouldFire`, `sound(forPref:)`, `notify(_:task:)`, `WaitReason.{permission,humanTurn}` are used identically across T6–T8 and T1–T5.
- **Known verify-at-impl detail:** the `UNNotificationSound(named:)` token (`"Name.aiff"` vs `"Name"`) is finicky; T9 Step 3 confirms audible sound and the pick-preview uses `NSSound(named:)` which takes the bare name.
- **App target not in `swift test`:** T6–T8 are build- + smoke-verified, not unit-tested; the risk is contained because the only non-trivial logic (`shouldFire`, `sound(forPref:)`) is pure and small.
