// Idle-CPU gate — one seam both the desktop (App/) and the phone (App-iOS/) drive so that the board's
// perpetual decorations (breathing status dots, the running shimmer) and its live age/stall clocks stop
// burning CoreAnimation + the compositor whenever nobody is looking. See docs/09 (animation policy).

import SwiftUI

/// Whether decorative, perpetual animations and live `TimelineView` ticks should run in this subtree.
///
/// The host apps set it false when the window is occluded/miniaturized or the app is backgrounded
/// (macOS: `NSWindow.occlusionState` + `NSApp.isActive`; iOS: `scenePhase != .active`). Every pulse /
/// shimmer / age-clock reads it and parks itself when it's false, so an idle board off-screen sits near
/// 0% CPU instead of driving a per-frame animation storm through WindowServer.
///
/// Defaults to `true` so previews, `ImageRenderer` snapshot hooks, and unit tests render exactly as before
/// — nothing that never installs a host monitor has to know this exists.
private struct AnimationsActiveKey: EnvironmentKey { static let defaultValue = true }

public extension EnvironmentValues {
    var animationsActive: Bool {
        get { self[AnimationsActiveKey.self] }
        set { self[AnimationsActiveKey.self] = newValue }
    }
}

/// A `TimelineSchedule` wrapper that stops emitting future entries while `paused`.
///
/// Wrapping a card's periodic age/stall clock in this pauses the per-card re-layout that the clock would
/// otherwise drive forever (once a second, board-wide) while the window is occluded/background. When it
/// un-pauses, SwiftUI re-reads the schedule against the *current* date and renders immediately, so a stale
/// "· 3s" stamp corrects the moment the window comes forward — no catch-up burst, no visible lag.
public struct PausableTimelineSchedule<Base: TimelineSchedule>: TimelineSchedule {
    let base: Base
    let paused: Bool

    public init(_ base: Base, paused: Bool) {
        self.base = base
        self.paused = paused
    }

    public func entries(from startDate: Date, mode: Mode) -> AnyIterator<Date> {
        if paused {
            // One entry (now) so the current label is correct, then nothing — no scheduled wakeups.
            var emitted = false
            return AnyIterator { emitted ? nil : { emitted = true; return startDate }() }
        }
        var it = base.entries(from: startDate, mode: mode).makeIterator()
        return AnyIterator { it.next() }
    }
}

/// The board's breathing status dot (ccPulse: opacity 1↔`dim`, optional scale 1↔`scaleTo`), consolidated
/// from the three near-identical copies the desktop card, the desktop toolbar, and the phone card each had.
///
/// It breathes only while `active` (the card is running/waiting) **and** `animationsActive` — so N of these
/// on a populated board collapse to zero running animations the instant the window is occluded, and a dot
/// scrolled out of a lazy list stops when its `onDisappear` fires. Parking it settles `on` back to rest
/// under a short finite animation, which is what actually cancels the perpetual `repeatForever` presentation
/// (re-driving the animated value without the repeat is the documented way to end it).
public struct PulseDot: View {
    let color: Color
    var size: CGFloat = 6
    var active: Bool = true
    /// Resting-vs-dim opacity floor (0.35 desktop, 0.4 phone).
    var dim: Double = 0.35
    /// Scale at the dim end, or nil for opacity-only (the phone's 7px dot doesn't scale).
    var scaleTo: CGFloat? = 0.78
    /// Half-period of one breath.
    var period: Double = 0.85

    @Environment(\.animationsActive) private var animationsActive
    @State private var on = false

    public init(color: Color, size: CGFloat = 6, active: Bool = true,
                dim: Double = 0.35, scaleTo: CGFloat? = 0.78, period: Double = 0.85) {
        self.color = color
        self.size = size
        self.active = active
        self.dim = dim
        self.scaleTo = scaleTo
        self.period = period
    }

    /// Breathe only when the card wants it AND the window is live.
    private var running: Bool { active && animationsActive }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(active ? (on ? dim : 1) : 1)
            .scaleEffect(active ? (on ? (scaleTo ?? 1) : 1) : 1)
            .onAppear { sync() }
            .onDisappear { park() }
            .onChange(of: running) { _, _ in sync() }
    }

    private func sync() {
        if running {
            withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) { on = true }
        } else {
            park()
        }
    }

    /// Settle to rest without a repeat, which ends the perpetual animation.
    private func park() {
        withAnimation(.easeOut(duration: 0.2)) { on = false }
    }
}
