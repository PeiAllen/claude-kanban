import Foundation
import OrchestraCore

/// In-memory `git config` semantics for FakeProc: --get (exit 1 when missing), set, --unset,
/// --get-regexp (KEY SP VALUE lines, exit 1 when nothing matches). Enough for BranchLineage,
/// whose every op is `git -C <repo> config ...`. Registers a broad ["git"] rule that handles
/// ONLY `git -C <repo> config ...` shapes and returns nil for everything else, so
/// fetch/rev-parse/merge-base rules registered before OR after compose (FakeProc rules fall
/// through on nil). Fidelity is pinned by ContractTests/Git/GitConfigContractTests (later task),
/// which runs the same operation matrix against real git.
public final class GitConfigEmulator: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: [String: String]] = [:]   // repo -> key -> value

    public init() {}

    public func install(on fake: FakeProc) {
        fake.on(["git"]) { [self] argv in
            guard argv.count >= 4, argv[1] == "-C", argv[3] == "config" else { return nil }
            let repo = argv[2]
            let rest = Array(argv.dropFirst(4))
            return lock.withLock { handle(repo: repo, rest: rest) }
        }
    }

    private func handle(repo: String, rest: [String]) -> ProcResult {
        func ok(_ s: String = "") -> ProcResult { ProcResult(stdout: s, stderr: "", exitCode: 0) }
        func miss() -> ProcResult { ProcResult(stdout: "", stderr: "", exitCode: 1) }
        switch rest.first {
        case "--get":
            guard rest.count == 2, let v = store[repo]?[rest[1]] else { return miss() }
            return ok(v + "\n")
        case "--unset":
            guard rest.count == 2, store[repo]?[rest[1]] != nil else {
                // real git: --unset of a missing key exits 5
                return ProcResult(stdout: "", stderr: "", exitCode: 5)
            }
            store[repo]?[rest[1]] = nil
            return ok()
        case "--get-regexp":
            guard rest.count == 2, let re = try? NSRegularExpression(pattern: rest[1]) else { return miss() }
            let hits = (store[repo] ?? [:])
                .filter { re.firstMatch(in: $0.key, range: NSRange($0.key.startIndex..., in: $0.key)) != nil }
                .sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
            return hits.isEmpty ? miss() : ok(hits.joined(separator: "\n") + "\n")
        default:
            guard rest.count == 2 else { return miss() }
            store[repo, default: [:]][rest[0]] = rest[1]
            return ok()
        }
    }
}
