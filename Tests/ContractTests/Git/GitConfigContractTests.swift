//
// The license for every emulator-backed unit suite (LineageTests and the branch-tree/merge-collab
// conversions): it runs the SAME `GitConfigEmulator` object those suites use (imported from TestSupport,
// not a copy) through the full `git config` operation matrix, AND runs the identical matrix against real
// `git config` in a private temp repo, asserting the two agree on (exitCode, stdout-shape, stderr-
// presence). If real git's porcelain drifts, this fails and the mocks are known to be lying.

import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

@Suite("Contract: GitConfigEmulator vs real git config")
struct GitConfigContractTests {

    /// (exitCode, the SET of non-empty trimmed stdout lines — order-independent shape, since real git's
    /// `--get-regexp` emits config-file order while the emulator sorts, stderr-present).
    private struct Shape: Equatable { let exit: Int32; let lines: Set<String>; let hasStderr: Bool }
    private func shape(_ r: ProcResult) -> Shape {
        Shape(exit: r.exitCode,
              lines: Set(r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                             .filter { !$0.isEmpty }),
              hasStderr: !r.stderr.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// A real git repo under a private temp dir (HOME is already redirected by GitHermeticBootstrap).
    private func realRepo() throws -> String {
        let dir = NSTemporaryDirectory() + "gitconfig-contract-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        #expect(try Proc.run(["git", "-C", dir, "init", "-q", "-b", "main"]).ok)
        return dir
    }

    @Test("set / get / unset / get-regexp — present & missing — match real git")
    func matrix() async throws {
        // The two runners: both take the args that follow `git … config`.
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        let fakeRepo = "/repo"
        let realDir = try realRepo()

        func runFake(_ a: [String]) async throws -> ProcResult {
            try await fake.run(["git", "-C", fakeRepo, "config"] + a, cwd: nil, env: [:], timeout: nil)
        }
        func runReal(_ a: [String]) throws -> ProcResult {
            try Proc.run(["git", "-C", realDir, "config"] + a)
        }

        // Each step's config args, applied in order to BOTH backends. Mutating steps keep the two stores
        // in lockstep so every read compares like against like.
        let steps: [(label: String, args: [String])] = [
            ("set parent",              ["branch.child.orchestra-parent", "feature-a"]),
            ("get present",             ["--get", "branch.child.orchestra-parent"]),
            ("get missing",             ["--get", "branch.child.nope"]),
            ("set base",                ["branch.child.orchestra-parent-base", "cafe"]),
            ("set second child",        ["branch.other.orchestra-parent", "feature-a"]),
            ("get-regexp match",        ["--get-regexp", "^branch\\..*\\.orchestra-parent$"]),
            ("get-regexp none",         ["--get-regexp", "^branch\\..*\\.no-such-key$"]),
            ("unset present",           ["--unset", "branch.child.orchestra-parent"]),
            ("unset missing",           ["--unset", "branch.child.orchestra-parent"]),
            ("get after unset",         ["--get", "branch.child.orchestra-parent"]),
        ]
        for step in steps {
            let f = shape(try await runFake(step.args))
            let r = shape(try runReal(step.args))
            #expect(f == r, "config \(step.label): emulator \(f) != real git \(r)")
        }
    }
}
