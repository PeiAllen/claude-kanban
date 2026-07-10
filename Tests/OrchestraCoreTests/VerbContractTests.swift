import Foundation
import Testing
@testable import OrchestraCore   // @_exported brings in OrchestraKit

@Suite("Verb contract — kind + phaseGate + dispatch gate (PR4a)")
struct VerbContractTests {

    // The expected policy, mirrored from spec §6 (deny-by-default allow-sets over Phase.Kind).
    private static let allKinds: Set<Phase.Kind> =
        [.creatingWorktree, .launching, .live, .relaunching, .dead, .archivedPending, .archivedComplete]
    private static let nonArchived: Set<Phase.Kind> =
        [.creatingWorktree, .launching, .live, .relaunching, .dead]
    private static let liveDead: Set<Phase.Kind> = [.live, .dead]

    private static let expected: [String: (VerbKind, Set<Phase.Kind>)] = [
        "list": (.query, allKinds), "status": (.query, allKinds), "sessions": (.query, allKinds),
        "capture": (.query, allKinds), "tree": (.query, allKinds), "trustState": (.query, allKinds),
        "inbox": (.query, allKinds),
        "move": (.mutation, nonArchived), "send": (.mutation, nonArchived), "trust": (.mutation, nonArchived),
        "wait": (.mutation, allKinds),
        "inbox-edit": (.mutation, nonArchived), "inbox-remove": (.mutation, nonArchived),
        "inbox-reorder": (.mutation, nonArchived),
        "set-parent": (.mutation, liveDead), "synced": (.mutation, liveDead), "shipped": (.mutation, liveDead),
        "merge-request": (.mutation, liveDead), "borrow": (.mutation, liveDead), "release": (.mutation, liveDead),
        "shell": (.mutation, liveDead), "inspect": (.mutation, liveDead), "closeShell": (.mutation, liveDead),
        "exec": (.mutation, liveDead), "send-keys": (.mutation, liveDead),
        "spawn": (.convergence, allKinds), "batch-spawn": (.convergence, allKinds),
        "archive": (.convergence, allKinds),   // idempotency deviation: re-archive must no-op, not error
        "reopen": (.convergence, [.archivedPending, .archivedComplete]),
        "resume": (.convergence, [.live, .dead, .relaunching]),
        "restart": (.convergence, [.live, .dead, .relaunching]),
        "handoff": (.convergence, liveDead),
    ]

    @Test("test_everyVerbDeclaresKind")
    func test_everyVerbDeclaresKind() {
        for schema in CommandCatalog.all {
            guard let (kind, gate) = Self.expected[schema.name] else {
                Issue.record("verb '\(schema.name)' is unclassified in the expected §6 policy"); continue
            }
            #expect(schema.kind == kind, "verb '\(schema.name)' kind")
            #expect(schema.phaseGate == gate, "verb '\(schema.name)' phaseGate")
            if schema.kind != .query {
                #expect(!schema.phaseGate.isEmpty, "Mutation/Convergence verb '\(schema.name)' must declare a non-empty gate")
            }
        }
        // Completeness: the catalog and the expected policy cover exactly the same verbs.
        #expect(Set(CommandCatalog.all.map(\.name)) == Set(Self.expected.keys))
    }

    /// Records whether a wrapped handler was ever invoked — the direct "handler never reached" oracle.
    private actor RunProbe { var ran = false; func mark() { ran = true } }

