import Foundation
import Testing
@testable import OrchestraCore

@Suite("SessionStart orientation — SessionBrief")
struct SessionBriefTests {

    // MARK: sentence content — column + mode + self-id

    @Test("each column names its phase and the card id")
    func perColumn() {
        let plan = SessionBrief.sentence(column: .plan, access: .readWrite, shortId: "abc123")
        let impl = SessionBrief.sentence(column: .impl, access: .readWrite, shortId: "abc123")
        let review = SessionBrief.sentence(column: .review, access: .readWrite, shortId: "abc123")
        #expect(plan.contains("Plan") && plan.contains("abc123"))
        #expect(impl.contains("Implementation") && impl.contains("abc123"))
        #expect(review.contains("Review") && review.contains("abc123"))
        // The self-move hint carries the card's own id so `move` has a ref.
        #expect(plan.contains("move abc123 --col"))
    }

    @Test("read-only adds the no-mutation clause; read/write does not")
    func readOnlyClause() {
        let ro = SessionBrief.sentence(column: .impl, access: .readOnly, shortId: "d00d")
        let rw = SessionBrief.sentence(column: .impl, access: .readWrite, shortId: "d00d")
        #expect(ro.lowercased().contains("read-only"))
        #expect(!rw.lowercased().contains("read-only"))
    }

    // (SessionStart envelope encoding is covered by HookChannelTests — HookEnvelope.additionalContext.)

    // MARK: service reads the LIVE column (not launch-time startIn)

    @Test("sessionBrief reflects the card's current column after a move")
    func liveColumn() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "work", repo: repo, branch: "feat"))

        _ = try await env.svc.move(task.id, to: .review)
        let reviewed = try #require(await env.svc.sessionBrief(task.id))
        #expect(reviewed.contains("Review"))

        _ = try await env.svc.move(task.id, to: .impl)
        let building = try #require(await env.svc.sessionBrief(task.id))
        #expect(building.contains("Implementation"))
    }

    @Test("sessionBrief is nil for an unknown card")
    func unknownNil() async {
        let env = TestEnv.make()
        #expect(await env.svc.sessionBrief(UUID()) == nil)
    }

    // MARK: launch — orientation rides the SessionStart hook, NOT the launch positional

    @Test("spawn never folds orientation into the launch positional (the hook delivers it)")
    func noPositionalFold() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "build the thing", repo: repo, branch: "cl"))
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        // The positional is exactly the user's prompt — no orientation text prepended.
        #expect(argv.last == "build the thing")
    }
}

@Suite("Codex SessionStart hook install (CodexHooks)")
struct CodexHooksTests {
    private func tmp() -> String { NSTemporaryDirectory() + "cxhooks-\(UUID().uuidString)" }
    private let rendered = #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/bin/orchestra _report --event session --agent codex"}]}]}}"#

    @Test("installs into an absent hooks.json")
    func writesWhenAbsent() throws {
        let dest = tmp() + "/.codex/hooks.json"
        #expect(CodexHooks.installIfSafe(content: rendered, to: dest) == true)
        let got = try String(contentsOfFile: dest, encoding: .utf8)
        #expect(got.contains(CodexHooks.sentinel))
    }

    @Test("idempotent: overwrites our own file")
    func idempotentForOurs() throws {
        let dest = tmp() + "/hooks.json"
        #expect(CodexHooks.installIfSafe(content: rendered, to: dest) == true)
        #expect(CodexHooks.installIfSafe(content: rendered, to: dest) == true)   // still ours → rewrite
    }

    @Test("never clobbers a foreign user hooks.json")
    func skipsForeign() throws {
        let dest = tmp() + "/hooks.json"
        let mine = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"my-own-script"}]}]}}"#
        try FileManager.default.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try mine.write(toFile: dest, atomically: true, encoding: .utf8)
        #expect(CodexHooks.installIfSafe(content: rendered, to: dest) == false)
        #expect(try String(contentsOfFile: dest, encoding: .utf8) == mine)   // untouched
    }

    @Test("renderCodex substitutes the orchestra bin + agent id and emits the session command")
    func renderCodexSubstitutes() throws {
        let dest = tmp() + "/codex-hooks.json"
        _ = try HooksRenderer.renderCodex(orchestraBin: "/abs/orchestra", agentId: "codex", to: dest)
        let got = try String(contentsOfFile: dest, encoding: .utf8)
        #expect(got.contains("/abs/orchestra _report --event session --agent codex"))
        #expect(!got.contains("__ORCHESTRA_BIN__"))
        #expect(!got.contains("__AGENT_ID__"))
        #expect(!got.contains(#""matcher""#))
    }
}
