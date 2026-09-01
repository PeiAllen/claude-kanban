import SwiftUI
import OrchestraKit
#if canImport(SwiftTerm)
import SwiftTerm
#endif

// Supporting NSView/delegate types for `AgentTerminalView` that don't need to live in the main file —
// split out to keep AgentTerminalView.swift under the project's 750-line guideline.

#if canImport(SwiftTerm)
/// Owns pointer-event routing for a single embedded `ScrollableTerminalView` — this, not the terminal
/// itself, is `AgentTerminalView`'s actual `NSViewRepresentable` result.
///
/// AppKit hit-tests once per real pointer event during `NSWindow.sendEvent`, on the native `NSView`
/// tree — cheap, and it never touches SwiftUI's graph. This view claims that hit test for its own
/// bounds when the terminal's own surface would otherwise answer (see `hitTest` below), so scroll/
/// click/drag events for it are dispatched straight here, then either handled locally or forwarded to
/// the terminal with a plain method call.
///
/// This replaces a former app-wide `NSEvent` local monitor that re-hit-tested `window.contentView` (the
/// SwiftUI-hosted window root) on EVERY matching event ANYWHERE in the app, to find out whether the
/// pointer happened to be over some terminal. That second, manual hit test forced a synchronous SwiftUI
/// graph flush (`NSHostingView.hitTest`) on every trackpad tick — measured at several milliseconds each
/// — which pegged the main thread solid under fast scrolling, including in views with no terminal at
/// all (e.g. the diff inspector). Claiming `hitTest` locally, per terminal instance, gets the same
/// routing decision from AppKit's own already-cheap per-event dispatch instead.
///
/// `scrollWheel`/`mouseDown`/`mouseUp`/`mouseDragged` all route through here — `hitTest` is positional,
/// not event-typed, so once this view claims a point for one event type it claims it for all of them,
/// and `mouseDown`/`mouseUp`/`mouseDragged` need the same handling either way even though SwiftTerm
/// would let `ScrollableTerminalView` override those three directly (see its doc comment).
///
/// `mouseMoved` is deliberately NOT overridden here, because it would be dead code: AppKit never
/// hit-tests a mouse-moved event the way it does the other four. It goes either straight to the
/// window's first responder (when `NSWindow.acceptsMouseMovedEvents` is set) or to whatever `NSView`
/// owns the `NSTrackingArea` the pointer is inside — both of which name a specific view directly and
/// skip `hitTest` entirely. SwiftTerm's own tracking area names the terminal itself as the owner, so a
/// mouse-moved event reaches it no matter what this wrapper does. Confirmed with a real `NSWindow`
/// dispatching synthetic events directly (no OS-level input injection needed): a `mouseMoved` sent at a
/// point inside this view's bounds calls the wrapped terminal's `mouseMoved`, never this view's.
///
/// Net effect on the hover-swallow this view's monitor predecessor used to provide: SwiftTerm's own
/// `shouldTrackMouse()` already gates its tracking area on Command being held or `linkHighlightMode ==
/// .hover(WithModifier)` — Orchestra sets `.alwaysWithModifier`, so today mouse-moved reaches the
/// terminal only while Command is down, where it now shows SwiftTerm's native hover link preview/
/// highlight (a cosmetic change, not the phantom-click bug: reaching tmux requires `sendMotionEvent()`,
/// true only in `.anyEvent` mouse-reporting mode, which nothing here requests). If a future TUI ever
/// asks tmux for `.anyEvent` (DECSET 1003), `shouldTrackMouse()` also becomes unconditionally true and
/// the original bug (buttonless motion misread as a click) would return with nothing to stop it — a
/// registry-based `mouseMoved`-only monitor could close that gap, but it reintroduces the same
/// z-order/clipping mis-routing the rejected rect-containment alternative had (see `ScrollableTerminalView`'s
/// doc comment), so it isn't done here; flagging it as a known limitation instead.
final class TerminalEventRoutingView: NSView {
    let terminalView: ScrollableTerminalView

