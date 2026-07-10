import Foundation
import Testing
@testable import OrchestraCore

/// PR7 (cross-cutting) — SMOKE, not the regression guard. Every race exercised here has a deterministic
/// stub test in a prior PR (`test_concurrentSameBranchEnsureJoins` — PR3b; `test_actorNotBlockedByExec`/
/// `_byLivenessList` — PR5; `test_spawnDrivesPhases` — PR2). This just proves the shipped machinery holds
/// together over a REAL git checkout + REAL tmux.
enum SlowRepoFixture {
    /// Absolute path to the bundled generator script.
    static var scriptPath: String {
        Bundle.module.path(forResource: "Fixtures/gen-slow-repo", ofType: "sh")
            ?? Bundle.module.path(forResource: "gen-slow-repo", ofType: "sh") ?? ""
    }

    /// Generate a slow repo of `count` files at `<base>/repos/app`; returns the canonical repo path.
    /// Default is 12k (not the plan's 28k): 12k already yields a multi-second `git worktree add`
    /// (~4-10s here) — far above the ~0.8s a borrowed card needs to overtake it — while keeping
    /// generation cheap (~15-20s vs ~80s for 28k). Generation cost is O(files), so the count trades
    /// checkout margin against setup time; 12k is the balance point (as-built deviation, see the vault).
    @discardableResult
    static func generate(base: String, count: Int = 12_000) throws -> String {
        let repo = base + "/repos/app"
        try FileManager.default.createDirectory(atPath: base + "/repos", withIntermediateDirectories: true)
        let r = try Proc.run(["/bin/bash", scriptPath, repo, String(count)])
        guard r.exitCode == 0 else {
            throw OrchestraError.io("gen-slow-repo failed: \(r.stderr)")   // `.io`, not `.internalError` (no such case)
        }
        return PathResolver.canonical(repo)
    }
}

