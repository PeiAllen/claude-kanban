import Foundation

/// The durable parent link for one branch, mirrored 1:1 to `branch.<child>.orchestra-*` git-config
/// keys. `parent` is the parent ref string (`feature-a` local / `origin/feature-b` remote); `base` is
/// the parent tip OID recorded at the last sync/restack (the redirect anchor); `prNumber`/`watch`
/// ride the optional remote-parent keys.
public struct ParentLink: Sendable, Equatable {
    public var parent: String
    public var base: String
    public var prNumber: Int?
    public var watch: Bool
    public init(parent: String, base: String, prNumber: Int? = nil, watch: Bool = false) {
        self.parent = parent; self.base = base; self.prNumber = prNumber; self.watch = watch
    }
}

/// git-config CRUD for branch lineage — the single source of truth for the parent link. It survives
/// card churn, is plain-git readable (git-town/Graphite style), and never touches refs or worktrees.
/// Writes happen daemon-side (read-only cards have `git config` blocked at launch), so this is the
/// one writer. Every op is `proc.run(["git","-C",repo,"config",…])` through the injected `ProcRunning`
/// seam (no default — a test must choose `RealProc` or a fake explicitly).
public actor BranchLineage {
    private let proc: any ProcRunning
    public init(proc: any ProcRunning) { self.proc = proc }

    // MARK: op serialization (impl-review M2)
    // Every public method was SYNCHRONOUS before the async proc seam — no suspension points, so the
    // actor ran each op to completion and the multi-key write invariants (satellites first,
    // `orchestra-parent` last; the catch-block prior-restore) held for free. The seam introduced an
    // await at every git leaf, so without this FIFO gate two ops could interleave mid-write and
    // manufacture exactly the old-parent/new-base torn state the restore exists to prevent.
    // Public methods acquire; internal cross-calls (`set` → `ancestors`) use the ungated privates.
    private var opBusy = false
    private var opWaiters: [CheckedContinuation<Void, Never>] = []
    private func opAcquire() async {
        if !opBusy { opBusy = true; return }
        await withCheckedContinuation { opWaiters.append($0) }
    }
    private func opRelease() {
        if opWaiters.isEmpty { opBusy = false } else { opWaiters.removeFirst().resume() }
    }

    private static let kParent = "orchestra-parent"
    private static let kBase   = "orchestra-parent-base"
    private static let kPr     = "orchestra-parent-pr"
    private static let kWatch  = "orchestra-parent-watch"
    private static let allSuffixes = [kParent, kBase, kPr, kWatch]

    // Child-progress counters (slice 4). Stored on the PARENT branch, NOT on the child link — so they are
    // deliberately OUT of `allSuffixes`: `clear`/`recordMergedChild` remove a CHILD's link keys and must
    // never wipe a parent's own counter. Neither suffix ends in `.orchestra-parent`, so the `_children`
    // regex can't match them either.
    private static let kMergedCount = "orchestra-merged-count"   // int; children merged + reaped, the `n`
    private static let kPlanned     = "orchestra-planned"        // int; declared plan size, the `m` (unset = none)

    /// Outcome of the one merge-classified removal funnel — `recordMergedChild`.
    public enum MergeRemoval: Sendable, Equatable {
        case absent        // no child link — already reaped; the idempotency no-op (dual-observer / re-detect)
        case linkChanged   // the child now points at a DIFFERENT parent (concurrent re-parent) — don't touch
        case counted       // the link was removed and the parent's merged-count incremented
    }

    private func key(_ branch: String, _ suffix: String) -> String { "branch.\(branch).\(suffix)" }

    private func get(_ repo: String, _ branch: String, _ suffix: String) async -> String? {
        guard let r = try? await proc.run(["git", "-C", repo, "config", "--get", key(branch, suffix)],
                                          cwd: nil, env: [:], timeout: .seconds(120)),
              r.ok else { return nil }
        let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    private func setKey(_ repo: String, _ branch: String, _ suffix: String, _ value: String) async throws {
        let r = try await proc.run(["git", "-C", repo, "config", key(branch, suffix), value],
                                   cwd: nil, env: [:], timeout: .seconds(120))
        if !r.ok { throw OrchestraError.io(r.stderr.isEmpty ? "git config write failed" : r.stderr) }
    }

    /// `--unset` one key; exit 5 (key absent) is not an error.
    private func unset(_ repo: String, _ branch: String, _ suffix: String) async {
        _ = try? await proc.run(["git", "-C", repo, "config", "--unset", key(branch, suffix)],
                                cwd: nil, env: [:], timeout: .seconds(120))
    }

    /// `--unset` one key, DISTINGUISHING outcomes by exit code so a caller can tell "did the key actually
    /// go?" from "the write failed": 0 = removed, 5 = key already absent, anything else = a genuine failure
    /// (a lock / IO error). `recordMergedChild` needs this because the failure-swallowing `unset` above,
    /// paired with a nil-conflating `get` re-read, could read a FAILED clear as "removed" and count while the
    /// link survived — then count AGAIN on retry.
    private enum UnsetOutcome { case removed, absent, failed }
    private func unsetChecked(_ repo: String, _ branch: String, _ suffix: String) async -> UnsetOutcome {
        guard let r = try? await proc.run(["git", "-C", repo, "config", "--unset", key(branch, suffix)],
                                          cwd: nil, env: [:], timeout: .seconds(120)) else { return .failed }
        if r.ok { return .removed }
        if r.exitCode == 5 { return .absent }
        return .failed
    }

    // MARK: CRUD

    /// The parent link for `branch`, or nil if it has no `orchestra-parent` key.
    private func _read(repo: String, branch: String) async -> ParentLink? {
        guard let parent = await get(repo, branch, Self.kParent) else { return nil }
        return ParentLink(parent: parent,
                          base: await get(repo, branch, Self.kBase) ?? "",
                          prNumber: await get(repo, branch, Self.kPr).flatMap(Int.init),
                          watch: await get(repo, branch, Self.kWatch) == "true")
    }

    /// Write the link's keys. Rejects an empty parent, self-parent, and cycles (via `ancestors`) with
    /// `.invalidParams`. The parent key is written LAST — `read` keys on it, so a mid-write failure
    /// leaves NO link rather than a partial one.
    private func _set(repo: String, branch: String, link: ParentLink) async throws {
        guard !link.parent.isEmpty else {
            throw OrchestraError.invalidParams("parent ref must not be empty")
        }
        guard link.parent != branch else {
            throw OrchestraError.invalidParams(
                "a branch cannot be its own parent: \(branch) — pick a different branch as the parent")
        }
        // If `branch` already sits above the proposed parent, adopting it would close a loop.
        if await _ancestors(repo: repo, of: link.parent).contains(branch) {
            throw OrchestraError.invalidParams(
                "parent link would create a cycle: \(branch) → \(link.parent) — pick a parent that is not a "
                + "descendant of \(branch)")
        }
        // S4: capture the prior link so a PARTIAL write can be rolled back. The parent-key-last ordering
        // makes a torn write read as "no link" only when there was NO prior link; RE-pointing an existing
        // link that fails between the base write and the parent write (e.g. `git config` losing to a held
        // `.git/config.lock`) would otherwise leave OLD parent + NEW base — a wrong rebase anchor.
        let prior = await _read(repo: repo, branch: branch)
        do {
            // Satellite keys first; the `orchestra-parent` key (read's existence marker) is the last write.
            try await setKey(repo, branch, Self.kBase, link.base)
            if let pr = link.prNumber { try await setKey(repo, branch, Self.kPr, String(pr)) }
            else { await unset(repo, branch, Self.kPr) }
            if link.watch { try await setKey(repo, branch, Self.kWatch, "true") }
            else { await unset(repo, branch, Self.kWatch) }
            try await setKey(repo, branch, Self.kParent, link.parent)
        } catch {
            // Best-effort restore to the prior link (or clear if there was none), so a partial failure
            // never leaves a torn old-parent/new-base link. Not airtight against a persistent lock, but
            // it recovers the common transient-contention case.
            if let prior {
                try? await setKey(repo, branch, Self.kBase, prior.base)
                if let pr = prior.prNumber { try? await setKey(repo, branch, Self.kPr, String(pr)) }
                else { await unset(repo, branch, Self.kPr) }
                if prior.watch { try? await setKey(repo, branch, Self.kWatch, "true") }
                else { await unset(repo, branch, Self.kWatch) }
                try? await setKey(repo, branch, Self.kParent, prior.parent)
            } else {
                for suffix in Self.allSuffixes { await unset(repo, branch, suffix) }
            }
            throw error
        }
    }

    /// Remove every `orchestra-*` lineage key for `branch` (tolerates already-unset keys).
    private func _clear(repo: String, branch: String) async throws {
        for suffix in Self.allSuffixes { await unset(repo, branch, suffix) }
    }

    /// Update just the recorded parent-tip OID (after a sync/restack).
    private func _updateBase(repo: String, branch: String, oid: String) async throws {
        try await setKey(repo, branch, Self.kBase, oid)
    }

    // MARK: child-progress counters (slice 4)

    /// The merged-children count stored on `branch` (the `n`). 0 when unset/garbage.
    private func _mergedCount(repo: String, branch: String) async -> Int {
        (await get(repo, branch, Self.kMergedCount)).flatMap(Int.init) ?? 0
    }

    /// The declared plan size on `branch` (the `m`), or nil when unset.
    private func _plannedCount(repo: String, branch: String) async -> Int? {
        (await get(repo, branch, Self.kPlanned)).flatMap(Int.init)
    }

    /// Set (or clear) the declared plan size. `n <= 0` clears it (unset), matching the verb's "0/absent
    /// clears" contract; a positive `n` writes it.
    private func _setPlanned(repo: String, branch: String, n: Int) async throws {
        if n <= 0 { await unset(repo, branch, Self.kPlanned) }
        else { try await setKey(repo, branch, Self.kPlanned, String(n)) }
    }

    /// The ONE merge-classified removal funnel (slice 4). Removes `child`'s lineage link AND increments
    /// `expectedParent`'s merged-count — the counter's only writer. The child link's existence is the
    /// idempotency guard, so both the `shipped` verb and a future merge-watch detector can call this and
    /// the SECOND caller (or a post-restart re-detection — "is ancestor" is a level, not an edge) no-ops.
    /// Merge CLASSIFICATION is the caller's job (shipped's advanced-past-base gate; a detector's zero-commit
    /// ancestor guard) — this trusts that the removal it's being asked to record IS a merge.
    ///
    /// CLEAR-FIRST, then a strict RE-READ before counting: removing the `orchestra-parent` marker first
    /// means a crash between the two writes leaves the entry GONE (re-detection → `.absent` → no-op) — a
    /// bounded UNDERcount, never a double-count. Increment-first would double-count on replay. If the clear
    /// doesn't take (a lock/IO failure — the marker survives the re-read), we do NOT count and report the
    /// link as still present, so a later observer retries.
    private func _recordMergedChild(repo: String, child: String, expectedParent: String) async -> MergeRemoval {
        guard let link = await _read(repo: repo, branch: child) else { return .absent }
        guard link.parent == expectedParent else { return .linkChanged }
        // Remove the `orchestra-parent` marker with a CHECKED unset: only a DEFINITE removal (exit 0) counts.
        // A lock/IO failure keeps the link → `.linkChanged` (retry later, don't count); an already-absent
        // marker (exit 5 — an external race after our read) → `.absent` (idempotent: someone else removed it).
        // This is exit-code truth, not a nil-conflating `get` re-read — which is what closes the double-count
        // window (a failed clear read as "removed" would count while the link survived, then count again).
        switch await unsetChecked(repo, child, Self.kParent) {
        case .failed: return .linkChanged
        case .absent: return .absent
        case .removed: break
        }
        for suffix in [Self.kBase, Self.kPr, Self.kWatch] { await unset(repo, child, suffix) }  // best-effort satellites
        // Increment the PARENT's counter. A failure here is the accepted crash-window off-by-one (undercount)
        // — the marker is already gone, so re-detection is `.absent` and never recounts.
        let current = await _mergedCount(repo: repo, branch: expectedParent)
        try? await setKey(repo, expectedParent, Self.kMergedCount, String(current + 1))
        return .counted
    }

    // MARK: tree queries

    /// Child branch names whose recorded parent is `parent` — a fan-out over all lineage keys. `nil` ONLY
    /// when the git read genuinely FAILED (distinct from a legitimately empty child set): the `drained`
    /// decision must not read a transient `--get-regexp` failure as "no children remain" and drain a wave
    /// that still has siblings. `git config --get-regexp` exits 1 when nothing matches (a real empty), 0
    /// with matches, and anything else on a genuine error.
    private func _childrenStrict(repo: String, of parent: String) async -> [String]? {
        let pattern = "^branch\\..*\\.\(Self.kParent)$"
        guard let r = try? await proc.run(["git", "-C", repo, "config", "--get-regexp", pattern],
                                          cwd: nil, env: [:], timeout: .seconds(120)) else { return nil }
        if r.exitCode == 1 { return [] }        // no matching keys → a genuine empty child set
        guard r.ok else { return nil }          // any other non-zero → unknown; don't trust it as empty
        var out: [String] = []
        for line in r.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard value == parent, name.hasPrefix("branch."), name.hasSuffix(".\(Self.kParent)")
            else { continue }
            let child = String(name.dropFirst("branch.".count).dropLast(".\(Self.kParent)".count))
            if !child.isEmpty { out.append(child) }
        }
        return out
    }

    /// Non-strict twin: a read failure reads as an empty child set. Every existing caller
    /// (`shipped` retarget, `tree`, the fan-out) is fine with that — only the `drained` decision needs the
    /// strict variant above.
    private func _children(repo: String, of parent: String) async -> [String] {
        await _childrenStrict(repo: repo, of: parent) ?? []
    }

    /// The parent chain above `branch`, nearest first (cycle-safe via a visited set).
    private func _ancestors(repo: String, of branch: String) async -> [String] {
        var out: [String] = []
        var seen: Set<String> = [branch]
        var cur = branch
        while let link = await _read(repo: repo, branch: cur) {
            let p = link.parent
            if seen.contains(p) { break }   // defensive: a pre-existing cycle can't loop us forever
            out.append(p); seen.insert(p); cur = p
        }
        return out
    }
    // O4/S4: `classify` deleted — it was dead (zero production callers) and disagreed with the
    // load-bearing `RemoteParentRef.parse` (which now also consults `git remote`). Classification runs
    // through that one seam.

    // MARK: gated public surface (see "op serialization" above)
    public func read(repo: String, branch: String) async -> ParentLink? {
        await opAcquire(); defer { opRelease() }
        return await _read(repo: repo, branch: branch)
    }
    public func set(repo: String, branch: String, link: ParentLink) async throws {
        await opAcquire(); defer { opRelease() }
        try await _set(repo: repo, branch: branch, link: link)
    }
    public func clear(repo: String, branch: String) async throws {
        await opAcquire(); defer { opRelease() }
        try await _clear(repo: repo, branch: branch)
    }
    public func updateBase(repo: String, branch: String, oid: String) async throws {
        await opAcquire(); defer { opRelease() }
        try await _updateBase(repo: repo, branch: branch, oid: oid)
    }
    public func children(repo: String, of parent: String) async -> [String] {
        await opAcquire(); defer { opRelease() }
        return await _children(repo: repo, of: parent)
    }
    /// Strict twin — nil ONLY on a genuine git read failure (vs `[]` for a real empty set). The `drained`
    /// decision uses this so a transient read failure can't be read as "no children remain".
    public func childrenStrict(repo: String, of parent: String) async -> [String]? {
        await opAcquire(); defer { opRelease() }
        return await _childrenStrict(repo: repo, of: parent)
    }
    public func ancestors(repo: String, of branch: String) async -> [String] {
        await opAcquire(); defer { opRelease() }
        return await _ancestors(repo: repo, of: branch)
    }
    public func mergedCount(repo: String, branch: String) async -> Int {
        await opAcquire(); defer { opRelease() }
        return await _mergedCount(repo: repo, branch: branch)
    }
    public func plannedCount(repo: String, branch: String) async -> Int? {
        await opAcquire(); defer { opRelease() }
        return await _plannedCount(repo: repo, branch: branch)
    }
    public func setPlanned(repo: String, branch: String, n: Int) async throws {
        await opAcquire(); defer { opRelease() }
        try await _setPlanned(repo: repo, branch: branch, n: n)
    }
    public func recordMergedChild(repo: String, child: String, expectedParent: String) async -> MergeRemoval {
        await opAcquire(); defer { opRelease() }
        return await _recordMergedChild(repo: repo, child: child, expectedParent: expectedParent)
    }
}
