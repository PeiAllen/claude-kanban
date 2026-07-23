# Deploy Orchestra to your iPhone (free Apple ID)

Install the Orchestra iOS app on a **real iPhone** with a **free personal Apple team** and connect it
to your Mac's live daemon over Tailscale. No paid Apple Developer membership required. (Push
notifications are the only thing the free tier can't do — out of scope; the board, terminals, and
takeover all work without it.)

There are two halves: **(A) get the app onto the phone** (Apple signing) and **(B) make it connect**
(Tailscale SSH to your Mac's daemon). Do A once, then B once.

After the one-time pairing, **everything here is wireless** — installs go over Wi-Fi and the cable
stays in the drawer.

---

## Prerequisites (one-time)

1. **Xcode signed into your Apple ID.** Xcode ▸ Settings ▸ Accounts ▸ **+** ▸ Apple ID ▸ sign in.
   A free Apple ID automatically gets a **"(Personal Team)"** — that's all you need.
2. **iPhone in Developer Mode.** Plug the iPhone into the Mac with a cable, unlock it, tap **Trust
   This Computer**. Then on the phone: Settings ▸ Privacy & Security ▸ **Developer Mode** ▸ on ▸
   restart when prompted (iOS 16+).
3. **Pair over the network.** Still with the cable in, open Xcode ▸ Window ▸ **Devices and
   Simulators**, select the phone, and tick **Connect via network**. Now unplug — every step below
   works over Wi-Fi. Confirm with `xcrun devicectl list devices`; the phone shows as
   `available (paired)`, which is the normal, healthy state for a network-paired device.
4. **Tailscale on both devices, same tailnet.** Install the Tailscale app on the iPhone and log into
   the same tailnet as the Mac. (This is how the phone reaches the Mac — there's no shared filesystem
   like the Simulator has.)
5. **Remote Login on the Mac.** System Settings ▸ General ▸ Sharing ▸ **Remote Login** ▸ on. (The app
   reaches the daemon by SSH-ing into your Mac over the tailnet and bridging to its socket.)

> **Keep the phone unlocked for both the install and the launch.** Two separate stages refuse a
> locked device, with two errors that look unrelated and mention neither the lock screen nor each
> other:
>
> - **Install** — the developer-disk-image mount fails with `kAMDMobileImageMounterDeviceLocked` /
>   `CoreDeviceError 12040`. Looks like a pairing or network fault.
> - **Launch** — SpringBoard refuses: `The request was denied by service delegate (SBMainWorkspace)
>   for reason: Locked`, `FBSOpenApplicationErrorDomain error 7 (0x07)`.
>
> These are asymmetric, which is the part that misleads: the **install can succeed completely** — the
> app is fully on the phone — and only the launch is denied. If you see
> `FBSOpenApplicationErrorDomain error 7` after a clean install, nothing is broken and the app does
> not crash on launch. Unlock the phone and launch again; rebuild and reinstall nothing.

---

## A. Build & install

Signing on a free team has one hard constraint that shapes this whole section: **`xcodebuild` cannot
create a provisioning profile from a shell — only use one that already exists.** That, plus the 7-day
life of a free-team certificate, makes this a **three-step cycle you repeat roughly weekly**:

1. **⌘R once from the Xcode GUI** (A1) — mints the 7-day profile. The CLI cannot do this.
2. **Scripted wireless build + install** (A2) — good for that profile's whole lifetime, no cable.
3. **Trust the developer on the phone** (A3) — manual, on the phone, and needed **every cycle**.

Only step 2 is automatable; steps 1 and 3 are the price of the free tier. A paid membership stretches
the cycle from a week to a year.

### A1. Mint the profile — ⌘R from Xcode (once per cycle)

```sh
cd <repo>
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

The app is now on the phone, but iOS will refuse to launch it until you do **A3**.

### A2. Every install after that — the scripted lane

With a profile on disk, the script does the whole thing over Wi-Fi, unattended:

```sh
ORCH_IOS_TEAM_ID=XXXXXXXXXX scripts/build-ios-device.sh --install
```

(Or drop `DEVELOPMENT_TEAM = XXXXXXXXXX` into the gitignored `App-iOS/DeviceSigning.local.xcconfig`
and omit the env var. Your team id is in Xcode ▸ Settings ▸ Accounts ▸ your Apple ID ▸ team.)

This builds **Release**, because a build on your actual phone is one you're going to *use* — Debug's
unoptimized Swift is felt as UI lag while scrolling the board and rendering terminals. Add `--debug`
on the rare occasion you want the unoptimized build to attach a debugger or get usable symbols.

It prints the phone it chose. If you have **more than one** iPhone paired it refuses to guess and
lists them — name the one you want, by identifier, udid, or any part of its name:

```sh
scripts/build-ios-device.sh --install --device 'Allen’s iPhone'   # or: export ORCH_IOS_DEVICE=…
```

A `--device` you pass explicitly is matched against every paired device, not only iPhones, so make
the substring specific enough to be unambiguous — with an iPad also paired, `--device Allen` matches
both and is rejected rather than guessed. The device is picked *before* the build, so a typo costs
seconds rather than a full build.

To launch it without touching the phone:

```sh
xcrun devicectl device process launch --device <identifier> --terminate-existing com.orchestra.ios
```

> **A scripted launch does not prove the install is usable.** `devicectl` starts the app through the
> developer-disk-image debug path, which is not subject to the Untrusted Developer gate — so it
> succeeds even while the developer is still untrusted. Use it to smoke-test a build; only tapping
> the home-screen icon after **A3** proves the app opens the way you'll actually open it. And if it
> fails with `FBSOpenApplicationErrorDomain error 7`, that's the lock screen, not the build — the
> install already succeeded (see the unlock note above).

### A3. Trust the developer on the phone (every cycle)

On the iPhone: Settings ▸ General ▸ **VPN & Device Management** ▸ your Apple ID ▸ **Trust**.

Until you do, tapping the icon shows **"Untrusted Developer"** and iOS refuses to launch the app.

**This is an expected manual step, not an error.** It's a per-signing-identity consent gate that sits
*downstream* of compile, sign, and install, so a build or install run that ends by telling you to
trust the team has **succeeded** — there is nothing to debug. And because every new 7-day profile is
a new signing identity, the prompt returns each cycle; it isn't one-time setup.

### When the week is up

Free-team certificates expire ~7 days after signing and the app stops launching. Nothing renews them
in place — just run the cycle again: ⌘R from Xcode (A1), `--install` (A2), Trust on the phone (A3).
A paid membership raises the 7 days to a year. Either way there is no TestFlight or App Store
distribution on a personal team.

(This renewal round-trip hasn't been run end to end on this lane yet — the lane was verified from a
first install. It's how free teams are documented to behave, but treat day eight as expected rather
than proven, and expect to fall back to plain ⌘R if the scripted step surprises you.)

### "No Accounts: Add a new account in Accounts settings"

If the script fails with that, plus `No profiles for 'com.orchestra.ios' were found`, **you are not
signed out** — this is the constraint at the top of section A. `xcodebuild` can't reach the
keychain-backed session of the Apple ID in Xcode from a non-GUI shell, so a missing profile surfaces
as a missing account. The fix is ⌘R from the GUI (A1), not re-adding your Apple ID.

### If signing fails on the bundle id

`com.orchestra.ios` may already be registered to another team. If Xcode says the bundle identifier is
unavailable, change it to something unique to you in **Signing & Capabilities ▸ Bundle Identifier**,
e.g. `com.<yourname>.orchestra`. If you do, also update the keychain group in
`App-iOS/OrchestraiOS-nopush.entitlements` (the `keychain-access-groups` string) to match your new id,
then re-run `xcodegen generate` and ⌘R. Pass the same id to the scripted lane afterwards:
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
