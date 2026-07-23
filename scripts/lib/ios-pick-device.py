#!/usr/bin/env python3
"""Pick the target iPhone out of `xcrun devicectl list devices --json-output` output.

Split out of scripts/build-ios-device.sh so the selection policy can be exercised against captured
JSON (scripts/lib/ios-pick-device-test.sh) instead of a physical phone: every interesting case —
network-paired, cable-attached, none, several, a bad override — is a fixture, not a device.

WHY JSON AND NOT THE TABLE. `devicectl list devices --help` says outright: "JSON output to a
user-provided file on disk is the ONLY supported interface for scripts/programs to consume command
output." The table is a human rendering and parsing it is how this lane broke — its State column
shows `available (paired)` for a network-paired iPhone (the normal state once you tick Xcode ▸
Devices ▸ "Connect via network"), so a filter looking for `connected` matched nothing and the
install died after a perfectly good build. There is no `state` field in the JSON at all: that column
is assembled from connectionProperties, so no allowlist of rendered state words can be correct.

WHY WE NEVER FILTER ON CONNECTION STATE. The automatic path selects on *identity* only —
hardwareProperties.{platform,reality,deviceType}. A phone is the same phone whether it is on the end
of a cable (transportType `wired`) or across the room on Wi-Fi (`localNetwork`), so the distinction
that broke the old filter is one this one cannot observe. If the device turns out to be unusable
(unpaired, locked, Developer Mode off) `devicectl device install` says so precisely, and its
diagnosis beats anything we could infer by pattern-matching a status string.
"""

import argparse
import json
import sys

# hardwareProperties values, as emitted by CoreDevice (the enum spellings are in
# CoreDevice.framework: platform `iOS`, reality `physical`/`simulator`, deviceType `iPhone`/`iPad`).
# App-iOS is an iPhone-family target (supportedDeviceFamilies == [1]), so that is what we look for.
PLATFORM = "ios"
REALITY = "physical"
DEVICE_TYPE = "iphone"


def _fold(value):
    """Compare CoreDevice enum spellings case-insensitively; absent fields become ''."""
    return value.casefold() if isinstance(value, str) else ""


class Device(object):
    def __init__(self, raw):
        hw = raw.get("hardwareProperties") or {}
        conn = raw.get("connectionProperties") or {}
        props = raw.get("deviceProperties") or {}
        self.identifier = raw.get("identifier") or ""
        self.udid = hw.get("udid") or ""
        self.name = props.get("name") or "(unnamed)"
        self.platform = _fold(hw.get("platform"))
        self.reality = _fold(hw.get("reality"))
        self.device_type = _fold(hw.get("deviceType"))
        self.model = hw.get("marketingName") or hw.get("productType") or "?"
        self.transport = conn.get("transportType") or "?"
        self.pairing = conn.get("pairingState") or "?"
        self.dev_mode = props.get("developerModeStatus") or "?"

    def is_target_iphone(self):
        # The identifier is what `devicectl device install --device` consumes, so a row without one
        # is not a candidate however well it matches otherwise. Without this guard an identifier-less
        # row selects "successfully" and prints an empty line, and the caller installs to --device ''
        # — the silent-empty-value failure this whole selector exists to make impossible.
        return (
            bool(self.identifier)
            and self.platform == PLATFORM
            and self.reality == REALITY
            and self.device_type == DEVICE_TYPE
        )

    def matches(self, selector):
        """An override may name the device by identifier, hardware udid, or (part of) its name.

        Names are the only thing a human reliably remembers, but they carry a typographic
        apostrophe ("Allen’s iPhone") that is a nuisance to type and impossible to guess, so a
        case-insensitive substring is enough — `--device allen` works.
        """
        sel = selector.casefold()
        return (
            sel == self.identifier.casefold()
            or sel == self.udid.casefold()
            or sel in self.name.casefold()
        )

    def describe(self):
        return "%s  %s  (%s, %s, pairing=%s)" % (
            self.identifier,
            self.name,
            self.model,
            self.transport,
            self.pairing,
        )


def _fail(message):
    sys.stderr.write("error: %s\n" % message)
    return 1


def _fail_listing(message, devices, hint):
    sys.stderr.write("error: %s\n" % message)
    for device in devices:
        sys.stderr.write("  • %s\n" % device.describe())
    sys.stderr.write("%s\n" % hint)
    return 1


