import SwiftUI
import OrchestraCore

/// The "Spawn a new agent" sheet. ui-spec §3.7 / §4.7.
struct SpawnSheet: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    @State private var prompt = ""
    @State private var repo = ""
    @State private var branch = "feat/new-task"
    @State private var modelSel = ""
    @State private var startIn: StartIn = .impl

    private var modelOptions: [String] {
        model.models.isEmpty
            ? ["claude-opus-4-5", "claude-sonnet-4-5", "gpt-4o", "gemini-2.5-pro"]
            : model.models
    }

    /// Mirror the daemon's own worktree layout (Config.worktreePath) so the preview can't diverge.
    private var worktree: String {
        let root = model.config.worktreesRoot.replacingOccurrences(of: Config.home, with: "~")
        let repoName = (repo as NSString).lastPathComponent
        return "\(root)/\(repoName)/\(branch.replacingOccurrences(of: "/", with: "-"))"
    }

    private var canSpawn: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !repo.isEmpty && !branch.isEmpty
    }

    private var cliPreview: String {
        "$ orchestra spawn --prompt \"\(prompt.isEmpty ? "…" : prompt)\" --repo \(repo) --branch \(branch) --col \(startIn.column.rawValue)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 2) {
                Text("Spawn a new agent").font(F.ui(15, .bold)).foregroundColor(theme.text)
                Text("Start an autonomous agent in an isolated worktree.")
                    .font(F.ui(12)).foregroundColor(theme.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 19).padding(.top, 17).padding(.bottom, 6)

            // Body
            VStack(alignment: .leading, spacing: 12) {
                field("Initial prompt") {
                    ZStack(alignment: .topLeading) {
                        if prompt.isEmpty {
                            Text("e.g. Add rate limiting to the API")
                                .font(F.ui(13)).foregroundColor(theme.text3)
                                .padding(.horizontal, 11).padding(.vertical, 9)
                        }
                        TextEditor(text: $prompt)
                            .font(F.ui(13))
                            .foregroundColor(theme.text)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .frame(minHeight: 54)
                    }
                    .background(theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.fieldBorder, lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 11) {
                    field("Repository") { monoInput($repo) }
                    field("Branch") { monoInput($branch) }
                }

                field("Model") {
                    HStack(spacing: 2) {
                        ForEach(modelOptions, id: \.self) { m in
                            let active = m == modelSel
                            Button { modelSel = m } label: {
                                Text(ModelDisplay.short(m))
                                    .font(F.mono(11.5, .semibold))
                                    .foregroundColor(active ? brandColor(m) : theme.text2)
                                    .padding(.horizontal, 12).frame(height: 28)
                                    .background(active ? theme.card : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(theme.chip)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                field("Worktree") {
                    Text(worktree)
                        .font(F.mono(11.5)).foregroundColor(theme.text2)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11).frame(height: 34)
                        .surface(theme.chip, corner: 8, hair: theme.hair)
                }

                field("Start in") {
                    HStack(spacing: 2) {
                        startButton("Plan", .plan)
                        startButton("Implementation", .impl)
                    }
                    .padding(2)
                    .background(theme.chip)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 19).padding(.top, 12).padding(.bottom, 4)

            // CLI equivalent
            VStack(alignment: .leading, spacing: 4) {
                Text("CLI EQUIVALENT")
                    .font(F.ui(9.5, .semibold)).tracking(0.7).foregroundColor(theme.text3)
                Text(cliPreview)
                    .font(F.mono(10.5)).foregroundColor(theme.text2)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .surface(theme.chip, corner: 8, hair: theme.hair)
            .padding(.horizontal, 19).padding(.top, 4)

            // Footer
            HStack(spacing: 9) {
                Spacer(minLength: 0)
                Button { model.showSpawn = false } label: {
                    Text("Cancel").font(F.ui(12, .medium)).foregroundColor(theme.text)
                        .padding(.horizontal, 15).frame(height: 32)
                        .surface(theme.card, corner: 8, hair: theme.hair)
                }
                .buttonStyle(.plain)

                Button {
                    let m = modelSel.isEmpty ? nil : modelSel
                    _Concurrency.Task {
                        await model.spawn(prompt: prompt, repo: repo, branch: branch, model: m, startIn: startIn)
                        model.showSpawn = false
                    }
                } label: {
                    Text("Spawn agent").font(F.ui(12, .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 16).frame(height: 32)
                        .background(theme.accent.opacity(canSpawn ? 1 : 0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!canSpawn)
            }
            .padding(.horizontal, 19).padding(.top, 6).padding(.bottom, 17)
        }
        .frame(width: 470)
        .surface(theme.winBg, corner: 13, hair: theme.hair)
        .shadow(color: Color(r: 20, g: 18, b: 40, a: 0.4), radius: 35, x: 0, y: 28)
        .onAppear {
            if repo.isEmpty {
                let last = (model.config.reposRoot as NSString).lastPathComponent
                repo = last.isEmpty ? "api-gateway" : last
            }
            if modelSel.isEmpty { modelSel = model.config.defaultModel ?? modelOptions.first ?? "" }
            startIn = model.spawnDefaultColumn == .plan ? .plan : .impl
        }
    }

    // MARK: helpers

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(F.ui(11, .semibold)).foregroundColor(theme.text2)
            content()
        }
    }

    private func monoInput(_ binding: Binding<String>) -> some View {
        TextField("", text: binding)
            .textFieldStyle(.plain)
            .font(F.mono(12.5))
            .foregroundColor(theme.text)
            .padding(.horizontal, 11).frame(height: 34)
            .background(theme.field)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.fieldBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func startButton(_ label: String, _ value: StartIn) -> some View {
        let active = startIn == value
        return Button { startIn = value } label: {
            Text(label).font(F.ui(12, .semibold))
                .foregroundColor(active ? theme.text : theme.text2)
                .padding(.horizontal, 14).frame(maxWidth: .infinity).frame(height: 28)
                .background(active ? theme.card : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func brandColor(_ m: String) -> Color {
        switch ModelDisplay.family(m) {
        case "claude": return m.contains("opus") ? Color(hex: 0xBF5836) : Color(hex: 0xA8741C)
        case "gpt":    return Color(hex: 0x0E8C6D)
        case "gemini": return Color(hex: 0x3B73DB)
        default:       return theme.text
        }
    }
}
