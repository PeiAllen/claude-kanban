import Foundation
import OrchestraKit

public extension CardFileSpec {
    /// The full set of derived per-card files Orchestra owns: each adapter's `cardFile` (Claude's
    /// `--settings`, Codex's launch profile) plus the service's own `inspect` read-only settings file.
    /// A future adapter opts in simply by returning a `cardFile`; no site here changes.
    static func all(adapters: [any Adapter], runtimeStateDir: String) -> [CardFileSpec] {
        adapters.compactMap(\.cardFile)
            + [CardFileSpec(directory: runtimeStateDir, prefix: "readonly-", suffix: ".json", key: .shortId)]
    }
}

extension OrchestraService {
    /// Reap orphaned derived per-card files (Claude `card-settings-*`, Codex `orch-*.config.toml`, the
    /// `readonly-*` inspect settings). Runs at daemon boot (backlog + crash residue) and after a card's
    /// teardown-kill (steady state). PURE decision via `OrphanSweep.reclaimable`; this side does only the
    /// evidence-gathering and the unlink.
    ///
    /// - Parameter specs: nil ⇒ derive from the live registry + config (production). Tests inject specs
    ///   pointed at private roots — the sweep must NEVER be pointed at the real
    ///   `~/Library/Application Support/Orchestra` or `~/.codex` from a stub harness (the ScratchSweepTests
    ///   landmine).
    /// - Parameter grace: keep files modified within this window (an in-flight launch that just wrote one).
    public func sweepCardFiles(specs: [CardFileSpec]? = nil, grace: TimeInterval = 300) async {
        let cards = await store.all()
        let loadComplete = await store.loadWasComplete()
        // Evidence is trustworthy ONLY when the board loaded fully. Two ways it isn't:
        //  • empty ⇒ indistinguishable from a failed/racing load;
        //  • partial ⇒ TaskStore drops undecodable records element-wise (id-less / unknown phase), so a
        //    non-empty `cards` may be MISSING the very live card a candidate file belongs to (`loadWasComplete`).
        // Either way ⇒ prune nothing (the borrow sweep's FIX E, applied here).
        let evidenceIsComplete = !cards.isEmpty && loadComplete
        let live = cards.filter { !$0.archived }
        let specs = specs ?? CardFileSpec.all(adapters: registry.list(), runtimeStateDir: config.runtimeStateDir)
        let now = Date()
        await offActorValue {
            let fm = FileManager.default
            for spec in specs {
                // Forward-computed keep-set: live card → token. Never invert a filename back to a card.
                let keep = Set(live.map { spec.token(for: $0) })
                guard let entries = try? fm.contentsOfDirectory(atPath: spec.directory) else { continue }
                let candidates: [OrphanSweep.Candidate] = entries.compactMap { name in
                    guard name.hasPrefix(spec.prefix), name.hasSuffix(spec.suffix),
                          name.count > spec.prefix.count + spec.suffix.count else { return nil }
                    let token = String(name.dropFirst(spec.prefix.count).dropLast(spec.suffix.count))
                    // Ownership is STRUCTURAL, not just prefix-convention: only reap files whose token has
                    // the exact shape our key generates. A user's own `orch-research.config.toml` in the
                    // real `~/.codex` shares the prefix/suffix but its token isn't a hash → never a candidate.
                    guard spec.hasWellFormedToken(token) else { return nil }
                    let full = "\(spec.directory)/\(name)"
                    // Regular files only — never a directory neighbor like `media/`.
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { return nil }
                    let mtime = (try? fm.attributesOfItem(atPath: full)[.modificationDate]) as? Date ?? .distantPast
                    return OrphanSweep.Candidate(id: token, mtime: mtime)
                }
                for c in OrphanSweep.reclaimable(candidates: candidates, keep: keep,
                                                 evidenceIsComplete: evidenceIsComplete, now: now, grace: grace) {
                    let full = spec.path(token: c.id)
                    // TOCTOU guard: mtime was read during enumeration, but a reopen lands on the SAME cwd
                    // (Recovery clears `archived`, keeps `cwd`) and its `prepareToLaunch` rewrites this exact
                    // file. Re-stat immediately before unlink — a file freshly written since we captured
                    // `now` has mtime within grace and is skipped, so we never delete a revived card's live
                    // file. (This restores the read-then-delete tightness the pre-refactor scratch sweep had.)
                    let current = (try? fm.attributesOfItem(atPath: full)[.modificationDate]) as? Date ?? .distantPast
                    guard now.timeIntervalSince(current) > grace else { continue }
                    try? fm.removeItem(atPath: full)
                }
            }
        }
    }
}
