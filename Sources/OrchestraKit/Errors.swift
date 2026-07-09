import Foundation

/// Typed errors surfaced over the control plane (mapped to JSON-RPC error objects).
public enum OrchestraError: Error, CustomStringConvertible, Sendable, Equatable {
    case unknownTask(String)
    case ambiguousTask(String)
    case unknownAgent(String)
    case pathNotAllowed(String)
    case branchInUse(String)
    case parentAlreadyBorrowed(String)   // O3: a sibling holds the bare parent's borrow — wait + retry
    case toolMissing(String)          // git / tmux / claude / zed not on PATH
    case worktreeDirty(String)
    case resumeFailed(String)
    case zedMissing
    case invalidParams(String)
    case io(String)
    case trustDenied(String)
    case ownershipDenied(String)   // CAS failure: release/heartbeat by a non-current epoch/clientId

    public var description: String {
        switch self {
        case .unknownTask(let r):   return "unknown task: \(r)"
        case .ambiguousTask(let r): return "ambiguous task ref: \(r)"
        case .unknownAgent(let a):  return "unknown agent: \(a)"
        case .pathNotAllowed(let p):return "path not allowed: \(p)"
        case .branchInUse(let b):   return "branch \(b) is already checked out in another worktree — "
                                         + "spawn onto a new branch, or use the existing card that owns it"
        case .parentAlreadyBorrowed(let b):
            return "parent \(b) is already borrowed (another child is landing) — wait for the sync "
                + "nudge after it ships, merge the parent down, then retry your ship"
        case .toolMissing(let t):   return "required tool not found: \(t)"
        case .worktreeDirty(let p): return "worktree has uncommitted changes: \(p)"
        case .resumeFailed(let d):  return "resume failed: \(d)"
        case .zedMissing:           return "Zed not found"
        case .invalidParams(let m): return "invalid params: \(m)"
        case .io(let m):            return "io error: \(m)"
        case .trustDenied(let m):   return "trust not granted: \(m)"
        case .ownershipDenied(let m): return "ownership denied: \(m)"
        }
    }

    /// Wrap raw git stderr in the agent-readable failure contract — WHAT failed (`object`), WHY (`stderr`,
    /// git's own words), and the runnable NEXT STEP (`recovery`) — as a classified `.io`. The cause clause
    /// is dropped when git said nothing; the recovery clause when there is no next step to name.
    public static func gitIO(_ object: String, stderr: String, recovery: String? = nil) -> OrchestraError {
        let cause = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        var msg = object
        if !cause.isEmpty { msg += " (git: \(cause))" }
        if let recovery, !recovery.isEmpty { msg += " — \(recovery)" }
        return .io(msg)
    }

    /// Stable JSON-RPC-ish error code for the control plane.
    public var code: Int {
        switch self {
        case .invalidParams:    return -32602
        case .unknownTask:      return 1001
        case .ambiguousTask:    return 1002
        case .unknownAgent:     return 1003
        case .pathNotAllowed:   return 1004
        case .branchInUse:      return 1005
        case .parentAlreadyBorrowed: return 1013
        case .toolMissing:      return 1006
        case .worktreeDirty:    return 1007
        case .resumeFailed:     return 1008
        case .zedMissing:       return 1009
        case .io:               return 1010
        case .trustDenied:      return 1011
        case .ownershipDenied:  return 1012
        }
    }
}
