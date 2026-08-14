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

    /// The document list, answered CONDITIONALLY — the reader's slow poll.
    ///
    /// The validator covers each document's path AND its stat stamp, not just the path set. Both halves
    /// are load-bearing: paths catch a document created or deleted, and stamps catch one whose bytes
    /// moved — which is what changes git's `M`/`A` answer, and therefore which section of the reader a
    /// document sits in. Statting the set costs ~1.2ms next to the walk's ~80ms.
    ///
    /// The two git forks behind `status` run ONLY when that digest moves, which is the whole point: a
    /// poll that finds nothing spends no subprocesses at all.
    ///
    /// The BASE is folded in for the same reason: `status` is derived against it, so a base that moved
    /// under an unchanged tree — a rebase, a retargeted parent — re-dates every badge while every path
    /// and stamp stays put. Without it the validator would answer "unchanged" indefinitely and the only
    /// repair would be reopening the picker, which is a gesture nobody knows to make. It costs one
    /// `git merge-base` per poll, and the caller hands it straight to `decorate`, so no fork is repeated.
    public func listDocuments(_ id: UUID, ifNoneMatch: String?) async throws -> DocumentList {
        let t = try await require(id)
        let l = launcher, cwd = t.cwd
        let parentRef = resolvedParentRef(t)
        return try await offActor {
            let discovered = DocumentDiscovery.walk(root: cwd)
            var fingerprint = ""
            for rel in discovered {
                var st = stat()
                let abs = (cwd as NSString).appendingPathComponent(rel)
                if stat(abs, &st) == 0 {
                    #if canImport(Darwin)
                    let secs = st.st_mtimespec.tv_sec
                    #else
                    let secs = st.st_mtim.tv_sec
                    #endif
                    fingerprint += "\(rel)\u{1}\(st.st_size)\u{1}\(secs)\n"
                } else {
                    fingerprint += "\(rel)\u{1}?\n"
                }
            }
            // The BASE, folded in. `status` is derived against it, so a base that moved under an
            // unchanged tree re-dates every badge while every path and stamp stays put. Without this the
            // validator would keep answering "unchanged" and the only repair would be reopening the
            // picker — a gesture nobody knows to make.
            let base = l.mergeBase(worktree: cwd, parentRef: parentRef)
            fingerprint += "\u{2}base\u{1}\(base ?? "-")\n"
            let digest = DocumentContentHash.hex(Data(fingerprint.utf8))
            guard digest != ifNoneMatch else { return DocumentList(hash: digest, documents: nil) }
            return DocumentList(hash: digest,
                                documents: Self.decorate(discovered, launcher: l, cwd: cwd, base: base))
        }
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
            Self.decorate(DocumentDiscovery.walk(root: cwd), launcher: l, cwd: cwd,
                          base: l.mergeBase(worktree: cwd, parentRef: parentRef))
        }
    }

    /// Ask git what it can say about an already-discovered set, and order it. The two forks in here are
    /// the expensive half of a list, which is why the conditional endpoint skips them when its validator
    /// matches.
    static func decorate(_ discovered: [String], launcher l: Launcher,
                         cwd: String, base: String?) -> [DocRef] {
        // Git's opinion, where it has one — the walk already found the files regardless.
        let statuses = Dictionary(
            l.changedMarkdown(worktree: cwd, base: base)
                .map { ($0.path, $0.added ? DocumentStatus.added : .modified) },
            uniquingKeysWith: { a, _ in a })
        // A discovered document git does NOT TRACK was created in this workspace. That one rule covers
        // three cases the diff alone misses: a gitignored document anywhere (not just under `notes/`),
        // an untracked document when no merge base resolves (the whole diff is skipped then), and a
        // repo with no commits yet.
        //
        // `nil` means "not a git repo", which is different from "tracks nothing": there, NO document
        // gets a status and the reader falls back to showing everything.
        let tracked = l.trackedPathSet(worktree: cwd)
        let refs = discovered.map { path -> DocRef in
            if let s = statuses[path] { return DocRef(path: path, status: s) }
            if let tracked, !tracked.contains(path) { return DocRef(path: path, status: .added) }
            return DocRef(path: path, status: nil)
        }
        // CHANGED FIRST, then everything else, each alphabetical. What the agent just touched is what
        // the reviewer came for; the rest is browsable below it.
        return refs.sorted {
            let (a, b) = ($0.status != nil, $1.status != nil)
            return a == b ? $0.path < $1.path : a
        }
    }

    /// One document's content, answered CONDITIONALLY — the reader's fast poll, and the mechanism that
    /// replaced the filesystem watcher.
    ///
    /// `ifNoneMatch` is the hash from a previous answer. When it still matches, no bytes are sent — and
    /// the bytes are the whole cost, because the phone reads this over a tunnel.
    ///
    /// The daemon still reads and hashes the file on every poll: ~250µs for a 256 KB document, local,
    /// against a poll every couple of seconds. Skipping that would mean caching a stamp-to-hash pair per
    /// document, which is per-document daemon state this design deliberately does not keep — and it
    /// would buy a quarter of a millisecond. Content is hashed rather than stat-compared for a second
    /// reason anyway: a touch, or an atomic save that rewrote identical bytes, moves mtime and inode
    /// without changing a thing the reader should redraw.
    public func readDocument(_ id: UUID, path: String, ifNoneMatch: String?) async throws -> DocumentContent {
        let content = try await readDocument(id, path: path)
        let hash = DocumentContentHash.hex(Data(content.utf8))
        return DocumentContent(hash: hash, content: hash == ifNoneMatch ? nil : content)
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

    /// Bytes for an image THE NOTE REFERENCES.
    ///
    /// Five gates, in order: the document is one this workspace actually has, read under the SAME
    /// containment rule as `readDocument`; the asset appears as an image reference in that document; the
    /// file finally opened lives inside the worktree; it carries an image extension; and it is a regular
    /// file within the size cap.
    ///
    /// GATE 2 IS DEFENSE IN DEPTH, and it is worth being exact about who it stops — an earlier version
    /// of this comment claimed it kept the endpoint from being "a wider capability than anything the
    /// daemon ships today", which is simply false. `exec` runs `sh -c` in the same working directory and
    /// returns 256 KB of stdout, on the same socket, to the same clients. Any caller that can reach
    /// `documentAsset` can already read the file outright.
    ///
    /// The one adversary it does narrow is script that escapes DOMPurify inside the reader's WebView.
    /// That script cannot call `exec` — the scheme handler is its only route to the daemon — so scoping
    /// this endpoint to the open document genuinely shrinks what it can reach. The CSP already denies it
    /// anywhere to send the bytes, which is why this is depth rather than the boundary.
    ///
    /// So it scopes what a CLIENT may name, and nothing more. It is not a check on the document's
    /// author, who can reference any in-tree image for real, and its regexes need not agree exactly with
    /// what the page renders. Containment does not rest on it — gates 3-5 hold whatever it says.
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
