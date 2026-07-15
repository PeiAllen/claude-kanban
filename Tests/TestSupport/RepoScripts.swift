import Foundation
import OrchestraCore

/// Shared FakeProc rule-sets that re-express the real-git repo arrangements the hidden-integration
/// suites used to build with `git init` + commits. A `RepoGraph` models a commit DAG in memory and
/// installs rules answering the EXACT argv shapes + exit-code semantics the production tree/lineage
/// probes run (`OrchestraService+Tree.swift`: `treeTip` = `rev-parse --verify --quiet`, `treeBehind`
/// = `rev-list --count A..B` distinguishing nil-from-0, `treeBaseIsAncestor` = `merge-base
/// --is-ancestor` distinguishing exit 1 from other failures, `mergeBaseOID` = plain `merge-base`).
///
/// Fidelity is pinned by ContractTests: `GitRevContractTests` runs the same RepoGraph rules AND real
/// git through the identical matrix and asserts `(exitCode, stdout-shape, stderr-presence)` agree, and
/// `GitConfigContractTests` does the same for `GitConfigEmulator`. The unit suites and the matrices
/// import the SAME rule objects from here — the license is exercised, not copied.
public final class RepoGraph: @unchecked Sendable {
    private let lock = NSLock()
    private var parents: [String: [String]] = [:]   // oid -> parent oids
    private var depth: [String: Int] = [:]          // oid -> distance from root (for merge-base LCA)
    private var refs: [String: String] = [:]        // bare branch name -> tip oid
    private var counter = 0

    public init() {}

    private func mint() -> String {
        counter += 1
        // A 40-char hex-ish OID: unique, opaque, whitespace-free. The leading `f` guarantees it never
        // parses as a decimal integer (a real SHA never does either — the rev contract compares that
        // shape). Production only compares/trims the OID, never its format.
        return "f" + String(format: "%039x", counter)
    }

    /// Normalize a ref argument to a bare branch name lookup key. `refs/heads/x` → `x`; a raw OID or
    /// bare name passes through.
    private func normalize(_ ref: String) -> String {
        if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
        return ref
    }

    /// Resolve a ref (branch name, `refs/heads/<b>`, or a raw OID) to an OID, or nil if unknown.
    private func resolveLocked(_ ref: String) -> String? {
        let n = normalize(ref)
        if let oid = refs[n] { return oid }
        if parents[n] != nil { return n }   // a known OID resolves to itself
        return nil
    }

    private func ancestorsLocked(_ oid: String) -> Set<String> {
        var seen: Set<String> = []
        var stack = [oid]
        while let cur = stack.popLast() {
            guard parents[cur] != nil, !seen.contains(cur) else { continue }
            seen.insert(cur)
            stack.append(contentsOf: parents[cur] ?? [])
        }
        return seen
    }

    // MARK: graph construction (mirrors the real-git fixture helpers)

    /// Append a commit to `branch` (creating the branch's first commit if empty). Returns the new tip.
    @discardableResult
    public func commit(on branch: String) -> String {
        lock.withLock {
            let p = refs[branch].map { [$0] } ?? []
            let oid = mint()
            parents[oid] = p
            depth[oid] = (p.first.flatMap { depth[$0] } ?? -1) + 1
            refs[branch] = oid
            return oid
        }
    }

    /// Create `branch` pointing at another ref's current tip (`git branch <branch> <at>`).
    public func branch(_ name: String, at ref: String) {
        lock.withLock {
            if let oid = resolveLocked(ref) { refs[name] = oid }
        }
    }

    /// Rewrite `branch`'s tip in place (`git commit --amend`): a new commit with the SAME parent as the
    /// old tip, so the old tip is orphaned (no longer an ancestor of the new tip).
    @discardableResult
    public func amend(_ branch: String) -> String {
        lock.withLock {
            let oldParents = refs[branch].flatMap { parents[$0] } ?? []
            let oid = mint()
            parents[oid] = oldParents
            depth[oid] = (oldParents.first.flatMap { depth[$0] } ?? -1) + 1
            refs[branch] = oid
            return oid
        }
    }

