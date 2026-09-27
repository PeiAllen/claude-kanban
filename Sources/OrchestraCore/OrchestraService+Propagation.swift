import Foundation
import OrchestraKit

/// Lifecycle wiring for the worktree propagation policy (see `docs/09`, "Worktree propagation policy").
/// `PropagationService` owns the git mechanics and the *when/whether*; this file owns the *where in the
/// lifecycle*: the launch grant, the idle-edge sync, the teardown/re-drive flush, the boot sweep, and the
/// Obsidian guard. A separate file because `OrchestraService.swift` is already over the 750-line rule.
extension OrchestraService {

    // MARK: - Sinks

    /// Install the notice and warning sinks. Called once at boot (an actor cannot capture `[weak self]`
    /// into a stored property during `init`). Until then the service runs silently — the safe default.
    public func installPropagationSinks() async {
        await propagation.setSinks(
            notify: { [weak self] card, text, dedupKey in
                guard let self else { return }
                await self.deliverPropagationNotice(card, text, dedupKey: dedupKey)
            },
            warn: { [weak self] text in
                guard let self else { return }
                _Concurrency.Task { await self.emitPropagationWarning(text) }
            })
    }

    private func deliverPropagationNotice(_ id: UUID, _ text: String, dedupKey: String) async {
        guard let card = await store.get(id), !card.archived else { return }
        _ = try? await enqueueAndArm(id, text, source: .orchestra, dedupKey: dedupKey)
    }

    private func emitPropagationWarning(_ text: String) {
        emitActivity(.warning, nil, .daemon, text)
    }

    // MARK: - Launch grant (G6: every Orchestra write into a worktree respects the ignore rules)

    /// Which of the adapter's launch writes may land in this card's checkout. Only ignored paths qualify,
    /// because an Orchestra write to an un-ignored path would dirty the project. A scratch (non-repo)
    /// checkout takes every write. An unanswerable probe grants nothing: skipping a skill is recoverable,
    /// dirtying a repo is not.
    func propagationGrant(for card: Task, adapter: any Adapter) async -> PropagationGrant {
        let cwd = card.cwd
        let candidates = adapter.launchWrites
        guard !candidates.isEmpty else { return PropagationGrant(writablePaths: []) }
        switch await IgnoreProbe.classify(candidates, inCheckout: cwd, proc: proc) {
        case .repo(let ignored):
            return PropagationGrant(writablePaths: Set(candidates).intersection(ignored))
        case .notARepo:
            return PropagationGrant(writablePaths: Set(candidates))
        case .unknown(let detail):
            emitActivity(.warning, card, .daemon, "Launch files skipped in \(cwd): could not read ignore rules (\(detail)).")
            return PropagationGrant(writablePaths: [])
        }
    }

    // MARK: - Launch receive

    /// The launch sync's own budget. The card's `.launching` deadline (`sessionLaunchTimeout`, 30s) is measured
    /// from the phase entry and this sync spends it, so an unbounded sync could kill a healthy launch with
    /// the wrong cause. The anchor must NOT be moved to give the time back: a re-step would re-stamp it
    /// every time and a card whose readiness times out would relaunch forever. So the budget is small
    /// (10s + the 15s readiness grace fits the 30s, and a cold first sync with real git needs more than 5s). The receive is an optimization the idle-edge sync
    /// repeats, so it may be abandoned.
    static let launchSyncBudget: Duration = .seconds(10)

