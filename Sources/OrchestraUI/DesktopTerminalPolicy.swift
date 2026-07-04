import Foundation
import OrchestraKit

/// Pure desktop-side rules for the agent-terminal ownership lease (PR D5). The daemon (PR D4) is the
/// authority for *who* owns a card's `agent` terminal; these functions decide what the **desktop** does
/// about it — whether to render the live terminal or a "Taken over by phone" placeholder, whether
/// selecting a card should claim `desktopOwned`, and whether a phone owner has gone stale.
///
/// AppKit-free and dependency-free (takes primitives, not the D4 RPC struct) so it lives in the
/// client-safe `OrchestraUI` layer, compiles for iOS as well as macOS (so the phone side — PR T4 — can
/// reuse the same rules), and is exercised directly by `swift test` (`OrchestraUITests`).

/// What the desktop should render for a card's agent terminal.
public enum DesktopTerminalDecision: Equatable {
    case mount        // attach the live AgentTerminalView
    case placeholder  // tear the terminal down, show "Taken over by phone" + Retake
}

/// Render decision: a phone owner means the desktop shows the placeholder and must NOT attach to the same
/// tmux `agent` window (a tmux window has one size — two attached clients at different sizes resize-fight).
///
/// `isStale` does **not** change mount-vs-placeholder: a stale phone owner is still the placeholder. The
/// desktop recovers via an explicit Retake, never by silently stealing the lease (the fail-safe default).
/// The staleness only shifts the placeholder's copy/affordance (Retake → Force Retake) in the view.
public func desktopTerminalDecision(ownerKind: AgentTerminalOwnerKind?, isStale: Bool) -> DesktopTerminalDecision {
    ownerKind == .phone ? .placeholder : .mount
}

/// Whether selecting/mounting this card should CAS the lease to `desktopOwned`.
/// - available             → yes, claim it.
/// - desktopOwned by me    → no (avoid a redundant RPC on every hjkl re-select — no select-churn spam).
/// - desktopOwned by other → yes (desktops cooperate; the just-selected client takes the size).
/// - phoneOwned            → no (never auto-steal from a phone; Retake is explicit).
public func shouldAcquireDesktopOwnership(ownerKind: AgentTerminalOwnerKind?,
                                          ownerClientId: String?,
                                          desktopClientId: String) -> Bool {
    switch ownerKind {
    case .none:    return true
    case .phone:   return false
    case .desktop: return ownerClientId != desktopClientId
    }
}

/// How long after an owner's last heartbeat the desktop treats it as stale. D4's server reports its own
/// `stale` in query/event snapshots; this constant lets the desktop derive staleness locally too, so the
/// Force-Retake affordance appears without waiting for a fresh server snapshot.
public let agentTerminalStaleTimeout: TimeInterval = 30

/// Local staleness derivation for a phone owner: stale if the server already says so, OR the owner's last
/// update is older than `agentTerminalStaleTimeout`. Pure (takes `now`) so it is deterministically testable.
public func isAgentTerminalStale(updatedAt: Date, serverStale: Bool, now: Date) -> Bool {
    serverStale || now.timeIntervalSince(updatedAt) > agentTerminalStaleTimeout
}
