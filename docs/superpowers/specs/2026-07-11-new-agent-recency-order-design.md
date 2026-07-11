# New Agent Picker Recency Ordering Design

## Goal

Show repositories, branches, and local base branches in the New Agent worktree flow from most recently committed to least recently committed on both the macOS and iOS clients.

## Current State

Branches already use `git for-each-ref --sort=-committerdate refs/heads` in both the macOS Spawn sheet and the daemon endpoint consumed by iOS. The base-branch picker reuses that same ordered branch list.

Repositories are the inconsistency: `RepoScanner` sorts desktop candidates by repository name, and `OrchestraService.spawnRepos()` independently lists direct child repositories and sorts them by name for iOS.

## Design

`RepoScanner` becomes the single repository-discovery and ordering seam for both clients. After finding repositories, it will rank them by the newest committer timestamp among their local branches, queried with Git's `for-each-ref` over `refs/heads`. This aligns repository recency with the existing branch and base-branch definition.

Repositories with no local commits, unreadable Git metadata, or a Git query failure remain selectable. They sort after repositories with a timestamp and use a case-insensitive repository-name/path ordering as a deterministic tie-breaker.

The macOS Spawn sheet continues to call `RepoScanner.discoverAsync`, now receiving recency-ordered candidates. `OrchestraService.spawnRepos()` will call that same scanner instead of maintaining a shallower, separately sorted enumeration. The iOS picker must preserve that supplied order rather than applying its current name sort.

No sort is added to branch or base-branch UI code: their current shared `--sort=-committerdate` source already satisfies the behavior.

## Error Handling and Performance

Repository discovery stays off the UI/service actor. Each repository's bounded Git metadata query is best-effort; failure produces the fallback order rather than failing or omitting the repository list. No repository state is written and no remote fetch is performed.

## Tests

Add a pure `RepoScanner` ordering test that injects distinct timestamps and verifies newest-first ordering, deterministic ties, and uncommitted/unqueryable repositories last. Update existing scanner assertions and add service coverage as needed to demonstrate the iOS endpoint uses the same recursive, recency-ordered scanner rather than its removed alphabetical path.

Existing branch-picker behavior remains covered by its implementation contract: both the branch and local base picker consume the same `branches` / `branchSuggestions` list returned in descending committer-date order.

## Scope

This changes only New Agent candidate ordering. It does not add history persistence, use card activity as a proxy for Git activity, change directory picker order, query remotes, or alter what paths are allowed to spawn.
