import Foundation
import OrchestraKit

/// The card's AUTHORED metadata — the two fields a human or an agent sets deliberately, as opposed to the
/// telemetry the report pipeline pushes. `title` is the naming SSOT (derived from the card's own identity at
/// spawn, pinned by any explicit source, pushed to the session as `--name` at every relaunch); `note` is a
/// durable one-liner about what the card IS. Both are invisible to `report()`. See `CardNaming` for the
/// naming rules and `docs/09-design-decisions.md` for the why.
extension OrchestraService {

    /// The `.worktree` card that owns `cwd` — the daemon-side twin of `BoardStore.attachedTarget`'s
    /// branchless arm, used to stamp a read-only card's "👁 <target>" title at spawn.
    ///
    /// Ordered by `(createdAt, id)`, matching `BoardStore.attachedBefore`: `createdAt` alone is NOT a total
    /// order (task dates serialize at second resolution), so co-located siblings would otherwise resolve to
    /// an arbitrary winner depending on snapshot input order.
    func attachedTargetTitle(cwd: String, excluding id: UUID, among cards: [Task]) -> String? {
        cards
            .filter { $0.id != id && $0.origin == .worktree && !$0.archived && $0.cwd == cwd }
            .min { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }?
            .title
    }

    /// Rename a card. The title is display-authoritative, so this is the direct way to fix a name — the
    /// agent session's own name follows at its next (re)launch (`--name`), and cannot be changed while it
    /// runs. `.explicit` pins the new title against every derived default.
    ///
    /// Any card may rename any card, exactly like `send`/`archive`/`restart`: Orchestra has no self-only
    /// verb scoping, and an orchestrator naming the delegate it just spawned is a first-class use.
    @discardableResult
    public func setTitle(ref: String, title: String, source: ActivitySource = .daemon) async throws -> Task {
        let t = try await resolveRef(ref)
        let clean = CardNaming.normalize(title)   // the SAME bound spawn's explicit title uses
        guard !clean.isEmpty else {
            throw OrchestraError.invalidParams("title must be non-empty")
        }
        guard let (saved, rev) = try? await store.update(t.id, {
            $0.title = clean
            $0.titleSource = .explicit
        }) else { throw OrchestraError.unknownTask(t.id.uuidString) }
        emit(.taskUpserted(saved), rev: rev)
        emitActivity(.command, saved, source, "renamed → “\(clean)”")
        return saved
    }

    /// Set (or clear) the card's durable note — the one-liner about what this card IS, which outlives every
    /// turn because the report pipeline never touches it. An empty/whitespace `note` CLEARS it back to nil,
    /// which is the only way to remove one; that is why this verb does not reject an empty string the way
    /// `set-title` does (a card must always have a name, but need not have a note).
    @discardableResult
    public func setNote(ref: String, note: String, source: ActivitySource = .daemon) async throws -> Task {
        let t = try await resolveRef(ref)
        let clean = CardNaming.normalizeNote(note)
        guard let (saved, rev) = try? await store.update(t.id, { $0.note = clean.isEmpty ? nil : clean })
        else { throw OrchestraError.unknownTask(t.id.uuidString) }
        emit(.taskUpserted(saved), rev: rev)
        emitActivity(.command, saved, source, clean.isEmpty ? "cleared its note" : "note → “\(clean)”")
        return saved
    }

    /// `set-planned` — an orchestrator DECLARES its wave's plan size (the `m` of the card's `n/m` progress
    /// bar): how many child cards the approved plan fans out. `n <= 0` (or absent at the verb) clears it.
    /// Stored on the branch's git-config (`branch.<b>.orchestra-planned`) and broadcast on
    /// `treeStat.plannedChildren`. Worktree-only: the count lives on the card's BRANCH, which a
    /// freeform/scratch card has none of (mirrors `set-parent`'s worktree gate).
    @discardableResult
    public func setPlanned(ref: String, n: Int, source: ActivitySource = .daemon) async throws -> Task {
        let t = try await resolveRef(ref)
        guard t.origin == .worktree else {
            throw OrchestraError.invalidParams("only worktree cards have a branch to plan against")
        }
        try await lineage.setPlanned(repo: t.repo, branch: t.branch, n: n)
        await recomputeChildProgress(t.id)   // broadcast the new plannedChildren
        emitActivity(.command, t, source, n > 0 ? "planned \(n) children" : "cleared planned count")
        return (await store.get(t.id)) ?? t
    }

    /// `needs-input` — the agent DECLARES that it is blocked on a decision only the card's owner can make.
    /// Set/replace only: there is deliberately no clear form, because a declaration an agent could retract
    /// is one it would forget to retract. The daemon retires it instead, at the only events that prove the
    /// question is moot — the agent's next turn demonstrably starting, or a completed session replacement
    /// (see `transition` and `confirmDelivery`).
    ///
    /// Empty is REJECTED, unlike `set-note`: an empty note means "no note", but an empty question would be
    /// an amber with nothing to answer.
    @discardableResult
    public func needsInput(ref: String, question: String, source: ActivitySource = .daemon) async throws -> Task {
        let t = try await resolveRef(ref)
        let clean = CardNaming.normalizeQuestion(question)
        guard !clean.isEmpty else {
            throw OrchestraError.invalidParams("needs-input requires a question — one line stating what you need decided")
        }
        // Stamp WHEN via the injected clock (`now`), so the fileTail turn-start fence has a declaration
        // time to compare a Codex rollout line's own write time against — and so the whole thing is
        // testable without wall-clock. Hoisted out of the `@Sendable` store.update closure so it doesn't
        // capture the actor's `now`.
        let declaredAt = now()
        guard let (saved, rev) = try? await store.update(t.id, {
            $0.pendingQuestion = PendingQuestion(text: clean, declaredAt: declaredAt)
        }) else { throw OrchestraError.unknownTask(t.id.uuidString) }
        emit(.taskUpserted(saved), rev: rev)
        emitActivity(.command, saved, source, "needs input → “\(clean)”")
        return saved
    }

    /// Retire a declared question. Called from the daemon's proof-of-turn seams ONLY (never from a verb):
    /// `transition`'s turn-start / session-landing edges and `confirmDelivery`'s receipt. Idempotent and
    /// delta-gated — a card with no question costs one store read and writes nothing.
    func clearPendingQuestion(_ id: UUID) async {
        guard let t = await store.get(id), t.pendingQuestion != nil else { return }
        if let (saved, rev) = try? await store.update(id, { $0.pendingQuestion = nil }) {
            emit(.taskUpserted(saved), rev: rev)
        }
    }
}
