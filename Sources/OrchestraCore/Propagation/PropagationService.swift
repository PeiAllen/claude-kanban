import Foundation
import OrchestraKit

/// Policy, per-checkout serialization and the entry points around `SharedStore`. `SharedStore` owns the
/// git mechanics; this actor owns *when* and *whether*: eligibility, the policy table, leaf
/// classification, stand-downs, notices, the lock rule, teardown flush/reap, and the boot sweep.
///
/// **Two chains, no cycle.** `checkout:<path>` serializes everything that touches one checkout git dir.
/// `store:<repoKey>` serializes everything that can write `store.git` (attach's seed push, `send`,
/// `resolve`'s internal send), because two checkouts of one repo push to the same bare repo and would
/// race on `refs/heads/main.lock`. A checkout op may take the store key. A store op takes nothing, and
/// `SharedStore`'s own seed lock never takes a service key, so no cycle exists.
///
/// **Only public entry points take chain keys.** `prepare` and `syncOne` take none, so `resolve`,
/// `status`, `adopt` and `flush` can compose them without ever re-entering their own key (the chain
/// awaits its predecessor unconditionally, so a nested same-key call would deadlock).
///
/// `init` does no filesystem or git work. Sinks are installed after init by `setSinks`, because an
/// actor cannot capture `[weak self]` in a stored property's initializer.
public actor PropagationService {
    let store: any SharedStoring
    let proc: any ProcRunning
    let resolver: PathResolver
    let root: String
    let policyPath: String
    /// The union across ALL adapters, not the card's own: a checkout's HEAD receives the other agent's
    /// files by merge, and `send`'s out-of-set guard reads HEAD — a per-adapter set would refuse every push.
    let adapterItems: @Sendable () -> [PropagationItem]

    typealias Notify = @Sendable (_ card: UUID, _ text: String, _ dedupKey: String) async -> Void
    typealias Warn = @Sendable (_ text: String) -> Void
    private var notifySink: Notify?
    var warnSink: Warn?

    // Chain state. `nextGeneration` is monotonic and NEVER reset: resetting it would let a stale link's
    // `generation == gen` check pass after the entry was cleared and recreated (ABA).
    private var chains: [String: (generation: Int, task: _Concurrency.Task<Void, Never>)] = [:]
    private var nextGeneration = 0

    var lastConflict: [String: ConflictRecord] = [:]
    /// Once-per-launch flags, per checkout, reset when the checkout's session epoch advances.
    var onceFlags: [String: (epoch: Int, kinds: Set<String>)] = [:]
    /// Process-wide one-shot warnings (git too old, corrupt policy). Cleared when the cause clears.
    private var globalWarned: Set<String> = []
    private var gitVersionOK: Bool?

    public init(store: any SharedStoring, proc: any ProcRunning, resolver: PathResolver,
                root: String, policyPath: String, adapterItems: @escaping @Sendable () -> [PropagationItem]) {
        self.store = store
        self.proc = proc
        self.resolver = resolver
        self.root = root
        self.policyPath = policyPath
        self.adapterItems = adapterItems
    }

    /// Installed by `OrchestraService` after its own initialization.
    func setSinks(notify: Notify?, warn: Warn?) {
        notifySink = notify
        warnSink = warn
    }

    // MARK: - Serialization

    func serialized<T: Sendable>(_ key: String, _ op: @escaping @Sendable () async -> T) async -> T {
        let prev = chains[key]?.task
        nextGeneration += 1
        let gen = nextGeneration
        let work = _Concurrency.Task<T, Never> { _ = await prev?.value; return await op() }
        chains[key] = (gen, _Concurrency.Task { _ = await work.value })
        let value = await work.value
        if chains[key]?.generation == gen { chains[key] = nil }
        return value
    }

    /// For tests: which chain keys are live, and the monotonic counter.
    func chainSnapshot() -> (keys: Set<String>, nextGeneration: Int) { (Set(chains.keys), nextGeneration) }

    static func checkoutKey(_ checkout: String) -> String { "checkout:" + checkout }
    static func storeKey(_ primary: String) -> String { "store:" + CardFileSpec.cwdHash(primary) }

    // MARK: - Sinks and once-flags

    func warn(_ text: String) { warnSink?(text) }

    func notify(_ card: UUID, _ text: String, dedupKey: String) async { await notifySink?(card, text, dedupKey) }

    /// True the first time `kind` is seen for `checkout` in this session epoch.
    func firstTime(_ checkout: String, epoch: Int, _ kind: String) -> Bool {
        var entry = onceFlags[checkout] ?? (epoch, [])
        if entry.epoch != epoch { entry = (epoch, []) }
        let fresh = entry.kinds.insert(kind).inserted
        onceFlags[checkout] = entry
        return fresh
    }

    func warnOnce(_ checkout: String, epoch: Int, _ kind: String, _ text: String) {
        if firstTime(checkout, epoch: epoch, kind) { warn(text) }
    }

    func warnGlobalOnce(_ kind: String, _ text: String) {
        if globalWarned.insert(kind).inserted { warn(text) }
    }

    // MARK: - Git version gate

    /// `git` >= 2.40, or propagation stays disabled. A version that cannot be read fails closed; only a
    /// definite answer is cached, so a transient spawn failure is retried. PR6 calls this at boot.
    public func checkGitVersion() async -> Bool {
        if let cached = gitVersionOK { return cached }
        guard let r = try? await proc.run(StoreGit.versionCheckArgv, cwd: nil, env: [:], timeout: .seconds(10)), r.ok else {
            warnGlobalOnce("gitVersionUnreadable", "Shared files are off: could not read the git version.")
            return false
        }
        let ok = StoreGit.meetsMinimumVersion(r.stdout)
        gitVersionOK = ok
        globalWarned.remove("gitVersionUnreadable")
        if !ok { warnGlobalOnce("gitTooOld", "Shared files are off: git 2.40 or newer is required.") }
        return ok
    }

    // MARK: - Context (steps 1–2)

    struct Context: Sendable { let checkout: String; let primary: String }
    enum ContextResult: Sendable { case ctx(Context), done(SyncOutcome) }

    /// Version gate, repo resolution and eligibility. Chain-free.
    func context(for card: OrchestraKit.Task, checkout rawCheckout: String) async -> ContextResult {
        guard await checkGitVersion() else { return .done(.standDown(.gitTooOld)) }
        var checkout = PathResolver.canonical(rawCheckout)
        let containment: RepoContainment
        var primary = ""
        switch card.origin {
        case .scratch:
            containment = .outsideAnyRepo
        case .worktree:
            guard let resolved = try? resolver.resolveRepo(card.repo) else {
                warnOnce(checkout, epoch: card.sessionEpoch, "repoUnresolved", "Shared files skipped: repo \(card.repo) does not resolve.")
                return .done(.skipped(.repoUnresolved))
            }
            primary = resolved
            containment = .insideRepo(root: checkout)
        case .borrowed:
            if let found = await locateBorrowed(checkout) {
                checkout = found.toplevel
                primary = found.primary
                containment = .insideRepo(root: found.toplevel)
            } else {
                containment = .outsideAnyRepo
            }
        }
        guard PropagationEligibility.decide(origin: card.origin, checkoutRepo: containment, primaryRoot: primary) == .participates
        else { return .done(.skipped(.ineligible)) }
        return .ctx(Context(checkout: checkout, primary: primary))
    }

    /// A borrowed cwd inside a known repo: its work tree root and that repo's primary checkout.
    private func locateBorrowed(_ cwd: String) async -> (toplevel: String, primary: String)? {
        guard let r = try? await proc.run(
            ["git", "rev-parse", "--show-toplevel", "--path-format=absolute", "--git-common-dir"],
            cwd: cwd, env: ["GIT_OPTIONAL_LOCKS": "0"], timeout: .seconds(10)), r.ok
        else { return nil }
        let lines = r.stdout.split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { return nil }
        let common = lines[1]
        guard (common as NSString).lastPathComponent == ".git" else { return nil }
        let primary = PathResolver.canonical((common as NSString).deletingLastPathComponent)
        guard (try? resolver.assertAllowed(primary)) != nil else { return nil }
        return (PathResolver.canonical(lines[0]), primary)
    }

    // MARK: - Prepare (steps 3–5)

    struct ItemPolicy: Sendable { let item: PropagationItem; let policy: PropagationPolicy }

    struct Prepared: Sendable {
        let checkout: String
        let primary: String
        let cardId: UUID
        let epoch: Int
        let readOnly: Bool
        let items: [ItemPolicy]
        /// Declared paths of every `shared` item that survived stand-down — the `paths:` argument for
        /// `receive`/`send`/`resolve`, and the same list fed to `DeclaredSet.build`. Never empty here:
        /// an empty list means no store call at all.
        let sharedPaths: [String]
        let exclusions: [String]
        let declared: DeclaredSet.Result
        let unignoredLeaves: Set<String>
        let dirs: (store: String, checkout: String)
    }

    enum Preparation: Sendable { case ready(Prepared), done(SyncOutcome) }

    /// Policy load, `tracked` verification and leaf classification. Chain-free.
    /// `extraShared`: items forced `shared` whose leaves bypass the un-ignored stand-down (`adopt` step 1,
    /// which must send the primary's still-tracked copies).
    /// `asPrimary`: preparing the primary checkout on a card's behalf — no notices or `tracked` warnings
    /// (they would name the wrong checkout), and never read-only.
    func prepare(_ card: OrchestraKit.Task, checkout: String, primary: String,
                 extraShared: [PropagationItem] = [], asPrimary: Bool = false) async -> Preparation {
        let epoch = card.sessionEpoch
        let loaded = PropagationStore.load(path: policyPath)
        guard let repoPolicy = loaded.repoPolicy(for: primary) else {
            warnGlobalOnce("policyLoadFailed", "Shared files are off: propagation.json could not be read.")
            return .done(.standDown(.policyLoadFailed))
        }
        globalWarned.remove("policyLoadFailed")

        var merged = repoPolicy.mergedItems(withAdapterItems: adapterItems())
        let extraNames = Set(extraShared.map(\.name))
        merged.removeAll { extraNames.contains($0.name) }
        var items = merged.map { ItemPolicy(item: $0, policy: repoPolicy.policy(for: $0.name)) }
        items += extraShared.map { ItemPolicy(item: $0, policy: .shared) }

        for ip in items where ip.policy == .tracked && !asPrimary {
            await verifyTracked(ip.item, in: checkout, epoch: epoch)
        }

        let shared = items.filter { $0.policy == .shared }
        let sharedPaths = Array(Set(shared.flatMap(\.item.paths))).sorted()
        guard !sharedPaths.isEmpty else { return .done(.nothingShared) }
        let exclusions = Array(Set(shared.flatMap(\.item.exclusions))).sorted()
        let dirs = SharedStore.gitDirs(root: root, repo: primary, checkout: checkout)

        // Candidate LEAVES only: a declared directory is never a candidate, so it can never be excluded
        // wholesale — its un-ignored children stand down one by one.
        var candidates = Set<String>()
        for p in sharedPaths { candidates.formUnion(Self.leaves(of: p, in: checkout, excluding: exclusions)) }
        let inStore = await headTreePaths(gitDir: dirs.checkout, paths: sharedPaths, excluding: exclusions)
        candidates.formUnion(inStore)

        let unignored: Set<String>
        switch await IgnoreProbe.classify(candidates.sorted(), inCheckout: checkout, proc: proc) {
        case .notARepo:
            return .done(.skipped(.notARepo))
        case .unknown(let detail):
            warn("Shared files stood down for \(checkout): could not check ignore rules (\(detail)).")
            return .done(.standDown(.probeUnknown(detail: detail)))
        case .repo(let ignored):
            var un = candidates.subtracting(ignored)
            for ip in extraShared { un = un.filter { leaf in !ip.paths.contains { Self.isUnder(leaf, $0) } } }
            unignored = un
        }

        let present = unignored.filter { FileManager.default.fileExists(atPath: checkout + "/" + $0) || inStore.contains($0) }
        if !asPrimary, !present.isEmpty, firstTime(checkout, epoch: epoch, "unignored") {
            await notify(card.id, "Shared files skipped because this project does not ignore them: "
                + present.sorted().joined(separator: ", ") + ". They stay as the project has them.",
                dedupKey: "shared-unignored:\(epoch)")
        }

        let declared = DeclaredSet.build(paths: sharedPaths, exclusions: exclusions, unignoredLeaves: unignored,
                                         existsInWorkingTreeOrIndex: { (try? FileManager.default.attributesOfItem(atPath: checkout + "/" + $0)) != nil })
        return .ready(Prepared(checkout: checkout, primary: primary, cardId: card.id, epoch: epoch,
                               readOnly: !asPrimary && card.access == .readOnly, items: items, sharedPaths: sharedPaths,
                               exclusions: exclusions, declared: declared, unignoredLeaves: unignored, dirs: dirs))
    }

    /// `tracked` means git already carries the path. One warning per launch when it does not.
    func verifyTracked(_ item: PropagationItem, in checkout: String, epoch: Int) async {
        guard !item.paths.isEmpty else { return }
        let r = try? await proc.run(["git", "ls-files", "--error-unmatch", "--"] + item.paths,
                                     cwd: checkout, env: ["GIT_OPTIONAL_LOCKS": "0"], timeout: .seconds(10))
        guard r?.ok != true else { return }
        warnOnce(checkout, epoch: epoch, "tracked:\(item.name)",
                 "Shared files: item \(item.name) is set to tracked, but git does not track all of its paths in \(checkout).")
    }

    /// Paths already in this checkout's git dir HEAD tree (files a previous sync sent or received).
    private func headTreePaths(gitDir: String, paths: [String], excluding ex: [String]) async -> Set<String> {
        guard FileManager.default.fileExists(atPath: gitDir + "/HEAD") else { return [] }
        guard let r = try? await proc.run(
            ["git", "--git-dir=\(gitDir)", "-c", "core.fsmonitor=false", "ls-tree", "-r", "--name-only", "-z", "HEAD", "--"] + paths,
            cwd: nil, env: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_OPTIONAL_LOCKS": "0"],
            timeout: .seconds(10)), r.ok
        else { return [] }
        return Set(r.stdout.split(separator: "\0").map(String.init).filter { p in !ex.contains { Self.isUnder(p, $0) } })
    }

    // MARK: - Pure path helpers

    /// `path` equals `ancestor` or sits beneath it (component-wise).
    static func isUnder(_ path: String, _ ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }

    /// The files at or under `path` in `checkout`, minus exclusions. A symlink is a leaf and is never
    /// followed; a missing path yields nothing.
    static func leaves(of path: String, in checkout: String, excluding ex: [String]) -> [String] {
        if ex.contains(where: { isUnder(path, $0) }) { return [] }
        let full = checkout + "/" + path
        guard let type = (try? FileManager.default.attributesOfItem(atPath: full))?[.type] as? FileAttributeType else { return [] }
        guard type == .typeDirectory else { return [path] }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: full)) ?? []).sorted()
        return names.flatMap { leaves(of: path + "/" + $0, in: checkout, excluding: ex) }
    }
}
