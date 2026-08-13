import Foundation

/// "View changes" — open a worktree in Zed, landing on its branch-vs-base diff.
public struct Launcher: Sendable {
    let resolver: PathResolver

    public init(resolver: PathResolver) { self.resolver = resolver }

    /// Cap on how many tabs `openInObsidian` opens at once, so a document-heavy workspace doesn't
    /// flood Obsidian. The rest stay one click away in the vault tree.
    static let obsidianTabCap = 15

    /// Per-document byte cap for `readDocument` — a pathological file is truncated with a sentinel so
    /// the wire payload stays bounded, mirroring `diffText`'s cap. Documents are markdown, so this
    /// virtually never fires.
    static let documentContentCap = 256 * 1024

    /// "Open in Obsidian" — open the card's WORKING DIRECTORY as an Obsidian vault, its documents
    /// each seeded into a tab.
    ///
    /// The caller supplies `tabs`, already discovered and ordered. That is deliberate: this and the
    /// in-app reader must show the SAME set, so discovery lives in one place and this function only
    /// does the Obsidian part. It used to run its own git-derived scan, which meant the two surfaces
    /// could disagree about what a card's documents were.
    ///
    /// The vault is the working directory itself — not a `notes/` subdirectory — because Obsidian only
    /// opens files inside a registered vault, and documents span several top-level dirs. With no
    /// documents the vault still opens, just with no seeded tabs.
    ///
    /// HOW THE TABS OPEN: firing `obsidian://open?path=…` per file does NOT work — Obsidian's open URI
    /// has no honored new-tab parameter (verified: `newtab=true` on both the `path=` and `vault=&file=`
    /// routes just reuses the active leaf, so only the last file survives). The official `obsidian`
    /// CLI's `newtab` flag needs Obsidian ≥ 1.12.7, and Advanced-URI means a bundled plugin. Instead we
    /// SEED `.obsidian/workspace.json` before opening; Obsidian restores that layout when it loads the
    /// vault. Caveat: a vault window ALREADY open in a running Obsidian keeps its in-memory workspace,
    /// so the seed only takes on a fresh load — acceptable for the review flow.
    ///
    /// `.obsidian/` is gitignored at the repo root, so registering the directory as a vault never
    /// pollutes the card's diff (and the script's own `.gitignore`-append is then a no-op).
    ///
    /// Returns `(opened:` tabs seeded, ≤ cap `, total:` documents `)` for the caller's toast.
    @discardableResult
    public func openInObsidian(_ workdir: String, tabs: [String]) throws -> (opened: Int, total: Int) {
        #if !os(macOS)
        throw OrchestraError.io("opening documents in Obsidian is a macOS-only convenience")
        #else
        // No `assertAllowed` here, for the same reason the document endpoints dropped it: `workdir` is
        // the card's own recorded directory, already authorized at spawn, and the repo allowlist would
        // refuse a freeform or scratch card outright.
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let script = (home as NSString).appendingPathComponent(".claude/open-obsidian-vault.sh")
        guard FileManager.default.fileExists(atPath: script) else { throw OrchestraError.toolMissing(script) }

        // Seed the tabs BEFORE the script opens the vault, so Obsidian restores them on load. Capped so
        // a document-heavy workspace doesn't seed dozens of tabs.
        let opened = Array(tabs.prefix(Self.obsidianTabCap))
        if !opened.isEmpty { seedWorkspaceTabs(worktree: workdir, relPaths: opened) }

        // The script resolves jq/python3/osascript/open on PATH; augmentedPATH (applied by Proc.run)
        // adds Homebrew + per-user bins so they're found under launchd's minimal PATH.
        let r = try Proc.run(["bash", script, workdir])
        if !r.ok { throw OrchestraError.io(r.stderr.isEmpty ? "open-obsidian-vault.sh failed" : r.stderr) }
        return (opened: opened.count, total: tabs.count)
        #endif
    }

