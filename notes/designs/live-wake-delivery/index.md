---
project: claude-kanban (Orchestra)
feature: live-wake-delivery
title: Index
status: draft
created: 2026-07-10
updated: 2026-07-10
links: ["[[01-design]]"]
---

# live-wake-delivery

Replace **restart-based wake** (kill + `--resume` / `codex resume`) with **in-place delivery** — a
per-session control channel the daemon pushes into — and fix the three defects behind "janky send/wake":
the restart itself, dropped sends (drain-before-confirm data loss + strand/lag no-ops), and the macOS
terminal going black on a session recreate. Broadens the deferred `controlChannel` seam from
[[../agent-provider-interface|agent-provider-interface]] §8 and retires the relaunch cost that
[[../codex-wake-delivery/01-design|codex-wake-delivery]] accepted.

## Layers
- [[01-design]] — Layer 1: initial design (the what).

## Key empirical findings (real binaries: Claude 2.1.206, Codex 0.142.5)
- **Channels wake an idle Claude session with no restart** (PID-stable, ~2 s) — proven; and Orchestra's own
  Swift MCP bridge can host the channel (no Node process).
- **Codex has no auto-reinvoke**; its no-restart options are a **blocking Stop-hook park** (proven) or the
  **App Server `turn/start`** control channel (probe pending).
- **Codex "won't wake" root cause** = hook-trust modal + stale-`hooks.json` install bug → the Stop drain
  never runs. Cheap to fix, independent of the wake rewrite.
- Wake mechanisms latch only at turn-end; **channels inject from any idle state**.

## Status (2026-07-10 — re-baselined on `main`)
Lifecycle-convergence merged (`f52e640`) + Layer A (`491109a`) + Codex hooks-parse fix (`70db66f`), so:
- ✅ **A — Codex busy-path drain** (hook-trust build-probe + `_report --event` sentinel + `_comment` strip) — MERGED, **verified working end-to-end** (Stop hook drains a queued send at turn-end, no resume).
- ✅ **C — macOS terminal reconnect** (edge-driven reattach on the →live edge) — MERGED via convergence.
- ✅ **Foundation** — Phase + funnel + epoch + reconciler + verb contract (`VerbKind`) — live on `main`.

## Remaining work (build on `main`, each its own PR card)
1. **B** — reliable at-least-once delivery: `pendingSeed` already covers most drain-after-confirm; build the
   **delivery reconciler** (level-triggered retry) + flip **`send` `.mutation`→`.convergence`**; close the
   narrow drain→persist crash window. *The main open work.*
2. **D** — Claude **channels** no-restart wake (`orchestra-mcp` advertises `claude/channel`) as a MutationVerb.
3. **E** — Codex: **clean restart** (reuses the merged busy-drain + terminal reconnect + B's guarantee),
   grace-park only if needed; app-server `turn/start` a documented long-horizon option (costs the TUI, not taken).
