import Foundation
import OrchestraKit

/// The result of one store call under the lock rule.
enum Guarded<T: Sendable>: Sendable {
    case value(T)
    /// A live process holds a git lock, or the lock probe could not prove nobody does.
    case busy
    case failed(String)
}

extension PropagationService {
    // MARK: - Lock rule

    /// The lock file path out of git's "Unable to create '<path>.lock': File exists" — real git words it
    /// the same for index and ref locks. A contract test pins this against real git output.
    static func lockPath(fromStderr stderr: String) -> String? {
        guard let a = stderr.range(of: "Unable to create '"),
              let b = stderr.range(of: "': File exists", range: a.upperBound..<stderr.endIndex) else { return nil }
        return String(stderr[a.upperBound..<b.lowerBound])
    }

    /// Only a `.lock` file inside the store root may ever be removed.
    func isRemovableLock(_ path: String) -> Bool {
        let real = PathResolver.canonical(path)
        return real.hasPrefix(PathResolver.canonical(root) + "/") && real.hasSuffix(".lock")
    }

    /// Runs one whole store method. On a lock failure: a holder (or an unproven one) is `.busy`; no holder
    /// means a crash left the file, so remove it once, warn, and re-run the WHOLE method once. Re-running is
    /// safe because every store method is re-runnable (files first, HEAD last).
    func guarded<T: Sendable>(_ op: @Sendable () async throws -> T) async -> Guarded<T> {
        var retried = false
        while true {
            do { return .value(try await op()) } catch {
                guard case SharedStoreError.gitFailed(_, _, let stderr) = error, let lock = Self.lockPath(fromStderr: stderr)
                else { return .failed("\(error)") }
                guard !retried, let holders = await LockProbe.holders(lock, proc: proc), holders.isEmpty,
                      isRemovableLock(lock) else { return .busy }
                retried = true
                try? FileManager.default.removeItem(atPath: lock)
                warn("Removed a stale git lock left by a crash: \(lock)")
            }
        }
    }

    /// A store call that may write `store.git`, under the repo's store chain.
    func underStore<T: Sendable>(_ p: Prepared, _ op: @escaping @Sendable () async throws -> T) async -> Guarded<T> {
        await serialized(Self.storeKey(p.primary)) { await self.guarded(op) }
    }

    // MARK: - sync

    public func sync(_ checkout: String, _ card: OrchestraKit.Task, _ intent: SyncIntent) async -> SyncOutcome {
        // A checkout that is gone has nothing to share, and a sync would re-create its git dir (a late idle
        // sync racing a teardown that already released and reaped it). `flush` has the same guard.
        guard FileManager.default.fileExists(atPath: checkout) else { return .skipped(.notARepo) }
        let ctx: Context
        switch await context(for: card, checkout: checkout) {
        case .done(let outcome): return outcome
        case .ctx(let c): ctx = c
        }
        // Step 6: every primary git call precedes the card's own, so a fresh card never receives a stale copy.
        if intent == .receiveOnly, ctx.checkout != ctx.primary {
            if case .ready(let primaryPrep) = await prepare(card, checkout: ctx.primary, primary: ctx.primary, asPrimary: true) {
                _ = await serialized(Self.checkoutKey(ctx.primary)) { await self.syncOne(primaryPrep, intent: .full) }
            }
        }
        let prep: Prepared
        switch await prepare(card, checkout: ctx.checkout, primary: ctx.primary) {
        case .done(let outcome): return outcome
        case .ready(let p): prep = p
        }
        return await serialized(Self.checkoutKey(ctx.checkout)) { await self.syncOne(prep, intent: intent) }
    }