    /// Write `<worktree>/.obsidian/workspace.json` describing one Obsidian tab per changed note, so a
    /// fresh vault load opens them all side by side. Mirrors Obsidian's own layout shape: a `split`
    /// holding one `tabs` container whose `leaf` children are the markdown files. Best-effort — a
    /// failure here just means the vault opens without pre-seeded tabs.
    func seedWorkspaceTabs(worktree: String, relPaths: [String]) {
        let obsidianDir = (worktree as NSString).appendingPathComponent(".obsidian")
        try? FileManager.default.createDirectory(atPath: obsidianDir, withIntermediateDirectories: true)
        let leaves: [[String: Any]] = relPaths.enumerated().map { i, rel in
            ["id": String(format: "orchnotesleaf%03d", i),
             "type": "leaf",
             "state": ["type": "markdown",
                       "state": ["file": rel, "mode": "preview", "source": false]]]
        }
        let workspace: [String: Any] = [
            "main": ["id": "orchnotesroot", "type": "split", "direction": "vertical",
                     "children": [["id": "orchnotestabs", "type": "tabs", "currentTab": 0,
                                   "children": leaves]]],
            "active": leaves.first?["id"] as? String ?? "",
            "lastOpenFiles": relPaths,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: workspace, options: [.prettyPrinted])
        else { return }
        let dest = URL(fileURLWithPath: (obsidianDir as NSString).appendingPathComponent("workspace.json"))
        try? data.write(to: dest)
    }

    /// A changed markdown document: its worktree-relative path + whether it's modified vs base or
    /// newly added. This is the git DECORATION behind the document list — discovery itself is a
    /// filesystem walk, so this only says what git happens to know. Deletions are excluded.
    struct ChangedNote { let path: String; let added: Bool }

    /// The changed/new markdown documents with their M/A status — the git half of what a card has
    /// the desktop's Open-notes and the phone's Notes page both use, before dropping status. Two sources,
    /// unioned (notes-first, deduped): the gitignored `notes/` vault scanned off disk (git can't see it),
    /// plus every other `.md` the branch changed vs base (docs, specs, skills — tracked, so git-visible).
    /// Notes come first so a card's plans/designs get first claim on the tab cap. Only empty when the card
    /// has no `notes/` files AND no resolvable base / changed markdown.
    func changedMarkdown(worktree: String, parentRef: String?) -> [ChangedNote] {
        // The git-visible side first: tracked/untracked-non-ignored `.md` changed vs base (docs, specs,
        // skills — and tracked notes in a repo that doesn't ignore notes/). This is the only source with
        // real M/A status, so it wins on any overlap with the disk scan below.
        var gitAdded: [String: Bool] = [:]        // path -> is-an-add-vs-base
        var gitOrder: [String] = []
        if let base = mergeBase(worktree: worktree, parentRef: parentRef) {
            for c in changedFiles(worktree: worktree, base: base)
            where c.status != .deleted && c.newPath.lowercased().hasSuffix(".md") {
                if gitAdded[c.newPath] == nil { gitOrder.append(c.newPath) }
                gitAdded[c.newPath] = (c.status == .added)
            }
        }
        var seen = Set<String>()
        var out: [ChangedNote] = []
        // Notes first (they get first claim on the tab cap): the gitignored notes/ vault scanned off disk,
        // which git's diff/ls-files never reports. Reuse git's M/A status if it happens to know the file
        // (tracked notes), else it's new-to-base → `.added`.
        for path in untrackedMarkdownUnderNotes(worktree: worktree) where seen.insert(path).inserted {
            out.append(ChangedNote(path: path, added: gitAdded[path] ?? true))
        }
        // Then the remaining git-changed markdown outside notes/ (docs, specs, skills).
        for path in gitOrder where seen.insert(path).inserted {
            out.append(ChangedNote(path: path, added: gitAdded[path]!))
        }
        return out
    }

    /// The UNTRACKED `.md` files under the worktree's `notes/` vault (plans + designs), as worktree-
    /// relative paths (`notes/…`). `notes/` is gitignored scratch, so git's diff/ls-files never reports
    /// it — a disk walk is the only way Open-notes / the phone can surface a card's notes. Recursive
    /// (design vaults nest, `notes/designs/<slug>/…`); skips dot components (`.obsidian`, `.trash`).
    /// Tracked notes are excluded: the git set already reports the changed ones and rightly omits the
    /// unchanged ones, so a repo that DOES track `notes/` behaves exactly as before this scan existed.
    func untrackedMarkdownUnderNotes(worktree: String) -> [String] {
        let notesRoot = (worktree as NSString).appendingPathComponent("notes")
        guard let en = FileManager.default.enumerator(atPath: notesRoot) else { return [] }
        var candidates: [String] = []
        for case let rel as String in en {
            guard rel.lowercased().hasSuffix(".md"),
                  !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            candidates.append("notes/" + rel)
        }
        guard !candidates.isEmpty else { return [] }
        let tracked = trackedPaths(worktree: worktree, under: "notes")
        return candidates.filter { !tracked.contains($0) }.sorted()
    }

