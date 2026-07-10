#!/bin/bash
# gen-slow-repo.sh — generate a large git repo whose `git worktree add` checkout takes multiple seconds.
# Usage: gen-slow-repo.sh <repo-dir> [file-count]   (default 12000; the Swift caller always passes one)
# Files are tiny and spread across nested dirs so file COUNT (not size) drives checkout time. The repo is
# generated fresh at test setup and torn down after — it is never committed to THIS repository.
#
# File creation uses a single `awk` pass (no per-file subprocess fork) rather than a shell loop, keeping
# generation as cheap as the filesystem allows even at tens of thousands of files (the cost is dominated
# by inode creation + git hashing, so the count is chosen to bound total setup time).
set -euo pipefail
repo="${1:?repo dir required}"
count="${2:-12000}"
per_dir=200                                   # files per leaf dir → count/200 dirs

mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email "t@t.t"
git -C "$repo" config user.name "T"
git -C "$repo" config core.autocrlf false

# Pre-create the leaf dirs (count/per_dir of them — cheap), then let awk write every file with no forks.
ndirs=$(( (count + per_dir - 1) / per_dir ))
for ((d = 0; d < ndirs; d++)); do mkdir -p "$repo/d$d"; done
awk -v count="$count" -v per="$per_dir" -v repo="$repo" 'BEGIN {
  for (i = 0; i < count; i++) {
    f = repo "/d" int(i / per) "/f" i ".txt"
    print "f" i > f
    close(f)                                  # awk caps concurrent open files — close each after writing
  }
}'

git -C "$repo" add -A
git -C "$repo" commit -q -m "seed $count files"