    init(terminalView: ScrollableTerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        terminalView.frame = bounds
        terminalView.autoresizingMask = [.width, .height]   // always fills this view, resize included
        addSubview(terminalView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Never become first responder itself — a click must focus the wrapped terminal (which needs real
    /// keyboard focus to receive typed input), not this routing shim. AppKit's own
    /// auto-first-responder-on-click would otherwise target whichever view `hitTest` returns, which is
    /// now this one; `mouseDown` below assigns the terminal explicitly instead.
    override var acceptsFirstResponder: Bool { false }

    /// Claim a point only when the terminal's own surface would answer for it — never when a subview
    /// SwiftTerm manages directly (its scrollback `NSScroller`, find bar, URL preview field, or marked-
    /// text overlay) would. Those aren't reachable today under tmux attach (`canScroll` is permanently
    /// false in the alternate screen buffer, and Orchestra never shows the find bar), but claiming them
    /// unconditionally would silently break them the moment that stops being true. The default `hitTest`
    /// recursion (via `super`) already resolves correctly through `MacCaretView` (which returns `nil`
    /// from its own `hitTest` and falls through to the terminal) — this only narrows WHICH resolved
    /// target gets redirected to `self`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === terminalView ? self : hit
    }

    override func scrollWheel(with event: NSEvent) {
        if terminalView.handleScroll(event) { return }   // consumed: forwarded to tmux
        terminalView.scrollWheel(with: event)             // let SwiftTerm scroll its own buffer natively
    }

    override func mouseDown(with event: NSEvent) {
        // Notify the owner so `focusZone` (and the inspector focus ring / chip) tracks the mouse click
        // regardless of what happens next, then let the click reach SwiftTerm — except a Command-click
        // on a link, which stays out of tmux entirely so a preview never becomes a provider-TUI click.
        terminalView.onBecameFirstResponder?()
        if terminalView.hasCommandLink(at: event) { return }
        window?.makeFirstResponder(terminalView)
        terminalView.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { terminalView.endDragMotion() }   // next drag always reports its first cell, click or not
        // SwiftTerm handles explicit OSC 8 links itself under `.alwaysWithModifier`. The visible
        // fallback is an implicit URL, so activate that one deliberately here without re-enabling
        // passive hover tracking.
        if terminalView.activateImplicitCommandLink(at: event) { return }
        terminalView.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        // AppKit keeps routing mouseDragged/mouseUp to the view that received the mouseDown for the
        // rest of that gesture, even once the pointer leaves this view's bounds — SwiftTerm's own
        // native selection-drag math (auto-scroll past the top/bottom edge) already depends on this
        // same guarantee, so a drag that wanders onto the board or another card still arrives here.
        if terminalView.handleDragMotion(event) { return }
        terminalView.mouseDragged(with: event)
    }

    // Deliberately not overridden: right/other mouse buttons, gestures (magnify/rotate/pressure), and
    // touches. `hitTest` claims the terminal's surface for these too since it can't discriminate by
    // event type, so they dead-end at this view's superview rather than reaching the terminal — same
    // as before this change for these specific types (the old monitor never watched them either, but
    // it also never claimed `hitTest`, so they reached the terminal via ordinary dispatch). SwiftTerm
    // 1.20.0 implements none of them, so nothing observable changes today; if a future SwiftTerm version
    // adds one, it needs an explicit forwarding override here.
}

/// `LocalProcessTerminalView` deliberately owns its SwiftTerm delegate. Replacing that delegate would
/// stop the local process from receiving terminal input, resize, and clipboard callbacks, so this proxy
/// forwards its complete protocol surface and intercepts only Orchestra's exact opaque media URL.
/// `internal`, not `private`: `ScrollableTerminalView` (a different file, same module) holds one.
final class TerminalImageLinkDelegateProxy: NSObject, TerminalViewDelegate {
    weak var downstream: (any TerminalViewDelegate)?
    var onOpenImage: ((UUID) -> Void)?

    init(downstream: (any TerminalViewDelegate)?, onOpenImage: @escaping (UUID) -> Void) {
        self.downstream = downstream
        self.onOpenImage = onOpenImage
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        downstream?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        downstream?.setTerminalTitle(source: source, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        downstream?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        downstream?.send(source: source, data: data)
    }

    func scrolled(source: TerminalView, position: Double) {
        downstream?.scrolled(source: source, position: position)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let referenceID = TranscriptImageLink.referenceID(from: link) else {
            downstream?.requestOpenLink(source: source, link: link, params: params)
            return
        }
        onOpenImage?(referenceID)
    }

    func bell(source: TerminalView) {
        downstream?.bell(source: source)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        downstream?.clipboardCopy(source: source, content: content)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        downstream?.iTermContent(source: source, content: content)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        downstream?.rangeChanged(source: source, startY: startY, endY: endY)
    }
}
#endif
