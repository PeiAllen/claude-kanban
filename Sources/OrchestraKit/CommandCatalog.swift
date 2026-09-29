import Foundation

/// The canonical command vocabulary — name + summary + JSON-schema params — with NO execution.
/// The daemon binds handlers to these in `CommandRegistry` (OrchestraCore); the MCP bridge builds
/// tools from them; a phone client builds/validates requests from them. Single source of truth for
/// command *shape* (the execution half lives in `OrchestraCore/CommandRegistry.swift`).
/// Who a command is exposed to. `.all` = the daemon dispatches it AND the MCP bridge advertises it as a
/// tool to agents. `.appOnly` = the daemon still dispatches it (the app uses it), but the MCP bridge does
/// NOT advertise it — an agent's normal tool-use can't reach it. `.terminalOnly` is available to the
/// Orchestra CLI inside an agent terminal but is likewise withheld from MCP. It is reserved for commands
/// intentionally limited to terminal access; human-only app affordances use `.appOnly` or remain outside
/// the catalog, such as `send-keys`, `capture`, and `inspect`.
public enum CommandExposure: Sendable, Equatable { case all, appOnly, terminalOnly }

/// The three verb kinds (spec §6). Query: read-only, retry-free, never changes `phase`. Mutation:
/// completes inline, idempotent, may hop off-actor, never changes `phase`. Convergence: the sync part
/// persists *durable intent* — a `transition()` (the phase-keyed stepper drives the rest, returning
/// `(card, rev)`) **or** durable side-state that a reconciler arm drives to its target. `send` is the
/// second shape: its durable intent is a queued inbox row, and the native sender advances that advisory
/// projection to handed-off or failed. It returns `{messageId, card}` — no `transition()`, no phase stepper.
public enum VerbKind: String, Sendable, Equatable { case query, mutation, convergence }

public struct CommandSchema: Sendable, Equatable {
    public let name: String
    public let summary: String
    public let params: JSONValue
    public let exposure: CommandExposure
    public let kind: VerbKind
    /// Deny-by-default ALLOW-set: a phase whose `Phase.Kind` is absent is denied. A future `Kind` is
    /// therefore denied — the fail-safe direction. Enforced at the one dispatch chokepoint
    /// (`CommandRegistry.dispatch`). `kind`/`phaseGate` are REQUIRED so every verb must classify itself.
    public let phaseGate: Set<Phase.Kind>
    public init(name: String, summary: String, params: JSONValue, exposure: CommandExposure = .all,
                kind: VerbKind, phaseGate: Set<Phase.Kind>) {
        self.name = name; self.summary = summary; self.params = params; self.exposure = exposure
        self.kind = kind; self.phaseGate = phaseGate
    }
}

public enum CommandCatalog {
    /// The commands the MCP bridge advertises as tools to agents. `.appOnly` and `.terminalOnly` commands
    /// remain withheld from tool enumeration. See `CommandExposure`.
    public static var mcpExposed: [CommandSchema] { all.filter { $0.exposure == .all } }

    // Gate allow-sets over Phase.Kind (spec §6 default gate policy). Deny-by-default: a kind absent from
    // the set is denied. Named once so the 32 classifications below read as the policy groups.
    private static let gAll: Set<Phase.Kind> =
        [.creatingWorktree, .launching, .live, .relaunching, .dead, .archivedPending, .archivedComplete]
    private static let gNonArchived: Set<Phase.Kind> =
        [.creatingWorktree, .launching, .live, .relaunching, .dead]
    private static let gLiveDead: Set<Phase.Kind> = [.live, .dead]

