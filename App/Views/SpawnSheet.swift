import SwiftUI
import OrchestraUI
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
    /// BT2: an existing local branch to create the new branch ON TOP OF (empty = none = today's HEAD
    /// behavior). Sourced from the same `branches` list as the branch combo.
    @State private var base = ""
    /// BT6: a REMOTE parent to branch from — `origin/<branch>` (same-repo remote branch) or `pr#<N>`
    /// (pull request). The daemon fetches + watches it. Non-empty ⇒ it wins over the local base picker.
    @State private var remoteBase = ""

    /// The base to actually send: `nil` unless a base is chosen AND the branch is newly created — the
    /// daemon ignores base for an existing branch, so we neither send nor preview it there. A typed remote
    /// parent (pr#N / origin/branch) takes precedence over the local base picker.
    private var effectiveBase: String? {
        if branches.contains(branch) { return nil }
        let rb = remoteBase.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rb.isEmpty { return rb }
        return base.isEmpty ? nil : base
    }
    @State private var agentSel = ""
    @State private var modelSel = ""
    @State private var startIn: StartIn = .plan

    /// Freeform card: the borrowed directory to run in, and whether it's read-only.
    @State private var cwd = ""
    @State private var readOnly = false

    /// The freeform cwd's trust state machine (T1 lookup + T2 grant), shared with the iOS spawn sheet via
    /// OrchestraUI so the two can't drift. It owns `cwdTrusted` and the generation race guard; this sheet
    /// keeps its own view (checkbox + amber banner) and `readOnly` side effects. An untrusted borrowed dir
    /// runs read-only (sandboxed) until the human grants trust — which they can do right here via "Trust
    /// this directory" (the app is a human grant surface, so it flips the dir read-write) or out-of-band
    /// with the `trust` tool / `orchestra trust`.
    @StateObject private var trust = FreeformTrustModel()

    /// Existing local branches in the selected repo (most-recently-committed first), loaded on appear
    /// and whenever the repo changes. Used to power the branch combo's fuzzy search.
    @State private var branches: [String] = []
    @State private var showBranchPopover = false
    @State private var branchQuery = ""

    @State private var showRepoPopover = false
    @State private var repoQuery = ""
    @FocusState private var repoSearchFocused: Bool

    /// PR6a stable-id reuse-on-retry: the in-flight/just-failed spawn attempt's client-minted id, so a
    /// retry after failure dedups onto the same card instead of spawning a duplicate. Cleared only on
    /// success; a failure keeps it so the next click reuses it.
    @State private var pendingSpawnId: UUID? = nil

    // Keyboard highlight index into the filtered combo lists (Ctrl-j/k move it; Enter picks it).
    @State private var repoHi = 0
    @State private var branchHi = 0

    /// The agents the daemon actually supports (each with its own model catalog). Falls back to the
    /// Claude Code adapter alone when the daemon hasn't answered yet — never invents providers that
    /// aren't wired up.
    ///
    /// `capabilities: nil` even though this side CAN reach the adapter: the local adapter is this app
    /// build's opinion, not the running daemon's answer, and the sheet reads only name/icon/models to
    /// draw its pickers. Claiming a profile we were never told is the drift b81c090 set out to remove —
    /// and it keeps both spawn sheets saying the same honest "not told yet".
    private var agentOptions: [AgentInfo] {
        if !model.agents.isEmpty { return model.agents }
        let a = ClaudeCodeAdapter()
        return [AgentInfo(id: a.id, name: a.name, icon: a.icon,
                          models: a.models(), capabilities: nil)]
    }

    /// The currently-selected agent (falls back to the first available).
    private var selectedAgent: AgentInfo? {
        agentOptions.first { $0.id == agentSel } ?? agentOptions.first
    }

    /// The selected agent's models — the Model picker's options.
    private var modelOptions: [AgentModel] { selectedAgent?.models ?? [] }

    /// The sheet's fixed geometry, named once and shared between the layout modifiers below and
    /// `modelGridColumnCount`'s math — so the two can't silently drift apart if the sheet is ever
    /// resized. Every SITE that uses one of these values (the .frame(width:), the Body VStack's
    /// .padding(.horizontal:), the Model grid's own .padding(), and its GridItem spacing/minimum)
    /// reads it from here, never repeats the literal.
    private enum Layout {
        static let sheetWidth: CGFloat = 470
        static let bodyHorizontalPadding: CGFloat = 19
        static let modelGridPadding: CGFloat = 2
        static let modelGridSpacing: CGFloat = 2
        static let modelGridMinItemWidth: CGFloat = 88
    }

    /// The Model grid's column count, chosen to BALANCE rows instead of greedy-filling them: the
    /// largest count that fits (`maxFit`, from the sheet's fixed geometry — `Layout` above)
    /// determines the row count, then the column count divides the catalog evenly across those rows.
    /// 6 models -> 3+3, 8 -> 4+4, 4 -> 4 (one row), 5 -> 3+2 — never a ragged last row with empty slots.
    private var modelGridColumnCount: Int {
        let n = modelOptions.count
        guard n > 0 else { return 1 }
        // Sheet width minus the Body VStack's horizontal padding (both sides) minus the grid's own
        // padding (both sides) — see field("Model")'s .padding(Layout.modelGridPadding) and the Body
        // VStack's .padding(.horizontal, Layout.bodyHorizontalPadding) below.
        let available = Layout.sheetWidth - Layout.bodyHorizontalPadding * 2 - Layout.modelGridPadding * 2
        let minItemWidth = Layout.modelGridMinItemWidth
        let spacing = Layout.modelGridSpacing
        var maxFit = 1
        while CGFloat(maxFit + 1) * minItemWidth + CGFloat(maxFit) * spacing <= available { maxFit += 1 }
        let rows = Int((Double(n) / Double(maxFit)).rounded(.up))
        return Int((Double(n) / Double(rows)).rounded(.up))
    }

    /// The default model for the selected agent: the configured default when it belongs to this agent,
    /// else the agent's first model. Used on appear and whenever the agent changes.
    private func defaultModelForAgent() -> String {
        let models = modelOptions
        if let d = model.config.defaultModel, models.contains(where: { $0.id == d }) { return d }
        return models.first?.id ?? ""
    }

    /// Absolute paths of the git repositories under the configured repos root — populated by an async
    /// recursive scan (`loadRepoCandidates`). The daemon only allows spawning inside an allowlisted
    /// root, so the repo must be a real path, not a bare name. The scan runs off the main thread: the
    /// root defaults to `$HOME`, and a deep filesystem walk on the main thread would beachball the sheet.
    @State private var repoCandidates: [String] = []
    /// True while the recursive scan is in flight — drives the picker's "Scanning…" placeholder.
    @State private var reposScanning = false

    /// Kick off the recursive repo scan off the main thread, then publish results on the main actor and
    /// default the repo selection to the first candidate if the user hasn't already picked one.
    private func loadRepoCandidates() {
        let root = model.config.reposRoot
        reposScanning = true
        _Concurrency.Task {
            let found = await RepoScanner.discoverAsync(root: root)
            await MainActor.run {
                repoCandidates = found
                reposScanning = false
                if repo.isEmpty { repo = found.first ?? "" }
            }
        }
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
        case .worktree: return !repo.isEmpty && !branch.isEmpty && remoteBaseWellFormed   // S3-2: block a malformed remote ref
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
            let baseFlag = effectiveBase.map { " --base \($0)" } ?? ""
            return "$ orchestra spawn --prompt \"\(prompt.isEmpty ? "…" : prompt)\"\(agentFlag) --repo \(repo) --branch \(branch.isEmpty ? "…" : branch)\(baseFlag) --col \(startIn.column.rawValue)"
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
                    // Base only applies when the branch is newly created; hide it for a branch that
                    // already exists (the daemon ignores base there anyway).
                    if !branches.contains(branch) {
                        field("Base branch (optional)") { basePicker }
                        field("Remote parent (optional — pr#12 or origin/branch)") { remoteBaseField }
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
                    // A WRAPPING grid, not a single row: an agent's catalog grows,
                    // and a fixed HStack silently truncates every label past ~6 — which made the three
                    // GPT-5.6 variants render as an identical "GPT-5.6…". Flowing onto a second row keeps
                    // every model legible at any catalog size.
                    //
                    // BALANCED columns, not `.adaptive` greedy-fill: `.adaptive` packs as many columns as
                    // fit then wraps the remainder, so 6 models (Codex's post-refresh count) rendered 4+2 —
                    // a ragged last row with two empty slots. modelGridColumnCount instead picks the column
                    // count that divides the catalog evenly (6 -> 3+3, 8 -> 4+4, 4 -> 4, 5 -> 3+2).
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Layout.modelGridSpacing),
                                              count: modelGridColumnCount), spacing: Layout.modelGridSpacing) {
                        ForEach(modelOptions, id: \.id) { m in
                            let active = m.id == modelSel
                            Button { modelSel = m.id } label: {
                                Text(m.displayName)
                                    .font(F.mono(11.5, .semibold))
                                    .foregroundColor(active ? brandColor(m) : theme.text2)
                                    .lineLimit(2).minimumScaleFactor(0.85)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 8)
                                    .frame(maxWidth: .infinity).frame(height: 32)
                                    .background(active ? theme.card : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(Layout.modelGridPadding)
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
                    .disabled(trust.cwdTrusted == false)

                    trustNotice
                }
            }
            .padding(.horizontal, Layout.bodyHorizontalPadding).padding(.top, 12).padding(.bottom, 4)

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
                    let sid = BoardStore.spawnAttemptId(reusing: pendingSpawnId)
                    pendingSpawnId = sid
                    _Concurrency.Task {
                        let spawned: Task?
                        switch mode {
                        case .worktree:
                            spawned = await model.spawn(id: sid, prompt: prompt, repo: repo, branch: branch, model: m,
                                                        startIn: startIn, agent: a, base: effectiveBase)
                        case .freeform:
                            spawned = await model.spawn(id: sid, prompt: prompt, repo: "", branch: "", model: m,
                                                        startIn: startIn, agent: a, cwd: cwd,
                                                        access: readOnly ? .readOnly : .readWrite)
                        case .scratch:
                            spawned = await model.spawn(id: sid, prompt: prompt, repo: "", branch: "", model: m,
                                                        startIn: startIn, agent: a, scratch: true)
                        }
                        // S3-2: only dismiss on success — a typo'd base/remote must not cost the whole form
                        // (the error surfaces as a toast; the sheet stays so the user can fix + retry).
                        // Clear the pending id only on success; a failure keeps it so a retry dedups (PR6a).
                        if spawned != nil { pendingSpawnId = nil; model.showSpawn = false }
                    }
                } label: {
                    Text("Spawn agent").font(F.ui(12, .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 16).frame(height: 32)
                        .background(theme.accent.opacity(canSpawn ? 1 : 0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!canSpawn || model.isSpawning)
            }
            .padding(.horizontal, 19).padding(.top, 6).padding(.bottom, 17)
        }
        .frame(width: Layout.sheetWidth)
        .surface(theme.winBg, corner: 13, hair: theme.hair)
        .shadow(color: Color(r: 20, g: 18, b: 40, a: 0.4), radius: 35, x: 0, y: 28)
        .onAppear {
            #if DEBUG
            // Headless screenshot hook (scripts/orch-ui-shot.sh): preset the mode + freeform cwd so the
            // freeform trust notice (and its "Trust this directory" button) is screenshotable. With no
            // daemon behind the mock, trustState resolves untrusted — exactly the state under test.
            if let m = ProcessInfo.processInfo.environment["ORCH_SPAWN_MODE"] {
                switch m { case "freeform": mode = .freeform; case "scratch": mode = .scratch; default: break }
            }
            if let c = ProcessInfo.processInfo.environment["ORCH_SPAWN_CWD"], !c.isEmpty { cwd = c }
            #endif
            loadRepoCandidates()
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
            if !base.isEmpty && !branches.contains(base) { base = "" }
            remoteBase = ""   // S3-2: a pr#/origin ref typed for the old repo names a different thing here
        }
        .onChange(of: cwd) { refreshTrust() }
        .onChange(of: mode) { refreshTrust() }
    }

    // MARK: helpers

    /// The freeform trust indicator (reads T1's ledger via the daemon). Three states:
    ///   • cwd empty / unchecked → nothing;
    ///   • trusted → a subtle "Trusted ✓";
    ///   • untrusted → an amber notice plus a "Trust this directory" button. The card is read-only
    ///     (sandboxed) until the human grants trust — clicking the button *is* that human grant (the app
    ///     is a grant surface), which records the dir in the ledger and flips the card read-write.
    @ViewBuilder private var trustNotice: some View {
        if !cwd.isEmpty, let trusted = trust.cwdTrusted {
            if trusted {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield").font(.system(size: 10, weight: .semibold))
                    Text("Trusted directory").font(F.ui(11)).foregroundColor(theme.text2)
                }
                .foregroundColor(theme.green.dot)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundColor(theme.amber.dot)
                        Text("Not a trusted directory — it will run read-only (sandboxed). Trust it to "
                            + "let the agent edit, write & commit here.")
                            .font(F.ui(11)).foregroundColor(theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(action: grantTrust) {
                        HStack(spacing: 5) {
                            if trust.granting {
                                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 11, height: 11)
                            } else {
                                Image(systemName: "checkmark.shield").font(.system(size: 10, weight: .semibold))
                            }
                            Text("Trust this directory").font(F.ui(11.5, .semibold))
                        }
                        .foregroundColor(theme.text)
                        .padding(.horizontal, 11).frame(height: 28)
                        .surface(theme.card, corner: 7, hair: theme.hair)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(trust.granting)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .surface(theme.chip, corner: 8, hair: theme.hair)
            }
        }
    }

    /// Re-check trust for the current freeform cwd, forcing read-only when untrusted. The generation +
    /// path guard (shared with iOS) lives in `FreeformTrustModel`, so a stale reply can't clobber a newer
    /// result — the desktop now has the grant-vs-refresh race guard it previously lacked (bug #7).
    private func refreshTrust() {
        guard mode == .freeform, !cwd.isEmpty else { trust.reset(); return }
        let path = cwd
        _Concurrency.Task {
            let outcome = await trust.refresh(path: path) { await model.trustState(path: $0) }
            if outcome == .untrusted { await MainActor.run { readOnly = true } }
        }
    }

    /// Grant the human's trust for the current freeform cwd (T2). On success the dir is trusted, so we
    /// clear the read-only lock and default the card to read-write — the user asked to enable writes.
    private func grantTrust() {
        _Concurrency.Task {
            let outcome = await trust.grant { await model.trust(path: $0) }
            if outcome == .granted { await MainActor.run { readOnly = false } }
        }
    }

    /// A combo of real repos under the repos root: shows the chosen repo and opens a popover where you
    /// can fuzzy-search the candidates by name. Falls back to a free-text absolute-path field when none
    /// are found (e.g. repos root unset or empty).
    @ViewBuilder private var repoPicker: some View {
        if reposScanning && repoCandidates.isEmpty {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 11, height: 11)
                Text("Scanning repositories…").font(F.mono(12.5)).foregroundColor(theme.text3)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 11).frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(theme.field)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.fieldBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if repoCandidates.isEmpty {
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
                                 tint: theme.text2, selected: path == repo, highlighted: idx == repoHi,
                                 theme: theme) { pickRepo(path) }
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
        .onAppear { repoSearchFocused = true; repoHi = filteredRepos.firstIndex(of: repo) ?? 0 }
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
                                  tint: theme.accent, selected: false, highlighted: false,
                                  theme: theme) { commitBranch(q) }
                    }
                    ForEach(Array(filteredBranches.enumerated()), id: \.element) { idx, b in
                        ComboRow(label: b, systemImage: "arrow.triangle.branch",
                                  tint: theme.text2, selected: b == branch, highlighted: idx == branchHi,
                                  theme: theme) { commitBranch(b) }
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
        .onAppear { branchHi = filteredBranches.firstIndex(of: branch) ?? 0 }
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

    // MARK: Base combo (BT2)

    /// A compact picker for the optional base branch: "None (branch from HEAD)" plus every existing
    /// local branch. Reuses `branches` (the same source as the branch combo). BT6 extends this with
    /// remote/PR entries — keep the "None" row first so the default stays today's behavior.
    /// S3-2: a non-empty remote parent silently wins over the local base picker; surface that so the
    /// picker isn't showing an ignored choice.
    private var remoteActive: Bool { !remoteBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var basePicker: some View {
        Menu {
            Button("None (branch from HEAD)") { base = "" }
            if !branches.isEmpty { Divider() }
            ForEach(branches, id: \.self) { b in
                Button(b) { base = b }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11)).foregroundColor(theme.text2)
                Text(remoteActive ? "ignored — remote parent set below"
                                  : (base.isEmpty ? "None (branch from HEAD)" : base))
                    .font(F.mono(12.5)).foregroundColor(base.isEmpty || remoteActive ? theme.text3 : theme.text)
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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(remoteActive)
        .opacity(remoteActive ? 0.5 : 1)
    }

    /// BT6: free-text remote parent entry. `pr#<N>` (pull request) or `origin/<branch>` (remote branch);
    /// the daemon fetches it into a private ref and watches it for merges. Empty = no remote parent.
    /// S3-2: shape-check the typed remote parent so a typo is teachable BEFORE spawn (rather than a
    /// "base branch not found" toast). Valid = empty, `pr#<N>` (case-insensitive), or `<remote>/<name>`.
    private var remoteBaseWellFormed: Bool {
        let s = remoteBase.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return true }
        if s.lowercased().hasPrefix("pr#") { return Int(s.dropFirst(3)).map { $0 > 0 } ?? false }
        if let slash = s.firstIndex(of: "/") { return slash != s.startIndex && s.index(after: slash) != s.endIndex }
        return false
    }

    private var remoteBaseField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "cloud")
                    .font(.system(size: 11)).foregroundColor(theme.text2)
                TextField("pr#12  or  origin/feature-x", text: $remoteBase)
                    .textFieldStyle(.plain)
                    .font(F.mono(12.5)).foregroundColor(theme.text)
            }
            .padding(.horizontal, 11).frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(theme.field)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(remoteBaseWellFormed ? theme.fieldBorder : theme.red.text, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if !remoteBaseWellFormed {
                Text("expected `pr#<N>` or `<remote>/<branch>`")
                    .font(F.ui(10)).foregroundColor(theme.red.text)
            }
        }
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
    /// The actual chosen value — draws the trailing checkmark. Compared by value, not by index.
    let selected: Bool
    /// The keyboard cursor (Ctrl-j/k) — draws a background highlight. Distinct from `selected`.
    let highlighted: Bool
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
            .background(hovering || highlighted ? theme.chipHover : Color.clear)
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

/// An `NSTextField` that grabs keyboard focus the instant it's mounted in a window, so a field is
/// ready to type into without a click. The claim is deferred one runloop tick (`main.async`) so it
/// lands *after* SwiftUI's own focus/layout pass — and, crucially, after the agent terminal's
/// deferred `claimFocusNow()` — rather than being clobbered by them. SwiftUI's `@FocusState` focuses
/// synchronously in `onAppear`, so it loses this race to the terminal; this AppKit claim wins it.
/// Shared by the branch search field, the `:` command palette, and the `/` card search bar.
final class AutoFocusTextField: NSTextField {
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
