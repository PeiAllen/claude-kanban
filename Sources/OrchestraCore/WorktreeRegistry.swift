import Foundation
import OrchestraKit

/// repo + branch -> git worktree (ensure / path / remove) via `git`. Every path passes
/// `PathResolver.assertAllowed`. Archive removes the worktree dir but keeps the branch.
/// `fileprivate` to this file — `WorktreeRegistry` is the only public surface; every teardown/adopt
/// path routes through the registry's `ensure`/`release`/`ensureBorrow`/`releaseBorrow` so the single
/// removal policy (`release`) can never be bypassed by a caller reaching for the raw manager.
fileprivate struct WorktreeManager: Sendable {
    let config: Config
    let resolver: PathResolver
    /// Runs git via `Proc.run` by default; injectable so tests can assert the timeout argument
    /// deterministically. `timeout` is a REQUIRED `Duration` — there is no legitimate unbounded git
    /// op in this file, so an unbounded call is a compile error. WorktreeManager never needs cwd/env
    /// (all git ops use `-C`).
    let run: @Sendable (_ argv: [String], _ timeout: Duration) throws -> ProcResult

    init(config: Config, resolver: PathResolver? = nil) {
        self.init(config: config, resolver: resolver, run: { try Proc.run($0, timeout: $1) })
    }

    init(config: Config, resolver: PathResolver?,
         run: @escaping @Sendable (_ argv: [String], _ timeout: Duration) throws -> ProcResult) {
        self.config = config
        self.resolver = resolver ?? PathResolver(config: config)
        self.run = run
    }

    /// Pure: the computed worktree path for a repo + branch (powers the Spawn sheet field).
    func path(repo: String, branch: String) -> String {
        config.worktreePath(repo: repo, branch: branch)
    }

    /// Ensure a worktree exists for repo + branch. Idempotent. Returns (worktree, created, branchExisted).
    /// `base` (BT2) is the start-point for a NEWLY-created branch only — an existing branch ignores it.
    /// An unknown `base` throws `.invalidParams` *before* any worktree is cut (no half-created dir).
    @discardableResult
    func ensure(repo: String, branch: String, base: String? = nil)
        throws -> (worktree: String, created: Bool, branchExisted: Bool) {
        let realRepo = try resolver.resolveRepo(repo)
        let wt = path(repo: realRepo, branch: branch)
        try resolver.assertAllowed(wt)

        if FileManager.default.fileExists(atPath: wt) {
            return (wt, false, true)   // a live worktree implies the branch already exists
        }
        try FileManager.default.createDirectory(
            atPath: (wt as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        // Does the branch already exist?
        let exists = branchExists(repo: realRepo, branch: branch)
        let argv: [String]
        if exists {
            argv = ["git", "-C", realRepo, "worktree", "add", wt, branch]   // existing branch ignores `base`
        } else {
            var a = ["git", "-C", realRepo, "worktree", "add", "-b", branch, wt]
            if let base = base?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
                // Validate the start-point BEFORE `worktree add`, so an unknown base leaves no dir.
                if base.hasPrefix("refs/") {
                    // A fully-qualified ref (a fetched remote private ref, refs/orch/parents/…, BT6).
                    // Use it verbatim as the start-point — no refs/heads/ pinning.
                    guard refExists(repo: realRepo, ref: base) else {
                        throw OrchestraError.invalidParams(
                            "base ref not found: \(base) — fetch or create it first")
                    }
                    a.append(base)
                } else {
                    // Local branch base (BT2). Pin to the LOCAL branch ref: a bare `base` would
                    // disambiguate to a same-named tag (git's rev precedence), starting the child off the
                    // wrong commit — or failing outright on an ambiguous ref.
                    guard branchExists(repo: realRepo, branch: base) else {
                        throw OrchestraError.invalidParams(
                            "base branch not found: \(base) — run `git branch` to see valid bases")
                    }
                    a.append("refs/heads/\(base)")
                }
            }
            argv = a
        }
        let r = try run(argv, .seconds(config.worktreeAddTimeout))
        if !r.ok {
            let msg = r.stderr.lowercased()
            if msg.contains("already checked out") || msg.contains("is already used by worktree") {
                throw OrchestraError.branchInUse(branch)
            }
            throw OrchestraError.gitIO("could not create worktree for \(branch)", stderr: r.stderr)
        }
        return (wt, true, exists)
    }

    // MARK: - bare-parent borrow (O3)

    /// The canonical throwaway-worktree path for borrowing `branch` (a bare parent to squash-merge a
    /// child into). Distinct from a normal card worktree (`orch-borrow-` prefix under the repo's
    /// worktree dir) so it never collides with a future spawn onto the parent, and so the orphan sweep
    /// can recognise it by name.
    func borrowPath(repo: String, branch: String) -> String {
        let realRepo = (try? resolver.resolveRepo(repo)) ?? repo
        let repoName = (realRepo as NSString).lastPathComponent
        let safe = branch.replacingOccurrences(of: "/", with: "-")
        return "\(config.worktreesRoot)/\(repoName)/orch-borrow-\(safe)"
    }

    /// Create (or reuse) a throwaway worktree checking out the EXISTING `branch` at its canonical borrow
    /// path — the agent then squash-merges into it and commits (the daemon never commits). Idempotent.
    @discardableResult
    func borrow(repo: String, branch: String) throws -> String {
        let realRepo = try resolver.resolveRepo(repo)
        let wt = borrowPath(repo: realRepo, branch: branch)
        try resolver.assertAllowed(wt)
        if FileManager.default.fileExists(atPath: wt) { return wt }
        guard branchExists(repo: realRepo, branch: branch) else {
            throw OrchestraError.invalidParams("cannot borrow: branch not found: \(branch)")
        }
        try FileManager.default.createDirectory(
            atPath: (wt as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let r = try run(["git", "-C", realRepo, "worktree", "add", wt, branch], .seconds(config.worktreeAddTimeout))
        if !r.ok {
            let msg = r.stderr.lowercased()
            if msg.contains("already checked out") || msg.contains("is already used by worktree") {
                // The branch is checked out elsewhere. If that "elsewhere" is a canonical `orch-borrow-*`
                // worktree, a sibling is mid-landing — surface the actionable wait-and-retry guidance
                // rather than a bare branchInUse. Any other checkout keeps the plain wording.
                if msg.contains("orch-borrow-") {
                    throw OrchestraError.parentAlreadyBorrowed(branch)
                }
                throw OrchestraError.branchInUse(branch)
            }
            throw OrchestraError.io(r.stderr.isEmpty ? "git worktree add (borrow) failed" : r.stderr)
        }
        return wt
    }

    /// Remove a worktree directory (keeps the branch). Guards a dirty tree unless `force`.
    func remove(worktree: String, force: Bool = false) throws {
        try resolver.assertAllowed(worktree)
        guard FileManager.default.fileExists(atPath: worktree) else { return }
        if !force && isDirty(worktree: worktree) {
            throw OrchestraError.worktreeDirty(worktree)
        }
        var argv = ["git", "-C", worktree, "worktree", "remove"]
        if force { argv.append("--force") }
        argv.append(worktree)
        let r = try run(argv, .seconds(config.controlTimeout))
        if !r.ok {
            // Fall back to pruning from the parent repo when the dir is already gone/detached.
            _ = try? run(["git", "-C", worktree, "worktree", "prune"], .seconds(config.controlTimeout))
            if FileManager.default.fileExists(atPath: worktree) {
                throw OrchestraError.io(r.stderr.isEmpty ? "git worktree remove failed" : r.stderr)
            }
        }
    }

    func branchExists(repo: String, branch: String) -> Bool {
        let r = try? run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], .seconds(config.controlTimeout))
        return r?.ok ?? false
    }

    /// Does a fully-qualified ref resolve? (Used for a remote private-ref start-point, refs/orch/parents/…)
    func refExists(repo: String, ref: String) -> Bool {
        let r = try? run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", ref], .seconds(config.controlTimeout))
        return r?.ok ?? false
    }

    /// True if the worktree has uncommitted changes. **Fails safe:** if git can't be queried we treat
    /// the tree as dirty so `remove` (without `force`) never deletes work it couldn't verify is clean.
    func isDirty(worktree: String) -> Bool {
        guard let r = try? run(["git", "-C", worktree, "status", "--porcelain"], .seconds(config.controlTimeout)), r.ok else {
            return true
        }
        return !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// List (no removal) canonical `orch-borrow-*` worktree dir paths currently present under `repo`.
    /// `WorktreeRegistry`'s orphan sweep uses this to reclaim stray/crashed borrow dirs it doesn't have
    /// a persisted registration for.
    func orphanBorrowPaths(repo: String) -> [String] {
        guard let realRepo = try? resolver.resolveRepo(repo),
              let r = try? run(["git", "-C", realRepo, "worktree", "list", "--porcelain"],
                               .seconds(config.controlTimeout)), r.ok else { return [] }
        var out: [String] = []
        for line in r.stdout.split(separator: "\n") where line.hasPrefix("worktree ") {
            let p = String(line.dropFirst("worktree ".count)).trimmingCharacters(in: .whitespaces)
            if (p as NSString).lastPathComponent.hasPrefix("orch-borrow-") { out.append(p) }
        }
        return out
    }
}

extension WorktreeManager: WorktreeManaging {}

public actor WorktreeRegistry {
    private let config: Config
    private let resolver: PathResolver
    private let manager: any WorktreeManaging
    private let borrowsPath: String
    private let markersDir: String

    /// borrower cardId -> canonical borrow path. Persisted (survives a daemon-only crash).
    private var borrows: [UUID: String] = [:]
    private var borrowsLoaded = false

    /// canonical worktree path -> cardIds that called `ensure` for it and have not yet `release`d.
    /// Closes the concurrent-spawn rollback race: spawn A creates a tree, spawn B for the same branch
    /// interleaves at the service actor's `await registry.ensure` suspension and ADOPTS A's tree, but B
    /// is not yet in the store; if A then fails lineage recording, A's rollback `release` would (from a
    /// store-only sibling scan) see no sibling and remove the tree out from under the in-flight B. An
    /// in-flight holder IS a reference — `release` keeps a tree any OTHER in-flight holder still holds.
    /// Cleaned on the normal paths (rollback now / archive later each call `release`, whose `defer` drops
    /// the id). Residual: if `store.create` — or anything between `ensure` success and persistence —
    /// throws, the card is never persisted and never `release`d, so its entry lingers until restart and
    /// pins the tree from removal. That is fail-safe (keeps a tree, never data loss) and restart-healed
    /// (in-memory ⇒ a fresh daemon recomputes references from `store.all()`); it matches the pre-existing
    /// "a store.create failure strands the worktree" tradeoff. NOT a data-loss path.
    private var inflight: [String: Set<UUID>] = [:]

    public init(config: Config, resolver: PathResolver? = nil,
                manager: (any WorktreeManaging)? = nil,
                borrowsPath: String = Config.borrowsPath,
                markersDir: String = Config.worktreeMarkersDir) {
        self.config = config
        self.resolver = resolver ?? PathResolver(config: config)
        self.manager = manager ?? WorktreeManager(config: config, resolver: resolver)
        self.borrowsPath = borrowsPath
        self.markersDir = markersDir
    }

    /// Test seam: inject the timed `run` closure into the (fileprivate) manager. Lets `WorktreeTests`'
    /// bounded-git assertions survive privatization without exposing `WorktreeManager`.
    internal init(config: Config, resolver: PathResolver? = nil,
                  run: @escaping @Sendable (_ argv: [String], _ timeout: Duration) throws -> ProcResult,
                  borrowsPath: String = Config.borrowsPath, markersDir: String = Config.worktreeMarkersDir) {
        let r = resolver ?? PathResolver(config: config)
        self.config = config; self.resolver = r
        self.manager = WorktreeManager(config: config, resolver: r, run: run)
        self.borrowsPath = borrowsPath; self.markersDir = markersDir
    }

    // MARK: pure helpers (no actor state)
    public nonisolated func path(repo: String, branch: String) -> String { manager.path(repo: repo, branch: branch) }
    public nonisolated func borrowPath(repo: String, branch: String) -> String { manager.borrowPath(repo: repo, branch: branch) }

    // MARK: - ensure
    /// Serialized by the actor mailbox. NO `await` between the marker check and the checkout, so two
    /// concurrent same-branch calls run one-at-a-time and `git worktree add` fires once.
    public func ensure(repo: String, branch: String, cardId: UUID, base: String? = nil) async throws -> Worktree {
        let realRepo = try resolver.resolveRepo(repo)
        let wt = manager.path(repo: realRepo, branch: branch)
        try assertUnderWorktreesRoot(wt)                      // path-escape guard

        let dirExists = FileManager.default.fileExists(atPath: wt)
        let marked = markerExists(wt)
        if dirExists && marked {                              // adopt a materialized tree
            inflight[PathResolver.canonical(wt), default: []].insert(cardId)   // record the in-flight adopter
            return Worktree(path: wt, created: false, branchExisted: true)
        }
        if dirExists && !marked {                            // half-created / pre-upgrade tree
            if manager.isDirty(worktree: wt) {
                throw OrchestraError.worktreeNeedsManualCleanup(wt)   // NEVER auto-removed
            }
            try? manager.remove(worktree: wt, force: true)           // clean ⇒ prune
            if FileManager.default.fileExists(atPath: wt) {          // stray non-worktree dir
                try FileManager.default.removeItem(atPath: wt)
            }
        }
        // dir absent (fresh OR just pruned OR re-materialize-missing) ⇒ cut a checkout, THEN mark.
        let ensured = try manager.ensure(repo: realRepo, branch: branch, base: base)
        writeMarker(ensured.worktree)
        inflight[PathResolver.canonical(ensured.worktree), default: []].insert(cardId)   // record the in-flight creator
        return Worktree(path: ensured.worktree, created: ensured.created, branchExisted: ensured.branchExisted)
    }

    // MARK: - borrow lifecycle
    public func ensureBorrow(repo: String, parentBranch: String, borrowerCardId: UUID) async throws -> Worktree {
        loadBorrows()
        let realRepo = try resolver.resolveRepo(repo)
        let path = manager.borrowPath(repo: realRepo, branch: parentBranch)
        let canonPath = PathResolver.canonical(path)
        if let holder = borrows.first(where: { PathResolver.canonical($0.value) == canonPath })?.key,
           holder != borrowerCardId {
            throw OrchestraError.parentAlreadyBorrowed(parentBranch)
        }
        if borrows.first(where: { PathResolver.canonical($0.value) == canonPath }) == nil
            && FileManager.default.fileExists(atPath: path) {
            throw OrchestraError.parentAlreadyBorrowed(parentBranch)   // stray/crashed borrow dir
        }
        let created = try manager.borrow(repo: realRepo, branch: parentBranch)
        borrows[borrowerCardId] = created
        persistBorrows()
        return Worktree(path: created, created: true, branchExisted: true)
    }

    public func releaseBorrow(borrowerCardId: UUID) async throws {
        loadBorrows()
        guard let path = borrows[borrowerCardId] else { return }   // idempotent
        borrows[borrowerCardId] = nil
        persistBorrows()
        if !borrows.values.contains(path) {                        // no other holder ⇒ throwaway, force-remove
            try? manager.remove(worktree: path, force: true)
        }
    }

    /// Liveness-guarded. Keeps any dir whose registered borrower is still non-`archived`; removes
    /// terminated-borrower registrations + stray unregistered `orch-borrow-*` dirs.
    public func sweepOrphanBorrows(cards: [Task]) async {
        loadBorrows()
        // FAIL-SAFE ambiguity guard: an empty `cards` alongside non-empty registrations means the caller
        // handed us no evidence (partial/failed store load). "On ambiguity keep everything" — do nothing.
        guard !(cards.isEmpty && !borrows.isEmpty) else { return }
        // POSITIVE terminal evidence only: reclaim a registered borrow ONLY when its borrower card is
        // PRESENT in `cards` AND archived. A borrower that is merely ABSENT is ambiguous ⇒ keep (the truly
        // crashed/unregistered dirs are handled by the stray loop below, which never touches a live borrow).
        func terminated(_ id: UUID) -> Bool { cards.first(where: { $0.id == id }).map { $0.archived } ?? false }
        // CANONICALIZE both sides: `borrows.values` come from `borrowPath` = "\(worktreesRoot)/…"
        // (worktreesRoot stored verbatim, maybe non-canonical); `orphanBorrowPaths` returns git's
        // realpath-CANONICAL paths. A bare string compare could see a LIVE borrower's dir as "stray" and
        // force-remove it (bug #1).
        let keptPaths = Set(borrows.compactMap { terminated($0.key) ? nil : PathResolver.canonical($0.value) })
        for (id, p) in borrows where terminated(id) {
            if !keptPaths.contains(PathResolver.canonical(p)) && isUnderOwnedRoots(p) {
                try? manager.remove(worktree: p, force: true)
            }
            borrows[id] = nil
        }
        persistBorrows()
        for repo in Set(cards.filter { $0.origin == .worktree }.map(\.repo)) {
            for stray in manager.orphanBorrowPaths(repo: repo)
                where isUnderOwnedRoots(stray) && !keptPaths.contains(PathResolver.canonical(stray)) {
                try? manager.remove(worktree: stray, force: true)
            }
        }
    }

    // MARK: - migration
    private var markersMigrationSentinel: String { "\(markersDir)/.migrated" }
    /// ONE-TIME. Stamps markers for the given existing trees, then drops a sentinel so later boots no-op.
    /// Runs only at the first post-upgrade boot, when the daemon was down and every persisted tree is
    /// at-rest/complete — so it can never mark an in-flight (Stage-4 non-blocking spawn) half-checkout
    /// adoptable. Does NOT touch tree contents ⇒ a dirty pre-upgrade tree survives byte-intact.
    public func stampMarkers(forMigratedPaths paths: [String]) async {
        guard !FileManager.default.fileExists(atPath: markersMigrationSentinel) else { return }
        for p in paths where FileManager.default.fileExists(atPath: p) { writeMarker(p) }
        try? FileManager.default.createDirectory(atPath: markersDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: markersMigrationSentinel, contents: Data())
    }

    // MARK: - markers (registry-owned, OUTSIDE the worktree)
    private func markerFile(_ wt: String) -> String {
        let canon = PathResolver.canonical(wt)
        let enc = canon.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "/", with: "%2F")
        return "\(markersDir)/\(enc)"
    }
    private func markerExists(_ wt: String) -> Bool { FileManager.default.fileExists(atPath: markerFile(wt)) }
    private func writeMarker(_ wt: String) {
        try? FileManager.default.createDirectory(atPath: markersDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: markerFile(wt), contents: Data())
    }
    private func removeMarker(_ wt: String) { try? FileManager.default.removeItem(atPath: markerFile(wt)) }

    // MARK: - path safety
    private func assertUnderWorktreesRoot(_ p: String) throws {
        guard isUnderOwnedRoots(p) else { throw OrchestraError.pathNotAllowed(p) }
        try resolver.assertAllowed(p)   // defense-in-depth (component-wise `..` collapse)
    }
    /// Owned roots for removal/creation = under `worktreesRoot` (covers `orch-borrow-*`).
    private func isUnderOwnedRoots(_ p: String) -> Bool {
        let root = PathResolver.canonical(config.worktreesRoot)
        let real = PathResolver.canonical(p)
        return real == root || real.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    // MARK: - release (single removal policy)
    /// Seam for Stage-4 conservative mode (post-corrupt-recovery): when true, release removes nothing until
    /// ownership is positively re-established. PR4b/Task 4.4 sets it; here it just gates the policy.
    private var conservativeMode = false
    public func setConservativeMode(_ on: Bool) { conservativeMode = on }

    /// The SINGLE removal policy every teardown routes through. Removes the card's tree only when
    /// siblings==0 && (!dirty || force) && created(marker present) && pathUnderOwnedRoots. A missing
    /// tree is a no-op success. Never throws in a way that escalates to data loss.
    public func release(cardId: UUID, cards: [Task], force: Bool) async throws {
        guard let card = cards.first(where: { $0.id == cardId }) else { return }   // unknown ⇒ no-op
        let wt = card.cwd
        let canon = PathResolver.canonical(wt)
        defer { inflight[canon]?.remove(cardId); if inflight[canon]?.isEmpty == true { inflight[canon] = nil } }
        if conservativeMode { return }                                            // Stage-4 seam
        guard isUnderOwnedRoots(wt) else { return }                              // never outside owned roots
        guard markerExists(wt) else { return }                                    // created(≡marker) guard
        guard FileManager.default.fileExists(atPath: wt) else { removeMarker(wt); return }  // idempotent-to-missing
        let storeSibling = cards.contains {
            $0.id != cardId && !$0.archived && $0.origin == .worktree && PathResolver.canonical($0.cwd) == canon
        }
        let inflightSibling = !(inflight[canon]?.subtracting([cardId]).isEmpty ?? true)   // another in-flight holder?
        guard !storeSibling && !inflightSibling else { return }                 // referenced (stored OR in-flight) ⇒ keep
        if manager.isDirty(worktree: wt) && !force { return }                    // dirty + !force ⇒ keep
        try? manager.remove(worktree: wt, force: force)                          // never throw to data loss
        if !FileManager.default.fileExists(atPath: wt) { removeMarker(wt) }
    }

    // MARK: - borrow persistence (atomic JSON, [String:String] on disk)
    private func loadBorrows() {
        guard !borrowsLoaded else { return }
        borrowsLoaded = true
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: borrowsPath)),
              let raw = try? OrchestraJSON.decoder.decode([String: String].self, from: data) else { return }
        borrows = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
    }
    private func persistBorrows() {
        let raw = Dictionary(uniqueKeysWithValues: borrows.map { ($0.key.uuidString, $0.value) })
        guard let data = try? OrchestraJSON.pretty.encode(raw) else { return }
        let dir = (borrowsPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: borrowsPath)
        let tmp = URL(fileURLWithPath: borrowsPath + ".tmp.\(UUID().uuidString)")
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return }
        if FileManager.default.fileExists(atPath: borrowsPath) {
            if (try? FileManager.default.replaceItemAt(url, withItemAt: tmp)) == nil {
                try? FileManager.default.removeItem(at: tmp)   // best-effort: don't leak the tmp sibling
            }
        } else if (try? FileManager.default.moveItem(at: tmp, to: url)) == nil {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