    /// Delete a branch ref (`git branch -D`).
    public func deleteBranch(_ name: String) { lock.withLock { refs[name] = nil } }

    /// Mint a standalone commit (no branch), returning its OID — a detached tip a remote ref can point at.
    /// `RemoteRules` uses it to model a fetched remote tip that `rev-parse --verify <privateRef>` resolves.
    @discardableResult
    public func mintCommit() -> String {
        lock.withLock {
            let oid = mint()
            parents[oid] = []
            depth[oid] = 0
            return oid
        }
    }

    /// Point an arbitrary ref name (e.g. a `refs/orch/parents/…` private ref) at `oid` — the effect a
    /// `fetch +<src>:<privateRef>` has, so a later `rev-parse --verify <privateRef>` resolves through the
    /// graph's rev-parse rule.
    public func setRef(_ name: String, to oid: String) {
        lock.withLock { refs[normalize(name)] = oid }
    }

    /// The current tip OID of `branch` (test-side read; never runs git).
    public func tip(_ branch: String) -> String? { lock.withLock { refs[branch] } }

    // MARK: rule installation

    /// Install `rev-parse` / `rev-list` / `merge-base` rules on `fake`. Repo-agnostic (each FakeProc is
    /// per-test/per-service): matches `git -C <repo> <sub>` and dispatches on the subcommand, returning
    /// nil for anything else (so `GitConfigEmulator`'s `["git"]` rule and later rules compose).
    public func install(on fake: FakeProc) {
        fake.on(["git", "-C"]) { [self] argv in
            guard argv.count >= 4 else { return nil }
            switch argv[3] {
            case "rev-parse":   return revParse(argv)
            case "rev-list":    return revList(argv)
            case "merge-base":  return mergeBase(argv)
            default:            return nil
            }
        }
    }

    /// `git -C <repo> rev-parse --verify --quiet <ref>` → oid+"\n" exit 0, or empty exit 1 when unknown
    /// (real git's `--verify --quiet` contract).
    private func revParse(_ argv: [String]) -> ProcResult {
        guard let ref = argv.last else { return ProcResult(stdout: "", stderr: "", exitCode: 1) }
        return lock.withLock {
            guard let oid = resolveLocked(ref) else { return ProcResult(stdout: "", stderr: "", exitCode: 1) }
            return ProcResult(stdout: oid + "\n", stderr: "", exitCode: 0)
        }
    }

    /// `git -C <repo> rev-list --count <base>..<tip>` → count+"\n" exit 0, or exit 128 (stderr) when a
    /// side is unresolvable (real git fatals — production `treeBehindStrict` maps `!r.ok` to nil, the
    /// nil-from-0 distinction it relies on).
    private func revList(_ argv: [String]) -> ProcResult {
        guard argv.count >= 6, argv[4] == "--count" else {
            return ProcResult(stdout: "", stderr: "usage: rev-list --count <range>\n", exitCode: 128)
        }
        let range = argv[5]
        let parts = range.components(separatedBy: "..")
        guard parts.count == 2 else {
            return ProcResult(stdout: "", stderr: "fatal: bad revision '\(range)'\n", exitCode: 128)
        }
        return lock.withLock {
            guard let baseOid = resolveLocked(parts[0]), let tipOid = resolveLocked(parts[1]) else {
                return ProcResult(stdout: "", stderr: "fatal: bad revision '\(range)'\n", exitCode: 128)
            }
            let n = ancestorsLocked(tipOid).subtracting(ancestorsLocked(baseOid)).count
            return ProcResult(stdout: "\(n)\n", stderr: "", exitCode: 0)
        }
    }