    /// attach → commitLocal → receive → (send). Takes no checkout key: callers hold it.
    func syncOne(_ p: Prepared, intent: SyncIntent) async -> SyncOutcome {
        if FileManager.default.fileExists(atPath: p.dirs.checkout + "/MERGE_HEAD") {
            warnOnce(p.checkout, epoch: p.epoch, "mergeHead",
                     "Shared files paused for \(p.checkout): a git merge is in progress in \(p.dirs.checkout).")
            return .standDown(.mergeInProgress)
        }
        let store = self.store
        let warnSink = self.warnSink

        let handle: StoreHandle
        switch await underStore(p, { try await store.attach(
            checkout: p.checkout, repo: p.primary, declared: p.declared,
            noteNovel: { warnSink?("Shared files: \($0) has local content the store lacks; it is committed on top.") }) }) {
        case .value(let h): handle = h
        case .busy: return .busy
        case .failed(let m): return failed(p, m)
        }

        var oversized: [String] = []
        switch await guarded({ try await store.commitLocal(handle, declared: p.declared, unignoredLeaves: p.unignoredLeaves) }) {
        case .busy: return .busy
        case .failed(let m): return failed(p, m)
        case .value(let outcome):
            let warnings: [CommitWarning]
            switch outcome {
            case .committed(_, let w), .nothingToCommit(let w): warnings = w
            }
            for w in warnings {
                warn(Self.text(for: w))
                if case .oversized(let path) = w { oversized.append(path) }
            }
        }

        let received: ReceiveOutcome
        switch await guarded({ try await store.receive(handle, paths: p.sharedPaths, declared: p.declared) }) {
        case .busy: return .busy
        case .failed(let m): return failed(p, m)
        case .value(let r): received = r
        }
        switch received {
        case .conflicted(let paths, let sha):
            await recordConflict(p, paths: paths, sha: sha, intent: intent)
            return .conflicted(paths: paths, storeSha: sha)
        case .partial(let dirty):
            warn(Self.partialText(dirty))
            return .partial(dirty: dirty)
        case .upToDate, .materialized:
            break
        }

        guard intent != .receiveOnly, !p.readOnly else {
            lastConflict[p.checkout] = nil
            return .completed(receive: received, send: nil)
        }
        switch await underStore(p, { try await store.send(handle, paths: p.sharedPaths, declared: p.declared) }) {
        case .busy: return .busy
        case .failed(let m): return failed(p, m)
        case .value(let sent):
            switch sent {
            case .pushed, .nothingToDo:
                lastConflict[p.checkout] = nil
                // An over-5-MiB edit was left out of the commit, so `nothingToDo` does not mean it is safe.
                if intent == .flush, !oversized.isEmpty { return .unsent(paths: oversized.sorted()) }
                return .completed(receive: received, send: sent)
            case .conflicted(let paths, let sha):
                await recordConflict(p, paths: paths, sha: sha, intent: intent)
                return .conflicted(paths: paths, storeSha: sha)
            case .partial(let dirty):
                warn(Self.partialText(dirty))
                return .partial(dirty: dirty)
            case .refusedOutOfSet(let paths):
                warn("Shared files: nothing was sent, because these paths lie outside the shared set: \(paths.joined(separator: ", ")).")
                return .refusedOutOfSet(paths: paths)
            }
        }
    }

    // MARK: - Notices

    /// A store failure is never silent: propagation is dead for this checkout until someone acts. One warning
    /// per checkout, launch and failure text.
    func failed(_ p: Prepared, _ message: String) -> SyncOutcome {
        warnOnce(p.checkout, epoch: p.epoch, "failed:\(message.prefix(120))",
                 "Shared files sync failed for \(p.checkout): \(message)")
        return .failed(message)
    }

    /// One notice per distinct (paths, store sha). `Inbox.enqueue` suppresses a duplicate only until the
    /// first copy is handed off, so its `dedupKey` alone would re-notify every idle turn. A teardown flush
    /// cannot use the inbox (the session is dead), so it warns every time.
    func recordConflict(_ p: Prepared, paths: [String], sha: String, intent: SyncIntent) async {
        let record = ConflictRecord(paths: paths.sorted(), storeSha: sha)
        let text = "Shared files conflict: \(record.paths.joined(separator: ", ")). Your files are unchanged. "
            + "To see the store's version, run `GIT_OPTIONAL_LOCKS=0 git --git-dir=\(p.dirs.checkout) show store/main:\(record.paths.first ?? "<path>")`. "
            + "Edit your file to the reconciled content, then run `orchestra shared resolve`."
        if intent == .flush { warn(text); lastConflict[p.checkout] = record; return }
        guard lastConflict[p.checkout] != record else { return }
        lastConflict[p.checkout] = record
        await notify(p.cardId, text, dedupKey: "shared-conflict:\(sha)")
    }

    static func partialText(_ dirty: [String]) -> String {
        "Shared files: \(dirty.joined(separator: ", ")) changed here and in the store. Sync is paused until that file is committed or removed."
    }

    static func text(for w: CommitWarning) -> String {
        switch w {
        case .strayUnstaged(let paths): return "Shared files: left out of the store (not declared): \(paths.joined(separator: ", "))."
        case .oversized(let path): return "Shared files: \(path) is over 5 MiB and is not shared."
        case .gitlink(let path): return "Shared files: \(path) is a nested git repo and is not shared."
        }
    }

