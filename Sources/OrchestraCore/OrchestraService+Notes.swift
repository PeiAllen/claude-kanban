import Foundation

/// The phone's Notes page (M6): the markdown notes a card's branch changed/added, WITH content, so the
/// phone can render them in-app. The desktop's `openNotes` opens the same file set as Obsidian tabs on
/// the daemon host; the phone has no Obsidian, so it reads the content over the wire. Reuses the exact
/// changed-notes computation `openNotes` uses (`Launcher.changedNoteFiles`). Read-only, app-only — cf.
/// `diffText`, this is NOT a registry Command (an agent reads notes off disk itself).
extension OrchestraService {

    /// The changed/new markdown notes on a card's branch, each with its current content. Non-`.worktree`
    /// cards (no git baseline) resolve to `[]`. Unknown card → throws `unknownTask`.
    public func changedNotes(_ id: UUID) async throws -> [NoteFile] {
        let t = try await require(id)
        guard t.origin == .worktree else { return [] }
        try resolver.assertAllowed(t.cwd)
        // PR5 actor-hygiene (Task 5.1.4 fold-back): `resolvedParentRef` is `nonisolated`, so it moves
        // INSIDE the hop alongside `changedNoteFiles` — full purity, no residual on-actor git call.
        let l = launcher, cwd = t.cwd
        return try await offActor { l.changedNoteFiles(worktree: cwd, parentRef: self.resolvedParentRef(t)) }
    }
}
