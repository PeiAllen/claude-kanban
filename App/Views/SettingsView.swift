import SwiftUI
import OrchestraUI
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

    // Local app preference (not daemon Config), like the notification rows. Registered `true` at
    // launch in OrchestraApp; the KeyboardController reads the same key live on each keypress.
    @AppStorage("orch_vim_keys") private var vimKeys = true

    // Bump to force a re-read of the per-trigger notification UserDefaults after a menu pick.
    @State private var notifyTick = 0

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
                    row("Repos root") { field($reposRoot, "~", focus: .repos) }
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

                section("Keyboard") {
                    toggleRow("Vim keyboard",
                              "Single-key navigation and commands (hjkl, g, f, :, …). ⌘N / ⌘T / ⌘W and Esc always work.",
                              isOn: $vimKeys)
                }

                section("Notifications") {
                    notifyRow(.permission, "Permission needed",
                              "Alert when an agent is blocked waiting for your approval.")
                    rowDivider
                    notifyRow(.needsYou, "Needs you",
                              "Alert when an agent finishes and is waiting on you — not while a background task is still running.")
                    rowDivider
                    notifyRow(.died, "Card died",
                              "Alert when an agent session crashes or exits and needs recovery.")
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

    /// A label + description on the left, a themed switch on the right.
    private func toggleRow(_ label: String, _ desc: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(F.ui(12.5, .medium)).foregroundStyle(theme.text)
                Text(desc).font(F.ui(11)).foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(theme.accent)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
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

    /// A themed dropdown. `width == nil` sizes to content (intrinsic); passing a fixed `width` makes
    /// the control that wide with the chevron pinned trailing — used to align columns of menus.
    private func menu<Content: View>(_ label: String, width: CGFloat? = nil, @ViewBuilder _ items: () -> Content) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 8) {
                Text(label).font(F.ui(12, .medium)).foregroundStyle(theme.text).lineLimit(1)
                if width != nil { Spacer(minLength: 6) }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.text)
            }
            .padding(.horizontal, 11).frame(width: width, height: 28)
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
        .fixedSize(horizontal: width == nil, vertical: false)
    }

    // MARK: - Notification rows (per-trigger scope + sound)

    // The named system sounds (everything except Default/None), for the sound picker — derived from the
    // shared `NotifySound` enum so the list can't drift from what the notifier resolves.
    private static let namedSounds: [NotifySound] =
        NotifySound.allCases.filter { $0 != .systemDefault && $0 != .none }

    private func notifyRow(_ trigger: NotifyTrigger, _ label: String, _ desc: String) -> some View {
        let scope = currentScope(trigger)
        let sound = currentSound(trigger)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(F.ui(12.5, .medium)).foregroundStyle(theme.text)
                Text(desc).font(F.ui(11)).foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            menu(scopeLabel(scope), width: 148) {
                ForEach(NotifyScope.allCases, id: \.self) { s in
                    Button(scopeLabel(s)) { setScope(trigger, s) }
                }
            }
            menu(sound.label, width: 116) {
                Button("Default") { setSound(trigger, .systemDefault) }
                Button("None") { setSound(trigger, .none) }
                Divider()
                ForEach(Self.namedSounds, id: \.self) { s in
                    Button(s.label) { setSound(trigger, s); NSSound(named: s.rawValue)?.play() }
                }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .id(notifyTick)   // re-render this row when a pick lands
    }

    // Read/write the per-trigger prefs through the shared `NotificationPrefs` (same `orch_notify_*` keys +
    // defaults the macOS notifier and the phone both consume).
    private func currentScope(_ t: NotifyTrigger) -> NotifyScope { NotificationPrefs().scope(t) }
    private func currentSound(_ t: NotifyTrigger) -> NotifySound { NotificationPrefs().sound(t) }
    private func setScope(_ t: NotifyTrigger, _ s: NotifyScope) {
        NotificationPrefs().setScope(s, for: t); notifyTick += 1
    }
    private func setSound(_ t: NotifyTrigger, _ s: NotifySound) {
        NotificationPrefs().setSound(s, for: t); notifyTick += 1
    }
    private func scopeLabel(_ s: NotifyScope) -> String {
        switch s { case .off: return "Off"; case .background: return "Background only"; case .always: return "Always" }
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