    // The canonical set. name/summary/params are copied verbatim from the original Commands.swift;
    // the handler bodies live alongside in OrchestraCore/CommandRegistry.swift, paired by name.
    public static let all: [CommandSchema] = [
        CommandSchema(name: "list", summary: "List cards (optionally by column).",
                      params: schema(["col": colProp(),
                                      "includeArchived": boolProp("Also list archived cards (default false).")],
                                     required: []),
                      kind: .query, phaseGate: gAll),

        CommandSchema(name: "spawn",
                      summary: "Spawn a new agent. Free text: `prompt`, and `title` (the card's name — "
                          + "pass it when you delegate).",
                      params: schema([
                          "note": strProp("A durable one-liner about what this card IS — e.g. \"Wave 2/4 — "
                              + "lease/claim delivery\". Unlike the live status blurb, telemetry never "
                              + "overwrites it and it survives restart/clear. Change it later with `set-note`."),
                          "title": strProp("Card title — the board's name for this card. Pass it whenever "
                              + "you delegate: a seed is NEVER used as a name, so an unnamed card falls back "
                              + "to its branch (worktree), its read-only target (👁), its prompt, or its "
                              + "directory. Rename later with `set-title`."),
                          "id": strProp("Client-minted UUID for idempotent retry — reuse the SAME id when "
                              + "re-issuing after a timeout to avoid a duplicate card; omit to have one minted "
                              + "(not retry-safe)."),
                          "prompt": strProp("Initial prompt — what the agent should start working on"),
                          "repo": strProp("Repository root (allowlisted). Omit for a freeform (cwd) card."),
                          "branch": strProp("Working branch. Omit for a freeform (cwd) card."),
                          "cwd": strProp("Freeform: run in this existing directory — no worktree is cut and "
                              + "the path is trusted via the sandbox (not the allowlist). Omit repo/branch when set."),
                          "access": strProp("'readWrite' (default) or 'readOnly' (agent cannot edit/write/commit)."),
                          "scratch": boolProp("Scratch: create a fresh throwaway ~/.orchestra/scratch/<id> dir, "
                              + "run there, and rm -rf it on archive. Omit repo/branch/cwd when set."),
                          "model": strProp("Model id (from the adapter's list)"),
                          "agent": strProp("Agent adapter to run: 'claude-code' (default) or 'codex'. Omit to "
                              + "infer from `model`, else use the configured default agent."),
                          "col": colProp(startInOnly: true),
                          "seed": strProp("Fork/fan-out context (the parent slice / handoff summary) the "
                              + "fresh card opens on — folded ahead of `prompt` into the launch turn."),
                          "base": strProp("Parent to create this card's branch ON TOP OF: an existing local "
                              + "branch, or a remote parent — 'origin/<branch>' (same-repo remote branch) or "
                              + "'pr#<N>' (pull request). A remote base is fetched and watched for merges. The "
                              + "new branch starts at the base's tip and its parent link is recorded. Ignored "
                              + "when the branch already exists. Omit for today's HEAD behavior."),
                      ], required: ["prompt"]),
                      kind: .convergence, phaseGate: gAll),

        CommandSchema(name: "set-title",
                      summary: "Rename a card. The card title is the board's SSOT for the name; the agent "
                          + "session's own name follows it at the next (re)launch (it cannot be changed "
                          + "mid-session). Name your card once the work takes shape, and update it as the "
                          + "work changes.",
                      params: schema(["ref": refProp(),
                                      "title": strProp("New card title (trimmed; 120 chars max)")],
                                     required: ["ref", "title"]),
                      kind: .mutation, phaseGate: gNonArchived),

        CommandSchema(name: "set-note",
                      summary: "Set (or clear) a card's durable note — the one-liner about what this card "
                          + "IS, e.g. its wave/layer in a larger plan. Distinct from the live status blurb, "
                          + "which telemetry overwrites every tick: a note is authored, and survives "
                          + "restart/clear. Keep yours current as the shape of the work changes. Send an "
                          + "empty `note` to clear it.",
                      params: schema(["ref": refProp(),
                                      "note": strProp("New note (trimmed; 120 chars max). Empty clears it.")],
                                     required: ["ref", "note"]),
                      kind: .mutation, phaseGate: gNonArchived),

        CommandSchema(name: "needs-input",
                      summary: "Declare that you are blocked on a decision only this card's owner can "
                          + "make, so the board can surface it — an agent waiting in its own terminal is "
                          + "otherwise indistinguishable from an idle one. Use it when you END a turn "
                          + "still blocked; if your harness has an in-session choices prompt, that is the "
                          + "better tool for a mid-turn question. Set/replace only: the daemon clears the "
                          + "declaration itself once your next turn starts, so re-declare if you are still "
                          + "blocked when that turn ends.",
                      params: schema(["ref": refProp(),
                                      "question": strProp("The one-line question (trimmed; 200 chars max)")],
                                     required: ["ref", "question"]),
                      kind: .mutation, phaseGate: gNonArchived),

        CommandSchema(name: "set-planned",
                      summary: "Declare how many child cards this card's approved plan will fan out — the "
                          + "target `m` of the `n/m` wave-progress bar (the bar shows dashed remainder until "
                          + "they spawn). Set it once your plan is approved and update it when the plan "
                          + "changes; send 0 (or omit `n`) to clear it. Worktree cards only.",
                      params: schema(["ref": refProp(),
                                      "n": intProp("Planned child count; 0 or absent clears it.")],
                                     required: ["ref"]),
                      kind: .mutation, phaseGate: gNonArchived),

        CommandSchema(name: "move", summary: "Move a card to a column (plan/impl/review).",
                      params: schema(["ref": refProp(), "col": colProp()], required: ["ref", "col"]),
                      kind: .mutation, phaseGate: gNonArchived),

        CommandSchema(name: "send", summary: "Queue a message to the agent's inbox for native provider delivery.",
                      params: schema(["ref": refProp(), "message": strProp("Text to send"),
                                      "id": strProp("Client-minted message UUID for idempotent retry — reuse the "
                                          + "SAME id when re-issuing after a timeout so the daemon dedups instead "
                                          + "of double-queuing; omit to have one minted (not retry-safe).")],
                                     required: ["ref", "message"]),
                      kind: .convergence, phaseGate: gNonArchived),

        CommandSchema(name: "inbox",
                      summary: "List a card's unresolved inbox messages in FIFO order. Set includeHistory to also "
                          + "return provider-accepted advisory history.",
                      params: schema(["ref": refProp(),
                                      "includeHistory": boolProp("Include provider-accepted advisory history.")],
                                     required: ["ref"]),
                      kind: .query, phaseGate: gAll),

        CommandSchema(name: "inbox-edit",
                      summary: "Edit an unresolved inbox message; editing a failed row requeues it.",
                      params: schema(["ref": refProp(),
                                      "id": strProp("Inbox message id (a UUID from `inbox`)"),
                                      "text": strProp("New message text")],
                                     required: ["ref", "id", "text"]),
                      kind: .mutation, phaseGate: gNonArchived),

        CommandSchema(name: "inbox-remove", summary: "Remove an inbox message, including handed-off history.",
                      params: schema(["ref": refProp(),
                                      "id": strProp("Inbox message id (a UUID from `inbox`)")],
                                     required: ["ref", "id"]),
                      kind: .mutation, phaseGate: gNonArchived),

        CommandSchema(name: "inbox-retry", summary: "Requeue a failed inbox message by id.",
                      params: schema(["ref": refProp(),
                                      "id": strProp("Inbox message id (a UUID from `inbox`)")],
                                     required: ["ref", "id"]),
                      kind: .mutation, phaseGate: gNonArchived),

        CommandSchema(name: "inbox-reorder",
                      summary: "Reorder a card's unresolved messages; failed rows must be resolved first.",
                      params: schema(["ref": refProp(),
                                      "ids": .object([
                                          "type": .string("array"),
                                          "items": .object(["type": .string("string")]),
                                          "description": .string("All unresolved message ids in the desired order"),
                                      ])],
                                     required: ["ref", "ids"]),
                      kind: .mutation, phaseGate: gNonArchived),

        CommandSchema(name: "wait",
                      summary: "Subscribe to watched card conclusions — a merge/archive (Done) or a death "
                          + "(exit) — and wake/remind the watcher when one fires. A delegate that just ends "
                          + "its turn does NOT conclude (it idles waiting); get its result via `send`, not "
                          + "`wait`. For reactive fan-out, re-issue on cards that remain.",
                      params: schema([
                          "refs": .object([
                              "type": .string("array"),
                              "items": .object(["type": .string("string")]),
                              "description": .string("Card refs to watch — UUID/shortId/orchestra:// URI"),
                          ]),
                          "watcher": strProp("The watching card's ref; its inbox coalesces each conclusion "
                              + "and it is woken (F2/F3). Omit for a CLI-style wait-and-return."),
                      ], required: ["refs"]),
                      kind: .mutation, phaseGate: gAll),

        CommandSchema(name: "handoff",
                      summary: "Clean-context handoff (F1): kill + resume THIS card in a fresh process, "
                          + "same session id, seeded with `context` folded together with its pending inbox.",
                      params: schema([
                          "ref": refProp(),
                          "context": strProp("Handoff context — the summary/instructions the resumed, "
                              + "clean-context session opens on (folded ahead of any queued inbox messages)."),
                          "model": strProp("RE-SEAT the card onto this model (from its OWN agent's list) as "
                              + "it resumes — how an agent escalates itself to a higher tier mid-task, "
                              + "carrying its context. Omit to keep the current model."),
                      ], required: ["ref", "context"]),
                      kind: .convergence, phaseGate: gLiveDead),

        CommandSchema(name: "set-parent",
                      summary: "Set or clear a card branch's parent link. With `parent`: 'adopt' (default) "
                          + "records parent + merge-base (history untouched); 'move' repoints and keeps the "
                          + "recorded base as the rebase anchor, marking restack-needed. Omit `parent` to clear.",
                      params: schema([
                          "ref": refProp(),
                          "parent": strProp("Parent branch ref: a local name, or a remote form "
                              + "'origin/<branch>' (same-repo remote branch) / 'pr#<N>' (pull request). "
                              + "Omit to clear the link."),
                          "mode": strProp("'adopt' (default): metadata-only relink, base = merge-base. "
                              + "'move': repoint + keep recorded base; marks restack-needed and nudges the "
                              + "owner to `git rebase --onto <new-parent> <recorded-base>`. Ignored for a "
                              + "remote parent (no local history to rebase yet)."),
                          "watch": boolProp("Remote parents only: poll the PR/branch and auto-redirect this "
                              + "card onto the parent's base when it merges. Default off."),
                      ], required: ["ref"]),
                      kind: .mutation, phaseGate: gLiveDead),

        CommandSchema(name: "tree",
                      summary: "Lineage snapshot — parent/children per card. Scope by `ref` or `repo`; "
                          + "omit both for all active cards.",
                      params: schema([
                          "ref": refProp(),
                          "repo": strProp("Limit to cards in this repo root."),
                      ], required: []),
                      kind: .query, phaseGate: gAll),

        CommandSchema(name: "synced",
                      summary: "Report that this card merged/restacked its parent down: record the "
                          + "parent's current tip as the sync base and clear the stale/behind signal.",
                      params: schema(["ref": refProp()], required: ["ref"]),
                      kind: .mutation, phaseGate: gLiveDead),

        CommandSchema(name: "shipped",
                      summary: "Post-merge bookkeeping after a child branch was merged into its parent: "
                          + "notify + wake the shipped child, retarget the child's own children onto the "
                          + "grandparent (keeping each one's recorded base) with a restack nudge. Idempotent. "
                          + "Refuses if the parent tip hasn't advanced past the recorded base (nothing "
                          + "merged) unless `force`.",
                      params: schema([
                          "ref": refProp(),
                          "force": boolProp("Skip the parent-tip-advanced sanity check (use for a genuinely "
                              + "empty/no-op squash). Default off."),
                      ], required: ["ref"]),
                      kind: .mutation, phaseGate: gLiveDead),

        CommandSchema(name: "merge-request",
                      summary: "Declare this card's work ready to integrate — the ONE ship verb, for every "
                          + "parent kind. The daemon routes it: a live card owning the parent branch is "
                          + "nudged to squash-merge and run `shipped`; an unowned target (main, a bare "
                          + "branch, a remote parent, or no parent link) is RECORDED for a human, who "
                          + "merges however they choose. Either way the card is marked 'merge requested' "
                          + "until it resolves, and re-sends dedup. Call it and stop.",
                      params: schema(["ref": refProp()], required: ["ref"]),
                      kind: .mutation, phaseGate: gLiveDead),

        CommandSchema(name: "borrow",
                      summary: "Cut a throwaway worktree checking out this card's BARE parent branch (no "
                          + "live card owns it). Returns the worktree path. A human-directed primitive, NOT "
                          + "a way to ship: to declare your own work ready, use `merge-request` and stop. "
                          + "Refuses a remote parent, and refuses one a live card owns.",
                      params: schema(["ref": refProp()], required: ["ref"]),
                      kind: .mutation, phaseGate: gLiveDead),

        CommandSchema(name: "release",
                      summary: "Tear down this card's borrow worktree (the daemon also sweeps it on archive "
                          + "and at startup).",
                      params: schema(["ref": refProp()], required: ["ref"]),
                      kind: .mutation, phaseGate: gLiveDead),

        CommandSchema(name: "status", summary: "Current state of a card (incl. derived running).",
                      params: schema(["ref": refProp()], required: ["ref"]),
                      kind: .query, phaseGate: gAll),

        CommandSchema(name: "archive", summary: "Archive a card (done + off the board).",
                      params: schema(["ref": refProp()], required: ["ref"]),
                      // gAll (NOT non-archived): the spec's idempotency guarantee wants a retried archive of an
                      // archived card to be `.noop` success, not a phaseGated error. Deviation from §6's gate
                      // table — the funnel/handler is the real entry-edge enforcer. See the plan's decisions.
                      kind: .convergence, phaseGate: gAll),

        CommandSchema(name: "reopen", summary: "Reopen an archived card (recreate its worktree + resume the agent).",
                      params: schema(["ref": refProp()], required: ["ref"]),
                      kind: .convergence, phaseGate: [.archivedPending, .archivedComplete]),

        CommandSchema(name: "restart", summary: "Start a new blank session in the same worktree (no prompt re-handed).",
                      params: schema(["ref": refProp(),
                                      "model": strProp("RE-SEAT the card onto this model (from its OWN "
                                          + "agent's list) for the new session. Omit to keep the current one.")],
                                     required: ["ref"]),
                      kind: .convergence, phaseGate: [.live, .dead, .relaunching]),

        CommandSchema(name: "resume", summary: "Re-attempt resuming the card's existing agent session.",
                      params: schema(["ref": refProp(),
                                      "model": strProp("RE-SEAT the card onto this model (from its OWN "
                                          + "agent's list) as it resumes. Omit to keep the current one.")],
                                     required: ["ref"]),
                      kind: .convergence, phaseGate: [.live, .dead, .relaunching]),

        CommandSchema(name: "shell", summary: "Open a shell window in the worktree; returns its tmux target.",
                      params: schema(["ref": refProp(),
                                      "window": strProp("Reuse/create this exact window (idempotent, e.g. a phone-owned `phone-<client>`); omit for a fresh shell-N")],
                                     required: ["ref"]),
                      kind: .mutation, phaseGate: gLiveDead),

        // `.appOnly`: inspect launches an interactive read-only `claude` inside the card's tmux session
        // (a visible shell tab). That's a HUMAN affordance (the inspector's eye button) — exposing it as
        // an agent tool let agents open surprise claude sessions on *peer* cards. Daemon + CLI still use it.
        CommandSchema(name: "inspect", summary: "Open a read-only claude in the card's worktree shell.",
                      params: schema(["ref": refProp()], required: ["ref"]),
                      exposure: .appOnly, kind: .mutation, phaseGate: gLiveDead),

        CommandSchema(name: "closeShell", summary: "Close a shell window opened via `shell`.",
                      params: schema(["ref": refProp(), "window": strProp("Shell window name, e.g. shell-1")],
                                     required: ["ref", "window"]),
                      kind: .mutation, phaseGate: gLiveDead),

        CommandSchema(name: "exec", summary: "Run a one-shot command in the worktree.",
                      params: schema(["ref": refProp(), "cmd": strProp("Command to run (/bin/sh -c)"),
                                      "timeout": intProp("Seconds")],
                                     required: ["ref", "cmd"]),
                      kind: .mutation, phaseGate: gLiveDead),

        CommandSchema(name: "sessions", summary: "Debug handles for a card: tmux targets + agent session id.",
                      params: schema(["ref": refProp()], required: ["ref"]),
                      kind: .query, phaseGate: gAll),

        CommandSchema(name: "capture",
                      summary: "Read-only snapshot of a card's tmux pane (agent or a shell window). "
                          + "No attach, no resize.",
                      params: schema(["ref": refProp(),
                                      "window": strProp("Window to read: 'agent' (default) or a shell "
                                          + "window like 'shell-1'")],
                                     required: ["ref"]),
                      exposure: .appOnly, kind: .query, phaseGate: gAll),

        CommandSchema(name: "publish-image",
                      summary: "Publish a temporary PNG or JPEG reference for this agent's transcript.",
                      params: schema([
                          "ref": refProp(),
                          "path": strProp("Absolute PNG or JPEG source path to copy into temporary daemon media"),
                          // pattern/maxLength come from the shared TranscriptImageCaption so the schema an
                          // MCP client validates against IS the rule the daemon enforces. The caption
                          // doubles as the filename each app gives the copy it stages for the human, which
                          // is why it is a slug rather than free text.
                          "caption": patternProp(
                              "Optional short label shown beside the transcript reference, and the "
                                  + "filename the human sees when they save or copy it — "
                                  + TranscriptImageCaption.rule,
                              pattern: TranscriptImageCaption.pattern,
                              maxLength: TranscriptImageCaption.maxLength),
                      ], required: ["ref", "path"]),
                      exposure: .all, kind: .mutation, phaseGate: gLiveDead),

        CommandSchema(name: "send-keys",
                      summary: "Send live keystrokes to a card's tmux window — an ordered chord of named "
                          + "keys (Esc, Up/Down/Left/Right, Tab, Enter, C-c, PgUp/PgDn, Home/End) and/or "
                          + "literal text. Distinct from `send` (inbox queue): no implicit Enter.",
                      params: schema([
                          "ref": refProp(),
                          "keys": .object([
                              "type": .string("array"),
                              "description": .string(
                                  "Ordered chord elements; each is {\"key\": <name>} (Esc, Up, Down, Left, "
                                  + "Right, Tab, Enter, C-c, PgUp, PgDn, Home, End) or {\"text\": <literal>}."),
                          ]),
                          "window": strProp("Target window (default 'agent')"),
                      ], required: ["ref", "keys"]),
                      exposure: .appOnly, kind: .mutation, phaseGate: gLiveDead),

        CommandSchema(name: "trustState",
                      summary: "Is a directory already trusted? Read-only ledger query for the spawn "
                          + "sheet's trust indicator — never grants (granting is a human-only surface).",
                      params: schema(["path": strProp("Absolute directory path to check")],
                                     required: ["path"]),
                      kind: .query, phaseGate: gAll),

        CommandSchema(name: "batch-spawn", summary: "Spawn many agents at once (one per entry).",
                      // The item schema is DECLARED, not just described in prose: a bare `type: array` makes a
                      // typed MCP client expose `tasks` as an array of STRINGS, so a caller cannot express the
                      // per-item fields at all (and each string then fails the handler's `item.uuid`/
                      // `item.string`). The handler's required set is mirrored here.
                      params: schema(["tasks": .object([
                          "type": .string("array"),
                          "description": .string("One spawn per entry. Per-item `title` names that card — pass "
                              + "it, since a fan-out of unnamed cards is all named off its shared branch."),
                          "items": schema([
                              "prompt": strProp("Initial prompt — what this agent should start working on"),
                              "repo": strProp("Repository root (allowlisted)"),
                              "branch": strProp("Working branch for this card"),
                              "title": strProp("Card title — the board's name for this card (pinned; a seed is "
                                  + "never used as a name). Omit to derive one from the branch."),
                              "note": strProp("A durable one-liner about what this card IS; telemetry never "
                                  + "overwrites it."),
                              "model": strProp("Model id (from the adapter's list)"),
                              "col": colProp(startInOnly: true),
                              "seed": strProp("Fork/fan-out context this card opens on, folded ahead of `prompt`."),
                              "base": strProp("Parent branch to create this card's branch ON TOP OF."),
                              "id": strProp("Client-minted UUID for idempotent retry — reuse the same per-item "
                                  + "ids when re-issuing a batch; omit to have them minted."),
                          ], required: ["prompt", "repo", "branch"]),
                      ])], required: ["tasks"]),
                      kind: .convergence, phaseGate: gAll),

        CommandSchema(name: "trust",
                      summary: "Grant a human's trust for a directory so agents may run there with write "
                          + "access. Requires a human to approve (MCP elicitation / interactive CLI); an "
                          + "agent can only trigger it, never self-grant.",
                      params: schema(["path": strProp("Directory to trust (the card's cwd / repo root)")],
                                     required: ["path"]),
                      kind: .mutation, phaseGate: gNonArchived),

        CommandSchema(name: "shared",
                      summary: "Shared agent files (CLAUDE.md, AGENTS.md, .claude/…) across worktrees. "
                          + "`sync` sends this card's edits and receives others'; `status` shows the "
                          + "policy table, un-ignored leaves, a standing conflict and the read-only git "
                          + "command for the store; `resolve` commits your fixed conflict files; `adopt` "
                          + "untracks the given paths (default: CLAUDE.md, AGENTS.md, .claude/commands/ship.md) "
                          + "from the project and shares them.",
                      params: schema([
                          "ref": refProp(),
                          "op": strProp("'sync' | 'status' | 'resolve' | 'adopt'"),
                          "paths": .object(["type": .string("array"),
                                            "items": .object(["type": .string("string")]),
                                            "description": .string("adopt only: repo-relative paths to adopt.")]),
                      ], required: ["ref", "op"]),
                      kind: .mutation, phaseGate: gAll.subtracting([.archivedPending])),

        CommandSchema(name: "shared-policy",
                      summary: "Read or set a repo's propagation policy (tracked | shared | ephemeral) per item.",
                      params: schema([
                          "repo": strProp("Repository root (allowlisted)"),
                          "item": strProp("Item name. Omit to list the whole table."),
                          "policy": strProp("'tracked' | 'shared' | 'ephemeral'. Omit to read the item's row."),
                      ], required: ["repo"]),
                      exposure: .appOnly, kind: .mutation, phaseGate: gAll),
    ]

