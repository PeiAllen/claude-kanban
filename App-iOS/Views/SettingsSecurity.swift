import SwiftUI
import OrchestraUI

/// Security settings — reset the pinned SSH **host key**. The terminal pins the Mac's host key on first
/// connect (trust-on-first-use) and refuses a *changed* key as a possible MITM (security #5). If you
/// deliberately re-keyed the Mac (fresh OS install, regenerated host key), the pin would otherwise be a
/// dead end — this clears it so the next connect re-trusts on first use.
struct SecuritySettingsSection: View {
    @EnvironmentObject private var model: BoardModel
    /// The terminal pins by the active connection's SSH host (the unified config). Read-only use of the
    /// endpoint parser — no connect-setup changes.
    private var host: String? { SSHEndpoint.resolve(connection: model.connections.active)?.host }
    private let store = SSHHostKeyPinStore()

    @State private var confirming = false
    @State private var status: String?

    var body: some View {
        Section {
            Button(role: .destructive) { confirming = true } label: {
                Label(host.map { "Reset trusted host key for \($0)" } ?? "Reset all trusted host keys",
                      systemImage: "lock.rotation")
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Security")
        } footer: {
            Text("The terminal pins the Mac's SSH host key on first connect and refuses a changed key "
                 + "(possible man-in-the-middle). Reset it only if you deliberately re-keyed the Mac.")
        }
        .confirmationDialog("Reset trusted host key?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next connection will trust whatever host key the server presents "
                 + "(trust-on-first-use). Only do this if you re-keyed the Mac yourself.")
        }
    }

    private func reset() {
        do {
            if let host { try store.reset(host: host) } else { try store.resetAll() }
            status = "Trusted host key cleared — the next connect will re-pin."
        } catch {
            status = "Couldn't clear the pin: \(error)"
        }
    }
}
