---
project: claude-kanban (Orchestra)
feature: live-wake-delivery
type: design-index
depth: 3 (full — L1 design, L2 contract, L3 implementation + tests, + PR tree)
created: 2026-07-10
updated: 2026-07-10
---

# live-wake-delivery — Design Index

Replace **restart-based wake** (kill + `--resume` / `codex resume`) with **in-place delivery** and
make send delivery **reliable at-least-once**: the durable inbox stays the source of truth until a
route-specific receipt proof confirms delivery (atomic token claims), a level-triggered delivery
arm in the merged reconciler re-drives stuck deliveries, Claude wakes idle via MCP **channels**
(PID-stable), and Codex's idle-cold wake is a **clean restart** riding the same guarantee.
Builds on the merged lifecycle-convergence foundation (`f52e640`).

**Sources of truth this vault deepens:** [[01-design]] (the empirically-grounded research + design,
Claude 2.1.206 / Codex 0.144.1). Gate mode: **agentic** (Opus 4.8 + GPT-5.6 Terra loop until no
complaints; human review of the whole plan at the end — Allen's standing instruction).

## Layers

| Layer | Document | Status |
|-------|----------|--------|
| 1 — Initial design | [[01-design]] | approved (research phase; re-baselined on post-merge `main`, 2026-07-10) |
| 2 — Contract | [[02-contract]] | approved (agentic gate: Opus 4.8 + GPT-5.6 Terra clean after 6/8 rounds, 2026-07-10) |
| 3 — Implementation | [[03-implementation]] | not started |
| 3 — Tests | [[04-tests]] | not started |
| 3 — PR tree (execution order) | [[05-pr-tree]] | not started |

<!-- Status values: not started · draft · in-review · approved · skipped -->

## Scope (remaining work — A and C already merged)

- **B — reliable at-least-once delivery** (the backbone): atomic inbox claims + token-scoped
  confirms, delivery reconciler arm, `send` → `.convergence`, delivery-stuck surfacing.
- **D — Claude no-restart wake via channels**: vendored-SDK `experimental` capability,
  `channel-wait` long-poll broker, `ChannelPump` in orchestra-mcp, consent choreography.
- **E — Codex clean-restart wake**: reuses B's `relaunchSeed` route + merged terminal reconnect;
  grace-park and App-Server `turn/start` stay documented seams only.

## Current picture (Layer 2 — modules; the L1 route reframe lives in [[01-design]])

```mermaid
flowchart TD
  subgraph kit [OrchestraKit]
    IMSG[InboxMessage + DeliveryLease token/route/epoch/watermark]
    CAT[CommandCatalog: send → convergence]
    CAPS[AgentCapabilities.wakeTransport<br/>claude → controlChannel when on]
  end
  subgraph daemon [orchestrad / OrchestraCore]
    SEND[send verb — enqueue + fast wake]
    ARM[delivery arm in reconcile tick<br/>level-triggered · backoff · stuck flip]
    WAKE[wake — deliveriesInFlight + route selection]
    INBOX[(Inbox actor<br/>claim / confirm / release by token)]
    STOP[payloadForStop — confirm prior + claim next]
    BROKER[ChannelBroker<br/>parked channel-wait per card+epoch+conn]
    STEP[Launch/RelaunchStepper<br/>seed claim from inbox + tail watermark]
    CONSENT[SessionManager consent choreography]
  end
  subgraph bridge [orchestra-mcp per session]
    PUMP[ChannelPump — dedicated long-timeout client]
    NOTIF[notifications/claude/channel]
  end
  SDK[Vendor/swift-sdk<br/>Capabilities.experimental]
  CLAUDE[live claude session · same PID]
  CODEX[codex session · clean restart]
  SEND --> INBOX & WAKE
  ARM --> WAKE
  WAKE -->|attached: claim→push| BROKER -->|resolve poll| PUMP --> NOTIF --> CLAUDE
  WAKE -->|cold: resume intent| STEP --> CODEX & CLAUDE
  STOP --> INBOX
  STEP --> INBOX
  BROKER -->|ack token| INBOX
  PUMP -.ack next poll.-> BROKER
  NOTIF -.uses.-> SDK
  CONSENT -.dev-channels Enter.-> CLAUDE
```

## Open questions (rolled up — for Allen at the final gate)

- **Channels default-on?** L2 recommends `claudeChannels` default **true** (build-probe +
  attach-probe + cold fallback contain the research-preview risk); flip to opt-in for a soak
  period if preferred.
- **L1 non-goal amendment ack:** stop-drain *removal timing* now changes (payload format/caps
  byte-identical) — folded into L1's non-goals; flag if the stronger reading was intended.
