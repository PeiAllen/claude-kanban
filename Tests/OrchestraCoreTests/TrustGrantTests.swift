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
