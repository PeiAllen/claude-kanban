import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Git mechanics for a per-repo shared instance: attach, commitLocal, receive, send, resolve. No
/// policy, no sinks — every "warn" the design calls for comes back as data on an outcome enum,
/// because this type's only collaborators are `ProcRunning` and `CardFileSpec.cwdHash`.
/// `PropagationService` (a later PR) owns policy, full per-checkout serialization, and the
/// lock-retry rule; this actor only closes the narrower first-attach seed race (see `attach`).
///
/// Every git call against the checkout git dir runs through `StoreGit`'s hermetic invocation
/// builder — never a bare `proc.run` with ad-hoc env — except the two bootstrap `git init --bare`
/// calls and the empty-tree `hash-object`, which need no `GIT_DIR` because no `StoreHandle` exists
/// yet at that point (they still get the config-isolation env vars, as defense in depth against
/// an ambient `~/.gitconfig` — e.g. `init.templateDir` or `init.defaultObjectFormat` — that the
/// agent sandbox can't reach but is still worth not trusting).
public actor SharedStore {
    private let root: String
    private let proc: any ProcRunning
    private var cachedEmptyTreeHash: String?
    private var seedChain: [String: _Concurrency.Task<Void, Never>] = [:]

    /// Env for the two bootstrap `git init --bare` calls and the empty-tree `hash-object` — no
    /// `GIT_DIR` (none exists yet), but still isolated from ambient global/system git config.
    private static let bootstrapEnv: [String: String] = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
    ]

    public init(root: String, proc: any ProcRunning) {
        self.root = root
        self.proc = proc
    }

    // MARK: - git-run helpers

    /// Runs one call against `handle`'s checkout git dir, with an optional env override (used by
    /// `resolve`'s temp-index calls) merged OVER the hermetic base env.
    private func run(_ extraArgs: [String], handle: StoreHandle, envOverrides: [String: String] = [:]) async throws -> ProcResult {
        let inv = StoreGit.invocation(gitDir: handle.checkoutGitDir, workTree: handle.workTree,
                                       emptyTreeHash: handle.emptyTreeHash, extraArgs: extraArgs)
        let env = inv.env.merging(envOverrides) { _, override in override }
        guard let result = try? await proc.run(inv.argv, cwd: inv.cwd, env: env, timeout: Self.timeout(for: extraArgs.first))
        else { throw SharedStoreError.gitDidNotRun(argv: inv.argv) }
        return result
    }

    /// Same, but throws `.gitFailed` on a non-zero exit — for calls with exactly one success
    /// shape. NEVER used at a branch decision point (seed-vs-adopt, unborn-HEAD checks) — `try?`
    /// around a throwing call there would conflate "git ran and said no" with "git did not run at
    /// all", so every decision point uses `run` + explicit `exitCode` branching instead.
    @discardableResult
    private func checked(_ extraArgs: [String], handle: StoreHandle, envOverrides: [String: String] = [:]) async throws -> ProcResult {
        let r = try await run(extraArgs, handle: handle, envOverrides: envOverrides)
        guard r.ok else { throw SharedStoreError.gitFailed(argv: extraArgs, exitCode: r.exitCode, stderr: r.stderr) }
        return r
    }

    /// A `diff` call, with `--no-renames` always pinned. Without it, a delete-plus-similar-add
    /// inside a declared directory (a rename, or coincidentally similar content) reports as one
    /// `R` record instead of separate `D`/`A` records — invisible to every `--diff-filter=D` query
    /// in this file, and to the untracked-detection logic in `writeOut`. Verified against real
    /// git: a plain `mv` + re-`add -f` inside a declared dir reports nothing to `--diff-filter=D`
    /// without this flag, silently letting an unintended deletion through.
    private func diff(_ args: [String], handle: StoreHandle, envOverrides: [String: String] = [:]) async throws -> ProcResult {
        try await checked(["diff", "--no-renames"] + args, handle: handle, envOverrides: envOverrides)
    }

    /// `fetch`/`push` against a real network-backed store can legitimately take longer than a
    /// local read; every other call is a local git operation. Two buckets, not one flat constant.
    private static func timeout(for subcommand: String?) -> Duration {
        switch subcommand {
        case "fetch", "push": return .seconds(60)
        default: return .seconds(30)
        }
    }

    private static func nullSeparated(_ s: String) -> [String] {
        s.split(separator: "\0").map(String.init)
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Does `path` exist on disk, without following a symlink — `FileManager.fileExists` follows
    /// symlinks, so a dangling symlink would read as "absent" and be silently overwritten by the
    /// absent-path filters in `staleTest`/`writeOut`/the ADOPT loop. `lstat` matches
    /// `hasConflictMarkers`'s own existence check.
    private func existsNoFollow(_ path: String, in workTree: String) -> Bool {
        var st = stat()
        return lstat(workTree + "/" + path, &st) == 0
    }

    // MARK: - layout + fetch

    /// The one definition of the on-disk layout: `<root>/<repoKey>/store.git` and
    /// `<root>/<repoKey>/checkouts/<checkoutKey>.git`. `PropagationService` reads it too, so the
    /// formula lives in exactly one place.
    public static func gitDirs(root: String, repo: String, checkout: String) -> (store: String, checkout: String) {
        let repoKey = CardFileSpec.cwdHash(repo)
        return ("\(root)/\(repoKey)/store.git",
                "\(root)/\(repoKey)/checkouts/\(CardFileSpec.cwdHash(checkout)).git")
    }

    /// Fetches the store's `main`. An absent `main` is not an error (`couldn't find remote ref`), but
    /// ANY other failure throws: a crash-left `refs/remotes/store/main.lock` used to read as "store
    /// main absent" (→ `.upToDate` forever), hiding a wedged checkout from the service's lock rule.
    private func fetchStore(_ handle: StoreHandle) async throws {
        let r = try await run(["fetch", handle.storeGitDir, "main:refs/remotes/store/main"], handle: handle)
        guard r.ok || r.stderr.contains("couldn't find remote ref") else {
            throw SharedStoreError.gitFailed(argv: ["fetch"], exitCode: r.exitCode, stderr: r.stderr)
        }
    }

    // MARK: - attach

    /// Creates the bare store and this checkout's git dir when absent, then — on a genuinely
    /// first attach (`rev-parse --verify -q HEAD` fails) — seeds or adopts, under a per-repo seed
    /// lock. `noteNovel` is called once per novel local file left uncommitted for `commitLocal`
    /// (the design's "one activity note naming the path"); defaults to a no-op since `SharedStore`
    /// has no notify sink of its own.
    public func attach(checkout: String, repo: String, declared: DeclaredSet.Result,
                        noteNovel: (@Sendable (String) -> Void)? = nil) async throws -> StoreHandle {
        let repoKey = CardFileSpec.cwdHash(repo)
        let (storeGitDir, checkoutGitDir) = Self.gitDirs(root: root, repo: repo, checkout: checkout)
        let fm = FileManager.default

        if !fm.fileExists(atPath: storeGitDir + "/HEAD") {
            guard let r = try? await proc.run(["git", "init", "--bare", "-b", "main", storeGitDir],
                                               cwd: nil, env: Self.bootstrapEnv, timeout: .seconds(30)), r.ok
            else { throw SharedStoreError.gitFailed(argv: ["git", "init", "--bare", "-b", "main", storeGitDir], exitCode: -1, stderr: "") }
        }
        // The bare init itself is existence-gated (avoid a redundant fork), not derived from a
        // single "isFirstAttach" flag off HEAD — `git init --bare` creates HEAD immediately,
        // before the writes below run, so gating everything on HEAD would make a crash between
        // `init` and the writes permanently skip them on every later attach. The writes
        // themselves (below) are unconditional and idempotent instead of existence-gated.
        var justInitializedCheckout = false
        if !fm.fileExists(atPath: checkoutGitDir + "/HEAD") {
            guard let r = try? await proc.run(["git", "init", "--bare", checkoutGitDir],
                                               cwd: nil, env: Self.bootstrapEnv, timeout: .seconds(30)), r.ok
            else { throw SharedStoreError.gitFailed(argv: ["git", "init", "--bare", checkoutGitDir], exitCode: -1, stderr: "") }
            justInitializedCheckout = true
        }
        // Unconditional, not existence-gated: `git init --bare` itself pre-populates `info/exclude`
        // with its own commented-out template (verified against real git), so gating this write on
        // "does the file already exist" would silently skip writing "/*" on EVERY attach, not just
        // a crash-recovered one. Both writes are idempotent — safe to repeat on every call.
        try fm.createDirectory(atPath: checkoutGitDir + "/info", withIntermediateDirectories: true)
        try "/*\n".write(toFile: checkoutGitDir + "/info/exclude", atomically: true, encoding: .utf8)
        try checkout.write(toFile: checkoutGitDir + "/orchestra-checkout", atomically: true, encoding: .utf8)

        let emptyTreeHash: String
        if let cached = cachedEmptyTreeHash {
            emptyTreeHash = cached
        } else {
            guard let hashResult = try? await proc.run(StoreGit.emptyTreeHashArgv, cwd: nil, env: Self.bootstrapEnv, timeout: .seconds(10)), hashResult.ok
            else { throw SharedStoreError.gitFailed(argv: StoreGit.emptyTreeHashArgv, exitCode: -1, stderr: "") }
            emptyTreeHash = Self.trimmed(hashResult.stdout)
            cachedEmptyTreeHash = emptyTreeHash
        }
        let handle = StoreHandle(storeGitDir: storeGitDir, checkoutGitDir: checkoutGitDir,
                                  workTree: checkout, emptyTreeHash: emptyTreeHash)

        // `core.bare false` is spec step 2, matching the design doc's documented layout. Harmless
        // to skip in practice (GIT_WORK_TREE alone makes add/commit/status work against a
        // core.bare=true dir — verified), but only when just-initialized: setting it repeatedly on
        // every attach is a wasted fork.
        if justInitializedCheckout {
            try await checked(["config", "core.bare", "false"], handle: handle)
        }

        let headCheck = try await run(["rev-parse", "--verify", "-q", "HEAD"], handle: handle)
        if !headCheck.ok {
            try await runSeedSerialized(repoKey + "#seed") { [self] in
                try await fetchStore(handle)
                let hasStoreMain = try await run(["rev-parse", "--verify", "-q", "refs/remotes/store/main"], handle: handle).ok
                if !hasStoreMain {
                    if !declared.stagingPositives.isEmpty {
                        try await checked(["add", "-f", "--"] + declared.stagingPathspec, handle: handle)
                    }
                    let clean = try await run(["diff", "--cached", "--quiet"], handle: handle)
                    if !clean.ok {
                        try await checked(["commit", "-q", "-m", "sync: \(checkout)"], handle: handle)
                    }
                    let headNowExists = try await run(["rev-parse", "--verify", "-q", "HEAD"], handle: handle).ok
                    if headNowExists {
                        try await checked(["push", handle.storeGitDir, "HEAD:main"], handle: handle)
                    }
                } else {
                    try await adoptFromStoreMain(handle, declared: declared, noteNovel: noteNovel)
                }
            }
        }
        return handle
    }

    /// `reset --mixed store/main` then, for every declared positive `ls-files` reports modified,
    /// either revert a stale local copy (found in this checkout's own history) or leave a novel
    /// one for `commitLocal` — shared between `attach`'s first-time ADOPT and `receive`'s
    /// unrelated-histories re-adopt, which the design also calls "re-ADOPT", not "reset only".
    private func adoptFromStoreMain(_ handle: StoreHandle, declared: DeclaredSet.Result, noteNovel: (@Sendable (String) -> Void)?) async throws {
        try await checked(["reset", "-q", "--mixed", "refs/remotes/store/main"], handle: handle)
        // Skipped when there are no positives — an EMPTY pathspec means "everything" to
        // `ls-files`, not "nothing" (the same hazard `DeclaredSet`'s own doc warns about for
        // `ls-tree`/`diff`), which would scan every modified file in the checkout instead of just
        // the declared ones.
        guard !declared.stagingPositives.isEmpty else { return }
        let modifiedRaw = try await run(["ls-files", "-z", "--modified", "--"] + declared.stagingPositives, handle: handle)
        for path in Self.nullSeparated(modifiedRaw.stdout).sorted() {
            // `ls-files --modified` also reports a path present in the index (just populated by
            // `reset --mixed`) but ABSENT from disk — the normal case for a checkout's very first
            // adopt, before anything has ever synced there. There is no local content to test or
            // preserve; `receive` (called right after attach in the normal flow) materializes it.
            guard existsNoFollow(path, in: handle.workTree) else { continue }
            if try await staleTest(path, handle: handle) {
                try await checked(["checkout", "--", path], handle: handle)
            } else {
                noteNovel?(path)
            }
        }
    }

    /// `false` for a path absent from disk — the normal case for a leaf that's in the index/tree
    /// but was never checked out here (a fresh adopt, or an un-ignored leaf whose HEAD advanced
    /// without ever touching the working tree). Without this guard, `hash-object` on a missing
    /// path exits 128 and `checked` throws, wedging every later call site that reaches here —
    /// confirmed against real git for both `attach`'s ADOPT loop and `commitLocal`'s flip test.
    private func staleTest(_ path: String, handle: StoreHandle) async throws -> Bool {
        guard existsNoFollow(path, in: handle.workTree) else { return false }
        let blob = try await checked(["hash-object", path], handle: handle)
        let sha = Self.trimmed(blob.stdout)
        guard !sha.isEmpty else { return false }
        let found = try await run(["log", "--all", "-n1", "--format=%H", "--find-object=\(sha)"], handle: handle)
        return found.ok && !Self.trimmed(found.stdout).isEmpty
    }

    // MARK: - commitLocal

    /// Stages, unstages and commits local state before every merge — "every sync commits before
    /// merging" is what makes it safe for `receive` to overwrite ignored files silently. Every
    /// HEAD-relative call (the flip test's `diff HEAD --`) is gated on `rev-parse --verify -q
    /// HEAD` succeeding: on an unborn HEAD (reachable after a SEED that staged nothing) that call
    /// 128s. `--cached`-only calls (`diff --cached …`, `checkout --`) are safe unborn and run
    /// unconditionally. Every unstage goes through `unstage(_:handle:headExists:)`, which picks
    /// `restore --staged` or `update-index --force-remove` per path — see that function's doc
    /// comment for why using the wrong one is a correctness bug, not just a style choice.
    public func commitLocal(_ handle: StoreHandle, declared: DeclaredSet.Result, unignoredLeaves: Set<String>) async throws -> CommitOutcome {
        let headExists = try await run(["rev-parse", "--verify", "-q", "HEAD"], handle: handle).ok

        let previouslyUnignored = readUnignoredRecord(handle)
        let flipped = previouslyUnignored.subtracting(unignoredLeaves)
        if headExists {
            for leaf in flipped.sorted() {
                let modified = try await diff(["--name-only", "HEAD", "--", leaf], handle: handle)
                guard !Self.trimmed(modified.stdout).isEmpty else { continue }
                if try await staleTest(leaf, handle: handle) {
                    try await checked(["checkout", "--", leaf], handle: handle)
                }
            }
        }

        let preRaw = try await diff(["--cached", "--name-only", "-z", "--diff-filter=D"], handle: handle)
        let pre = Set(Self.nullSeparated(preRaw.stdout))

        if !declared.stagingPositives.isEmpty {
            try await checked(["add", "-f", "--"] + declared.stagingPathspec, handle: handle)
        }

        var warnings: [CommitWarning] = []
        var stray = Set(Self.nullSeparated(try await diff(["--cached", "--name-only", "-z", "--"] + declared.outsideQuery, handle: handle).stdout))
        if !declared.holesQuery.isEmpty {
            stray.formUnion(Self.nullSeparated(try await diff(["--cached", "--name-only", "-z", "--"] + declared.holesQuery, handle: handle).stdout))
        }
        if !stray.isEmpty {
            try await unstage(stray.sorted(), handle: handle, headExists: headExists)
            warnings.append(.strayUnstaged(paths: stray.sorted()))
        }

        let postRaw = try await diff(["--cached", "--name-only", "-z", "--diff-filter=D"], handle: handle)
        let newlyDeleted = Set(Self.nullSeparated(postRaw.stdout)).subtracting(pre)
        if !newlyDeleted.isEmpty {
            let sortedNew = newlyDeleted.sorted()
            try await unstage(sortedNew, handle: handle, headExists: headExists)
            try await checked(["checkout", "--"] + sortedNew, handle: handle)
        }

        let stagedRaw = try await diff(["--cached", "--name-only", "-z"], handle: handle)
        for path in Self.nullSeparated(stagedRaw.stdout).sorted() {
            let fullPath = handle.workTree + "/" + path
            if let size = (try? FileManager.default.attributesOfItem(atPath: fullPath))?[.size] as? Int, size > 5_242_880 {
                try await unstage([path], handle: handle, headExists: headExists)
                warnings.append(.oversized(path: path))
            } else if try await stageMode(path, handle: handle) == "160000" {
                try await unstage([path], handle: handle, headExists: headExists)
                warnings.append(.gitlink(path: path))
            }
        }

        let clean = try await run(["diff", "--cached", "--quiet"], handle: handle)
        let committed = !clean.ok
        var sha: String?
        if committed {
            try await checked(["commit", "-q", "-m", "sync: \(handle.workTree)"], handle: handle)
            sha = Self.trimmed(try await checked(["rev-parse", "HEAD"], handle: handle).stdout)
        }

        writeUnignoredRecord(handle, unignoredLeaves)
        return committed ? .committed(sha: sha ?? "", warnings: warnings) : .nothingToCommit(warnings: warnings)
    }

    /// Unstages `paths` — index-only, working tree untouched. **Not a single git command**: which
    /// one is correct depends on whether HEAD already has the path, and using the wrong one is a
    /// correctness bug, not a style choice — confirmed against real git for both directions:
    /// - A path IN HEAD: `restore --staged` resets its index entry back to HEAD's version — a
    ///   true no-op unstage. `update-index --force-remove` instead DROPS the entry, which against
    ///   a HEAD that still has the path is a STAGED DELETION — `commitLocal` would then commit
    ///   that deletion, which is exactly the "background sync infers a deletion" the owner decided
    ///   against, reached through the unstage path instead of the no-inferred-deletion guard. It
    ///   also breaks the new-deletion-unstage call site's trailing `checkout --`, which fails with
    ///   "pathspec did not match any file(s) known to git" once the entry is gone.
    /// - A path NOT in HEAD (unborn HEAD, or a gitlink just staged and never committed):
    ///   `restore --staged` has nothing to restore to and 128s ("could not resolve 'HEAD'" or,
    ///   for `git rm --cached`, refuses with "has local modifications"). `update-index
    ///   --force-remove` is the only one that works.
    private func unstage(_ paths: [String], handle: StoreHandle, headExists: Bool) async throws {
        guard !paths.isEmpty else { return }
        guard headExists else {
            try await checked(["update-index", "--force-remove", "--"] + paths, handle: handle)
            return
        }
        let inHeadRaw = try await checked(["ls-tree", "-r", "--name-only", "-z", "HEAD", "--"] + paths, handle: handle)
        let inHead = Set(Self.nullSeparated(inHeadRaw.stdout))
        let toRestore = paths.filter { inHead.contains($0) }.sorted()
        let toForceRemove = paths.filter { !inHead.contains($0) }.sorted()
        if !toRestore.isEmpty {
            try await checked(["restore", "--staged", "--"] + toRestore, handle: handle)
        }
        if !toForceRemove.isEmpty {
            try await checked(["update-index", "--force-remove", "--"] + toForceRemove, handle: handle)
        }
    }

    private func stageMode(_ path: String, handle: StoreHandle) async throws -> String? {
        let r = try await checked(["ls-files", "--stage", "--", path], handle: handle)
        return Self.trimmed(r.stdout).split(separator: " ").first.map(String.init)
    }

    private func readUnignoredRecord(_ handle: StoreHandle) -> Set<String> {
        guard let content = try? String(contentsOfFile: handle.checkoutGitDir + "/orchestra-unignored", encoding: .utf8) else { return [] }
        return Set(content.split(separator: "\n").map(String.init))
    }

    private func writeUnignoredRecord(_ handle: StoreHandle, _ leaves: Set<String>) {
        try? leaves.sorted().joined(separator: "\n").write(toFile: handle.checkoutGitDir + "/orchestra-unignored", atomically: true, encoding: .utf8)
    }

    // MARK: - receive

    /// Fetches the store, computes the merged tree with `merge-tree --write-tree` (or takes the
    /// fast-forward/already-ancestor shortcut), writes out the declared+ignored leaves, and moves
    /// HEAD only when nothing written is dirty. **HEAD never moves while a written leaf is
    /// dirty** — the single most load-bearing property in this file: moving it while skipping a
    /// dirty leaf would make the NEXT `commitLocal` read the agent's still-uncommitted edit as
    /// something to undo, silently reverting the other checkout's already-applied change with no
    /// conflict raised.
    public func receive(_ handle: StoreHandle, paths: [String], declared: DeclaredSet.Result) async throws -> ReceiveOutcome {
        try await receive(handle, paths: paths, declared: declared, retried: false)
    }

    private func receive(_ handle: StoreHandle, paths: [String], declared: DeclaredSet.Result, retried: Bool) async throws -> ReceiveOutcome {
        try await fetchStore(handle)
        guard try await run(["rev-parse", "--verify", "-q", "refs/remotes/store/main"], handle: handle).ok
        else { return .upToDate }

        let S = Self.trimmed(try await checked(["rev-parse", "refs/remotes/store/main"], handle: handle).stdout)
        let H = try await run(["rev-parse", "--verify", "-q", "HEAD"], handle: handle)
        let headExists = H.ok
        let Hsha = Self.trimmed(H.stdout)

        var storeAlreadyAncestor = false
        if headExists {
            storeAlreadyAncestor = try await run(["merge-base", "--is-ancestor", S, Hsha], handle: handle).ok
        }
        var isFastForward = !headExists
        if headExists, !storeAlreadyAncestor {
            isFastForward = try await run(["merge-base", "--is-ancestor", Hsha, S], handle: handle).ok
        }

        let T: String
        let M: String
        if storeAlreadyAncestor {
            // Nothing NEW from the store by history — but the working tree may still be missing
            // content that `attach`'s ADOPT put into the index via `reset --mixed` without ever
            // touching disk (`--mixed` deliberately never touches the working tree). Use HEAD's
            // own tree so the write-out below still reconciles disk with what the index/HEAD
            // already has. Since M == Hsha here, HEAD literally cannot move regardless of what
            // write-out finds — see the `.partial` guard below, which is gated on `M != Hsha` for
            // exactly this reason.
            T = Self.trimmed(try await checked(["rev-parse", Hsha + "^{tree}"], handle: handle).stdout)
            M = Hsha
        } else if isFastForward {
            // Fast-forward (or unborn HEAD, which is trivially "behind" S).
            T = Self.trimmed(try await checked(["rev-parse", S + "^{tree}"], handle: handle).stdout)
            M = S
        } else {
            let mt = try await run(["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", Hsha, S], handle: handle)
            if mt.exitCode == 1 {
                let records = Self.nullSeparated(mt.stdout)
                return .conflicted(paths: Array(records.dropFirst()), storeSha: S)
            }
            if mt.exitCode == 128, mt.stderr.contains("unrelated histories") {
                guard !retried else { throw SharedStoreError.gitFailed(argv: ["merge-tree"], exitCode: 128, stderr: mt.stderr) }
                try await adoptFromStoreMain(handle, declared: declared, noteNovel: nil)
                return try await receive(handle, paths: paths, declared: declared, retried: true)
            }
            guard mt.ok else { throw SharedStoreError.gitFailed(argv: ["merge-tree"], exitCode: mt.exitCode, stderr: mt.stderr) }
            let records = Self.nullSeparated(mt.stdout)
            T = records.first ?? ""
            M = Self.trimmed(try await checked(["commit-tree", T, "-p", Hsha, "-p", S, "-m", "sync: merge"], handle: handle).stdout)
        }

        let h = headExists ? Hsha : handle.emptyTreeHash
        let result = try await writeOut(handle, tree: T, h: h, paths: paths, holesQuery: declared.holesQuery, knownClean: [])
        if M != Hsha {
            guard result.dirty.isEmpty else { return .partial(dirty: result.dirty) }
        }
        guard !result.written.isEmpty || !result.deleted.isEmpty || M != Hsha else { return .upToDate }

        // `read-tree` before `update-ref`, not after: a crash between them then leaves the index
        // already at T with HEAD still at the OLD value. The next `commitLocal` correctly commits
        // T's content on top of the old HEAD (matching what's already on disk from the write-out
        // above), and a later `merge-tree` combines it cleanly — "files first, HEAD last" applied
        // one level deeper. The reverse order risks the next `commitLocal` reading a STALE index
        // (still at the old tree, for any leaf `writeOut` didn't touch) against the ALREADY-MOVED
        // HEAD, committing the stale content and reverting this sync's change to those leaves.
        try await checked(["read-tree", T], handle: handle)
        if M != Hsha {
            try await checked(["update-ref", "HEAD", M], handle: handle)
        }
        return .materialized(written: result.written, deleted: result.deleted)
    }

    // MARK: - resolve

    /// The one write path for a conflict. The agent's conflicted files are read as DATA, never as
    /// instructions to git. `serialized(checkoutKey)` (so a resolution rides the same chain as a
    /// sync) belongs to `PropagationService` (a later PR), not here — `SharedStore.resolve` is
    /// just the git mechanics, called from inside that serialization the same way `sync` calls
    /// `attach`/`commitLocal`/`receive`/`send`.
    ///
    /// **Every conflicted path is dirty against H by construction** — H holds the checkout's
    /// last-synced version, and each path's current content is the agent's uncommitted
    /// reconciliation edit (that is WHY `merge-tree` conflicted). `writeOut` is called with
    /// `knownClean: Set(P)`: `T2`'s blob for each `p ∈ P` is EXACTLY what `add -f` captured from
    /// `p`'s current on-disk content, so writing it out would be a no-op — nothing `knownClean`
    /// could clobber by excluding those paths from the dirty check.
    ///
    /// **A conflicted path the project still tracks here is refused, never staged.** `resolve`
    /// only ever stages a conflicted path's on-disk content — for a leaf that's currently tracked
    /// (not ignored) in THIS checkout, that content is the project's own, unrelated to the shared
    /// store, and staging it would ship project content into the store and every other checkout —
    /// exactly the violation 02-contract's non-interference table warns against.
    public func resolve(_ handle: StoreHandle, paths: [String], declared: DeclaredSet.Result) async throws -> ResolveOutcome {
        try await fetchStore(handle)
        guard try await run(["rev-parse", "--verify", "-q", "refs/remotes/store/main"], handle: handle).ok
        else { return .nothingToResolve }
        guard try await run(["rev-parse", "--verify", "-q", "HEAD"], handle: handle).ok
        else { return .nothingToResolve }

        let H = Self.trimmed(try await checked(["rev-parse", "HEAD"], handle: handle).stdout)
        let S = Self.trimmed(try await checked(["rev-parse", "refs/remotes/store/main"], handle: handle).stdout)
        let mt = try await run(["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", H, S], handle: handle)
        if mt.exitCode == 0 { return .nothingToResolve }
        guard mt.exitCode == 1 else { throw SharedStoreError.gitFailed(argv: ["merge-tree"], exitCode: mt.exitCode, stderr: mt.stderr) }

        let records = Self.nullSeparated(mt.stdout)
        let mtTree = records.first ?? ""
        let P = Array(records.dropFirst()).sorted()

        let markered = P.filter { hasConflictMarkers(atPath: handle.workTree + "/" + $0) }
        guard markered.isEmpty else { return .refusedMarkers(paths: markered) }

        let classifyP = await IgnoreProbe.classify(P, inCheckout: handle.workTree, proc: proc)
        let ignoredP: Set<String>
        switch classifyP {
        case .repo(let ignored): ignoredP = ignored
        case .notARepo: ignoredP = Set(P)
        case .unknown(let detail): throw SharedStoreError.ignoreProbeFailed(detail: detail)
        }
        let unignoredConflicted = Set(P).subtracting(ignoredP)
        guard unignoredConflicted.isEmpty else { return .refusedMarkers(paths: unignoredConflicted.sorted()) }

        let resolveIndex = handle.checkoutGitDir + "/resolve-index"
        let envOverride = ["GIT_INDEX_FILE": resolveIndex]
        defer { try? FileManager.default.removeItem(atPath: resolveIndex) }
        try await checked(["read-tree", mtTree], handle: handle, envOverrides: envOverride)
        try await checked(["add", "-f", "--"] + P, handle: handle, envOverrides: envOverride)
        let T2 = Self.trimmed(try await checked(["write-tree"], handle: handle, envOverrides: envOverride).stdout)

        // The out-of-set guard runs against T2 BEFORE anything commits or moves HEAD — checking
        // it only inside `send`, after `update-ref`/`read-tree` already ran, would leave HEAD
        // permanently holding an out-of-set path on a refusal: `send`'s own guard reads HEAD, so
        // every later `send` from this checkout would refuse forever, with no way back short of a
        // human editing the index.
        let outOfSet = Self.nullSeparated(try await diff(["--name-only", "-z", handle.emptyTreeHash, T2, "--"] + declared.outsideQuery, handle: handle).stdout)
        var holesInT2: [String] = []
        if !declared.holesQuery.isEmpty {
            holesInT2 = Self.nullSeparated(try await checked(["ls-tree", "-r", "--name-only", "-z", T2, "--"] + declared.holesQuery, handle: handle).stdout)
        }
        guard outOfSet.isEmpty, holesInT2.isEmpty else {
            return .sendOutcome(.refusedOutOfSet(paths: (outOfSet + holesInT2).sorted()))
        }

        let M = Self.trimmed(try await checked(["commit-tree", T2, "-p", H, "-p", S, "-m", "resolve: " + P.joined(separator: ",")], handle: handle).stdout)

        let result = try await writeOut(handle, tree: T2, h: H, paths: paths, holesQuery: declared.holesQuery, knownClean: Set(P))
        guard result.dirty.isEmpty else { return .sendOutcome(.partial(dirty: result.dirty)) }

        // read-tree before update-ref — same crash-safety ordering as `receive`.
        try await checked(["read-tree", T2], handle: handle)
        try await checked(["update-ref", "HEAD", M], handle: handle)
        let sendResult = try await send(handle, paths: paths, declared: declared)
        switch sendResult {
        case .pushed, .nothingToDo: return .resolved
        default: return .sendOutcome(sendResult)
        }
    }

    /// Scans a conflicted path's raw bytes for a line starting `"<<<<<<< "` or `">>>>>>> "`.
    /// Reads bytes, never a UTF8-decoding `String` read — a non-UTF8 (binary) conflicted file must
    /// not make the whole resolve throw, it should just be scanned and found marker-free. `lstat`s
    /// first: a symlink's "content" for marker-scanning purposes is irrelevant (a symlink can't
    /// literally contain a text line), so it's treated as marker-free and left for `add -f` to
    /// store as a link (mode 120000), never followed.
    private func hasConflictMarkers(atPath path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        guard (st.st_mode & S_IFMT) != S_IFLNK else { return false }
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        let openMarker = Array("<<<<<<< ".utf8)
        let closeMarker = Array(">>>>>>> ".utf8)
        for line in data.split(separator: 0x0A) {
            let bytes = Array(line)
            if bytes.starts(with: openMarker) || bytes.starts(with: closeMarker) { return true }
        }
        return false
    }

    // MARK: - send

    /// Refuses (never pushes) when HEAD holds a path outside the declared set or inside an
    /// exclusion. Otherwise pushes by explicit URL, retrying a non-fast-forward rejection a
    /// bounded number of times by calling `receive` to catch up first. The unborn-HEAD guard is
    /// hoisted above the out-of-set queries — the `diff <emptyTree> HEAD` query itself 128s on an
    /// unborn HEAD, not just the push.
    public func send(_ handle: StoreHandle, paths: [String], declared: DeclaredSet.Result) async throws -> SendOutcome {
        guard try await run(["rev-parse", "--verify", "-q", "HEAD"], handle: handle).ok else { return .nothingToDo }

        let out = Self.nullSeparated(try await diff(["--name-only", "-z", handle.emptyTreeHash, "HEAD", "--"] + declared.outsideQuery, handle: handle).stdout)
        var holes: [String] = []
        if !declared.holesQuery.isEmpty {
            holes = Self.nullSeparated(try await checked(["ls-tree", "-r", "--name-only", "-z", "HEAD", "--"] + declared.holesQuery, handle: handle).stdout)
        }
        guard out.isEmpty, holes.isEmpty else { return .refusedOutOfSet(paths: (out + holes).sorted()) }

        var attempt = 0
        while attempt < 3 {
            attempt += 1
            let r = try await run(["push", handle.storeGitDir, "HEAD:main"], handle: handle)
            if r.ok {
                return r.stderr.contains("Everything up-to-date") ? .nothingToDo : .pushed
            }
            if r.stderr.contains("[rejected]"), r.stderr.contains("fetch first") || r.stderr.contains("non-fast-forward") {
                let outcome = try await receive(handle, paths: paths, declared: declared)
                switch outcome {
                case .materialized, .upToDate: continue
                case .conflicted(let p, let s): return .conflicted(paths: p, storeSha: s)
                case .partial(let d): return .partial(dirty: d)
                }
            }
            throw SharedStoreError.gitFailed(argv: ["push", handle.storeGitDir, "HEAD:main"], exitCode: r.exitCode, stderr: r.stderr)
        }
        throw SharedStoreError.sendRetriesExhausted
    }

    /// Shared by `receive` and `resolve`. `knownClean` excludes paths from the dirty check — used
    /// by `resolve` to exclude the just-resolved conflicted paths, which are dirty against H BY
    /// CONSTRUCTION (that's why they conflicted) but whose content in `tree` is EXACTLY what
    /// `resolve` staged from disk, so writing them out would be a no-op.
    private func writeOut(_ handle: StoreHandle, tree: String, h: String, paths: [String], holesQuery: [String], knownClean: Set<String>)
        async throws -> (written: [String], deleted: [String], dirty: [String])
    {
        guard !paths.isEmpty else { return ([], [], []) }
        let call1 = Self.nullSeparated(try await checked(["ls-tree", "-r", "--name-only", "-z", tree, "--"] + paths, handle: handle).stdout)
        let call2 = Self.nullSeparated(try await checked(["ls-tree", "-r", "--name-only", "-z", h, "--"] + paths, handle: handle).stdout)
        var holesInTree: [String] = [], holesInH: [String] = []
        if !holesQuery.isEmpty {
            holesInTree = Self.nullSeparated(try await checked(["ls-tree", "-r", "--name-only", "-z", tree, "--"] + holesQuery, handle: handle).stdout)
            holesInH = Self.nullSeparated(try await checked(["ls-tree", "-r", "--name-only", "-z", h, "--"] + holesQuery, handle: handle).stdout)
        }
        let candidates = (Set(call1).union(call2)).subtracting(holesInTree).subtracting(holesInH)
        guard !candidates.isEmpty else { return ([], [], []) }

        let classifyResult = await IgnoreProbe.classify(candidates.sorted(), inCheckout: handle.workTree, proc: proc)
        let keep: Set<String>
        switch classifyResult {
        case .repo(let ignored):
            keep = ignored
        case .notARepo:
            // Stable, not transient: a directory either is a repo or it isn't. Nothing is ignored
            // here (no ignore rules can exist), so there's nothing to write — safe to advance.
            keep = []
        case .unknown(let detail):
            // A batch classification failure must never be read as "safe to write" NOR "safe to
            // advance HEAD past" — unlike `.notARepo`, this is a TRANSIENT probe failure (a
            // `check-ignore` that errored or never completed). Throwing here, rather than
            // returning an empty result, is what stops `receive`/`resolve` from silently moving
            // HEAD/committing over content this write-out never actually verified.
            throw SharedStoreError.ignoreProbeFailed(detail: detail)
        }
        guard !keep.isEmpty else { return ([], [], []) }

        let dirtyFromH = Set(Self.nullSeparated(try await diff(["--name-only", "-z", h, "--"] + keep.sorted(), handle: handle).stdout))
            .subtracting(knownClean)
            .filter { existsNoFollow($0, in: handle.workTree) }
        // A leaf present on disk but absent from BOTH `h`'s tree and `tree` itself is invisible to
        // the `diff h --` query above (git reports nothing when a path is absent from both the
        // tree being compared AND the working tree's corresponding entry doesn't exist in that
        // tree to begin with) — confirmed against real git: an untracked new file produces no
        // output from `diff <tree that lacks it> -- <path>`, even though the file exists with
        // real content. Without this second check, `writeOut` would silently `checkout tree --
        // leaf` over a genuinely local, never-synced file, destroying it with no signal at all.
        let inH = Set(call2)
        let untrackedDirty = keep.subtracting(inH).subtracting(dirtyFromH)
            .filter { existsNoFollow($0, in: handle.workTree) }
        let dirty = dirtyFromH.union(untrackedDirty)
        let toCheck = keep.subtracting(dirty)
        guard !toCheck.isEmpty else { return ([], [], dirty.sorted()) }

        let changed = Set(Self.nullSeparated(try await diff(["--name-only", "-z", tree, "--"] + toCheck.sorted(), handle: handle).stdout))
        var written: [String] = [], deleted: [String] = []
        let inTreeSet = Set(call1)
        for leaf in changed.sorted() {
            if inTreeSet.contains(leaf) {
                try await checked(["checkout", tree, "--", leaf], handle: handle)
                written.append(leaf)
            } else {
                try? FileManager.default.removeItem(atPath: handle.workTree + "/" + leaf)
                // Keeps the index consistent with disk even though HEAD/read-tree haven't
                // advanced yet — `checkout tree -- leaf` above already updates the index for the
                // WRITTEN case, so only the removed case needs this.
                try await checked(["update-index", "--force-remove", "--", leaf], handle: handle)
                deleted.append(leaf)
            }
        }
        return (written, deleted, dirty.sorted())
    }

    /// The seed-vs-adopt decision keys on `store/main` (a repo-wide ref), not on the per-checkout
    /// `HEAD` — two concurrent `attach` calls for two DIFFERENT checkouts of the SAME repo each
    /// have their own independently-unborn `HEAD`, so re-checking that ref after the lock tells
    /// either side nothing new. What must be re-evaluated fresh, inside the lock, is
    /// `hasStoreMain` — since the whole first-attach decision is wrapped by this lock (fetch
    /// through push/adopt), the loser's closure invocation runs strictly after the winner's
    /// completes, so it correctly observes `store/main` now present and takes ADOPT. Deliberately
    /// never clears `seedChain[key]` after finishing — repos are few and long-lived per daemon
    /// process, not worth PR4's full generational-chain complexity for just this narrower race.
    /// Known limitation: the unstructured `Task` does not inherit the caller's cancellation.
    private func runSeedSerialized(_ key: String, _ op: @escaping @Sendable () async throws -> Void) async throws {
        let previous = seedChain[key]
        let box = ThrownErrorBox()
        let task = _Concurrency.Task<Void, Never> {
            _ = await previous?.value
            do { try await op() } catch { box.set(error) }
        }
        seedChain[key] = task
        await task.value
        if let error = box.get() { throw error }
    }
}
