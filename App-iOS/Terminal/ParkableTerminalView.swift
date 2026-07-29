import UIKit
import SwiftTerm

/// A SwiftTerm `TerminalView` that can *park* its rendering — stop per-frame paint and freeze the caret
/// blink — while the byte channel keeps feeding the emulator, so the buffer is current the instant the
/// user returns. The phone parks far less than the desktop already: SwiftTerm's iOS side pauses its
/// `CADisplayLink` between feed bursts and self-parks the caret when detached from a window, and iOS
/// suspends a truly backgrounded scene. This closes the remaining gap — a scene that's inactive (app
/// switcher, iPad multitasking) or a terminal driven off-screen while output still streams — and keeps
/// the parking model identical to the desktop's `ScrollableTerminalView`.
///
/// SwiftTerm is a read-only dependency, so — exactly as on the desktop — we intercept at the two public
/// seams a subclass owns: the `setNeedsDisplay(_:)` funnel every redraw routes through (swallowed while
/// parked, marking a single deferred repaint), and the caret's perpetual animation, frozen by halting the
/// layer's timeline (`layer.speed = 0`, which stops every animation in this view's layer subtree). The
/// caret's own blink API is `internal` to SwiftTerm and unreachable from here. Metal is not enabled, so
/// `setNeedsDisplay` is the sole paint path.
final class ParkableTerminalView: TerminalView {
    /// See `TerminalRenderParkingPolicy`. True → stop painting + freeze the caret; the view stays mounted
    /// and its channel keeps feeding. Unpark thaws the timeline and coalesces one full repaint.
    var renderingParked = false {
        didSet {
            guard renderingParked != oldValue else { return }
            if renderingParked {
                layer.speed = 0
            } else {
                layer.speed = 1
                layer.beginTime = 0
                if deferredRedraw {
                    deferredRedraw = false
                    super.setNeedsDisplay(bounds)
                }
            }
        }
    }
    /// Set while parked whenever SwiftTerm asked to redraw; consumed by a single repaint on unpark.
    private var deferredRedraw = false

    override func setNeedsDisplay() {
        if renderingParked { deferredRedraw = true; return }
        super.setNeedsDisplay()
    }

    override func setNeedsDisplay(_ rect: CGRect) {
        if renderingParked { deferredRedraw = true; return }
        super.setNeedsDisplay(rect)
    }
}
