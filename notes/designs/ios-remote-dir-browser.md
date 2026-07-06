# iOS remote directory browser for the Spawn sheet

**Card:** `9c42ad` (feat/ios-freeform-dir-browser, based on `mobile-impl-orchestration`)
**Status:** design → impl

## Problem

The iPhone Spawn sheet's freeform **Directory** field is a *flat searchable picker*, not a
filesystem browser. It's seeded from a fixed list — the `spawnRepos` RPC's `dirs` field (which the
daemon currently fills with just the repo paths) unioned with dirs seen on existing borrowed cards
(`App-iOS/Views/SpawnSheet.swift` `freeformBody` → `SpawnPickerField`, `dirSuggestions`). You cannot
tap into a folder to see its contents, climb back out, or see sibling files/folders. The phone is a
**remote client** and can't browse the daemon's disk, so today there is genuinely no way to navigate.

## Why this isn't "just port NSOpenPanel"

The desktop Spawn sheet (`App/Views/SpawnSheet.swift:681`) uses `NSOpenPanel` — the **local user**
browsing their **own** machine, unconstrained. A phone browsing the daemon's disk is a **remote
client**: an unconstrained browse RPC would let it enumerate the daemon's entire filesystem
(`~/.ssh`, `~/.aws`, `/etc`, …) — an information disclosure the desktop can't have. So the remote
browser needs its **own** boundary.

That boundary is also distinct from the **spawn allowlist**. Two independent mechanisms exist today:

- **Allowlist / allowed roots** (`PathResolver`, `Config.allowedRoots = [reposRoot, worktreesRoot] +
  allowlist`): gates **worktree** cards only. `assertAllowed` canonicalizes via `realpath(3)`
  (symlink-escape safe, collapses `..` in a non-existent tail) and requires the path to sit under a
  root, else throws `pathNotAllowed`.
