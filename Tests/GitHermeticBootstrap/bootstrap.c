// Bundle-wide environment isolation for the test suite: a hermetic git config, and a HOME of its own.
//
// WHY THIS IS C, AND WHY IT LIVES HERE
//
// Every real-`git` fork made during a test run — the ~116 from test code, and every fork made by the
// *production* code under test (SessionManager, DiffService, BranchLineage, worktree creation) — goes
// through `Proc.run`, which rebuilds the child environment from `ProcessInfo.processInfo.environment`
// on every call. Likewise every HOME-derived path (Config.dataDir, scratchRoot, worktreesRoot) resolves
// `$HOME` from that same process environment on each access. So isolating the suite needs exactly one
// thing: the right variables set in the test process, once, before the first test runs.
//
// The hard part is the "before": this is a mixed XCTest + swift-testing suite, and neither runner
// offers a bundle-wide setup hook, while the ~20 test files that fork git each roll their own local
// `git(...)` helper (so there is nothing shared to hang a bootstrap off, and production-side forks and
// writes would escape it anyway). A C constructor is the hook that does exist: it runs when the test
// bundle is loaded — before the first test of *either* runner, in debug and release — with no import,
// no call site, and no discipline required of test authors.
//
// Because this target lives under Tests/ and only the test targets depend on it, it CANNOT be linked
// into orchestrad / orchestra / orchestra-mcp. Production behaviour is unchanged by construction:
// the daemon still reads the user's real gitconfig and the user's real home.
//
// Design: docs/08-building-operations.md (§Test hermeticity)

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>   // mkdtemp (POSIX; on Linux it is declared here, not in stdlib.h)

// ---------------------------------------------------------------------------------------------
// HOME
//
// The suite's writes are not confined to git. A full run under an instrumented home was observed to
// write ALL of this into the developer's real one: the production scratch root (~/.orchestra/scratch),
// fake-agent transcripts (~/.claude/projects/**), Claude Code's own ~/.claude.json, and — the one that
// actually bit — ~/Library/Application Support/Orchestra/claude-hooks.json.
//
// That last file is shared, live state. ClaudeCodeAdapter.prepareToLaunch renders the managed hooks
// settings to Config.hooksPath, substituting __ORCHESTRA_BIN__ with a path derived from the RUNNING
// executable. Under `swift test` the running executable is Xcode's swiftpm-testing-helper, so the
// tests that call prepareToLaunch directly wrote a nonexistent
// `.../XcodeDefault.xctoolchain/usr/libexec/swift/pm/orchestra` into the single settings file that
// every live Claude session was launched with (`--settings <Config.hooksPath>`). Claude re-reads it
// mid-session, so every hook in every running card immediately started erroring. `swift test` must
// never be able to reach that file — nor any other live state — at all.
//
// So: relocate HOME to a fresh, empty, per-run temp dir. Nothing here is git-specific; it just needs
// the same "before the first test, without discipline" property, which is why it shares this hook.
//
// LIFECYCLE: the temp home is deliberately NOT removed at exit. It lives under $TMPDIR (per-user
// /var/folders on macOS, which the OS reaps), so leaving it costs nothing and keeps a failed run's
// artifacts — rendered hooks files, transcripts, scratch dirs — available to inspect. An atexit sweep
// would also be actively wrong: E2EBinaryTests spawns real orchestrad/orchestra processes that inherit
// this HOME and may outlive the test process, and an atexit handler does not run at all when the suite
// crashes or is killed — so the sweep would be both racy and unreliable. Reaping is the OS's job.
static void orchestra_isolate_home(void) {
    // Escape hatch, mirroring ORCHESTRA_TEST_GIT_HERMETIC: run the suite against the developer's real
    // home to debug a home-sensitive failure. It cannot be quiet — HomeIsolationTests fails when set.
    const char *opt_out = getenv("ORCHESTRA_TEST_HOME_ISOLATION");
    if (opt_out != NULL && strcmp(opt_out, "0") == 0) return;

    // The temp home MUST live outside the repo checkout: Config.defaultReposRoot *is* $HOME, RepoScanner
    // scans recursively under it (so a home inside the working copy would make the suite scan itself),
    // and RepoScannerTests asserts the root contains no "/Documents/Projects". $TMPDIR (or /tmp) is
    // outside any checkout by construction.
    const char *tmp = getenv("TMPDIR");
    if (tmp == NULL || tmp[0] != '/') tmp = "/tmp";
    const char *sep = (tmp[strlen(tmp) - 1] == '/') ? "" : "/";

    char tmpl[PATH_MAX];
    int n = snprintf(tmpl, sizeof(tmpl), "%s%sorchestra-test-home-XXXXXX", tmp, sep);
    if (n < 0 || (size_t)n >= sizeof(tmpl) || mkdtemp(tmpl) == NULL) {
        // Fail CLOSED. Falling back to the real home is the exact failure this exists to prevent, and
        // it would corrupt live state (see above) rather than merely fail a test — so refuse to run.
        fprintf(stderr,
                "orchestra test bootstrap: could not create an isolated HOME under %s — refusing to run "
                "the suite against the developer's real home. Set ORCHESTRA_TEST_HOME_ISOLATION=0 to "
                "override deliberately.\n", tmp);
        abort();
    }
    setenv("HOME", tmpl, 1);

    // Config.dataDir prefers $XDG_DATA_HOME over $HOME on Linux, so an inherited one would walk straight
    // back out of the temp home. Clear it and let the $HOME-relative default apply.
    unsetenv("XDG_DATA_HOME");
}