@Suite("Slow-repo fixture sanity", .enabled(if: IntegrationSupport.gitAvailable), .serialized)
struct SlowRepoFixtureTests {
    @Test("generator produces a large committed working tree")
    func fixtureGeneratesSlowCheckout() throws {
        #expect(!SlowRepoFixture.scriptPath.isEmpty)
        let base = IntegrationSupport.tempDir("slowfix")
        defer { try? FileManager.default.removeItem(atPath: base) }
        // A small count keeps this sanity test fast; the E2E uses the 12k default (see `generate`).
        let repo = try SlowRepoFixture.generate(base: base, count: 2_000)
        let n = try Proc.checked(["git", "-C", repo, "ls-files"]).stdout
            .split(whereSeparator: \.isNewline).count
        #expect(n >= 2_000)
        // HEAD is a single commit on main
        let head = try Proc.checked(["git", "-C", repo, "rev-parse", "--abbrev-ref", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(head == "main")
    }
}

@Suite("Slow-repo lifecycle E2E — SMOKE (both agents)",
       .enabled(if: IntegrationSupport.gitAvailable && IntegrationSupport.tmuxAvailable), .serialized)
final class SlowRepoE2ETests {
    // one harness per test instance (swift-testing makes a fresh instance per case/arg)
    let base: String
    let tmuxSock: String
    let ctlSock: String
    var service: OrchestraService!
    var pollLoop: _Concurrency.Task<Void, Never>!

    init() {
        base = IntegrationSupport.tempDir("slowe2e")
        tmuxSock = "orch-slow-\(UUID().uuidString.prefix(8))"
        ctlSock = "/tmp/orch-slow-\(UUID().uuidString.prefix(8)).sock"
    }

    deinit {
        pollLoop?.cancel()
        _ = try? Proc.run(["tmux", "-L", tmuxSock, "kill-server"])
        try? FileManager.default.removeItem(atPath: base)
    }

    private func makeService(repo: String) -> OrchestraService {
        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)])
        let sessions = SessionManager(socket: tmuxSock, confPath: SessionManager.bundledConf, sockEnvPath: ctlSock)
        let claude = ClaudeCodeAdapter(binOverride: IntegrationSupport.fakeAgentPath)
        let codex = CodexAdapter(binOverride: IntegrationSupport.fakeAgentPath, codexHome: base + "/codexhome")
        let svc = OrchestraService(config: config, store: TaskStore(path: base + "/tasks.json"),
                                   registry: AgentRegistry(adapters: [claude, codex]),
                                   worktrees: WorktreeRegistry(config: config, borrowsPath: base + "/borrows.json",
                                                               markersDir: base + "/worktree-markers"),
                                   sessions: sessions)
        let s = svc
        pollLoop = _Concurrency.Task {
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(for: .milliseconds(200))
                await s.reconcile()
                await s.pollTelemetry()
            }
        }
        return svc
    }

    @Test("slow-repo spawn: race-free ensure + non-frozen actor + phase walk",
          arguments: ["claude-code", "codex"])
    func slowRepoSpawn(agentId: String) async throws {
        let repo = try SlowRepoFixture.generate(base: base)      // 12k files → multi-second checkout
        service = makeService(repo: repo)
        let branch = "slow-\(agentId)"

        // Two SAME-branch spawns, concurrently — both return immediately at `.creatingWorktree`.
        let a = try await service.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: branch, agentId: agentId))
        let b = try await service.spawn(SpawnInput(id: UUID(), prompt: "y", repo: repo, branch: branch, agentId: agentId))
        #expect(a.phase.kind == .creatingWorktree)
        #expect(b.phase.kind == .creatingWorktree)

        // Non-frozen proof by PHASE ORDERING (not wall-clock — codex findings 1 & 3 killed the timing
        // approach as vacuous/flaky). Concurrently spawn a fast card `c` that skips the git checkout —
        // a BORROWED card whose cwd is a pre-created dir UNDER `base` (materialize = instant, no
        // `worktrees.ensure`; then the N=3 liveness fallback ≈ 600ms → `.live`). Borrowed (not scratch)
        // deliberately: a scratch card materializes under the REAL `~/.orchestra/scratch/<id>` and would
        // leak state / flake full-suite runs (codex cleanup note); a borrowed dir under `base` is torn
        // down with `base` in `deinit`. If the service actor were frozen by an on-actor `git worktree
        // add`, the reconcile loop could not dispatch/advance ANY other card, so `c` could NOT reach
        // `.live` while A and B are still `.creatingWorktree`. On the shipped code it CAN: `stepIfEligible`
        // dispatches each card's stepper as a DETACHED `_Concurrency.Task` (per-card `inFlightSteps`) and
        // git runs off-actor in the registry, so `c` (~0.8s to live) overtakes the ~9s checkout with a
        // wide, non-flaky margin. The 12k-file fixture is sized so the checkout reliably outlasts `c`.
        let cDir = base + "/borrowed-c"
        try FileManager.default.createDirectory(atPath: cDir, withIntermediateDirectories: true)
        let c = try await service.spawn(SpawnInput(id: UUID(), prompt: "z", agentId: agentId, cwd: cDir))

        var sawBeingBorn = false
        var overtook = false                                     // c reached .live while BOTH A and B still creating
        for _ in 0..<100 {                                       // 100 × 200ms = 20s cap
            let cards = await service.list(includeArchived: true)
            func phase(_ id: UUID) -> Phase.Kind? { cards.first { $0.id == id }?.phase.kind }
            if [a.id, b.id].contains(where: { phase($0) == .creatingWorktree || phase($0) == .launching }) {
                sawBeingBorn = true                              // Stage 2 being-born phases observed
            }
            if phase(c.id) == .live && phase(a.id) == .creatingWorktree && phase(b.id) == .creatingWorktree {
                overtook = true                                 // fast card advanced during the slow checkout
            }
            if [a.id, b.id].filter({ phase($0) == .live }).count == 2 { break }
            try await _Concurrency.Task.sleep(for: .milliseconds(200))
        }
        #expect(sawBeingBorn)                                     // Stage 2 phase walk observed
        #expect(overtook)                                        // Stages 4-5: service actor stayed responsive during the checkout

        let final = await service.list(includeArchived: true).filter { $0.id == a.id || $0.id == b.id }
        #expect(final.count == 2)
        #expect(final.allSatisfy { $0.phase.kind == .live })     // both reached live

        // Race-free ensure (Stage 3): both cards joined ONE worktree for the shared branch.
        #expect(Set(final.map(\.cwd)).count == 1)
        let wtList = try Proc.checked(["git", "-C", repo, "worktree", "list"]).stdout
        #expect(wtList.split(whereSeparator: \.isNewline).filter { $0.contains(branch) }.count == 1)

        // The tmux `:agent` window is up for BOTH live cards (codex finding 2 — assert each, not just
        // one). `sessions(_:)` is `throws`-returning a NON-optional `CardSessions` (Model.swift:876);
        // its `targets: [TmuxTarget]` carry the windows (`TmuxTarget.window == "agent"`, Model.swift:796)
        // — there is no `.windows` field.
        for card in final {
            let cs = try await service.sessions(card.id)
            #expect(cs.targets.contains { $0.window == "agent" })
        }
    }
}
