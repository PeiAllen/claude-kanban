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

    /// (GPT-Blocker, boot path) Daemon restart INSIDE the grace: `spawnPending` is in-memory and lost, but
    /// the tmux session survives with a dead pane (remain-on-exit). `recoverSessions` must NOT read that as
    /// alive — it converges the orphan (capture stderr → dead), never leaving it wedged-alive-but-dead.
    @Test("daemon restart (boot recover): a surviving dead-pane session converges to dead, not wedged")
    func daemonRestartBootConverges() async throws {
        let env = TestEnv.make(grace: 1)
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        env.sessions.setPaneText(t.id, "usage limit reached")
        env.sessions.setPaneDead(t.id)                     // aborted: session present, pane dead
        await env.svc.clearSpawnPending(t.id)              // simulate the daemon restart losing in-memory pending

        await env.svc.recoverSessions()                    // tmux session survived (still "alive" in the stub)

        #expect(env.sessions.killed.contains(env.sessions.sessionName(t.id)))   // stale dead-pane session reaped
        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.status == .dead)                     // converged, NOT silently left running-but-dead
        #expect(after.deadReason == .spawnExitedImmediately)
        #expect(after.deadDetail?.contains("usage limit") == true)   // evidence preserved
    }

    /// (GPT-Blocker, CONTINUOUS path — the core convergence requirement) Even if the boot sweep misses it,
    /// the ongoing 2s reconcile MUST converge an orphaned dead pane (session present, agent pane dead, no
    /// `spawnPending`) — otherwise the card hangs "running" forever. Keys on the pane, not session-name
    /// absence (the session is still present), so the generic sessionVanished check would never fire.
    @Test("continuous reconcile converges an orphaned dead pane (lost pending) → dead, evidence preserved")
    func reconcileConvergesOrphanedDeadPane() async throws {
        let env = TestEnv.make(grace: 1)
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        env.sessions.setPaneText(t.id, "unauthorized")
        env.sessions.setPaneDead(t.id)                     // aborted: session present, pane dead
        await env.svc.clearSpawnPending(t.id)              // in-memory pending gone (restart), session persists

        await env.svc.reconcileLiveness()                  // the continuous poll must resolve it

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.status == .dead)                     // converged — not hanging "running"
        #expect(after.deadReason == .spawnExitedImmediately)
        #expect(after.deadReason != .sessionVanished)
        #expect(after.deadDetail?.contains("unauthorized") == true)
        #expect(env.sessions.killed.contains(env.sessions.sessionName(t.id)))   // orphan session reaped
    }

    /// (GPT-Blocker round 2) Daemon restart during grace while the pane is STILL ALIVE: the session survives
    /// with remain-on-exit ON but `spawnPending` is gone, so the card would never graduate and a later NORMAL
    /// mid-run exit would leave a dead pane MISread as a startup abort. Boot must clear remain-on-exit for the
    /// alive survivor so a later exit is correctly `.sessionVanished`, not `.spawnExitedImmediately`.
    @Test("daemon restart while pane alive: boot clears remain-on-exit → later exit is sessionVanished")
    func daemonRestartWhilePaneAliveNotMisclassified() async throws {
        let env = TestEnv.make(grace: 1)
        await env.svc.setStartupConfirmation(graceSeconds: 4, maxRetries: 1)   // long grace: still armed at "restart"
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        let name = env.sessions.sessionName(t.id)
        #expect(env.sessions.remainOnExit[name] == true)   // spawn armed it

        // Restart WHILE the pane is still alive: in-memory pending lost, session + remain-on-exit survive.
        await env.svc.clearSpawnPending(t.id)
        await env.svc.recoverSessions()

        #expect(env.sessions.remainOnExit[name] == false)  // boot cleared the stuck arm → invariant restored
        let mid = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(mid.status != .dead)                       // healthy survivor, not clobbered

        // A later genuine mid-run exit now vanishes the session (remain-on-exit off), not a dead pane.
        env.sessions.setAlive(t.id, false)
        await env.svc.reconcileLiveness()

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.status == .dead)
        #expect(after.deadReason == .sessionVanished)      // correctly classified, NOT spawnExitedImmediately
        #expect(after.deadReason != .spawnExitedImmediately)
    }

    /// (GPT-Important B) If graduation's remain-on-exit→off toggle FAILS, the card must stay startup-pending
    /// (not clear + wedge), so a later crash is still caught — otherwise a dead pane in a present session
    /// would never be seen as vanished.
    @Test("failed graduation toggle keeps the card pending so a later crash is still classified")
    func failedGraduationTogglePreservesPending() async throws {
        let env = TestEnv.make(grace: 1)
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 0)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        env.sessions.failRemainOnExitOff = true            // graduation's toggle-off will throw

        await env.svc.reconcileLiveness()                  // alive + past deadline → toggle fails → STAY pending
        let mid = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(mid.status != .dead)                       // still healthy, not clobbered

        env.sessions.setPaneDead(t.id)                     // the card later aborts/crashes while still watched
        await env.svc.reconcileLiveness()

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        // Proof pending survived the failed toggle: the crash is classified, not masked as a live session.
        #expect(after.status == .dead)
        #expect(after.deadReason == .spawnExitedImmediately)
    }

    /// (GPT-Important C) A card concluded to `.done` DURING the capture await (a fast read-only/freeform
    /// child reporting task_complete) must be left alone — not retried, not marked dead by the abort path.
    @Test("card that turns .done during the capture await is not retried or marked dead")
    func doneDuringCaptureLeftAlone() async throws {
        let env = TestEnv.make(grace: 1)
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 1)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        env.sessions.setPaneDead(t.id)
        env.sessions.captureSleepMs = 200                  // widen the capture window
        let ensureAfterSpawn = env.sessions.ensureCount

        async let reconciled: Void = env.svc.reconcileLiveness()   // enters handleStartupAbort, suspends in capture
        try await _Concurrency.Task.sleep(for: .milliseconds(50))  // land inside the capture await
        try await env.svc.report(t.id, StatusReport(status: .done))// card concludes mid-capture
        await reconciled

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.status == .done)                     // preserved…
        #expect(after.deadReason == nil)                   // …not marked dead
        #expect(env.sessions.ensureCount == ensureAfterSpawn)      // …and not re-spawned
    }

    /// A `send` arriving during the startup grace is NOT swallowed (startup-pending is separate from
    /// `recovering`, so wake gate A stays open) — it queues and is available for delivery.
    @Test("a send during the startup grace is not dropped")
    func sendDuringGraceNotDropped() async throws {
        let env = TestEnv.make(grace: 1)
        await env.svc.setStartupConfirmation(graceSeconds: 4, maxRetries: 1)   // stay pending across the send
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))   // .running, startup-pending
        try await env.svc.send(t.id, "hello during grace")
        // A running card queues the send for its Stop-drain (gate B) — the point is it is NOT lost at gate A.
        #expect(try await env.svc.inboxPeek(t.id).map(\.text) == ["hello during grace"])
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
