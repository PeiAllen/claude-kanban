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
