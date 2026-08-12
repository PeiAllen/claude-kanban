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

    /// Every document in the card's working directory — path + whatever git can say, NO CONTENT.
    ///
    /// Discovery is a pruned filesystem walk, deliberately git-independent: a gitignored `notes/` must
    /// be found exactly like a tracked `docs/`. Git runs afterwards ONLY to decorate the subset it
    /// knows about, so most results carry no status, which is correct rather than missing data.
    ///
    /// Content is a separate call. Shipping it here is fine for three changed notes and wrong for two
    /// hundred documents — a phone pays for every byte, and the reader opens one file at a time.
    public func listDocuments(_ id: UUID) async throws -> [DocRef] {
        let t = try await require(id)
        // Documents are a property of the WORKING DIRECTORY, not of the card, so there is no card-kind
        // gate here: a freeform or scratch card has documents exactly like a worktree card does.
        try resolver.assertAllowed(t.cwd)
        let l = launcher, cwd = t.cwd
        let parentRef = resolvedParentRef(t)
        return try await offActor {
            let discovered = DocumentDiscovery.walk(root: cwd)
            // Git's opinion, where it has one. A non-repo, or a card with no resolvable base, simply
            // yields no statuses — the walk already found the files.
            let statuses = Dictionary(
                l.changedMarkdown(worktree: cwd, parentRef: parentRef)
                    .map { ($0.path, $0.added ? NoteStatus.added : .modified) },
                uniquingKeysWith: { a, _ in a })
            let refs = discovered.map { DocRef(path: $0, status: statuses[$0]) }
            // CHANGED FIRST, then everything else, each alphabetical. What the agent just touched is
            // what the reviewer came for; the rest is browsable below it.
            return refs.sorted {
                let (a, b) = ($0.status != nil, $1.status != nil)
                return a == b ? $0.path < $1.path : a
            }
        }
    }

    /// One document's content. Size-capped like `changedNoteFiles`, so a pathological file cannot blow
    /// the wire. The path must be one `listDocuments` would return — the same membership rule the asset
    /// endpoint uses, so a client cannot read an arbitrary file by naming it here.
    public func readDocument(_ id: UUID, path: String) async throws -> String {
        let t = try await require(id)
        try resolver.assertAllowed(t.cwd)
        let cwd = t.cwd, pathResolver = resolver
        return try await offActor {
            guard DocumentDiscovery.isDocument(path), !DocumentDiscovery.isPruned(relativePath: path)
            else { throw OrchestraError.invalidParams("\(path) is not a readable document") }
            // REALPATH containment, same rule as the asset endpoint: `standardizingPath` would leave a
            // symlink intact and let `notes/x -> /` escape a textual prefix check.
            let abs = PathResolver.canonical((cwd as NSString).appendingPathComponent(path))
            let root = PathResolver.canonical(cwd)
            guard abs.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
                throw OrchestraError.pathNotAllowed(path)
            }
            try pathResolver.assertAllowed(abs)
            guard let data = FileManager.default.contents(atPath: abs) else {
                throw OrchestraError.io("cannot read \(path)")
            }
            var content = String(decoding: data, as: UTF8.self)
            if content.utf8.count > Launcher.noteContentCap {
                content = String(content.prefix(Launcher.noteContentCap)) + "\n… (document truncated)\n"
            }
            return content
        }
    }

    /// Reconcile the daemon's note watches against the live worktree cards.
    ///
    /// Idempotent and self-healing, so call it freely: at boot after recovery, once a card's worktree
    /// exists, and when a card is archived or its worktree goes. A missed call costs a late or briefly
    /// orphaned stream, repaired at the next call — which is why this needs no teardown protocol.
    public func syncNoteWatches() async {
        let cards = await store.snapshot().tasks
            .filter { !$0.archived && $0.origin == .worktree }
            .map { (id: $0.id, worktree: $0.cwd) }
        await noteWatches.sync(cards: cards)
    }

    /// Bytes for an image THE NOTE REFERENCES.
    ///
    /// Five gates, in order: the note is one this card changed; the asset appears as an image
    /// reference IN that note; the resolved path sits inside the worktree by REALPATH; it carries an
    /// image extension; and it is a regular file within the size cap.
    ///
    /// Gate 2 is what keeps this from being an arbitrary worktree file read. Without it the endpoint
    /// serves any image-extension file anywhere under any card's worktree — a wider capability than
    /// anything the daemon ships today, and wider than `listDir` (names only) or `changedNotes`
    /// (git-reported `.md` for one card).
    public func noteAsset(_ id: UUID, notePath: String, assetPath: String) async throws -> NoteAsset {
        let t = try await require(id)
        guard t.origin == .worktree else { throw OrchestraError.invalidParams("not a worktree card") }
        try resolver.assertAllowed(t.cwd)
        // Capture everything the hop needs BEFORE it: `offActor` takes a Sendable closure, so reaching
        // back for an actor-isolated property inside it is a compile error.
        let l = launcher, cwd = t.cwd, pathResolver = resolver
        let parentRef = resolvedParentRef(t)
        return try await offActor {
            // GATE 1 — the note must be one this card actually changed. Paths only: `changedNotes`
            // would read the full content of every changed note just to test membership.
            guard l.changedNotes(worktree: cwd, parentRef: parentRef).contains(notePath) else {
                throw OrchestraError.invalidParams("\(notePath) is not one of this card's changed notes")
            }
            // GATE 2 — the asset must be referenced BY that note. The allowlist is derived from the
            // note read off DISK, never from anything a client supplied.
            let noteAbs = (cwd as NSString).appendingPathComponent(notePath)
            guard let noteData = FileManager.default.contents(atPath: noteAbs) else {
                throw OrchestraError.io("cannot read \(notePath)")
            }
            let allowed = MarkdownAssets.referencedImages(
                in: String(decoding: noteData, as: UTF8.self),
                noteDir: (notePath as NSString).deletingLastPathComponent)
            let path = MarkdownAssets.normalize(assetPath)
            guard allowed.contains(path) else {
                throw OrchestraError.invalidParams("\(assetPath) is not referenced by \(notePath)")
            }
            return try Self.readNoteAsset(path, cwd: cwd, resolver: pathResolver)
        }
    }

    /// GATES 3-5, split out so the containment/type/size rules live in one place. `path` is already
    /// normalized and allowlisted by the caller.
    static func readNoteAsset(_ path: String, cwd: String, resolver: PathResolver) throws -> NoteAsset {
        // GATE 3 — REALPATH containment. Do NOT substitute `NSString.standardizingPath`: it collapses
        // `..` lexically and leaves symlinks intact, so a worktree containing `notes/pics -> /` would
        // let `notes/pics/etc/hosts` pass a textual prefix check while resolving outside the worktree.
        let abs = PathResolver.canonical((cwd as NSString).appendingPathComponent(path))
        let root = PathResolver.canonical(cwd)
        guard abs == root || abs.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw OrchestraError.pathNotAllowed(path)
        }
        try resolver.assertAllowed(abs)          // independent second containment check

        // GATE 4 — image types only.
        let ext = (abs as NSString).pathExtension.lowercased()
        guard let mime = noteAssetMimeTypes[ext] else {
            throw OrchestraError.invalidParams("\(ext) is not a renderable note asset")
        }

        // GATE 5 — STAT BEFORE READING. `contents(atPath:)` loads the whole file, so checking the cap
        // afterwards would let a multi-gigabyte `.png` exhaust the daemon before it was rejected. The
        // regular-file check matters too: a fifo under an allowed extension would block forever.
        let attrs = try FileManager.default.attributesOfItem(atPath: abs)
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else {
            throw OrchestraError.invalidParams("\(path) is not a regular file")
        }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? Int.max
        guard size <= noteAssetCap else {
            throw OrchestraError.invalidParams("asset is \(size) bytes; the cap is \(noteAssetCap)")
        }
        guard let data = FileManager.default.contents(atPath: abs) else {
            throw OrchestraError.io("cannot read \(path)")
        }
        return NoteAsset(path: path, mimeType: mime, base64: data.base64EncodedString())
    }

    /// SVG is included deliberately: an `<img src=…svg>` cannot run script — only an SVG loaded as a
    /// document or a frame can — and the reader only ever references assets from `<img>`.
    static let noteAssetMimeTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "svg": "image/svg+xml", "avif": "image/avif",
    ]
    static let noteAssetCap = 8 * 1024 * 1024
}
