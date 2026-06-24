import SwiftUI
import OrchestraCore

/// Native Settings form editing daemon `Config` + appearance preferences. ui-spec §4.11.
struct SettingsView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    @State private var reposRoot = ""
    @State private var worktreesRoot = ""
    @State private var defaultModel = ""
    @State private var allowlistText = ""
    @State private var statusLineMode: StatusLineMode = .passthroughGlobal
    @State private var customStatusLine = ""

    var body: some View {
        Form {
            Section("Paths") {
                TextField("Repos root", text: $reposRoot)
                TextField("Worktrees root", text: $worktreesRoot)
            }

            Section("Agent") {
                TextField("Default model", text: $defaultModel)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allowlist (one path per line)")
                        .font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $allowlistText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 70)
                }
            }

            Section("Status line") {
                Picker("Mode", selection: $statusLineMode) {
                    Text("Passthrough (global)").tag(StatusLineMode.passthroughGlobal)
                    Text("Custom").tag(StatusLineMode.custom)
                    Text("Orchestra default").tag(StatusLineMode.orchestraDefault)
                }
                if statusLineMode == .custom {
                    TextField("Custom status line", text: $customStatusLine)
                }
            }

            Section {
                Button("Save") {
                    var cfg = model.config
                    cfg.reposRoot = reposRoot
                    cfg.worktreesRoot = worktreesRoot
                    cfg.defaultModel = defaultModel.isEmpty ? nil : defaultModel
                    cfg.allowlist = allowlistText
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    cfg.statusLineMode = statusLineMode
                    cfg.customStatusLine = customStatusLine.isEmpty ? nil : customStatusLine
                    _Concurrency.Task { await model.saveConfig(cfg) }
                }
            }

            Section("Appearance") {
                Picker("Accent", selection: model.$accentRaw) {
                    ForEach(Accent.allCases) { a in
                        Text(a.rawValue.capitalized).tag(a.rawValue)
                    }
                }
                Picker("Density", selection: model.$densityRaw) {
                    ForEach(Density.allCases) { d in
                        Text(d.rawValue.capitalized).tag(d.rawValue)
                    }
                }
                Toggle("Dark mode", isOn: model.$darkMode)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 540)
        .onAppear(perform: load)
    }

    private func load() {
        let c = model.config
        reposRoot = c.reposRoot
        worktreesRoot = c.worktreesRoot
        defaultModel = c.defaultModel ?? ""
        allowlistText = c.allowlist.joined(separator: "\n")
        statusLineMode = c.statusLineMode
        customStatusLine = c.customStatusLine ?? ""
    }
}
