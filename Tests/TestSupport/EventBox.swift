import Foundation
import OrchestraCore

/// A minimal async-safe event sink for round-trip / subscription tests: collect pushed `Event`s and
/// assert on them. Shared test support (round-trip suites live in both the unit and contract tiers).
public actor EventBox {
    public private(set) var events: [Event] = []
    public init() {}
    public func add(_ e: Event) { events.append(e) }
}
