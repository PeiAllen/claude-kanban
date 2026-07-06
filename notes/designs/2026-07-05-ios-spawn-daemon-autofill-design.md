# iOS Spawn sheet — daemon-backed repo/branch/dir autofill

**Date:** 2026-07-05 · **Card:** `1b6fe6` · **Branch:** `feat/ios-spawn-form-autofill`

## Problem

The iOS "Spawn a new agent" sheet (`App-iOS/Views/SpawnSheet.swift`) makes you blind-type the
full **daemon-side** repo path, branch, and freeform directory. Its only assistance is a tiny
icon-only `Menu` whose suggestions are derived **solely from cards that already exist on the
board** (`knownRepos` / `knownBranches(in:)` / `knownDirs`, all filtering `model.tasks`). So a repo
you haven't carded yet, or a brand-new branch, gets no help at all — and the help that does exist is
easy to miss.

The desktop sheet doesn't have this problem: it runs on the daemon host and reads the disk directly
(`repoCandidates` scans `Config.reposRoot` for `.git` children; `gitBranches(in:)` shells
`git for-each-ref`; `NSOpenPanel` browses freeform dirs). **The phone is a remote client and can't
touch the daemon's disk** — the header comment in `SpawnSheet.swift` states this as a hard
constraint. The daemon, however, *does* know its filesystem. The fix is to expose that knowledge
over the control plane.

## Approach

Add a **UI-only enumeration RPC** that ports the desktop's local disk logic into the daemon, and
surface it as obvious searchable pickers on the phone — unioned with the existing card-derived
suggestions, still free-text-capable as a fallback.

Following the established pattern (`changedNotes`, `diffText`, `diffStat`, the agent-terminal
cluster): these are handled **inline in `ControlServer.dispatch` and deliberately NOT added to
`CommandCatalog`**, so they never become agent-facing MCP tools. Enumerating spawn targets is a
client-UI affordance, not an agent capability — exactly this category.

### New RPCs (inline in `ControlServer.dispatch`, app-only)

1. `spawnRepos` — no params → `SpawnRepos { repos: [RepoCandidate], dirs: [String] }`
   - `repos`: absolute paths of git repos under `Config.reposRoot` (port `repoCandidates`: list
     `reposRoot`, drop dotfiles, keep entries containing `.git`, sort by name).
   - `dirs`: freeform directory candidates the phone can autocomplete — the repo paths themselves
     (running a read-only/freeform agent inside a repo is the common case). The sheet unions these
     with card-derived `knownDirs` (previously-borrowed dirs), so both "repos on disk" and "dirs
     I've used before" are offered. Free text still allowed for anything else.
2. `spawnBranches` — `{ repo }` → `[String]`
   - Local branch names for `repo`, most-recent-commit first (port `gitBranches`:
     `git -C <repo> for-each-ref --format=%(refname:short) --sort=-committerdate refs/heads`).
   - **Defense-in-depth:** resolve + `assertAllowed` the repo through `PathResolver` before shelling
     git; return `[]` if it isn't under an allowlisted root (never run git on an arbitrary path).
   - Fetched lazily when a repo is selected (mirrors the desktop's `.onChange(of: repo)` reload).

Why two methods rather than one param-switched call: each response is single-purpose, and branches
are a lazy per-repo round-trip while repos/dirs load once on sheet appear.

### Shared types (`Sources/OrchestraKit/SpawnTargets.swift` — new file)

```swift
public struct RepoCandidate: Codable, Sendable, Hashable, Identifiable {
    public var path: String   // absolute, daemon-side
    public var name: String   // path.lastPathComponent
    public var id: String { path }
}
public struct SpawnRepos: Codable, Sendable {
    public var repos: [RepoCandidate]
    public var dirs:  [String]
}
```
Defined in OrchestraKit so daemon + macOS + iOS all share one definition.

### Wiring (the call chain)

```
SpawnSheet (App-iOS)
  → BoardModel.refreshSpawnTargets()  /  .spawnBranches(forRepo:)   (Sources/OrchestraUI/BoardModel.swift)
    → ControlClient.spawnRepos()  /  .spawnBranches(repo:)           (Sources/OrchestraKit/Control/ControlClient.swift)
      → client.call("spawnRepos" | "spawnBranches", …)  NDJSON/UDS
        → ControlServer.dispatch case … (inline, NOT CommandCatalog)  (Sources/OrchestraCore/Control/ControlServer.swift)
          → OrchestraService.spawnRepos() / .spawnBranches(repo:)     (Sources/OrchestraCore/OrchestraService.swift)
```

- `BoardModel` gains `@Published var repoCandidates: [RepoCandidate]` + `@Published var
  dirCandidates: [String]`, a `refreshSpawnTargets()` that fills them, and an async
  `spawnBranches(forRepo:) -> [String]`. Loaded on sheet `.onAppear` (fresh each open, no cost when
  not spawning).

### iOS UI — make the assistance obvious

Replace the tiny trailing-icon `Menu` with a prominent, **searchable picker sheet** while keeping the
field free-text:

- Each path row = a mono `TextField` (free text, unchanged binding) + a clearly visible trailing
  **chevron button** that opens a `.sheet` with a `List` + `.searchable`.
- The picker list = union(daemon candidates, card-derived suggestions), de-duplicated + sorted, each
  a tappable row that fills the field.
- A top row echoes the current query as a free-text/**create** affordance: `Use "<query>"` for
  repo/dir, `Create branch "<query>"` for branch — this is the new-branch affordance the branch
  field lacked (a from-existing-cards menu couldn't help create a fresh branch).
- Branch picker is populated from `spawnBranches(forRepo: repo)`, reloaded on repo change, unioned
  with `knownBranches(in:)`.

### Invariants preserved (must not regress)

- Trust flow for freeform dirs (`refreshTrust` / `grantTrust` / `trustNotice` / `readOnly` /
  `keptReadOnly`, and the `.onChange(of: cwd)` / `.onChange(of: mode)` wiring).
- Worktree preview reads `model.config.worktreesRoot` (unchanged).
- Free-text fallback: every field still accepts arbitrary typed input through the same binding.
- DEBUG screenshot hooks: `seedDefaults()`'s `ORCH_SPAWN_MODE` / `ORCH_SPAWN_CWD` block and
  `BoardTab`'s `ORCH_DEV_OPEN_SPAWN`.
- `CommandCatalog` untouched → no new agent-facing MCP tool; the 1:1 catalog↔registry test still holds.
- **Desktop sheet left as-is** — it reads local disk on the daemon host, which is correct there. (A
  future desktop-connected-to-*remote*-daemon mode would want to switch it to these RPCs too; out of
  scope here.)

## Verification

- `swift build` + `swift test` cover daemon + Kit (new RPCs, catalog 1:1 unchanged).
- `scripts/build-ios-app.sh` is the iOS Release gate.
- `scripts/ios-live.sh` builds + launches a visible Simulator against the live Mac daemon; open the
  `+` sheet and confirm the repo/branch/dir pickers populate from the daemon (repos/branches that
  have no card) — the core acceptance test.
