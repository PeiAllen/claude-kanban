import Foundation
import Testing
@testable import OrchestraCore

/// HOST resource exhaustion is its own diagnosable death — `.dead(.resourceExhausted)` carrying WHICH
/// resource ran out — instead of a cryptic misattribution to the card.
///
/// From a real incident: the machine's pty pool was drained (511 max, ~0 free), so tmux could not fork a
/// window and EVERY spawn and resume on the board failed. What the owner was shown was
/// `dead(spawnExitedImmediately)` with `"ENOENT: Bun could not find a file …"` and
/// `dead(resumeFailed)` with `"launch timed out after 30s"` — neither of which says "your machine is out
/// of pseudo-terminals". The board looked broken; the host was.
///
/// Agent-agnostic by construction: the signatures are tmux's and libc's, so the same classification runs
/// for Claude and Codex (pinned by `agentAgnostic` below). Nothing here touches the real host — the stub
/// session backend answers the resource question hermetically (see `StubSessions.hostResourceFault`).
@Suite("Host resource exhaustion — diagnosis + messaging")
struct ResourceExhaustionTests {

    /// The exact string tmux emits with an empty pty pool — measured, not guessed.
    static let tmuxPtyExhausted = "create window failed: fork failed: Device not configured"

    // MARK: - classification (pure)

    @Test("the incident's tmux stderr classifies as a pty exhaustion")
    func classifiesTheIncident() {
        #expect(HostResource.classify(Self.tmuxPtyExhausted) == .pty)
    }

    @Test("host-exhaustion signatures classify to the right resource", arguments: [
        ("create window failed: fork failed: Device not configured", HostResource.pty),
        ("OSError: out of pty devices", .pty),
        ("openpty failed", .pty),
        ("bash: fork: Resource temporarily unavailable", .process),
        ("cannot fork", .process),
        ("error: Too many open files", .fileDescriptor),
        ("EMFILE: too many open files, open '/x'", .fileDescriptor),
        // case-insensitive + embedded in surrounding noise, as real captured output always is
        ("agent: FORK FAILED: DEVICE NOT CONFIGURED (rc=1)", .pty),
    ])
    func classifiesSignatures(_ text: String, _ expected: HostResource) {
        #expect(HostResource.classify(text) == expected)
    }

    /// NON-REGRESSION: ordinary launch failures must NOT be relabelled as host exhaustion. Includes the
    /// literal text the incident's starved spawn printed — proof that this string alone can't be the
    /// signal, and that the live host probe (not string-matching) is what actually catches that case.
    @Test("unrelated failures are not misread as resource exhaustion", arguments: [
        "Error: usage limit reached",
        "unauthorized",
        "ENOENT: Bun could not find a file, and the code that produces this error is missing a better error.",
        "Pane is dead (status 1)",
        "transcript gone",
        "",
    ])
    func doesNotOverClassify(_ text: String) {
        #expect(HostResource.classify(text) == nil)
    }

    @Test("the headline names the resource and its numbers")
    func headlineReadsLikeEnglish() {
        let r = HostResourceReport(resource: .pty, max: 511, free: 0)
        #expect(r.headline == "The host is out of pseudo-terminals (511 max, 0 free).")
        // A host we couldn't take a census of still names the resource — the part that matters.
        #expect(HostResourceReport(resource: .pty).headline == "The host is out of pseudo-terminals.")
    }

    // MARK: - spawn