    // MARK: - flush / reap

    /// Before a worktree is released. True when nothing can be lost: the cwd is gone (no git call), the card
    /// is ineligible or has nothing shared, propagation is disabled, or the send landed.
    public func flush(_ card: OrchestraKit.Task) async -> Bool {
        guard FileManager.default.fileExists(atPath: card.cwd) else { return true }
        switch await sync(card.cwd, card, .flush) {
        case .skipped, .nothingShared, .standDown(.gitTooOld):
            return true
        case .completed(_, let send):
            guard let send else { return true }
            return send == .pushed || send == .nothingToDo
        case .standDown, .busy, .conflicted, .partial, .refusedOutOfSet, .unsent, .failed:
            return false
        }
    }

    /// After a release returned `.removed`: delete the checkout's git dir once its chain drains. Found by
    /// scanning for the checkout's hash, so it works with the worktree gone and needs no repo resolution.
    /// A borrowed card is never reaped (see below).
    public func reap(_ card: OrchestraKit.Task) async {
        // A borrowed card's git dir is keyed by its work tree's toplevel (which other cards may share), and
        // releasing a borrowed card removes no worktree. Only the sweep reclaims it.
        guard card.origin != .borrowed else { return }
        let checkout = PathResolver.canonical(card.cwd)
        let hash = CardFileSpec.cwdHash(checkout)
        let root = self.root
        _ = await serialized(Self.checkoutKey(checkout)) { Self.removeGitDirs(root: root, matching: { $0 == hash }) }
        lastConflict[checkout] = nil
        onceFlags[checkout] = nil
    }

