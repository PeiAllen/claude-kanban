import Foundation
import OrchestraKit

/// Finds the documents a user might review in a working directory.
///
/// GIT-INDEPENDENT BY DESIGN. A gitignored `notes/` must be found exactly like a tracked `docs/`, so
/// discovery is a filesystem walk and git is consulted only afterwards, to decorate what it happens to
/// know about. Documents are a property of the WORKSPACE, not of a card: two cards on one directory
/// list the same documents, the same way they show the same diff.
public enum DocumentDiscovery {
    /// Extensions the reader can render. Markdown only — the page is a markdown renderer, and adding
    /// formats it cannot lay out would list documents that open blank.
    public static let documentExtensions: Set<String> = ["md", "markdown"]

    /// Directory names pruned wholesale. Pruning at the DIRECTORY level is what makes this cheap:
    /// `node_modules` costs one comparison, not forty thousand stats.
    ///
    /// Shared with the file watcher on purpose. If the watcher did not prune the same set, a `.md`
    /// inside a denied directory would emit change events for a document discovery never lists.
    public static let denyDirectories: Set<String> = [
        "node_modules", "build", "dist", "target", "vendor", "Pods", "DerivedData",
    ]

    /// Upper bound on results. A pathological tree must not turn the list into an unusable wall or the
    /// payload into a problem; the cap is generous enough that a real project never reaches it.
    public static let resultCap = 500

    /// True when this path is a document the reader should list. Used by discovery AND by the watcher,
    /// so the two can never disagree about what counts.
    public static func isDocument(_ path: String) -> Bool {
        documentExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// True when a DIRECTORY should not be descended into.
    ///
    /// EVERY dot-directory is pruned, with no exceptions. The dot prefix marks machine-owned config, not
    /// a document a human reviews, so this is fail-safe against tools the reader has never heard of —
    /// `.cursor/rules/*.md`, `.github/copilot-instructions.md`, an agent's injected `.claude/skills`. An
    /// exception list cannot do that, because it has to know the name first.
    ///
    /// The cost is real and accepted: a card whose only markdown sits in `.claude/skills` or `.github`
    /// shows an empty reader. That is rarer than the noise the exception list let through, and the diff
    /// still shows the change.
    public static func isPrunedDirectory(_ name: String) -> Bool {
        denyDirectories.contains(name) || name.hasPrefix(".")
    }

    /// True when any component of `relativePath` is pruned, or the file itself is hidden. The watcher
    /// sees absolute paths from the OS rather than walking, so it needs this component test rather
    /// than `skipDescendants`. It MUST agree with the walk, or the watcher reports changes for
    /// documents the list never shows.
    public static func isPruned(relativePath: String) -> Bool {
        for component in relativePath.split(separator: "/").dropLast() {
            if isPrunedDirectory(String(component)) { return true }
        }
        return (relativePath as NSString).lastPathComponent.hasPrefix(".")
    }

    /// Walk `root` and return up to `cap` documents, as paths relative to `root`, newest first.
    /// Paths break equal modification times so every client receives one deterministic order.
    ///
    /// Blocking I/O — call it off the actor.
    public static func walk(root: String, cap: Int = resultCap) -> [String] {
        guard cap > 0 else { return [] }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        // Hidden entries are NOT skipped by the enumerator. Pruning happens per-directory below instead,
        // which keeps the dot rule and the deny list in ONE decision that `isPruned` can mirror for the
        // watcher.
        guard let en = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            errorHandler: { _, _ in true })      // an unreadable subtree is skipped, never fatal
        else { return [] }

        let rootPath = rootURL.standardizedFileURL.path
        var documents: [(path: String, modifiedAt: Date)] = []
        for case let url as URL in en {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let isDir = values?.isDirectory ?? false
            if isDir {
                // PRUNE HERE, not per-file. This is the whole performance story.
                if isPrunedDirectory(url.lastPathComponent) { en.skipDescendants() }
                continue
            }
            guard isDocument(url.lastPathComponent),
                  !url.lastPathComponent.hasPrefix(".") else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }   // never leave the root
            documents.append((path: String(path.dropFirst(rootPath.count + 1)),
                              modifiedAt: values?.contentModificationDate ?? .distantPast))
        }
        return documents
            .sorted { lhs, rhs in
                lhs.modifiedAt == rhs.modifiedAt ? lhs.path < rhs.path : lhs.modifiedAt > rhs.modifiedAt
            }
            .prefix(cap)
            .map(\.path)
    }
}
