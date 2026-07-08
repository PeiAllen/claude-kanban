import Foundation

/// One child of a browsed directory, for the phone's remote directory browser (the `listDir` RPC).
/// The phone is a remote client and can't browse the daemon's disk, so the daemon enumerates a
/// directory's children over the control plane. Directories are navigable + selectable as a cwd;
/// files are shown for context but not selectable.
public struct DirEntry: Codable, Sendable, Hashable, Identifiable {
    /// Absolute, canonical (realpath'd) path on the daemon's filesystem.
    public var path: String
    /// `path.lastPathComponent`, for display.
    public var name: String
    /// True for a directory (tap to descend, pickable as cwd); false for a plain file (shown, disabled).
    public var isDir: Bool
    public var id: String { path }

    public init(path: String, name: String, isDir: Bool) {
        self.path = path
        self.name = name
        self.isDir = isDir
    }
}

/// Result of the `listDir` RPC — one directory's children, plus a bounded parent affordance. The
/// browser is confined to a set of *browse roots* (`$HOME` + the spawn allowlist); `listDir` never
/// returns paths outside them (symlink- and `..`-escape safe, via `PathResolver`). Dotfiles are hidden.
public struct DirListing: Codable, Sendable {
    /// The canonical directory being listed. Empty (`""`) for the synthetic *root listing* — the set of
    /// browse roots the phone may start from (Home + any allowlist entry outside home).
    public var path: String
    /// The parent directory to climb to, IFF it too stays within a browse root. `nil` at a browse root
    /// (can't climb above it) or for the root listing — the browser then shows no "up" affordance.
    public var parent: String?
    /// Children, dotfiles hidden: directories first (case-insensitive), then files (case-insensitive).
    public var entries: [DirEntry]

    public init(path: String, parent: String?, entries: [DirEntry]) {
        self.path = path
        self.parent = parent
        self.entries = entries
    }
}