    /// Receive the shared files before the agent starts. Returns after the sync or the budget, whichever
    /// comes first; an abandoned sync keeps running on its checkout chain.
    func receiveSharedAtLaunch(_ card: Task) async {
        let budget = Self.launchSyncBudget, clock = self.clock
        let finished = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = OnceResume(cont)
            let timer = _Concurrency.Task { try? await clock.sleep(for: budget); once.resume(false) }
            _Concurrency.Task {
                await self.syncShared(card, .receiveOnly)
                once.resume(true)
                timer.cancel()
            }
        }
        if !finished {
            emitActivity(.warning, card, .daemon,
                         "Shared files were still syncing after \(budget.components.seconds)s; launching without waiting. The next idle sync retries.")
        }
    }

    // MARK: - Idle edge

    /// Start a detached full sync after a card's agent goes idle. The sync re-checks that the card is
    /// still live at the same epoch: a teardown may have flushed and reaped the checkout in the meantime,
    /// and a sync then would re-create a git dir for a dead card. (Both serialize on the checkout chain;
    /// the boot sweep reclaims any residue.)
    func scheduleIdleSync(_ card: Task) {
        let id = card.id, epoch = card.sessionEpoch
        _Concurrency.Task { [weak self] in
            guard let self else { return }
            await self.runIdleSync(id, epoch: epoch)
        }
    }

    func runIdleSync(_ id: UUID, epoch: Int) async {
        guard let card = await store.get(id), card.phase.kind == .live, card.sessionEpoch == epoch else { return }
        await syncShared(card, .full)
    }

    // MARK: - Teardown / re-drive release

    /// Flush, release, reap — the one removal sequence for the boot re-drive (the stepper runs the same
    /// sequence through `ConvergeContext`). Returns nil when the flush refused, so nothing was released:
    /// a false flush means unsent shared edits would be deleted with the worktree.
    func _setSyncSharedObserverForTest(_ observer: (@Sendable (UUID, SyncIntent) async -> Void)?) { syncSharedObserver = observer }

    /// The one entry the lifecycle syncs through (launch receive, idle full sync).
    @discardableResult
    func syncShared(_ card: Task, _ intent: SyncIntent) async -> SyncOutcome {
        await syncSharedObserver?(card.id, intent)
        return await propagation.sync(card.cwd, card, intent)
    }

    func _setFlushSharedForTest(_ flush: (@Sendable (Task) async -> Bool)?) { flushSharedOverride = flush }

    func flushShared(_ card: Task) async -> Bool {
        if let flushSharedOverride { return await flushSharedOverride(card) }
        return await propagation.flush(card)
    }

    func releaseWorktreeFlushingShared(_ card: Task, cards: [Task]) async -> ReleaseOutcome? {
        guard await flushShared(card) else { return nil }
        let outcome = (try? await worktrees.release(cardId: card.id, cards: cards, force: false))
            ?? .removalFailed(detail: "release threw")
        if case .removed = outcome { await propagation.reap(card) }
        return outcome
    }

    // MARK: - Boot

    /// The git-version gate, then the checkout-git-dir sweep. Awaited at top level in `orchestrad` BEFORE
    /// the boot task and the tick loop are created, because both reach `finishLaunch` → `sync`.
    public func propagationBoot() async {
        _ = await propagation.checkGitVersion()
        let cards = await store.all()
        let fm = FileManager.default
        let live = cards.filter { fm.fileExists(atPath: $0.cwd) }
        // A worktree card names its repo. A borrowed card's `repo` is unvalidated and may be empty, and its cwd
        // may sit in a worktree, so its primary must be located the way `sync` locates it — otherwise a live
        // primary's git dir looks unreferenced and is swept every boot, losing its merge base.
        var primaries = Set(cards.compactMap { $0.origin == .worktree ? try? resolver.resolveRepo($0.repo) : nil })
        for card in live where card.origin == .borrowed {
            if let found = await propagation.locateBorrowed(card.cwd) { primaries.insert(found.primary) }
        }
        // Every card whose directory exists is referenced, INCLUDING an archivedComplete card that retained
        // its worktree (its `resolve` needs the git dir). An empty board is "not known", which the sweep
        // treats as path-gone only.
        await propagation.sweep(referencedCwds: Set(live.map(\.cwd)), primaries: primaries)
    }

    // MARK: - Obsidian guard (G6, third writer)

    /// Obsidian's vault script writes `.obsidian` and `.trash` into the checkout. Refuse before it runs
    /// unless the project ignores both (or the directory is not a repo).
    func guardObsidianWrites(cwd: String) async throws {
        // Probe a CHILD of each directory, not the bare name: neither directory exists yet, and git cannot
        // match a `dir/` pattern (this repo's own .gitignore) against a path it cannot see is a directory.
        let dirs = [".obsidian", ".trash"]
        let probes = dirs.map { $0 + "/.orchestra-probe" }
        switch await IgnoreProbe.classify(probes, inCheckout: cwd, proc: proc) {
        case .notARepo:
            return
        case .repo(let ignored):
            if let i = probes.firstIndex(where: { !ignored.contains($0) }) {
                throw OrchestraError.invalidParams(
                    "\(dirs[i]) is not git-ignored in \(cwd); add it to .gitignore before opening the vault")
            }
        case .unknown(let detail):
            throw OrchestraError.invalidParams("cannot verify .obsidian/.trash are git-ignored in \(cwd): \(detail)")
        }
    }
}

/// Resumes a continuation exactly once, from whichever of two racing tasks gets there first.
private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Bool, Never>?
    init(_ cont: CheckedContinuation<Bool, Never>) { self.cont = cont }
    func resume(_ value: Bool) {
        let c = lock.withLock { () -> CheckedContinuation<Bool, Never>? in defer { cont = nil }; return cont }
        c?.resume(returning: value)
    }
}
