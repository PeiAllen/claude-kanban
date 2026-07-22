import Testing
import Foundation
@testable import OrchestraCore

@Suite("OrphanSweep.reclaimable — the shared fail-safe decision")
struct OrphanSweepTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func cand(_ id: String, ageSeconds: TimeInterval) -> OrphanSweep.Candidate {
        OrphanSweep.Candidate(id: id, mtime: now.addingTimeInterval(-ageSeconds))
    }

    @Test("incomplete evidence ⇒ reclaim nothing, even for clearly-orphaned candidates")
    func incompleteEvidenceKeepsAll() {
        let out = OrphanSweep.reclaimable(
            candidates: [cand("a", ageSeconds: 10_000)], keep: [],
            evidenceIsComplete: false, now: now, grace: 300)
        #expect(out.isEmpty)
    }

    @Test("a candidate in the keep-set is never reclaimed")
    func keepSetRespected() {
        let out = OrphanSweep.reclaimable(
            candidates: [cand("live", ageSeconds: 10_000), cand("dead", ageSeconds: 10_000)],
            keep: ["live"], evidenceIsComplete: true, now: now, grace: 300)
        #expect(out.map(\.id) == ["dead"])
    }

    @Test("a candidate younger than the grace window is kept (in-flight writer)")
    func graceRespected() {
        let out = OrphanSweep.reclaimable(
            candidates: [cand("fresh", ageSeconds: 100), cand("old", ageSeconds: 1_000)],
            keep: [], evidenceIsComplete: true, now: now, grace: 300)
        #expect(out.map(\.id) == ["old"])
    }

    @Test("grace boundary is exclusive of exactly-grace-old (kept), reclaims strictly older")
    func graceBoundary() {
        let out = OrphanSweep.reclaimable(
            candidates: [cand("exactly", ageSeconds: 300), cand("justOlder", ageSeconds: 301)],
            keep: [], evidenceIsComplete: true, now: now, grace: 300)
        #expect(out.map(\.id) == ["justOlder"])
    }

    @Test("empty candidates ⇒ empty result")
    func emptyCandidates() {
        #expect(OrphanSweep.reclaimable(candidates: [], keep: ["x"],
                                        evidenceIsComplete: true, now: now, grace: 300).isEmpty)
    }
}