    static func removeGitDirs(root: String, matching hashMatches: (String) -> Bool) -> [String] {
        let fm = FileManager.default
        var removed: [String] = []
        for repo in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let dir = "\(root)/\(repo)/checkouts"
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".git") {
                guard hashMatches(String(name.dropLast(4))) else { continue }
                if (try? fm.removeItem(atPath: "\(dir)/\(name)")) != nil { removed.append("\(dir)/\(name)") }
            }
        }
        return removed
    }

    // MARK: - resolve / status / locate

    private func preparedForEntry(_ card: OrchestraKit.Task) async throws -> Prepared {
        let ctx: Context
        switch await context(for: card, checkout: card.cwd) {
        case .done(let o): throw PropagationServiceError.notParticipating(o)
        case .ctx(let c): ctx = c
        }
        switch await prepare(card, checkout: ctx.checkout, primary: ctx.primary) {
        case .done(let o): throw PropagationServiceError.notParticipating(o)
        case .ready(let p): return p
        }
    }

    /// The one write path for a conflict, on the same chain as a sync.
    public func resolve(_ card: OrchestraKit.Task) async throws -> ResolveOutcome {
        let p = try await preparedForEntry(card)
        let result: Guarded<ResolveOutcome> = await serialized(Self.checkoutKey(p.checkout)) { await self.resolveLocked(p) }
        switch result {
        case .value(let outcome): return outcome
        case .busy: throw PropagationServiceError.storeFailed("a git lock is held")
        case .failed(let m): throw PropagationServiceError.storeFailed(m)
        }
    }

    private func resolveLocked(_ p: Prepared) async -> Guarded<ResolveOutcome> {
        if FileManager.default.fileExists(atPath: p.dirs.checkout + "/MERGE_HEAD") {
            return .failed("a git merge is in progress in \(p.dirs.checkout)")
        }
        let store = self.store
        let handle: StoreHandle
        switch await underStore(p, { try await store.attach(checkout: p.checkout, repo: p.primary, declared: p.declared, noteNovel: nil) }) {
        case .value(let h): handle = h
        case .busy: return .busy
        case .failed(let m): return .failed(m)
        }
        let result = await underStore(p, { try await store.resolve(handle, paths: p.sharedPaths, declared: p.declared) })
        if case .value(.resolved) = result { lastConflict[p.checkout] = nil }
        return result
    }

    /// Read-only: items, policies, un-ignored leaves, the standing conflict, and the store read command.
    /// Never attaches, so it never writes.
    public func status(_ card: OrchestraKit.Task) async throws -> PropagationStatus {
        let ctx: Context
        switch await context(for: card, checkout: card.cwd) {
        case .done(let o): throw PropagationServiceError.notParticipating(o)
        case .ctx(let c): ctx = c
        }
        let prep = await serialized(Self.checkoutKey(ctx.checkout)) { await self.prepare(card, checkout: ctx.checkout, primary: ctx.primary) }
        let p: Prepared
        switch prep {
        case .done(let o): throw PropagationServiceError.notParticipating(o)
        case .ready(let ready): p = ready
        }
        let exists = FileManager.default.fileExists(atPath: p.dirs.checkout + "/HEAD")
        return PropagationStatus(
            repo: p.primary,
            items: p.items.map { ItemStatus(name: $0.item.name, policy: $0.policy, paths: $0.item.paths) },
            unignoredLeaves: p.unignoredLeaves.sorted(),
            conflict: lastConflict[p.checkout],
            readCommand: exists ? "GIT_OPTIONAL_LOCKS=0 git --git-dir=\(p.dirs.checkout)" : nil)
    }

    /// Attaches if needed and returns where this checkout's git dir lives.
    public func locate(_ card: OrchestraKit.Task) async throws -> StoreLocation {
        let p = try await preparedForEntry(card)
        let store = self.store
        let result: Guarded<StoreHandle> = await serialized(Self.checkoutKey(p.checkout)) {
            await self.underStore(p, { try await store.attach(checkout: p.checkout, repo: p.primary, declared: p.declared, noteNovel: nil) })
        }
        switch result {
        case .value(let h): return StoreLocation(storeGitDir: h.storeGitDir, checkoutGitDir: h.checkoutGitDir, workTree: h.workTree)
        case .busy: throw PropagationServiceError.storeFailed("a git lock is held")
        case .failed(let m): throw PropagationServiceError.storeFailed(m)
        }
    }

    // MARK: - Boot sweep

    /// Deletes each `checkouts/*.git` whose recorded path is gone, or — only when the caller supplies a
    /// non-empty referenced set — is neither a primary nor a referenced cwd. An empty set is "the card
    /// set is not known yet", so only the path-is-gone arm runs. `referencedCwds` must hold EVERY card whose
    /// worktree still exists, INCLUDING an `.archivedComplete` card that retained its worktree: its
    /// `resolve` path needs the git dir. Both sides are canonicalized (`/tmp` vs `/private/tmp`).
    /// A git dir with no readable `orchestra-checkout` record is left alone. PR6 runs this at boot.
    ///
    /// Three more guards keep a sweep from deleting a live checkout's history:
    /// - `startedAt`: a git dir created at or after it belongs to a card that attached after the caller took its
    ///   card snapshot (the boot wait can time out and let the sweep run on while the daemon serves). Skipped.
    /// - A recorded path whose `.git` is a DIRECTORY is a primary repo root, not a card worktree. Its git dir holds
    ///   the merge base for the next launch, so it is never swept, even when no card names the repo right now.
    /// - The caller passes an empty `referencedCwds` when the board loaded incompletely (a dropped record hides a
    ///   live card), which leaves only the path-gone arm.
    @discardableResult
    public func sweep(referencedCwds: Set<String>, primaries: Set<String>, startedAt: Date = .distantFuture) async -> [String] {
        let fm = FileManager.default
        let keep = Set(referencedCwds.map(PathResolver.canonical)).union(primaries.map(PathResolver.canonical))
        var removed: [String] = []
        for repo in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let dir = "\(root)/\(repo)/checkouts"
            for name in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where name.hasSuffix(".git") {
                let gitDir = "\(dir)/\(name)"
                guard let raw = try? String(contentsOfFile: gitDir + "/orchestra-checkout", encoding: .utf8) else { continue }
                let path = PathResolver.canonical(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                if let created = (try? fm.attributesOfItem(atPath: gitDir))?[.creationDate] as? Date, created >= startedAt { continue }
                let gone = !fm.fileExists(atPath: path)
                var isDir: ObjCBool = false
                if !gone, fm.fileExists(atPath: path + "/.git", isDirectory: &isDir), isDir.boolValue { continue }
                // A referenced cwd anywhere under the recorded checkout keeps it: a borrowed card's cwd may be a
                // subdirectory of the work tree its git dir is keyed by.
                let referenced = keep.contains { Self.isUnder($0, path) }
                guard gone || (!referencedCwds.isEmpty && !referenced) else { continue }
                let hash = String(name.dropLast(4))
                let root = self.root
                let dropped = await serialized(Self.checkoutKey(path)) { Self.removeGitDirs(root: root, matching: { $0 == hash }) }
                removed += dropped
                lastConflict[path] = nil
                onceFlags[path] = nil
            }
        }
        return removed
    }
}
