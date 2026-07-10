import Foundation
import Testing
@testable import OrchestraCore

@Suite("PhaseStepper — protocol contract (skeleton, PR4a)")
struct StepperTests {

    /// A trivial conforming stepper used ONLY to exercise the protocol's idempotency contract.
    /// (The four real steppers — Materialize/Launch/Relaunch/Teardown — are PR4b.) It advances a
    /// card creatingWorktree → launching through the real funnel; a second `step` is a funnel no-op,
    /// so no side effect repeats.
    private struct DoubleStepper: PhaseStepper {
        static var drives: Phase.Kind { .creatingWorktree }
        func step(_ card: Task, _ ctx: ConvergeContext) async throws {
            _ = await ctx.transition(card.id, .launching, nil)
        }
        func verify(_ card: Task, _ ctx: ConvergeContext) async -> Bool {
            (await ctx.store.get(card.id))?.phase.kind == .launching
        }
    }

    @Test("the reconciler-owned stepper map is an empty skeleton in PR4a")
    func test_stepperMapEmptyInPR4a() {
        #expect(PhaseSteppers.byKind.isEmpty)
    }

    @Test("test_stepperStepIsIdempotent")
    func test_stepperStepIsIdempotent() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        // Seed a being-born phase directly (live→creatingWorktree is not a legal verb edge).
        _ = try await env.svc.store.update(card.id) { $0.phase = .creatingWorktree }

        let ctx = await env.svc.convergeContext()
        let stepper = DoubleStepper()

        try await stepper.step(card, ctx)
        let after1 = try #require(await env.svc.store.get(card.id))
        #expect(after1.phase.kind == .launching)
        #expect(await stepper.verify(card, ctx))

        // Second call from the same phase: the funnel rejects/no-ops the redundant edge — no repeat side
        // effect. `phaseChangedAt` is stamped ONLY on an applied edge, so it must be unchanged.
        try await stepper.step(card, ctx)
        let after2 = try #require(await env.svc.store.get(card.id))
        #expect(after2.phase.kind == .launching)
        #expect(after2.phaseChangedAt == after1.phaseChangedAt)
    }
}
