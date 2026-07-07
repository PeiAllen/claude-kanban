import SwiftUI
import UIKit
import OrchestraKit

/// A handle the takeover UI (PR T4) holds to drive a mounted `IOSTerminalView` imperatively: send
/// accessory-bar keys into the live PTY, arm/dismiss the soft keyboard, and reflect font size, Select
/// mode, and sticky-Ctrl state. The `IOSTerminalView.Coordinator` wires itself in when the view mounts;
/// the handle keeps only a weak ref, so it never keeps a torn-down terminal alive.
///
/// This is the reusable "reinterpreted terminal affordances" seam the design calls for — T2's live shell
/// will hold the same handle over the same `IOSTerminalView`, provider-neutrally.
@MainActor
final class TerminalControl: ObservableObject {
    /// Live font point size (A− / A+). Applied to the SwiftTerm view in `updateUIView`; SwiftTerm reflows
    /// and the existing `sizeChanged` path drives a PTY resize, so the agent redraws at the new columns.
    @Published var fontSize: CGFloat = 13
    /// Select mode: when on, SwiftTerm mouse reporting is disabled so a one-finger drag *selects text*
    /// rather than being forwarded as a terminal mouse event (design §Copy/selection).
    @Published var selectMode = false
    /// Whether typing is armed — the terminal is (or should be) first responder. Drives the "Start Typing"
    /// scrim: disarmed shows the scrim and blocks touches so a scroll/inspect can't send stray input.
    @Published private(set) var armed = false
    /// Sticky-Ctrl UI state: `ctrl` primes the next keystroke; `ctrlLocked` keeps it primed until untapped.
    @Published var ctrl = false
    @Published var ctrlLocked = false

    static let minFont: CGFloat = 8
    static let maxFont: CGFloat = 28

    fileprivate weak var coordinator: IOSTerminalView.Coordinator?

    /// Wire this handle to a freshly-made coordinator (called from `IOSTerminalView.makeCoordinator`). Also
    /// re-applies the current sticky-Ctrl state and installs the consume callback that de-highlights the
    /// bar's Ctrl chip when a one-shot Ctrl is used up by a soft-keyboard keystroke.
    func attach(coordinator c: IOSTerminalView.Coordinator) {
        coordinator = c
        c.setPendingCtrl(ctrl, locked: ctrlLocked)
        c.onCtrlConsumed = { [weak self] in self?.ctrl = false }
    }

    /// Revive a terminal that gave up reconnecting (or was dropped on a lease loss). Safe to call any time —
    /// a no-op unless the channel is actually dead. Wired to the takeover surface's `scenePhase == .active`
    /// so foregrounding the app retries a dead terminal (the "reopen or foreground to retry" affordance).
    func retry() {
        coordinator?.retryConnection()
    }

    /// Send a special key (Esc/Tab/arrows/Page…). Consumes a primed one-shot Ctrl if set (so Ctrl then a
    /// tapped key composes), matching a hardware Ctrl chord.
    func send(_ key: KeyName) {
        let withCtrl = ctrl ? applyControlModifier(to: key.bytes) : key.bytes
        coordinator?.sendBytes(withCtrl)
        consumeOneShotCtrl()
    }

    /// Arm typing: show the soft keyboard by making the terminal first responder. Idempotent.
    func arm() {
        armed = true
        coordinator?.focus()
    }
    /// Hide the soft keyboard but stay on the takeover surface (accessory keys still work).
    func dismissKeyboard() {
        armed = false
        coordinator?.blur()
    }

    func bumpFont(_ delta: CGFloat) {
        fontSize = min(Self.maxFont, max(Self.minFont, fontSize + delta))
    }

    /// Tapping the Ctrl key: one-shot on first tap, locked on the second, off on the third — the design's
    /// "Ctrl is one-shot by default; double-tap locks it".
    func tapCtrl() {
        if ctrlLocked { ctrl = false; ctrlLocked = false }        // locked → off
        else if ctrl { ctrlLocked = true }                        // one-shot → locked
        else { ctrl = true }                                      // off → one-shot
        coordinator?.setPendingCtrl(ctrl, locked: ctrlLocked)
    }

    /// After a Ctrl-modified key is sent (accessory or soft keyboard), clear a one-shot Ctrl but keep a
    /// locked one. Called by the coordinator too, so soft-keyboard chords stay in sync with the bar.
    func consumeOneShotCtrl() {
        guard ctrl, !ctrlLocked else { return }
        ctrl = false
        coordinator?.setPendingCtrl(false, locked: false)
    }
}
