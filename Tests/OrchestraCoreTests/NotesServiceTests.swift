import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit

/// `OrchestraService.changedNotes` — the phone Notes page's RPC source (M6). Read-only; guards on
/// `Task.origin == .worktree` like the diff endpoints.
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
