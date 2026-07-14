import Foundation
import XCTest
@testable import OrchestraCore

/// A resolvable adapter whose `sessionInfo` always returns nil — the shape of an agent that genuinely
/// has nothing to report yet (e.g. before its session id has bound). Used to exercise `boardSnapshot`'s
/// cache-hit `?? AgentSessionInfo(…)` fallback (PR5 actor-hygiene, Task 5.2): a nil `sessionInfo` MUST
/// still land on the hit branch, not fall through to a live shell every snapshot.
final class NilInfoAdapter: Adapter, @unchecked Sendable {
    let id = "nil-info-agent"
    let name = "NilInfo"
    let icon = "sparkle"
    let bin = "fake-agent"
    let enabled = true
    let capabilities: AgentCapabilities = .stub
    func models() -> [AgentModel] { [AgentModel(id: "m1")] }
    func newSessionId() -> String? { UUID().uuidString.lowercased() }
    func start(_ ctx: AdapterContext) -> [String] { [bin] }
    func resume(_ ctx: AdapterContext) -> [String]? {
        guard let s = ctx.sessionId else { return nil }
        return [bin, "--resume", s]
    }
    func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo? { nil }
}

/// Shared setup for the `boardSnapshot` observed-cache tests (PR5 actor-hygiene, Task 5.2).
enum BoardSnapshotSupport {
    /// A service wired like `TestEnv.make`, but with a SECOND adapter (`NilInfoAdapter`) registered
    /// alongside the normal claude-shaped stub, so callers can spawn a card whose `sessionInfo` never
    /// resolves.
    private static func makeService() -> (svc: OrchestraService, sessions: StubSessions, repo: String, nilInfoId: String) {
        let base = NSTemporaryDirectory() + "orch-snap-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: base + "/repos", withIntermediateDirectories: true)
        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)], sessionLaunchTimeout: 3600,
                            scratchRoot: PathResolver.canonical(base) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(base) + "/state")
        let sessions = StubSessions()
        let worktrees = StubWorktrees(root: config.worktreesRoot)
        let wtRegistry = WorktreeRegistry(config: config, manager: worktrees,
                                          borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")
        let claude = StubAdapter(transcriptDir: base + "/transcripts", capabilities: .stub)
        let nilInfo = NilInfoAdapter()
        let store = TaskStore(path: base + "/tasks.json")
        let trust = TrustLedger(path: base + "/trust-ledger.json")
        let inbox = Inbox(path: base + "/inbox.json")
        let svc = OrchestraService(config: config, store: store,
                                   registry: AgentRegistry(adapters: [claude, nilInfo]),
                                   worktrees: wtRegistry, sessions: sessions, trust: trust, inbox: inbox,
                                   watchStore: WatchRegistryStore(path: base + "/watch-registry.json"))
        let repo = TestEnv.repo(PathResolver.canonical(base))
        return (svc, sessions, repo, nilInfo.id)
    }

    /// `count` live worktree cards on the normal claude-shaped adapter PLUS one extra live card on
    /// `NilInfoAdapter` — so a snapshot exercised against this fixture always crosses a card whose
    /// `sessionInfo` resolves to nil (the fallback path a hit-only fixture would mask).
    static func serviceWithLiveCards(count: Int) async throws -> (service: OrchestraService, stub: StubSessions) {
        let (svc, sessions, repo, nilInfoId) = makeService()
        for i in 0..<count {
            _ = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "card\(i)", repo: repo, branch: "b\(i)"))
        }
        _ = try await TestEnv.spawnAndAwaitLive(
            svc, SpawnInput(id: UUID(), prompt: "nil-info", repo: repo, branch: "b-nilinfo", agentId: nilInfoId))
        return (svc, sessions)
    }

    /// One live card (agent window) with exactly one shell window already open.
    static func liveCardWithShell() async throws -> (service: OrchestraService, stub: StubSessions, cardId: UUID) {
        let (svc, sessions, repo, _) = makeService()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "shell-card", repo: repo, branch: "b"))
        _ = try await svc.openShell(card.id)
        return (svc, sessions, card.id)
    }
}

/// `boardSnapshot` serves a reconciled card's session state from the reconciler's off-actor
/// `observedSessions` cache instead of shelling to tmux per card (PR5 actor-hygiene, Task 5.2).
final class BoardSnapshotTests: XCTestCase {

    /// (a) A cache HIT (post-`reconcile()`) costs zero `windows()` calls.
    func test_boardSnapshotDoesNotShell() async throws {
        let (service, stub) = try await BoardSnapshotSupport.serviceWithLiveCards(count: 3)
        await service.reconcile()                          // populates observedSessions off-actor
        let before = stub.windowsCount
        _ = await service.boardSnapshot()
        XCTAssertEqual(stub.windowsCount, before, "boardSnapshot shelled instead of reading cache")
    }

    /// (b) The cache's content matches what a live `windows()` call would report.
    func test_boardSnapshotContentMatchesObservedWindows() async throws {
        let (service, stub, cardId) = try await BoardSnapshotSupport.liveCardWithShell()  // agent + one shell
        await service.reconcile()
        let snap = await service.boardSnapshot()
        let cs = try XCTUnwrap(snap.sessions.first { $0.id == cardId })
        XCTAssertTrue(cs.running)
        XCTAssertEqual(Set(cs.targets.map(\.window)), Set(try stub.windowsForTest(cardId).map(\.window)))
    }

    /// (c) A cache MISS falls back to exactly one live shell — first-connect stays preserved.
    func test_boardSnapshotCacheMissFallsBackToLiveShell() async throws {
        let (service, stub, _) = try await BoardSnapshotSupport.liveCardWithShell()  // NO reconcile yet
        let before = stub.windowsCount
        let snap = await service.boardSnapshot()
        XCTAssertEqual(stub.windowsCount, before + 1, "miss should live-shell exactly once")
        XCTAssertTrue(try XCTUnwrap(snap.sessions.first).running)
    }

    /// (d) Opening a shell evicts the entry — the next snapshot reflects the new window, not a stale cache.
    func test_boardSnapshotFreshAfterShellOpen() async throws {
        let (service, _, cardId) = try await BoardSnapshotSupport.liveCardWithShell()
        await service.reconcile()
        _ = try await service.openShell(cardId)             // evicts the entry
        let snap = await service.boardSnapshot()            // miss → live shell → sees the new window
        XCTAssertTrue(try XCTUnwrap(snap.sessions.first).targets.contains { $0.window.hasPrefix("shell-") })
    }
}
