import Foundation
import OrchestraCore

/// Scripted, recording, gateable `ProcRunning`. Rules match by argv PREFIX in registration
/// order; a rule may return nil to FALL THROUGH (so the GitConfigEmulator's broad ["git"] rule
/// composes with later fetch/rev-parse rules). Unmatched calls get `defaultResult` (exit 0,
/// empty output) so incidental probes never fail a test that doesn't care about them. Every
/// call is recorded for intent assertions.
///
/// Respond closures run OUTSIDE the internal lock (a closure may re-enter the fake).
public final class FakeProc: ProcRunning, @unchecked Sendable {
    public struct Call: Sendable, Equatable {
        public let argv: [String]
        public let cwd: String?
    }

    private struct Rule {
        let prefix: [String]
        let respond: ([String]) -> ProcResult?
    }

    private let lock = NSLock()
    private var rules: [Rule] = []
    private var gates: [(prefix: [String], gate: Gate)] = []
    private var defaultResult = ProcResult(stdout: "", stderr: "", exitCode: 0)
    private var _calls: [Call] = []

    public init() {}
    public var calls: [Call] { lock.withLock { _calls } }

    /// Register a rule for calls whose argv starts with `prefix`. Return nil to fall through
    /// to the next matching rule (or the default).
    public func on(_ prefix: [String], _ respond: @escaping ([String]) -> ProcResult?) {
        lock.withLock { rules.append(Rule(prefix: prefix, respond: respond)) }
    }

    public func onDefault(_ result: ProcResult) {
        lock.withLock { defaultResult = result }
    }

    /// Install a one-shot park on the next call whose argv starts with `prefix`. The gate's
    /// release value REPLACES any scripted response for that call.
    public func gate(on prefix: [String]) -> Gate {
        let g = Gate()
        lock.withLock { gates.append((prefix, g)) }
        return g
    }

    @discardableResult
    public func run(_ argv: [String], cwd: String?, env: [String: String], timeout: Duration?) async throws -> ProcResult {
        let (gate, candidateRules, fallback): (Gate?, [Rule], ProcResult) = lock.withLock {
            _calls.append(Call(argv: argv, cwd: cwd))
            var g: Gate? = nil
            if let i = gates.firstIndex(where: { argv.starts(with: $0.prefix) }) {
                g = gates.remove(at: i).gate
            }
            return (g, rules.filter { argv.starts(with: $0.prefix) }, defaultResult)
        }
        if let gate { return await gate.park() }
        for rule in candidateRules {                       // outside the lock — re-entrant-safe
            if let r = rule.respond(argv) { return r }
        }
        return fallback
    }
}
