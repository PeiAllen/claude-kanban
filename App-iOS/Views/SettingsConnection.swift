import SwiftUI
import OrchestraKit
import OrchestraUI

/// Connection settings: a live status banner bound to `BoardModel.connectionState` (with Disconnect /
/// Connect), then the shared `ConnectionStore` list — **This Mac** plus saved remotes, an active radio
/// to switch which daemon the board talks to, **Edit** on remotes, and an **Add remote…** row that opens
/// the editor. This is the same `Connection` model the desktop uses; the phone is just another client.
struct ConnectionSettingsSections: View {
    @EnvironmentObject var model: BoardModel

    @State private var editing: Connection?   // non-nil → editor sheet open
    @State private var refresh = 0            // bumped after a store mutation to force a re-read

    var body: some View {
        // The store isn't observable, so mutations bump `refresh` (a @State write invalidates this view,
        // re-reading `model.connections` on the next body pass).
        Group {
            statusSection
            connectionSection
        }
        .sheet(item: $editing) { conn in
            RemoteEditorView(connection: conn) { saved in
                model.connections.upsert(saved); editing = nil; refresh += 1
            } onCancel: { editing = nil }
        }
    }

    // MARK: - status banner

    private var statusSection: some View {
        Section {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(statusLabel).font(.subheadline.weight(.medium))
                Spacer()
                if model.connectionState == .down {
                    Button("Connect") { _Concurrency.Task { await model.activate(model.connections.active) } }
                        .font(.subheadline.weight(.semibold))
                } else {
                    Button("Disconnect", role: .destructive) { model.disconnect() }
                        .font(.subheadline.weight(.semibold))
                }
            }
        } header: {
            Text("Status")
        } footer: {
            // Never fabricate data when offline — say so plainly.
            if model.connectionState == .down {
                Text("Offline — the board shows the last snapshot and won't update until reconnected.")
            }
        }
    }

    private var statusLabel: String {
        switch model.connectionState {
        case .connecting: return "Connecting…"
        case .live:       return "Connected"
        case .retrying:   return "Reconnecting…"
        case .down:       return "Disconnected"
        }
    }
    private var statusColor: Color {
        switch model.connectionState {
        case .live:       return .green
        case .connecting: return .blue
        case .retrying:   return .orange
        case .down:       return .secondary
        }
    }

    // MARK: - connection list

    private var connectionSection: some View {
        Section {
            ForEach(model.connections.all) { conn in
                connectionRow(conn)
            }
            Button {
                // Prefill the Mac daemon socket + name so adding your Mac is one field — the tailnet
                // target. The board reaches it over SSH (P1); terminals/takeover use the same connection.
                editing = Connection(name: "My Mac", kind: .remote,
                                     remoteSocketPath: Connection.defaultMacSocketPath,
                                     remoteTmuxSocket: "orchestra")
            } label: {
                Label("Add your Mac…", systemImage: "plus.circle")
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("Which daemon the board talks to. Add your Mac over Tailscale (its user@…​.ts.net "
                 + "target) — the socket path is prefilled. The board, terminals, and takeover all use "
                 + "this one connection.")
        }
    }

    @ViewBuilder
    private func connectionRow(_ conn: Connection) -> some View {
        let active = model.connections.activeId == conn.id
        HStack(spacing: 12) {
            Button {
                _Concurrency.Task { await model.switchConnection(conn.id); refresh += 1 }
            } label: {
                Image(systemName: active ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(conn.name).font(.body)
                Text(conn.isLocal ? "Local daemon · tmux \(conn.remoteTmuxSocket)"
                                  : "\(conn.sshTarget ?? "?") · \(conn.remoteSocketPath ?? "?")")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if !conn.isLocal {
                Button { editing = conn } label: { Text("Edit").font(.subheadline) }
                    .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing) {
            if !conn.isLocal {
                Button(role: .destructive) {
                    model.connections.delete(conn.id); refresh += 1
                } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }
}

/// Add / edit a remote connection — a native grouped form. Local connections are never edited here.
/// Saves back through `ConnectionStore.upsert`, mirroring the desktop editor's fields verbatim.
private struct RemoteEditorView: View {
    @State private var connection: Connection
    let onSave: (Connection) -> Void
    let onCancel: () -> Void

    init(connection: Connection, onSave: @escaping (Connection) -> Void, onCancel: @escaping () -> Void) {
        _connection = State(initialValue: connection); self.onSave = onSave; self.onCancel = onCancel
    }

    private var canSave: Bool {
        !connection.name.trimmed.isEmpty
            && !(connection.sshTarget ?? "").trimmed.isEmpty
            && !(connection.remoteSocketPath ?? "").trimmed.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Remote") {
                    labeled("Name", $connection.name, "Work box")
                    labeled("SSH target", optBinding(\.sshTarget), "user@host")
                    labeled("Identity file", optBinding(\.identityFile), "~/.ssh/id_ed25519")
                }
                Section("Socket") {
                    labeled("Remote socket path", optBinding(\.remoteSocketPath),
                            "~/.local/share/orchestra/orchestrad.sock")
                    labeled("Remote tmux socket", $connection.remoteTmuxSocket, "orchestra")
                }
            }
            .navigationTitle(connection.name.isEmpty ? "Add remote" : "Edit remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(normalized()) }.disabled(!canSave)
                }
            }
        }
    }

    private func labeled(_ label: String, _ text: Binding<String>, _ placeholder: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    /// Trim blanks; turn empty optionals back into nil so the store stays clean.
    private func normalized() -> Connection {
        var c = connection
        c.name = c.name.trimmed
        c.sshTarget = c.sshTarget?.trimmed
        c.identityFile = (c.identityFile?.trimmed).flatMap { $0.isEmpty ? nil : $0 }
        c.remoteSocketPath = c.remoteSocketPath?.trimmed
        if c.remoteTmuxSocket.trimmed.isEmpty { c.remoteTmuxSocket = "orchestra" }
        return c
    }

    private func optBinding(_ key: WritableKeyPath<Connection, String?>) -> Binding<String> {
        Binding(get: { connection[keyPath: key] ?? "" }, set: { connection[keyPath: key] = $0 })
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
