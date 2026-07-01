import SwiftUI
import Foundation
import OrchestraCore

/// The "Fan-out" board action: batch-spawn one worktree card per prompt line, off a shared repo +
/// base branch (each card gets `<branch>-<n>`). This is the human surface for UC6 (Fan-out) — a
/// board-level action (no card selected), distinct from the per-card Handoff/Fork/Send actions.
struct FanoutSheet: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    @State private var repo = ""
    @State private var branch = ""
    @State private var promptsText = ""

    /// One trimmed, non-empty prompt per line.
    private var prompts: [String] {
        promptsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canSpawn: Bool { !repo.isEmpty && !branch.isEmpty && !prompts.isEmpty }

    private var repoCandidates: [String] {
        let root = (model.config.reposRoot as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        return entries.filter { !$0.hasPrefix(".") }
            .map { "\(root)/\($0)" }
            .filter { fm.fileExists(atPath: "\($0)/.git") }
            .sorted { ($0 as NSString).lastPathComponent.localizedCaseInsensitiveCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Fan-out").font(F.ui(15, .bold)).foregroundColor(theme.text)
                Text("Batch-spawn one agent per line, off a shared repo + base branch.")
                    .font(F.ui(12)).foregroundColor(theme.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 19).padding(.top, 17).padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 11) {
                    field("Repository") {
                        Picker("", selection: $repo) {
                            Text("Choose a repo").tag("")
                            ForEach(repoCandidates, id: \.self) { p in
                                Text((p as NSString).lastPathComponent).tag(p)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    field("Base branch") { monoInput($branch, placeholder: "e.g. fanout") }
                }

                field("Prompts (one per line)") {
                    TextEditor(text: $promptsText)
                        .font(F.ui(13)).foregroundColor(theme.text)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 6).padding(.vertical, 8)
                        .frame(height: 120)
                        .background(theme.field)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.fieldBorder, lineWidth: 0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Text("\(prompts.count) card(s) → \(branch.isEmpty ? "…" : branch)-1 … \(branch.isEmpty ? "…" : branch)-\(max(prompts.count, 1))")
                    .font(F.mono(10.5)).foregroundColor(theme.text3)
            }
            .padding(.horizontal, 19).padding(.top, 12).padding(.bottom, 4)

            HStack(spacing: 9) {
                Spacer(minLength: 0)
                Button { model.showFanout = false } label: {
                    Text("Cancel").font(F.ui(12, .medium)).foregroundColor(theme.text)
                        .padding(.horizontal, 15).frame(height: 32)
                        .surface(theme.card, corner: 8, hair: theme.hair)
                }
                .buttonStyle(.plain)

                Button {
                    let ps = prompts, r = repo, b = branch
                    _Concurrency.Task {
                        await model.fanout(prompts: ps, repo: r, branch: b)
                        model.showFanout = false
                    }
                } label: {
                    Text("Fan out").font(F.ui(12, .semibold)).foregroundColor(.white)
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
        .onAppear { if repo.isEmpty { repo = repoCandidates.first ?? "" } }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(F.ui(11, .semibold)).foregroundColor(theme.text2)
            content()
        }
    }

    private func monoInput(_ binding: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: binding)
            .textFieldStyle(.plain)
            .font(F.mono(12.5)).foregroundColor(theme.text)
            .padding(.horizontal, 11).frame(height: 34)
            .background(theme.field)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.fieldBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
