#!/usr/bin/env bash
#
# install-doc-hooks.sh — install git hooks that auto-update README.md + docs/ whenever a new
# plan or code change is committed/merged into the main branch.
#
# Installs two hooks into this repo's git hooks directory (shared across all worktrees):
#   * post-commit — fires after a normal commit on main (e.g. committing a new plan).
#   * post-merge  — fires after a merge into main (e.g. merging a feature PR).
#
# Both hooks launch scripts/update-docs.sh detached, so the commit/merge returns instantly.
# update-docs.sh itself no-ops unless HEAD is on main and real (non-doc) files changed.
#
# Re-running this script is safe (idempotent). To remove the automation, run with --uninstall.
#
set -uo pipefail

MARKER="orchestra-docs-sync"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo" >&2; exit 1; }
cd "$repo_root"

# Respect core.hooksPath if set; otherwise use the common git dir's hooks/ (worktree-shared).
hooks_dir="$(git config --get core.hooksPath || true)"
if [ -z "$hooks_dir" ]; then
  hooks_dir="$(git rev-parse --git-common-dir)/hooks"
fi
mkdir -p "$hooks_dir"

uninstall() {
  local name="$1"
  local path="$hooks_dir/$name"
  [ -e "$path" ] || return 0
  if grep -q "$MARKER" "$path" 2>/dev/null; then
    if [ -e "$path.pre-orchestra.bak" ]; then
      mv "$path.pre-orchestra.bak" "$path"
      echo "[install-doc-hooks] restored previous $name from backup"
    else
      rm -f "$path"
      echo "[install-doc-hooks] removed $name"
    fi
  else
    echo "[install-doc-hooks] $name is not ours; left untouched"
  fi
}

if [ "${1:-}" = "--uninstall" ]; then
  uninstall post-commit
  uninstall post-merge
  exit 0
fi

write_hook() {
  local name="$1"
  local path="$hooks_dir/$name"
  local chain=""

  # If a foreign hook already exists, preserve it and chain to it.
  if [ -e "$path" ] && ! grep -q "$MARKER" "$path" 2>/dev/null; then
    cp "$path" "$path.pre-orchestra.bak"
    chain="$path.pre-orchestra.bak"
    echo "[install-doc-hooks] backed up existing $name -> $name.pre-orchestra.bak (it will still run)"
  fi

  {
    echo '#!/usr/bin/env bash'
    echo "# $MARKER — installed by scripts/install-doc-hooks.sh; updates docs on main."
    echo 'set -uo pipefail'
    if [ -n "$chain" ]; then
      echo "# Run the pre-existing hook first, then ours."
      echo "[ -x \"$chain\" ] && \"$chain\" \"\$@\""
    fi
    echo 'root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0'
    echo 'script="$root/scripts/update-docs.sh"'
    echo '[ -x "$script" ] || exit 0'
    echo '# Detach so the commit/merge returns immediately; update-docs.sh self-guards on branch.'
    echo '( "$script" >/dev/null 2>&1 </dev/null & )'
    echo 'exit 0'
  } >"$path"
  chmod +x "$path"
  echo "[install-doc-hooks] installed $name -> $path"
}

chmod +x "$repo_root/scripts/update-docs.sh" 2>/dev/null || true
write_hook post-commit
write_hook post-merge

cat <<EOF

Done. README.md and docs/ will now auto-update on commits/merges to the '${ORCHESTRA_DOCS_BRANCH:-main}' branch.

  • Trigger:   any commit/merge on main that changes non-doc files
  • Action:    scripts/update-docs.sh runs Claude headlessly and commits a "docs: … [docs-sync]" commit
  • Guards:    only on main; skips doc-only commits; single-flight lock; never blocks/fails your commit
  • Logs:      .git/orchestra-docs-sync.log
  • Pause:     export ORCHESTRA_DOCS_BRANCH=__disabled__   (hooks become no-ops)
  • Remove:    scripts/install-doc-hooks.sh --uninstall

See docs/11-doc-automation.md for the full description.
EOF
