import Foundation
import Testing
import TestSupport
import OrchestraKit
@testable import OrchestraCore

@Suite("OrchestraService+Shared — result text, policy verb, cwd → card")
struct OrchestraServiceSharedTests {
    private func msg(_ v: JSONValue) -> String { v["message"]?.stringValue ?? "" }

    @Test("a conflict tells the agent the exact command that resolves it")
    func conflictNamesResolve() {
        let v = SharedResult.sync(.conflicted(paths: ["CLAUDE.md"], storeSha: "abc"))
        #expect(v["outcome"]?.stringValue == "conflicted")
        #expect(msg(v).contains("orchestra shared resolve"))
        #expect(msg(v).contains("CLAUDE.md"))
    }

    @Test("resolve while markers remain is refused and names the path")
    func refusedMarkersNamesPath() {
        let v = SharedResult.resolve(.refusedMarkers(paths: ["AGENTS.md"]))
        #expect(v["outcome"]?.stringValue == "refusedMarkers")
        #expect(msg(v).contains("AGENTS.md"))
    }

    @Test("adopt stopped by a remaining negation names the leaf")
    func adoptNegation() {
        let v = SharedResult.adopt(.stopped(.negationRemains(paths: [".claude/commands/ship.md"])))
        #expect(v["outcome"]?.stringValue == "negationRemains")
        #expect(v["paths"]?.arrayValue?.first?.stringValue == ".claude/commands/ship.md")
    }

    @Test("status carries the read-only git command and the standing conflict")
    func statusJSONShape() {
        let s = PropagationStatus(repo: "/r", items: [ItemStatus(name: "claude", policy: .shared, paths: ["CLAUDE.md"])],
                                  unignoredLeaves: [], conflict: ConflictRecord(paths: ["CLAUDE.md"], storeSha: "s"),
                                  readCommand: "GIT_OPTIONAL_LOCKS=0 git --git-dir=/g")
        let v = OrchestraService.statusJSON(s)
        #expect(v["readCommand"]?.stringValue == "GIT_OPTIONAL_LOCKS=0 git --git-dir=/g")
        #expect(v["outcome"]?.stringValue == "conflicted")
        #expect(v["items"]?.arrayValue?.count == 1)
    }

    @Test("resolve reports a pre-commit refusal as not resolved")
    func resolveRefusalsAreNotResolved() {
        for o in [ResolveOutcome.sendOutcome(.refusedOutOfSet(paths: ["x"])), .sendOutcome(.partial(dirty: ["y"]))] {
            let v = SharedResult.resolve(o)
            #expect(v["outcome"]?.stringValue != "resolved")
            #expect(msg(v).contains("still stands"))
            #expect(v["paths"]?.arrayValue?.count == 1)
        }
        #expect(SharedResult.resolve(.sendOutcome(.pushed))["outcome"]?.stringValue == "resolved")
    }

    @Test("a git older than 2.40 has its own outcome, distinct from a real stand-down")
    func gitTooOldOutcome() {
        #expect(SharedResult.sync(.standDown(.gitTooOld))["outcome"]?.stringValue == "gitTooOld")
        #expect(SharedResult.sync(.standDown(.policyLoadFailed))["outcome"]?.stringValue == "standDown")
    }

    @Test("adopt paths must be plain repo-relative paths")
    func adoptPathValidation() throws {
        try OrchestraService.validateAdoptPaths(["CLAUDE.md", ".claude/commands/ship.md", "docs"])
        for bad in [".", "..", "../x", "a/../b", "/etc/passwd", "", "a//b", "a/", "./a"] {
            #expect(throws: OrchestraError.self, "\(bad)") { try OrchestraService.validateAdoptPaths([bad]) }
        }
        #expect(throws: OrchestraError.self) {
            try OrchestraService.validateAdoptPaths((0...OrchestraService.adoptMaxPaths).map { "f\($0)" })
        }
    }

    @Test("a read-only card cannot adopt")
    func readOnlyCannotAdopt() async throws {
        let env = TestEnv.make()
        var card = Task(id: UUID(), title: "t", repo: "/repo", branch: "b", cwd: "/repo/wt",
                        model: AgentModel(id: "m"), startIn: .impl, column: .impl, order: 0,
                        phase: .live(.running), initialPrompt: "p")
        card.access = .readOnly
        await #expect(throws: OrchestraError.self) {
            try await env.svc.shared(op: "adopt", card: card, paths: [], source: .daemon)
        }
    }

    @Test("cwd containment picks the deepest card, and never a sibling with a shared prefix")
    func cardContainingDeepest() {
        func card(_ cwd: String) -> Task {
            Task(id: UUID(), title: cwd, repo: "/repo", branch: "b", cwd: cwd,
                 model: AgentModel(id: "m"), startIn: .impl, column: .impl, order: 0,
                 phase: .live(.running), initialPrompt: "p")
        }
        let outer = card("/tmp/ck-a/wt"), inner = card("/tmp/ck-a/wt/sub"), sibling = card("/tmp/ck-a/wt2")
        let all = [outer, inner, sibling]
        #expect(OrchestraService.cardContaining(cwd: "/tmp/ck-a/wt/sub/deep", in: all)?.id == inner.id)
        #expect(OrchestraService.cardContaining(cwd: "/tmp/ck-a/wt/other", in: all)?.id == outer.id)
        #expect(OrchestraService.cardContaining(cwd: "/tmp/ck-b", in: all) == nil)
    }

    @Test("shared-policy reads the table, sets one row, and rejects bad input")
    func policyVerb() async throws {
        let env = TestEnv.make(registry: AgentRegistry(adapters: [ClaudeCodeAdapter(), CodexAdapter()]))
        let repo = TestEnv.repo(env.base)
        let table = try await env.svc.sharedPolicy(repo: repo, item: nil, policy: nil)
        let names = (table["items"]?.arrayValue ?? []).compactMap { $0["item"]?.stringValue }
        #expect(names.contains("claude") && names.contains("codex"))

        let row = try await env.svc.sharedPolicy(repo: repo, item: "codex", policy: "ephemeral")
        #expect(row["policy"]?.stringValue == "ephemeral")
        // Persisted, and readable back through the same verb.
        let again = try await env.svc.sharedPolicy(repo: repo, item: "codex", policy: nil)
        #expect(again["policy"]?.stringValue == "ephemeral")

        await #expect(throws: OrchestraError.self) { try await env.svc.sharedPolicy(repo: repo, item: "nope", policy: nil) }
        await #expect(throws: OrchestraError.self) { try await env.svc.sharedPolicy(repo: repo, item: "codex", policy: "bogus") }
    }

    @Test("shared-policy never overwrites a corrupt propagation.json")
    func policyRefusesCorruptFile() async throws {
        let env = TestEnv.make(registry: AgentRegistry(adapters: [ClaudeCodeAdapter(), CodexAdapter()]))
        let repo = TestEnv.repo(env.base)
        let path = env.base + "/propagation.json"
        try "{ not json".write(toFile: path, atomically: true, encoding: .utf8)
        await #expect(throws: OrchestraError.self) { try await env.svc.sharedPolicy(repo: repo, item: "codex", policy: "shared") }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "{ not json")
    }
}
