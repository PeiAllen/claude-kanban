// MOVES-TO: ContractTests/Git — RepoGraph fidelity matrix
//
// The license for every RepoGraph-backed unit suite (TreeStat, StaleNudge, SetParentMove, TreeCommand,
// and the merge-collab conversions): it runs the SAME `RepoGraph` rules those suites use (imported from
// TestSupport) AND real git over an identically-shaped repo, asserting the two agree on the exit-code
// CLASSES the production tree probes depend on — `rev-parse --verify --quiet` (known vs unknown ref),
// `rev-list --count A..B` (a real count, and the 0-vs-fatal distinction `treeBehindStrict` relies on),
// `merge-base --is-ancestor` (ancestor=0 / non-ancestor=1 / unknown-ref=128, the three classes
// `treeBaseIsAncestor` discriminates).

import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

@Suite("Contract: RepoGraph vs real git rev-parse / rev-list / merge-base")
struct GitRevContractTests {

    /// A real repo: `main` base commit, a `parent` branch, then +2 commits on parent. Returns the repo
    /// dir plus parent's tip BEFORE (`base`) and AFTER (`tip`) the two commits.
    private func realRepo() throws -> (dir: String, base: String, tip: String) {
        let dir = NSTemporaryDirectory() + "gitrev-contract-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func git(_ a: String...) throws -> String {
            let r = try Proc.run(["git", "-C", dir] + a)
            #expect(r.ok, "git \(a.joined(separator: " ")): \(r.stderr)")
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ s: String, _ rel: String) throws { try s.write(toFile: dir + "/" + rel, atomically: true, encoding: .utf8) }
        _ = try git("init", "-q", "-b", "main")
        _ = try git("config", "user.email", "t@t"); _ = try git("config", "user.name", "t")
        try write("0\n", "a.txt"); _ = try git("add", "-A"); _ = try git("commit", "-q", "-m", "base")
        _ = try git("branch", "parent")
        let base = try git("rev-parse", "parent")
        _ = try git("checkout", "-q", "parent")
        for i in 0..<2 { try write("x", "p\(i).txt"); _ = try git("add", "-A"); _ = try git("commit", "-q", "-m", "p\(i)") }
        let tip = try git("rev-parse", "parent")
        return (dir, base, tip)
    }

    /// (exitCode, stdout is non-empty, an Int count if stdout parses to one, stderr present).
    private struct Shape: Equatable {
        let exit: Int32; let stdoutNonEmpty: Bool; let count: Int?; let hasStderr: Bool
    }
    private func shape(_ r: ProcResult) -> Shape {
        let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Shape(exit: r.exitCode, stdoutNonEmpty: !s.isEmpty, count: Int(s),
                     hasStderr: !r.stderr.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test("rev-parse / rev-list --count / merge-base --is-ancestor match real git")
    func matrix() async throws {
        let real = try realRepo()
        let fake = FakeProc()
        let g = RepoScripts.withParent(on: fake)
        let gBase = g.tip("parent")!
        RepoScripts.advanceParent(g, 2)
        let gTip = g.tip("parent")!

        // A query is a name + the two argv builders (each side supplies its own oids). Compared by shape.
        struct Query { let label: String; let real: [String]; let fake: [String] }
        func q(_ label: String, real rArgs: [String], fake fArgs: [String]) -> Query {
            Query(label: label, real: ["git", "-C", real.dir] + rArgs, fake: ["git", "-C", "/repo"] + fArgs)
        }
        let queries = [
            q("rev-parse known ref",
              real: ["rev-parse", "--verify", "--quiet", "refs/heads/parent"],
              fake: ["rev-parse", "--verify", "--quiet", "refs/heads/parent"]),
            q("rev-parse unknown ref",
              real: ["rev-parse", "--verify", "--quiet", "refs/heads/nope"],
              fake: ["rev-parse", "--verify", "--quiet", "refs/heads/nope"]),
            q("rev-list --count N",
              real: ["rev-list", "--count", "\(real.base)..\(real.tip)"],
              fake: ["rev-list", "--count", "\(gBase)..\(gTip)"]),
            q("rev-list --count 0",
              real: ["rev-list", "--count", "\(real.tip)..\(real.tip)"],
              fake: ["rev-list", "--count", "\(gTip)..\(gTip)"]),
            q("rev-list --count unknown ref",
              real: ["rev-list", "--count", "refs/heads/nope..\(real.tip)"],
              fake: ["rev-list", "--count", "refs/heads/nope..\(gTip)"]),
            q("merge-base --is-ancestor (ancestor)",
              real: ["merge-base", "--is-ancestor", real.base, real.tip],
              fake: ["merge-base", "--is-ancestor", gBase, gTip]),
            q("merge-base --is-ancestor (non-ancestor)",
              real: ["merge-base", "--is-ancestor", real.tip, real.base],
              fake: ["merge-base", "--is-ancestor", gTip, gBase]),
            q("merge-base --is-ancestor (unknown ref)",
              real: ["merge-base", "--is-ancestor", "refs/heads/nope", real.tip],
              fake: ["merge-base", "--is-ancestor", "refs/heads/nope", gTip]),
        ]
        for query in queries {
            let r = shape(try Proc.run(query.real))
            let f = shape(try await fake.run(query.fake, cwd: nil, env: [:], timeout: nil))
            #expect(f == r, "\(query.label): RepoGraph \(f) != real git \(r)")
        }
    }
}
