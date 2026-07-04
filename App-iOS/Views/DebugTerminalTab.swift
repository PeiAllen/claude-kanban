#if DEBUG
import SwiftUI
import OrchestraKit
import OrchestraUI

/// A DEBUG-only harness to exercise the T1 terminal seam end-to-end before the product surfaces
/// (T2 Terminal tab / T3 Agent tab / T4 takeover) exist to mount it. It builds a `TmuxTarget` from
/// entered fields and hands it to the Environment-injected `terminalHost` — the exact call path
/// T2/T3/T4 will use. Compiled out of Release; not a product surface.
struct DebugTerminalTab: View {
    @Environment(\.terminalHost) private var terminalHost

    @State private var socket: String
    @State private var session: String
    @State private var window: String
    @State private var attached: Bool

    init() {
        // Prefill + optionally auto-attach from the launch environment so a `simctl` harness can drive
        // the terminal without UI text entry (there's no XCUITest here). ORCH_T1_AUTOATTACH=1 attaches
        // immediately when a session is provided.
        let env = ProcessInfo.processInfo.environment
        _socket = State(initialValue: env["ORCH_T1_SOCKET"] ?? "orchestra")
        let s = env["ORCH_T1_SESSION"] ?? ""
        _session = State(initialValue: s)
        _window = State(initialValue: env["ORCH_T1_WINDOW"] ?? "agent")
        _attached = State(initialValue: env["ORCH_T1_AUTOATTACH"] == "1" && !s.isEmpty)
    }

    private var target: TmuxTarget {
        TmuxTarget(socket: socket, session: session, window: window,
                   kind: window == "agent" ? .agent : .shell,
                   target: "\(session):\(window)",
                   attach: "tmux -L \(socket) attach -t \(session):\(window)")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if attached {
                    terminalHost.attach(target: target)
                        .background(Color.black)
                    Divider()
                    Button("Detach") { attached = false }
                        .padding(8)
                } else {
                    Form {
                        Section("tmux target") {
                            TextField("socket", text: $socket).autocorrectionDisabled()
                            TextField("session (orchestra-<id>)", text: $session)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                            TextField("window", text: $window).autocorrectionDisabled()
                        }
                        Section {
                            Button("Attach terminal") { attached = true }
                                .disabled(session.isEmpty)
                        } footer: {
                            Text("SSH target: \(SSHEndpoint.resolve().map { "\($0.user)@\($0.host):\($0.port)" } ?? "unset (ORCH_SSH_TARGET) — attach shows setup banner")")
                        }
                    }
                }
            }
            .navigationTitle("Terminal (dev)")
        }
    }
}
#endif
