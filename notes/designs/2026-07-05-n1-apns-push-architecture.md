# N1 — APNs / notifications delivery (implementation architecture)

PR N1 wires **push delivery for the 3 attention triggers** (🔐 permission · 🙋 needsYou · 💀 died),
respecting the M5 `NotificationPrefs` scope/sound dials + background-wait suppression, and deep-links an
incoming push into the in-app **Needs You** queue / the card. This note records the *internal* architecture
(the product design is fixed by the mobile spec §6/§7 — not re-opened here) and, per the N1 gates, the
**honest verified-vs-deferred boundary**.

## The deterministic core (fully unit-tested)

Lifted from the existing macOS transition logic (`BoardModel.apply`, `#if os(macOS)`, which is fenced with
the comment "iOS notifications are N1") into a **pure, provider-neutral, shared** place so it is testable
without a daemon or a simulator, and reused by both sides.

`Sources/OrchestraKit/Push.swift` (client-safe, Foundation only → links on iOS *and* the daemon):

- **`NotificationIntent`** — the provider-neutral intent: `{ trigger, cardId, cardTitle, cardRef }`.
- **`AttentionTransition.trigger(prev:task:)`** — the mapping. Mirrors the macOS notifier exactly:
  - `prev == nil` (fresh card / post-reconnect wholesale set) → **no** trigger.
  - `prev != .waiting && status == .waiting` → `.permission` if `waitReason == .permission` else `.needsYou`.
  - `prev != .dead && status == .dead` → `.died`.
  - **Background-wait suppression is by construction**: a card that yields to a background task
    (`run_in_background` / subagent / `/loop`) stays `.running` with no `waitReason` (the adapters emit no
    waiting report), so it never produces a `.waiting` transition and never pushes. Asserted by a test.
- **`AttentionTracker`** — the stateful daemon-side observer (holds `[cardId: AgentStatus]`), `observe(task)
  → NotificationIntent?`. Pure (no I/O), so the whole transition→intent path is unit-tested.
- **`PushGate`** — the scope/sound gating, mirroring `AgentNotifier.shouldFire`:
  - `shouldSend(scope:)` — daemon pre-filter: drop `.off`, send `.background`/`.always` (the daemon can't
    know foreground, so it never suppresses `.background` — that's the client's job).
  - `shouldPresent(scope:appForeground:)` — client foreground gate: `.always` always; `.background`
    suppressed while foreground (the "background-only stays quiet while the app is open" promise);
    `.off` never.
- **`APNsPayload.build(intent:sound:)`** — the pure APNs JSON payload builder: `aps.alert{title,body}`,
  `aps.sound`, and custom `taskId`/`trigger` keys the deep-link reads. Testable independent of any send.
- **`DeviceRegistration`** — `{ token, clientId, platform, prefs: NotifyPrefsSnapshot }`. The phone
  re-registers whenever prefs change so the daemon's `shouldSend`/sound decision never drifts from the
  client's Settings screen.

## Daemon side (OrchestraCore) — wired

- **`DeviceTokenStore`** (actor, JSON at `dataDir/device-tokens.json`, TaskStore idiom) — registered
  devices keyed by `clientId` (re-register replaces).
- **RPC `registerDevice` / `unregisterDevice`** — new `ControlServer.dispatch` cases →
  `OrchestraService.registerDevice(...)`. `ControlClient.registerDevice(...)` typed wrapper (in Kit).
- **`PushSender`** protocol + **`APNsHTTPSender`** — builds the real APNs request:
  `POST https://api.push.apple.com/3/device/<hex-token>`, `authorization: bearer <ES256 JWT>`,
  `apns-topic`, `apns-push-type: alert`, `apns-priority: 10`, body = `APNsPayload`. JWT ES256 signing is
  gated `#if canImport(CryptoKit)` (Apple only; Linux/musl has no CryptoKit → the sender reports
  `unsupported`, documented). When unconfigured (no auth key / key-id / team-id / topic) the sender is
  **disabled** (no-op + log) — the honest boundary, not a fake success.
- **`PushNotifier`** — subscribes to `service.subscribe()` in `orchestrad/main.swift` (a *second* consumer
  alongside `ControlServer`), runs each `.taskUpserted` through `AttentionTracker` → intent → for each
  registered device: `PushGate.shouldSend` → `sender.send`. A `MockPushSender` drives the end-to-end
  observer test (mapping + gating + bg-suppression) without any network.

## iOS side (App-iOS) — wired

- **`PushController`** (`UIApplicationDelegate` via `@UIApplicationDelegateAdaptor`): requests
  authorization, `registerForRemoteNotifications()`; on token → `client.registerDevice(token, prefs)`; on
  `willPresent` (foreground) applies `PushGate.shouldPresent(scope, appForeground:true)` from local
  `NotificationPrefs`; on tap → deep-link.
- **`PushRouter`** (`ObservableObject`) — lifts tab selection + card selection out of `RootView`'s local
  `@State` so a push handler can set `tab = .needsYou` and select the card. Respects/clears snooze.
- **Entitlements/Info.plist/project.yml** — `aps-environment`, `UIBackgroundModes: [remote-notification]`.
- **Local-notification simulation (DEBUG, labeled)** — schedules a `UNNotificationRequest` from the SAME
  `APNsPayload`/intent so the deep-link + foreground gating are exercised end-to-end on the simulator
  **without** a real APNs server. Clearly labeled a *simulation*, per the gate ("do NOT fake a delivered
  push").

## Verified vs deferred (honest)

- **Verified** (unit tests + simulator): transition→intent mapping (incl. fresh-card and bg-wait
  suppression), `PushGate` scope/sound gating (both `shouldSend` and `shouldPresent`), `APNsPayload`
  shape, `DeviceTokenStore` register/replace, the `registerDevice` RPC round-trip, the `PushNotifier`
  end-to-end via `MockPushSender`, and the iOS deep-link routing (via the local-notification simulation).
- **Deferred** (needs a real device + an APNs `.p8` auth key + a registered token + Apple's push
  gateway): the actual ES256-signed HTTP/2 push landing on a physical device. The path is built and
  type-checked but not exercised here (no APNs credentials / device in this environment).
</content>
</invoke>