__attribute__((constructor))
static void orchestra_install_hermetic_git_env(void) {
    orchestra_isolate_home();

    // Escape hatch: run the suite against the developer's real git config, for debugging a failure
    // that is suspected to be config-sensitive.
    const char *opt_out = getenv("ORCHESTRA_TEST_GIT_HERMETIC");
    if (opt_out != NULL && strcmp(opt_out, "0") == 0) return;

    // FIRST, clear EVERY git variable we inherited — then install exactly the ones we want, below.
    //
    // Controlling git's *config* is not sufficient on its own: git takes a great deal of its behavior
    // straight from the environment, and a single inherited variable silently defeats the whole scheme.
    // Three found in review, each demonstrated live:
    //
    //   * GIT_CONFIG_PARAMETERS is the older form of `-c` and is parsed IN ADDITION to GIT_CONFIG_COUNT,
    //     so an inherited one injects config straight past our overrides — a `credential.helper=!…` in
    //     it still RAN, which is the exact keychain invocation this bootstrap exists to prevent.
    //   * GIT_DIR / GIT_WORK_TREE point git at a DIFFERENT repository, overriding even an explicit
    //     `git -C <tmpdir>` — so a test's commits and config writes could land in the developer's repo.
    //   * GIT_EXTERNAL_DIFF replaces git's builtin diff with a program of the parent's choosing, which
    //     would hijack the very code under test (DiffService/DiffProvider are built on `git diff`).
    //
    // These are inherited for real whenever the suite runs from inside a git operation — a hook, an
    // alias, a rebase's `exec` step.
    //
    // This is a WILDCARD sweep, not a list of the three above, and deliberately so: two successive
    // reviews each found "one more variable" (GIT_CONFIG_PARAMETERS, then GIT_EXTERNAL_DIFF). A denylist
    // is a standing invitation to miss the next one — GIT_SSH_COMMAND, GIT_PROXY_COMMAND, GIT_PAGER,
    // whatever git adds in a future release. Clearing the whole namespace is the only form of this that
    // is complete by construction rather than by vigilance. Nothing is lost: every git variable the
    // suite actually wants is set explicitly below, and production passes its own via Proc.run's
    // per-call `env:` argument, which is unaffected by the test process's environment.
    extern char **environ;
    for (;;) {
        const char *found = NULL;
        for (char **e = environ; *e != NULL; e++) {
            if (strncmp(*e, "GIT_", 4) != 0) continue;
            static char name[256];
            const char *eq = strchr(*e, '=');
            size_t n = eq ? (size_t)(eq - *e) : strlen(*e);
            if (n >= sizeof(name)) continue;
            memcpy(name, *e, n);
            name[n] = '\0';
            found = name;
            break;
        }
        if (found == NULL) break;   // no GIT_* left
        // unsetenv() mutates `environ`, so re-scan from the top rather than continuing to walk it.
        unsetenv(found);
    }

    // Cut every config scope outside the repo itself. GIT_CONFIG_GLOBAL replaces BOTH ~/.gitconfig and
    // the XDG config ($XDG_CONFIG_HOME/git/config), so pointing it at /dev/null makes git see an empty
    // global scope regardless of where HOME points. Keep it: it is what makes the git hermeticity hold
    // even under ORCHESTRA_TEST_HOME_ISOLATION=0, and it cuts the XDG path, which relocating HOME alone
    // would not. (This comment used to argue the converse — that HOME therefore "does not need to be
    // relocated". That was reasoning about git and only git; every non-git write in the suite — the
    // trust ledger, Config.dataDir, the rendered hooks files, scratch dirs, transcripts — landed in the
    // developer's real home as a result. See orchestra_isolate_home() above. Do not re-open it.)
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
