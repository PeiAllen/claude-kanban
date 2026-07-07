# Deploy Orchestra to your iPhone (free Apple ID)

Install the Orchestra iOS app on a **real iPhone** with a **free personal Apple team** and connect it
to your Mac's live daemon over Tailscale. No paid Apple Developer membership required. (Push
notifications are the only thing the free tier can't do — out of scope; the board, terminals, and
takeover all work without it.)

There are two halves: **(A) get the app onto the phone** (Xcode signing) and **(B) make it connect**
(Tailscale SSH to your Mac's daemon). Do A once, then B once.

---

## Prerequisites (one-time)

1. **Xcode signed into your Apple ID.** Xcode ▸ Settings ▸ Accounts ▸ **+** ▸ Apple ID ▸ sign in.
   A free Apple ID automatically gets a **"(Personal Team)"** — that's all you need.
2. **iPhone in Developer Mode.** Plug the iPhone into the Mac with a cable, unlock it, tap **Trust
   This Computer**. Then on the phone: Settings ▸ Privacy & Security ▸ **Developer Mode** ▸ on ▸
   restart when prompted (iOS 16+).
3. **Tailscale on both devices, same tailnet.** Install the Tailscale app on the iPhone and log into
   the same tailnet as the Mac. (This is how the phone reaches the Mac — there's no shared filesystem
   like the Simulator has.)
4. **Remote Login on the Mac.** System Settings ▸ General ▸ Sharing ▸ **Remote Login** ▸ on. (The app
   reaches the daemon by SSH-ing into your Mac over the tailnet and bridging to its socket.)

---

## A. Build & install (Xcode GUI)

```sh
cd <repo>                       # the mobile-impl-orchestration worktree
xcodegen generate --spec App-iOS/project.yml --project App-iOS
open App-iOS/OrchestraiOS.xcodeproj
```

In Xcode:

1. **Destination:** in the top bar, pick your iPhone (not a Simulator) from the device menu.
2. **Scheme:** `OrchestraiOS`.
3. **Signing:** select the **OrchestraiOS** target ▸ **Signing & Capabilities** tab:
   - **Team** → your **(Personal Team)**.
   - **Automatically manage signing** → checked.
   - The entitlements are already the free-team-safe set (keychain only, no `aps-environment`), so
     signing should resolve with no manual capability edits.
4. **Run:** ⌘R. Xcode creates the development certificate + provisioning profile on the fly and
   installs to the phone.
5. **Trust the developer on the phone** (first install only): the app installs but iOS blocks launch
   until you approve it — iPhone ▸ Settings ▸ General ▸ **VPN & Device Management** ▸ your Apple ID ▸
   **Trust**. Then tap the app icon (or ⌘R again).

> **7-day expiry (free team):** free-team apps stop launching ~7 days after signing. To keep using it,
> just ⌘R from Xcode again to re-sign. (A paid membership raises this to a year.)

### If signing fails on the bundle id
`com.orchestra.ios` may already be registered to another team. If Xcode says the bundle identifier is
unavailable, change it to something unique to you in **Signing & Capabilities ▸ Bundle Identifier**,
e.g. `com.<yourname>.orchestra`. If you do, also update the keychain group in
`App-iOS/OrchestraiOS-nopush.entitlements` (the `keychain-access-groups` string) to match your new id,
then re-run `xcodegen generate` and ⌘R. Alternatively use the scripted lane:
`ORCH_IOS_BUNDLE_ID=com.<yourname>.orchestra scripts/build-ios-device.sh --install`.

---

## B. Connect the app to your Mac (first run)

On first launch the app opens a **"Connect your Mac"** screen (3 steps, matching the UI):

1. **Enter your Mac** — type your Mac's Tailscale name, e.g. `you@my-mac.tailnet.ts.net`, or
   `you@100.x.y.z` (a `100.64.0.0/10` tailnet IP). Find it with `tailscale status` on the Mac or in
   the Tailscale menu. The `you@` is your Mac username.
2. **Trust this device** — the screen shows this phone's SSH public-key line and a **Copy key line**
   button. On the Mac, append it to `~/.ssh/authorized_keys`:
   ```sh
   echo '<paste the copied line>' >> ~/.ssh/authorized_keys
   ```
   That's how the Mac lets this phone in (public-key SSH; no password).
3. **Test** — tap **Test connection**. On success it says **"Connected. Your board is live."** and you
   can open the board. If it fails, re-check: both devices on Tailscale, **Remote Login** on, and the
   key line is in `authorized_keys`.

After that the board is driven by your **live daemon** — the same cards you see on the Mac, plus
spawn, Needs-You approvals, terminals, and phone→desktop takeover.

---

## What works vs. what doesn't (free tier)

- **Works:** board sync, spawn + freeform trust, Needs-You approve/deny, block-REPL terminals,
  phone-owned shells, agent-terminal takeover — all over the tailnet SSH transport.
- **Not on the free tier:** real APNs push (agents-ended / needs-you banners while the app is closed).
  It's a paid-membership feature and is intentionally disabled here; use the Claude/Codex mobile apps'
  own notifications in the meantime. To enable it later on a paid account: point
  `CODE_SIGN_ENTITLEMENTS` in `App-iOS/project.yml` back at `OrchestraiOS.entitlements` (which carries
  `aps-environment`), mint an APNs key, and inject `ORCH_APNS_*` into the daemon LaunchAgent.
