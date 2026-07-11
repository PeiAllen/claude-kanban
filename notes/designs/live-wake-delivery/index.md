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

## Recommended sequencing
1. **A** — Codex hook-trust + stale-file install fix (restores the busy-path drain).
2. **B** — drain-after-confirm + provisional/lag delivery (stops dropped sends).
3. **C** — macOS terminal reconnect + per-launch epoch (stops the UI break).
4. **D/E** — no-restart wake transport: Claude channels (or `nativeReinvoke`), Codex app-server/parked-hook.