    /// `merge-base --is-ancestor A B` → exit 0 (ancestor) / exit 1 (not) / exit 128 (unknown ref); and
    /// plain `merge-base A B` → LCA oid+"\n" exit 0, or exit 1 empty when they share no history.
    private func mergeBase(_ argv: [String]) -> ProcResult {
        if argv.count >= 6, argv[4] == "--is-ancestor" {
            return lock.withLock {
                guard let a = resolveLocked(argv[5]), let b = resolveLocked(argv[6]) else {
                    return ProcResult(stdout: "", stderr: "fatal: Not a valid object name\n", exitCode: 128)
                }
                let isAnc = ancestorsLocked(b).contains(a)
                return ProcResult(stdout: "", stderr: "", exitCode: isAnc ? 0 : 1)
            }
        }
        guard argv.count >= 6 else { return ProcResult(stdout: "", stderr: "usage: merge-base\n", exitCode: 128) }
        return lock.withLock {
            guard let a = resolveLocked(argv[4]), let b = resolveLocked(argv[5]) else {
                return ProcResult(stdout: "", stderr: "fatal: Not a valid object name\n", exitCode: 128)
            }
            let common = ancestorsLocked(a).intersection(ancestorsLocked(b))
            guard let lca = common.max(by: { (depth[$0] ?? 0) < (depth[$1] ?? 0) }) else {
                return ProcResult(stdout: "", stderr: "", exitCode: 1)   // no shared history
            }
            return ProcResult(stdout: lca + "\n", stderr: "", exitCode: 0)
        }
    }
}

public enum RepoScripts {
    /// The `TreeStatTests.repoWithParent` arrangement over FakeProc: one base commit on `main`, a
    /// `parent` branch at that tip. Installs the RepoGraph rules on `fake` and returns the graph so the
    /// test can `advanceParent`/`amend`/`deleteBranch` and read tips. Does NOT install the config
    /// emulator — the caller shares one across lineage + graph.
    @discardableResult
    public static func withParent(on fake: FakeProc) -> RepoGraph {
        let g = RepoGraph()
        g.commit(on: "main")
        g.branch("parent", at: "main")
        g.install(on: fake)
        return g
    }

    /// Advance `parent` by `n` commits; returns the new tip (mirrors `TreeStatTests.advanceParent`).
    @discardableResult
    public static func advanceParent(_ g: RepoGraph, _ n: Int) -> String {
        for _ in 0..<n { g.commit(on: "parent") }
        return g.tip("parent")!
    }

    /// The `ShipChoreoTests.repoWithChild` arrangement: `main` + `parent` (at main's base), plus a real
    /// `child` branch off `parent` carrying one commit — enough for `merge-base(child, …)` to resolve.
    /// Returns the graph; the parent tip is `g.tip("parent")`.
    @discardableResult
    public static func withChild(on fake: FakeProc) -> RepoGraph {
        let g = withParent(on: fake)
        g.branch("child", at: "parent")
        g.commit(on: "child")
        return g
    }

    /// The remote-tier setup over FakeProc: a fresh `RepoGraph` (its rev-parse/rev-list/merge-base rules,
    /// which also answer `RemoteParents.fetch`'s trailing `rev-parse <privateRef>`) plus a `RemoteRules`
    /// (its `fetch`/`ls-remote` answers). Returns both so a suite can register reachable/gone/unreachable
    /// refs and read tips. Does NOT install the config emulator — the caller shares one across lineage,
    /// graph, and remote (mirrors `withParent`). The SAME `RemoteRules` object RemoteFetchContractTests
    /// exercises against a real `--bare` origin.
    @discardableResult
    public static func withRemote(on fake: FakeProc) -> (graph: RepoGraph, rules: RemoteRules) {
        let g = RepoGraph()
        g.install(on: fake)
        let r = RemoteRules(graph: g)
        r.install(on: fake)
        return (g, r)
    }
}

/// Scripted `fetch` / `ls-remote` answers for the isolated remote-git tier — the FakeProc analogue of a
/// real `--bare` origin. Keyed by `(remoteName, remoteSrc)`; each ref is `reachable` (a tip `ls-remote`
/// reports and `fetch` lands into its private ref), `gone` (`ls-remote` ok + empty ⇒ `RemoteTip.gone`,
/// `fetch` fails), or `unreachable` (`ls-remote` errors ⇒ `.unavailable`, `fetch` fails). Faithful to the
/// exact exit-code semantics `RemoteParents.fetch`/`lsRemoteTip` branch on:
///   - fetch: `git -C <r> fetch --no-tags <remote> +<src>:<priv>` → exit 0 lands `<priv>`, else throws.
///   - ls-remote: `git -C <r> ls-remote <remote> <src>` → first token of the first line is the tip;
///     ok + empty ⇒ `.gone`; any error ⇒ `.unavailable`.
/// A landed private ref is set in the SHARED `RepoGraph` so `RemoteParents.fetch`'s trailing
/// `rev-parse --verify <priv>` resolves. Fidelity is pinned by ContractTests/Git/RemoteFetchContractTests,
/// which runs THESE rules AND a real bare origin through the identical reachable/missing/unreachable matrix.
public final class RemoteRules: @unchecked Sendable {
    public enum Reach: Sendable { case reachable, gone, unreachable }
    private let graph: RepoGraph
    private let lock = NSLock()
    private var entries: [String: (reach: Reach, tip: String)] = [:]

