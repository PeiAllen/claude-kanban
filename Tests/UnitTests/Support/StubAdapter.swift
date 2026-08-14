import Foundation
import TestSupport
@testable import OrchestraCore

/// An adapter whose transcript path is under a test-controlled dir, so resumable/transcript-exists is
/// fully controllable. Registered with id "claude-code" so `spawn` finds it.
extension AgentCapabilities {
    /// The default test-stub capability: Claude-shaped on every axis EXCEPT readiness confirmation, which
    /// is `.relaunchLiveness` so a blank spawn/reopen and a resume both land immediately on a successful
    /// `ensure` — no readiness signal to hand-deliver. This keeps the many tests that spawn/resume a card
    /// merely as SETUP green and synchronous under 2.6's capability-gated launch readiness. Tests that
    /// specifically exercise the awaited signal path opt into `.claudeCode` (`.sessionStartHook`) or
    /// `.codex` (`.rolloutMeta`) explicitly.
    static let stub = AgentCapabilities(
        sessionId: .seeded, telemetry: .hooksPush, contextUsage: .percent,
        wakeTransport: .nativeReinvoke, inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed, authMode: .subscription,
        terminalImagePaste: .controlV, readinessConfirmation: .relaunchLiveness)

    /// `.stub` but with `fileTail` telemetry — for the tests that exercise the Codex-shaped polling-lag
    /// paths (the `needs-input` turn-start fence, the permission seq-fence) without standing up a real
    /// Codex adapter. Readiness stays `.relaunchLiveness` so spawn/resume still land synchronously.
    static let fileTailStub = AgentCapabilities(
        sessionId: .seeded, telemetry: .fileTail, contextUsage: .percent,
        wakeTransport: .nativeReinvoke, inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed, authMode: .subscription,
        terminalImagePaste: .controlV, readinessConfirmation: .relaunchLiveness)
}

final class StubAdapter: Adapter, @unchecked Sendable {
    let id: String
    let name: String
    let icon = "sparkle"
    let bin = "fake-agent"
    let enabled = true
    let capabilities: AgentCapabilities
    let transcriptDir: String
    /// The stub's model catalog. Per-instance so a test can stand up two adapters with DISJOINT catalogs
    /// and prove a cross-adapter `--model` (a Codex id on a claude-code card) is rejected.
    let modelIds: [String]
    init(transcriptDir: String, capabilities: AgentCapabilities = .stub,
         id: String = "claude-code", name: String = "Stub", modelIds: [String] = ["m1", "m2", "m3"]) {
        self.transcriptDir = transcriptDir
        self.capabilities = capabilities
        self.id = id
        self.name = name
        self.modelIds = modelIds
    }

    func models() -> [AgentModel] { modelIds.map { AgentModel(id: $0) } }
    func newSessionId() -> String? { UUID().uuidString.lowercased() }
    /// Both argv builders emit the model flag from `ctx.model`, like the real adapters
    /// (ClaudeCodeAdapter `--model`, Codex `-m`) — so a test can assert which model a launch actually
    /// went up on. Emitted BEFORE the trailing prompt/seed positional, again like the real ones.
    private func modelFlag(_ model: String?) -> [String] {
        guard let m = model, !m.isEmpty else { return [] }
        return ["--model", m]
    }
    /// The read-only posture, emitted on BOTH launch paths like the real adapters (Claude's locked-down
    /// tool list, Codex's `-s read-only -a never`) — so a test can prove a read-only card stays read-only
    /// across a resume, not only on the spawn that created it.
    private func accessFlags(_ access: CardAccess) -> [String] {
        access == .readOnly ? ["--read-only"] : []
    }
    func start(_ ctx: AdapterContext) -> [String] {
        var a = [bin]
        if let s = ctx.sessionId { a += ["--session-id", s] }
        if let n = ctx.name { a += ["--name", n] }
        a += accessFlags(ctx.access)
        a += modelFlag(ctx.model)
        if let p = ctx.prompt { a.append(p) }
        return a
    }
    func resume(_ ctx: AdapterContext) -> [String]? {
        guard let s = ctx.sessionId else { return nil }
        var a = [bin, "--resume", s, "--name", ctx.name ?? ""]
        a += accessFlags(ctx.access)
        a += modelFlag(ctx.model)
        if let seed = ctx.seed, !seed.isEmpty { a.append(seed) }   // F1: deliver the seed like real adapters
        return a
    }
    /// A recognizable, NON-Claude parse: turns a tailed line into a marker report, proving parse is
    /// per-adapter (a Claude adapter returns nil for the same `.fileTail` raw).
    func parse(_ raw: RawTelemetry) -> StatusReport? {
        if case let .fileTail(line) = raw { return StatusReport(desc: "tail:\(line)") }
        return nil
    }
    func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo? {
        let sid = current
        return AgentSessionInfo(agentId: id, sessionId: sid,
                                transcriptPath: sid.map { "\(transcriptDir)/\($0).jsonl" },
                                priorSessionIds: prior, priorTranscripts: [],
                                resumeCmd: sid.map { [bin, "--resume", $0] })
    }
    func writeTranscript(for sessionId: String) {
        try? FileManager.default.createDirectory(atPath: transcriptDir, withIntermediateDirectories: true)
        try? "{}".write(toFile: "\(transcriptDir)/\(sessionId).jsonl", atomically: true, encoding: .utf8)
    }
    func deleteTranscript(for sessionId: String) {
        try? FileManager.default.removeItem(atPath: "\(transcriptDir)/\(sessionId).jsonl")
    }
}
