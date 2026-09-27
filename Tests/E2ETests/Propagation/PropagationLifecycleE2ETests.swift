import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

/// Shared-file propagation over the REAL lifecycle: a real git repo, real tmux, the fake agent, a real
/// `SharedStore` under a per-test root — for BOTH agents. The unit tier already pins each wiring site
/// against a fake; this proves the pieces work together through `finishLaunch` and `TeardownStepper`.
@Suite("Propagation lifecycle E2E (both agents)",
       .enabled(if: IntegrationSupport.gitAvailable && IntegrationSupport.tmuxAvailable))
final class PropagationLifecycleE2ETests {
    let base: String
    let tmuxSock: String
    let ctlSock: String
    var pollLoop: _Concurrency.Task<Void, Never>?

    init() {
        base = IntegrationSupport.tempDir("prope2e")
        tmuxSock = "orch-prop-\(UUID().uuidString.prefix(8))"
        ctlSock = "/tmp/orch-prop-\(UUID().uuidString.prefix(8)).sock"
    }

    deinit {
        pollLoop?.cancel()
        _ = try? Proc.run(["tmux", "-L", tmuxSock, "kill-server"])
        try? FileManager.default.removeItem(atPath: base)
    }

    /// A repo that ignores the shared agent files, with the primary's copies present on disk.
    private func makeRepo() throws -> String {
        let repo = PathResolver.canonical(base) + "/repos/app"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try Proc.checked(["git", "-C", repo, "init", "-q", "-b", "main"])
        try Proc.checked(["git", "-C", repo, "config", "user.email", "t@t.t"])
        try Proc.checked(["git", "-C", repo, "config", "user.name", "T"])
        try "CLAUDE.md\nAGENTS.md\n.claude/\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
        try "x".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", repo, "add", "."])
        try Proc.checked(["git", "-C", repo, "commit", "-q", "-m", "init"])
        try "primary claude rules\n".write(toFile: repo + "/CLAUDE.md", atomically: true, encoding: .utf8)
        try "primary codex rules\n".write(toFile: repo + "/AGENTS.md", atomically: true, encoding: .utf8)
        return repo
    }

    private func makeService() -> OrchestraService {
        let b = PathResolver.canonical(base)
        let config = Config(reposRoot: b + "/repos", worktreesRoot: b + "/worktrees", allowlist: [b],
                            sessionLaunchTimeout: 3600, scratchRoot: b + "/scratch", runtimeStateDir: b + "/state",
                            sharedStoreRoot: b + "/shared", propagationPath: b + "/propagation.json")
        let sessions = SessionManager(socket: tmuxSock, confPath: SessionManager.bundledConf, sockEnvPath: ctlSock)
        let claude = ClaudeCodeAdapter(binOverride: IntegrationSupport.fakeAgentPath)
        let codex = CodexAdapter(binOverride: IntegrationSupport.fakeAgentPath, codexHome: base + "/codexhome")
        let svc = OrchestraService(config: config, store: TaskStore(path: base + "/tasks.json"),
                                   registry: AgentRegistry(adapters: [claude, codex]),
                                   worktrees: WorktreeRegistry(config: config, borrowsPath: base + "/borrows.json",
                                                               markersDir: base + "/worktree-markers"),
                                   sessions: sessions,
                                   proc: RealProc(), gitRemotesProbe: OrchestraService.defaultGitRemotesProbe)
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

    private func awaitPhase(_ svc: OrchestraService, _ id: UUID, _ kind: Phase.Kind) async throws {
        try await pollUntil("card \(id) to reach \(kind)", timeout: .seconds(90)) {
            await svc.list(includeArchived: true).first { $0.id == id }?.phase.kind == kind
        }
    }

    @Test("a launched card receives the primary's shared files before its agent starts",
          arguments: ["claude-code", "codex"])
    func launchReceivesSharedFiles(agentId: String) async throws {
        let repo = try makeRepo()
        let svc = makeService()
        let card = try await svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "recv-\(agentId)", agentId: agentId))
        try await awaitPhase(svc, card.id, .live)

        let cwd = try #require(await svc.list(includeArchived: true).first { $0.id == card.id }?.cwd)
        #expect(try String(contentsOfFile: cwd + "/CLAUDE.md", encoding: .utf8) == "primary claude rules\n")
        #expect(try String(contentsOfFile: cwd + "/AGENTS.md", encoding: .utf8) == "primary codex rules\n")
        // The Claude adapter installs its skills only because `.claude/` is ignored (the launch grant); Codex
        // declares no launch writes.
        let skill = cwd + "/.claude/skills/orchestra-tree/SKILL.md"
        #expect(FileManager.default.fileExists(atPath: skill) == (agentId == "claude-code"))
    }

    @Test("archiving a card sends its shared edits to the store before the worktree is removed",
          arguments: ["claude-code", "codex"])
    func teardownFlushesBeforeRelease(agentId: String) async throws {
        let repo = try makeRepo()
        let svc = makeService()
        let card = try await svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "flush-\(agentId)", agentId: agentId))
        try await awaitPhase(svc, card.id, .live)
        let cwd = try #require(await svc.list(includeArchived: true).first { $0.id == card.id }?.cwd)

        try "edited by the card\n".write(toFile: cwd + "/CLAUDE.md", atomically: true, encoding: .utf8)
        try await svc.archive(card.id)
        try await awaitPhase(svc, card.id, .archivedComplete)

        #expect(!FileManager.default.fileExists(atPath: cwd))   // the worktree is gone…
        let root = PathResolver.canonical(base) + "/shared"
        let store = SharedStore.gitDirs(root: root, repo: repo, checkout: cwd).store
        let shown = try Proc.checked(["git", "--git-dir", store, "show", "main:CLAUDE.md"]).stdout
        #expect(shown == "edited by the card\n")                // …and its edit reached the store first
    }
}
