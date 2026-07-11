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
    /// BT2: an existing local branch to create the new branch ON TOP OF (empty = none). Sourced from the
    /// same `branchSuggestions` as the branch picker. BT6 will extend it with remote/PR entries.
    @State private var base = ""
    /// BT6: a REMOTE parent to branch from — `origin/<branch>` or `pr#<N>`. The daemon fetches + watches
    /// it. Non-empty ⇒ it wins over the local base picker.
    @State private var remoteBase = ""

    /// The base to actually send: `nil` unless chosen AND the branch is newly created — the daemon
    /// ignores base for an existing branch, so we don't send it there. A typed remote parent
    /// (pr#N / origin/branch) takes precedence over the local base picker.
    private var effectiveBase: String? {
        if branchSuggestions.contains(branch) { return nil }
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

    /// The freeform cwd's trust state machine (trust lookup + grant), shared with the desktop spawn sheet
    /// via OrchestraUI so the two can't drift. It owns `cwdTrusted` and the generation race guard (#7);
    /// this sheet keeps its own view (collapse chip + "Trust & allow writes"/"Keep read-only") and its
    /// `readOnly` / `keptReadOnly` side effects. An untrusted borrowed dir is forced read-only until the
    /// human grants trust — doable right here via "Trust & allow writes".
    @StateObject private var trust = FreeformTrustModel()
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

    /// PR6a stable-id reuse-on-retry: the in-flight/just-failed spawn attempt's client-minted id, so a
    /// retry after failure dedups onto the same card instead of spawning a duplicate. Cleared only on
    /// success; a failure keeps it so the next tap reuses it.
    @State private var pendingSpawnId: UUID?

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

    /// Repos for the picker: the daemon's on-disk repos (any repo under reposRoot, carded or not),
    /// sorted by repo name. A worktree card's repo is under reposRoot too, so it's already in this list —
    /// no separate card-derived repo hint is needed.
    private var repoSuggestions: [String] {
        sortedByName(dedup(model.spawnRepoCandidates))
    }
    /// Branches for the picker: the daemon's live git branches for the chosen repo (recency order). A
    /// card's branch is a real local branch in that repo, so it's already in this list — no card-derived
    /// branch hint needed.
    private var branchSuggestions: [String] {
        dedup(branchOptions)
    }
    /// Freeform dir candidates: the daemon's repo paths plus dirs seen on existing borrowed cards. The
    /// borrowed dirs are the one hint the daemon *can't* supply (an arbitrary dir the user pointed at,
    /// not under reposRoot), so `knownDirs` stays.
    private var dirSuggestions: [String] {
        dedup(model.spawnRepoCandidates + knownDirs).sorted()
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

    // MARK: card-derived hint — only the one the daemon can't supply

    /// Distinct directories seen on freeform (borrowed) cards. The daemon's spawn answers cover repos and
    /// branches already; a borrowed dir the user pointed at (not under reposRoot) is the one thing they
    /// don't, so this is the sole surviving card-derived hint. Seeds the directory menu.
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
        case .worktree: return !repo.isEmpty && !branch.isEmpty && remoteBaseWellFormed   // S3-2
        case .freeform: return !cwd.isEmpty
        case .scratch:  return true
        }
    }

    /// S3-2: `!remoteBase.isEmpty` wins over the local base picker; shape-check it so a typo is caught
    /// before spawn. Valid = empty / `pr#<N>` (case-insensitive) / `<remote>/<branch>`.
    private var remoteActive: Bool { !remoteBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var remoteBaseWellFormed: Bool {
        let s = remoteBase.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return true }
        if s.lowercased().hasPrefix("pr#") { return Int(s.dropFirst(3)).map { $0 > 0 } ?? false }
        if let slash = s.firstIndex(of: "/") { return slash != s.startIndex && s.index(after: slash) != s.endIndex }
        return false
    }

    /// The CTA reads "Spawn read-only agent" while the freeform card is read-only (forced by an untrusted
    /// dir, or chosen) — otherwise the plain "Spawn agent".
    private var ctaLabel: String { (mode == .freeform && readOnly) ? "Spawn read-only agent" : "Spawn agent" }

    /// DEBUG-only: auto-present the directory browser on appear (headless screenshot via ORCH_SPAWN_BROWSE).
    private var debugAutoBrowse: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["ORCH_SPAWN_BROWSE"] == "1"
        #else
        return false
        #endif
    }

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
                    Button(ctaLabel, action: spawn).disabled(!canSpawn || model.isSpawning).fontWeight(.semibold)
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
            // Flipping mode re-evaluates BOTH trust (freeform) and the branch list (worktree). Without the
            // branch load, entering via the Freeform page then switching to Worktree left `branchOptions`
            // empty forever — `loadBranches()` had only ever run on `.task`/repo-change while in worktree.
            .onChange(of: mode) {
                refreshTrust()
                _Concurrency.Task { await loadBranches() }
            }
            // A new repo selection reloads its branch list from the daemon.
            .onChange(of: repo) { base = ""; remoteBase = ""; _Concurrency.Task { await loadBranches() } }
            // S3-2: a remote parent wins over the local base — clear `base` so the disabled Picker's
            // selection matches its "ignored" tag (no SwiftUI invalid-selection warning / blank render).
            .onChange(of: remoteActive) { if remoteActive { base = "" } }
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

        // Base only applies to a NEWLY-created branch; the daemon ignores it for an existing one. BT6
        // extends this with remote/PR entries — keep the "None" tag first so the default is HEAD.
        if !branchSuggestions.contains(branch) {
            // S3-2: a non-empty remote parent wins — disable the local base picker so it isn't showing an
            // ignored choice.
            Picker("Base branch", selection: $base) {
                Text(remoteActive ? "ignored — remote parent set" : "None (branch from HEAD)").tag("")
                if !remoteActive { ForEach(branchSuggestions, id: \.self) { Text($0).tag($0) } }
            }
            .disabled(remoteActive)
            // BT6: remote parent — pr#<N> or origin/<branch>; fetched + watched by the daemon.
            LabeledContent("Remote parent") {
                TextField("pr#12 or origin/branch", text: $remoteBase)
                    .font(.system(.footnote, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .foregroundStyle(remoteBaseWellFormed ? theme.text : theme.red.text)
            }
            // S3-2: inline shape hint so a typo is teachable before spawn (not a "not found" toast).
            if !remoteBaseWellFormed {
                Text("expected `pr#<N>` or `<remote>/<branch>`")
                    .font(.caption2).foregroundStyle(theme.red.text)
            }
        }

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
        // A real remote directory browser (not a flat picker): tap in/out of the daemon's folders,
        // see sibling files, pick one as the cwd. The mono TextField stays as the free-text fallback
        // (any path, trust-gated). Confined daemon-side to the browse roots ($HOME + allowlist).
        DirBrowserField(cwd: $cwd, suggestions: dirSuggestions,
                        list: { await model.listDir(path: $0) }, autoOpen: debugAutoBrowse)

        trustNotice

        Toggle(isOn: $readOnly) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Read-only")
                Text("Agent can read, search & run git, but cannot edit or write.")
                    .font(.caption).foregroundStyle(theme.text2)
            }
        }
        // An untrusted borrowed dir is forced read-only (can't be unchecked until trust is granted).
        .disabled(trust.cwdTrusted == false)
    }

    /// The freeform trust indicator (reads the daemon's trust ledger via `trustState`). Untrusted dirs
    /// show an amber "Directory not trusted" notice with **Trust & allow writes** / **Keep read-only**.
    @ViewBuilder private var trustNotice: some View {
        if !cwd.isEmpty, let trusted = trust.cwdTrusted {
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
                                if trust.granting { ProgressView().controlSize(.mini) }
                                else { Image(systemName: "checkmark.shield") }
                                Text("Trust & allow writes")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(trust.granting)

                        Button("Keep read-only") { keptReadOnly = true }
                            .buttonStyle(.bordered)
                            .disabled(trust.granting)
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
        // flow can be driven headlessly (scripts/t4-takeover-shot.sh --spawn). Scratch mode needs no
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

    /// Re-check trust for the current freeform cwd, forcing read-only when untrusted. The generation +
    /// path guard (shared with the desktop) lives in `FreeformTrustModel`, so a slow in-flight reply that
    /// lands after a faster grant is recognized as stale and dropped (#7).
    private func refreshTrust() {
        guard mode == .freeform, !cwd.isEmpty else { trust.reset(); return }
        let path = cwd
        _Concurrency.Task {
            if await trust.refresh(path: path, check: { await model.trustState(path: $0) }) == .untrusted {
                readOnly = true
            }
        }
    }

    /// Grant the human's trust for the current freeform cwd. On success the dir is trusted, so we clear
    /// the read-only lock and default the card to read-write — the user asked to enable writes. The shared
    /// model bumps its generation so any in-flight `refreshTrust()` reply can't overwrite the grant (#7).
    private func grantTrust() {
        _Concurrency.Task {
            if await trust.grant(perform: { await model.trust(path: $0) }) == .granted {
                readOnly = false; keptReadOnly = false
            }
        }
    }

    private func spawn() {
        let m = modelSel.isEmpty ? nil : modelSel
        let a = agentSel.isEmpty ? nil : agentSel
        let sid = BoardStore.spawnAttemptId(reusing: pendingSpawnId)
        pendingSpawnId = sid
        _Concurrency.Task {
            let card: Task?
            switch mode {
            case .worktree:
                card = await model.spawn(id: sid, prompt: prompt, repo: repo, branch: branch, model: m, startIn: startIn,
                                         agent: a, base: effectiveBase)
            case .freeform:
                card = await model.spawn(id: sid, prompt: prompt, repo: "", branch: "", model: m, startIn: startIn,
                                         agent: a, cwd: cwd, access: readOnly ? .readOnly : .readWrite)
            case .scratch:
                card = await model.spawn(id: sid, prompt: prompt, repo: "", branch: "", model: m, startIn: startIn,
                                         agent: a, scratch: true)
            }
            // Auto-own on phone-spawn (Bug 3): the phone that spawned the card is its intended driver, so
            // acquire the D4 takeover lease and drop straight into the live agent surface — no separate
            // "Take Over" tap. Non-blocking spawn (PR4b) returns the card at `.creatingWorktree` BEFORE any
            // tmux `agent` window exists (the reconciler's LaunchStepper brings it up ~2s+ later), so the
            // takeover can't lease a window yet — `TakeoverController` bounded-retries the acquire while the
            // card is being born and re-arms on the `→ live` edge (F1), so this fires the request eagerly.
            // S3-2: dismiss only on SUCCESS — a typo'd base/remote used to cost the whole form because we
            // dismissed before the RPC returned; now the sheet stays (toast shows the error) so the user
            // can fix + retry. A failed spawn (`nil`) leaves the sheet up and routes nowhere.
            // Clear the pending id only on success; a failure keeps it so a retry dedups (PR6a).
            if let card {
                pendingSpawnId = nil
                model.phoneTakeoverRequest = PhoneTakeoverRequest(cardId: card.id)
                dismiss()
            }
        }
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

// MARK: - Remote directory browser

/// The freeform Directory field: a free-text mono `TextField` (the fallback — any path, trust-gated,
/// exactly as before) plus a **Browse** button that opens a real navigable browser of the *daemon's*
/// disk. The phone can't browse the daemon directly, so the browser drives the app-only `listDir` RPC
/// (`list`), which is confined daemon-side to the browse roots ($HOME + allowlist) and hides dotfiles.
/// Selecting a folder writes `cwd`, so the sheet's existing trust flow (`refreshTrust`) fires unchanged.
private struct DirBrowserField: View {
    @Binding var cwd: String
    /// Recent freeform dirs + repos, surfaced as one-tap "Suggestions" at the browser's root level.
    let suggestions: [String]
    /// Fetch a directory listing from the daemon (nil path → the root listing). `nil` result = an
    /// escaping/invalid path (the browser falls back to the roots).
    let list: (String?) async -> DirListing?
    /// DEBUG-only: auto-present the browser on appear (headless screenshot via ORCH_SPAWN_BROWSE).
    var autoOpen: Bool = false

    @Environment(\.theme) private var theme: Theme
    @State private var showBrowser = false

    var body: some View {
        HStack(spacing: 8) {
            TextField("/path/on/the/daemon", text: $cwd)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .lineLimit(1).truncationMode(.head)
            Button { showBrowser = true } label: {
                HStack(spacing: 3) {
                    Image(systemName: "folder")
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .foregroundStyle(theme.accent)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Browse directories")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Directory")
        .sheet(isPresented: $showBrowser) {
            DirBrowserSheet(cwd: $cwd, suggestions: suggestions, list: list)
        }
        .onAppear { if autoOpen { showBrowser = true } }
    }
}

/// A single-pane file browser over the daemon's disk. Up and down are symmetric (`currentPath` +
/// refetch), not a stack of pushes: tap a folder to descend, the "up" row to climb (bounded at a
/// browse root by the daemon), "Use this folder" to pick `currentPath` as the cwd. Files are shown
/// (context) but disabled. Opens seeded at the current cwd so re-opening lands where you are — and you
/// can climb out to see siblings. An escaping/invalid seed falls back to the root listing.
private struct DirBrowserSheet: View {
    @Binding var cwd: String
    let suggestions: [String]
    let list: (String?) async -> DirListing?

    @Environment(\.theme) private var theme: Theme
    @Environment(\.dismiss) private var dismiss

    /// The directory currently shown. "" == the synthetic root listing (the browse roots).
    @State private var currentPath = ""
    @State private var listing: DirListing?
    @State private var loading = false
    @State private var loadFailed = false
    @State private var query = ""

    private var atRoot: Bool { currentPath.isEmpty }
    private var title: String { atRoot ? "Directories" : (currentPath as NSString).lastPathComponent }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func matches(_ name: String, _ path: String) -> Bool {
        let q = trimmedQuery
        return q.isEmpty || name.localizedCaseInsensitiveContains(q) || path.localizedCaseInsensitiveContains(q)
    }
    private var filteredEntries: [DirEntry] {
        (listing?.entries ?? []).filter { matches($0.name, $0.path) }
    }
    private var filteredSuggestions: [String] {
        suggestions.filter { matches(($0 as NSString).lastPathComponent, $0) }
    }

    var body: some View {
        NavigationStack {
            List {
                if atRoot, !filteredSuggestions.isEmpty { suggestionsSection }
                if let parent = listing?.parent { upRow(parent) }
                entriesSection
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Filter this folder")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this folder") { cwd = currentPath; dismiss() }
                        .disabled(atRoot)
                        .fontWeight(.semibold)
                }
            }
            .overlay { if loading { ProgressView().controlSize(.large) } }
            .task { await load(cwd.isEmpty ? "" : cwd, fallbackToRoot: true) }
        }
    }

    // MARK: rows

    private var suggestionsSection: some View {
        Section("Suggestions") {
            ForEach(filteredSuggestions, id: \.self) { s in
                Button { descend(s) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(theme.text2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((s as NSString).lastPathComponent).foregroundStyle(theme.text)
                            Text(s).font(.caption).foregroundStyle(theme.text2)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(theme.text2)
                    }
                }
            }
        }
    }

    private func upRow(_ parent: String) -> some View {
        Button { descend(parent) } label: {
            Label {
                Text("Up to “\((parent as NSString).lastPathComponent)”").foregroundStyle(theme.text)
            } icon: {
                Image(systemName: "arrow.turn.left.up").foregroundStyle(theme.accent)
            }
        }
    }

    @ViewBuilder private var entriesSection: some View {
        Section {
            ForEach(filteredEntries) { entry in
                if entry.isDir {
                    Button { descend(entry.path) } label: { entryRow(entry) }
                } else {
                    entryRow(entry).foregroundStyle(theme.text2)   // files: context only, not selectable
                }
            }
            if !loading, filteredEntries.isEmpty {
                Text(loadFailed ? "Couldn’t open this folder."
                     : trimmedQuery.isEmpty ? "Empty folder." : "No match.")
                    .font(.footnote).foregroundStyle(theme.text2)
            }
        } header: {
            if !atRoot {
                Text(currentPath).font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.head).textCase(nil)
            }
        }
    }

    private func entryRow(_ entry: DirEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDir ? "folder" : "doc")
                .foregroundStyle(entry.isDir ? theme.accent : theme.text2)
            Text(entry.name).foregroundStyle(entry.isDir ? theme.text : theme.text2)
            Spacer(minLength: 4)
            if entry.isDir {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(theme.text2)
            }
        }
    }

    // MARK: load

    private func descend(_ path: String) { _Concurrency.Task { await load(path) } }

    /// Fetch `path` (empty → roots) and swap the pane on success. On failure, either fall back to the
    /// root listing (used for the seed / suggestions) or leave the current pane and flag the error.
    private func load(_ path: String, fallbackToRoot: Bool = false) async {
        loading = true
        let result = await list(path.isEmpty ? nil : path)
        loading = false
        if let result {
            listing = result
            currentPath = result.path   // daemon-canonical (symlinks resolved) — what "Use" will pick
            query = ""
            loadFailed = false
        } else if fallbackToRoot, !path.isEmpty {
            await load("", fallbackToRoot: false)   // escaping/invalid seed → show the roots
        } else {
            loadFailed = true                       // keep the current pane; show an inline notice
        }
    }
}