    /// Every path git tracks in this working directory, or `nil` when it is not a git repo at all.
    ///
    /// The nil case is load-bearing for the document list: it distinguishes "git has nothing to say
    /// about this directory" (a scratch dir — so NO document gets a status, and the reader shows
    /// everything) from "git tracks this repo, and this file is not in it" (the card created it).
    /// An empty repo succeeds with an empty set, which is correct — nothing is committed yet, so every
    /// document is new.
    func trackedPathSet(worktree: String) -> Set<String>? {
        guard let r = try? Proc.run(["git", "ls-files", "-z"], cwd: worktree), r.ok else { return nil }
        return Set(r.stdout.split(separator: "\0").map(String.init).filter { !$0.isEmpty })
    }

    /// The paths git tracks under `dir` (worktree-relative) — subtracted from the notes disk scan so a
    /// repo that tracks `notes/` still shows only *changed* notes (via the diff set), not every file.
    private func trackedPaths(worktree: String, under dir: String) -> Set<String> {
        guard let r = try? Proc.run(["git", "ls-files", "-z", "--", dir], cwd: worktree), r.ok
        else { return [] }
        return Set(r.stdout.split(separator: "\0").map(String.init).filter { !$0.isEmpty })
    }

    public func openInZed(_ worktree: String, parentRef: String?) throws {
        #if !os(macOS)
        throw OrchestraError.io("opening in Zed is a macOS-only convenience")
        #else
        try resolver.assertAllowed(worktree)
        guard Proc.toolExists("zed") else {
            // No CLI (Zed.app installed without running "Install CLI") — launch the bundle instead.
            // `open` can't pass `--diff`, so this just opens the worktree; the user is one step from
            // the git panel.
            let r = try Proc.run(["/usr/bin/open", "-a", "Zed", worktree])
            if !r.ok { throw OrchestraError.zedMissing }   // `open` fails only when the app isn't found
            return
        }

        // Open the worktree project + its branch-vs-base diff in ONE new window. `-n` (new window) is
        // essential: without it `zed --diff` routes the diff into whatever Zed window is currently
        // focused (typically a *different* project), and reusing an existing window drops the diff
        // entirely. A dedicated new window keeps the worktree project and the multi-diff together.
        //
        // Passing two DIRECTORIES to `--diff` (rather than one `--diff old new` per file) makes Zed
        // recurse and render every changed file in a SINGLE multi-diff multibuffer — the same view as
        // its native "Branch Diff" button, which has no external trigger of its own.
        //
        // Ordering is load-bearing: Zed's CLI positional (`PATHS_WITH_POSITION…`) is a trailing var-arg,
        // so once a positional path is seen, EVERYTHING after it — including `--diff` — is consumed as a
        // literal path rather than parsed as a flag. Putting the worktree first made Zed open `--diff`,
        // `old`, and `new` as three separate paths (an empty `--diff` buffer + two folders). So the
        // `--diff old new` flag MUST come before the worktree positional.
        var argv = ["zed", "-n"]
        if let dirs = try? branchDiffDirs(worktree: worktree, parentRef: parentRef) {
            argv += ["--diff", dirs.old, dirs.new]
        }
        argv.append(worktree)
        let r = try Proc.run(argv)
        if !r.ok { throw OrchestraError.io(r.stderr.isEmpty ? "zed failed to open" : r.stderr) }
        #endif
    }

    // MARK: - branch-vs-base diff

    private enum ChangeStatus { case modified, added, deleted }
    private struct Change { let status: ChangeStatus; let oldPath: String; let newPath: String }

