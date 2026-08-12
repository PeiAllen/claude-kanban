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
    /// Dot-directories (`.git`, `.build`, `.venv`) are NOT listed here because `.skipsHiddenFiles`
    /// already removes them for free.
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

    /// True when any component of `relativePath` is a pruned or hidden directory. The watcher sees
    /// absolute paths from the OS rather than walking, so it needs this component test rather than
    /// `skipDescendants`.
    public static func isPruned(relativePath: String) -> Bool {
        for component in relativePath.split(separator: "/").dropLast() {
            if component.hasPrefix(".") || denyDirectories.contains(String(component)) { return true }
        }
        return (relativePath as NSString).lastPathComponent.hasPrefix(".")
    }

    /// Walk `root` and return every document, as paths relative to `root`, sorted.
    ///
    /// Blocking I/O — call it off the actor.
    public static func walk(root: String, cap: Int = resultCap) -> [String] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        // `.skipsHiddenFiles` is doing real work: it removes `.git`, `.build`, `.venv`, and every
        // dotfile in one option instead of a deny list that would have to chase them.
        guard let en = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true })      // an unreadable subtree is skipped, never fatal
        else { return [] }

        let rootPath = rootURL.standardizedFileURL.path
        var out: [String] = []
        for case let url as URL in en {
            if out.count >= cap { break }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                // PRUNE HERE, not per-file. This is the whole performance story.
                if denyDirectories.contains(url.lastPathComponent) { en.skipDescendants() }
                continue
            }
            guard isDocument(url.lastPathComponent) else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }   // never leave the root
            out.append(String(path.dropFirst(rootPath.count + 1)))
        }
        return out.sorted()
    }
}
