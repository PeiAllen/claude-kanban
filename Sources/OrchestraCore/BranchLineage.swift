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

    // MARK: tree queries

    /// Child branch names whose recorded parent is `parent` — a fan-out over all lineage keys.
    private func _children(repo: String, of parent: String) async -> [String] {
        let pattern = "^branch\\..*\\.\(Self.kParent)$"
        guard let r = try? await proc.run(["git", "-C", repo, "config", "--get-regexp", pattern],
                                          cwd: nil, env: [:], timeout: .seconds(120)), r.ok
        else { return [] }
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
    public func ancestors(repo: String, of branch: String) async -> [String] {
        await opAcquire(); defer { opRelease() }
        return await _ancestors(repo: repo, of: branch)
    }
}
