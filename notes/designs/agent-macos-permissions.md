# Granting macOS permissions (TCC) to Orchestra agents

Orchestra's Claude agents run inside the `-L orchestra` tmux server. They **can screenshot and
control other apps**, with permissions attributed to **Orchestra**, *not* Terminal. (The old "tmux
makes Terminal the responsible process, so I'd have to grant Terminal" problem does not apply.)

## The key finding: the two permissions attribute to *different* processes

Verified empirically (a running agent's `CGPreflightScreenCaptureAccess()` / `AXIsProcessTrusted()`):

| Permission | Grant it to | Notes |
|---|---|---|
| **Screen Recording** | **`Orchestra.app`** | Only `Orchestra.app` appears in the Screen Recording list (no `orchestrad`), and agents have capture. |
| **Accessibility** | **`orchestrad`** | Granting `Orchestra.app` Accessibility did **nothing**. Granting the `orchestrad` entry worked. |

Because they differ, the robust move is to **grant the permission to BOTH `Orchestra.app` and
`orchestrad`** in System Settings → Privacy & Security.

## No restart, no new agent needed

Granting `orchestrad` Accessibility took effect **live** — a long-running, pre-existing agent
flipped from `AX: false` to `AX: true` with **no orchestrad restart and no new agent**. The earlier
belief that a restart or a freshly-spawned agent was required was wrong; the real problem was just
granting the *wrong process* (Orchestra.app instead of orchestrad). So:

1. Grant the permission to `Orchestra.app` **and** `orchestrad`.
2. That's it — running agents pick it up live.

`orchestrad` is the launchd daemon (`com.orchestra.daemon`,
`/Applications/Orchestra.app/Contents/Resources/bin/orchestrad`); if it isn't already listed in a
Privacy pane, add it with the `+` button.

## Gotcha: Claude Code's bash sandbox hides the grant

`CGPreflightScreenCaptureAccess()` / `AXIsProcessTrusted()` return `false` inside the agent's bash
sandbox and `true` unsandboxed. Any screenshot/control command an agent runs must go through the
**unsandboxed** path (`dangerouslyDisableSandbox`, or a loosened `/sandbox`). Quick check:

```
swift -e 'import CoreGraphics; import ApplicationServices; print("SR:", CGPreflightScreenCaptureAccess()); print("AX:", AXIsProcessTrusted())'
```

## Note: separate from the in-app screenshot hook

`App/OrchestraApp.swift`'s `SIGUSR1` hook makes **Orchestra.app screenshot its own window** (needs
Orchestra.app to have Screen Recording). That's dev tooling, unrelated to how *agents* capture or
control other apps.
