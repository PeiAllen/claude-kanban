import Foundation

/// "View changes" — open a worktree in Zed.
public struct Launcher: Sendable {
    let resolver: PathResolver

    public init(resolver: PathResolver) { self.resolver = resolver }

    public func openInZed(_ worktree: String) throws {
        try resolver.assertAllowed(worktree)
        guard Proc.toolExists("zed") else { throw OrchestraError.zedMissing }
        let r = try Proc.run(["zed", worktree])
        if !r.ok { throw OrchestraError.io(r.stderr.isEmpty ? "zed failed to open" : r.stderr) }
    }
}
