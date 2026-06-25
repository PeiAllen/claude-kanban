import SwiftUI
import Foundation
import OrchestraCore

/// The "Spawn a new agent" sheet. ui-spec §3.7 / §4.7.
struct SpawnSheet: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    @State private var prompt = ""
    @State private var repo = ""
    @State private var branch = ""
    @State private var modelSel = ""
    @State private var startIn: StartIn = .plan

    /// Existing local branches in the selected repo (most-recently-committed first), loaded on appear
    /// and whenever the repo changes. Used to power the branch combo's fuzzy search.
    @State private var branches: [String] = []
    @State private var showBranchPopover = false
    @State private var branchQuery = ""
    @FocusState private var branchSearchFocused: Bool

    @State private var showRepoPopover = false
    @State private var repoQuery = ""
    @FocusState private var repoSearchFocused: Bool

    /// The agents the daemon actually supports. Falls back to the Claude Code adapter's own catalog
    /// when the daemon hasn't answered yet — never invents providers that aren't wired up.
    private var modelOptions: [AgentModel] {
        model.models.isEmpty ? ClaudeCodeAdapter().models() : model.models
    }

    /// Absolute paths of the git repositories under the configured repos root. The daemon only allows
    /// spawning inside an allowlisted root, so the repo must be a real path — not a bare name.
    private var repoCandidates: [String] {
        let root = (model.config.reposRoot as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        return entries
            .filter { !$0.hasPrefix(".") }
            .map { "\(root)/\($0)" }
            .filter { fm.fileExists(atPath: "\($0)/.git") }
            .sorted { ($0 as NSString).lastPathComponent.localizedCaseInsensitiveCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
    }
    private var repoName: String { (repo as NSString).lastPathComponent }

    /// Mirror the daemon's own worktree layout (Config.worktreePath) so the preview can't diverge.
    private var worktree: String {
        let root = model.config.worktreesRoot.replacingOccurrences(of: Config.home, with: "~")
        let repoName = (repo as NSString).lastPathComponent
        let slug = branch.isEmpty ? "…" : branch.replacingOccurrences(of: "/", with: "-")
        return "\(root)/\(repoName)/\(slug)"
    }

    private var canSpawn: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !repo.isEmpty && !branch.isEmpty
    }

    private var cliPreview: String {
        "$ orchestra spawn --prompt \"\(prompt.isEmpty ? "…" : prompt)\" --repo \(repo) --branch \(branch.isEmpty ? "…" : branch) --col \(startIn.column.rawValue)"
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
                                .padding(.horizontal, 11).padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $prompt)
                            .font(F.ui(13))
                            .foregroundColor(theme.text)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 6).padding(.vertical, 8)
                            .frame(height: 92)
                    }
                    .background(theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.fieldBorder, lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 11) {
                    field("Repository") { repoPicker }
                    field("Branch") { branchPicker }
                }

                field("Model") {
                    HStack(spacing: 2) {
                        ForEach(modelOptions, id: \.id) { m in
                            let active = m.id == modelSel
                            Button { modelSel = m.id } label: {
                                Text(m.displayName)
                                    .font(F.mono(11.5, .semibold))
                                    .foregroundColor(active ? brandColor(m) : theme.text2)
                                    .padding(.horizontal, 12).frame(height: 28)
                                    .background(active ? theme.card : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
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
            if repo.isEmpty { repo = repoCandidates.first ?? "" }
            if modelSel.isEmpty { modelSel = model.config.defaultModel ?? modelOptions.first?.id ?? "" }
            startIn = model.spawnDefaultColumn == .plan ? .plan : .impl
            branches = gitBranches(in: repo)
        }
        .onChange(of: repo) {
            branches = gitBranches(in: repo)
            if branch.isEmpty || !branches.contains(branch) { branch = "" }
        }
    }

    // MARK: helpers

    /// A combo of real repos under the repos root: shows the chosen repo and opens a popover where you
    /// can fuzzy-search the candidates by name. Falls back to a free-text absolute-path field when none
    /// are found (e.g. repos root unset or empty).
    @ViewBuilder private var repoPicker: some View {
        if repoCandidates.isEmpty {
            monoInput($repo)
        } else {
            Button {
                repoQuery = ""
                showRepoPopover = true
            } label: {
                HStack(spacing: 6) {
                    Text(repo.isEmpty ? "Choose a repo" : repoName)
                        .font(F.mono(12.5)).foregroundColor(repo.isEmpty ? theme.text3 : theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundColor(theme.text2)
                }
                .padding(.horizontal, 11).frame(height: 34)
                .frame(maxWidth: .infinity)
                .background(theme.field)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.fieldBorder, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showRepoPopover, arrowEdge: .bottom) { repoPopover }
        }
    }

    /// Repo candidates whose name fuzzy-matches the current query, in the candidates' sorted order.
    private var filteredRepos: [String] {
        repoCandidates.filter { fuzzyMatch(repoQuery, ($0 as NSString).lastPathComponent) }
    }

    private var repoPopover: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundColor(theme.text3)
                TextField("Search repositories", text: $repoQuery)
                    .textFieldStyle(.plain)
                    .font(F.mono(12.5)).foregroundColor(theme.text)
                    .focused($repoSearchFocused)
                    .onSubmit { if let first = filteredRepos.first { pickRepo(first) } }
            }
            .padding(.horizontal, 11).frame(height: 36)

            Divider().overlay(theme.hair)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(filteredRepos, id: \.self) { path in
                        ComboRow(label: (path as NSString).lastPathComponent, systemImage: "folder",
                                 tint: theme.text2, selected: path == repo, theme: theme) { pickRepo(path) }
                    }
                    if filteredRepos.isEmpty {
                        Text("No matches").font(F.ui(11.5)).foregroundColor(theme.text3)
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 220)
        }
        .frame(width: 270)
        .onAppear { repoSearchFocused = true }
    }

    private func pickRepo(_ path: String) {
        repo = path
        showRepoPopover = false
    }

    // MARK: Branch combo

    /// A combo field: shows the chosen branch (empty by default) and opens a popover where you can
    /// fuzzy-search the repo's existing branches or type a brand-new name to create one.
    private var branchPicker: some View {
        Button {
            branchQuery = branch
            showBranchPopover = true
        } label: {
            HStack(spacing: 6) {
                Text(branch.isEmpty ? "Pick or create branch" : branch)
                    .font(F.mono(12.5)).foregroundColor(branch.isEmpty ? theme.text3 : theme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundColor(theme.text2)
            }
            .padding(.horizontal, 11).frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(theme.field)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.fieldBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showBranchPopover, arrowEdge: .bottom) { branchPopover }
    }

    /// Branches matching the current query as a fuzzy subsequence, recency order preserved.
    private var filteredBranches: [String] {
        branches.filter { fuzzyMatch(branchQuery, $0) }
    }

    private var branchPopover: some View {
        let q = branchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let exactExists = branches.contains(q)
        return VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundColor(theme.text3)
                TextField("Search or create branch", text: $branchQuery)
                    .textFieldStyle(.plain)
                    .font(F.mono(12.5)).foregroundColor(theme.text)
                    .focused($branchSearchFocused)
                    .onSubmit { commitBranch(q.isEmpty ? (filteredBranches.first ?? "") : q) }
            }
            .padding(.horizontal, 11).frame(height: 36)

            Divider().overlay(theme.hair)

            ScrollView {
                VStack(spacing: 1) {
                    if !q.isEmpty && !exactExists {
                        ComboRow(label: "Create “\(q)”", systemImage: "plus.circle",
                                  tint: theme.accent, selected: false, theme: theme) { commitBranch(q) }
                    }
                    ForEach(filteredBranches, id: \.self) { b in
                        ComboRow(label: b, systemImage: "arrow.triangle.branch",
                                  tint: theme.text2, selected: b == branch, theme: theme) { commitBranch(b) }
                    }
                    if filteredBranches.isEmpty && (q.isEmpty || exactExists) {
                        Text(branches.isEmpty ? "No branches in this repo" : "No matches")
                            .font(F.ui(11.5)).foregroundColor(theme.text3)
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 220)
        }
        .frame(width: 270)
        .onAppear { branchSearchFocused = true }
    }

    /// Commit a branch choice (existing or new) and close the popover.
    private func commitBranch(_ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        branch = v
        showBranchPopover = false
    }

    /// Case-insensitive subsequence ("fuzzy") match — every char of `query` appears in order in `text`.
    private func fuzzyMatch(_ query: String, _ text: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return true }
        var qi = q.startIndex
        for ch in text.lowercased() {
            if ch == q[qi] {
                qi = q.index(after: qi)
                if qi == q.endIndex { return true }
            }
        }
        return false
    }

    /// Local branch names for a repo, most-recently-committed first. Empty on any failure (no repo,
    /// git missing, not a worktree) so the combo simply degrades to free-text branch creation.
    private func gitBranches(in repoPath: String) -> [String] {
        guard !repoPath.isEmpty else { return [] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", repoPath, "for-each-ref",
                          "--format=%(refname:short)", "--sort=-committerdate", "refs/heads"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

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
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func brandColor(_ m: AgentModel) -> Color {
        switch m.family {
        case "claude": return m.id.contains("opus") ? Color(hex: 0xBF5836) : Color(hex: 0xA8741C)
        case "gpt":    return Color(hex: 0x0E8C6D)
        case "gemini": return Color(hex: 0x3B73DB)
        default:       return theme.text
        }
    }
}

/// A single row in the branch combo's dropdown — an existing branch or the "Create …" affordance.
/// Carries its own hover state so the whole row (not just its text) highlights and is clickable.
private struct ComboRow: View {
    let label: String
    let systemImage: String
    let tint: Color
    let selected: Bool
    let theme: Theme
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 11)).foregroundColor(tint)
                    .frame(width: 13)
                Text(label)
                    .font(F.mono(12)).foregroundColor(theme.text).lineLimit(1)
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(theme.accent)
                }
            }
            .padding(.horizontal, 9).frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? theme.chipHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
