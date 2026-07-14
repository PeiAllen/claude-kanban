import Foundation
import Testing
@testable import OrchestraCore

/// PR4b Task 4 — `archive` becomes an INTENT-ONLY verb: its synchronous part records the archive intent
/// (`transition(→ .archivedPending)` + the `archived` Bool mirror so the card leaves the board instantly)
/// and RETURNS; the reconciler's `TeardownStepper` runs the full duty list (kill / releaseBorrow / release /
/// cancel-loops / nudge-children) and flips `archivedPending → archivedComplete`. The funnel concludes on the
/// non-terminal → `archivedPending` entry (no manual `concludeCard`).
@Suite("Archive — intent-only + idempotency + supersede races (PR4b Task 4)")
struct ArchiveIntentTests {

    // The three run-dir origins the teardown switch handles + both agent backends. Every supersede-race is
    // exercised across the full cross-product (the funnel + TeardownStepper + orphan sweep never branch on
    // agentId, so this is agent-agnostic BY CONSTRUCTION — the parameterization is the proof).
    enum Origin: CaseIterable { case worktree, scratch, borrowed }
    static let agentCaps: [(id: String, caps: AgentCapabilities)] =
        [("claude-code", .claudeCode), ("codex", ReadinessSignalTests.codexStubCaps)]

