import SwiftUI
import OrchestraKit
import OrchestraUI

/// The "Spawn a new agent" sheet (design §4) — the iOS reinterpretation of the desktop
/// `App/Views/SpawnSheet.swift`. Same shared `BoardModel` contract (`spawn` / `trust` / `trustState`),
/// same modes and trust flow; the desktop's AppKit chrome (`NSOpenPanel`, `.popover` combos) is replaced
/// by native SwiftUI (`Form`, `Picker`, searchable pickers). The phone is a **remote client** — repo/dir
/// paths live on the *daemon's* filesystem — so it can't browse that disk directly like the desktop's
/// `NSOpenPanel`. Instead the daemon enumerates its own disk over the control plane (`spawnRepos` /
/// `spawnBranches`), and each path field is a searchable picker populated from that list **unioned** with
/// suggestions derived from the board's existing cards. Every field stays free-text-capable as a fallback.
///
/// Layout: prompt · agent (Claude Code / Codex, only when >1) · model · **Card mode** three-way chip
/// (Worktree · Freeform · Scratch) then the per-mode body. The **Read-only toggle** is a separate control
/// (CardAccess, orthogonal to mode — not a 4th chip), shown in Freeform where `access` is honored; an
/// untrusted Freeform dir forces it on until the human grants trust right here.
struct SpawnSheet: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    @Environment(\.dismiss) private var dismiss

    /// Worktree (repo + branch, the default) · Freeform (an existing directory) · Scratch (a throwaway dir).
    enum Mode: String, CaseIterable, Identifiable { case worktree, freeform, scratch
        var id: String { rawValue }
        var label: String { self == .worktree ? "Worktree" : self == .freeform ? "Freeform" : "Scratch" }
    }
    @State private var mode: Mode
    /// BoardTab seeds the mode from the page the user launched from (Freeform page → Freeform).
    init(startFreeform: Bool = false) { _mode = State(initialValue: startFreeform ? .freeform : .worktree) }

    @State private var prompt = ""
    @State private var repo = ""
    @State private var branch = ""
    @State private var agentSel = ""
    @State private var modelSel = ""
    @State private var startIn: StartIn = .plan

    /// Freeform card: the borrowed directory to run in, and whether it's read-only.
    @State private var cwd = ""
    @State private var readOnly = false

    /// Trust state for the freeform cwd (nil = unknown/unchecked). An untrusted borrowed dir is forced
    /// read-only until the human grants trust — doable right here via "Trust & allow writes".
    @State private var cwdTrusted: Bool? = nil
    /// True while the in-sheet trust grant is in flight (disables the button, shows progress).
    @State private var granting = false
    /// The human chose "Keep read-only" — collapses the amber prompt to a compact acknowledgment while
    /// leaving the read-only lock in place (Trust is still reachable). Reset when the dir changes.
    @State private var keptReadOnly = false
    /// One-shot guard so the repo default is filled once the board's cards load (the phone loads `tasks`
    /// asynchronously, so `onAppear` can fire before any repo suggestion exists) — without clobbering a
    /// value the user has since typed.
    @State private var didSeedRepo = false
    /// Daemon-supplied git branches for the currently-selected repo (most-recent-commit first). Loaded
    /// lazily when the repo changes; empty until then / on failure (the picker falls back to card-derived
    /// branches + free-text creation).
    @State private var branchOptions: [String] = []

    // MARK: agents / models (sourced from the daemon; falls back to Claude Code when it hasn't answered)

    /// The Claude Code fallback, built from OrchestraKit types only (iOS doesn't link OrchestraCore, so
    /// it can't construct `ClaudeCodeAdapter()` like the desktop sheet). Used only until `model.agents`
    /// arrives — never invents providers the daemon hasn't wired up.
    private static let claudeFallback = AgentInfo(
        id: "claude-code", name: "Claude Code", icon: "sparkle",
        models: [
            AgentModel(id: "claude-opus-4-8", displayName: "Opus 4.8", family: "claude"),
            AgentModel(id: "claude-sonnet-4-6", displayName: "Sonnet 4.6", family: "claude"),
            AgentModel(id: "claude-haiku-4-5", displayName: "Haiku 4.5", family: "claude"),
        ],
        capabilities: .claudeCode)

    private var agentOptions: [AgentInfo] { model.agents.isEmpty ? [Self.claudeFallback] : model.agents }
    private var selectedAgent: AgentInfo? { agentOptions.first { $0.id == agentSel } ?? agentOptions.first }
    private var modelOptions: [AgentModel] { selectedAgent?.models ?? [] }

    /// The default model for the selected agent: the configured default when it belongs to this agent,
    /// else the agent's first model.
    private func defaultModelForAgent() -> String {
        let models = modelOptions
        if let d = model.config.defaultModel, models.contains(where: { $0.id == d }) { return d }
        return models.first?.id ?? ""
    }

    // MARK: suggestions — daemon-enumerated disk UNIONed with board-card-derived hints

    /// Repos for the picker: the daemon's on-disk repos (any repo, carded or not) plus repos seen on
    /// existing worktree cards. De-duplicated, sorted by repo name.
    private var repoSuggestions: [String] {
        sortedByName(dedup(model.spawnRepoCandidates.map(\.path) + knownRepos))
    }
    /// Branches for the picker: the daemon's live git branches for the chosen repo (recency order) then
    /// any branches seen on that repo's cards. Order-preserving de-dup (recency first).
    private var branchSuggestions: [String] {
        dedup(branchOptions + knownBranches(in: repo))
    }
    /// Freeform dir candidates: the daemon's repo paths plus dirs seen on existing borrowed cards.
    private var dirSuggestions: [String] {
        dedup(model.spawnDirCandidates + knownDirs).sorted()
    }

    /// Order-preserving de-dup, dropping empties (keeps the daemon's recency/sort where it matters).
    private func dedup(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for x in xs where !x.isEmpty && seen.insert(x).inserted { out.append(x) }
        return out
    }
    /// Sort paths by their last component (repo name), case-insensitively.
    private func sortedByName(_ xs: [String]) -> [String] {
        xs.sorted {
            ($0 as NSString).lastPathComponent
                .localizedCaseInsensitiveCompare(($1 as NSString).lastPathComponent) == .orderedAscending
        }
    }

    // MARK: card-derived hints (the phone's original suggestion source; still unioned in above)

    /// Distinct repos seen on worktree cards, by repo name. Seeds the repo menu.
    private var knownRepos: [String] {
        let repos = model.tasks.filter { $0.origin == .worktree }.map(\.repo)
        return Array(Set(repos)).sorted {
            ($0 as NSString).lastPathComponent.localizedCaseInsensitiveCompare(($1 as NSString).lastPathComponent) == .orderedAscending
        }
    }
    /// Distinct existing branches seen on the chosen repo's worktree cards. Seeds the branch menu.
    private func knownBranches(in repoPath: String) -> [String] {
        let branches = model.tasks.filter { $0.origin == .worktree && $0.repo == repoPath }.map(\.branch)
        return Array(Set(branches)).sorted()
    }
    /// Distinct directories seen on freeform cards. Seeds the directory menu.
    private var knownDirs: [String] {
        Array(Set(model.tasks.filter { $0.origin == .borrowed }.map(\.cwd))).sorted()
    }

    private var repoName: String { (repo as NSString).lastPathComponent }

    /// Mirror the daemon's own worktree layout (`Config.worktreePath`) so the preview can't diverge; the
    /// path is the *daemon's* (shown verbatim — the phone doesn't know the daemon's `$HOME` to abbreviate).
    private var worktreePreview: String {
        let root = model.config.worktreesRoot
        let name = repoName.isEmpty ? "…" : repoName
        let slug = branch.isEmpty ? "…" : branch.replacingOccurrences(of: "/", with: "-")
        return "\(root)/\(name)/\(slug)"
    }

    private var canSpawn: Bool {
        switch mode {
        case .worktree: return !repo.isEmpty && !branch.isEmpty
        case .freeform: return !cwd.isEmpty
        case .scratch:  return true
        }
    }

    /// The CTA reads "Spawn read-only agent" while the freeform card is read-only (forced by an untrusted
    /// dir, or chosen) — otherwise the plain "Spawn agent".
    private var ctaLabel: String { (mode == .freeform && readOnly) ? "Spawn read-only agent" : "Spawn agent" }

    var body: some View {
        NavigationStack {
            Form {
                promptSection
                agentModelSection
                modeSection
            }
            .navigationTitle("Spawn a new agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ctaLabel, action: spawn).disabled(!canSpawn).fontWeight(.semibold)
                }
            }
            .onAppear(perform: seedDefaults)
            // Pull the daemon's repo/dir list (the phone can't browse its disk), then seed the repo
            // default from it and load that repo's branches.
            .task {
                await model.refreshSpawnTargets()
                seedRepoIfNeeded()
                await loadBranches()
            }
            .onChange(of: agentSel) { modelSel = defaultModelForAgent() }
            .onChange(of: cwd) { keptReadOnly = false; refreshTrust() }
            .onChange(of: mode) { refreshTrust() }
            // A new repo selection reloads its branch list from the daemon.
            .onChange(of: repo) { _Concurrency.Task { await loadBranches() } }
            // The board's cards can arrive after this sheet mounts; seed the repo default once they do.
            .onChange(of: model.tasks.count) { seedRepoIfNeeded() }
            // Daemon repos can arrive after mount too; seed once they do.
            .onChange(of: model.spawnRepoCandidates.count) { seedRepoIfNeeded() }
        }
    }

    // MARK: - Sections

    private var promptSection: some View {
        Section {
            TextField("e.g. Add rate limiting to the API", text: $prompt, axis: .vertical)
                .lineLimit(3...6)
        } header: {
            Text("Initial prompt")
        } footer: {
            Text("Optional — leave blank to drop into the agent and name the card from your first message.")
        }
    }

    @ViewBuilder private var agentModelSection: some View {
        Section("Agent & model") {
            if agentOptions.count > 1 {
                Picker("Agent", selection: $agentSel) {
                    ForEach(agentOptions) { a in Label(a.name, systemImage: a.icon).tag(a.id) }
                }
            }
            Picker("Model", selection: $modelSel) {
                ForEach(modelOptions) { m in Text(m.displayName).tag(m.id) }
            }
        }
    }

    @ViewBuilder private var modeSection: some View {
        Section("Card mode") {
            Picker("Run in", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .worktree: worktreeBody
            case .freeform: freeformBody
            case .scratch:  scratchBody
            }
        }
    }

    // MARK: Worktree

    @ViewBuilder private var worktreeBody: some View {
        SpawnPickerField(label: "Repository", placeholder: "repo name or /path", text: $repo,
                         icon: "folder", suggestions: repoSuggestions,
                         display: { ($0 as NSString).lastPathComponent }, createVerb: "Use")
        SpawnPickerField(label: "Branch", placeholder: "new or existing branch", text: $branch,
                         icon: "arrow.triangle.branch", suggestions: branchSuggestions,
                         display: { $0 }, createVerb: "Create branch")

        LabeledContent("Worktree") {
            Text(worktreePreview)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(theme.text2)
                .lineLimit(1).truncationMode(.middle)
        }

        Picker("Start in", selection: $startIn) {
            Text("Plan").tag(StartIn.plan)
            Text("Implementation").tag(StartIn.impl)
        }
        .pickerStyle(.segmented)
    }

    // MARK: Freeform

    @ViewBuilder private var freeformBody: some View {
        SpawnPickerField(label: "Directory", placeholder: "/path/on/the/daemon", text: $cwd,
                         icon: "folder", suggestions: dirSuggestions, display: { $0 }, createVerb: "Use")

        trustNotice

        Toggle(isOn: $readOnly) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Read-only")
                Text("Agent can read, search & run git, but cannot edit or write.")
                    .font(.caption).foregroundStyle(theme.text2)
            }
        }
        // An untrusted borrowed dir is forced read-only (can't be unchecked until trust is granted).
        .disabled(cwdTrusted == false)
    }

    /// The freeform trust indicator (reads the daemon's trust ledger via `trustState`). Untrusted dirs
    /// show an amber "Directory not trusted" notice with **Trust & allow writes** / **Keep read-only**.
    @ViewBuilder private var trustNotice: some View {
        if !cwd.isEmpty, let trusted = cwdTrusted {
            if trusted {
                Label("Trusted directory", systemImage: "checkmark.shield")
                    .font(.footnote).foregroundStyle(theme.green.text)
            } else if keptReadOnly {
                // Collapsed acknowledgment — read-only stays locked, Trust still reachable.
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(theme.amber.dot)
                    Text("Running read-only — untrusted directory").font(.footnote).foregroundStyle(theme.text2)
                    Spacer(minLength: 4)
                    Button("Trust") { keptReadOnly = false }.font(.footnote.weight(.semibold))
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.amber.dot)
                        Text("Directory not trusted — it will run read-only (sandboxed). Trust it to let the "
                            + "agent edit, write & commit here.")
                            .font(.footnote).foregroundStyle(theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        Button(action: grantTrust) {
                            HStack(spacing: 5) {
                                if granting { ProgressView().controlSize(.mini) }
                                else { Image(systemName: "checkmark.shield") }
                                Text("Trust & allow writes")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(granting)

                        Button("Keep read-only") { keptReadOnly = true }
                            .buttonStyle(.bordered)
                            .disabled(granting)
                    }
                    .font(.footnote)
                }
                .padding(.vertical, 4)
                .listRowBackground(theme.amber.tint)
            }
        }
    }

    // MARK: Scratch

    private var scratchBody: some View {
        Label {
            Text("Orchestra creates a throwaway directory now and deletes it when you archive the card.")
                .font(.footnote).foregroundStyle(theme.text2)
        } icon: {
            Image(systemName: "sparkles").foregroundStyle(theme.accent)
        }
    }

    // MARK: - Actions

    private func seedDefaults() {
        #if DEBUG
        // Headless-screenshot hook (mirrors the desktop's ORCH_SPAWN_MODE/CWD): preset the mode + freeform
        // cwd so the trust notice is screenshotable. Against a real daemon `trustState` resolves the dir.
        let env = ProcessInfo.processInfo.environment
        if let m = env["ORCH_SPAWN_MODE"], let parsed = Mode(rawValue: m) { mode = parsed }
        if let c = env["ORCH_SPAWN_CWD"], !c.isEmpty { cwd = c }
        // Bug-3 verify hook: auto-submit the sheet once fields have seeded, so the phone-spawn → auto-takeover
        // flow can be driven headlessly (scripts/t4-phone-spawn-takeover-shot.sh). Scratch mode needs no
        // repo/branch, so `canSpawn` is already true. DEBUG-only; production never sets this.
        if env["ORCH_SPAWN_AUTOSUBMIT"] == "1" {
            _Concurrency.Task { @MainActor in
                try? await _Concurrency.Task.sleep(nanoseconds: 1_500_000_000)
                if canSpawn { spawn() }
            }
        }
        #endif
        seedRepoIfNeeded()
        if agentSel.isEmpty { agentSel = model.config.defaultAgentId }
        if !agentOptions.contains(where: { $0.id == agentSel }) { agentSel = agentOptions.first?.id ?? "" }
        if modelSel.isEmpty { modelSel = defaultModelForAgent() }
        startIn = model.spawnDefaultColumn == .plan ? .plan : .impl
        refreshTrust()
    }

    /// Fill the repo field from the first known repo — once, and only while it's still empty, so a
    /// late-arriving board (the phone loads `tasks` async) still seeds a default without clobbering typing.
    private func seedRepoIfNeeded() {
        guard !didSeedRepo, repo.isEmpty, let first = repoSuggestions.first else { return }
        repo = first
        didSeedRepo = true
    }

    /// Load the selected repo's git branches from the daemon (recency order). Stale-guarded against a
    /// repo change mid-flight. Only meaningful for worktree mode.
    private func loadBranches() async {
        guard mode == .worktree, !repo.isEmpty else { branchOptions = []; return }
        let r = repo
        let list = await model.spawnBranches(forRepo: r)
        guard r == repo else { return }   // ignore a stale result after the repo changed
        branchOptions = list
    }

    /// Re-check trust for the current freeform cwd, forcing read-only when untrusted. Stale-guarded.
    private func refreshTrust() {
        guard mode == .freeform, !cwd.isEmpty else { cwdTrusted = nil; return }
        let path = cwd
        _Concurrency.Task {
            let trusted = await model.trustState(path: path)
            guard path == cwd else { return }   // ignore a stale result after the dir changed
            cwdTrusted = trusted
            if !trusted { readOnly = true }
        }
    }

    /// Grant the human's trust for the current freeform cwd. On success the dir is trusted, so we clear
    /// the read-only lock and default the card to read-write — the user asked to enable writes.
    private func grantTrust() {
        guard !cwd.isEmpty, !granting else { return }
        let path = cwd
        granting = true
        _Concurrency.Task {
            let ok = await model.trust(path: path)
            granting = false
            guard path == cwd else { return }   // ignore a stale result after the dir changed
            if ok { cwdTrusted = true; readOnly = false; keptReadOnly = false }
        }
    }

    private func spawn() {
        let m = modelSel.isEmpty ? nil : modelSel
        let a = agentSel.isEmpty ? nil : agentSel
        _Concurrency.Task {
            let card: Task?
            switch mode {
            case .worktree:
                card = await model.spawn(prompt: prompt, repo: repo, branch: branch, model: m, startIn: startIn, agent: a)
            case .freeform:
                card = await model.spawn(prompt: prompt, repo: "", branch: "", model: m, startIn: startIn,
                                         agent: a, cwd: cwd, access: readOnly ? .readOnly : .readWrite)
            case .scratch:
                card = await model.spawn(prompt: prompt, repo: "", branch: "", model: m, startIn: startIn,
                                         agent: a, scratch: true)
            }
            // Auto-own on phone-spawn (Bug 3): the phone that spawned the card is its intended driver, so
            // acquire the D4 takeover lease and drop straight into the live agent surface — no separate
            // "Take Over" tap. The daemon creates the `agent` tmux window synchronously inside `spawn`
            // (SessionManager.ensure) before returning the card, so the lease target already resolves. The
            // sheet has dismissed by the time the RPC returns, so presenting the takeover cover doesn't
            // collide with this sheet. A failed spawn (`nil`) simply routes nowhere.
            if let card { model.phoneTakeoverRequest = PhoneTakeoverRequest(cardId: card.id) }
        }
        dismiss()
    }
}

