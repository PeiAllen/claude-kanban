import Foundation

/// The reader's daemon side: document discovery, content, live-watch reconciliation, and the image
/// endpoint. Read-only and app-only — like `diffText`, none of these are registry Commands, so they
/// never surface as MCP tools (an agent reads its own working directory off disk).
///
/// Documents are a property of the WORKING DIRECTORY, not of the card: two cards on one directory list
/// the same documents, the same way they show the same diff. So there is no card-kind gate anywhere in
/// here — a freeform or scratch card has documents exactly like a worktree card does.
extension OrchestraService {

    /// Every document in the card's working directory — path + whatever git can say, NO CONTENT.
    ///
    /// Discovery is a pruned filesystem walk, deliberately git-independent: a gitignored `notes/` must
    /// be found exactly like a tracked `docs/`. Git runs afterwards ONLY to decorate the subset it
    /// knows about, so most results carry no status, which is correct rather than missing data.
    ///
    /// Content is a separate call. Shipping it here is fine for three changed documents and wrong for two
    /// hundred documents — a phone pays for every byte, and the reader opens one file at a time.
    public func listDocuments(_ id: UUID) async throws -> [DocRef] {
        try await documentRefs(id)
    }

    /// The ordered document set — the ONE place discovery + git decoration + ordering happen. Both the
    /// in-app reader and "Open in Obsidian" read from here, so the two surfaces can never disagree
    /// about what a card's documents are.
    func documentRefs(_ id: UUID) async throws -> [DocRef] {
        let t = try await require(id)
        // NO card-kind gate and NO `assertAllowed(t.cwd)`. Documents are a property of the WORKING
        // DIRECTORY, so a freeform or scratch card has them exactly like a worktree card does — and
        // the repo allowlist is the wrong question for a cwd. `allowedRoots` is
        // [reposRoot, worktreesRoot] + allowlist, which a borrowed card's arbitrary directory and a
        // scratch dir both fail; it guards paths a CLIENT NAMES, and `cwd` is the card's own recorded
        // directory, already authorized at spawn (worktree: derived by Orchestra; borrowed: the trust
        // ledger; scratch: created by Orchestra). Containment is enforced where it matters — every
        // document path is realpath-checked against this cwd in `readDocument`.
        let l = launcher, cwd = t.cwd
        let parentRef = resolvedParentRef(t)
        return try await offActor {
            let discovered = DocumentDiscovery.walk(root: cwd)
            // Git's opinion, where it has one — the walk already found the files regardless.
            let statuses = Dictionary(
                l.changedMarkdown(worktree: cwd, parentRef: parentRef)
                    .map { ($0.path, $0.added ? DocumentStatus.added : .modified) },
                uniquingKeysWith: { a, _ in a })
            // A discovered document git does NOT TRACK was created in this workspace. That one rule
            // covers three cases the diff alone misses: a gitignored document anywhere (not just under
            // `notes/`), an untracked document when no merge base resolves (the whole diff is skipped
            // then), and a repo with no commits yet.
            //
            // `nil` means "not a git repo", which is different from "tracks nothing": there, NO
            // document gets a status and the reader falls back to showing everything.
            let tracked = l.trackedPathSet(worktree: cwd)
            let refs = discovered.map { path -> DocRef in
                if let s = statuses[path] { return DocRef(path: path, status: s) }
                if let tracked, !tracked.contains(path) { return DocRef(path: path, status: .added) }
                return DocRef(path: path, status: nil)
            }
            // CHANGED FIRST, then everything else, each alphabetical. What the agent just touched is
            // what the reviewer came for; the rest is browsable below it.
            return refs.sorted {
                let (a, b) = ($0.status != nil, $1.status != nil)
                return a == b ? $0.path < $1.path : a
            }
        }
    }

    /// One document's content. Size-capped, so a pathological file cannot blow
    /// the wire. The path must be one `listDocuments` would return — the same membership rule the asset
    /// endpoint uses, so a client cannot read an arbitrary file by naming it here.
    public func readDocument(_ id: UUID, path: String) async throws -> String {
        let t = try await require(id)
        let cwd = t.cwd
        return try await offActor {
            guard DocumentDiscovery.isDocument(path), !DocumentDiscovery.isPruned(relativePath: path)
            else { throw OrchestraError.invalidParams("\(path) is not a readable document") }
            // Containment, the regular-file test, and the size cap all come from ONE open descriptor.
            // Validating the pathname and then re-opening it is a TOCTOU: the name can become a symlink
            // between the two calls. `ContainedFile` explains the rest.
            let (data, size) = try ContainedFile.read(
                (cwd as NSString).appendingPathComponent(path),
                containedIn: PathResolver.canonical(cwd),
                limit: Launcher.documentContentCap)
            var content = String(decoding: data, as: UTF8.self)
            // The cut is on a BYTE boundary, so a split multi-byte character decodes to U+FFFD. That is
            // the right trade: capping by characters means reading the whole file first, which is the
            // thing the cap exists to prevent.
            if size > Launcher.documentContentCap { content += "\n… (document truncated)\n" }
            return content
        }
    }

