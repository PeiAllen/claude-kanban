import SwiftUI
import Foundation
import AppKit
import OrchestraCore

/// The "Spawn a new agent" sheet. ui-spec §3.7 / §4.7.
struct SpawnSheet: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    /// Worktree (repo + branch, the default) vs Freeform (run in an existing directory) vs Scratch
    /// (a fresh throwaway dir Orchestra makes and deletes on archive).
    private enum Mode { case worktree, freeform, scratch }
    @State private var mode: Mode = .worktree

    @State private var prompt = ""
    @State private var repo = ""
    @State private var branch = ""
    @State private var agentSel = ""
    @State private var modelSel = ""
    @State private var startIn: StartIn = .plan

    /// Freeform card: the borrowed directory to run in, and whether it's read-only.
    @State private var cwd = ""
    @State private var readOnly = false

    /// T1 trust state for the freeform cwd (nil = unknown/unchecked). An untrusted borrowed dir can
    /// only run read-only (sandboxed) — granting trust is a separate human surface (the `trust` tool /
    /// `orchestra trust`), so here we surface the state and force the safe fallback.
    @State private var cwdTrusted: Bool? = nil

    /// Existing local branches in the selected repo (most-recently-committed first), loaded on appear
    /// and whenever the repo changes. Used to power the branch combo's fuzzy search.
    @State private var branches: [String] = []
    @State private var showBranchPopover = false
    @State private var branchQuery = ""

    @State private var showRepoPopover = false
    @State private var repoQuery = ""
    @FocusState private var repoSearchFocused: Bool

    // Keyboard highlight index into the filtered combo lists (Ctrl-j/k move it; Enter picks it).
    @State private var repoHi = 0
    @State private var branchHi = 0

    /// The agents the daemon actually supports (each with its own model catalog). Falls back to the
    /// Claude Code adapter alone when the daemon hasn't answered yet — never invents providers that
    /// aren't wired up.
    private var agentOptions: [AgentInfo] {
        if !model.agents.isEmpty { return model.agents }
        let a = ClaudeCodeAdapter()
        return [AgentInfo(id: a.id, name: a.name, icon: a.icon, models: a.models())]
    }

    /// The currently-selected agent (falls back to the first available).
    private var selectedAgent: AgentInfo? {
        agentOptions.first { $0.id == agentSel } ?? agentOptions.first
    }

    /// The selected agent's models — the Model picker's options.
    private var modelOptions: [AgentModel] { selectedAgent?.models ?? [] }

    /// The default model for the selected agent: the configured default when it belongs to this agent,
    /// else the agent's first model. Used on appear and whenever the agent changes.
    private func defaultModelForAgent() -> String {
        let models = modelOptions
        if let d = model.config.defaultModel, models.contains(where: { $0.id == d }) { return d }
        return models.first?.id ?? ""
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

    /// The prompt is optional: spawning with an empty prompt drops you into the agent and the card is
    /// named off the first prompt you type (e.g. `/layered-plan`). Repo + branch are still required.
    private var canSpawn: Bool {
        switch mode {
        case .worktree: return !repo.isEmpty && !branch.isEmpty
        case .freeform: return !cwd.isEmpty
        case .scratch:  return true   // nothing to pick — Orchestra makes the dir
        }
    }

    /// `--agent <id>` only when a non-default agent is picked (keeps the common Claude preview clean).
    private var agentFlag: String {
        guard !agentSel.isEmpty, agentSel != model.config.defaultAgentId else { return "" }
        return " --agent \(agentSel)"
    }

    private var cliPreview: String {
        switch mode {
        case .worktree:
            return "$ orchestra spawn --prompt \"\(prompt.isEmpty ? "…" : prompt)\"\(agentFlag) --repo \(repo) --branch \(branch.isEmpty ? "…" : branch) --col \(startIn.column.rawValue)"
        case .freeform:
            return "$ orchestra spawn --prompt \"\(prompt.isEmpty ? "…" : prompt)\"\(agentFlag) --cwd \(cwd.isEmpty ? "…" : cwd)\(readOnly ? " --read-only" : "")"
        case .scratch:
            return "$ orchestra spawn --prompt \"\(prompt.isEmpty ? "…" : prompt)\"\(agentFlag) --scratch"
        }
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
                field("Initial prompt (optional)") {
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

                field("Run in") {
                    HStack(spacing: 2) {
                        modeButton("Worktree", .worktree)
                        modeButton("Freeform", .freeform)
                        modeButton("Scratch", .scratch)
                    }
                    .padding(2)
                    .background(theme.chip)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                switch mode {
                case .worktree:
                    HStack(spacing: 11) {
                        field("Repository") { repoPicker }
                        field("Branch") { branchPicker }
                    }
                case .freeform:
                    field("Directory") { directoryPicker }
                case .scratch:
                    field("Directory") { scratchNote }
                }

                if agentOptions.count > 1 {
                    field("Agent") {
                        HStack(spacing: 2) {
                            ForEach(agentOptions) { a in agentButton(a) }
                        }
                        .padding(2)
                        .background(theme.chip)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
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

                if mode == .worktree {
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
                } else if mode == .freeform {
                    Toggle(isOn: $readOnly) {
                        Text("Read-only (agent can read, search & run git, but cannot edit or write)")
                            .font(F.ui(12)).foregroundColor(theme.text2)
                    }
                    .toggleStyle(.checkbox)
                    // An untrusted borrowed dir is forced read-only (can't be unchecked here).
                    .disabled(cwdTrusted == false)

                    trustNotice
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
                    let a = agentSel.isEmpty ? nil : agentSel
                    _Concurrency.Task {
                        switch mode {
                        case .worktree:
                            await model.spawn(prompt: prompt, repo: repo, branch: branch, model: m, startIn: startIn,
                                              agent: a)
                        case .freeform:
                            await model.spawn(prompt: prompt, repo: "", branch: "", model: m, startIn: startIn,
                                              agent: a, cwd: cwd, access: readOnly ? .readOnly : .readWrite)
                        case .scratch:
                            await model.spawn(prompt: prompt, repo: "", branch: "", model: m, startIn: startIn,
                                              agent: a, scratch: true)
                        }
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
            if agentSel.isEmpty { agentSel = model.config.defaultAgentId }
            // Guard against a stale/unknown default agent id (adapter disabled, etc.).
            if !agentOptions.contains(where: { $0.id == agentSel }) { agentSel = agentOptions.first?.id ?? "" }
            if modelSel.isEmpty { modelSel = defaultModelForAgent() }
            startIn = model.spawnDefaultColumn == .plan ? .plan : .impl
            branches = gitBranches(in: repo)
        }
        // Switching agent re-scopes the Model picker: reset to this agent's default/first model.
        .onChange(of: agentSel) { modelSel = defaultModelForAgent() }
        .onChange(of: repo) {
            branches = gitBranches(in: repo)
            if branch.isEmpty || !branches.contains(branch) { branch = "" }
        }
        .onChange(of: cwd) { refreshTrust() }
        .onChange(of: mode) { refreshTrust() }
    }

    // MARK: helpers

    /// The freeform trust indicator (reads T1's ledger via the daemon). Three states:
    ///   • cwd empty / unchecked → nothing;
    ///   • trusted → a subtle "Trusted ✓";
    ///   • untrusted → an amber notice; the card is forced read-only (sandboxed) here — granting trust
    ///     is a separate human surface (the `trust` tool / `orchestra trust`).
    @ViewBuilder private var trustNotice: some View {
        if !cwd.isEmpty, let trusted = cwdTrusted {
            if trusted {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield").font(.system(size: 10, weight: .semibold))
                    Text("Trusted directory").font(F.ui(11)).foregroundColor(theme.text2)
                }
                .foregroundColor(theme.green.dot)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundColor(theme.amber.dot)
                    Text("Not a trusted directory — it will run read-only (sandboxed). Grant trust from "
                        + "the agent’s client or `orchestra trust` to enable read-write.")
                        .font(F.ui(11)).foregroundColor(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .surface(theme.chip, corner: 8, hair: theme.hair)
            }
        }
    }

    /// Re-check trust for the current freeform cwd, forcing read-only when untrusted.
    private func refreshTrust() {
        guard mode == .freeform, !cwd.isEmpty else { cwdTrusted = nil; return }
        let path = cwd
        _Concurrency.Task {
            let trusted = await model.trustState(path: path)
            await MainActor.run {
                guard path == cwd else { return }   // ignore a stale result after the dir changed
                cwdTrusted = trusted
                if !trusted { readOnly = true }
            }
        }
    }

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
                    .onSubmit { pickHighlightedRepo() }
                    .onChange(of: repoQuery) { _, _ in repoHi = 0 }
            }
            .padding(.horizontal, 11).frame(height: 36)

            Divider().overlay(theme.hair)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(filteredRepos.enumerated()), id: \.element) { idx, path in
                        ComboRow(label: (path as NSString).lastPathComponent, systemImage: "folder",
                                 tint: theme.text2, selected: idx == repoHi, theme: theme) { pickRepo(path) }
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
        .onAppear { repoSearchFocused = true; repoHi = 0 }
        .onKeyPress(phases: .down) { press in comboMove(press, count: filteredRepos.count, hi: $repoHi) }
    }

    private func pickHighlightedRepo() {
        let list = filteredRepos
        guard !list.isEmpty else { return }
        pickRepo(list[min(max(0, repoHi), list.count - 1)])
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
                BranchSearchField(text: $branchQuery, textColor: theme.text) { live in
                    // `live` is the field's own current content, read straight off the NSTextField at
                    // Return time — unlike a SwiftUI binding it never lags the final keystroke. With
                    // matches present, Enter commits the Ctrl-j/k-highlighted branch; otherwise it
                    // creates the typed name.
                    let cur = live.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !filteredBranches.isEmpty {
                        commitBranch(filteredBranches[min(max(0, branchHi), filteredBranches.count - 1)])
                    } else {
                        commitBranch(cur)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 11).frame(height: 36)

            Divider().overlay(theme.hair)

            ScrollView {
                VStack(spacing: 1) {
                    if !q.isEmpty && !exactExists {
                        ComboRow(label: "Create “\(q)”", systemImage: "plus.circle",
                                  tint: theme.accent, selected: false, theme: theme) { commitBranch(q) }
                    }
                    ForEach(Array(filteredBranches.enumerated()), id: \.element) { idx, b in
                        ComboRow(label: b, systemImage: "arrow.triangle.branch",
                                  tint: theme.text2, selected: idx == branchHi, theme: theme) { commitBranch(b) }
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
        .onAppear { branchHi = 0 }
        .onChange(of: branchQuery) { _, _ in branchHi = 0 }
        .onKeyPress(phases: .down) { press in comboMove(press, count: filteredBranches.count, hi: $branchHi) }
    }

    /// Ctrl-j / Ctrl-k move a combo's highlight index (clamped). Returns `.handled` when it consumes a
    /// key, `.ignored` otherwise (so typing still reaches the search field).
    private func comboMove(_ press: KeyPress, count: Int, hi: Binding<Int>) -> KeyPress.Result {
        guard press.modifiers.contains(.control), count > 0 else { return .ignored }
        switch press.characters {
        case "j": hi.wrappedValue = min(count - 1, hi.wrappedValue + 1); return .handled
        case "k": hi.wrappedValue = max(0, hi.wrappedValue - 1); return .handled
        default:  return .ignored
        }
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

    /// One segment of the Agent picker — an adapter's icon + name. Selecting it re-scopes the Model
    /// picker to that agent's catalog (via `.onChange(of: agentSel)`).
    private func agentButton(_ info: AgentInfo) -> some View {
        let active = agentSel == info.id
        return Button { agentSel = info.id } label: {
            HStack(spacing: 5) {
                Image(systemName: info.icon).font(.system(size: 11, weight: .semibold))
                Text(info.name).font(F.ui(12, .semibold))
            }
            .foregroundColor(active ? theme.text : theme.text2)
            .padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 28)
            .background(active ? theme.card : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modeButton(_ label: String, _ value: Mode) -> some View {
        let active = mode == value
        return Button { mode = value } label: {
            Text(label).font(F.ui(12, .semibold))
                .foregroundColor(active ? theme.text : theme.text2)
                .padding(.horizontal, 14).frame(maxWidth: .infinity).frame(height: 28)
                .background(active ? theme.card : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Freeform directory chooser: shows the picked path and opens an `NSOpenPanel` (directories only).
    private var directoryPicker: some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            if panel.runModal() == .OK, let url = panel.url { cwd = url.path }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 11)).foregroundColor(theme.text2)
                Text(cwd.isEmpty ? "Choose a directory" : cwd)
                    .font(F.mono(12.5)).foregroundColor(cwd.isEmpty ? theme.text3 : theme.text)
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 11).frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(theme.field)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.fieldBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Scratch mode has nothing to pick — show the path Orchestra will create + the throwaway warning.
    private var scratchNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 11)).foregroundColor(theme.text2)
            Text("~/.orchestra/scratch/<id> — created now, deleted when you archive the card.")
                .font(F.mono(11.5)).foregroundColor(theme.text2)
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).frame(height: 34)
        .surface(theme.chip, corner: 8, hair: theme.hair)
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

// MARK: - Branch search field (AppKit-backed)

/// The branch search/create field, backed by an AppKit `NSTextField` rather than SwiftUI's `TextField`.
/// SwiftUI flushes a `TextField`'s text binding asynchronously, so when the user types the final
/// character and presses Return together, `.onSubmit` fires *before* the binding catches up and the
/// committed branch name comes out one character short. Reading the field's own `string` at Return time
/// is always current, so the last character is never dropped.
private struct BranchSearchField: NSViewRepresentable {
    @Binding var text: String
    var textColor: Color
    var onSubmit: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let tf = AutoFocusTextField()
        tf.delegate = context.coordinator
        tf.placeholderString = "Search or create branch"
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tf.textColor = NSColor(textColor)
        tf.cell?.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        context.coordinator.parent = self
        if tf.stringValue != text { tf.stringValue = text }
        tf.textColor = NSColor(textColor)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BranchSearchField
        init(_ parent: BranchSearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let tf = note.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit(textView.string)   // live field content — never lags a keystroke
                return true
            }
            return false
        }
    }
}

/// An `NSTextField` that grabs keyboard focus the instant it's mounted in a window, so the branch
/// popover's search field is ready to type into without a click.
private final class AutoFocusTextField: NSTextField {
    private var didFocus = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didFocus, window != nil else { return }
        didFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }
}
