import Foundation

/// Discovers git repositories nested at any depth under a root directory.
///
/// The default repos root is `$HOME` (see `Config.defaultReposRoot`), so a naive recursive walk is a
/// footgun: `$HOME` holds `Library`, `node_modules`, caches, Photos libraries, `.git` object stores,
/// etc. — walking all of it would take minutes. So the scan:
///   • prunes hidden (`.`-prefixed) directories and known-heavy trees (`Library`, `node_modules`, …),
///   • stops descending the moment a directory is itself a repo (a repo's own subdirs and its
///     `.worktrees/` are not separate repos to list),
///   • bounds the walk with a max depth.
///
/// The core walk (`scan`) is pure — filesystem access is injected — so the pruning/depth/stop-at-repo
/// logic is unit-testable without touching a real disk. `discover` wires it to `FileManager` for the app.
public enum RepoScanner {
    /// How many directory levels below the root to search. The root's direct children are depth 1.
    /// Deep enough for common layouts (`~/Documents/Projects/<group>/<repo>` is depth 4) while keeping
    /// a `$HOME`-rooted scan bounded.
    public static let defaultMaxDepth = 6

    /// Directory names that never contain project repos worth listing but are expensive to walk.
    static let prunedDirNames: Set<String> = [
        "Library", "node_modules", ".build", "DerivedData", "Pods", "build",
        "Applications", "vendor", ".git", "target", ".cache", ".Trash",
    ]

    /// Whether a directory (by name) should be skipped: hidden dot-directories and known-heavy trees.
    static func shouldPrune(_ name: String) -> Bool {
        name.hasPrefix(".") || prunedDirNames.contains(name)
    }

    /// Pure recursive walk. `isRepo(path)` is true when `path` contains a `.git`; `subdirs(path)`
    /// returns the child *directory* names of `path`. Returns absolute repo paths, sorted by directory
    /// name case-insensitively (tie-broken by full path for stability).
    static func scan(
        root: String,
        maxDepth: Int,
        isRepo: (String) -> Bool,
        subdirs: (String) -> [String]
    ) -> [String] {
        var found: [String] = []
        func walk(_ dir: String, _ depth: Int) {
            for name in subdirs(dir) where !shouldPrune(name) {
                let child = "\(dir)/\(name)"
                if isRepo(child) {
                    found.append(child)          // record and stop — don't recurse into a repo
                } else if depth < maxDepth {
                    walk(child, depth + 1)
                }
            }
        }
        walk(root, 1)
        return found.sorted { a, b in
            let an = (a as NSString).lastPathComponent, bn = (b as NSString).lastPathComponent
            switch an.localizedCaseInsensitiveCompare(bn) {
            case .orderedSame: return a < b
            case .orderedAscending: return true
            case .orderedDescending: return false
            }
        }
    }

    /// Discover repos under `root` on the real filesystem via `FileManager`. Symlinks are not followed
    /// (avoids cycles and escaping the root into unrelated trees).
    public static func discover(
        root: String,
        maxDepth: Int = defaultMaxDepth,
        fileManager fm: FileManager = .default
    ) -> [String] {
        let expandedRoot = (root as NSString).expandingTildeInPath
        return scan(
            root: expandedRoot,
            maxDepth: maxDepth,
            isRepo: { fm.fileExists(atPath: "\($0)/.git") },
            subdirs: { dir in
                let url = URL(fileURLWithPath: dir)
                guard let entries = try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                ) else { return [] }
                return entries.compactMap { entry in
                    let vals = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard vals?.isDirectory == true, vals?.isSymbolicLink != true else { return nil }
                    return entry.lastPathComponent
                }
            }
        )
    }

    /// `discover` off the main thread — the recursive walk of a `$HOME`-rooted tree must never run on
    /// the UI thread. Returns the sorted repo paths; callers publish them back on the main actor.
    public static func discoverAsync(root: String, maxDepth: Int = defaultMaxDepth) async -> [String] {
        await _Concurrency.Task.detached(priority: .userInitiated) {
            discover(root: root, maxDepth: maxDepth)
        }.value
    }
}
