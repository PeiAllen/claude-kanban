import SwiftUI
import OrchestraUI
import OrchestraCore

/// The 53px application toolbar (ui-spec §3.2, §4.1). The window uses a hidden title bar, so the
/// traffic lights overlay the top-left of this toolbar — the leading inset clears them.
struct ToolbarView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    // The OS traffic lights are fixed with their center ~16pt below the window top. Making the bar 32pt
    // tall puts the bottom divider at 32pt, so 16pt is the exact midpoint between the top and the
    // divider — the lights (and the vertically-centered content) sit on that centerline.
    static let height: CGFloat = 32

    var body: some View {
        // This view is the toolbar BACKGROUND strip + app identity only. It renders in the SwiftUI
        // content, under the transparent title bar. The interactive controls live in `ControlsRow`,
        // hosted in a real title-bar accessory (see WindowConfigurator) — that's the only way they
        // receive clicks, since AppKit's title-bar container sits above this content in the shared
        // band and would otherwise swallow every mouse-down. Identity is display-only, so it's fine
        // for it to live here (under the title bar) where it can't be clicked.
        HStack(spacing: 10) {
            appIdentity
            Spacer(minLength: 8)
        }
        .padding(.leading, 80).padding(.trailing, 14)
        .frame(height: Self.height)
        .background(theme.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.hair)
                .frame(height: 0.5)
        }
    }

    // MARK: - App identity

    private var appIdentity: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(theme.accent)
                .frame(width: 16, height: 16)
                .overlay(
                    Text("◧")
                        .font(F.ui(9.5, .heavy))
                        .foregroundStyle(.white)
                )
                .shadow(color: Color(r: 0, g: 0, b: 0, a: 0.18), radius: 1, x: 0, y: 1)
            HStack(spacing: 4) {
                Text("Orchestra")
                    .font(F.ui(12, .semibold))
                    .tracking(-0.12)
                    .foregroundStyle(theme.text)
                Text("· Personal")
                    .font(F.ui(11))
                    .foregroundStyle(theme.text2)
            }
        }
    }
}

/// The interactive toolbar controls, hosted in a real title-bar accessory so they sit on the
/// traffic-light row and actually receive clicks (see WindowConfigurator). The accessory is a
/// separate NSHostingView outside ContentView's environment, so this wrapper observes the model and
/// re-supplies the theme (which recomputes when dark mode / accent change).
struct ToolbarControls: View {
    @EnvironmentObject var model: BoardModel
    // Injected as an environmentObject by WindowConfigurator (this accessory host is outside ContentView's
    // environment), so the MCP status dot parks with the rest of the board when the window is occluded.
    @EnvironmentObject var activity: WindowActivityMonitor
    var body: some View {
        ControlsRow()
            .environment(\.theme, Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent))
            .environment(\.animationsActive, activity.active)
            .padding(.trailing, 14)
            .frame(height: ToolbarView.height)
            .fixedSize()
    }
}

/// The trailing cluster of toolbar controls (MCP status, Done, Activity, theme toggle, New agent).
struct ControlsRow: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    /// Control height for the bar's chips/buttons — kept compact so they read at roughly the scale of
    /// the 14pt traffic lights rather than towering over them.
    private static let ctl: CGFloat = 22

    var body: some View {
        HStack(spacing: 10) {
            ContextChip()
            mcpChip
            doneButton
            activityButton
            themeToggle
            newAgentButton
        }
    }

    // MARK: - MCP chip

    /// Connected → a static status pill. Offline → a button that (re)starts + connects the daemon.
    private var mcpChip: some View {
        Button {
            guard !model.connected else { return }
            _Concurrency.Task { await model.ensureDaemonAndStart() }
        } label: {
            HStack(spacing: 6) {
                PulseDot(color: dotColor, size: 6, active: model.connected || model.connecting, period: 0.9)
                Text(chipLabel)
                    .font(F.ui(10.5, .medium))
                    .foregroundStyle(theme.text)
            }
            .frame(height: Self.ctl)
            .padding(.horizontal, 9)
            .background(Capsule(style: .continuous).fill(theme.chip))
            .overlay(Capsule(style: .continuous).strokeBorder(theme.hair, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.connected)
        .help(model.connected ? "Daemon connected" : "Click to start the Orchestra daemon")
    }

    private var dotColor: Color {
        if model.connected { return theme.green.dot }
        if model.connecting { return theme.amber.dot }
        return theme.gray.dot
    }

    private var chipLabel: String {
        if model.connected { return "MCP connected · \(model.activeAgentCount) agents" }
        if model.connecting { return "Starting daemon…" }
        return "MCP offline · Start"
    }

    // MARK: - Done / Activity buttons

    private var doneButton: some View {
        Button {
            model.showDone.toggle()
        } label: {
            HStack(spacing: 5) {
                Text("✓")
                    .font(F.ui(9))
                    .opacity(0.6)
                Text("Done")
                    .font(F.ui(11, .medium))
            }
            .foregroundStyle(theme.text)
            .padding(.horizontal, 9)
            .frame(height: Self.ctl)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.chip))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.hair, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        // Anchor the popover to the button itself so it drops from the control with an arrow,
        // instead of floating at a hardcoded offset in the window.
        .popover(isPresented: $model.showDone, arrowEdge: .bottom) {
            DonePopover()
                .environmentObject(model)
                .environment(\.theme, theme)
        }
    }

    private var activityButton: some View {
        Button {
            model.showActivity.toggle()
        } label: {
            HStack(spacing: 5) {
                EqualizerGlyph(color: theme.text)
                Text("Activity")
                    .font(F.ui(11, .medium))
            }
            .foregroundStyle(theme.text)
            .padding(.horizontal, 9)
            .frame(height: Self.ctl)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.chip))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.hair, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $model.showActivity, arrowEdge: .bottom) {
            ActivityPopover()
                .environmentObject(model)
                .environment(\.theme, theme)
        }
    }

    // MARK: - Light/Dark segmented toggle

    private var themeToggle: some View {
        HStack(spacing: 2) {
            segment(glyph: "☀", active: !model.darkMode) { model.darkMode = false }
            segment(glyph: "☾", active: model.darkMode) { model.darkMode = true }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.chip))
    }

    private func segment(glyph: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(F.ui(11))
                .foregroundStyle(active ? theme.text : theme.text2)
                .frame(width: 24, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(active ? theme.card : Color.clear)
                        .shadow(color: active ? Color(r: 0, g: 0, b: 0, a: 0.16) : .clear,
                                radius: 1, x: 0, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - New agent

    private var newAgentButton: some View {
        Button {
            model.spawnDefaultColumn = .plan
            model.showSpawn = true
        } label: {
            HStack(spacing: 5) {
                Text("+")
                    .font(F.ui(13, .medium))
                Text("New agent")
                    .font(F.ui(11.5, .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: Self.ctl)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.accent))
            .shadow(color: Color(r: 0, g: 0, b: 0, a: 0.16), radius: 1, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Helpers

/// The 3-bar equalizer glyph for the Activity button (bars 2px wide, heights 6/11/8).
private struct EqualizerGlyph: View {
    let color: Color
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            bar(height: 6, opacity: 0.55)
            bar(height: 11, opacity: 1)
            bar(height: 8, opacity: 0.75)
        }
        .frame(height: 11)
    }
    private func bar(height: CGFloat, opacity: Double) -> some View {
        Capsule()
            .fill(color)
            .frame(width: 2, height: height)
            .opacity(opacity)
    }
}
