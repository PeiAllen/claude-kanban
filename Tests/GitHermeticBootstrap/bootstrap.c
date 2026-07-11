// Bundle-wide git hermeticity for the test suite.
//
// WHY THIS IS C, AND WHY IT LIVES HERE
//
// Every real-`git` fork made during a test run — the ~116 from test code, and every fork made by the
// *production* code under test (SessionManager, DiffService, BranchLineage, worktree creation) — goes
// through `Proc.run`, which rebuilds the child environment from `ProcessInfo.processInfo.environment`
// on every call. So making the suite hermetic needs exactly one thing: the right variables set in the
// test process, once, before the first git fork.
//
// The hard part is the "before": this is a mixed XCTest + swift-testing suite, and neither runner
// offers a bundle-wide setup hook, while the ~20 test files that fork git each roll their own local
// `git(...)` helper (so there is nothing shared to hang a bootstrap off, and production-side forks
// would escape it anyway). A C constructor is the hook that does exist: it runs when the test bundle
// is loaded — before the first test of *either* runner, in debug and release — with no import, no
// call site, and no discipline required of test authors.
//
// Because this target lives under Tests/ and only the test targets depend on it, it CANNOT be linked
// into orchestrad / orchestra / orchestra-mcp. Production behaviour is unchanged by construction:
// the daemon still reads the user's real gitconfig.
//
// Design: notes/designs/2026-07-11-test-suite-git-hermeticity.md

#include <stdlib.h>
#include <string.h>

__attribute__((constructor))
static void orchestra_install_hermetic_git_env(void) {
    // Escape hatch: run the suite against the developer's real git config, for debugging a failure
    // that is suspected to be config-sensitive.
    const char *opt_out = getenv("ORCHESTRA_TEST_GIT_HERMETIC");
    if (opt_out != NULL && strcmp(opt_out, "0") == 0) return;

    // Cut every config scope outside the repo itself. GIT_CONFIG_GLOBAL replaces BOTH ~/.gitconfig
    // and the XDG config ($XDG_CONFIG_HOME/git/config), so pointing it at /dev/null makes git see an
    // empty global scope — which is why HOME does not need to be relocated (and is deliberately left
    // alone: the trust ledger, Config.dataDir and transcript discovery all read the real home).
    setenv("GIT_CONFIG_NOSYSTEM", "1", 1);
    setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1);

    // GIT_CONFIG_COUNT/KEY/VALUE is the env form of `-c`, so these two win over EVERY config scope,
    // including repo-local. Clearing credential.helper is the point of the exercise: the developer's
    // `credential.helper = osxkeychain` made git invoke the keychain helper during tests, which the
    // Claude Code sandbox denies (it blocks ~/Library/Keychains) — surfacing as keychain errors and
    // dialogs mid-run. Note the suite's pre-existing guard, RemoteParents.remoteEnv(), does NOT
    // disable the helper; only clearing the key does.
    setenv("GIT_CONFIG_COUNT", "2", 1);
    setenv("GIT_CONFIG_KEY_0", "credential.helper", 1);
    setenv("GIT_CONFIG_VALUE_0", "", 1);
    setenv("GIT_CONFIG_KEY_1", "init.defaultBranch", 1);
    setenv("GIT_CONFIG_VALUE_1", "main", 1);

    // Never block on a prompt if something does reach for a credential.
    setenv("GIT_TERMINAL_PROMPT", "0", 1);
    setenv("GIT_ASKPASS", "/usr/bin/false", 1);

    // Cutting the global scope also takes away the developer's user.name/user.email — which several
    // tests (and Fixtures/gen-slow-repo.sh) rely on to commit. Supply a fixed identity instead, so
    // commits work on a machine with no git identity at all and are reproducible across machines.
    // These env vars outrank a repo-local `git config user.email`, so the handful of tests that set
    // one locally now have it as a no-op — harmless (no test asserts a commit author) and strictly
    // more deterministic.
    setenv("GIT_AUTHOR_NAME", "Orchestra Test", 1);
    setenv("GIT_AUTHOR_EMAIL", "test@orchestra.invalid", 1);
    setenv("GIT_COMMITTER_NAME", "Orchestra Test", 1);
    setenv("GIT_COMMITTER_EMAIL", "test@orchestra.invalid", 1);
}
