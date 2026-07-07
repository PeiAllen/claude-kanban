import Foundation

/// Code review on the board (axis 7): the card footer diffstat + the inspector's rendered diff. All
/// read-only. Everything guards on `Task.origin` — a non-`.worktree` card (`.scratch`/`.borrowed`,
/// possibly no git baseline) has no diff. See `notes/designs/code-review-on-board`.
extension OrchestraService {

    /// Max bytes of rendered diff handed to the app; a bigger diff is truncated with a sentinel line
    /// pointing at "open in Zed" for the full thing, so the inspector stays responsive.
    static let diffTextCap = 256 * 1024

    /// The card's rendered git patch for `base`. Non-`.worktree` cards return `""`. Errors:
    /// unknown card → `unknownTask`.
    public func diffText(_ id: UUID, base: DiffBase = .branch) async throws -> String {
        let t = try await require(id)
        guard t.origin == .worktree else { return "" }
        try resolver.assertAllowed(t.cwd)
        let text = (try? GitDiffProvider().render(worktree: t.cwd, base: base,
                                                  parentBranch: resolvedParentRef(t))) ?? ""
        if text.utf8.count > Self.diffTextCap {
            return String(text.prefix(Self.diffTextCap))
                + "\n… (diff truncated — open in Zed for the full changes)\n"
        }
        return text
    }

    /// Recompute the card's footer `DiffStat`; persist + emit **only when it changed** (idempotent, so
    /// it's safe to call freely from the report funnel). Best-effort — swallows git/lookup failures.
    /// Non-`.worktree` cards resolve to `nil`. Returns the current stat.
    @discardableResult
    public func recomputeDiffStat(_ id: UUID, base: DiffBase? = nil) async -> DiffStat? {
        guard let t = await store.get(id) else { return nil }
        let ref = resolvedParentRef(t)
        // The report-funnel path passes no base: a stacked card baselines against its parent (the card's
        // own work), everyone else against the default branch — byte-identical to before for nil-parent.
        // An explicit base (the on-selection endpoint) is honored verbatim.
        let effective = base ?? (ref != nil ? .parent : .branch)
        var newStat: DiffStat? = nil
        if t.origin == .worktree {
            do {
                try resolver.assertAllowed(t.cwd)
                newStat = try GitDiffProvider().stat(worktree: t.cwd, base: effective, parentBranch: ref)
            } catch {
                newStat = nil
            }
        }
        guard newStat != t.diffStat else { return newStat }   // no delta → no persist, no emit
        guard let saved = try? await store.update(id, { $0.diffStat = newStat }) else { return newStat }
        emit(.taskUpserted(saved))
        return newStat
    }

    /// Recompute + return the stat (the `diffStat` endpoint / on-selection path). Unknown card → throws.
    public func diffStat(_ id: UUID, base: DiffBase = .branch) async throws -> DiffStat? {
        _ = try await require(id)
        return await recomputeDiffStat(id, base: base)
    }

    /// Coalescing per-card trigger. Debounces an activity burst into a single recompute — a one-shot,
    /// **not** a periodic timer. Called from the normalized `report()` funnel (adapter-agnostic: it
    /// sees only that the card had activity, never which tool ran).
    func scheduleDiffStat(_ id: UUID) {
        diffStatDebounce[id]?.cancel()
        diffStatDebounce[id] = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: .milliseconds(750))
            if _Concurrency.Task.isCancelled { return }
            await self?.recomputeDiffStat(id)
            await self?.clearDiffStatDebounce(id)
        }
    }

    private func clearDiffStatDebounce(_ id: UUID) { diffStatDebounce[id] = nil }
}
