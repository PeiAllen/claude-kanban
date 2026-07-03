import Foundation
import Testing
@testable import OrchestraCore

@Suite("Trust grant seam — types")
struct TrustGrantSeamTests {
    @Test("SurfaceGrantResolver approves interactive surfaces, denies agent/daemon (autonomy-exempt)")
    func surfaceResolverGating() async {
        let r = SurfaceGrantResolver()
        for s in [ActivitySource.cli, .mcp, .app] {
            #expect(await r.requestGrant(path: "/p", reason: "x", source: s) == .approved)
        }
        for s in [ActivitySource.agent, .daemon] {
            #expect(await r.requestGrant(path: "/p", reason: "x", source: s) == .denied)
        }
    }

    @Test("TrustPrompt.isAffirmative accepts y/yes (any case), rejects everything else incl. nil/empty")
    func affirmative() {
        for yes in ["y", "Y", "yes", "YES", " yes "] { #expect(TrustPrompt.isAffirmative(yes)) }
        for no in [nil, "", "n", "no", "q", "sure"] { #expect(!TrustPrompt.isAffirmative(no)) }
    }

    @Test("nonInteractiveHelp names the path and mentions no --trust, read-only, and the interactive verb")
    func help() {
        let m = TrustPrompt.nonInteractiveHelp("/some/dir")
        #expect(m.contains("/some/dir"))
        #expect(m.contains("orchestra trust"))
        #expect(m.contains("read-only"))
        #expect(!m.contains("--trust"))   // there is NO --trust flag
    }
}

@Suite("grantTrust — the trust Command's service method")
struct GrantTrustTests {
    @Test("approved grant records a human entry and reports granted (not already-trusted)")
    func approvedRecords() async throws {
        let env = TestEnv.make(grantResolver: StubGrantResolver(.approved))
        let dir = env.base + "/borrowed-grant"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        #expect(await env.trust.isTrusted(dir) == false)
        let res = try await env.svc.grantTrust(dir, source: .cli)
        #expect(res.granted && !res.alreadyTrusted)
        #expect(await env.trust.isTrusted(dir) == true)
        // and the grant now flips resolveTrust for a borrowed card in that dir → trusted (mirrors)
        #expect(await env.svc.resolveTrust(origin: .borrowed, cwd: dir, repo: nil) == .trusted)
    }

    @Test("denied grant records NOTHING and throws trustDenied (agent/tool can't self-grant)")
    func deniedThrows() async throws {
        let env = TestEnv.make(grantResolver: StubGrantResolver(.denied))
        let dir = env.base + "/borrowed-deny"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.grantTrust(dir, source: .agent)
        }
        #expect(await env.trust.isTrusted(dir) == false)   // no self-grant
    }

    @Test("granting an already-trusted path is a no-op success (alreadyTrusted, resolver not asked)")
    func idempotent() async throws {
        let resolver = StubGrantResolver(.denied)   // would deny if asked — proves it isn't
        let env = TestEnv.make(grantResolver: resolver)
        let dir = env.base + "/pre-trusted"
        try await env.trust.record(dir, grantedBy: .human)
        let res = try await env.svc.grantTrust(dir, source: .cli)
        #expect(res.granted && res.alreadyTrusted)
        #expect(resolver.asked.isEmpty)
    }
}

@Suite("spawn — untrusted (needsGrant) actionable context")
struct UntrustedSpawnTests {
    @Test("borrowed un-ledgered spawn proceeds sandboxed AND emits an actionable needsGrant activity")
    func emitsActionableActivity() async throws {
        let env = TestEnv.make()
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())
        let dir = env.base + "/borrowed-needsgrant"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let t = try await env.svc.spawn(SpawnInput(prompt: "peek", cwd: dir, access: .readWrite))
        #expect(t.origin == .borrowed)
        #expect(await env.trust.isTrusted(dir) == false)   // still untrusted (no auto-trust, no block)
        // wait a tick for the async event fan-out, then assert an actionable warning was emitted
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        let acts = await collector.activities
        let grant = acts.first { $0.text.contains("orchestra trust") }
        #expect(grant != nil)
        #expect(grant?.text.contains(dir) == true)
    }
}

@Suite("resolveTrust — scratch external-intake demotion")
struct ScratchDemotionTests {
    @Test("an empty scratch dir still auto-trusts (unchanged)")
    func emptyScratchAutoTrusts() async throws {
        let env = TestEnv.make()
        let cwd = env.base + "/scratch-empty"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        #expect(await env.svc.resolveTrust(origin: .scratch, cwd: cwd, repo: nil) == .trusted)
    }

    @Test("a scratch dir that has become a foreign repo (.git present) demotes to borrowed → needsGrant")
    func clonedScratchDemotes() async throws {
        let env = TestEnv.make()
        let cwd = env.base + "/scratch-cloned"
        try FileManager.default.createDirectory(atPath: cwd + "/.git", withIntermediateDirectories: true)
        #expect(await env.svc.resolveTrust(origin: .scratch, cwd: cwd, repo: nil) == .needsGrant)
        // ...and once a human grants it, it's trusted (re-entered the grant path, didn't auto-trust)
        try await env.trust.record(cwd, grantedBy: .human)
        #expect(await env.svc.resolveTrust(origin: .scratch, cwd: cwd, repo: nil) == .trusted)
    }
}

@Suite("trust Command — registry dispatch")
struct TrustCommandTests {
    @Test("trust command records via grantTrust when the (surface) source approves")
    func commandGrants() async throws {
        let env = TestEnv.make(grantResolver: StubGrantResolver(.approved))
        let dir = env.base + "/cmd-grant"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cmd = try #require(CommandRegistry().command("trust"))
        let out = try await cmd.run(env.svc, .object(["path": .string(dir)]), .cli)
        #expect(try out.decode(TrustGrantResult.self).granted)
        #expect(await env.trust.isTrusted(dir) == true)
    }

    @Test("trust command grants for an app source (the SpawnSheet's Trust this directory button)")
    func commandGrantsFromApp() async throws {
        // The app is a human grant surface — the user clicking "Trust this directory" in the spawn
        // sheet arrives as an `.app`-sourced `trust` command, which SurfaceGrantResolver approves with
        // no further prompt. This is the exact backend contract BoardModel.trust(path:) relies on.
        let env = TestEnv.make(grantResolver: SurfaceGrantResolver())
        let dir = env.base + "/cmd-grant-app"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cmd = try #require(CommandRegistry().command("trust"))
        let out = try await cmd.run(env.svc, .object(["path": .string(dir)]), .app)
        #expect(try out.decode(TrustGrantResult.self).granted)
        #expect(await env.trust.isTrusted(dir) == true)
    }

    @Test("trust command surfaces trustDenied when the agent source can't self-grant")
    func commandDenies() async throws {
        let env = TestEnv.make(grantResolver: StubGrantResolver(.denied))
        let dir = env.base + "/cmd-deny"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cmd = try #require(CommandRegistry().command("trust"))
        await #expect(throws: OrchestraError.self) {
            _ = try await cmd.run(env.svc, .object(["path": .string(dir)]), .agent)
        }
    }
}
