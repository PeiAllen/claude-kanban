import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit

/// The remote directory browser's daemon RPC. `listDir` must never leak paths outside the browse roots
/// ($HOME + the spawn allowlist), and must be symlink- / `..`-escape safe — this is the security crux.
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

    @Test("parent is bounded: set within a root, nil at a browse root")
    func parentBounded() async throws {
        let (svc, base) = make()
        let proj = try seedProj(base)
        // proj's parent is `base`, which is a browse root → included.
        let inner = try await svc.listDir(proj)
        #expect(inner.parent == base)
        // base IS a browse root → its parent (outside the roots) is not offered.
        let atRoot = try await svc.listDir(base)
        #expect(atRoot.parent == nil)
    }

    @Test("rejects a path outside every browse root")
    func rejectsOutside() async throws {
        let (svc, _) = make()
        // A fresh temp tree that is NOT allowlisted and not under $HOME (/var/folders on macOS).
        let outside = PathResolver.canonical(NSTemporaryDirectory() + "orch-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        await #expect(throws: OrchestraError.self) { try await svc.listDir(outside) }
    }

    @Test("rejects a symlink that escapes the browse roots")
    func rejectsSymlinkEscape() async throws {
        let (svc, base) = make()
        let proj = try seedProj(base)
        let outside = PathResolver.canonical(NSTemporaryDirectory() + "orch-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: outside + "/secret", withIntermediateDirectories: true)
        let link = proj + "/link"
        try? FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside + "/secret")
        await #expect(throws: OrchestraError.self) { try await svc.listDir(link) }
    }

    @Test("rejects a ../ escape that climbs out of a browse root")
    func rejectsDotDotEscape() async throws {
        let (svc, base) = make()
        _ = try seedProj(base)
        await #expect(throws: OrchestraError.self) {
            try await svc.listDir(base + "/proj/../../orch-nope/secret")
        }
    }

    @Test("rejects a non-directory (file) path")
    func rejectsFile() async throws {
        let (svc, base) = make()
        let proj = try seedProj(base)
        await #expect(throws: OrchestraError.self) { try await svc.listDir(proj + "/mid.txt") }
    }
}
