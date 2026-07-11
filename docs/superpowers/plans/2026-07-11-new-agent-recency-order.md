# New Agent Recency Ordering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sort New Agent repositories by newest local commit while retaining the existing newest-first ordering for branches and local base branches on macOS and iOS.

**Architecture:** `RepoScanner` discovers and ranks repositories once for both clients. A bounded Git query reads the newest local-branch committer timestamp; timestamp-less repositories sort last using a stable name/path tie-breaker.

**Tech Stack:** Swift 6, Swift Testing, Foundation, `Proc.run`.

## Global Constraints

- Use local `refs/heads` committer timestamps only; do not fetch or query remotes.
- Keep Git work off UI and service actors through `RepoScanner.discoverAsync`.
- Preserve repositories whose Git timestamp is unavailable.
- Do not change freeform-directory order or the existing branch/base `--sort=-committerdate` behavior.

---

### Task 1: Centralize and test repository recency ordering

**Files:**

- Modify: `Tests/OrchestraCoreTests/RepoScannerTests.swift`
- Modify: `Sources/OrchestraCore/RepoScanner.swift`

**Interfaces:**

- Produces: `RepoScanner.orderByMostRecentCommit(_:commitTimestamp:) -> [String]`.
- Consumes: discovered absolute paths and an injected `Int?` Unix timestamp lookup.

- [ ] **Step 1: Write the failing regression test**

Add beside the scanner tests:

```swift
@Test("orders repositories by newest local commit, then deterministic fallbacks")
func recentCommitOrder() {
    let repos = ["/repos/Zed", "/repos/alpha", "/repos/Beta", "/repos/empty"]
    let timestamps = ["/repos/Zed": 100, "/repos/alpha": 300, "/repos/Beta": 100]

    let found = RepoScanner.orderByMostRecentCommit(repos) { timestamps[$0] }

    #expect(found == ["/repos/alpha", "/repos/Beta", "/repos/Zed", "/repos/empty"])
}
```

- [ ] **Step 2: Verify the test is red**

Run: `./scripts/test.sh --filter RepoScannerTests/recentCommitOrder`

Expected: FAIL because `orderByMostRecentCommit` does not exist.

- [ ] **Step 3: Add the minimal ordering implementation**

Add to `RepoScanner`:

```swift
static func orderByMostRecentCommit(_ repos: [String], commitTimestamp: (String) -> Int?) -> [String] {
    repos.map { (path: $0, timestamp: commitTimestamp($0)) }
        .sorted { lhs, rhs in
            switch (lhs.timestamp, rhs.timestamp) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let ln = (lhs.path as NSString).lastPathComponent
                let rn = (rhs.path as NSString).lastPathComponent
                switch ln.localizedCaseInsensitiveCompare(rn) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.path < rhs.path
                }
            }
        }
        .map(\.path)
}

private static func newestLocalCommitTimestamp(in repo: String) -> Int? {
    guard let result = try? Proc.run(
        ["git", "-C", repo, "for-each-ref", "--format=%(committerdate:unix)",
         "--sort=-committerdate", "--count=1", "refs/heads"], timeout: .seconds(2)
    ), result.ok else { return nil }
    return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
}
```

Make `scan` return its discovery list without name sorting. In `discover`, save `scan` to `repos` and return `orderByMostRecentCommit(repos, commitTimestamp: newestLocalCommitTimestamp)`. Update the `scan` and `discover` comments to distinguish discovery from commit-recency order.

- [ ] **Step 4: Verify the focused suite is green**

Run: `./scripts/test.sh --filter RepoScannerTests`

Expected: PASS, including newest-first, deterministic-tie, and timestamp-less coverage.

- [ ] **Step 5: Commit the core task**

Run: `git add Sources/OrchestraCore/RepoScanner.swift Tests/OrchestraCoreTests/RepoScannerTests.swift`

Run: `git commit -m "feat: order repo candidates by latest commit"`

### Task 2: Share that order with iOS and preserve it in its Repository picker

**Files:**

- Modify: `Sources/OrchestraCore/OrchestraService.swift:1062-1081`
- Modify: `App-iOS/Views/SpawnSheet.swift:110-141`

**Interfaces:**

- Consumes: `RepoScanner.discoverAsync(root:)` from Task 1.
- Produces: a recency-ordered `spawnRepos` RPC and an iOS Repository picker that preserves it.

- [ ] **Step 1: Replace the iOS-specific alphabetical source and UI re-sort**

Replace `OrchestraService.spawnRepos()` with:

```swift
public func spawnRepos() async -> [String] {
    await RepoScanner.discoverAsync(root: config.reposRoot)
}
```

Make `repoSuggestions` in `App-iOS/Views/SpawnSheet.swift` return `dedup(model.spawnRepoCandidates)` and remove `sortedByName`. Update comments to say repository values arrive in latest-commit order. Leave `branchSuggestions` and the base Picker untouched; they already consume descending-committer-date branch options.

- [ ] **Step 2: Run focused tests and typecheck app surfaces**

Run: `./scripts/test.sh --filter RepoScannerTests && scripts/typecheck-app.sh`

Expected: both commands exit 0.

- [ ] **Step 3: Check all candidate sources**

Run: `rg -n "orderByMostRecentCommit|newestLocalCommitTimestamp|RepoScanner.discoverAsync|--sort=-committerdate|repoSuggestions" Sources/OrchestraCore/RepoScanner.swift Sources/OrchestraCore/OrchestraService.swift App/Views/SpawnSheet.swift App-iOS/Views/SpawnSheet.swift`

Expected: both repository sources route through `RepoScanner`; both branch sources retain `--sort=-committerdate`; iOS does not name-sort repository suggestions.

- [ ] **Step 4: Commit the iOS wiring task**

Run: `git add Sources/OrchestraCore/OrchestraService.swift App-iOS/Views/SpawnSheet.swift`

Run: `git commit -m "feat: share recent repo order with ios"`

### Task 3: Validate integrated behavior

**Files:**

- Verify only: `Sources/OrchestraCore/RepoScanner.swift`
- Verify only: `Sources/OrchestraCore/OrchestraService.swift`
- Verify only: `App/Views/SpawnSheet.swift`
- Verify only: `App-iOS/Views/SpawnSheet.swift`

**Interfaces:**

- Consumes: completed Tasks 1 and 2.
- Produces: evidence that repository, branch, and base-branch sources sort newest first.

- [ ] **Step 1: Run project checks**

Run: `./scripts/test.sh --filter RepoScannerTests && scripts/typecheck-app.sh`

Expected: both commands exit 0 with no test failures or compiler errors.

- [ ] **Step 2: Review the final diff**

Run: `git diff --check HEAD~2..HEAD && git status --short`

Expected: no whitespace errors and no uncommitted task files.
