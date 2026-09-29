import Foundation
import OrchestraKit

extension PropagationService {
    /// Moves `items` from `tracked` to `shared`: the one explicit carve-out from "the daemon never touches the
    /// project repo" — it STAGES `git rm --cached` and never commits. **Re-runnable**: steps 2–5 are
    /// idempotent, so a second run repeats only step 1, which sends the primary's newest content.
    ///
    /// 1. Sync the items in the PRIMARY's git dir (its tracked copies are sent; the write-out never touches
    ///    them, because they are not ignored there). Conflict or failure → stop, the project is untouched.
    ///    (Steps 2–3 are the one exception: a stop at step 3 leaves the appended `.gitignore` lines, which are
    ///    harmless and make the re-run's step 2 a no-op.)
    /// 2. Append a root-anchored pattern to the CALLING checkout's `.gitignore` for a path no pattern matches.
    /// 3. Re-probe by pattern (`check-ignore --no-index`). A leaf still un-matched → stop, a negation remains.
    /// 4. `git rm --cached` the leaves git tracks — as an explicit file list minus each item's exclusions, so
    ///    a declared directory never drags an excluded subtree (`.claude/skills`) out of the index.
    /// 5. Persist the items as user items with policy `shared`.
    public func adopt(items: [PropagationItem], from card: OrchestraKit.Task) async -> AdoptOutcome {
        let ctx: Context
        switch await context(for: card, checkout: card.cwd) {
        case .done(let o): return .stopped(.notParticipating(o))
        case .ctx(let c): ctx = c
        }

        // Step 1, on the primary's chain.
        let primaryPrep = await prepare(card, checkout: ctx.primary, primary: ctx.primary, extraShared: items, asPrimary: true)
        guard case .ready(let pp) = primaryPrep else {
            if case .done(let o) = primaryPrep { return .stopped(.primarySyncFailed(o)) }
            return .stopped(.primarySyncFailed(.nothingShared))
        }
        let primaryOutcome = await serialized(Self.checkoutKey(ctx.primary)) { await self.syncOne(pp, intent: .full) }
        guard case .completed(_, let sent?) = primaryOutcome, sent == .pushed || sent == .nothingToDo else {
            return .stopped(.primarySyncFailed(primaryOutcome))
        }

        // Steps 2–5, on the calling checkout's chain.
        return await serialized(Self.checkoutKey(ctx.checkout)) { await self.adoptInProject(items: items, ctx: ctx) }
    }

    private func adoptInProject(items: [PropagationItem], ctx: Context) async -> AdoptOutcome {
        let loaded = PropagationStore.load(path: policyPath)
        guard loaded.repoPolicy(for: ctx.primary) != nil else { return .stopped(.policyLoadFailed) }

        // Probe every leaf that exists. A declared path with no leaf here (a fresh worktree without CLAUDE.md)
        // is probed as itself, so its pattern is still added — the write-out only writes ignored paths.
        var leaves = Set<String>()
        var probe = Set<String>()
        for item in items {
            for p in item.paths {
                let found = Self.leaves(of: p, in: ctx.checkout, excluding: item.exclusions)
                leaves.formUnion(found)
                probe.formUnion(found.isEmpty ? [p] : found)
            }
        }
        let sorted = leaves.sorted()
        let probeList = probe.sorted()

        var matched = await IgnoreProbe.ignoredByPatterns(probeList, inCheckout: ctx.checkout, proc: proc)
        if matched.count < probeList.count {
            let unmatched = Set(probeList).subtracting(matched)
            appendIgnorePatterns(Self.patterns(for: items, unmatched: unmatched), checkout: ctx.checkout)
            matched = await IgnoreProbe.ignoredByPatterns(probeList, inCheckout: ctx.checkout, proc: proc)
            let stillOut = probeList.filter { !matched.contains($0) }
            if !stillOut.isEmpty { return .stopped(.negationRemains(paths: stillOut)) }
        }

        var untracked: [String] = []
        if !sorted.isEmpty {
            guard let ls = try? await proc.run(["git", "ls-files", "-z", "--"] + sorted, cwd: ctx.checkout,
                                               env: ["GIT_OPTIONAL_LOCKS": "0"], timeout: .seconds(20)), ls.ok
            else { return .stopped(.projectGitFailed("git ls-files failed")) }
            untracked = ls.stdout.split(separator: "\0").map(String.init)
            if !untracked.isEmpty {
                guard let rm = try? await proc.run(["git", "rm", "--cached", "-q", "--"] + untracked, cwd: ctx.checkout,
                                                   env: [:], timeout: .seconds(20)), rm.ok
                else { return .stopped(.projectGitFailed("git rm --cached failed")) }
            }
        }

        var table = loaded.table
        let key = PathResolver.canonical(ctx.primary)
        var row = table[key] ?? PropagationRepoPolicy()
        for item in items { row.userItems[item.name] = item; row.overrides[item.name] = .shared }
        table[key] = row
        guard PropagationStore.save(table, path: policyPath) else { return .stopped(.policySaveFailed) }
        return .adopted(untracked: untracked)
    }

    /// The lines to append. An item without exclusions gets one root-anchored line per declared path that has an
    /// unmatched leaf. An item WITH exclusions gets one line per unmatched leaf instead: a root line such as
    /// `/.claude` would also ignore the excluded subtrees (`.claude/skills`) that must stay tracked.
    static func patterns(for items: [PropagationItem], unmatched: Set<String>) -> [String] {
        var out: [String] = []
        for item in items {
            if item.exclusions.isEmpty {
                out += item.paths.filter { p in unmatched.contains { isUnder($0, p) } }
            } else {
                out += unmatched.filter { u in item.paths.contains { isUnder(u, $0) } }
            }
        }
        return out
    }

    /// Appends `/<path>` lines that are not already present. Never rewrites an existing line.
    private func appendIgnorePatterns(_ paths: [String], checkout: String) {
        let file = checkout + "/.gitignore"
        var text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let existing = Set(text.split(separator: "\n").map(String.init))
        let add = Array(Set(paths)).sorted().map { "/" + $0 }.filter { !existing.contains($0) }
        guard !add.isEmpty else { return }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += add.joined(separator: "\n") + "\n"
        try? text.write(toFile: file, atomically: true, encoding: .utf8)
    }
}
