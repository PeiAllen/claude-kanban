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
            // Git's opinion, where it has one. A non-repo, or a card with no resolvable base, simply
            // yields no statuses — the walk already found the files.
            let statuses = Dictionary(
                l.changedMarkdown(worktree: cwd, parentRef: parentRef)
                    .map { ($0.path, $0.added ? DocumentStatus.added : .modified) },
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

    /// One document's content. Size-capped, so a pathological file cannot blow
    /// the wire. The path must be one `listDocuments` would return — the same membership rule the asset
    /// endpoint uses, so a client cannot read an arbitrary file by naming it here.
    public func readDocument(_ id: UUID, path: String) async throws -> String {
        let t = try await require(id)
        let cwd = t.cwd
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
            guard let data = FileManager.default.contents(atPath: abs) else {
                throw OrchestraError.io("cannot read \(path)")
            }
            var content = String(decoding: data, as: UTF8.self)
            if content.utf8.count > Launcher.documentContentCap {
                content = String(content.prefix(Launcher.documentContentCap)) + "\n… (document truncated)\n"
            }
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
    /// Five gates, in order: the document is one this card changed; the asset appears as an image
    /// reference IN that note; the resolved path sits inside the worktree by REALPATH; it carries an
    /// image extension; and it is a regular file within the size cap.
    ///
    /// Gate 2 is what keeps this from being an arbitrary worktree file read. Without it the endpoint
    /// serves any image-extension file anywhere under any card's worktree — a wider capability than
    /// anything the daemon ships today, and wider than `listDir` (names only) or `readDocument`
    /// (one document the workspace actually has).
    public func documentAsset(_ id: UUID, documentPath: String, assetPath: String) async throws -> DocumentAsset {
        let t = try await require(id)
        // No card-kind gate and no cwd allowlist check — see `listDocuments` for why. Containment
        // comes from the realpath check in `readDocumentAsset`, not from `allowedRoots`.
        // Capture everything the hop needs BEFORE it: `offActor` takes a Sendable closure, so reaching
        // back for an actor-isolated property inside it is a compile error.
        let l = launcher, cwd = t.cwd
        let parentRef = resolvedParentRef(t)
        return try await offActor {
            // GATE 1 — the document must be a document this workspace actually has. Discovery, not the
            // git-derived changed set: a gitignored note is a perfectly valid document to read.
            guard DocumentDiscovery.isDocument(documentPath),
                  !DocumentDiscovery.isPruned(relativePath: documentPath) else {
                throw OrchestraError.invalidParams("\(documentPath) is not a readable document")
            }
            // GATE 2 — the asset must be referenced BY that note. The allowlist is derived from the
            // note read off DISK, never from anything a client supplied.
            let noteAbs = (cwd as NSString).appendingPathComponent(documentPath)
            guard let noteData = FileManager.default.contents(atPath: noteAbs) else {
                throw OrchestraError.io("cannot read \(documentPath)")
            }
            let allowed = MarkdownAssets.referencedImages(
                in: String(decoding: noteData, as: UTF8.self),
                documentDir: (documentPath as NSString).deletingLastPathComponent)
            let path = MarkdownAssets.normalize(assetPath)
            guard allowed.contains(path) else {
                throw OrchestraError.invalidParams("\(assetPath) is not referenced by \(documentPath)")
            }
            return try Self.readDocumentAsset(path, cwd: cwd)
        }
    }

    /// GATES 3-5, split out so the containment/type/size rules live in one place. `path` is already
    /// normalized and allowlisted by the caller.
    static func readDocumentAsset(_ path: String, cwd: String) throws -> DocumentAsset {
        // GATE 3 — REALPATH containment. Do NOT substitute `NSString.standardizingPath`: it collapses
        // `..` lexically and leaves symlinks intact, so a worktree containing `notes/pics -> /` would
        // let `notes/pics/etc/hosts` pass a textual prefix check while resolving outside the worktree.
        let abs = PathResolver.canonical((cwd as NSString).appendingPathComponent(path))
        let root = PathResolver.canonical(cwd)
        guard abs == root || abs.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw OrchestraError.pathNotAllowed(path)
        }
        // GATE 4 — image types only.
        let ext = (abs as NSString).pathExtension.lowercased()
        guard let mime = documentAssetMimeTypes[ext] else {
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
        guard size <= documentAssetCap else {
            throw OrchestraError.invalidParams("asset is \(size) bytes; the cap is \(documentAssetCap)")
        }
        guard let data = FileManager.default.contents(atPath: abs) else {
            throw OrchestraError.io("cannot read \(path)")
        }
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
