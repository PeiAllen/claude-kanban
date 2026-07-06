# iOS push not delivering — diagnosis & verification (N1)

**Card:** 424828 · **Branch:** `fix/ios-push-notifications` (off `mobile-impl-orchestration`)
**Date:** 2026-07-06 · **Scope chosen by user:** diagnosis + verification only, *no production code change*.

## TL;DR

The push code is **correctly wired end-to-end** — I traced every hop and proved the two
that can be proven without Apple credentials. The phone gets nothing for **two compounding,
purely environmental reasons — neither is a code defect**:

1. **You're testing on the iOS Simulator, which physically cannot receive real remote APNs
   push.** This alone fully explains the symptom. The Simulator only accepts *locally
   injected* pushes via `xcrun simctl push` (which I used to prove the receive side).
2. **The daemon runs `DisabledPushSender`** — it has no APNs auth key and, more importantly,
   **no supported way to ever be given one** (see hop #3). So even on a real device today,
   every push is silently dropped.

Real end-to-end delivery genuinely requires **a physical iPhone + a valid APNs `.p8` auth
key (Key ID + Team ID) + a topic matching `com.orchestra.ios` + a matching provisioning
profile**. None exist in this environment and I cannot mint them — they come from your Apple
Developer account. Per the task's instruction, I stopped at that boundary rather than faking it.

## The five hops, traced

| # | Hop | Verdict | How verified |
|---|-----|---------|--------------|
| 1 | Agent state change → daemon emits `.taskUpserted` | ✅ wired | `markDead` / `applyReport` emit; `PushNotifier` is a 2nd stream subscriber (`OrchestraService.subscribe` supports many) |
| 2 | Transition → `NotificationIntent` (`AttentionTracker`) | ✅ **proven** | 15 `PushNotifierTests` pass (mock sender) |
| 3 | Daemon builds + dispatches APNs request | ❌ **no-op sender** | root cause — see below |
| 4 | APNs → device → banner + foreground gate | ✅ **proven** | 3 `simctl push` cases (screens in `.scratch/push/`) |
| 4t | Tapped push → deep-link into Needs You | ✅ wired | single-path code + `IOSAppTests` (`deepLink`/`consumeDeepLink`) + DEBUG in-app "simulate push" button |

## Hop #3 — the actual break (and why it can't self-heal)

`Sources/orchestrad/main.swift` picks the sender from the environment:

```swift
if let apns = APNsConfig.from(env: ProcessInfo.processInfo.environment) {
    pushSender = APNsHTTPSender(config: apns)          // real send
} else {
    pushSender = DisabledPushSender()                  // drops every push, silently
}
```

`APNsConfig.from(env:)` requires `ORCH_APNS_KEY_PATH`, `_KEY_ID`, `_TEAM_ID`, `_TOPIC`. It
returns `nil` and stays a no-op because:

- **No `.p8` key exists** anywhere in the repo or on disk; `ORCH_APNS_*` is set by no script.
- **There is no path to ever provision the production daemon.** `DaemonLifecycle.install()`
  renders the LaunchAgent plist substituting only `__ORCHESTRAD_BIN__` and `__LOG__`. The
  plist (`Sources/OrchestraCore/Resources/com.orchestra.daemon.plist` +
  `~/Library/LaunchAgents/com.orchestra.daemon.plist`) has **no `EnvironmentVariables`**, and
  a GUI LaunchAgent does **not** inherit your shell environment. So exporting `ORCH_APNS_*`
  in `~/.zshrc` would *not* reach the launchd-spawned `orchestrad`.

Net: the shipped daemon is hardwired to `DisabledPushSender`, and the drop is invisible
(only a one-line startup log; nothing at send time).

> If you later want push to actually work, the minimal fix (deferred by your "diagnosis only"
> choice) is: teach `DaemonLifecycle.install()` + the plist template to inject `ORCH_APNS_*`
> into `EnvironmentVariables` (from config or the installing env), and log at the drop points
> (`DisabledPushSender` used / 0 devices / send OK|err). With that + a real `.p8` key, delivery
> works with no further code change. **Not implemented** — reported only.

## What I verified vs. what needs a real device

### Verified WITHOUT Apple credentials

**Daemon send-decision (#2→#3)** — `swift test --filter PushNotifierTests` → **15/15 pass**,
incl. `testTransitionFansOutToRegisteredDevice`: a `running → waiting(permission)` transition
fans out exactly **one** push to the registered token, with `trigger:"permission"` and
`aps.sound:"Glass.aiff"`. Also proven: `.off` scope dropped at source, background-wait never
fires, 410/400 dead-token → unregister, transient 5xx keeps the token, ES256 JWT signing +
caching, request shape/headers.

**iOS receive + present + foreground gate (#4)** — built Debug, booted a Simulator, installed,
and injected pushes with `xcrun simctl push com.orchestra.ios <payload>.apns`. The payloads
mirror `APNsPayload.build` (top-level `taskId` / `trigger` / `ref` + `aps.alert`). Three cases,
screenshots in `.scratch/push/`:

| Case | Scope | App state | Expected | Result |
|------|-------|-----------|----------|--------|
| `died` | `.always` | foreground | banner | ✅ banner "Agent session ended — needs recovery" (`01-died-foreground.png`) |
| `needsYou` | `.background` | foreground | **suppressed** | ✅ no banner (`03-needsyou-foreground.png`) |
| `needsYou` | `.background` | not-foreground | banner | ✅ home-screen banner "Agent finished — waiting on you" (`04-needsyou-background.png`) |

Cases 1+2 prove `willPresent` → `PushGate.shouldPresent` discriminates exactly. Case 3 proves
the **backgrounded phone still gets the banner** — the whole reason daemon-side push exists.
All banner bodies match `APNsPayload.body(for:)` verbatim, confirming the payload contract
lines up end-to-end.

### Genuinely blocked — needs a physical device + your Apple Developer account

The single hop I *cannot* exercise here is the live **daemon → Apple's APNs gateway → real
device** POST. It requires an APNs `.p8` auth key (Key ID + Team ID), the `com.orchestra.ios`
topic, a device provisioning profile with `aps-environment`, and a real iPhone. The code for
it (`APNsHTTPSender.send`) is present, type-checked, and its request/JWT construction is
unit-tested — only the network POST is unexercised.

## Secondary note (working as designed, not a bug)

`needsYou`'s **default scope is `.background`** (`permission`/`died` are `.always`). So while
the app is *open*, needsYou banners are intentionally suppressed (design §7). If you were
testing needsYou with the app foreground, that's expected quiet, not a failure — case 2 above.

## Repro / cleanup

- Build+run: `scripts/build-ios-app.sh --run --debug`
- Push: `xcrun simctl push <booted-udid> com.orchestra.ios .scratch/push/{died,needsyou}.apns`
- Payloads + screenshots live under `.scratch/push/` (gitignored).
