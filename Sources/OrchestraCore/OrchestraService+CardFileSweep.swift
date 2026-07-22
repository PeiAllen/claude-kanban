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
        guard !cards.isEmpty, loadComplete else { return }
        let specs = specs ?? CardFileSpec.all(adapters: registry.list(), runtimeStateDir: config.runtimeStateDir)
        let now = Date()

        // Phase 1 — ENUMERATE off-actor: readdir + shape + ownership-marker + regular-file + mtime. No
        // deletion here; this is the slow (stat-per-file) part and it needs no live-card knowledge.
        let enumerated: [(spec: CardFileSpec, candidates: [OrphanSweep.Candidate])] =
            await offActorValue {
                let fm = FileManager.default
                return specs.map { spec in
                    let entries = (try? fm.contentsOfDirectory(atPath: spec.directory)) ?? []
                    let candidates: [OrphanSweep.Candidate] = entries.compactMap { name in
                        guard name.hasPrefix(spec.prefix), name.hasSuffix(spec.suffix),
                              name.count > spec.prefix.count + spec.suffix.count else { return nil }
                        let token = String(name.dropFirst(spec.prefix.count).dropLast(spec.suffix.count))
                        // Ownership shape: only tokens with the exact form our key GENERATES (a canonical
                        // hash / a shortId). A user's `orch-research.config.toml` fails here.
                        guard spec.hasWellFormedToken(token) else { return nil }
                        let full = "\(spec.directory)/\(name)"
                        var isDir: ObjCBool = false
                        guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { return nil }
                        // Ownership PROOF for a shared directory (`~/.codex`): the file must carry the marker
                        // Orchestra stamped. A user's hand-written `orch-<16-hex>.config.toml` — same name
                        // shape, no marker — is therefore never a candidate. Files in Orchestra's exclusive
                        // data dir set no marker (the directory itself is the proof).
                        if let marker = spec.ownershipMarker, !Self.fileHasMarker(full, marker, fm: fm) { return nil }
                        let mtime = (try? fm.attributesOfItem(atPath: full)[.modificationDate]) as? Date ?? .distantPast
                        return OrphanSweep.Candidate(id: token, mtime: mtime)
                    }
                    return (spec, candidates)
                }
            }

        // Phase 2 — FRESH keep-set, on-actor, as late as possible before deletion. Spawn PERSISTS a card
        // before its `prepareToLaunch` writes the file, so any card that could have written a candidate
        // path is already in the store by now — including a DIFFERENT card that came live on a shared cwd
        // AFTER our first snapshot. This is what closes the "keep-set captured before B existed" race; the
        // per-file re-stat below is the second, finer guard for the residual stat→unlink window.
        let live = await store.all().filter { !$0.archived }

        // Phase 3 — DELETE off-actor against the fresh keep-set.
        await offActorValue {
            let fm = FileManager.default
            for (spec, candidates) in enumerated {
                let keep = Set(live.map { spec.token(for: $0) })   // fresh: protects cards that just came live
                for c in OrphanSweep.reclaimable(candidates: candidates, keep: keep,
                                                 evidenceIsComplete: true, now: now, grace: grace) {
                    let full = spec.path(token: c.id)
                    // Re-stat immediately before unlink: a card (re)launched onto this same path since we
                    // enumerated has a fresh mtime (within grace) → skipped. Collapses the residual TOCTOU
                    // to the stat→unlink window and matches the pre-refactor scratch sweep's tightness.
                    let current = (try? fm.attributesOfItem(atPath: full)[.modificationDate]) as? Date ?? .distantPast
                    guard now.timeIntervalSince(current) > grace else { continue }
                    try? fm.removeItem(atPath: full)
                }
            }
        }
    }

    /// True iff the file at `path` begins with `marker` (read just the head — the marker is the first line).
    private static func fileHasMarker(_ path: String, _ marker: String, fm: FileManager) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: max(marker.utf8.count, 256))) ?? Data()
        return String(decoding: head, as: UTF8.self).hasPrefix(marker)
    }
}
