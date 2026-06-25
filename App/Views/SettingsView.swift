import SwiftUI
import OrchestraCore

/// Settings, styled to match the rest of the app (themed surfaces, not the native grey Form). Edits
/// auto-save to the daemon, debounced — there is no Save button. Appearance lives in the toolbar.
struct SettingsView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    @State private var reposRoot = ""
    @State private var worktreesRoot = ""
    @State private var defaultModel = ""
    @State private var allowlistText = ""
    @State private var statusLineMode: StatusLineMode = .passthroughGlobal
    @State private var customStatusLine = ""

    @State private var loaded = false
    @State private var saveTask: _Concurrency.Task<Void, Never>?

    private enum Field: Hashable { case repos, worktrees, custom, allowlist }
    @FocusState private var focusedField: Field?

    private var modelChoices: [AgentModel] {
        model.models.isEmpty ? ClaudeCodeAdapter().models() : model.models
    }
    private var modelLabel: String {
        defaultModel.isEmpty ? "Use agent default"
            : (modelChoices.first { $0.id == defaultModel }?.displayName ?? defaultModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                section("Paths") {
                    row("Repos root") { field($reposRoot, "~/Documents/Projects", focus: .repos) }
                    rowDivider
                    row("Worktrees root") { field($worktreesRoot, "~/.orchestra/worktrees", focus: .worktrees) }
                }

                section("Agent") {
                    row("Default model") {
                        menu(modelLabel) {
                            Button("Use agent default") { defaultModel = "" }
                            Divider()
                            ForEach(modelChoices) { m in
                                Button(m.displayName) { defaultModel = m.id }
                            }
                        }
                    }
                    rowDivider
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Allowlist")
                            .font(F.ui(12.5, .medium)).foregroundStyle(theme.text)
                        Text("Extra directories agents may touch — one path per line.")
                            .font(F.ui(11)).foregroundStyle(theme.text2)
                        editor($allowlistText, focus: .allowlist)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 11)
                }

                section("Status line") {
                    row("Mode") {
                        menu(statusLineMode.label) {
                            ForEach(StatusLineMode.allDisplay, id: \.0) { mode, label in
                                Button(label) { statusLineMode = mode }
                            }
                        }
                    }
                    if statusLineMode == .custom {
                        rowDivider
                        row("Command") { field($customStatusLine, "statusline.sh", focus: .custom) }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.winBg)
        .frame(width: 480, height: 470)
        .onAppear(perform: load)
        .task {
            // Defeat AppKit auto-focusing (and select-all-ing) the first text field when the
            // window opens — start with nothing focused so there's no stray caret/selection.
            try? await _Concurrency.Task.sleep(for: .milliseconds(50))
            focusedField = nil
        }
        .onChange(of: reposRoot) { scheduleSave() }
        .onChange(of: worktreesRoot) { scheduleSave() }
        .onChange(of: defaultModel) { scheduleSave() }
        .onChange(of: allowlistText) { scheduleSave() }
        .onChange(of: statusLineMode) { scheduleSave() }
        .onChange(of: customStatusLine) { scheduleSave() }
    }

    // MARK: - Building blocks

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings").font(F.ui(17, .bold)).tracking(-0.2).foregroundStyle(theme.text)
            Text("Changes save automatically.").font(F.ui(11.5)).foregroundStyle(theme.text2)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(F.ui(10.5, .semibold)).tracking(0.6).foregroundStyle(theme.text2)
                .padding(.leading, 3)
            VStack(spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(theme.card, corner: 10, hair: theme.hair)
        }
    }

    private func row<Control: View>(_ label: String, @ViewBuilder _ control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Text(label).font(F.ui(12.5, .medium)).foregroundStyle(theme.text)
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 42)
    }

    private var rowDivider: some View {
        Rectangle().fill(theme.hair).frame(height: 0.5).padding(.leading, 13)
    }

    private func field(_ binding: Binding<String>, _ placeholder: String, focus: Field) -> some View {
        TextField("", text: binding, prompt: Text(placeholder).foregroundColor(theme.text3))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(F.mono(11.5))
            .foregroundColor(theme.text)
            .focused($focusedField, equals: focus)
            .frame(width: 240)
            .padding(.horizontal, 10).frame(height: 28)
            .background(theme.field)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func editor(_ binding: Binding<String>, focus: Field) -> some View {
        TextEditor(text: binding)
            .font(F.mono(11.5))
            .foregroundColor(theme.text)
            .scrollContentBackground(.hidden)
            .focused($focusedField, equals: focus)
            .frame(height: 74)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(theme.field)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func menu<Content: View>(_ label: String, @ViewBuilder _ items: () -> Content) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 8) {
                Text(label).font(F.ui(12, .medium)).foregroundStyle(theme.text).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.text)
            }
            .padding(.horizontal, 11).frame(height: 28)
            .background(theme.field)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        // `.borderlessButton` renders ONLY the title text — it strips the custom label's box/chevron,
        // so the control looked like plain right-aligned text. `.button` + `.plain` keeps our label
        // chrome (field background, hairline, chevron) while still presenting the menu.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Load / save

    private func load() {
        let c = model.config
        reposRoot = c.reposRoot
        worktreesRoot = c.worktreesRoot
        defaultModel = c.defaultModel ?? ""
        allowlistText = c.allowlist.joined(separator: "\n")
        statusLineMode = c.statusLineMode
        customStatusLine = c.customStatusLine ?? ""
        loaded = true
    }

    private func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = _Concurrency.Task {
            try? await _Concurrency.Task.sleep(for: .milliseconds(500))
            guard !_Concurrency.Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
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
        await model.saveConfig(cfg)
    }
}

// MARK: - StatusLineMode display

private extension StatusLineMode {
    var label: String {
        switch self {
        case .passthroughGlobal: return "Passthrough (global)"
        case .orchestraDefault:  return "Orchestra default"
        case .custom:            return "Custom"
        }
    }
    static var allDisplay: [(StatusLineMode, String)] {
        [(.passthroughGlobal, "Passthrough (global)"),
         (.orchestraDefault, "Orchestra default"),
         (.custom, "Custom")]
    }
}
