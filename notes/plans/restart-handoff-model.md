# PR: `--model` override on `restart` / `handoff` / `resume`

Tier M. Lets a live card be re-seated onto a different model **in place** — the escalation path
("this turned out to be architecture work, I need Fable") without spawning a successor card.

> **v2** after the plan review pair. v1's report-revert answer (an epoch-gated `pendingModelCheck`
> consumed in `report()`) was **wrong** and is replaced by `pendingModel`, below. See "What the review
> changed".

## Empirical finding (settles the central risk)

Probed both vendor CLIs for real in `.scratch/modelprobe`, throwaway sessions, ground truth read from
the transcript/rollout (not the agent's self-report):

- **Claude** — `claude -p --session-id S --model claude-haiku-4-5-20251001`, then
  `claude -p --resume S --model claude-opus-4-8`. Same transcript appended; turn-1 assistant messages
  `"model":"claude-haiku-4-5-20251001"`, resumed turn `"model":"claude-opus-4-8"`.
- **Codex** — `codex exec -m gpt-5.6-luna`, then `codex exec resume <sid> -m gpt-5.6-terra`. The SAME
  rollout file gains `"model":"gpt-5.6-terra"` lines after the luna ones; no fork, context carried.

**Both vendors re-bind the model on resume.** The session's stored model does not win. So
handoff-with-model is sound and the override ships on all three verbs — option (b) (restart-only) is
unnecessary and would not serve the motivating use case anyway.

## The real revert trap is ORCHESTRA'S, not the vendor's

`report()` overwrites `task.model` from the agent's reported `modelId` (+Report.swift:133-139) and that
write is **not epoch-fenced** — only the phase write is (:184). The field-delta half goes through
`Task.applyReportFields` (Model.swift:684-692), which copies `model` unconditionally.

And `restart`/`resume` are **intent-only**: they write the card and return (+Recovery.swift:51, :101);
the old session is not killed until the RelaunchStepper reaches +Converge.swift:205, a reconcile tick
(≥2s) later. In that window **the old, still-running session's statusline fires with the OLD model id
and reverts `task.model`** — then `finishLaunch` re-reads the card (+Converge.swift:142) and builds
`ctx.model = task.model.id`, so the relaunch goes up on the OLD model. The override erases itself,
silently, and the motivating case (an agent mid-turn handing off to itself, statusline actively
rendering) is the *most* likely to hit it.

So the fix cannot be "the verb writes `task.model` and nothing else touches it".

### `pendingModel` — mirror `pendingSeed`

`pendingSeed` already solves exactly this problem for the handoff seed: persisted launch **intent**,
read by the stepper when it builds the launch, cleared in the same transition that lands `.live`
(PhaseStepper.swift:107, 176, 220, 233; +Reconcile.swift:139), and deliberately left set when a launch
fails so a retry still carries it. `pendingModel` mirrors it field for field:

- **`Task.pendingModel: String?`** — the requested launch id. **Deliberately NOT added to
  `applyReportFields`**, so `report()` structurally *cannot* clobber it, epoch or no epoch.
- The verbs set `t.pendingModel = m.id` **and** `t.model = m` (the latter purely so the board shows the
  new model immediately; if a stale report reverts it, nothing breaks — the launch no longer reads it).
- **`finishLaunch` builds `ctx.model` from `task.pendingModel ?? task.model.id`** on BOTH the `.blank`
  (:160) and `.resume` (:169) paths. This is the line that makes the stale-report revert harmless.
- Cleared on readiness in the same transitions that clear `pendingSeed` (PhaseStepper.swift:176, :233;
  +Reconcile.swift:139 — the adopt path), and in that same mutate `t.model = adapter.model(for: pending)`
  is re-asserted, correcting `task.model` if a stale pre-kill report had reverted it.

This is epoch-independent, which matters: **Codex reports carry no epoch at all** — the file-tailer calls
`report(t.id, patch)` with no `observedEpoch` (OrchestraService.swift:382) — so v1's epoch gate would
have been Claude-only, violating the project's "must work for Claude AND Codex" rule.

### Did the vendor honor it? — a fail-safe detector

With the launch argv sourced from `pendingModel`, an Orchestra-side silent undo is now structurally
impossible, and the vendor-side one is empirically absent. The detector is therefore cheap insurance,
not the mechanism:

- In-memory `modelOverrideWatch: [UUID: String]` (NOT persisted — a daemon restart just drops it, which
  is harmless for a best-effort check, and it avoids a second Codable field).
- **Armed** when a relaunch lands `.live` carrying a `pendingModel` — i.e. after the old session is dead,
  so only the NEW session's reports can reach it. No epoch gate needed → works for Codex.
- **Consumed** by the first model-bearing report thereafter: on a genuine mismatch emit ONE `.warning`
  activity ("requested X; the agent came up on Y"), then remove the watch (no per-tick spam).
- Compared through the catalog, never raw `==`: the vendor's resolved id carries a date suffix the
  catalog omits (`claude-haiku-4-5` in claude-code-models.json vs the reported
  `claude-haiku-4-5-20251001`), so a raw compare would false-warn. Unresolvable id → treat as a match
  (fail safe: never false-warn).

```swift
func modelMatches(reported: String, requested: String, adapter: any Adapter) -> Bool {
    if reported == requested { return true }
    let ids = adapter.models().map(\.id)
    guard let canon = ids.first(where: { reported == $0 || reported.hasPrefix($0 + "-") }) else { return true }
    return canon == requested
}
```

## Validation

`Adapter.model(for:)` does not validate. The override is checked against **the card's own adapter's**
catalog (agentId cannot change — the transcript is vendor-specific), so a Codex id on a claude-code card
is rejected rather than becoming `claude --model gpt-5.6-terra`:

```swift
func resolveModelOverride(_ id: String?, for task: Task) throws -> AgentModel? {
    guard let id else { return nil }                       // absent = no override
    let want = id.trimmingCharacters(in: .whitespaces)
    let adapter = try registry.get(task.agentId)
    guard !want.isEmpty, let m = adapter.models().first(where: { $0.id == want }) else {
        throw OrchestraError.invalidParams(
            "unknown model '\(id)' for agent '\(task.agentId)'. Valid: \(adapter.models().map(\.id).joined(separator: ", "))")
    }
    return m
}
```

Called **first thing in the verb — before `clearSpawnPending`** (+Recovery.swift:48, :87) — so a rejected
model leaves the card completely untouched (v1 would have torn down an in-flight startup-watch first).
An explicitly-passed empty/whitespace model is an error, not a silent no-op. Case-sensitive (fails
closed). Known limit: if the bundled catalog resource fails to load, `models()` falls back to a hardcoded
list (ClaudeCodeAdapter.swift:30, CodexAdapter.swift:51) and validation could reject a genuinely valid
id — fails closed, acceptable, noted here rather than left as an unexamined assumption.

## Changes

No adapter or launch-path change: both adapters already build the model flag from `ctx.model` on resume
(ClaudeCodeAdapter.swift:226 → `--model`, CodexAdapter.swift:242 → `-m`), and Converge already feeds
`task.model.id` into both ctx paths. The override only has to reach `ctx.model`.

1. **`OrchestraKit/Model.swift`** — `Task.pendingModel: String?`. Task has a **custom Codable**
   (CodingKeys :541, `init(from:)` :551, `encode(to:)` :629), so this is 4 edits + the memberwise init;
   NOT added to `applyReportFields` (:684), deliberately — that omission is the whole defense.
2. **`OrchestraCore/OrchestraService+Recovery.swift`** — `resolveModelOverride` + `modelMatches`;
   `restart(_:model:)`, `resume(_:…model:)`, `resumeInCard(_:…model:)` (all defaulting `model: nil`, so
   the 4th caller — the idle-wake path at +Wake.swift:208 — is unchanged) set `pendingModel` + `model`
   inside their EXISTING `transition` mutate blocks.
3. **`OrchestraCore/OrchestraService+Converge.swift`** — `ctx.model = task.pendingModel ?? task.model.id`
   on both flavors.
4. **`OrchestraCore/PhaseStepper.swift` + `OrchestraService+Reconcile.swift`** — clear `pendingModel` /
   re-assert `task.model` wherever `pendingSeed` is cleared on the `.live` landing.
5. **`OrchestraCore/OrchestraService+Report.swift`** — arm/consume the `modelOverrideWatch` detector.
6. **`OrchestraKit/CommandCatalog.swift`** — `"model": strProp(…)` on `handoff`, `restart`, `resume`
   (MCP schemas are generated from this, so the MCP arg comes free).
7. **`OrchestraCore/CommandRegistry.swift`** — decode the optional `model` in the 3 handlers.
8. **`orchestra/CLIRunner.swift`** + **`CLIHelp.swift`** — `--model` flag + help on the 3 verbs.

**Desktop UI: OUT OF SCOPE** (BoardStore keeps sending `{ref}`); a restart model-picker would balloon
the diff. Called out in the merge-request.

## Separate commit (own commit on this branch, clearly labelled)

**Read-only cards lose their read-only flags on resume.** VERIFIED, and confirmed by the reviewer:
`AdapterContext.access` defaults `.readWrite` (Adapter.swift:22); the `.blank` ctx passes
`access: task.access` (+Converge.swift:162) but the `.resume` ctx (:169-171) **omits it**; and both
adapters' `resume()` DO emit the flags (ClaudeCodeAdapter.swift:227, CodexAdapter.swift:241). So a
read-only reviewer card that is resumed/handed-off comes back **writable**. One-line fix + test.
The same ctx also omits `startIn`; that one is harmless (it only picks the launch column) but I will
make it a deliberate, commented call rather than a second silent omission.

## Tests (`Tests/OrchestraCoreTests/`, existing conventions)

- **The BLOCKER-1 regression test, most important:** a stale statusline from the OLD session arriving
  while the card is `.relaunching` must NOT change the launch argv — assert the relaunch still goes up
  with the requested model even after a report reverts `task.model`.
- `resolveModelOverride` rejects an unknown id, a **cross-adapter** id (`gpt-5.6-terra` on a claude-code
  card), and an explicit empty string → `.invalidParams`, card untouched (still startup-pending).
- `restart(model:)` / `resume(model:)` / handoff land the override on `pendingModel` + `model`, and it
  survives to the launch argv (`--model <new>` for Claude, `-m <new>` for Codex).
- `pendingModel` is cleared on the `.live` landing, and LEFT SET when the launch fails.
- Detector: a Codex (nil-epoch) report is still checked; a mismatched report warns exactly once; a
  dated vendor id (`claude-haiku-4-5-20251001`) against the catalog id (`claude-haiku-4-5`) does NOT
  false-warn.
- `restart(model:)` on a `.discovered` (Codex) card, where restart also nils `agentSessionId`.
- Separate commit: a `.readOnly` card's resume argv still carries the read-only flags.

## What the review changed (v1 → v2)

The Claude reviewer (8147d8) raised 8 findings; I verified all 8 against the code and **confirmed all 8**
— v1's detector was simply the wrong shape. B1 (the field-delta write is unfenced, so the old session
reverts the override before the stepper launches) and M3 (Codex reports carry no epoch, so an epoch gate
is Claude-only) together killed the `pendingModelCheck` design; B2 (`applyReportFields` is a 7-field
whitelist, so `report()` cannot clear the field anyway) and M4 (catalog id vs dated vendor id, so raw
`==` false-warns) shaped what replaced it. minors 5-7 (validate before `clearSpawnPending`; document the
`models()` fallback; the +Wake.swift:208 caller and the stale-report test) are folded in above.
