import Foundation
import Testing
@testable import OrchestraCore

@Suite("RemoteParentRef — canonical remote base parsing")
struct RemoteParentRefTests {
    @Test("pr#N parses to a pull-request ref")
    func parsesPR() throws {
        let r = try #require(RemoteParentRef.parse("pr#12"))
        #expect(r == .pullRequest(12))
        #expect(r.remoteSrc == "refs/pull/12/head")
        #expect(r.privateName == "pr-12")
        #expect(r.privateRef == "refs/orch/parents/pr-12")
        #expect(r.canonical == "pr#12")
    }

    @Test("origin/<branch> parses to a remote branch ref (slashes preserved)")
    func parsesBranch() throws {
        let r = try #require(RemoteParentRef.parse("origin/feature/foo"))
        #expect(r == .branch("feature/foo"))
        #expect(r.remoteSrc == "refs/heads/feature/foo")
        #expect(r.privateName == "feature/foo")
        #expect(r.privateRef == "refs/orch/parents/feature/foo")
        #expect(r.canonical == "origin/feature/foo")
    }

    @Test("a plain local name is NOT a remote ref")
    func localIsNil() {
        #expect(RemoteParentRef.parse("feature-a") == nil)
        #expect(RemoteParentRef.parse("") == nil)
        #expect(RemoteParentRef.parse("pr#") == nil)      // no number
        #expect(RemoteParentRef.parse("pr#abc") == nil)   // not a number
        #expect(RemoteParentRef.parse("pr#0") == nil)     // non-positive
        #expect(RemoteParentRef.parse("origin/") == nil)  // empty branch
    }
}