    /// Reconcile the daemon's note watches against the live worktree cards.
    ///
    /// Idempotent and self-healing, so call it freely: at boot after recovery, once a card's worktree
    /// exists, and when a card is archived or its worktree goes. A missed call costs a late or briefly
    /// orphaned stream, repaired at the next call — which is why this needs no teardown protocol.
    public func syncDocumentWatches() async {
        let cards = await store.snapshot().tasks
            .filter { !$0.archived && !$0.cwd.isEmpty }
            .map { (id: $0.id, worktree: $0.cwd) }
        await documentWatches.sync(cards: cards)
    }

    /// Bytes for an image THE NOTE REFERENCES.
    ///
    /// Five gates, in order: the document is one this workspace actually has, read under the SAME
    /// containment rule as `readDocument`; the asset appears as an image reference in that document; the
    /// file finally opened lives inside the worktree; it carries an image extension; and it is a regular
    /// file within the size cap.
    ///
    /// Gate 2 is what keeps this from being an arbitrary worktree file read. Without it the endpoint
    /// serves any image-extension file anywhere under any card's worktree — a wider capability than
    /// anything the daemon ships today, and wider than `listDir` (names only) or `readDocument`
    /// (one document the workspace actually has).
    ///
    /// Gate 2 is RECOGNITION, not a markdown parser, so it approximates what the page renders. That is
    /// tolerable precisely because it is not the containment boundary: an over-broad allowlist widens
    /// the surface by in-tree IMAGE files, and gates 3-5 hold regardless of what it says.
    public func documentAsset(_ id: UUID, documentPath: String, assetPath: String) async throws -> DocumentAsset {
        let t = try await require(id)
        // No card-kind gate and no cwd allowlist check — see `listDocuments` for why. Containment comes
        // from the descriptor-based check in `ContainedFile`, not from `allowedRoots`.
        // Capture everything the hop needs BEFORE it: `offActor` takes a Sendable closure, so reaching
        // back for an actor-isolated property inside it is a compile error.
        let cwd = t.cwd
        return try await offActor {
            // GATE 1 — the document must be a document this workspace actually has. Discovery, not the
            // git-derived changed set: a gitignored note is a perfectly valid document to read.
            guard DocumentDiscovery.isDocument(documentPath),
                  !DocumentDiscovery.isPruned(relativePath: documentPath) else {
                throw OrchestraError.invalidParams("\(documentPath) is not a readable document")
            }
            // GATE 2 — the asset must be referenced BY that note. The allowlist is derived from the
            // note read off DISK, never from anything a client supplied.
            //
            // The document is read through the SAME contained reader `readDocument` uses, so it is held
            // to the same containment rule. Reading it by name alone let a card-local
            // `docs/foreign.md -> /elsewhere/foreign.md` supply the allowlist from outside the
            // workspace — a document `readDocument` refuses outright.
            let root = PathResolver.canonical(cwd)
            let (noteData, _) = try ContainedFile.read(
                (cwd as NSString).appendingPathComponent(documentPath),
                containedIn: root, limit: Launcher.documentContentCap)
            let allowed = MarkdownAssets.referencedImages(
                in: String(decoding: noteData, as: UTF8.self),
                documentDir: (documentPath as NSString).deletingLastPathComponent)
            let path = MarkdownAssets.normalize(assetPath)
            guard allowed.contains(path) else {
                throw OrchestraError.invalidParams("\(assetPath) is not referenced by \(documentPath)")
            }
            return try Self.readDocumentAsset(path, cwd: root)
        }
    }

    /// GATES 3-5, split out so the containment/type/size rules live in one place. `path` is already
    /// normalized and allowlisted by the caller, and `cwd` is already canonical.
    static func readDocumentAsset(_ path: String, cwd: String) throws -> DocumentAsset {
        // GATE 4 — image types only. On the requested name, because the extension is what selects the
        // MIME type the page will be handed.
        let ext = (path as NSString).pathExtension.lowercased()
        guard let mime = documentAssetMimeTypes[ext] else {
            throw OrchestraError.invalidParams("\(ext) is not a renderable note asset")
        }
        // GATES 3 + 5 — containment, regular-file, and the size cap, all proved from ONE descriptor.
        // Doing this by pathname was three separate races: the name could become a symlink out of the
        // worktree after the containment check, a fifo under an allowed extension blocked the open
        // forever, and `attributesOfItem` described a different file than the one finally read.
        let (data, _) = try ContainedFile.read((cwd as NSString).appendingPathComponent(path),
                                               containedIn: cwd,
                                               limit: documentAssetCap, maxSize: documentAssetCap)
        return DocumentAsset(path: path, mimeType: mime, base64: data.base64EncodedString())
    }

    /// SVG is included deliberately: an `<img src=…svg>` cannot run script — only an SVG loaded as a
    /// document or a frame can — and the reader only ever references assets from `<img>`.
    static let documentAssetMimeTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "svg": "image/svg+xml", "avif": "image/avif",
    ]
    static let documentAssetCap = 8 * 1024 * 1024
}
