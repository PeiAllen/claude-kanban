import Foundation
import Testing
@testable import OrchestraCore

/// B3 — cold-path resume-modal suppression (5866ea fold). A machine-driven `claude --resume` on an
/// old+large session opens a "Resume from summary/full" modal INSTEAD of running the seed, and with no
/// human to answer it the resume deadlocks and swallows the seed. `ClaudeCodeAdapter.env` sets the two
/// thresholds very high so the modal never triggers. Fail-soft + agent-agnostic (via the `Adapter.env`
/// seam Codex uses for `CODEX_HOME`; a build that doesn't know the vars ignores them).
@Suite("B3 · resume-modal env suppression")
struct ResumeModalEnvTests {

    @Test("claude env carries both resume-threshold overrides, set very high")
    func claudeResumeEnvSuppressesResumeModal() {
        let env = ClaudeCodeAdapter().env
        let minutes = try! #require(env["CLAUDE_CODE_RESUME_THRESHOLD_MINUTES"])
        let tokens = try! #require(env["CLAUDE_CODE_RESUME_TOKEN_THRESHOLD"])
        #expect((Int(minutes) ?? 0) >= 1_000_000)
        #expect((Int(tokens) ?? 0) >= 1_000_000)
    }

    @Test("the suppression is agent-agnostic — Codex carries no such env")
    func codexEnvUnaffected() {
        let env = CodexAdapter().env
        #expect(env["CLAUDE_CODE_RESUME_THRESHOLD_MINUTES"] == nil)
        #expect(env["CLAUDE_CODE_RESUME_TOKEN_THRESHOLD"] == nil)
    }
}
