# Test-deletion decisions (Task 8 prune, 2026-07-14)

Full-suite audit: **1,170 tests across 157 files**, every test body read, every claimed
deletion verified against `Sources/` (symbol presence via grep + `git log -S`).

## Outcome

| category | count | action |
|---|---|---|
| keep | 1,166 | — |
| delete-1 (dead code path) | **0** | ~175 distinct production symbols grep-verified present |
| delete-2 (provable duplicate) | **2** | deleted directly (below) |
| delete-3 (tests the stub) | **0** | near-misses examined and kept deliberately¹ |
| category-4 (regression guard, judgment) | **2** | both recommended KEEP (below) |

¹ `AdapterEncodeTests/stubDefaults` and `CapabilitiesTests/stubAdvertisesTuple` pin *production*
protocol-extension/memberwise defaults; `TestClockTests`/`FakeProcTests` pin test-infrastructure
contracts by design.

## Deleted directly (category 2 — byte-identical duplicates)

1. `ResourceExhaustionTests/classifiesTheIncident` — identical to the first parameterized
   argument of `classifiesSignatures`: both assert
   `HostResource.classify("create window failed: fork failed: Device not configured") == .pty`
   on the same pure function with the same literal. The `tmuxPtyExhausted` constant stays
   (four other tests use it).
2. `KeybindingsTests/test_ctrl_hjkl_still_focuses_without_shift` — its single assertion
   (`map(KeyChord("l", .control), .board) == .focusPane(.right)`) is byte-identical to the
   first assertion of `test_board_ctrl_hjkl_is_pane_focus`; it was added as a "still works"
   companion in the resize commit `4fafd62` and proves nothing new.

## Category-4 decision list (for Allen — both recommended KEEP)

### `RecoveryTests/concurrentResumeNeverLeaks` — **keep**
- **Guards:** the overlapping-`resume(id)` continuation leak (second resume leaked a readiness
  continuation → hang / duplicate session); introduced in `69bd722`, reshaped by `607f04a`.
- **Today:** the original leak is unrepresentable — `resume` is intent-only now (non-blocking
  `transition(→ .relaunching)`; no continuation held). But the surviving assertions are live
  invariants of the current reconciler: both calls return, `inFlightSteps` + epoch fencing
  converge exactly one live session, and the card stays wakeable afterward.
- **Why keep:** the only test running two overlapping `resume` verbs end-to-end.

### `ActorHygieneTests/test_reconcileLivenessNotBlockedByList` — **keep, lifetime-tied**
- **Guards:** the PR5 actor-hygiene fix — `reconcileLiveness()`'s synchronous `sessions.list()`
  blocking the OrchestraService actor (the suite-wedge lineage).
- **Today:** `reconcileLiveness` has no production caller
  (`OrchestraService+Recovery.swift:284` documents it is retained only for focused unit tests),
  so the guarded bug can't manifest in production — but six test files still drive it, and an
  on-actor regression there would starve `--parallel` runs.
- **Why keep:** for as long as `reconcileLiveness` exists as the test-retained entry point;
  when its retained tests migrate to `reconcile()` and the method is deleted, this goes with it.

## Incidental findings (not deletions)

- `ModelReseatTests/reportLandingConsumesTheReseat`: comment says `grace: 0`, code uses
  `grace: 2` — test valid, comment stale (fix in passing during the mirror move).
- `RedirectMechanicsTests/onlyChildCommitsTransplant` pins **git's own** `rebase --onto`
  semantics rather than Orchestra code — kept deliberately as the executable contract behind
  the restack nudge text `SetParentMoveTests` asserts on; it belongs in the contract tier.

## Accounting

Baseline at audit time: 1,170 test cases. After the two deletions: 1,168. Any further
deletion requires Allen's answer on the category-4 list (both currently recommended keep,
so the expected end state is 1,168 + whatever Stage-2 conversions add/merge, reconciled in
the final report).

## Deferred follow-up (from the impl-review confirm/deny, recorded per the bounded contract)

- **ControlClient reconnect backoff is shortened, not virtualized** (Codex DENY, accepted as
  real, deferred as out-of-proportion): the reader is a dedicated OS thread (blocking `read(2)`,
  reader-owns-close), so its `Thread.sleep(reconnectBackoff(attempt))` cannot ride the injected
  async clock without redesigning the reader loop. Unit tests inject `{ _ in 0.001 }` and wait
  on observable state via `pollUntil` — slower under load, never wrong. Virtualize if/when the
  ControlClient reader moves off threads.
