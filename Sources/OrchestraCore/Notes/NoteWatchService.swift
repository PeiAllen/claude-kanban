import Foundation

/// A late-bound sink for note changes.
///
/// `OrchestraService` builds its `NoteWatchService` as a stored property, so the emit closure cannot
/// capture `self` — `self` is not usable until every stored property is initialized. The service
/// constructs this box first, hands it to the watcher, then wires the real sink once initialization
/// completes. Emitting before the sink is set is a silent no-op, which is correct: nothing can be
/// watching yet.
final class NoteEmitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (NoteChange) -> Void)?
    func set(_ s: @escaping @Sendable (NoteChange) -> Void) { lock.withLock { sink = s } }
    func emit(_ change: NoteChange) { (lock.withLock { sink })?(change) }
}

/// Daemon-owned note watching: ONE stream per live worktree card, watching that card's tree.
///
/// The daemon holds these because IT wants them, not because a client asked. That is the whole reason
/// this type has no subscribers, no refcounts, and no connection identity — there is nothing registered,
/// so there is nothing to leak, race, or replay. It is the same shape as `shellsChanged`, which the
/// daemon derives from tmux and broadcasts without anyone subscribing to a particular card.
///
/// An earlier design registered a watch per client, per open view. That obliged connection identity
/// surviving fd reuse, teardown on both death paths, a register/teardown race rollback, reconnect
/// replay, and refcounting — six mechanisms and two RPCs, all of them tax on a subscription rather than
/// the feature. Deleting the registration deleted all of it.
///
/// A change emits only when the content HASH moves — the same "never broadcast an unchanged value" rule
/// the report pipeline follows — so a touch, or a rewrite with identical bytes, wakes nobody.
actor NoteWatchService {
    private struct Stream { let token: FileWatchToken; let worktree: String }

    private let watcher: any FileWatching
    private let hash: @Sendable (String) -> String?
    private let emit: @Sendable (NoteChange) -> Void

    private var streams: [UUID: Stream] = [:]          // cardId -> its worktree watch
    private var lastHash: [String: String?] = [:]      // canonical abs path -> last seen digest

    init(watcher: any FileWatching,
         hash: @escaping @Sendable (String) -> String?,
         emit: @escaping @Sendable (NoteChange) -> Void) {
        self.watcher = watcher; self.hash = hash; self.emit = emit
    }

    var activeStreamCount: Int { streams.count }

    /// Reconcile the watched set against the live worktree cards.
    ///
    /// A DIFF, not a command: start what is missing, cancel what is gone, leave the rest alone.
    /// Idempotent, so extra calls cost nothing and a missed call is repaired by the next one — which is
    /// precisely why this design needs no teardown protocol, no rollback, and no race handling.
    func sync(cards: [(id: UUID, worktree: String)]) {
        let desired = Dictionary(cards.map { ($0.id, $0.worktree) }, uniquingKeysWith: { a, _ in a })

        // Cancel streams for cards that are gone, or whose worktree moved.
        for (id, s) in streams where desired[id] != s.worktree {
            s.token.cancel()
            streams[id] = nil
            let root = PathResolver.canonical(s.worktree)
            lastHash = lastHash.filter { !$0.key.hasPrefix(root + "/") }
        }

        // Start streams for cards that need one.
        for (id, worktree) in desired where streams[id] == nil {
            // Canonicalize the root ONCE. FSEvents reports realpath-resolved paths, so comparing them
            // against a non-canonical root would silently never match — live refresh would do nothing,
            // with no error and no failing test. (`/tmp` -> `/private/tmp` is the classic case, and
            // this project has already been bitten by that exact mismatch in Codex trust-path lookup.)
            let root = PathResolver.canonical(worktree)
            let token = watcher.watch(directory: root) { [weak self] event in
                guard let self else { return }
                // CHEAPEST GATE FIRST. A worktree root is watched recursively, so a build floods this
                // with .git / .build / node_modules churn. A suffix check costs nothing; hashing does
                // not, so nothing but markdown ever reaches the file read.
                let md = event.paths.filter { $0.lowercased().hasSuffix(".md") }
                guard !md.isEmpty || event.needsRescan else { return }
                let changed = Set(md.map { PathResolver.canonical($0) })
                _Concurrency.Task {
                    await self.observe(cardId: id, root: root,
                                       changed: changed, rescan: event.needsRescan)
                }
            }
            streams[id] = Stream(token: token, worktree: worktree)
        }
    }

    /// The actor-side step. Hashing is blocking file I/O, so it runs only for the handful of markdown
    /// paths that survived the suffix gate — never for a raw event batch.
    ///
    /// On overflow the reported paths are INCOMPLETE (the batch can name only `/`), so every path this
    /// service already knows about under the tree is re-checked instead of trusting `changed`.
    private func observe(cardId: UUID, root: String, changed: Set<String>, rescan: Bool) {
        let prefix = root + "/"
        let targets: Set<String> = rescan
            ? Set(lastHash.keys.filter { $0.hasPrefix(prefix) }).union(changed)
            : changed
        for abs in targets.sorted() {
            guard abs.hasPrefix(prefix) else { continue }     // never leave the card's own tree
            let now = hash(abs)
            // `lastHash[abs]` is a double optional: `.none` = never seen, `.some(nil)` = known absent.
            if let seen = lastHash[abs], seen == now { continue }   // suppress unchanged
            lastHash[abs] = now
            // `nil` means the file is GONE. That is reportable: suppressing it would leave the reader
            // displaying a note that no longer exists.
            emit(NoteChange(cardId: cardId, path: String(abs.dropFirst(prefix.count)),
                            contentHash: now))
        }
    }
}