    @Test("test_gateEnforcedAtDispatch")
    func test_gateEnforcedAtDispatch() async throws {
        // A gated-out call must never reach its handler. Proven TWO ways: (1) a probe handler wrapping the
        // real denied schema records if it runs; (2) an observable side-effect absence (the real `send`
        // handler would enqueue to the inbox). `send` (board mutation, gate = non-archived) is denied on an
        // archived card (effective kind archivedComplete via the bridge).
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "x", repo: repo, branch: "b"))
        // Seed the archived terminal state as the intent-only `archive` + TeardownStepper leaves it
        // (PR4b Task 4: `.archived(_)` is the sole archived representation — no Bool-bridge).
        _ = try await env.svc.store.update(card.id) { $0.phase = .archived(teardownComplete: true); $0.archived = true }

        // (1) Wrap the REAL `send` schema around a probe `run` that MUST NOT fire.
        let sendSchema = try #require(CommandRegistry().command("send")).schema
        let probe = RunProbe()
        let probed = Command(schema: sendSchema, run: { _, _, _ in await probe.mark(); return .ok() })
        await #expect(throws: OrchestraError.phaseGated(verb: "send", phase: "archivedComplete")) {
            _ = try await CommandRegistry().dispatch(probed, env.svc,
                            .object(["ref": .string(card.shortId), "message": .string("blocked")]), .cli)
        }
        #expect(await probe.ran == false, "the gated handler must never be invoked")

        // (2) And the REAL handler leaves no side effect — nothing enqueued.
        let realSend = try #require(CommandRegistry().command("send"))
        await #expect(throws: OrchestraError.phaseGated(verb: "send", phase: "archivedComplete")) {
            _ = try await CommandRegistry().dispatch(realSend, env.svc,
                            .object(["ref": .string(card.shortId), "message": .string("blocked")]), .cli)
        }
        #expect(try await env.svc.inboxPeek(card.id).isEmpty, "gated `send` must not reach the inbox handler")
    }

    @Test("test_gatePolicyConformance")
    func test_gatePolicyConformance() async throws {
        // PR4b Task 4: the gate reads `card.phase.kind` DIRECTLY (Bool-bridge retired). Prove an archived
        // card gates via its real phase kind — for BOTH archived kinds — and that `archive` (gAll) never
        // denies an idempotent re-archive.
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "x", repo: repo, branch: "b"))
        let reg = CommandRegistry()

        for (phase, gatedName) in [(Phase.archived(teardownComplete: false), "archivedPending"),
                                   (Phase.archived(teardownComplete: true), "archivedComplete")] {
            _ = try await env.svc.store.update(card.id) { $0.phase = phase; $0.archived = true }
            // `send` (gate = non-archived) is denied, naming the card's ACTUAL phase kind.
            let send = try #require(reg.command("send"))
            await #expect(throws: OrchestraError.phaseGated(verb: "send", phase: gatedName)) {
                _ = try await reg.dispatch(send, env.svc,
                        .object(["ref": .string(card.shortId), "message": .string("x")]), .cli)
            }
            // `archive` (gate = gAll) is admitted by the gate — the handler's own idempotency guard no-ops it.
            let archive = try #require(reg.command("archive"))
            _ = try await reg.dispatch(archive, env.svc, .object(["ref": .string(card.shortId)]), .cli)
            #expect(try #require(await env.svc.store.get(card.id)).phase == phase)   // unchanged (idempotent)
        }
    }

    @Test("test_openShellDeniedWhileLaunching")
    func test_openShellDeniedWhileLaunching() async throws {
        // Bug #3: shell/inspect must NOT claim the agent session while a card is being born.
        for phase in [Phase.creatingWorktree, .launching, .relaunching] {
            for verb in ["shell", "inspect"] {
                let env = TestEnv.make()
                let repo = TestEnv.repo(env.base)
                let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "x", repo: repo, branch: "b"))
                _ = try await env.svc.store.update(card.id) { $0.phase = phase }
                // Make the session NOT alive, so an UNGATED shell/inspect WOULD call
                // `sessions.ensure(argv:["/bin/sh"])` (both guard behind `if !isAlive`). This makes the
                // "ensureCount unchanged" assertion below a genuine proof of bug #3, not a vacuous one.
                env.sessions.setAlive(card.id, false)
                let ensureBefore = env.sessions.ensureCount   // captured AFTER killing the session

                let reg = CommandRegistry()
                let cmd = try #require(reg.command(verb))
                await #expect(throws: OrchestraError.phaseGated(verb: verb, phase: phase.kind.rawValue)) {
                    _ = try await reg.dispatch(cmd, env.svc, .object(["ref": .string(card.shortId)]), .cli)
                }
                // The agent session name was never claimed by /bin/sh — the gate fired before `ensure`.
                #expect(env.sessions.ensureCount == ensureBefore,
                        "\(verb) on \(phase.kind.rawValue) must not claim the session with /bin/sh (bug #3)")
            }
        }
    }
}
