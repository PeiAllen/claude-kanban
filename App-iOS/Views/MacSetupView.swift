import SwiftUI
import UIKit
import OrchestraKit
import OrchestraUI

/// The guided first-launch "connect your Mac" flow — a single sheet with a 3-step checklist that takes a
/// fresh install to a green board. It configures the **one** unified `Connection` that lights up every
/// feature (board, terminals, takeover); there is no second setting. Also reachable any time from
/// Settings → Connection ("Set up your Mac…"), so it doubles as re-setup.
///
/// The three steps mirror what actually has to happen once:
///   1. **Enter your Mac** — its Tailscale target (`you@my-mac.tailnet.ts.net` or a 100.64/10 IP).
///   2. **Trust this device** — paste this device's SSH key line into the Mac's `~/.ssh/authorized_keys`.
///   3. **Test** — connect; on `.live` the board is ready.
struct MacSetupView: View {
    @EnvironmentObject var model: BoardModel
    @StateObject private var vm = MacSetupModel()
    /// Focus for the target field so the keyboard has a way out: a tap-off on the Form background, an
    /// interactive swipe-down, and the return key all resign it. Mirrors `TerminalTab`'s `@FocusState`.
    @FocusState private var targetFocused: Bool
    /// Called when the user finishes (a successful test) or explicitly dismisses — RootView records that
    /// onboarding was shown so it doesn't reappear on every launch.
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                stepTarget
                stepTrust
                stepTest
            }
            // Tap-off + swipe-down dismissal for the target keyboard. Swipe-down is native; tap-off is a
            // window-level UIKit recognizer (see `KeyboardDismissTap`) — a SwiftUI `.onTapGesture` on the
            // Form is an *ancestor* of the row controls and, inside a List, wins the tap arena and eats the
            // Copy/Test/Done presses (empirically: even `.simultaneousGesture` does). The recognizer
            // resigns the keyboard without cancelling the touch, so the buttons still fire on the first tap.
            .scrollDismissesKeyboard(.interactively)
            .background(KeyboardDismissTap())
            .navigationTitle("Connect your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { onClose() }
                }
            }
        }
    }

    // MARK: 1 — target

    private var stepTarget: some View {
        Section {
            TextField("you@my-mac.tailnet.ts.net", text: $vm.target)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                .focused($targetFocused)
                // The keyboard's return key doubles as an explicit dismiss (single-line field), alongside
                // tap-off and swipe-down.
                .submitLabel(.done)
                .onSubmit { targetFocused = false }
        } header: {
            Label("1 · Enter your Mac", systemImage: "desktopcomputer")
        } footer: {
            if let reason = vm.targetRejection {
                Text(reason).foregroundStyle(.red)
            } else {
                Text("Its Tailscale name (you@my-mac.tailnet.ts.net) or a 100.64.0.0/10 tailnet IP. "
                     + "This one target drives the board, terminals, and takeover.")
            }
        }
    }

    // MARK: 2 — trust this device

    private var stepTrust: some View {
        Section {
            if let key = vm.deviceKeyLine {
                Text(key)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                Button {
                    UIPasteboard.general.string = key
                    vm.copied = true
                } label: {
                    Label(vm.copied ? "Copied" : "Copy key line", systemImage: vm.copied ? "checkmark" : "doc.on.doc")
                }
            } else {
                Text("This device's SSH key isn't available yet.").foregroundStyle(.secondary)
            }
        } header: {
            Label("2 · Trust this device", systemImage: "key")
        } footer: {
            Text("On the Mac, append this line to ~/.ssh/authorized_keys — that's how the Mac trusts this "
                 + "phone. One time only; the key is stored in this device's Keychain.")
        }
    }

    // MARK: 3 — test

    private var stepTest: some View {
        Section {
            Button {
                runTest()
            } label: {
                HStack {
                    Label("Test connection", systemImage: "bolt.horizontal.circle")
                    Spacer()
                    switch vm.testState {
                    case .testing: ProgressView()
                    case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    case .idle:    EmptyView()
                    }
                }
            }
            .disabled(!vm.canTest || vm.testState == .testing)

            if vm.testState == .success {
                Button { onClose() } label: {
                    Label("Done — open the board", systemImage: "square.stack.3d.up.fill")
                        .font(.body.weight(.semibold))
                }
            }
        } header: {
            Label("3 · Test", systemImage: "checkmark.seal")
        } footer: {
            switch vm.testState {
            case .failure(let reason): Text(reason).foregroundStyle(.red)
            case .success:             Text("Connected. Your board is live.").foregroundStyle(.green)
            default:                   Text("Connects to your Mac and confirms the board goes live.")
            }
        }
    }

    /// Save the connection, activate it, and watch `model.connectionState` for `.live`. Reflects the
    /// outcome into `vm.testState` (green check / red reason). The daemon is either reachable or not —
    /// never fabricate success.
    private func runTest() {
        guard let conn = vm.makeConnection() else { return }
        vm.testState = .testing
        _Concurrency.Task {
            model.connections.upsert(conn)
            await model.switchConnection(conn.id)
            let live = await vm.waitForLive { model.connectionState }
            vm.testState = live
                ? .success
                : .failure("Couldn't connect. Check the Mac is on Tailscale, Remote Login is on, and this "
                           + "device's key is in ~/.ssh/authorized_keys.")
        }
    }
}

