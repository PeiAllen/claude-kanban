import Foundation

/// The fail-safe contract every Orchestra orphan sweep obeys, stated ONCE and PURE (no IO, no clock,
/// no filesystem) so it unit-tests with neither. Callers supply candidates + a forward-computed keep-set
/// and perform the deletion themselves; this only decides. See the sweeps that independently re-derived
/// this (`sweepOrphanScratch` / `sweepOrphanBorrows` / `sweepOrphanSessions`) — the encoded bug fixes
/// there are exactly rules (1)–(3) below.
public enum OrphanSweep {
    /// One sweep candidate: an opaque id (matched against `keep`) and the mtime used for the grace gate.
    public struct Candidate: Sendable {
        public let id: String
        public let mtime: Date
        public init(id: String, mtime: Date) { self.id = id; self.mtime = mtime }
    }

    /// Decide which candidates are safe to reclaim. Rules, in order:
    ///  (1) `evidenceIsComplete == false` ⇒ reclaim NOTHING. An empty/failed store load is "unknown",
    ///      never "everything is orphaned".
    ///  (2) Keep anything whose id is in `keep` — the keep-set is forward-computed from live cards, never
    ///      inverted from a filename, so it is authoritative for "still referenced".
    ///  (3) Keep anything modified within `grace` of `now` — an in-flight writer that has not registered
    ///      its card yet (e.g. a launch that just wrote the file microseconds before the sweep ran).
    public static func reclaimable(candidates: [Candidate], keep: Set<String>,
                                   evidenceIsComplete: Bool, now: Date,
                                   grace: TimeInterval) -> [Candidate] {
        guard evidenceIsComplete else { return [] }                        // (1)
        return candidates.filter { c in
            !keep.contains(c.id)                                           // (2)
                && now.timeIntervalSince(c.mtime) > grace                  // (3)
        }
    }
}
