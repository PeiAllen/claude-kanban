# PR: `--model` override on `restart` / `handoff` / `resume`

Tier M. Lets a live card be re-seated onto a different model **in place** — the escalation path
("this turned out to be architecture work, I need Fable") without spawning a successor card.

## Empirical finding (settles the central risk)

Probed both vendor CLIs for real in `.scratch/modelprobe`, throwaway sessions, ground truth read
from the transcript/rollout (not the agent's self-report):

- **Claude** — `claude -p --session-id S --model haiku` then `claude -p --resume S --model claude-opus-4-8`.
  Transcript `S.jsonl`: turn-1 assistant messages `"model":"claude-haiku-4-5-20251001"`, resumed turn
  `"model":"claude-opus-4-8"`. Same transcript appended. **`--model` re-binds on resume.**
- **Codex** — `codex exec -m gpt-5.6-luna` then `codex exec resume <sid> -m gpt-5.6-terra`. The SAME
  rollout file gains 4 `"model":"gpt-5.6-terra"` lines after the 2 luna ones; no fork.
  **`-m` re-binds on resume, and context carries.**

So the vendor does NOT snap back to the session's original model, and **handoff-with-model is sound**.
Ship the override on all three verbs — option (b) (restart-only) is unnecessary and wouldn't serve the
motivating use case anyway.

## The report-revert trap — what we do about it

`+Report.swift:133-139` overwrites `task.model` from the agent's own reported `modelId`. Since the
vendors honor the flag, the first report after a re-seat echoes the **new** model and reinforces the
override. The trap only springs if a vendor ever *stops* honoring it — and then it would erase the
override silently, which is the worst outcome.

So we ship (a) as a **detector**, not a mechanism: remember the requested id and check the first
report from the NEW session against it.

- New `Task.pendingModelCheck: String?` — the id we asked for, set by the verb.
- In `report()`, inside the existing snapshot half where `snap.modelId` lands: if `pendingModelCheck`
  is set **and** `observedEpoch == task.sessionEpoch` (only the post-relaunch session can confirm or
  deny; a stale pre-relaunch report carries the old epoch and is ignored — nil epoch also skips, no
  warn/no clear), then consume it:
  - reported id **==** requested → override confirmed, clear the field silently.
  - reported id **!=** requested → the vendor ignored us. Clear the field, let the reported (true)
    model land — `task.model` must reflect what is actually running, it is the `ctxPct` denominator —
    and emit an `.warning` activity: *"requested <X>; the agent came up on <Y>"*. Loud, not silent.

Only the FIRST model-bearing report of the new session is checked, so a later in-session `/model`
switch is untouched.

## Validation

`Adapter.model(for:)` does not validate. A `--model` override must be checked against **the card's own
adapter's** catalog (agentId cannot change — the transcript is vendor-specific), else you get
`claude --model gpt-5.6-terra`.

New helper in `+Recovery.swift`:

```swift
/// Resolve a --model override against the CARD'S OWN adapter catalog. nil → no override.
func resolveModelOverride(_ id: String?, for task: Task) throws -> AgentModel? {
    guard let id, !id.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    let adapter = try registry.get(task.agentId)          // throws .unknownAgent
    guard let m = adapter.models().first(where: { $0.id == id }) else {
        throw OrchestraError.invalidParams(
            "unknown model '\(id)' for agent '\(task.agentId)'. Valid: \(adapter.models().map(\.id).joined(separator: ", "))")
    }
    return m
}
```

Rejects unknown ids AND cross-adapter ids (a Codex id is simply not in the claude-code catalog) with
one message that names the valid set. Called BEFORE `transition` so a bad id is a clean RPC error that
leaves the card untouched.

## Changes

No adapter or launch-path change — both adapters already build the model flag from `ctx.model`, and
Converge already reads `task.model.id` into the AdapterContext on both the `.blank` (:160) and
`.resume` (:169) paths. The override only has to land on `Task.model`.

1. **`OrchestraKit/Model.swift`** — `Task.pendingModelCheck: String?` (Codable, defaulted nil).
2. **`OrchestraCore/OrchestraService+Recovery.swift`**
   - `resolveModelOverride(_:for:)` helper (above).
   - `resume(_:graceSeconds:seed:model:source:)` — validate, then in the existing `transition` mutate:
     `if let m { t.model = m; t.pendingModelCheck = m.id }`.
   - `restart(_:model:source:)` — same, inside its existing mutate block.
   - `resumeInCard(_:seed:graceSeconds:model:source:)` — thread `model` through to `resume`.
   All three default `model: nil`, so every existing caller is unchanged.
3. **`OrchestraCore/OrchestraService+Report.swift`** — the detector above.
4. **`OrchestraKit/CommandCatalog.swift`** — `"model": strProp(...)` on `handoff`, `restart`, `resume`.
   MCP schemas are generated from this, so the MCP arg comes free.
5. **`OrchestraCore/CommandRegistry.swift`** — decode optional `model` in the 3 handlers, pass it down.
6. **`orchestra/CLIRunner.swift`** — `--model` on `handoff` and the shared `restart`/`resume` branch
   (flags are free-form; additive).
7. **`orchestra/CLIHelp.swift`** — help text for the 3 verbs.

**Desktop UI: OUT OF SCOPE.** `BoardStore` keeps sending `{ref}`; a restart model-picker is a
nice-to-have that would balloon the diff. Called out in the merge-request.

## Separate commit (own commit on this branch, clearly labelled)

**Read-only cards lose their read-only flags on resume.** VERIFIED, real:
`AdapterContext.access` defaults to `.readWrite` (Adapter.swift:22); Converge's `.blank` ctx passes
`access: task.access` (:162) but the `.resume` ctx (:169-171) **omits it**; and both adapters' `resume()`
DO emit the flags — `ClaudeCodeAdapter:227` and `CodexAdapter:241` both call `accessFlags(ctx.access)`.
So a read-only reviewer card that gets resumed/handed-off relaunches **writable**. One-line fix
(`access: task.access` on the `.resume` ctx) + a test; separate commit, not folded into the feature.

## Tests (`Tests/OrchestraCoreTests/`, existing conventions)

- `resolveModelOverride` rejects an unknown id → `.invalidParams`, card untouched.
- Rejects a **cross-adapter** id (`gpt-5.6-terra` on a `claude-code` card) → `.invalidParams`.
- `restart(model:)` / `resume(model:)` / handoff land the override on `Task.model` and set
  `pendingModelCheck`.
- The override survives to the **launch argv**: the relaunched card's argv contains `--model <new>`
  (Claude) / `-m <new>` (Codex).
- Report detector: a same-epoch report echoing the requested id clears `pendingModelCheck` with no
  warning; a same-epoch report with a DIFFERENT id clears it, lands the reported model, and emits the
  warning activity; a STALE-epoch report does neither.
- Separate-commit test: a `.readOnly` card's resume argv still carries the read-only flags.

## Risks

- `pendingModelCheck` is a new persisted field — additive + defaulted, so old `tasks.json` decodes fine.
- The detector is best-effort: an agent that never reports a `modelId` just leaves the field set. Harmless
  (it is only ever read as "is a check pending"), and the next re-seat overwrites it.
