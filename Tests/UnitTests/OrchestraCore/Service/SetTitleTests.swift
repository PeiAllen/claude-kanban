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

    /// …and it arms it BEFORE `ensure`, which is the whole point: `ensure` returns the moment the session
    /// exists, so a baseline written after it could lose the race to that session's first statusline.
    /// Asserting the final value can't see the difference — park inside `ensure` and read the store there.
    @Test("the baseline is armed BEFORE the session is created, not after")
    func baselineIsArmedBeforeEnsure() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let gate = SyncGate()
        env.sessions.ensureGate = gate

        let id = UUID()
        _ = try await env.svc.spawn(SpawnInput(id: id, prompt: "x", repo: repo, branch: "feat-h"))
        // Drive the reconciler off to the side: its LaunchStepper parks inside the off-actor `ensure`, so
        // the tick that gets there never returns until we release — the actor itself stays free to serve
        // the `store.get` below, which is exactly the observation we need.
        let driver = _Concurrency.Task { while !_Concurrency.Task.isCancelled { await env.svc.reconcile() } }
        defer { driver.cancel() }
        await gate.reached()                       // provably parked INSIDE the off-actor ensure
        env.sessions.ensureGate = nil
        // The session now exists as far as tmux is concerned; the baseline must ALREADY be on the card.
        let mid = try #require(await env.svc.store.get(id))
        #expect(mid.lastSessionName == "feat-h")
        gate.release()
    }

    /// The daemon-side attached-target resolver exists BECAUSE `createdAt` is not a total order (task dates
    /// serialize at second resolution), so co-located worktree cards need a deterministic winner.
    @Test("the 👁 target is the oldest co-located worktree card, deterministically")
    func attachedTargetPicksTheOldestSibling() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let first = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "a", repo: repo, branch: "feat/shared"))
        // A co-located sibling on the SAME branch/cwd — permitted, and same-second `createdAt`.
        let second = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "b", repo: repo, branch: "feat/shared"))
        #expect(second.cwd == first.cwd)
        _ = try await env.svc.setTitle(ref: first.shortId, title: "The First One")
        _ = try await env.svc.setTitle(ref: second.shortId, title: "The Second One")

        let reviewer = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "review", cwd: first.cwd, access: .readOnly))
        // (createdAt, id) ordering — the same total order BoardStore.attachedTarget uses.
        let expected = [first, second]
            .min { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        #expect(reviewer.title == "👁 \(expected?.id == first.id ? "The First One" : "The Second One")")
    }

    /// An INTEGRATION check, not the proof. Nothing here forces `setTitle` to land inside report()'s
    /// read→write window — if it wins the race, report simply reads the already-renamed card and the
    /// assertion holds under a blanket overlay too. `TaskStore` has no rendezvous seam to pin that ordering,
    /// so the deterministic pin lives at the model level instead, in
    /// `ReportTests.test_reportPreservesAConcurrentRename`, which DOES fail if the delta is reverted. What
    /// this one still guarantees is worth keeping: whichever order the two land in, the rename survives and
    /// report's own field still applies.
    @Test("a rename and a concurrent report both land, in either order")
    func setTitleSurvivesAConcurrentReport() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "feat-i"))
        // A report that changes only `desc` — it carries the STALE title in its snapshot.
        let epoch = try #require(await env.svc.store.get(t.id)).sessionEpoch
        async let reporting: Void = try env.svc.report(t.id, StatusReport(desc: "working"),
                                                       observedEpoch: epoch)
        _ = try await env.svc.setTitle(ref: t.shortId, title: "Reviewer A")
        try await reporting

        let after = try #require(await env.svc.store.get(t.id))
        #expect(after.title == "Reviewer A")        // report must not restore the name it happened to read
        #expect(after.titleSource == .explicit)
        #expect(after.desc == "working")            // …while what report DID change still lands
    }

    // MARK: - the durable note

    @Test("set-note sets, updates, and clears a durable note")
    func setNoteRoundTrip() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "feat-n"))
        #expect(t.note == nil)

        let noted = try await env.svc.setNote(ref: t.shortId, note: "  Wave 2/4 — lease/claim delivery ",
                                              source: .mcp)
        #expect(noted.note == "Wave 2/4 — lease/claim delivery")   // normalized
        let updated = try await env.svc.setNote(ref: t.shortId, note: "Wave 3/4 — Claude channels")
        #expect(updated.note == "Wave 3/4 — Claude channels")
        // An EMPTY note CLEARS it — the only way to remove one, so it must not error like `set-title` does.
        let cleared = try await env.svc.setNote(ref: t.shortId, note: "   ")
        #expect(cleared.note == nil)
    }

    @Test("spawn carries an explicit note")
    func spawnCarriesNote() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", note: "Wave 1/4 — the funnel",
                                repo: repo, branch: "feat-o"))
        #expect(t.note == "Wave 1/4 — the funnel")
    }

    /// The whole reason `note` exists rather than overloading `desc`: `desc` is the volatile status mirror
    /// that telemetry overwrites and a restart blanks, so it can never hold narrative that must outlive a
    /// turn. `note` must survive both, and the report pipeline must never touch it.
    @Test("a note survives telemetry and restart; desc does not")
    func noteOutlivesDescChurn() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", note: "Wave 2/4", repo: repo, branch: "feat-p"))
        let epoch = try #require(await env.svc.store.get(t.id)).sessionEpoch

        // Telemetry churns `desc` and must leave `note` alone.
        try await env.svc.report(t.id, StatusReport(desc: "Editing Model.swift"), observedEpoch: epoch)
        var after = try #require(await env.svc.store.get(t.id))
        #expect(after.desc == "Editing Model.swift")
        #expect(after.note == "Wave 2/4")
        #expect(after.cardLine == "Wave 2/4")        // the note wins the card's second line

        // `/clear` blanks `desc`; the note is untouched.
        try await env.svc.report(t.id, StatusReport(sessionSource: "clear"), observedEpoch: epoch)
        after = try #require(await env.svc.store.get(t.id))
        #expect(after.desc.isEmpty)
        #expect(after.note == "Wave 2/4")
        #expect(after.cardLine == "Wave 2/4")        // …and still carries the card's second line

        // A restart re-arms the lifecycle flag and blanks desc; the note still survives.
        _ = try await env.svc.restart(t.id)
        after = try #require(await env.svc.store.get(t.id))
        #expect(after.desc.isEmpty)
        #expect(after.note == "Wave 2/4")
    }

    @Test("cardLine falls back to desc when there is no note")
    func cardLineFallsBackToDesc() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "feat-q"))
        let epoch = try #require(await env.svc.store.get(t.id)).sessionEpoch
        try await env.svc.report(t.id, StatusReport(desc: "Running tests"), observedEpoch: epoch)
        let after = try #require(await env.svc.store.get(t.id))
        #expect(after.note == nil)
        #expect(after.cardLine == "Running tests")
    }

    private func nameFlag(_ argv: [String]?) -> String? {
        guard let argv, let i = argv.firstIndex(of: "--name"), i + 1 < argv.count else { return nil }
        return argv[i + 1]
    }
}
