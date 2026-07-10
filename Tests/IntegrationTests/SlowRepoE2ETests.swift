import Foundation
import Testing
@testable import OrchestraCore

/// PR7 (cross-cutting) — SMOKE, not the regression guard. Every race exercised here has a deterministic
/// stub test in a prior PR (`test_concurrentSameBranchEnsureJoins` — PR3b; `test_actorNotBlockedByExec`/
/// `_byLivenessList` — PR5; `test_spawnDrivesPhases` — PR2). This just proves the shipped machinery holds
/// together over a REAL git checkout + REAL tmux.
enum SlowRepoFixture {
    /// Absolute path to the bundled generator script.
    static var scriptPath: String {
        Bundle.module.path(forResource: "Fixtures/gen-slow-repo", ofType: "sh")
            ?? Bundle.module.path(forResource: "gen-slow-repo", ofType: "sh") ?? ""
    }

    /// Generate a slow repo of `count` files at `<base>/repos/app`; returns the canonical repo path.
    /// Default is 12k (not the plan's 28k): 12k already yields a multi-second `git worktree add`
    /// (~4-10s here) — far above the ~0.8s a borrowed card needs to overtake it — while keeping
    /// generation cheap (~15-20s vs ~80s for 28k). Generation cost is O(files), so the count trades
    /// checkout margin against setup time; 12k is the balance point (as-built deviation, see the vault).
    @discardableResult
    static func generate(base: String, count: Int = 12_000) throws -> String {
        let repo = base + "/repos/app"
        try FileManager.default.createDirectory(atPath: base + "/repos", withIntermediateDirectories: true)
        let r = try Proc.run(["/bin/bash", scriptPath, repo, String(count)])
        guard r.exitCode == 0 else {
            throw OrchestraError.io("gen-slow-repo failed: \(r.stderr)")   // `.io`, not `.internalError` (no such case)
        }
        return PathResolver.canonical(repo)
    }
}

@Suite("Slow-repo fixture sanity", .enabled(if: IntegrationSupport.gitAvailable), .serialized)
struct SlowRepoFixtureTests {
    @Test("generator produces a large committed working tree")
    func fixtureGeneratesSlowCheckout() throws {
        #expect(!SlowRepoFixture.scriptPath.isEmpty)
        let base = IntegrationSupport.tempDir("slowfix")
        defer { try? FileManager.default.removeItem(atPath: base) }
        // A small count keeps this sanity test fast; the E2E uses the 12k default (see `generate`).
        let repo = try SlowRepoFixture.generate(base: base, count: 2_000)
        let n = try Proc.checked(["git", "-C", repo, "ls-files"]).stdout
            .split(whereSeparator: \.isNewline).count
        #expect(n >= 2_000)
        // HEAD is a single commit on main
        let head = try Proc.checked(["git", "-C", repo, "rev-parse", "--abbrev-ref", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(head == "main")
    }
}