/// Tap-off keyboard dismissal that coexists with buttons. A SwiftUI `.onTapGesture` (or even a
/// `.simultaneousGesture(TapGesture())`) placed on the Form is an ancestor of the row controls and, in a
/// List, wins the tap arena — so a short tap dismisses the keyboard but the Copy/Test/Done buttons never
/// see it (empirically verified on a Simulator with injected touches). This installs a
/// `UITapGestureRecognizer` on the host **window** instead, with `cancelsTouchesInView = false` and a
/// delegate that (a) recognizes simultaneously with every other recognizer and (b) ignores touches that
/// land on a text-entry view. The net behaviour: a tap anywhere off the field resigns first responder
/// (dismissing the keyboard) while the touch still reaches whatever it hit, so buttons fire on the first
/// tap and tapping the field itself keeps it focused. Mirrors the board's UIKit-recognizer approach to the
/// same SwiftUI gesture-arena problem (see `LongPressMoveGesture` in `BoardTab`). The recognizer is torn
/// down when the view goes away so it never lingers on the window past this sheet.
private struct KeyboardDismissTap: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false          // only used to reach the window; never a hit target
        DispatchQueue.main.async { context.coordinator.install(from: v) }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { context.coordinator.install(from: uiView) }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?
        private var recognizer: UITapGestureRecognizer?

        func install(from view: UIView) {
            guard recognizer == nil, let w = view.window else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(fire))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            w.addGestureRecognizer(tap)
            window = w
            recognizer = tap
        }

        func remove() {
            if let tap = recognizer { window?.removeGestureRecognizer(tap) }
            recognizer = nil
            window = nil
        }

        @objc private func fire() {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        // A tap on a text-entry view is that field's own business (focus / cursor placement) — don't treat
        // it as a dismiss, or tapping the field to type would immediately close the keyboard.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            var v = touch.view
            while let cur = v {
                if cur is UITextField || cur is UITextView { return false }
                v = cur.superview
            }
            return true
        }
    }
}

/// The onboarding view-model: pure validation + connection building (unit-tested), plus the small
/// connect-and-wait helper. Deliberately holds no NIO/daemon state — the actual connect is driven by
/// `BoardModel` in the view.
@MainActor
final class MacSetupModel: ObservableObject {
    enum TestState: Equatable { case idle, testing, success, failure(String) }

    @Published var target: String = ""
    @Published var testState: TestState = .idle
    @Published var copied: Bool = false

    /// A user-facing reason the target is invalid, or nil when it's usable (mirrors the terminal's
    /// connect-time gate so setup never accepts a target the transport would then refuse). Empty = no
    /// reason yet (the field is just blank), so the footer shows guidance instead of an error.
    var targetRejection: String? {
        SSHEndpoint.settingsRejectionReason(for: target)
    }

    /// Can we attempt a test? A non-empty, non-rejected target.
    var canTest: Bool {
        !target.trimmingCharacters(in: .whitespaces).isEmpty && targetRejection == nil
    }

    /// This device's `authorized_keys` line (from the Keychain identity), or nil if unavailable.
    var deviceKeyLine: String? { try? SSHKeyStore.authorizedKeyLine() }

    /// The unified Mac connection this flow configures, or nil when the target is invalid. The socket path
    /// + tmux socket are the standard Mac defaults, so the user only ever enters the one tailnet target.
    func makeConnection() -> Connection? {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard canTest, SSHEndpoint(target: t) != nil else { return nil }
        return Connection.mac(sshTarget: t)
    }

    /// Poll `state()` until it is `.live` (success) or a timeout elapses. `.retrying`/`.connecting` keep
    /// waiting; only `.live` is success. Returns false if it never reaches `.live`.
    func waitForLive(timeout: TimeInterval = 12, state: @escaping () -> ConnectionState) async -> Bool {
        let steps = Int(timeout / 0.25)
        for _ in 0..<max(1, steps) {
            if state() == .live { return true }
            try? await _Concurrency.Task.sleep(nanoseconds: 250_000_000)
        }
        return state() == .live
    }
}
