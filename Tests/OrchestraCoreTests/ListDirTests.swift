import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit

/// The remote directory browser's daemon RPC. `browseRoots` ($HOME + the spawn allowlist) are the
/// starting points; from there the owner can browse anywhere the daemon user can read (no confinement —
/// the same socket already exposes `exec`). Dotfiles are hidden as declutter; dirs sort before files.
@Suite("listDir — the remote directory browser")
struct ListDirTests {

    /// A service whose browse roots include `base` (the allowlist). Returns the service + canonical base.
    private func make() -> (svc: OrchestraService, base: String) {
        let env = TestEnv.make()
        return (env.svc, env.base)
    }

    /// Build `<base>/proj` with two subdirs, a file, and a hidden dotfile. Returns the proj path.
    private func seedProj(_ base: String) throws -> String {
        let proj = base + "/proj"
        let fm = FileManager.default
        try fm.createDirectory(atPath: proj + "/Zeta", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: proj + "/alpha", withIntermediateDirectories: true)
        fm.createFile(atPath: proj + "/mid.txt", contents: Data("x".utf8))
        fm.createFile(atPath: proj + "/.hidden", contents: Data("x".utf8))
        return PathResolver.canonical(proj)
    }

    @Test("root listing returns the browse roots (allowlist included), no parent")
    func rootListing() async throws {
        let (svc, base) = make()
        let listing = try await svc.listDir(nil)
        #expect(listing.path == "")
        #expect(listing.parent == nil)
        #expect(listing.entries.contains { $0.path == base && $0.isDir })
    }

    @Test("descend: dirs sort before files (case-insensitive), dotfiles hidden")
    func descend() async throws {
        let (svc, base) = make()
        let proj = try seedProj(base)
        let listing = try await svc.listDir(proj)
        #expect(listing.path == proj)
        #expect(listing.entries.map(\.name) == ["alpha", "Zeta", "mid.txt"])
        #expect(listing.entries.first { $0.name == "alpha" }?.isDir == true)
        #expect(listing.entries.first { $0.name == "mid.txt" }?.isDir == false)
        #expect(!listing.entries.contains { $0.name == ".hidden" })
    }

    @Test("parent is the filesystem parent (unconfined)")
    func parentIsFilesystemParent() async throws {
        let (svc, base) = make()
        let proj = try seedProj(base)
        // proj's parent is `base`.
        let inner = try await svc.listDir(proj)
        #expect(inner.parent == base)
        // A browse root is no longer a ceiling: its parent is offered too (no confinement).
        let atRoot = try await svc.listDir(base)
        #expect(atRoot.parent == PathResolver.canonical((base as NSString).deletingLastPathComponent))
    }

    @Test("browses outside the browse roots (no confinement)")
    func browsesOutsideRoots() async throws {
        let (svc, _) = make()
        // A fresh temp tree that is NOT allowlisted and not under $HOME (/var/folders on macOS).
        let outside = PathResolver.canonical(NSTemporaryDirectory() + "orch-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: outside + "/child", withIntermediateDirectories: true)
        let listing = try await svc.listDir(outside)
        #expect(listing.path == outside)
        #expect(listing.entries.contains { $0.name == "child" && $0.isDir })
    }

    @Test("rejects a non-directory (file) path")
    func rejectsFile() async throws {
        let (svc, base) = make()
        let proj = try seedProj(base)
        await #expect(throws: OrchestraError.self) { try await svc.listDir(proj + "/mid.txt") }
    }
}
