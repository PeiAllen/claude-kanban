import Foundation
import OrchestraCore

/// Scriptable gh double: a fixed PrState (or nil), an availability flag, and a recorded editBase call.
/// Shared test support — the remote-watch/recompute unit suites and the real-git LadderTests contract
/// suite all drive the gh DECISION through this fake; only the git/remote layer differs between tiers.
public final class FakeGh: GhClient, @unchecked Sendable {
    public let available: Bool
    private let lock = NSLock()
    public var state: PrState?
    public var headPR: Int?
    private(set) var editedBase: (number: Int, base: String)?
    public init(available: Bool = true, state: PrState? = nil, headPR: Int? = nil) {
        self.available = available; self.state = state; self.headPR = headPR
    }
    private(set) var prStateCalls = 0
    public func prState(repo: String, number: Int) async -> PrState? {
        lock.withLock { prStateCalls += 1; return state }
    }
    public func prNumber(repo: String, head: String) async -> Int? { lock.withLock { headPR } }
    public func editBase(repo: String, number: Int, base: String) async -> Bool {
        lock.withLock { editedBase = (number, base) }; return true
    }
    public var recordedEdit: (number: Int, base: String)? { lock.withLock { editedBase } }
    public var stateCallCount: Int { lock.withLock { prStateCalls } }
}
