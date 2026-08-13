import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit

/// WHICH documents count as "changed by this card" — the signal both the reader's focus section and
/// Obsidian's tab seeding key on. Contract tier: it is git's real answer, reached through `Launcher`'s
/// static `Proc.run` calls rather than the injectable seam.
///
/// The rule is: git's diff vs the branch base, PLUS anything git does not track at all. That second
/// half is what catches a document the agent created, including one sitting in a gitignored directory
/// and one created in a repo with no resolvable base.
@Suite("Document status — what counts as changed")
struct DocumentStatusTests {
    typealias Env = (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees,
                     adapter: StubAdapter, trust: TrustLedger, base: String)

    /// A worktree card whose repo has ONE committed document, then the card's own additions.
    private func card() async throws -> (env: Env, task: Task) {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "task", repo: repo, branch: "b"))
        let fm = FileManager.default
        try fm.createDirectory(atPath: t.cwd + "/docs", withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            #expect(try Proc.run(["git"] + args, cwd: t.cwd).ok)
        }
        try "# Committed\n".write(toFile: t.cwd + "/docs/committed.md", atomically: true, encoding: .utf8)
        try "# Edited\n".write(toFile: t.cwd + "/docs/edited.md", atomically: true, encoding: .utf8)
        try "plans/\n".write(toFile: t.cwd + "/.gitignore", atomically: true, encoding: .utf8)
        #expect(try Proc.run(["git", "add", "-A"], cwd: t.cwd).ok)
        #expect(try Proc.run(["git", "commit", "-q", "-m", "base"], cwd: t.cwd).ok)
        return (env, t)
    }

    private func statuses(_ env: Env, _ t: Task) async throws -> [String: DocumentStatus?] {
        var out: [String: DocumentStatus?] = [:]
        for d in try await env.svc.listDocuments(t.id) { out[d.path] = d.status }
        return out
    }

    @Test("a committed, untouched document has NO status")
    func untouchedIsUnmarked() async throws {
        let (env, t) = try await card()
        #expect(try await statuses(env, t)["docs/committed.md"] == .some(nil))
    }

    @Test("an edited tracked document is modified")
    func editedIsModified() async throws {
        let (env, t) = try await card()
        try "# Edited more\n".write(toFile: t.cwd + "/docs/edited.md", atomically: true, encoding: .utf8)
        #expect(try await statuses(env, t)["docs/edited.md"] == .modified)
    }

    @Test("an untracked new document is added")
    func untrackedIsAdded() async throws {
        let (env, t) = try await card()
        try "# New\n".write(toFile: t.cwd + "/docs/new.md", atomically: true, encoding: .utf8)
        #expect(try await statuses(env, t)["docs/new.md"] == .added)
    }

    @Test("a GITIGNORED document is added, wherever it lives")
    func gitignoredIsAdded() async throws {
        // The old rule only rescued gitignored files under `notes/`. A plan in any other ignored
        // directory read as untouched, which is exactly backwards — the agent just wrote it.
        let (env, t) = try await card()
        try FileManager.default.createDirectory(atPath: t.cwd + "/plans", withIntermediateDirectories: true)
        try "# Plan\n".write(toFile: t.cwd + "/plans/design.md", atomically: true, encoding: .utf8)
        #expect(try await statuses(env, t)["plans/design.md"] == .added)
    }

    @Test("a document in a NON-repo directory has no status at all")
    func nonRepoHasNoStatuses() async throws {
        // Nothing is "changed" without git, so every document must read unmarked — that is what makes
        // the reader fall back to showing everything instead of an empty focus section.
        let env = TestEnv.make()
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "scratch", scratch: true))
        try "# A\n".write(toFile: t.cwd + "/a.md", atomically: true, encoding: .utf8)
        let docs = try await env.svc.listDocuments(t.id)
        #expect(docs.map(\.path) == ["a.md"])
        #expect(docs.allSatisfy { $0.status == nil })
    }

    @Test("changed documents sort ahead of untouched ones")
    func changedSortFirst() async throws {
        let (env, t) = try await card()
        try "# New\n".write(toFile: t.cwd + "/docs/new.md", atomically: true, encoding: .utf8)
        let paths = try await env.svc.listDocuments(t.id).map(\.path)
        // `docs/committed.md` sorts before `docs/new.md` alphabetically, so ordering by status is the
        // only thing that can put the new document first. The two untouched ones follow, alphabetical.
        #expect(paths == ["docs/new.md", "docs/committed.md", "docs/edited.md"])
    }
}