    /// SPAWN, tmux refusing to create the session: the card must die with the HOST's reason and keep the
    /// raw tmux stderr as the (secondary) detail — not a bare `.spawnFailed`.
    @Test("spawn onto a pty-starved host → dead(resourceExhausted), raw tmux stderr preserved")
    func spawnOnExhaustedHostIsDiagnosed() async throws {
        let env = TestEnv.make()
        env.sessions.ensureError = Self.tmuxPtyExhausted     // tmux cannot fork a window

        let created = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x",
                                                         repo: TestEnv.repo(env.base), branch: "b"))
        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list(includeArchived: true).first { $0.id == created.id }?.phase.kind == .dead
        }

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == created.id })
        #expect(after.deadReason == .resourceExhausted)
        #expect(after.deadReason != .spawnFailed)             // not a generic launch failure…
        #expect(after.deadReason != .spawnExitedImmediately)  // …and not blamed on the agent
        #expect(after.deadResource?.resource == .pty)         // the UI can NAME the resource
        #expect(after.deadDetail?.contains("Device not configured") == true)   // raw evidence kept
    }

    /// NON-REGRESSION twin of the above: the same `ensure` failure on a HEALTHY host still classifies the
    /// way it always did. Only deaths we positively recognise are relabelled.
    @Test("spawn failing for a non-resource reason still → dead(spawnFailed), with its real stderr")
    func spawnFailureOnHealthyHostUnchanged() async throws {
        let env = TestEnv.make()
        env.sessions.ensureError = "tmux: server exited unexpectedly"   // nothing resource-shaped

        let created = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x",
                                                         repo: TestEnv.repo(env.base), branch: "b"))
        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list(includeArchived: true).first { $0.id == created.id }?.phase.kind == .dead
        }

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == created.id })
        #expect(after.deadReason == .spawnFailed)
        #expect(after.deadResource == nil)
        #expect(after.deadDetail?.contains("server exited unexpectedly") == true)
    }

    // MARK: - the startup abort the incident actually produced

    /// THE INCIDENT'S SPAWN, faithfully: tmux got its window, but the starved agent underneath died
    /// instantly printing something entirely unrelated to the real cause. Text alone cannot save us here —
    /// only asking the host "can you still give me a terminal?" reveals the truth.
    ///
    /// Also asserts we do NOT burn the retry budget: relaunching three times into a machine with no ptys
    /// cannot succeed, and is what previously buried the card under the agent's misleading last words.
    @Test("starved agent dying with unrelated output → resourceExhausted (host probe), no doomed retries")
    func startupAbortOnStarvedHostIsDiagnosedByProbe() async throws {
        let env = TestEnv.make(grace: 1)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: "b"))
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 2)   // retries AVAILABLE…
        let ensuresBefore = env.sessions.ensureCount

        // The pane's final words name no resource at all — exactly what the incident showed the owner.
        env.sessions.setPaneText(t.id, "ENOENT: Bun could not find a file, and the code that produces "
                                     + "this error is missing a better error. | Pane is dead (status 1)")
        env.sessions.setPaneDead(t.id)
        env.sessions.simulatedHostFault = .pty                // …but the HOST is what actually failed

        await env.svc.reconcileLiveness()

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.deadReason == .resourceExhausted)
        #expect(after.deadReason != .spawnExitedImmediately)     // the misclassification from the incident
        #expect(after.deadResource?.resource == .pty)
        #expect(env.sessions.ensureCount == ensuresBefore)       // …and NOT re-launched into a dead machine
    }

    /// NON-REGRESSION: the very same dying pane on a HEALTHY host is still a startup abort, still retried,
    /// still carries its evidence. The probe only ever *adds* a diagnosis; it never steals this one.
    @Test("dying pane on a healthy host → still spawnExitedImmediately (classification intact)")
    func startupAbortOnHealthyHostUnchanged() async throws {
        let env = TestEnv.make(grace: 1)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: "b"))
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 0)
        env.sessions.setPaneText(t.id, "Error: usage limit reached")
        env.sessions.setPaneDead(t.id)                        // healthy host: simulatedHostFault stays nil

        await env.svc.reconcileLiveness()

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.deadReason == .spawnExitedImmediately)
        #expect(after.deadResource == nil)
        #expect(after.deadDetail?.contains("usage limit") == true)
    }

    // MARK: - resume (and the live session it used to destroy)

    /// THE PREFLIGHT, and the reason it exists. A resume is `kill` THEN `ensure`. On a pty-starved host the
    /// kill succeeds and the ensure cannot, so a perfectly healthy, actively-running agent was reaped and
    /// then written down as dead — killed by a machine-wide condition it had nothing to do with.
    ///
    /// With the preflight, the bring-up refuses BEFORE the destructive step: the card is told the truth and
    /// its session is left standing.
    @Test("resume on a starved host does NOT kill the live session — it refuses, and says why")
    func resumePreflightSpareTheLiveSession() async throws {
        let env = TestEnv.make(grace: 1, capabilities: .claudeCode)
        let t = try await TestEnv.spawnAwaited(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: "b"))
        env.adapter.writeTranscript(for: t.agentSessionId!)    // a genuinely resumable, LIVE card
        let name = env.sessions.sessionName(t.id)
        let ensuresBefore = env.sessions.ensureCount
        let killsBefore = env.sessions.killed.filter { $0 == name }.count

        env.sessions.simulatedHostFault = .pty                // the machine runs out of ptys…
        try await env.svc.resume(t.id)                        // …and the user hits "Try resume"
        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list(includeArchived: true).first { $0.id == t.id }?.phase.kind == .dead
        }

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == t.id })
        #expect(after.deadReason == .resourceExhausted)
        #expect(after.deadReason != .resumeFailed)            // not "launch timed out after 30s"
        #expect(after.deadResource?.resource == .pty)
        // The point of the preflight: the existing session was never touched.
        #expect(env.sessions.killed.filter { $0 == name }.count == killsBefore)
        #expect(env.sessions.ensureCount == ensuresBefore)
    }

    /// A resource death is TRANSIENT — the machine recovers, and so must the card. Once the ptys come back,
    /// the same card resumes to `.live` with no restart and no lost worktree.
    @Test("a resource-exhausted card resumes cleanly once the host recovers")
    func resourceDeathIsRetryable() async throws {
        let env = TestEnv.make(grace: 1)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: "b"))
        env.adapter.writeTranscript(for: t.agentSessionId!)    // resumable across the outage

        env.sessions.simulatedHostFault = .pty
        try await env.svc.resume(t.id)
        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list(includeArchived: true).first { $0.id == t.id }?.phase.kind == .dead
        }
        #expect(await env.svc.list(includeArchived: true).first { $0.id == t.id }?.deadReason == .resourceExhausted)

        env.sessions.simulatedHostFault = nil                 // the owner frees some terminals
        try await env.svc.resume(t.id)
        let revived = try await TestEnv.reconcileToLive(env.svc, t.id, inject: true)

        #expect(revived.phase.kind == .live)
        #expect(revived.deadReason == nil)                    // the death cleared…
        #expect(revived.deadResource == nil)                  // …including the resource report
    }

    // MARK: - agent-agnostic

    /// Project rule: works for BOTH backends. The resource is consumed by tmux, not by the agent, so the
    /// SAME diagnosis must fall out for a Claude-shaped and a Codex-shaped capability profile.
    @Test("agent-agnostic: identical diagnosis for Claude- and Codex-shaped adapters",
          arguments: [AgentCapabilities.claudeCode, AgentCapabilities.codex])
    func agentAgnostic(_ caps: AgentCapabilities) async throws {
        let env = TestEnv.make(grace: 1, capabilities: caps)
        env.sessions.ensureError = Self.tmuxPtyExhausted

        let created = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x",
                                                         repo: TestEnv.repo(env.base), branch: "b"))
        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list(includeArchived: true).first { $0.id == created.id }?.phase.kind == .dead
        }

        let after = try #require(await env.svc.list(includeArchived: true).first { $0.id == created.id })
        #expect(after.deadReason == .resourceExhausted)
        #expect(after.deadResource?.resource == .pty)
    }
}
