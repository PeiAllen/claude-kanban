import Foundation
import Testing
import OrchestraKit
@testable import OrchestraCore

@Suite("PropagationEligibility — does this checkout take part")
struct PropagationEligibilityTests {
    @Test("worktree card participates")
    func worktreeParticipates() {
        let result = PropagationEligibility.decide(
            origin: .worktree, checkoutRepo: .insideRepo(root: "/repo/primary"), primaryRoot: "/repo/primary")
        #expect(result == .participates)
    }

    @Test("worktree card participates even if checkoutRepo happens to equal primaryRoot — only .borrowed compares against the primary")
    func worktreeParticipatesRegardlessOfResolvedRoot() {
        let result = PropagationEligibility.decide(
            origin: .worktree, checkoutRepo: .outsideAnyRepo, primaryRoot: "/repo/primary")
        #expect(result == .participates)
    }

    @Test("scratch card is always skipped")
    func scratchSkipped() {
        let result = PropagationEligibility.decide(
            origin: .scratch, checkoutRepo: .insideRepo(root: "/repo/primary"), primaryRoot: "/repo/primary")
        #expect(result == .skipped)
    }

    @Test("borrowed card inside a known repo, not the primary, participates")
    func borrowedInsideKnownRepoParticipates() {
        let result = PropagationEligibility.decide(
            origin: .borrowed, checkoutRepo: .insideRepo(root: "/repo/secondary"), primaryRoot: "/repo/primary")
        #expect(result == .participates)
    }

    @Test("borrowed card AT the primary checkout is skipped — never sync onto self")
    func borrowedAtPrimarySkipped() {
        let result = PropagationEligibility.decide(
            origin: .borrowed, checkoutRepo: .insideRepo(root: "/repo/primary"), primaryRoot: "/repo/primary")
        #expect(result == .skipped)
    }

    @Test("borrowed card outside any known repo is skipped")
    func borrowedOutsideKnownRepoSkipped() {
        let result = PropagationEligibility.decide(
            origin: .borrowed, checkoutRepo: .outsideAnyRepo, primaryRoot: "/repo/primary")
        #expect(result == .skipped)
    }
}
