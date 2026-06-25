import SwiftUI
import OrchestraCore

/// The 53px application toolbar (ui-spec §3.2, §4.1). The window uses a hidden title bar, so the
/// traffic lights overlay the top-left of this toolbar — the leading inset clears them.
struct ToolbarView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    /// Shared with WindowConfigurator so the traffic lights center in this exact band.
    static let height: CGFloat = 52

    var body: some View {
        HStack(spacing: 10) {
            appIdentity
            Spacer(minLength: 8)
            mcpChip
            doneButton
            activityButton
            themeToggle
            newAgentButton
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
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.accent)
                .frame(width: 21, height: 21)
                .overlay(
                    Text("◧")
                        .font(F.ui(12, .heavy))
                        .foregroundStyle(.white)
                )
                .shadow(color: Color(r: 0, g: 0, b: 0, a: 0.18), radius: 1, x: 0, y: 1)
            HStack(spacing: 5) {
                Text("Orchestra")
                    .font(F.ui(13.5, .semibold))
                    .tracking(-0.135)
                    .foregroundStyle(theme.text)
                Text("· Personal")
                    .font(F.ui(12.5))
                    .foregroundStyle(theme.text2)
            }
        }
    }

    // MARK: - MCP chip

    /// Connected → a static status pill. Offline → a button that (re)starts + connects the daemon.
    private var mcpChip: some View {
        Button {
            guard !model.connected else { return }
            _Concurrency.Task { await model.ensureDaemonAndStart() }
        } label: {
            HStack(spacing: 7) {
                PulseDot(color: dotColor, size: 7, active: model.connected || model.connecting)
                Text(chipLabel)
                    .font(F.ui(11.5, .medium))
                    .foregroundStyle(theme.text)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 11)
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
            HStack(spacing: 6) {
                Text("✓")
                    .font(F.ui(10))
                    .opacity(0.6)
                Text("Done")
                    .font(F.ui(12, .medium))
            }
            .foregroundStyle(theme.text)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.chip))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(theme.hair, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var activityButton: some View {
        Button {
            model.showActivity.toggle()
        } label: {
            HStack(spacing: 6) {
                EqualizerGlyph(color: theme.text)
                Text("Activity")
                    .font(F.ui(12, .medium))
            }
            .foregroundStyle(theme.text)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.chip))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(theme.hair, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
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
                .font(F.ui(12))
                .foregroundStyle(active ? theme.text : theme.text2)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
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
            HStack(spacing: 6) {
                Text("+")
                    .font(F.ui(15, .medium))
                Text("New agent")
                    .font(F.ui(12.5, .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.accent))
            .shadow(color: Color(r: 0, g: 0, b: 0, a: 0.16), radius: 1, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Helpers

/// A breathing pulse dot (ccPulse: opacity 1↔.35, scale 1↔.78).
private struct PulseDot: View {
    let color: Color
    let size: CGFloat
    var active: Bool = true
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(active ? (on ? 0.35 : 1) : 1)
            .scaleEffect(active ? (on ? 0.78 : 1) : 1)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

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