    public init(graph: RepoGraph) { self.graph = graph }
    private func key(_ remote: String, _ src: String) -> String { remote + "\u{0}" + src }

    /// Mark `<remote> <src>` reachable at a freshly-minted tip (or `tip` if given); returns the tip OID —
    /// the value `ls-remote` reports and `fetch` lands into the private ref.
    @discardableResult
    public func reachable(remote: String, src: String, tip: String? = nil) -> String {
        let oid = tip ?? graph.mintCommit()
        lock.withLock { entries[key(remote, src)] = (.reachable, oid) }
        return oid
    }
    /// Branch/PR-head deleted on the remote: `ls-remote` returns ok + empty (⇒ `.gone`), `fetch` fails.
    public func gone(remote: String, src: String) {
        lock.withLock { entries[key(remote, src)] = (.gone, "") }
    }
    /// Origin path / network unreachable: `ls-remote` errors (⇒ `.unavailable`), `fetch` fails.
    public func unreachable(remote: String, src: String) {
        lock.withLock { entries[key(remote, src)] = (.unreachable, "") }
    }
    private func lookup(_ remote: String, _ src: String) -> (reach: Reach, tip: String)? {
        lock.withLock { entries[key(remote, src)] }
    }

    /// Install the `ls-remote` + `fetch` rules on `fake`. Repo-agnostic; returns nil for any other verb so
    /// the RepoGraph rev/merge rules and the config emulator compose (FakeProc falls through on nil). A ref
    /// with no registered entry also falls through (unregistered ⇒ the suite didn't script it).
    public func install(on fake: FakeProc) {
        fake.on(["git", "-C"]) { [self] argv in                        // ls-remote <remote> <src>
            guard argv.count >= 6, argv[3] == "ls-remote" else { return nil }
            guard let e = lookup(argv[4], argv[5]) else { return nil }
            switch e.reach {
            case .reachable:   return ProcResult(stdout: "\(e.tip)\t\(argv[5])\n", stderr: "", exitCode: 0)
            case .gone:        return ProcResult(stdout: "", stderr: "", exitCode: 0)
            case .unreachable: return ProcResult(stdout: "", stderr: "fatal: could not read from remote repository\n", exitCode: 128)
            }
        }
        fake.on(["git", "-C"]) { [self] argv in                        // fetch --no-tags <remote> +<src>:<priv>
            guard argv.count >= 7, argv[3] == "fetch" else { return nil }
            let remote = argv[argv.count - 2]
            let spec = argv[argv.count - 1]
            let body = spec.hasPrefix("+") ? String(spec.dropFirst()) : spec
            let parts = body.components(separatedBy: ":")
            guard parts.count == 2, let e = lookup(remote, parts[0]) else { return nil }
            switch e.reach {
            case .reachable:
                graph.setRef(parts[1], to: e.tip)                      // land the private ref
                // Real git prints a fetch summary to STDERR on a new-ref fetch ("From <remote>\n * [new ref]
                // <src> -> <priv>"), never stdout — model it so the contract's stderr-presence matches real git.
                return ProcResult(stdout: "",
                                  stderr: "From \(remote)\n * [new ref]         \(parts[0]) -> \(parts[1])\n",
                                  exitCode: 0)
            case .gone, .unreachable:
                return ProcResult(stdout: "", stderr: "fatal: couldn't find remote ref \(parts[0])\n", exitCode: 128)
            }
        }
    }
}
