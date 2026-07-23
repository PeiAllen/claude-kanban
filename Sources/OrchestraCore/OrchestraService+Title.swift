import Foundation
import OrchestraKit

/// Card naming: the daemon half of `CardNaming`. The card title is the SSOT — derived from the card's own
/// identity at spawn, pinned by any explicit source, and pushed to the agent session as `--name` at every
/// (re)launch. See `CardNaming` for the rules themselves and `docs/09-design-decisions.md` for the why.
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
}
