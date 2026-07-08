// The freeform-trust state machine, single-sourced for both spawn sheets (the macOS desktop
// `App/Views/SpawnSheet.swift` and the iOS phone `App-iOS/Views/SpawnSheet.swift`). It was copied
// two ways and the copies had already drifted: iOS carried a generation-counter race guard (deep-review
// bug #7) that the desktop lacked. Hoisting the logic here gives the desktop that guard for free and
// stops the two from diverging again.
//
// It owns ONLY the trust STATE + async orchestration (the `cwdTrusted` value, the generation guard,
// and the two daemon round-trips). Each sheet keeps its own *view* (the desktop's checkbox + amber
// banner, the phone's collapse chip) and its own `readOnly` / `keptReadOnly` side effects, driven off
// the outcome this type returns.
//
// iOS-clean: SwiftUI + Foundation only, no AppKit — it must pass `scripts/typecheck-ios-ui.sh`.

import SwiftUI

/// The freeform cwd's trust state + the two async ops that read/change it, generation-guarded so a slow,
/// stale reply can't clobber a newer result. Parameterized on the daemon client via per-call closures
/// (kept out of `init` so a SwiftUI view can hold it as a plain `@StateObject` and the daemon lives on
/// the view's `BoardModel`); this also keeps the type trivially unit-testable with stub closures.
@MainActor
public final class FreeformTrustModel: ObservableObject {
    /// Is the current cwd trusted? `nil` = unknown/unchecked (or no dir selected). Read by the sheet's
    /// trust notice; only this type writes it.
    @Published public private(set) var cwdTrusted: Bool? = nil
    /// True while a grant is in flight — drives the button's spinner + disabled state.
    @Published public private(set) var granting: Bool = false

    /// The dir the last op was launched for; a reply whose captured path no longer equals this is stale
    /// (the dir changed under it). Updated by `refresh`/`reset`.
    private var path: String = ""
    /// Monotonic generation, bumped on EVERY op (`refresh`, `grant`, `reset`). A reply whose captured
    /// generation no longer equals this is stale — this is what orders a grant against a concurrent
    /// refresh for the SAME dir (bug #7): the grant bumps the generation, so the earlier refresh's slow
    /// `trustState` reply is recognized as stale and dropped instead of overwriting the grant.
    private var gen: Int = 0

    public init() {}

    /// Outcome of a `refresh` — `.untrusted` is the only one the sheet acts on (forces read-only).
    public enum RefreshOutcome: Equatable, Sendable { case trusted, untrusted, stale }
    /// Outcome of a `grant` — the sheet clears its read-only lock on `.granted`.
    public enum GrantOutcome: Equatable, Sendable { case granted, failed, stale }

    /// Clear back to unknown (dir emptied / mode left freeform). Bumps the generation so any in-flight
    /// reply is dropped.
    public func reset() {
        path = ""
        gen += 1
        cwdTrusted = nil
    }

    /// Re-check trust for `newPath` via `check` (the daemon's `trustState`). The reply is applied only if
    /// no newer op superseded it (generation + path guard); otherwise it's dropped as `.stale`.
    public func refresh(path newPath: String, check: (String) async -> Bool) async -> RefreshOutcome {
        path = newPath
        gen += 1
        let g = gen
        let trusted = await check(newPath)
        guard g == gen, newPath == path else { return .stale }   // stale (dir changed OR a grant superseded)
        cwdTrusted = trusted
        return trusted ? .trusted : .untrusted
    }

    /// Grant trust for the current dir via `perform` (the daemon's `trust`). Bumps the generation up front
    /// so an in-flight `refresh` reply for the same dir is recognized as stale and can't revert the grant
    /// (bug #7). On success `cwdTrusted` flips to true.
    public func grant(perform: (String) async -> Bool) async -> GrantOutcome {
        guard !path.isEmpty, !granting else { return .stale }
        let p = path
        granting = true
        gen += 1
        let g = gen
        let ok = await perform(p)
        granting = false
        guard g == gen, p == path else { return .stale }   // stale (dir changed OR superseded)
        if ok { cwdTrusted = true; return .granted }
        return .failed
    }
}
