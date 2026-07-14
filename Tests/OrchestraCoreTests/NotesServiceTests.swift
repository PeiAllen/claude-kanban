// MOVES-TO: ContractTests/Git — OrchestraService.changedNotes over real repos (changed-notes detection: merge-base/ls-files/diff --name-status)
import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit

/// `OrchestraService.changedNotes` — the phone Notes page's RPC source (M6). Read-only; guards on
/// `Task.origin == .worktree` like the diff endpoints.
///
/// WHOLE-SUITE CONTRACT MOVER (not convertible): `changedNotes` reaches git through `Launcher`
/// (`changedNoteFiles` → `changedMarkdown` → `mergeBase`/`changedFiles`, which call static `Proc.run`
/// — NOT the injectable `proc`/`DiffProvider` seam), so the changed-notes detection is irreducibly real
/// git and can't be stubbed without touching Sources/. It relocates verbatim at the flip. The Launcher-
/// level computation is also contract-pinned by IntegrationTests/LauncherDiffTests.
@Suite("OrchestraService — changed-notes RPC")
struct NotesServiceTests {
    typealias Env = (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String)

    /// Spawn a `.worktree` card and turn its cwd into a git repo with a committed `notes/keep.md` on
    /// `main` — the base the branch's changes are measured against.
    private func worktreeCardWithNotes() async throws -> (env: Env, task: Task) {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "task", repo: repo, branch: "b"))
        let fm = FileManager.default
        try fm.createDirectory(atPath: t.cwd + "/notes", withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            #expect(try Proc.run(["git"] + args, cwd: t.cwd).ok)
        }
        try "base\n".write(toFile: t.cwd + "/notes/keep.md", atomically: true, encoding: .utf8)
        try "code\n".write(toFile: t.cwd + "/main.swift", atomically: true, encoding: .utf8)
        #expect(try Proc.run(["git", "add", "-A"], cwd: t.cwd).ok)
        #expect(try Proc.run(["git", "commit", "-q", "-m", "base"], cwd: t.cwd).ok)
        return (env, t)
    }

    @Test("returns the branch's changed/new .md with correct M/A status + content; excludes non-md")
    func changedNotesWorktree() async throws {
        let (env, t) = try await worktreeCardWithNotes()
        // Modify a tracked note (→ M) and add an untracked one (→ A); also touch a non-md file (excluded).
        try "branch edit\n".write(toFile: t.cwd + "/notes/keep.md", atomically: true, encoding: .utf8)
        try "brand new\n".write(toFile: t.cwd + "/notes/new.md", atomically: true, encoding: .utf8)
        try "changed\n".write(toFile: t.cwd + "/main.swift", atomically: true, encoding: .utf8)

        let byPath = Dictionary(uniqueKeysWithValues:
            try await env.svc.changedNotes(t.id).map { ($0.path, $0) })

        #expect(Set(byPath.keys) == ["notes/keep.md", "notes/new.md"])
        #expect(byPath["notes/keep.md"]?.status == .modified)
        #expect(byPath["notes/keep.md"]?.content == "branch edit\n")
        #expect(byPath["notes/new.md"]?.status == .added)
        #expect(byPath["notes/new.md"]?.content == "brand new\n")
    }

    /// main(a.txt) → parent(+parent.md) → child=HEAD(+child.md). Once the card baselines against its
    /// parent, only `child.md` counts as the card's changed note.
    private func gitParentChildNotes(_ dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func git(_ a: String...) { #expect((try? Proc.run(["git"] + a, cwd: dir))?.ok == true) }
        git("init", "-q", "-b", "main"); git("config", "user.email", "t@t"); git("config", "user.name", "t")
        try "base\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        git("add", "-A"); git("commit", "-q", "-m", "base")
        git("checkout", "-q", "-b", "parent")
        try "# parent\n".write(toFile: dir + "/parent.md", atomically: true, encoding: .utf8)
        git("add", "-A"); git("commit", "-q", "-m", "parent note")
        git("checkout", "-q", "-b", "child")
        try "# child\n".write(toFile: dir + "/child.md", atomically: true, encoding: .utf8)
        git("add", "-A"); git("commit", "-q", "-m", "child note")
    }

    // Migrated verbatim from DiffServiceTests (diff-review commit): a changedNotes assertion that reaches
    // git through the Launcher, so it lives with the other real-git changed-notes tests here, not in the
    // now-stubbed DiffServiceTests.
    @Test("changedNotes baselines against the parent — the parent's note is excluded")
    func changedNotesUsesParentBaseline() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "task", repo: repo, branch: "child"))
        try gitParentChildNotes(t.cwd)
        _ = try await env.svc.store.update(t.id) { $0.parentBranch = "parent" }
        let notes = try await env.svc.changedNotes(t.id)
        #expect(notes.map(\.path) == ["child.md"])   // parent.md excluded
    }

    @Test("no note changes → empty")
    func noNoteChanges() async throws {
        let (env, t) = try await worktreeCardWithNotes()
        #expect(try await env.svc.changedNotes(t.id).isEmpty)
    }

    @Test("non-worktree (borrowed) card → empty, never touches git")
    func borrowedGuarded() async throws {
        let env = TestEnv.make()
        let dir = env.base + "/data"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", cwd: dir, access: .readWrite))
        #expect(t.origin == .borrowed)
        #expect(try await env.svc.changedNotes(t.id).isEmpty)
    }

    @Test("unknown card → throws")
    func unknownCard() async throws {
        let env = TestEnv.make()
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.changedNotes(UUID())
        }
    }
}