// MARK: - Searchable path picker

/// A free-text path field with an obvious, searchable picker. The mono `TextField` keeps direct typing
/// (the free-text fallback); the bordered trailing button opens a searchable `List` of `suggestions`
/// (daemon-enumerated ∪ card-derived). A top "create" row echoes the current query so anything typed —
/// including a brand-new branch name the daemon can't know — is one tap away. Nothing is constrained to
/// the list; the phone can't fully browse the daemon's disk, so typed input is always honored.
private struct SpawnPickerField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    /// Leading glyph on the picker button (folder / branch).
    let icon: String
    let suggestions: [String]
    /// Row title for a suggestion (repos show the basename; branches/dirs show the raw value).
    let display: (String) -> String
    /// Verb for the free-text row at the top of the picker ("Use" for repo/dir, "Create branch").
    let createVerb: String

    @Environment(\.theme) private var theme: Theme
    @State private var showPicker = false
    @State private var query = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .lineLimit(1).truncationMode(.head)
            Button {
                query = text
                showPicker = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .foregroundStyle(theme.accent)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Choose \(label.lowercased())")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .sheet(isPresented: $showPicker) { pickerSheet }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filtered: [String] {
        let q = trimmedQuery
        guard !q.isEmpty else { return suggestions }
        return suggestions.filter {
            display($0).localizedCaseInsensitiveContains(q) || $0.localizedCaseInsensitiveContains(q)
        }
    }

    private var pickerSheet: some View {
        NavigationStack {
            List {
                // Free-text / new-branch affordance: whatever's typed, appliable in one tap.
                if !trimmedQuery.isEmpty, !suggestions.contains(trimmedQuery) {
                    Button {
                        text = trimmedQuery
                        showPicker = false
                    } label: {
                        Label("\(createVerb) “\(trimmedQuery)”", systemImage: "plus.circle")
                    }
                }
                Section {
                    ForEach(filtered, id: \.self) { s in
                        Button {
                            text = s
                            showPicker = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(display(s)).foregroundStyle(theme.text)
                                if display(s) != s {
                                    Text(s).font(.caption).foregroundStyle(theme.text2)
                                        .lineLimit(1).truncationMode(.head)
                                }
                            }
                        }
                    }
                    if filtered.isEmpty {
                        Text(suggestions.isEmpty
                             ? "No suggestions from the daemon yet — type a \(label.lowercased()) above."
                             : "No match — type to create a new \(label.lowercased()).")
                            .font(.footnote).foregroundStyle(theme.text2)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search or type a \(label.lowercased())")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle(label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showPicker = false } }
            }
        }
    }
}