    /// Build two mirror directories — `old` and `new` — that contain ONLY the files the worktree's
    /// branch changed relative to the commit it forked from (the merge-base with the repo's default
    /// branch), each at its worktree-relative path. Pointing `zed --diff old new` at the pair makes
    /// Zed recurse and show every change in one multi-diff multibuffer.
    ///
    /// The `new` side is a tree of *hardlinks* to the live worktree files; the `old` side holds that
    /// file's content at the base, materialized via `git show`. An add has an empty placeholder on the
    /// `old` side; a delete has one on the `new` side. Returns `nil` when the base can't be determined
    /// or nothing changed — the caller then just opens the worktree with no diff.
    ///
    /// Hardlinks (not symlinks) because Zed renders a symlinked diff side as empty; a hardlink reads as
    /// the real file. The multibuffer is for review — to *edit*, use the worktree project that opens in
    /// the same window (Zed saves atomically, so edits in the diff don't reliably reach the worktree).
    func branchDiffDirs(worktree: String, parentRef: String?) throws -> (old: String, new: String)? {
        guard let base = mergeBase(worktree: worktree, parentRef: parentRef) else { return nil }
        let changes = changedFiles(worktree: worktree, base: base)
        guard !changes.isEmpty else { return nil }

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("orchestra-zeddiff-\(UUID().uuidString)", isDirectory: true)
        let oldRoot = root.appendingPathComponent("old", isDirectory: true)
        let newRoot = root.appendingPathComponent("new", isDirectory: true)

        for change in changes {
            // Both sides key off the same relative path so Zed pairs them as one file's diff. A rename
            // is shown as a modify at the file's new location.
            let rel = change.status == .deleted ? change.oldPath : change.newPath

            let oldDst = oldRoot.appendingPathComponent(rel)
            try fm.createDirectory(at: oldDst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if change.status == .added {
                fm.createFile(atPath: oldDst.path, contents: Data())
            } else {
                // Binary-safe: `git show` streams the blob straight to disk (no String round-trip).
                let code = try? Proc.runStdoutToFile(
                    ["git", "show", "\(base):\(change.oldPath)"], cwd: worktree, outputURL: oldDst)
                if code != 0 { fm.createFile(atPath: oldDst.path, contents: Data()) }
            }

            let newDst = newRoot.appendingPathComponent(rel)
            try fm.createDirectory(at: newDst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let live = (worktree as NSString).appendingPathComponent(change.newPath)
            if change.status != .deleted && fm.fileExists(atPath: live) {
                // Copy is the fallback when the temp dir is on a different volume (hardlinks can't
                // cross filesystems).
                do { try fm.linkItem(atPath: live, toPath: newDst.path) }
                catch { try? fm.copyItem(atPath: live, toPath: newDst.path) }
            } else {
                fm.createFile(atPath: newDst.path, contents: Data())
            }
        }
        return (oldRoot.path, newRoot.path)
    }

    /// The commit this branch's diff baselines against: the merge-base of HEAD and either the card's
    /// PARENT branch (a stacked card — its OWN work only) or, when there's no parent, the repo's default
    /// branch (today's behavior). A set-but-unresolvable parent (e.g. the branch is missing) falls back
    /// to the default-branch merge-base, exactly like `DiffBaseline.range(.parent)`. `nil` when neither
    /// resolves or git fails. Base-ref resolution (local default branch preferred over a stale
    /// `origin/main`) is shared with the board diffstat via `DiffBaseline.defaultBaseRef`.
    private func mergeBase(worktree: String, parentRef: String?) -> String? {
        if let parentRef, !parentRef.isEmpty,
           let r = try? Proc.run(["git", "merge-base", "HEAD", parentRef], cwd: worktree), r.ok {
            let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return sha }
        }
        guard let baseRef = DiffBaseline.defaultBaseRef(worktree: worktree),
              let r = try? Proc.run(["git", "merge-base", "HEAD", baseRef], cwd: worktree), r.ok
        else { return nil }
        let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Every file the branch changed vs `base`: tracked changes (`git diff`) plus untracked-but-not-
    /// ignored files (`git ls-files --others`). Untracked files matter because an agent's freshly
    /// created files are usually not `git add`ed yet, and `git diff` omits them entirely.
    private func changedFiles(worktree: String, base: String) -> [Change] {
        var out = trackedChanges(worktree: worktree, base: base)
        if let r = try? Proc.run(["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd: worktree),
           r.ok {
            for path in r.stdout.split(separator: "\0").map(String.init) where !path.isEmpty {
                out.append(Change(status: .added, oldPath: path, newPath: path))
            }
        }
        return out
    }

    /// Parse `git diff --name-status -z <base>` (NUL-delimited fields). A rename/copy record is
    /// `R###\0<old>\0<new>`; every other status is `<X>\0<path>`. Treated as old→new so the diff
    /// follows the file across a rename.
    private func trackedChanges(worktree: String, base: String) -> [Change] {
        guard let r = try? Proc.run(["git", "diff", "--name-status", "-z", base], cwd: worktree), r.ok
        else { return [] }
        let f = r.stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var out: [Change] = []
        var i = 0
        while i < f.count {
            let status = f[i]
            guard let letter = status.first else { break }   // trailing empty field after final NUL
            i += 1
            if letter == "R" || letter == "C" {
                guard i + 1 < f.count else { break }
                out.append(Change(status: .modified, oldPath: f[i], newPath: f[i + 1]))
                i += 2
            } else {
                guard i < f.count else { break }
                let path = f[i]
                i += 1
                let s: ChangeStatus = letter == "A" ? .added : (letter == "D" ? .deleted : .modified)
                out.append(Change(status: s, oldPath: path, newPath: path))
            }
        }
        return out
    }
}
