import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit

/// `OrchestraService.noteAsset` — the reader's image endpoint, and its five gates.
///
/// CONTRACT TIER for the same reason `NotesServiceTests` is: gate 1 reaches git through `Launcher`,
/// which calls static `Proc.run` rather than the injectable seam, so the changed-notes scope is
/// irreducibly real git and cannot be stubbed without touching Sources/.
///
/// The rejection tests here ARE the security boundary. An earlier draft of this endpoint served any
/// image-extension file inside the worktree; `noteAssetRejectsAnImageTheNoteDoesNotReference` is what
/// distinguishes the shipped scope from that one, so it must never be deleted or weakened.
@Suite("OrchestraService — noteAsset")
struct NoteAssetServiceTests {
    typealias Env = (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees,
                     adapter: StubAdapter, trust: TrustLedger, base: String)


    /// A worktree card whose branch adds `docs/page.md`, referencing `docs/images/ok.png`. A second,
    /// UNREFERENCED image sits beside it — readable, in-worktree, correctly extensioned.
    private func cardWithAnIllustratedNote() async throws -> (env: Env, task: Task) {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "task", repo: repo, branch: "b"))
        let fm = FileManager.default
        try fm.createDirectory(atPath: t.cwd + "/docs/images", withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            #expect(try Proc.run(["git"] + args, cwd: t.cwd).ok)
        }
        try "seed\n".write(toFile: t.cwd + "/seed.txt", atomically: true, encoding: .utf8)
        #expect(try Proc.run(["git", "add", "-A"], cwd: t.cwd).ok)
        #expect(try Proc.run(["git", "commit", "-q", "-m", "base"], cwd: t.cwd).ok)

        // The branch's change: a note that references exactly one image.
        try "# Page\n\n![ok](images/ok.png)\n".write(
            toFile: t.cwd + "/docs/page.md", atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: t.cwd + "/docs/images/ok.png"))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: t.cwd + "/docs/images/secret.png"))
        return (env, t)
    }

    @Test("serves an image the note references")
    func servesAReferencedImage() async throws {
        let (env, t) = try await cardWithAnIllustratedNote()
        let asset = try await env.svc.noteAsset(t.id, notePath: "docs/page.md",
                                                assetPath: "docs/images/ok.png")
        #expect(asset.mimeType == "image/png")
        #expect(Data(base64Encoded: asset.base64) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("GATE 2 — refuses an in-worktree image the note does NOT reference")
    func noteAssetRejectsAnImageTheNoteDoesNotReference() async throws {
        // `secret.png` is real, readable, inside the worktree, and correctly extensioned. It passes
        // every gate EXCEPT the reference allowlist. This is the whole difference between the shipped
        // endpoint and an arbitrary worktree image read.
        let (env, t) = try await cardWithAnIllustratedNote()
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.noteAsset(t.id, notePath: "docs/page.md",
                                            assetPath: "docs/images/secret.png")
        }
    }

    @Test("GATE 1 — refuses a note outside the card's changed set")
    func noteAssetRejectsANoteOutsideTheChangedSet() async throws {
        let (env, t) = try await cardWithAnIllustratedNote()
        try "![x](images/ok.png)\n".write(toFile: t.cwd + "/untracked-not-md.txt",
                                          atomically: true, encoding: .utf8)
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.noteAsset(t.id, notePath: "untracked-not-md.txt",
                                            assetPath: "docs/images/ok.png")
        }
    }

    @Test("GATE 3 — refuses a path escaping the worktree")
    func noteAssetRejectsAPathEscapingTheWorktree() async throws {
        let (env, t) = try await cardWithAnIllustratedNote()
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.noteAsset(t.id, notePath: "docs/page.md",
                                            assetPath: "../../../../etc/hosts")
        }
    }

    @Test("GATE 4 — refuses a non-image extension even when referenced")
    func noteAssetRejectsANonImageExtension() async throws {
        let (env, t) = try await cardWithAnIllustratedNote()
        // Reference a .md from the note, so ONLY the extension gate can reject it.
        try "# Page\n\n![nope](page.md)\n".write(
            toFile: t.cwd + "/docs/page.md", atomically: true, encoding: .utf8)
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.noteAsset(t.id, notePath: "docs/page.md", assetPath: "docs/page.md")
        }
    }

    @Test("a non-worktree card has no assets at all")
    func noteAssetRefusesANonWorktreeCard() async throws {
        let env = TestEnv.make()
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "scratch", scratch: true))
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.noteAsset(t.id, notePath: "a.md", assetPath: "b.png")
        }
    }
}
