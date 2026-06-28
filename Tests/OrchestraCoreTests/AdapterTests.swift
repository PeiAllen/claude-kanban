import Foundation
import Testing
@testable import OrchestraCore

@Suite("ClaudeCodeAdapter — argv & session identity")
struct AdapterTests {

    let adapter = ClaudeCodeAdapter()

    @Test("registry get/list and unknown throws")
    func registry() throws {
        let reg = AgentRegistry()
        #expect(try reg.get("claude-code").id == "claude-code")
        #expect(throws: OrchestraError.self) { try reg.get("nope") }
        #expect(reg.list().contains { $0.id == "claude-code" })
    }

    @Test("models() returns non-empty ids")
    func models() {
        #expect(!adapter.models().isEmpty)
    }

    @Test("newSessionId mints a valid UUID")
    func sessionId() throws {
        let id = try #require(adapter.newSessionId())
        #expect(UUID(uuidString: id) != nil)
    }

    @Test("start(ctx) is [String] carrying model, plan flag, --session-id, --settings, --name, and the prompt")
    func startArgv() {
        let ctx = AdapterContext(cwd: "/wt", model: "claude-sonnet-4-6", startIn: .plan,
                                 sessionId: "the-id", prompt: "Add OAuth login\nwith Google",
                                 name: nil, hooksPath: "/hooks.json")
        let argv = adapter.start(ctx)
        #expect(argv.first == "claude")
        #expect(argv.contains("--model"))
        #expect(argv.contains("claude-sonnet-4-6"))
        #expect(adjacent(argv, "--permission-mode", "auto"))   // plan column → auto mode
        #expect(adjacent(argv, "--session-id", "the-id"))
        #expect(adjacent(argv, "--settings", "/hooks.json"))
        // --name defaults to the prompt's first line (== Task.title seed)
        #expect(adjacent(argv, "--name", "Add OAuth login"))
        // the prompt is the launch positional arg (last element, full text)
        #expect(argv.last == "Add OAuth login\nwith Google")
    }

    @Test("restart-style start: ctx.name preserved, NO positional prompt")
    func startNameOverride() {
        // restart hands name = preserved title and prompt = nil (blank session).
        let ctx = AdapterContext(cwd: "/wt", sessionId: "id", prompt: nil, name: "Preserved Title")
        let argv = adapter.start(ctx)
        #expect(adjacent(argv, "--name", "Preserved Title"))
        // The only occurrence of the title string is the --name value; there is no trailing prompt.
        #expect(argv.filter { $0 == "Preserved Title" }.count == 1)
        #expect(argv.last == "Preserved Title")  // last token is the --name value, not a prompt
    }

    @Test("resume(ctx) is --resume <id> --settings --name, NO --session-id, NO prompt")
    func resumeArgv() throws {
        let ctx = AdapterContext(cwd: "/wt", model: "claude-opus-4-8", sessionId: "sess-9",
                                 prompt: "should be ignored", name: "Title", hooksPath: "/h.json")
        let argv = try #require(adapter.resume(ctx))
        #expect(adjacent(argv, "--resume", "sess-9"))
        #expect(adjacent(argv, "--settings", "/h.json"))
        #expect(adjacent(argv, "--name", "Title"))
        #expect(adjacent(argv, "--model", "claude-opus-4-8"))
        #expect(!argv.contains("--session-id"))
        #expect(!argv.contains("should be ignored"))
    }

    @Test("resume returns nil without a session id")
    func resumeNilNoId() {
        let ctx = AdapterContext(cwd: "/wt", sessionId: nil)
        #expect(adapter.resume(ctx) == nil)
    }

    @Test("sessionInfo (assigned) gives exact transcript + resume argv")
    func sessionInfoAssigned() throws {
        let ctx = AdapterContext(cwd: "/Users/x/wt/app/feat", sessionId: "abc", name: "T")
        let info = try #require(adapter.sessionInfo(ctx, current: "abc", prior: ["old1"]))
        #expect(info.sessionId == "abc")
        let tp = try #require(info.transcriptPath)
        #expect(tp.contains("/.claude/projects/"))
        #expect(tp.hasSuffix("/abc.jsonl"))
        // cwd slug uses '-' for '/'
        #expect(tp.contains("-Users-x-wt-app-feat"))
        #expect(info.priorSessionIds == ["old1"])
        #expect(info.resumeCmd?.contains("--resume") == true)
    }

    @Test("sessionInfo returns nil session id when nothing is known and no transcript exists")
    func sessionInfoFallbackNil() {
        let ctx = AdapterContext(cwd: "/nonexistent/\(UUID().uuidString)", sessionId: nil)
        let info = adapter.sessionInfo(ctx, current: nil, prior: [])
        #expect(info?.sessionId == nil)
    }

    // True iff `flag` is immediately followed by `value` in argv.
    private func adjacent(_ argv: [String], _ flag: String, _ value: String) -> Bool {
        guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return false }
        return argv[i + 1] == value
    }
}
