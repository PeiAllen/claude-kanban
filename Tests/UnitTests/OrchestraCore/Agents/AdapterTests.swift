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
    func startArgv() throws {
        let ctx = AdapterContext(cwd: "/wt", model: "claude-sonnet-5", startIn: .plan,
                                 sessionId: "the-id", prompt: "Add OAuth login\nwith Google",
                                 name: nil, orchestraMCPBin: "/abs/orchestra-mcp")
        let argv = adapter.start(ctx)
        #expect(argv.first == "claude")
        #expect(argv.contains("--model"))
        #expect(argv.contains("claude-sonnet-5"))
        #expect(adjacent(argv, "--permission-mode", "auto"))   // plan column → auto mode
        #expect(adjacent(argv, "--session-id", "the-id"))
        #expect(adjacent(argv, "--settings", Config.hooksPath))
        #expect(adjacent(argv, "--mcp-config",
                         MCPConfiguration.claudeJSON(command: "/abs/orchestra-mcp")))
        #expect(!argv.contains("--strict-mcp-config"))
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
                                 prompt: "should be ignored", name: "Title",
                                 orchestraMCPBin: "/abs/orchestra-mcp")
        let argv = try #require(adapter.resume(ctx))
        #expect(adjacent(argv, "--resume", "sess-9"))
        #expect(adjacent(argv, "--settings", Config.hooksPath))
        #expect(adjacent(argv, "--mcp-config",
                         MCPConfiguration.claudeJSON(command: "/abs/orchestra-mcp")))
        #expect(!argv.contains("--strict-mcp-config"))
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

    @Test("transcript slug maps EVERY non-alphanumeric char to '-' (matches Claude's real encoding)")
    func transcriptSlugDottedCwd() throws {
        // Claude Code names the transcript dir by replacing every non-alphanumeric char in the cwd
        // with '-' — dots included, with NO collapsing of consecutive separators. Every Orchestra
        // worktree lives under '~/.orchestra/…', so '/.orchestra' must slug to '--orchestra' (the
        // leading '/' AND the '.' each become a '-'). Getting this wrong points resume/isResumable
        // at a nonexistent path and silently downgrades reopen/recover to a blank restart.
        let ctx = AdapterContext(cwd: "/Users/dev/.orchestra/worktrees/app/feat", sessionId: "abc", name: "T")
        let info = try #require(adapter.sessionInfo(ctx, current: "abc", prior: []))
        let tp = try #require(info.transcriptPath)
        #expect(tp.contains("-Users-dev--orchestra-worktrees-app-feat"))
        #expect(!tp.contains(".orchestra"))   // the dot must NOT survive in the slug
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

@Suite("ClaudeCodeAdapter — shared guidance skill materialization")
struct ClaudeDelegationTests {
    private func tmpCwd() -> String {
        let d = NSTemporaryDirectory() + "claude-deleg-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }
    private func skillPath(_ cwd: String, section: String) -> String {
        "\(cwd)/.claude/skills/orchestra-\(section)/SKILL.md"
    }

    @Test("prepareToLaunch writes every shared Claude guidance section under .claude/skills")
    func materializesSkills() throws {
        let cwd = tmpCwd(); defer { try? FileManager.default.removeItem(atPath: cwd) }
        try ClaudeCodeAdapter().prepareToLaunch(AdapterContext(cwd: cwd))
        let sections = AgentGuidance.sections(for: "claude-code")
        #expect(sections.map(\.name) == ["delegation", "tree", "image-publishing"])
        for section in sections {
            let text = try String(contentsOfFile: skillPath(cwd, section: section.name), encoding: .utf8)
            #expect(text == section.content)
        }
    }

    @Test("shared skill materialization is idempotent across launches")
    func idempotent() throws {
        let cwd = tmpCwd(); defer { try? FileManager.default.removeItem(atPath: cwd) }
        let a = ClaudeCodeAdapter()
        try a.prepareToLaunch(AdapterContext(cwd: cwd))
        try a.prepareToLaunch(AdapterContext(cwd: cwd))
        for section in AgentGuidance.sections(for: "claude-code") {
            #expect(try String(contentsOfFile: skillPath(cwd, section: section.name), encoding: .utf8)
                    == section.content)
        }
    }

    @Test("prepareToLaunch degrades gracefully (no throw) when cwd is unwritable")
    func gracefulOnBadCwd() {
        #expect(throws: Never.self) {
            try ClaudeCodeAdapter().prepareToLaunch(AdapterContext(cwd: "/System/nope-\(UUID().uuidString)"))
        }
    }

    @Test("global MCP installation is opt-in and add-only")
    func globalMCPInstallIsOptIn() throws {
        let home = tmpCwd()
        let cwd = tmpCwd()
        defer {
            try? FileManager.default.removeItem(atPath: home)
            try? FileManager.default.removeItem(atPath: cwd)
        }
        let path = home + "/.claude.json"
        let adapter = ClaudeCodeAdapter(claudeHome: home)

        try adapter.prepareToLaunch(AdapterContext(cwd: cwd, orchestraMCPBin: "/abs/orchestra-mcp"))
        #expect(!FileManager.default.fileExists(atPath: path))

        try adapter.prepareToLaunch(AdapterContext(cwd: cwd, orchestraMCPBin: "/abs/orchestra-mcp",
                                                   autoInstallMCPGlobally: true))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect((servers["orchestra"] as? [String: Any])?["command"] as? String == "/abs/orchestra-mcp")
    }

    @Test("start(ctx) argv + env are unchanged by the added materialization")
    func argvUnchanged() throws {
        let cwd = tmpCwd(); defer { try? FileManager.default.removeItem(atPath: cwd) }
        let a = ClaudeCodeAdapter()
        let ctx = AdapterContext(cwd: cwd, model: "claude-sonnet-5", startIn: .plan,
                                 sessionId: "sid", prompt: "do it", name: nil)
        let before = a.start(ctx)
        try a.prepareToLaunch(ctx)
        #expect(a.start(ctx) == before)                          // byte-identical argv
        #expect(a.env.isEmpty)                                   // Claude adds no env
    }
}
