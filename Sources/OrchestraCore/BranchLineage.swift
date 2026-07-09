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
/// one writer. Every op is `Proc.run(["git","-C",repo,"config",…])` — the house git idiom.
public actor BranchLineage {
    public init() {}

    private static let kParent = "orchestra-parent"
    private static let kBase   = "orchestra-parent-base"
    private static let kPr     = "orchestra-parent-pr"
    private static let kWatch  = "orchestra-parent-watch"
    private static let allSuffixes = [kParent, kBase, kPr, kWatch]

    private func key(_ branch: String, _ suffix: String) -> String { "branch.\(branch).\(suffix)" }

    private func get(_ repo: String, _ branch: String, _ suffix: String) -> String? {
        guard let r = try? Proc.run(["git", "-C", repo, "config", "--get", key(branch, suffix)]),
              r.ok else { return nil }
        let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    private func setKey(_ repo: String, _ branch: String, _ suffix: String, _ value: String) throws {
        let r = try Proc.run(["git", "-C", repo, "config", key(branch, suffix), value])
        if !r.ok { throw OrchestraError.io(r.stderr.isEmpty ? "git config write failed" : r.stderr) }
    }

    /// `--unset` one key; exit 5 (key absent) is not an error.
    private func unset(_ repo: String, _ branch: String, _ suffix: String) {
        _ = try? Proc.run(["git", "-C", repo, "config", "--unset", key(branch, suffix)])
    }

    // MARK: CRUD

    /// The parent link for `branch`, or nil if it has no `orchestra-parent` key.
    public func read(repo: String, branch: String) -> ParentLink? {
        guard let parent = get(repo, branch, Self.kParent) else { return nil }
        return ParentLink(parent: parent,
                          base: get(repo, branch, Self.kBase) ?? "",
                          prNumber: get(repo, branch, Self.kPr).flatMap(Int.init),
                          watch: get(repo, branch, Self.kWatch) == "true")
    }

    /// Write the link's keys. Rejects an empty parent, self-parent, and cycles (via `ancestors`) with
    /// `.invalidParams`. The parent key is written LAST — `read` keys on it, so a mid-write failure
    /// leaves NO link rather than a partial one.
    public func set(repo: String, branch: String, link: ParentLink) throws {
        guard !link.parent.isEmpty else {
            throw OrchestraError.invalidParams("parent ref must not be empty")
        }
        guard link.parent != branch else {
            throw OrchestraError.invalidParams(
                "a branch cannot be its own parent: \(branch) — pick a different branch as the parent")
        }
        // If `branch` already sits above the proposed parent, adopting it would close a loop.
        if ancestors(repo: repo, of: link.parent).contains(branch) {
            throw OrchestraError.invalidParams(
                "parent link would create a cycle: \(branch) → \(link.parent) — pick a parent that is not a "
                + "descendant of \(branch)")
        }
        // S4: capture the prior link so a PARTIAL write can be rolled back. The parent-key-last ordering
        // makes a torn write read as "no link" only when there was NO prior link; RE-pointing an existing
        // link that fails between the base write and the parent write (e.g. `git config` losing to a held
        // `.git/config.lock`) would otherwise leave OLD parent + NEW base — a wrong rebase anchor.
        let prior = read(repo: repo, branch: branch)
        do {
            // Satellite keys first; the `orchestra-parent` key (read's existence marker) is the last write.
            try setKey(repo, branch, Self.kBase, link.base)
            if let pr = link.prNumber { try setKey(repo, branch, Self.kPr, String(pr)) }
            else { unset(repo, branch, Self.kPr) }
            if link.watch { try setKey(repo, branch, Self.kWatch, "true") }
            else { unset(repo, branch, Self.kWatch) }
            try setKey(repo, branch, Self.kParent, link.parent)
        } catch {
            // Best-effort restore to the prior link (or clear if there was none), so a partial failure
            // never leaves a torn old-parent/new-base link. Not airtight against a persistent lock, but
            // it recovers the common transient-contention case.
            if let prior {
                try? setKey(repo, branch, Self.kBase, prior.base)
                if let pr = prior.prNumber { try? setKey(repo, branch, Self.kPr, String(pr)) }
                else { unset(repo, branch, Self.kPr) }
                if prior.watch { try? setKey(repo, branch, Self.kWatch, "true") }
                else { unset(repo, branch, Self.kWatch) }
                try? setKey(repo, branch, Self.kParent, prior.parent)
            } else {
                for suffix in Self.allSuffixes { unset(repo, branch, suffix) }
            }
            throw error
        }
    }

    /// Remove every `orchestra-*` lineage key for `branch` (tolerates already-unset keys).
    public func clear(repo: String, branch: String) throws {
        for suffix in Self.allSuffixes { unset(repo, branch, suffix) }
    }

    /// Update just the recorded parent-tip OID (after a sync/restack).
    public func updateBase(repo: String, branch: String, oid: String) throws {
        try setKey(repo, branch, Self.kBase, oid)
    }

    // MARK: tree queries

    /// Child branch names whose recorded parent is `parent` — a fan-out over all lineage keys.
    public func children(repo: String, of parent: String) -> [String] {
        let pattern = "^branch\\..*\\.\(Self.kParent)$"
        guard let r = try? Proc.run(["git", "-C", repo, "config", "--get-regexp", pattern]), r.ok
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
    public func ancestors(repo: String, of branch: String) -> [String] {
        var out: [String] = []
        var seen: Set<String> = [branch]
        var cur = branch
        while let link = read(repo: repo, branch: cur) {
            let p = link.parent
            if seen.contains(p) { break }   // defensive: a pre-existing cycle can't loop us forever
            out.append(p); seen.insert(p); cur = p
        }
        return out
    }
    // O4/S4: `classify` deleted — it was dead (zero production callers) and disagreed with the
    // load-bearing `RemoteParentRef.parse` (which now also consults `git remote`). Classification runs
    // through that one seam.
}