NO_DEVICE_HINT = """
If the iPhone should be there, check in this order — the first two are the usual culprits:
  • the phone is UNLOCKED and on its home screen (a locked phone can still pair, but mounting the
    developer disk image fails later with kAMDMobileImageMounterDeviceLocked / CoreDeviceError 12040)
  • paired to this Mac: Xcode ▸ Window ▸ Devices and Simulators — for a cable-free workflow tick
    "Connect via network" there once, with the phone plugged in
  • Developer Mode on: iPhone ▸ Settings ▸ Privacy & Security ▸ Developer Mode ▸ on ▸ restart"""


def select(payload, selector=None):
    """Return (device, 0) or (None, exit_code) — the whole policy, so the test covers it."""
    # Be defensive about the envelope: a devicectl that failed, or a truncated/!dict file, must
    # produce a diagnosis rather than an AttributeError traceback.
    if not isinstance(payload, dict):
        return None, _fail("devicectl JSON is not an object (got %s)" % type(payload).__name__)
    result = payload.get("result")
    raw_devices = (result or {}).get("devices") if isinstance(result, dict) else None
    devices = [Device(d) for d in (raw_devices or []) if isinstance(d, dict)]

    # An explicit override is matched against EVERY device, not just the iPhones the automatic path
    # would consider: if a human names a device, honor it verbatim rather than second-guessing it.
    if selector:
        hits = [d for d in devices if d.matches(selector)]
        if not hits:
            return None, _fail_listing(
                "no device matches --device/ORCH_IOS_DEVICE '%s'. Known devices:" % selector,
                devices,
                "Pass an identifier, a udid, or part of the device name.",
            )
        if len(hits) > 1:
            return None, _fail_listing(
                "--device/ORCH_IOS_DEVICE '%s' is ambiguous — it matches:" % selector,
                hits,
                "Narrow it, or pass the full identifier from the first column.",
            )
        # Same guard as the automatic path: matching a device by name says nothing about whether it
        # has the identifier the install actually needs.
        if not hits[0].identifier:
            return None, _fail(
                "device '%s' has no identifier — devicectl cannot install to it." % hits[0].name
            )
        return hits[0], 0

    candidates = [d for d in devices if d.is_target_iphone()]
    if not candidates:
        if devices:
            return None, _fail_listing(
                "no physical iPhone known to devicectl. It does see:", devices, NO_DEVICE_HINT
            )
        return None, _fail("devicectl knows about no devices at all." + NO_DEVICE_HINT)

    # A row that looks like a target iPhone but carries no identifier drops out of `candidates`
    # silently. On its own that is caught below (zero candidates → we list everything we saw), but
    # alongside a healthy phone it would disappear without a word and the "several iPhones, say which
    # one" guard would quietly fail to apply. Say what was skipped, then carry on.
    skipped = [
        d
        for d in devices
        if not d.identifier
        and d.platform == PLATFORM
        and d.reality == REALITY
        and d.device_type == DEVICE_TYPE
    ]
    for device in skipped:
        sys.stderr.write(
            "warning: ignoring iPhone '%s' — devicectl reported no identifier for it.\n" % device.name
        )

    # Never install onto an arbitrary phone. Which one you meant is unknowable here, and guessing
    # wrong wipes the wrong device's build, so make the human say it once.
    if len(candidates) > 1:
        return None, _fail_listing(
            "several iPhones are available — say which one:",
            candidates,
            "  scripts/build-ios-device.sh --install --device '<identifier or name>'\n"
            "  (or export ORCH_IOS_DEVICE=... to make it stick)",
        )
    return candidates[0], 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--json",
        metavar="PATH",
        help="devicectl --json-output file (default: read the JSON from stdin)",
    )
    parser.add_argument(
        "--device",
        metavar="SELECTOR",
        help="identifier, udid, or part of the device name to install to",
    )
    args = parser.parse_args(argv)

    try:
        if args.json:
            with open(args.json) as handle:
                payload = json.load(handle)
        else:
            payload = json.load(sys.stdin)
    except (OSError, ValueError) as exc:
        return _fail("could not read devicectl JSON: %s" % exc)

    device, status = select(payload, args.device)
    if device is None:
        return status
    # stdout is the machine channel (the caller captures it); the human line goes to stderr so the
    # caller never has to strip it back out.
    sys.stderr.write("device: %s\n" % device.describe())
    sys.stdout.write("%s\n" % device.identifier)
    return 0


if __name__ == "__main__":
    sys.exit(main())
