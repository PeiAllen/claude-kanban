import Foundation
import Testing
@testable import OrchestraCore

/// Spawn startup-abort classification: an agent that exits within its first seconds is a DISTINCT,
/// diagnosable, self-healing launch abort — `.spawnExitedImmediately` with captured stderr + bounded
/// retry — not a silent permanent `.sessionVanished`. The seam is `ensure` + `reconcileLiveness`, and it
/// is agent-agnostic (no `if agent==…`). An abort is modeled as a pane that DIED while the session
/// persists (what tmux `remain-on-exit` leaves behind); a fully-gone session is a normal mid-run vanish.
@Suite("OrchestraService — spawn startup-abort classification")
struct StartupAbortTests {

    /// (i) Immediate exit, no retries → dead with the NEW reason + non-empty captured detail, NOT sessionVanished.
    @Test("startup abort with no retries → dead(spawnExitedImmediately) + captured detail")
    func immediateExitClassified() async throws {
        let env = TestEnv.make(grace: 1)
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 0)   // no retry; deadline already past
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        env.sessions.setPaneText(t.id, "Error: usage limit reached\nprocess exited")
        env.sessions.setPaneDead(t.id)                                          // aborted: pane dead, session present

        await env.svc.reconcileLiveness()

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.status == .dead)
        #expect(after.deadReason == .spawnExitedImmediately)
        #expect(after.deadReason != .sessionVanished)
        #expect(after.deadDetail?.isEmpty == false)
        #expect(after.deadDetail?.contains("usage limit") == true)
    }

    /// (ii) Auto-retry fires; the retry stays up → the card ends ALIVE (not dead), with exactly one extra launch.
    @Test("startup abort then healthy retry → alive, one bounded re-spawn, no worktree churn")
    func retryRecovers() async throws {
        let env = TestEnv.make(grace: 1)
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        let ensureAfterSpawn = env.sessions.ensureCount
        let worktreesAfterSpawn = env.worktrees.ensured.count
        env.sessions.setPaneDead(t.id)                     // first launch aborts

        await env.svc.reconcileLiveness()                  // detect abort → retry (kill + fresh ensure → live pane)
        #expect(env.sessions.ensureCount == ensureAfterSpawn + 1)   // exactly one retry launch (no double-create)

        await env.svc.reconcileLiveness()                  // retry is alive + past deadline → graduate

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.status != .dead)
        #expect(after.deadReason == nil)
        #expect(env.worktrees.ensured.count == worktreesAfterSpawn)   // retry reused the cwd — no new worktree
    }

    /// (iii) A genuine mid-session vanish (gone session, AFTER startup) still → sessionVanished (no regression).
    @Test("graduated card that later vanishes → sessionVanished, not a startup abort")
    func midRunVanishStillSessionVanished() async throws {
        let env = TestEnv.make(grace: 1)
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))

        await env.svc.reconcileLiveness()                  // pane alive + deadline past → graduate (pending cleared)
        env.sessions.setAlive(t.id, false)                 // NOW it vanishes mid-run (session gone)
        await env.svc.reconcileLiveness()

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.status == .dead)
        #expect(after.deadReason == .sessionVanished)
    }

    /// (iv) A startup abort that keeps aborting exhausts the retry budget and ends dead (bounded — never loops).
    @Test("startup abort that never recovers → dead after exactly maxStartupRetries respawns")
    func retryExhaustionEndsDead() async throws {
        let env = TestEnv.make(grace: 1)
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        env.sessions.setPaneText(t.id, "unauthorized")
        env.sessions.setPaneDead(t.id)

        await env.svc.reconcileLiveness()                  // attempt 0 < 1 → retry (kill reaps the old pane; fresh ensure)
        env.sessions.setPaneText(t.id, "unauthorized")     // the retry's launch emits its own stderr…
        env.sessions.setPaneDead(t.id)                     // …then also aborts immediately
        await env.svc.reconcileLiveness()                  // attempt 1 == max → give up

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.status == .dead)
        #expect(after.deadReason == .spawnExitedImmediately)
        #expect(after.deadDetail?.contains("unauthorized") == true)
    }

    /// (vi) Don't fight a kill: a card ARCHIVED while startup-pending is not resurrected by a later retry.
    @Test("archive during startup grace clears pending → no resurrecting re-spawn")
    func archiveDuringGraceNotResurrected() async throws {
        let env = TestEnv.make(grace: 1)
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        env.sessions.setPaneDead(t.id)
        let ensureAfterSpawn = env.sessions.ensureCount

        try await env.svc.archive(t.id)                    // user archives the card (kills session, clears pending)
        await env.svc.reconcileLiveness()                  // must NOT retry/re-ensure an archived card

        #expect(env.sessions.ensureCount == ensureAfterSpawn)   // no resurrecting launch
        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.archived == true)
    }

    /// (vii) A SessionEnd death while startup-pending wins + clears pending → no retry resurrects it.
    @Test("SessionEnd death during startup grace clears pending → stays dead(agentExited), no retry")
    func sessionEndDuringGraceStaysDead() async throws {
        let env = TestEnv.make(grace: 1)
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        let ensureAfterSpawn = env.sessions.ensureCount

        try await env.svc.report(t.id, StatusReport(endReason: "exit"))   // genuine SessionEnd → dead(agentExited)
        await env.svc.reconcileLiveness()                                 // must NOT re-spawn the dead card

        #expect(env.sessions.ensureCount == ensureAfterSpawn)
        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.status == .dead)
        #expect(after.deadReason == .agentExited)   // SessionEnd classification preserved, not overwritten
    }

    /// (v) Agent-agnostic: the SAME startup-abort classification runs for a Claude-shaped and a Codex-shaped
    /// adapter (capability profiles differ; the path does not). Proves there is no `if agent==…` branch.
    @Test("agent-agnostic: startup abort classified identically for Claude- and Codex-shaped adapters",
          arguments: [AgentCapabilities.claudeCode, AgentCapabilities.codex])
    func agentAgnostic(_ caps: AgentCapabilities) async throws {
        let env = TestEnv.make(grace: 1, capabilities: caps)
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 0)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        env.sessions.setPaneText(t.id, "unauthorized")
        env.sessions.setPaneDead(t.id)

        await env.svc.reconcileLiveness()

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.deadReason == .spawnExitedImmediately)
        #expect(after.deadDetail?.contains("unauthorized") == true)
    }
}
