import Foundation

/// "View changes" — open a worktree in Zed, landing on its branch-vs-base diff.
public struct Launcher: Sendable {
    let resolver: PathResolver

    public init(resolver: PathResolver) { self.resolver = resolver }

    /// Cap on how many changed-note tabs `openNotes` opens at once, so a card that touched many
    /// markdown files doesn't flood Obsidian with dozens of tabs. The rest stay one click away in
    /// the vault tree.
    static let openNotesTabCap = 15

    /// "Open notes" — open the card's WORKTREE as an Obsidian vault and jump straight to the
    /// markdown files its branch changed (docs, notes, superpower specs, `.claude/skills` — anywhere
    /// in the worktree), each as a tab. Uses the same `~/.claude/open-obsidian-vault.sh` recipe the
    /// `/open-notes` Claude command runs (seed a default config, register the vault, launch Obsidian
    /// — restarting a running instance only when the vault is new).
    ///
    /// The vault is the worktree root — not `<repo>/notes` — because Obsidian only opens files that
    /// live inside a registered vault, and the changed notes span several top-level dirs. Opening the
    /// changed files directly as tabs means the whole-worktree vault is never actually browsed. When
    /// nothing changed (or the card isn't a git worktree) the vault still opens, just with no tabs.
    ///
    /// `.obsidian/` is gitignored at the repo root, so registering the worktree as a vault never
    /// pollutes the card's diff (and the script's own `.gitignore`-append is then a no-op).
    ///
    /// Returns `(opened:` tabs opened, ≤ cap `, total:` changed `.md` count `)` for the caller's toast.
    @discardableResult
    public func openNotes(_ worktree: String) throws -> (opened: Int, total: Int) {
        #if !os(macOS)
        throw OrchestraError.io("opening notes in Obsidian is a macOS-only convenience")
        #else
        try resolver.assertAllowed(worktree)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let script = (home as NSString).appendingPathComponent(".claude/open-obsidian-vault.sh")
        guard FileManager.default.fileExists(atPath: script) else { throw OrchestraError.toolMissing(script) }
        // The script resolves jq/python3/osascript/open on PATH; augmentedPATH (applied by Proc.run)
        // adds Homebrew + per-user bins so they're found under launchd's minimal PATH. Running it on
        // the worktree root registers + opens that as the vault, and covers the no-changes case.
        let r = try Proc.run(["bash", script, worktree])
        if !r.ok { throw OrchestraError.io(r.stderr.isEmpty ? "open-obsidian-vault.sh failed" : r.stderr) }

        // Jump to the changed notes: fire one `obsidian://open?path=…` URI per file so each opens as
        // a tab in the just-registered vault. Capped so a large diff doesn't spawn dozens of tabs.
        let notes = changedNotes(worktree: worktree)
        let opened = Array(notes.prefix(Self.openNotesTabCap))
        for path in opened {
            var comps = URLComponents()
            comps.scheme = "obsidian"
            comps.host = "open"
            comps.queryItems = [URLQueryItem(name: "path", value: path)]
            guard let uri = comps.url?.absoluteString else { continue }
            _ = try? Proc.run(["/usr/bin/open", uri])
        }
        return (opened: opened.count, total: notes.count)
        #endif
    }

    /// The markdown files the worktree's branch changed vs its base — the same branch-vs-base set as
    /// the Zed "View changes" diff, filtered to notes/docs (`.md`) and excluding deletions (a deleted
    /// file can't be opened). Returns absolute worktree paths. Empty when nothing changed, the base
    /// can't be resolved, or the card isn't a git worktree.
    func changedNotes(worktree: String) -> [String] {
        guard let base = mergeBase(worktree: worktree) else { return [] }
        return changedFiles(worktree: worktree, base: base)
            .filter { $0.status != .deleted }
            .map { $0.newPath }
            .filter { $0.lowercased().hasSuffix(".md") }
            .map { (worktree as NSString).appendingPathComponent($0) }
    }

    public func openInZed(_ worktree: String) throws {
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
        if let dirs = try? branchDiffDirs(worktree: worktree) {
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
    func branchDiffDirs(worktree: String) throws -> (old: String, new: String)? {
        guard let base = mergeBase(worktree: worktree) else { return nil }
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

    /// The merge-base of HEAD and the repo's default branch: the commit this branch forked from. `nil`
    /// if no base branch is found or git fails. Base-ref resolution (local default branch preferred over a
    /// stale `origin/main`) is shared with the board diffstat via `DiffBaseline.defaultBaseRef`.
    private func mergeBase(worktree: String) -> String? {
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