    /// A stub-backed service whose default adapter carries `id` + `caps` (so a "codex" card is genuinely a
    /// different backend id, not just Claude-with-different-caps).
    static func env(_ caps: AgentCapabilities, id: String)
        -> (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, base: String) {
        let base = PathResolver.canonical(NSTemporaryDirectory() + "orch-arch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: base + "/repos", withIntermediateDirectories: true)
        let config = Config(reposRoot: base + "/repos", worktreesRoot: base + "/worktrees", allowlist: [base], sessionLaunchTimeout: 3600,
                            scratchRoot: base + "/scratch", runtimeStateDir: base + "/state")
        let sessions = StubSessions()
        let worktrees = StubWorktrees(root: config.worktreesRoot)
        let wtReg = WorktreeRegistry(config: config, manager: worktrees,
                                     borrowsPath: base + "/borrows.json", markersDir: base + "/wm")
        let adapter = StubAdapter(transcriptDir: base + "/transcripts", capabilities: caps, id: id)
        let store = TaskStore(path: base + "/tasks.json")
        let trust = TrustLedger(path: base + "/trust.json")
        let inbox = Inbox(path: base + "/inbox.json")
        let svc = OrchestraService(config: config, store: store, registry: AgentRegistry(adapters: [adapter]),
                                   worktrees: wtReg, sessions: sessions, trust: trust, inbox: inbox,
                                   watchStore: WatchRegistryStore(path: base + "/watch.json"))
        return (svc, sessions, worktrees, adapter, base)
    }

    /// Spawn a card of `origin` and drive it to `.live` (so the run dir is materialized + the session is up),
    /// returning the live card.
    static func spawnLive(_ e: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, base: String),
                          _ origin: Origin, _ branch: String) async throws -> Task {
        let agentId = e.adapter.id
        let input: SpawnInput
        switch origin {
        case .worktree:
            input = SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(e.base), branch: branch, agentId: agentId)
        case .scratch:
            input = SpawnInput(id: UUID(), prompt: "x", agentId: agentId, scratch: true)
        case .borrowed:
            let dir = e.base + "/borrowed-\(branch)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            input = SpawnInput(id: UUID(), prompt: "x", agentId: agentId, cwd: dir)
        }
        // Awaited caps need the ready signal each launching tick; deliver it defensively.
        let created = try await e.svc.spawn(input)
        try await pollUntil {
            await e.svc.reconcile()
            let card = await e.svc.list(includeArchived: true).first { $0.id == created.id }
            if card?.phase.kind == .launching { try? await e.svc.report(created.id, StatusReport(sessionSource: "startup")) }
            return card?.phase.kind == .live
        }
        return try #require(await e.svc.list(includeArchived: true).first { $0.id == created.id })
    }

    static func phaseKind(_ e: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, base: String),
                          _ id: UUID) async -> Phase.Kind? {
        await e.svc.list(includeArchived: true).first { $0.id == id }?.phase.kind
    }

    /// Per-origin resource reclaim after teardown: worktree → tree released; scratch → dir removed;
    /// borrowed → dir kept (never removed).
    static func assertReclaim(_ e: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, base: String),
                              _ card: Task, _ origin: Origin) {
        switch origin {
        case .worktree:
            #expect(e.worktrees.removed.contains(card.cwd))
        case .scratch:
            #expect(!FileManager.default.fileExists(atPath: card.cwd))
        case .borrowed:
            #expect(FileManager.default.fileExists(atPath: card.cwd))   // borrowed dir NEVER removed
            #expect(e.worktrees.removed.isEmpty)
        }
    }

    // MARK: - intent-only + idempotency

    @Test("test_archiveIsIntentOnly")
    func test_archiveIsIntentOnly() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))

        try await env.svc.archive(t.id)

        // Intent recorded synchronously: archivedPending + the `archived` Bool mirror (off the board now).
        let pending = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(pending.phase.kind == .archivedPending)
        #expect(pending.archived)
        // Duty list is DEFERRED to the stepper — the session is NOT torn down by the verb itself.
        #expect(!env.sessions.killed.contains(env.sessions.sessionName(t.id)))

        // The reconciler's TeardownStepper drives it to archivedComplete + reclaims the session.
        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list(includeArchived: true).first { $0.id == t.id }?.phase.kind == .archivedComplete
        }
        #expect(env.sessions.killed.contains(env.sessions.sessionName(t.id)))
    }

    @Test("test_reArchiveIsIdempotent")
    func test_reArchiveIsIdempotent() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))

        // archivedPending: a retried archive is an idempotent no-op success (never throws).
        _ = try await env.svc.store.update(t.id) { $0.phase = .archived(teardownComplete: false); $0.archived = true }
        try await env.svc.archive(t.id)
        #expect(try #require(await env.svc.store.get(t.id)).phase.kind == .archivedPending)

        // archivedComplete: the handler's idempotency GUARD is the save — the tightened isLegalEdge makes
        // `archivedComplete → archivedPending` illegal, so without the guard this would `.rejected`-error.
        _ = try await env.svc.store.update(t.id) { $0.phase = .archived(teardownComplete: true); $0.archived = true }
        try await env.svc.archive(t.id)   // must NOT throw, must NOT roll the phase back to pending
        #expect(try #require(await env.svc.store.get(t.id)).phase.kind == .archivedComplete)

        // Through the dispatch gate too: archive stays `gAll`, so the gate admits an already-archived card.
        let reg = CommandRegistry()
        let cmd = try #require(reg.command("archive"))
        _ = try await reg.dispatch(cmd, env.svc, .object(["ref": .string(t.shortId)]), .cli)
        #expect(try #require(await env.svc.store.get(t.id)).phase.kind == .archivedComplete)
    }

    // MARK: - supersede races (each × worktree/scratch/borrowed × claude-code/codex)

    @Test("test_archiveDuringMidCheckout", arguments: Origin.allCases, agentCaps)
    func test_archiveDuringMidCheckout(origin: Origin, agent: (id: String, caps: AgentCapabilities)) async throws {
        let e = Self.env(agent.caps, id: agent.id)
        let card = try await Self.spawnLive(e, origin, "mc")
        let epoch = card.sessionEpoch
        // Rewind to `.creatingWorktree` (mid-checkout) — the run dir + session from the live drive are still present.
        _ = try await e.svc.store.update(card.id) { $0.phase = .creatingWorktree }

        // Archive lands mid-checkout → the funnel takes the card to archivedPending (+ archived mirror).
        try await e.svc.archive(card.id)
        let pending = try #require(await e.svc.list(includeArchived: true).first { $0.id == card.id })
        #expect(pending.phase.kind == .archivedPending)
        #expect(pending.archived)

        // A late materialize advance (creatingWorktree → launching) is funnel-rejected from archivedPending.
        let r = await e.svc.transition(card.id, to: .launching, observedEpoch: epoch)
        #expect(r == .rejected(from: .archived(teardownComplete: false), to: .launching))

        try await pollUntil { await e.svc.reconcile(); return await Self.phaseKind(e, card.id) == .archivedComplete }
        #expect(e.sessions.killed.contains(e.sessions.sessionName(card.id)))   // session reclaimed
        Self.assertReclaim(e, card, origin)
    }

    @Test("test_archiveDuringLaunching", arguments: Origin.allCases, agentCaps)
    func test_archiveDuringLaunching(origin: Origin, agent: (id: String, caps: AgentCapabilities)) async throws {
        let e = Self.env(agent.caps, id: agent.id)
        let card = try await Self.spawnLive(e, origin, "lc")
        let epoch = card.sessionEpoch
        _ = try await e.svc.store.update(card.id) { $0.phase = .launching }

        try await e.svc.archive(card.id)
        #expect(await Self.phaseKind(e, card.id) == .archivedPending)

        // The late LaunchStepper finalize (launching → live at the same epoch) is funnel-rejected.
        let r = await e.svc.transition(card.id, to: .live(.waiting(.humanTurn)), observedEpoch: epoch)
        #expect(r == .rejected(from: .archived(teardownComplete: false), to: .live(.waiting(.humanTurn))))

        try await pollUntil { await e.svc.reconcile(); return await Self.phaseKind(e, card.id) == .archivedComplete }
        #expect(e.sessions.killed.contains(e.sessions.sessionName(card.id)))
        Self.assertReclaim(e, card, origin)
    }

    @Test("test_archiveRacesLaunch_reclaimsSession", arguments: Origin.allCases, agentCaps)
    func test_archiveRacesLaunch_reclaimsSession(origin: Origin, agent: (id: String, caps: AgentCapabilities)) async throws {
        let e = Self.env(agent.caps, id: agent.id)
        let card = try await Self.spawnLive(e, origin, "rl")
        let epoch = card.sessionEpoch
        _ = try await e.svc.store.update(card.id) { $0.phase = .launching }

        // Archive wins the race to the funnel.
        try await e.svc.archive(card.id)
        #expect(await Self.phaseKind(e, card.id) == .archivedPending)

        // The racing launch's `ensure` lands AFTER archive: a fresh epoch-stamped session appears, and its
        // finalize is funnel-rejected. The orphan-session sweep (+ teardown kill) must reclaim it.
        e.sessions.setStampedEpoch(card.id, epoch)
        #expect(e.sessions.isAliveTest(card.id))
        let r = await e.svc.transition(card.id, to: .live(.waiting(.humanTurn)), observedEpoch: epoch)
        #expect(r == .rejected(from: .archived(teardownComplete: false), to: .live(.waiting(.humanTurn))))

        try await pollUntil {
            await e.svc.reconcile()
            return await Self.phaseKind(e, card.id) == .archivedComplete && !e.sessions.isAliveTest(card.id)
        }
        #expect(!e.sessions.isAliveTest(card.id))   // the orphaned session was reclaimed
        Self.assertReclaim(e, card, origin)
    }
}