    // MARK: - schema builders (moved verbatim from Commands.swift; now public for Kit consumers)

    public static func schema(_ props: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map { .string($0) }),
        ])
    }
    // Required-ness is driven by the `required:` array in `schema(...)`, so these just describe shape.
    public static func strProp(_ desc: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(desc)])
    }
    /// A string param that additionally advertises its shape. The registry dispatches on `phaseGate` and
    /// never validates params against a schema, so this does not enforce anything server-side — its job is
    /// to let an MCP client reject a malformed value before the call. The verb's handler must enforce the
    /// same rule; both sides read it from one shared definition so they cannot drift.
    public static func patternProp(_ desc: String, pattern: String, maxLength: Int) -> JSONValue {
        .object([
            "type": .string("string"), "description": .string(desc),
            "pattern": .string(pattern), "maxLength": .int(maxLength),
        ])
    }
    public static func intProp(_ desc: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(desc)])
    }
    public static func boolProp(_ desc: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(desc)])
    }
    public static func refProp() -> JSONValue {
        strProp("Card ref — UUID, shortId, or orchestra://task/<ref> URI")
    }
    /// Column enum prop. `startInOnly` restricts it to the two spawn-start columns (plan/impl).
    public static func colProp(startInOnly: Bool = false) -> JSONValue {
        let cols = startInOnly ? ["plan", "impl"] : Column.allCases.map(\.rawValue)
        return .object([
            "type": .string("string"),
            "enum": .array(cols.map { .string($0) }),
            "description": .string(startInOnly ? "Start in: plan or impl" : "Column"),
        ])
    }
}
