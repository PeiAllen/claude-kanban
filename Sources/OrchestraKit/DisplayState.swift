import Foundation

/// A UI action a surface can offer. A verb is just its catalog name (so `validActions` derives straight
/// from `CommandCatalog` with no parallel table); the statics give call sites type-checked spelling.
public struct Verb: Hashable, Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

extension Verb {
    // Catalog-backed — rawValue MUST equal the `CommandSchema.name` it gates.
    public static let move = Verb("move")
    public static let send = Verb("send")
    public static let archive = Verb("archive")
    public static let reopen = Verb("reopen")
    public static let restart = Verb("restart")
    public static let resume = Verb("resume")
    public static let shell = Verb("shell")
    public static let inspect = Verb("inspect")
    public static let mergeRequest = Verb("merge-request")
    // UI-only extra (no catalog verb): opening the worktree notes is a local file op.
    public static let openNotes = Verb("openNotes")
}

/// The ONE render contract every surface consumes (mac, iOS, CLI). Pure + `Equatable` → table-tested.
/// `label`/`statusKey` come from `phase`; `validActions` from the catalog's `phaseGate` (gated to empty
/// when the link is down); `isBusy` marks a being-born phase; `isStale` feeds the offline banner/dim.
public struct DisplayState: Equatable, Sendable {
    public let statusKey: PhaseDisplayKey
    public let label: String
    public let validActions: Set<Verb>
    public let isBusy: Bool
    public let isStale: Bool
    public init(statusKey: PhaseDisplayKey, label: String, validActions: Set<Verb>,
                isBusy: Bool, isStale: Bool) {
        self.statusKey = statusKey; self.label = label; self.validActions = validActions
        self.isBusy = isBusy; self.isStale = isStale
    }
}

/// Derive the render contract from a card's `phase` and the board's link `connection`. Pure — no I/O,
/// no clock. `phase == nil` (card not yet known) reads as a being-born card.
public func displayState(phase: Phase?, connection: ConnectionState) -> DisplayState {
    let key = phase?.displayKey ?? .starting
    let live = (connection == .live)

    var actions = Set<Verb>()
    if live, let phase {
        // Derived from the catalog — a verb is dispatchable iff its phaseGate admits this phase's kind.
        // (No hand-copied table; the catalog is the single source of truth.)
        let kind = phase.kind
        for schema in CommandCatalog.all where schema.phaseGate.contains(kind) {
            actions.insert(Verb(schema.name))
        }
        // "Open notes" is NOT a local file op — it's a daemon RPC (`BoardStore.openNotes` → `client.call`)
        // that fails link-down — so it belongs INSIDE the connected gate like every other action (the
        // contract is "validActions empty when the link is down"). It also needs a materialized cwd: a
        // being-born card has no worktree yet; a spawn-failed card never got one.
        if cwdMaterialized(phase) { actions.insert(.openNotes) }
    }

    let busy = (key == .starting || key == .launching || key == .relaunching)
    return DisplayState(statusKey: key, label: key.label,
                        validActions: actions, isBusy: busy, isStale: !live)
}

/// Does this phase have a materialized worktree cwd (so local file affordances like notes apply)?
private func cwdMaterialized(_ phase: Phase?) -> Bool {
    switch phase {
    case .launching, .live, .relaunching: return true
    case .dead(let reason):               return reason != .spawnFailed
    default:                              return false   // creatingWorktree, archived, nil
    }
}
