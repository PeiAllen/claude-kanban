import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Security boundary: every repo/worktree path must canonicalize to inside an allowlisted root.
/// Symlink-escape safe (it resolves the real path before the prefix check).
public struct PathResolver: Sendable {
    public let allowedRoots: [String]
    /// The root a **bare** (non-absolute, non-`~`) repo name resolves against — `Config.reposRoot`. The
    /// phone's Spawn sheet invites a "repo name" (its placeholder), but a relative name otherwise
    /// canonicalizes against the *daemon's* process cwd and fails the allowlist with `pathNotAllowed`.
    /// Empty disables bare-name resolution (relative paths stay cwd-relative — the pre-existing behavior
    /// for the browse-only `PathResolver(allowedRoots:)`).
    public let reposRoot: String

    public init(allowedRoots: [String], reposRoot: String = "") {
        self.allowedRoots = allowedRoots.map { Self.canonical($0) }
        self.reposRoot = reposRoot.isEmpty ? "" : Self.canonical(reposRoot)
    }

    public init(config: Config) {
        self.init(allowedRoots: config.allowedRoots, reposRoot: config.reposRoot)
    }

    /// realpath(3), falling back to a lexical normalization when the path doesn't exist yet (e.g. a
    /// worktree about to be created). We resolve the deepest existing ancestor with realpath, then
    /// re-append the non-existent tail, so a symlinked ancestor can't be used to escape.
    public static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if let resolved = resolveExisting(expanded) { return resolved }
        return (expanded as NSString).standardizingPath
    }

    private static func resolveExisting(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buf) != nil {
            // Drop the null terminator, then decode the CChar bytes as UTF-8 (matching the old
            // `String(cString:)` behavior without the deprecated array initializer; the macOS-15-only
            // `String(validating:as:)` isn't usable on this macOS-14 target).
            return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        // Resolve the deepest existing ancestor, then re-append the missing tail — collapsing `.`/`..`
        // against the realpath-resolved ancestor. This is the security crux: the tail is non-existent
        // (so realpath can't normalize it) and the prefix check that follows is purely textual, so a
        // literal `..` left in the tail (e.g. an attacker-chosen branch `a/../../../etc`) would let a
        // path that resolves OUTSIDE the root still pass `hasPrefix(root)`. Collapsing here closes that.
        let ns = path as NSString
        let parent = ns.deletingLastPathComponent
        let last = ns.lastPathComponent
        guard !parent.isEmpty, parent != path, !last.isEmpty else { return nil }
        guard let resolvedParent = resolveExisting(parent) else { return nil }
        switch last {
        case ".":  return resolvedParent
        case "..": return (resolvedParent as NSString).deletingLastPathComponent   // can't climb above "/"
        default:   return (resolvedParent as NSString).appendingPathComponent(last)
        }
    }

    /// Resolve a repo path and assert it is allowed. A bare repo name (no path separator, not absolute or
    /// `~`) is resolved against `reposRoot` first (see `resolveBareRepo`) so the phone's "repo name" input
    /// works; absolute / tilde / path-like inputs are canonicalized as given.
    public func resolveRepo(_ repo: String) throws -> String {
        let real = Self.canonical(resolveBareRepo(repo))
        try assertAllowed(real)
        return real
    }

    /// A bare repo name is resolved under `reposRoot`. "Bare" = trimmed, non-empty, and neither absolute
    /// (`/…`) nor home-relative (`~…`) — i.e. exactly the "repo name or a nested `name/sub`" the phone's
    /// Spawn placeholder invites. Absolute/tilde/empty inputs (and any `PathResolver` with no `reposRoot`)
    /// pass through untouched, so existing absolute-path callers are unaffected.
    private func resolveBareRepo(_ repo: String) -> String {
        guard !reposRoot.isEmpty else { return repo }
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return repo }
        return (reposRoot as NSString).appendingPathComponent(trimmed)
    }

    /// Throws `pathNotAllowed` unless `absPath` is equal to or sits under an allowlisted root.
    public func assertAllowed(_ absPath: String) throws {
        let real = Self.canonical(absPath)
        for root in allowedRoots where isPrefix(root, of: real) {
            return
        }
        throw OrchestraError.pathNotAllowed(absPath)
    }

    /// True when `root` is `path` or a parent directory of `path` (component-wise, not substring).
    private func isPrefix(_ root: String, of path: String) -> Bool {
        if root == path { return true }
        let rootSlash = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(rootSlash)
    }
}
