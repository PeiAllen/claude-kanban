import SwiftUI
import OrchestraUI
import OrchestraCore

/// Settings → Connections. Lists the built-in local connection + saved remotes, lets you add/edit/delete
/// a remote, pick the active one, and Connect/Disconnect. A live status chip reflects the tunnel/link
/// state published by `BoardModel.connectionState`.
struct ConnectionsSettingsView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    @State private var editing: Connection?   // non-nil → editor sheet open
    @State private var bump = false           // toggled to re-read the store after a mutation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusRow
                list
                addButton
                Text("Remote setup: run scripts/deploy-linux-daemon.sh on the box, then paste its printed "
                     + "SSH target + socket path here. Key-based SSH auth to the host is required.")
                    .font(F.ui(11)).foregroundStyle(theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(bump)   // force a rebuild after upsert/delete so the list reflects the store
        }
        .background(theme.winBg)
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 470, maxHeight: .infinity)
        .sheet(item: $editing) { conn in
            InterfaceScaledPresentation {
                ConnectionEditor(connection: conn) { saved in
                    model.connections.upsert(saved); editing = nil; bump.toggle()
                } onCancel: { editing = nil }
                .environment(\.theme, theme)
            }
        }
    }

    // MARK: - pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Connections").font(F.ui(17, .bold)).tracking(-0.2).foregroundStyle(theme.text)
            Text("Run the board against this Mac or a remote Linux daemon.")
                .font(F.ui(11.5)).foregroundStyle(theme.text2)
        }
    }

    private var statusRow: some View {
        let (label, color): (String, Color) = {
            switch model.connectionState {
            case .live:       return ("Connected", .green)
            case .connecting: return ("Connecting…", .blue)
            case .retrying:   return ("Reconnecting…", .orange)
            case .down:       return ("Disconnected", theme.text3)
            }
        }()
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(F.ui(12, .medium)).foregroundStyle(theme.text2)
            Spacer()
            if model.connectionState == .down {
                pillButton("Connect") { _Concurrency.Task { await model.activate(model.connections.active) } }
            } else {
                pillButton("Disconnect") { model.disconnect() }
            }
        }
        .padding(.horizontal, 13).frame(minHeight: 42)
        .surface(theme.card, corner: 10, hair: theme.hair)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.connections.all.enumerated()), id: \.element.id) { idx, conn in
                if idx > 0 { Rectangle().fill(theme.hair).frame(height: 0.5).padding(.leading, 13) }
                row(conn)
            }
        }
        .surface(theme.card, corner: 10, hair: theme.hair)
    }

    private func row(_ conn: Connection) -> some View {
        let active = model.connections.activeId == conn.id
        return HStack(spacing: 10) {
            Image(systemName: active ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 14)).foregroundStyle(active ? Color.accentColor : theme.text3)
                .onTapGesture { _Concurrency.Task { await model.switchConnection(conn.id) } }
            VStack(alignment: .leading, spacing: 1) {
                Text(conn.name).font(F.ui(12.5, .medium)).foregroundStyle(theme.text)
                Text(conn.isLocal ? "Local daemon · tmux \(conn.remoteTmuxSocket)"
                                  : "\(conn.sshTarget ?? "?") · \(conn.remoteSocketPath ?? "?")")
                    .font(F.mono(10.5)).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if !conn.isLocal {
                iconButton("pencil") { editing = conn }
                iconButton("trash") { model.connections.delete(conn.id); bump.toggle() }
            }
        }
        .padding(.horizontal, 13).frame(minHeight: 48)
    }

    private var addButton: some View {
        pillButton("Add remote…") {
            editing = Connection(name: "", kind: .remote, remoteTmuxSocket: "orchestra")
        }
    }

    // MARK: - small controls

    private func pillButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(F.ui(12, .medium)).foregroundStyle(theme.text)
                .padding(.horizontal, 12).frame(height: 28)
                .background(theme.field)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ systemName: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 12)).foregroundStyle(theme.text2)
                .frame(width: 26, height: 26)
                .background(theme.field)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.fieldBorder, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

/// A modal form to add/edit a remote connection. Local connections are never edited here.
private struct ConnectionEditor: View {
    @Environment(\.theme) var theme: Theme
    @State var connection: Connection
    let onSave: (Connection) -> Void
    let onCancel: () -> Void

    init(connection: Connection, onSave: @escaping (Connection) -> Void, onCancel: @escaping () -> Void) {
        _connection = State(initialValue: connection); self.onSave = onSave; self.onCancel = onCancel
    }

    private var canSave: Bool {
        !connection.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !(connection.sshTarget ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && !(connection.remoteSocketPath ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remote connection").font(F.ui(15, .bold)).foregroundStyle(theme.text)
            field("Name", text: $connection.name, placeholder: "Work box")
            field("SSH target", text: optBinding(\.sshTarget), placeholder: "user@host")
            field("Identity file (optional)", text: optBinding(\.identityFile), placeholder: "~/.ssh/id_ed25519")
            field("Remote socket path", text: optBinding(\.remoteSocketPath),
                  placeholder: "~/.local/share/orchestra/orchestrad.sock")
            field("Remote tmux socket", text: $connection.remoteTmuxSocket, placeholder: "orchestra")
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(.plain)
                    .font(F.ui(12, .medium)).foregroundStyle(theme.text2)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                Button("Save") { onSave(normalized()) }.buttonStyle(.plain)
                    .font(F.ui(12, .semibold)).foregroundStyle(canSave ? .white : theme.text3)
                    .padding(.horizontal, 14).frame(height: 28)
                    .background(canSave ? Color.accentColor : theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .disabled(!canSave)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
        .background(theme.winBg)
    }

    /// Trim blanks; turn empty optionals back into nil so the store stays clean.
    private func normalized() -> Connection {
        var c = connection
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        c.sshTarget = c.sshTarget?.trimmingCharacters(in: .whitespaces)
        c.identityFile = (c.identityFile?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        c.remoteSocketPath = c.remoteSocketPath?.trimmingCharacters(in: .whitespaces)
        if c.remoteTmuxSocket.trimmingCharacters(in: .whitespaces).isEmpty { c.remoteTmuxSocket = "orchestra" }
        return c
    }

    private func optBinding(_ key: WritableKeyPath<Connection, String?>) -> Binding<String> {
        Binding(get: { connection[keyPath: key] ?? "" }, set: { connection[keyPath: key] = $0 })
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(F.ui(11.5, .medium)).foregroundStyle(theme.text2)
            TextField("", text: text, prompt: Text(placeholder).foregroundColor(theme.text3))
                .textFieldStyle(.plain).font(F.mono(11.5)).foregroundColor(theme.text)
                .padding(.horizontal, 10).frame(height: 28)
                .background(theme.field)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }
}