- **Trust ledger** (`TrustLedger`, `~/.local/share/orchestra/trust-ledger.json`): governs
  read-write vs read-only for **freeform/borrowed** cwds. Freeform spawns **skip the allowlist
  entirely** — `origin == .borrowed` bypasses `assertAllowed` ("the path may even be outside any
  repo"); the OS sandbox + trust ledger is the boundary. Untrusted → runs read-only until a human
  grants trust.

So a freeform card can run **anywhere**, but we must not let the phone **enumerate** anywhere.

## Browse boundary (decision)

**`browseRoots = [daemon $HOME] + config.allowedRoots`**, canonicalized and collapsed to top-most
roots (drop any root that sits under another kept root — since `reposRoot`/`worktreesRoot` usually
live under `$HOME`, the effective root list is `[$HOME]` plus any allowlist entry outside home).

- **Dotfiles hidden** — `~/.ssh`, `~/.aws`, `.git`, etc. never appear in a listing.
- **Free-text typing is unchanged** — the Directory field's mono `TextField` still accepts **any**
  path (trust-gated exactly as today). The browser is the safe, convenient path; typing remains the
  pre-existing unconstrained escape hatch.

Rationale: the user chose "Home dir + allowlist" — broad enough to reach any project under home,
narrow enough that the remote phone can't walk outside home / the allowlist, with obvious secret
dirs elided by the dotfile filter. Reuses the existing `PathResolver` abstraction rather than
inventing new path logic.

## (a) Daemon RPC — `listDir`

**App-only, NOT a registry command.** Agents must never browse the daemon disk, so — like
`spawnRepos`/`spawnBranches` — this is a hand-written `case` in `ControlServer.dispatch`, never a
`CommandCatalog`/`CommandRegistry` entry, so it never becomes an MCP tool.

### Wire types — `Sources/OrchestraKit/DirListing.swift` (new)

```swift
public struct DirEntry: Codable, Sendable, Hashable, Identifiable {
    public var path: String   // absolute, canonical
    public var name: String   // basename for display
    public var isDir: Bool    // dir → navigable + selectable; file → shown, disabled
    public var id: String { path }
}

public struct DirListing: Codable, Sendable {
    public var path: String        // "" == the synthetic root listing
    public var parent: String?     // parent IFF still within a browse root; nil at a root → no "up"
    public var entries: [DirEntry] // dirs first then files, each case-insensitive; dotfiles hidden
}
```

### Service — `OrchestraService.listDir(_ path: String?) throws -> DirListing`

- `path` nil/empty → **synthetic root listing**: one `DirEntry(isDir: true)` per browse root
  (Home + any external allowlist entry), `path == ""`, `parent == nil`.
- else:
  1. `let real = PathResolver.canonical(path)` — symlink-safe, `..`-collapsing.
  2. Assert `real` sits under a browse root via a second `PathResolver(allowedRoots: browseRoots)`
     instance's `assertAllowed`. Escape (symlink-escape, `..`, outright outside) → throw
     `pathNotAllowed`.
  3. If `real` is not a directory → throw `invalidParams`.
  4. Enumerate children (`FileManager.contentsOfDirectory`), drop dotfiles, split dir/file, sort each
     case-insensitively, dirs first.
  5. `parent = canonical(real + "/..")`, included only if it too passes `assertAllowed` (so `..`
     stops at a browse root).

`browseRoots` is a computed helper on the service: `dedupTopMost(([Config.home] +
config.allowedRoots).map(PathResolver.canonical))`.

### Dispatch — `Sources/OrchestraCore/Control/ControlServer.swift`

Add next to `spawnRepos` (~line 196):

```swift
case "listDir":
    let path = req.params?.optString("path")   // nil/"" → root listing
    return try JSONValue(encodable: try await service.listDir(path))
```

### Client — `Sources/OrchestraKit/Control/ControlClient.swift`

```swift
public func listDir(path: String?) async throws -> DirListing {
    try await call("listDir", .object(["path": .string(path ?? "")]), as: DirListing.self)
}
```

### Model — `Sources/OrchestraUI/BoardModel.swift`

```swift
public func listDir(path: String?) async -> DirListing? {
    try? await client.listDir(path: path)
}
```

## (b) iOS UI — single-pane file browser

Replace the flat picker **only for the Directory field** (repo/branch keep `SpawnPickerField`
unchanged). New component in `App-iOS/Views/SpawnSheet.swift` (or a sibling file):

### `DirBrowserField`
The existing mono free-text `TextField` (unchanged fallback) + a "Browse" button (`folder` +
`chevron.down`) that presents `DirBrowserSheet`. Binds `$cwd`.

### `DirBrowserSheet` — symmetric up/down, single pane
Not per-level `NavigationStack` pushes — a file browser wants up and down to be symmetric.

- State: `@State currentPath` (`""` = roots), `listing: DirListing?`, `loading: Bool`,
  `query: String`.
- **Seed**: open at the current `cwd` (or its parent dir) when set and in-bounds, else the root list
  — so re-opening lands where you are, and you can climb **up** to see siblings.
- **Rows**:
  - an **"⤴ up"** row when `listing.parent != nil` (tap → `currentPath = parent`, refetch);
  - **folders** — chevron, tap descends (`currentPath = entry.path`, refetch);
  - **files** — shown **disabled/dimmed** for context (not selectable);
  - at the **root** level, a leading **"Suggestions"** section preserves one-tap access to recent
    freeform dirs + repos (today's `dirSuggestions`); tapping a suggestion that is a dir descends
    into it.
- **Toolbar**: **Cancel** + **"Use this folder"** — picks `currentPath` as `cwd`, dismisses;
  disabled on the root listing (can't spawn in a synthetic root). Search filters the current
  listing.
- On selection, set `cwd`. The **existing `.onChange(of: cwd)` → `refreshTrust()` flow** fires
  unchanged: untrusted dir → forced read-only + amber "Trust & allow writes". **No trust logic is
  duplicated in the browser** — it only navigates and sets `cwd`.

## Decisions / scope

- **Files shown-but-disabled** (context per the task's "see sibling files/folders"), not dirs-only.
- **No `isGitRepo` badge** on entries in v1 — keeps the wire type minimal (revisit if repo/plain-dir
  distinction proves useful).
- **No entry cap** in v1 (UDS payload size is fine for realistic home dirs); note as a known limit
  if pathological dirs surface.
- `listDir` stays **app-only** — never an agent/MCP tool.

## Verification

- **swift test** on `listDir` — the security-critical unit. Cases: root listing; descend; dotfiles
  hidden; escape rejected (path outside browse roots); **symlink-escape rejected**; file-path
  rejected (`invalidParams`); `parent` bounded (nil at a root, set within). Build the fixture as a
  temp dir tree.
- **scripts/typecheck-ios.sh** for the iOS build.
- **scripts/iso-stack.sh up** + drive `listDir` over the control client against a **seeded temp dir
  tree with real subfolders** (the iso repo is nearly empty), asserting navigation + escape
  rejection; screenshot the iOS browser if feasible.
