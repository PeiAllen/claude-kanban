import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

/// The card title as the naming SSOT: `set-title` pins it, spawn derives it from the card's own identity,
/// and every (re)launch pushes the CURRENT title to the agent as `--name`.
@Suite("Card naming — set-title, derived defaults, and the --name push")
struct SetTitleTests {

    // MARK: - set-title

    @Test("set-title renames and pins, without touching the lifecycle flag")
    func setTitlePinsWithoutTouchingLifecycle() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "", repo: repo, branch: "feat-a"))
        #expect(t.title == "feat-a")
        #expect(t.awaitingFirstPrompt == true)

        let renamed = try await env.svc.setTitle(ref: t.shortId, title: "  Reviewer A  ", source: .mcp)
        #expect(renamed.title == "Reviewer A")            // normalized
        #expect(renamed.titleSource == .explicit)
        #expect(renamed.awaitingFirstPrompt == true)      // renaming is not being prompted
    }

    @Test("set-title rejects an empty title and caps an over-long one")
    func setTitleBounds() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "feat-b"))
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.setTitle(ref: t.shortId, title: "   ")
        }
        let long = try await env.svc.setTitle(ref: t.shortId, title: String(repeating: "x", count: 500))
        #expect(long.title.count == CardNaming.maxTitleChars)
    }

    @Test("an explicit title survives a restart — a default would be re-derived, a pin is not")
    func explicitTitleSurvivesRestart() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "feat-c"))
        _ = try await env.svc.setTitle(ref: t.shortId, title: "Reviewer A")
        _ = try await env.svc.restart(t.id)
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.title == "Reviewer A")
        #expect(after.titleSource == .explicit)
    }

    // MARK: - derived defaults at spawn

    @Test("a read-only card borrowing a worktree card's dir is stamped with its target")
    func readOnlyBorrowedStampsItsTarget() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let target = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "build it", repo: repo, branch: "feat/under-review"))

        let reviewer = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "review this", cwd: target.cwd, access: .readOnly))
        #expect(reviewer.title == "👁 feat/under-review")
        #expect(reviewer.titleSource == .attached)

        // Read-WRITE in the same dir is not an attached agent — it keeps the prompt cutoff.
        let helper = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "help out", cwd: target.cwd, access: .readWrite))
        #expect(helper.title == "help out")
    }

    @Test("a seeded card is never named from its seed")
    func seededCardIsNeverNamedFromItsSeed() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        // Worktree: its branch.
        let forked = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "", repo: repo, branch: "feat-d",
                                seed: "A LONG PARENT SLICE that used to become the title"))
        #expect(forked.title == "feat-d")
        #expect(forked.awaitingFirstPrompt == false)   // the seed IS its first turn

        // Branchless: its directory — never the seed, and never a permanent placeholder.
        let dir = env.base + "/claude-kanban"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let branchless = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "", cwd: dir,
                                seed: "A LONG PARENT SLICE that used to become the title"))
        #expect(branchless.title == "claude-kanban")
    }

    @Test("an explicit spawn title outranks every derived default")
    func spawnExplicitTitleOutranksDefaults() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", title: "Parser probe",
                                repo: repo, branch: "feat-e"))
        #expect(t.title == "Parser probe")
        #expect(t.titleSource == .explicit)
    }

    // MARK: - the --name push

    @Test("a relaunch pushes the CURRENT title, not the one the first launch captured")
    func relaunchPushesTheCurrentTitle() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "feat-f"))
        let session = env.sessions.sessionName(t.id)
        #expect(nameFlag(env.sessions.ensureArgv[session]) == "feat-f")

        _ = try await env.svc.setTitle(ref: t.shortId, title: "Reviewer A")
        _ = try await env.svc.restart(t.id)
        try await pollUntil("the relaunch to re-ensure the session") {
            await env.svc.reconcile()
            return await env.svc.list().first { $0.id == t.id }?.phase.kind == .live
        }
        #expect(nameFlag(env.sessions.ensureArgv[session]) == "Reviewer A")
    }

    /// The launch arms the mirror's delta baseline with the name it just pushed, BEFORE the session can
    /// report — otherwise the new session's opening statusline reads as a rename against a stale baseline.
    @Test("a launch arms the session-name baseline with what it pushed")
    func launchArmsTheBaseline() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "feat-g"))
        #expect(t.lastSessionName == "feat-g")
    }

    private func nameFlag(_ argv: [String]?) -> String? {
        guard let argv, let i = argv.firstIndex(of: "--name"), i + 1 < argv.count else { return nil }
        return argv[i + 1]
    }
}
