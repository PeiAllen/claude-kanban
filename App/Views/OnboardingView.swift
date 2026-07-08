import SwiftUI
import OrchestraUI
import OrchestraCore
import AppKit

/// First-run welcome that asks the user to install Orchestra's mandatory background daemon. Shown
/// full-window over the board until the daemon is installed + connected (or the user quits).
struct OnboardingView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    var body: some View {
        ZStack {
            theme.winBg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                logo
                    .padding(.bottom, 22)

                Text("Welcome to Orchestra")
                    .font(F.ui(23, .bold)).tracking(-0.4)
                    .foregroundStyle(theme.text)
                Text("Run autonomous coding agents in isolated git worktrees.")
                    .font(F.ui(13.5)).foregroundStyle(theme.text2)
                    .padding(.top, 5)

                daemonCard
                    .frame(maxWidth: 420)
                    .padding(.top, 26)

                actions
                    .frame(maxWidth: 420)
                    .padding(.top, 18)

                Spacer(minLength: 0)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Logo

    private var logo: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
                LinearGradient(colors: [theme.accent.opacity(0.92), theme.accent],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: 76, height: 76)
            .overlay {
                HStack(alignment: .bottom, spacing: 7) {
                    bar(0.52); bar(0.74); bar(0.40)
                }
                .frame(height: 34)
            }
            .shadow(color: theme.accent.opacity(0.35), radius: 14, y: 8)
    }

    private func bar(_ frac: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(.white)
            .frame(width: 9, height: 34 * frac)
    }

    // MARK: - Daemon explainer

    private var daemonCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 26)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Install the background service")
                    .font(F.ui(13, .semibold)).foregroundStyle(theme.text)
                Text("Orchestra needs a small background daemon to manage agents and keep them running when this window is closed. It installs as a login-time service (a LaunchAgent) and can be removed at any time.")
                    .font(F.ui(12)).foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1.5)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(theme.card, corner: 12, hair: theme.hair)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                _Concurrency.Task { await model.installDaemon() }
            } label: {
                HStack(spacing: 7) {
                    if model.connecting { ProgressView().controlSize(.small).tint(.white) }
                    Text(model.connecting ? "Installing…" : "Install & Start")
                        .font(F.ui(13, .semibold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.accent))
            }
            .buttonStyle(.plain)
            .disabled(model.connecting)

            Button { NSApp.terminate(nil) } label: {
                Text("Quit")
                    .font(F.ui(12.5, .medium)).foregroundStyle(theme.text2)
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
