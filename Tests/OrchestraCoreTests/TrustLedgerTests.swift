import Foundation
import Testing
@testable import OrchestraCore

@Suite("TrustLedger — durable path store")
struct TrustLedgerTests {
    private func tmpPath() -> String {
        NSTemporaryDirectory() + "trust-\(UUID().uuidString)/ledger.json"
    }

    @Test("unrecorded path is untrusted; recorded path is trusted")
    func recordThenTrusted() async throws {
        let ledger = TrustLedger(path: tmpPath())
        let p = "/some/repo"
        #expect(await ledger.isTrusted(p) == false)
        let added = try await ledger.record(p, grantedBy: .human)
        #expect(added == true)
        #expect(await ledger.isTrusted(p) == true)
    }

    @Test("record is idempotent (second record returns false, still trusted)")
    func recordIdempotent() async throws {
        let ledger = TrustLedger(path: tmpPath())
        let p = "/repo/x"
        #expect(try await ledger.record(p, grantedBy: .orchestra) == true)
        #expect(try await ledger.record(p, grantedBy: .orchestra) == false)
        #expect(await ledger.isTrusted(p) == true)
    }

    @Test("ledger persists across restart (new instance, same path)")
    func persistsAcrossRestart() async throws {
        let path = tmpPath()
        do {
            let ledger = TrustLedger(path: path)
            try await ledger.record("/persisted/repo", grantedBy: .repoRegistration)
        }
        let reopened = TrustLedger(path: path)   // simulates a daemon restart
        #expect(await reopened.isTrusted("/persisted/repo") == true)
    }

    @Test("keys are canonicalized (/tmp == /private/tmp on macOS)")
    func canonicalKeys() async throws {
        let ledger = TrustLedger(path: tmpPath())
        let raw = NSTemporaryDirectory() + "canon-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        try await ledger.record(raw, grantedBy: .human)
        #expect(await ledger.isTrusted(PathResolver.canonical(raw)) == true)
    }

    @Test("malformed ledger file → treated as empty, moved to .bak")
    func malformedResetsToEmpty() async throws {
        let path = tmpPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "not json".write(toFile: path, atomically: true, encoding: .utf8)
        let ledger = TrustLedger(path: path)
        #expect(await ledger.isTrusted("/anything") == false)
        #expect(FileManager.default.fileExists(atPath: path + ".bak"))
    }
}

@Suite("resolveTrust — origin → decision")
struct ResolveTrustTests {
    @Test("scratch auto-trusts and records the cwd in the ledger")
    func scratchAutoTrusts() async throws {
        let env = TestEnv.make()
        let cwd = env.base + "/scratch-xyz"
        let d = await env.svc.resolveTrust(origin: .scratch, cwd: cwd, repo: nil)
        #expect(d == .trusted)
        #expect(await env.trust.isTrusted(cwd) == true)   // recorded
    }

    @Test("worktree inherits the source-repo entry (trusted; repo recorded)")
    func worktreeInheritsRepo() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base, "app")
        // A repo already registered in the ledger → its worktree inherits trust.
        try await env.trust.record(repo, grantedBy: .repoRegistration)
        let wt = env.base + "/worktrees/app/feat"
        let d = await env.svc.resolveTrust(origin: .worktree, cwd: wt, repo: repo)
        #expect(d == .trusted)
    }

    @Test("worktree with an unregistered repo records it then trusts (registration IS the trust act)")
    func worktreeRecordsRepo() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base, "fresh")
        #expect(await env.trust.isTrusted(repo) == false)
        let d = await env.svc.resolveTrust(origin: .worktree, cwd: env.base + "/worktrees/fresh/x", repo: repo)
        #expect(d == .trusted)
        #expect(await env.trust.isTrusted(repo) == true)   // now registered
    }

    @Test("borrowed in the ledger = trusted; else = needsGrant")
    func borrowedConditional() async throws {
        let env = TestEnv.make()
        let inLedger = env.base + "/borrowed-trusted"
        let notInLedger = env.base + "/borrowed-unknown"
        try await env.trust.record(inLedger, grantedBy: .human)
        #expect(await env.svc.resolveTrust(origin: .borrowed, cwd: inLedger, repo: nil) == .trusted)
        #expect(await env.svc.resolveTrust(origin: .borrowed, cwd: notInLedger, repo: nil) == .needsGrant)
    }
}
