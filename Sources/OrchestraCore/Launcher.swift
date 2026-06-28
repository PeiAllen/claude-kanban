import Foundation

/// "View changes" — open a worktree in Zed, landing on its branch-vs-base diff.
public struct Launcher: Sendable {
    let resolver: PathResolver

    public init(resolver: PathResolver) { self.resolver = resolver }

    public func openInZed(_ worktree: String) throws {
        try resolver.assertAllowed(worktree)
        // Prefer the `zed` CLI: it can open the worktree as a project AND open a multi-file diff view
        // (`--diff <old> <new>` pairs). We point those pairs at the branch's changes vs the commit it
        // forked from, so the window lands on a PR-style "branch vs base" review of the worktree.
        if Proc.toolExists("zed") {
            var argv = ["zed"]
            for (old, new) in (try? branchDiffPairs(worktree: worktree)) ?? [] {
                argv += ["--diff", old, new]
            }
            argv.append(worktree)
            let r = try Proc.run(argv)
            if !r.ok { throw OrchestraError.io(r.stderr.isEmpty ? "zed failed to open" : r.stderr) }
            return
        }
        // No CLI (Zed.app installed without running "Install CLI") — launch the bundle instead. `open`
        // can't pass `--diff`, so this just opens the worktree; the user is one step from the git panel.
        let r = try Proc.run(["/usr/bin/open", "-a", "Zed", worktree])
        if !r.ok { throw OrchestraError.zedMissing }   // `open` fails only when the app isn't found
    }

    // MARK: - branch-vs-base diff

    private enum ChangeStatus { case modified, added, deleted }
    private struct Change { let status: ChangeStatus; let oldPath: String; let newPath: String }

    /// Build `(oldPath, newPath)` pairs for every file the worktree's branch changed relative to the
    /// commit it forked from (the merge-base with the repo's default branch). The "new" side is the
    /// live worktree file (editable in Zed); the "old" side is that file's content at the base,
    /// materialized into a temp dir. Returns `[]` when the base can't be determined or nothing
    /// changed — the caller then just opens the worktree with no diff.
    func branchDiffPairs(worktree: String) throws -> [(String, String)] {
        guard let base = mergeBase(worktree: worktree) else { return [] }
        let changes = changedFiles(worktree: worktree, base: base)
        guard !changes.isEmpty else { return [] }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchestra-zeddiff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // A shared empty file stands in for the missing side of an add (no base) or delete (no worktree).
        let empty = tmp.appendingPathComponent("empty")
        FileManager.default.createFile(atPath: empty.path, contents: Data())

        var pairs: [(String, String)] = []
        for change in changes {
            let new: String
            if change.status == .deleted {
                new = empty.path
            } else {
                let p = (worktree as NSString).appendingPathComponent(change.newPath)
                new = FileManager.default.fileExists(atPath: p) ? p : empty.path
            }

            let old: String
            if change.status == .added {
                old = empty.path
            } else {
                let dst = tmp.appendingPathComponent("base/\(change.oldPath)")
                try? FileManager.default.createDirectory(
                    at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Binary-safe: `git show` streams the blob straight to disk (no String round-trip).
                let code = try? Proc.runStdoutToFile(
                    ["git", "show", "\(base):\(change.oldPath)"], cwd: worktree, outputURL: dst)
                old = (code == 0) ? dst.path : empty.path
            }
            pairs.append((old, new))
        }
        return pairs
    }

    /// The merge-base of HEAD and the repo's default branch (origin/HEAD → local `main` → `master`):
    /// the commit this branch forked from. `nil` if no base branch is found or git fails.
    private func mergeBase(worktree: String) -> String? {
        var baseRef: String?
        if let r = try? Proc.run(["git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: worktree),
           r.ok {
            baseRef = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if baseRef == nil {
            for name in ["main", "master"] {
                if let r = try? Proc.run(["git", "rev-parse", "--verify", "--quiet", name], cwd: worktree), r.ok {
                    baseRef = name
                    break
                }
            }
        }
        guard let baseRef,
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
