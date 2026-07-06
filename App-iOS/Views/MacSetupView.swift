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
